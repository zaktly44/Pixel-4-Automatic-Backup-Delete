#!/system/bin/sh

# Configuration
SOURCE_DIRS="/storage/emulated/0/SendAnywhere /storage/emulated/0/Download"
PHOTOS_DB="/data/data/com.google.android.apps.photos/databases/gphotos0.db"
MODULE_DIR="/data/adb/modules/gphotos_auto_backup"
LOG_FILE="$MODULE_DIR/monitor.log"
IN_PROGRESS_FILE="$MODULE_DIR/in_progress.txt"
PENDING_DELETE_FILE="$MODULE_DIR/pending_delete.txt"
SLEEP_INTERVAL=15
CLEANUP_DELAY=300
BATCH_SIZE=50

# Binary paths
SQLITE="/system/bin/sqlite3"
[ ! -f "$SQLITE" ] && SQLITE=$(which sqlite3)

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    if [ $(wc -l < "$LOG_FILE" 2>/dev/null || echo 0) -gt 2000 ]; then
        sed -i '1,1000d' "$LOG_FILE"
    fi
}

notify() {
    /system/bin/cmd notification post -S bigtext -t "GPhotos Backup" "tag_backup" "$1" >/dev/null 2>&1
}

# Ensure state files exist with correct permissions
touch "$IN_PROGRESS_FILE" "$PENDING_DELETE_FILE"
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
    "$SQLITE" "$PHOTOS_DB" "SELECT filepath FROM local_media WHERE state IN (3,4) OR remote_url IS NOT NULL OR remote_media_key IS NOT NULL;" > "$results_file" 2>/dev/null

    grep -Fxf "$results_file" "$list_file"
    rm -f "$results_file"
}

get_content_uri() {
    local filepath="$1"
    local escaped_path=$(escape_sql "$filepath")
    local id=$(/system/bin/content query --uri content://media/external/file --projection _id --where "_data='$escaped_path'" 2>/dev/null | sed -n 's/.*_id=\([0-9]*\).*/\1/p')
    if [ -n "$id" ]; then
        echo "content://media/external/file/$id"
    else
        log "Missing ID for $filepath. Scanning..."
        scan_file "$filepath"
        sleep 2
        id=$(/system/bin/content query --uri content://media/external/file --projection _id --where "_data='$escaped_path'" 2>/dev/null | sed -n 's/.*_id=\([0-9]*\).*/\1/p')
        [ -n "$id" ] && echo "content://media/external/file/$id" || echo "file://$filepath"
    fi
}

trigger_batch_upload() {
    local files_file="$1"
    [ ! -s "$files_file" ] && return

    local uris=""
    local count=0

    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local curi=$(get_content_uri "$f")
        uris="${uris}${curi},"
        echo "$(date +%s)|$f" >> "$IN_PROGRESS_FILE"
        count=$((count + 1))
    done < "$files_file"
    uris=${uris%,}

    log "Triggering upload for $count files."
    notify "Uploading $count files..."

    # Adding --grant-read-uri-permission for content:// URIs
    local out=$(/system/bin/am start -n com.google.android.apps.photos/com.google.android.apps.photos.upload.UploadContentActivity \
             -a android.intent.action.SEND_MULTIPLE \
             --eua android.intent.extra.STREAM "$uris" \
             --grant-read-uri-permission \
             -t "*/*" \
             --user 0 2>&1)

    log "Intent output: $out"

    if [ "$(getprop sys.boot_completed)" = "1" ] && /system/bin/dumpsys display | grep -q "mScreenState=ON"; then
        sleep 2
        /system/bin/input keyevent KEYCODE_HOME
    fi
}

# Main loop
log "--- Monitor Start (Diagnostic Mode) ---"

while true; do
    now=$(date +%s)

    # 1. Cleanup
    if [ -s "$PENDING_DELETE_FILE" ]; then
        tmp_pending=$(mktemp)
        deleted=0
        while IFS='|' read -r timestamp file; do
            if [ $((now - timestamp)) -ge $CLEANUP_DELAY ]; then
                [ -f "$file" ] && rm -f "$file" && deleted=$((deleted+1))
            else
                echo "$timestamp|$file" >> "$tmp_pending"
            fi
        done < "$PENDING_DELETE_FILE"
        mv "$tmp_pending" "$PENDING_DELETE_FILE"
        [ $deleted -gt 0 ] && log "Deleted $deleted confirmed files."
    fi

    # 2. Verification
    if [ -s "$IN_PROGRESS_FILE" ]; then
        tmp_check=$(mktemp)
        awk -F'|' '{print $2}' "$IN_PROGRESS_FILE" > "$tmp_check"
        backed_up_files=$(mktemp)
        check_backups_batch "$tmp_check" > "$backed_up_files"

        tmp_new_progress=$(mktemp)
        while IFS='|' read -r timestamp file; do
            if grep -qFx "$file" "$backed_up_files" 2>/dev/null; then
                log "Confirmed backup: $file"
                echo "$(date +%s)|$file" >> "$PENDING_DELETE_FILE"
            elif [ $((now - timestamp)) -gt 3600 ]; then
                log "Upload timeout: $file"
            else
                echo "$timestamp|$file" >> "$tmp_new_progress"
            fi
        done < "$IN_PROGRESS_FILE"
        mv "$tmp_new_progress" "$IN_PROGRESS_FILE"
        rm -f "$tmp_check" "$backed_up_files"
    fi

    # 3. Discovery
    found_any_in_dirs=0
    discovery_list=$(mktemp)
    for dir in $SOURCE_DIRS; do
        if [ -d "$dir" ]; then
            /system/bin/find "$dir" -maxdepth 1 -type f ! -name ".*" >> "$discovery_list"
            found_any_in_dirs=1
        fi
    done

    if [ "$found_any_in_dirs" -eq 1 ] && [ -s "$discovery_list" ]; then
        batch_trigger_file=$(mktemp)
        batch_count=0

        while IFS= read -r file; do
            # Robust check for already tracked files
            if ! grep -qF "|$file" "$IN_PROGRESS_FILE" "$PENDING_DELETE_FILE" 2>/dev/null; then
                log "Discovered new file: $file"

                s1=$(stat -c%s "$file" 2>/dev/null || echo 0)
                [ "$s1" -eq 0 ] && continue
                sleep 1
                s2=$(stat -c%s "$file" 2>/dev/null || echo 0)
                if [ "$s1" != "$s2" ]; then
                    log "Skipping (still writing): $file"
                    continue
                fi

                echo "$file" >> "$batch_trigger_file"
                batch_count=$((batch_count + 1))

                if [ $batch_count -ge $BATCH_SIZE ]; then
                    trigger_batch_upload "$batch_trigger_file"
                    > "$batch_trigger_file"
                    batch_count=0
                    sleep 2
                fi
            fi
        done < "$discovery_list"

        [ $batch_count -gt 0 ] && trigger_batch_upload "$batch_trigger_file"
        rm -f "$batch_trigger_file"
    fi
    rm -f "$discovery_list"

    sleep $SLEEP_INTERVAL
done
