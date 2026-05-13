#!/system/bin/sh

# Configuration
SOURCE_DIRS="/storage/emulated/0/SendAnywhere /storage/emulated/0/Download /storage/emulated/0/DCIM /storage/emulated/0/Pictures"
PHOTOS_DB="/data/data/com.google.android.apps.photos/databases/gphotos0.db"
MODULE_DIR="/data/adb/modules/gphotos_auto_backup"
LOG_FILE="$MODULE_DIR/monitor.log"
STATUS_FILE="$MODULE_DIR/status.txt"
IN_PROGRESS_FILE="$MODULE_DIR/in_progress.txt"
PENDING_DELETE_FILE="$MODULE_DIR/pending_delete.txt"
SLEEP_INTERVAL=15
CLEANUP_DELAY=300

# Binary paths
SQLITE="/system/bin/sqlite3"
[ ! -f "$SQLITE" ] && SQLITE=$(which sqlite3)

log() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - $msg" >> "$LOG_FILE"
    # Also log to system logcat for easier debugging via apps
    log -t "GPhotosAuto" "$msg"

    if [ $(wc -l < "$LOG_FILE" 2>/dev/null || echo 0) -gt 2000 ]; then
        sed -i '1,1000d' "$LOG_FILE"
    fi
}

notify() {
    /system/bin/cmd notification post -p -S bigtext -t "GPhotos Backup" "tag_backup" "$1" >/dev/null 2>&1
}

# Ensure environment
touch "$IN_PROGRESS_FILE" "$PENDING_DELETE_FILE" "$LOG_FILE"
chmod 666 "$IN_PROGRESS_FILE" "$PENDING_DELETE_FILE" "$LOG_FILE" 2>/dev/null

escape_sql() {
    echo "$1" | sed "s/'/''/g"
}

scan_file() {
    local filepath="$1"
    /system/bin/am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$filepath" > /dev/null 2>&1
}

check_backups_batch() {
    local list_file="$1"
    [ ! -f "$PHOTOS_DB" ] && return
    [ ! -s "$list_file" ] && return
    [ -z "$SQLITE" ] && return

    local results_file=$(mktemp)
    # Broad check for backup success
    "$SQLITE" "$PHOTOS_DB" "SELECT filepath FROM local_media WHERE state IN (3,4) OR remote_url IS NOT NULL OR remote_media_key IS NOT NULL UNION SELECT local_path FROM local_media WHERE state IN (3,4) OR remote_url IS NOT NULL OR remote_media_key IS NOT NULL;" > "$results_file" 2>/dev/null

    grep -Fxf "$results_file" "$list_file"
    rm -f "$results_file"
}

