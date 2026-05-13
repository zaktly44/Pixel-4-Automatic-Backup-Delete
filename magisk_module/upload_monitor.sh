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
    # Keep log file from growing too large
    if [ $(wc -l < "$LOG_FILE") -gt 1000 ]; then
        sed -i '1,500d' "$LOG_FILE"
    fi
}

notify() {
    /system/bin/cmd notification post -S bigtext -t "GPhotos Backup" "tag_backup" "$1" >/dev/null 2>&1
}

# Initial check
log "--- Monitor Diagnostic Start ---"
log "Module Dir: $MODULE_DIR"
log "SQLite binary: $SQLITE"
log "Photos DB: $PHOTOS_DB (Exists: $([ -f "$PHOTOS_DB" ] && echo "YES" || echo "NO"))"
for dir in $SOURCE_DIRS; do
    log "Monitored Dir: $dir (Exists: $([ -d "$dir" ] && echo "YES" || echo "NO"))"
done

# Ensure state files exist
touch "$IN_PROGRESS_FILE" "$PENDING_DELETE_FILE"

escape_sql() {
    echo "$1" | sed "s/'/''/g"
}

# Force MediaStore scan
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
        log "Warning: Could not find MediaStore ID for $filepath. Forcing scan."
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

    log "Attempting to trigger batch upload for $count files..."

    # Try the most robust intent first
    local out=$(/system/bin/am start -n com.google.android.apps.photos/com.google.android.apps.photos.upload.UploadContentActivity \
             -a android.intent.action.SEND_MULTIPLE \
             --eua android.intent.extra.STREAM "$uris" \
             -t "*/*" \
             --user 0 2>&1)

    log "Intent result: $out"

    if /system/bin/dumpsys display | grep -q "mScreenState=ON"; then
        sleep 2
        /system/bin/input keyevent KEYCODE_HOME
    fi
}

# Main loop
log "Entering main loop."

while true; do
    now=$(date +%s)

    # 1. Delayed cleanup
    if [ -s "$PENDING_DELETE_FILE" ]; then
        tmp_pending=$(mktemp)
        deleted_count=0
        while IFS='|' read -r timestamp file; do
            if [ $((now - timestamp)) -ge $CLEANUP_DELAY ]; then
                log "Deleting backed up file: $file"
                rm -f "$file"
                deleted_count=$((deleted_count + 1))
            else
                echo "$timestamp|$file" >> "$tmp_pending"
            fi
        done < "$PENDING_DELETE_FILE"
        mv "$tmp_pending" "$PENDING_DELETE_FILE"
        [ $deleted_count -gt 0 ] && notify "Cleanup: Deleted $deleted_count files."
    fi

    # 2. Verification
    if [ -s "$IN_PROGRESS_FILE" ]; then
        tmp_check=$(mktemp)
        awk -F'|' '{print $2}' "$IN_PROGRESS_FILE" > "$tmp_check"

        backed_up_files=$(mktemp)
        check_backups_batch "$tmp_check" > "$backed_up_files"

        if [ -s "$backed_up_files" ]; then
            tmp_new_progress=$(mktemp)
            while IFS='|' read -r timestamp file; do
                if grep -qFx "$file" "$backed_up_files" 2>/dev/null; then
                    log "Confirmed backed up in GPhotos: $file"
                    echo "$(date +%s)|$file" >> "$PENDING_DELETE_FILE"
                elif [ $((now - timestamp)) -gt 3600 ]; then
                    log "Retrying timed out file: $file"
                else
                    echo "$timestamp|$file" >> "$tmp_new_progress"
                fi
            done < "$IN_PROGRESS_FILE"
            mv "$tmp_new_progress" "$IN_PROGRESS_FILE"
        fi
        rm -f "$tmp_check" "$backed_up_files"
    fi

    # 3. Discovery
    discovery_list=$(mktemp)
    found_any=0
    for dir in $SOURCE_DIRS; do
        if [ -d "$dir" ]; then
            # Find and count files
            count=$(/system/bin/find "$dir" -maxdepth 1 -type f ! -name ".*" | wc -l)
            if [ "$count" -gt 0 ]; then
                log "Found $count total files in $dir"
                /system/bin/find "$dir" -maxdepth 1 -type f ! -name ".*" >> "$discovery_list"
                found_any=1
            fi
        fi
    done

    if [ "$found_any" -eq 1 ]; then
        batch_trigger_file=$(mktemp)
        batch_count=0

        while IFS= read -r file; do
            if grep -qF "|$file" "$IN_PROGRESS_FILE" "$PENDING_DELETE_FILE" 2>/dev/null; then
                continue
            fi

            # Additional check: skip if file is being written (size stability)
            s1=$(stat -c%s "$file")
            sleep 1
            s2=$(stat -c%s "$file")
            if [ "$s1" != "$s2" ]; then
                log "File still being written: $file"
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
        done < "$discovery_list"

        [ $batch_count -gt 0 ] && trigger_batch_upload "$batch_trigger_file"
        rm -f "$batch_trigger_file"
    fi
    rm -f "$discovery_list"

    sleep $SLEEP_INTERVAL
done
