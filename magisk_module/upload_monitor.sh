#!/system/bin/sh

# Configuration
SOURCE_DIRS="/sdcard/SendAnywhere /sdcard/Download"
PHOTOS_DB="/data/data/com.google.android.apps.photos/databases/gphotos0.db"
MODULE_DIR="/data/adb/modules/gphotos_auto_backup"
LOG_FILE="$MODULE_DIR/monitor.log"
IN_PROGRESS_FILE="$MODULE_DIR/in_progress.txt"
PENDING_DELETE_FILE="$MODULE_DIR/pending_delete.txt"
SLEEP_INTERVAL=15
CLEANUP_DELAY=300
BATCH_SIZE=50

# Use absolute paths for binaries to ensure compatibility with all kernels/ROMs
SQLITE="/system/bin/sqlite3"
[ ! -f "$SQLITE" ] && SQLITE=$(which sqlite3)

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

notify() {
    /system/bin/cmd notification post -S bigtext -t "GPhotos Backup" "tag_backup" "$1" >/dev/null 2>&1
}

# Ensure state files exist
touch "$IN_PROGRESS_FILE" "$PENDING_DELETE_FILE"

# Function to escape single quotes for SQL-like where clauses
escape_sql() {
    echo "$1" | sed "s/'/''/g"
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
    [ -n "$id" ] && echo "content://media/external/file/$id" || echo "file://$filepath"
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

    log "Triggering batch upload for $count files"
    notify "Uploading $count files to Google Photos..."

    /system/bin/am start -n com.google.android.apps.photos/com.google.android.apps.photos.upload.UploadContentActivity \
             -a android.intent.action.SEND_MULTIPLE \
             --eua android.intent.extra.STREAM "$uris" \
             -t "*/*" \
             --user 0 > /dev/null 2>&1

    # Minimize UI to return to home screen
    if /system/bin/dumpsys display | grep -q "mScreenState=ON"; then
        sleep 2
        /system/bin/input keyevent KEYCODE_HOME
    fi
}

# Main loop
log "Monitor started on Kirisakura kernel."

while true; do
    # Safety Check: Prevent the script from running if the system is extremely busy or shutting down
    if [ "$(getprop sys.shutdown.requested)" != "" ]; then
        log "System shutting down. Exiting monitor."
        exit 0
    fi

    # Optimization: If the device is in Power Save mode, double the sleep interval
    current_sleep=$SLEEP_INTERVAL
    if [ "$(settings get global low_power)" = "1" ]; then
        current_sleep=$((SLEEP_INTERVAL * 2))
    fi

    now=$(date +%s)

    # 1. Delayed cleanup
    if [ -s "$PENDING_DELETE_FILE" ]; then
        tmp_pending=$(mktemp)
        deleted_count=0
        while IFS='|' read -r timestamp file; do
            if [ $((now - timestamp)) -ge $CLEANUP_DELAY ]; then
                log "Deleting: $file"
                rm -f "$file"
                deleted_count=$((deleted_count + 1))
            else
                echo "$timestamp|$file" >> "$tmp_pending"
            fi
        done < "$PENDING_DELETE_FILE"
        mv "$tmp_pending" "$PENDING_DELETE_FILE"
        [ $deleted_count -gt 0 ] && notify "Cleanup: Deleted $deleted_count backed-up files."
    fi

    # 2. Check in-progress files (Verification)
    if [ -s "$IN_PROGRESS_FILE" ]; then
        tmp_check=$(mktemp)
        awk -F'|' '{print $2}' "$IN_PROGRESS_FILE" > "$tmp_check"

        backed_up_files=$(mktemp)
        check_backups_batch "$tmp_check" > "$backed_up_files"

        if [ -s "$backed_up_files" ] || grep -q "\|" "$IN_PROGRESS_FILE"; then
            tmp_new_progress=$(mktemp)
            while IFS='|' read -r timestamp file; do
                if grep -qFx "$file" "$backed_up_files" 2>/dev/null; then
                    log "Backup confirmed: $file"
                    echo "$(date +%s)|$file" >> "$PENDING_DELETE_FILE"
                elif [ $((now - timestamp)) -gt 3600 ]; then
                    log "Timeout: $file"
                else
                    echo "$timestamp|$file" >> "$tmp_new_progress"
                fi
            done < "$IN_PROGRESS_FILE"
            mv "$tmp_new_progress" "$IN_PROGRESS_FILE"
        fi
        rm -f "$tmp_check" "$backed_up_files"
    fi

    # 3. Discovery of new files
    discovery_list=$(mktemp)
    for dir in $SOURCE_DIRS; do
        [ -d "$dir" ] && /system/bin/find "$dir" -maxdepth 1 -type f ! -name ".*" >> "$discovery_list"
    done

    if [ -s "$discovery_list" ]; then
        batch_trigger_file=$(mktemp)
        batch_count=0

        while IFS= read -r file; do
            grep -qF "|$file" "$IN_PROGRESS_FILE" "$PENDING_DELETE_FILE" && continue

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

    sleep $current_sleep
done