get_file_info() {
    local filepath="$1"
    local escaped_path=$(escape_sql "$filepath")
    # Query ID and MIME type
    local info=$(/system/bin/content query --uri content://media/external/file --projection _id,mime_type --where "_data='$escaped_path'" 2>/dev/null)
    local id=$(echo "$info" | sed -n 's/.*_id=\([0-9]*\).*/\1/p')
    local mime=$(echo "$info" | sed -n 's/.*mime_type=\([^, ]*\).*/\1/p')

    if [ -n "$id" ]; then
        echo "$id|$mime"
    else
        # Fallback to display name
        local fname=$(basename "$filepath")
        local escaped_name=$(escape_sql "$fname")
        info=$(/system/bin/content query --uri content://media/external/file --projection _id,mime_type --where "_display_name='$escaped_name'" 2>/dev/null | head -n 1)
        id=$(echo "$info" | sed -n 's/.*_id=\([0-9]*\).*/\1/p')
        mime=$(echo "$info" | sed -n 's/.*mime_type=\([^, ]*\).*/\1/p')
        [ -n "$id" ] && echo "$id|$mime" || echo "|"
    fi
}

trigger_single_upload() {
    local filepath="$1"

    # Ensure MediaStore is updated
    scan_file "$filepath"
    sleep 1

    local info=$(get_file_info "$filepath")
    local id=${info%|*}
    local mime=${info#*|}

    local curi=""
    [ -n "$id" ] && curi="content://media/external/file/$id" || curi="file://$filepath"
    [ -z "$mime" ] && mime="*/*"

    log "Initiating upload: $filepath (MIME: $mime)"

    # Standard ACTION_SEND is what "Sharing" uses
    # We try multiple ways to ensure one works
    local success=0

    # Method 1: Target the specific upload activity (most direct)
    # Method 2: Target the general photos package with ACTION_SEND
    for method in "am start -n com.google.android.apps.photos/com.google.android.apps.photos.upload.UploadContentActivity" \
                  "am start -n com.google.android.apps.photos/com.google.android.apps.photos.share.handler.ShareHandlerActivity" \
                  "am start com.google.android.apps.photos"; do

        local cmd="$method -a android.intent.action.SEND --eu android.intent.extra.STREAM \"$curi\" -t \"$mime\" --grant-read-uri-permission --user 0"
        local out=$(eval "$cmd" 2>&1)

        if echo "$out" | grep -q "Error"; then
            log "Method [$method] failed: $out"
        else
            log "Method [$method] succeeded."
            success=1
            break
        fi
    done

    if [ "$success" -eq 1 ]; then
        echo "$(date +%s)|$filepath" >> "$IN_PROGRESS_FILE"
        return 0
    else
        log "CRITICAL: All upload methods failed for $filepath"
        return 1
    fi
}

# Start Heartbeat
log "Monitor Engine Active. Polling interval: ${SLEEP_INTERVAL}s"

while true; do
    now=$(date +%s)
    echo "Last Run: $(date)" > "$STATUS_FILE"

    # 1. Verification & Cleanup Queue
    if [ -s "$IN_PROGRESS_FILE" ]; then
        tmp_check=$(mktemp)
        awk -F'|' '{print $2}' "$IN_PROGRESS_FILE" > "$tmp_check"
        backed_up_files=$(mktemp)
        check_backups_batch "$tmp_check" > "$backed_up_files"

        tmp_new_progress=$(mktemp)
        while IFS='|' read -r timestamp file; do
            if grep -qFx "$file" "$backed_up_files" 2>/dev/null; then
                log "Verification Success: $file. Queued for deletion."
                echo "$(date +%s)|$file" >> "$PENDING_DELETE_FILE"
            elif [ $((now - timestamp)) -gt 3600 ]; then
                log "Upload Timeout: $file. Will retry next cycle."
            else
                echo "$timestamp|$file" >> "$tmp_new_progress"
            fi
        done < "$IN_PROGRESS_FILE"
        mv "$tmp_new_progress" "$IN_PROGRESS_FILE"
        rm -f "$tmp_check" "$backed_up_files"
    fi

    # 2. Execute Cleanup (5m delay)
    if [ -s "$PENDING_DELETE_FILE" ]; then
        tmp_pending=$(mktemp)
        del_count=0
        while IFS='|' read -r timestamp file; do
            if [ $((now - timestamp)) -ge $CLEANUP_DELAY ]; then
                [ -f "$file" ] && rm -f "$file" && del_count=$((del_count + 1))
            else
                echo "$timestamp|$file" >> "$tmp_pending"
            fi
        done < "$PENDING_DELETE_FILE"
        mv "$tmp_pending" "$PENDING_DELETE_FILE"
        [ $del_count -gt 0 ] && log "Cleanup: Removed $del_count files."
    fi

    # 3. Discovery & Trigger
    discovery_list=$(mktemp)
    for dir in $SOURCE_DIRS; do
        [ -d "$dir" ] && find "$dir" -maxdepth 1 -type f ! -name ".*" >> "$discovery_list"
    done

    if [ -s "$discovery_list" ]; then
        trig_count=0
        while IFS= read -r file; do
            # Skip if already handled
            grep -qF "|$file" "$IN_PROGRESS_FILE" "$PENDING_DELETE_FILE" 2>/dev/null && continue

            # Size stability check (ensure download finished)
            s1=$(stat -c%s "$file" 2>/dev/null || echo 0)
            [ "$s1" -eq 0 ] && continue
            sleep 1
            s2=$(stat -c%s "$file" 2>/dev/null || echo 0)
            [ "$s1" != "$s2" ] && continue

            if trigger_single_upload "$file"; then
                trig_count=$((trig_count + 1))
                sleep 2 # Calm down between intents
            fi

            # Limit triggers per cycle
            [ $trig_count -ge 5 ] && break
        done < "$discovery_list"

        if [ $trig_count -gt 0 ]; then
            notify "Triggered $trig_count backups."
            if dumpsys display | grep -q "mScreenState=ON"; then
                sleep 2
                input keyevent KEYCODE_HOME
            fi
        fi
    fi
    rm -f "$discovery_list"

    sleep $SLEEP_INTERVAL
done
