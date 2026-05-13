#!/system/bin/sh

# Configuration
SOURCE_DIRS="/storage/emulated/0/SendAnywhere /storage/emulated/0/Download"
PHOTOS_DB="/data/data/com.google.android.apps.photos/databases/gphotos0.db"
MODULE_DIR="/data/adb/modules/gphotos_auto_backup"
LOG_FILE="$MODULE_DIR/monitor.log"
IN_PROGRESS_FILE="$MODULE_DIR/in_progress.txt"
PENDING_DELETE_FILE="$MODULE_DIR/pending_delete.txt"
SLEEP_INTERVAL=30 # Increased to 30s to reduce background load
CLEANUP_DELAY=300
MAX_TRIGGERS_PER_CYCLE=5 # Throttling to prevent crashes

# Supported extensions for stability
EXTENSIONS="jpg jpeg png gif mp4 mov m4v"

# Binary paths
SQLITE="/system/bin/sqlite3"
[ ! -f "$SQLITE" ] && SQLITE=$(which sqlite3)

log() {
    local msg="$1"
    [ ! -f "$LOG_FILE" ] && touch "$LOG_FILE"
    echo "$(date '+%H/%d %H:%M') - $msg" >> "$LOG_FILE"
    if [ $(wc -l < "$LOG_FILE") -gt 1000 ]; then
        sed -i '1,500d' "$LOG_FILE"
    fi
}

notify() {
    /system/bin/cmd notification post -S bigtext -t "GPhotos" "tag" "$1" >/dev/null 2>&1
}

# Ensure state files exist
touch "$IN_PROGRESS_FILE" "$PENDING_DELETE_FILE"
chmod 666 "$IN_PROGRESS_FILE" "$PENDING_DELETE_FILE" "$LOG_FILE" 2>/dev/null

escape_sql() {
    echo "$1" | sed "s/'/''/g"
}

scan_file() {
    /system/bin/am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$1" > /dev/null 2>&1
}

# Efficiently check if files are backed up using a bulk query
filter_backed_up() {
    local list_file="$1"
    [ ! -f "$PHOTOS_DB" ] || [ ! -s "$list_file" ] || [ -z "$SQLITE" ] && return

    local results_file=$(mktemp)
    "$SQLITE" "$PHOTOS_DB" "SELECT filepath FROM local_media WHERE state IN (3,4) OR remote_url IS NOT NULL; SELECT local_path FROM local_media WHERE state IN (3,4) OR remote_url IS NOT NULL;" > "$results_file" 2>/dev/null

    # Files in list_file that ARE in results_file are backed up
    grep -Fxf "$results_file" "$list_file"
    rm -f "$results_file"
}

get_content_uri() {
    local filepath="$1"
    local escaped_path=$(escape_sql "$filepath")
    local id=$(/system/bin/content query --uri content://media/external/file --projection _id --where "_data='$escaped_path'" 2>/dev/null | sed -n 's/.*_id=\([0-9]*\).*/\1/p')
    [ -n "$id" ] && echo "content://media/external/file/$id" || echo ""
}

trigger_upload() {
    local filepath="$1"

    # 5-second stability check to ensure Chrome/SendAnywhere finished writing
    local s1=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
    [ "$s1" -eq 0 ] && return 1
    sleep 5
    local s2=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
    [ "$s1" != "$s2" ] && return 1

    scan_file "$filepath"
    sleep 1

    local curi=$(get_content_uri "$filepath")
    [ -z "$curi" ] && return 1

    # Standard Share intent - most compatible and lightweight
    /system/bin/am start -n com.google.android.apps.photos/com.google.android.apps.photos.upload.UploadContentActivity \
             -a android.intent.action.SEND \
             --eu android.intent.extra.STREAM "$curi" \
             --grant-read-uri-permission \
             -t "*/*" \
             --user 0 > /dev/null 2>&1

    echo "$(date +%s)|$filepath" >> "$IN_PROGRESS_FILE"
    return 0
}

# Main loop
log "Monitor Active (Stability Focused)."

while true; do
    now=$(date +%s)

    # 1. Cleanup Confirmed
    if [ -s "$PENDING_DELETE_FILE" ]; then
        tmp_pending=$(mktemp)
        while IFS='|' read -r timestamp file; do
            if [ $((now - timestamp)) -ge $CLEANUP_DELAY ]; then
                [ -f "$file" ] && rm -f "$file"
            else
                echo "$timestamp|$file" >> "$tmp_pending"
            fi
        done < "$PENDING_DELETE_FILE"
        mv "$tmp_pending" "$PENDING_DELETE_FILE"
    fi

    # 2. Verify In-Progress (Bulk)
    if [ -s "$IN_PROGRESS_FILE" ]; then
        tmp_check=$(mktemp)
        awk -F'|' '{print $2}' "$IN_PROGRESS_FILE" > "$tmp_check"
        backed_files_list=$(mktemp)
        filter_backed_up "$tmp_check" > "$backed_files_list"

        tmp_new_progress=$(mktemp)
        while IFS='|' read -r timestamp file; do
            if grep -qFx "$file" "$backed_files_list" 2>/dev/null; then
                echo "$now|$file" >> "$PENDING_DELETE_FILE"
            elif [ $((now - timestamp)) -gt 3600 ]; then
                log "Retry allowed for: $(basename "$file")"
            else
                echo "$timestamp|$file" >> "$tmp_new_progress"
            fi
        done < "$IN_PROGRESS_FILE"
        mv "$tmp_new_progress" "$IN_PROGRESS_FILE"
        rm -f "$tmp_check" "$backed_files_list"
    fi

    # 3. Discovery
    discovery_list=$(mktemp)
    for dir in $SOURCE_DIRS; do
        if [ -d "$dir" ]; then
            # Find media files only
            for ext in $EXTENSIONS; do
                /system/bin/find "$dir" -maxdepth 1 -iname "*.$ext" >> "$discovery_list"
            done
        fi
    done

    if [ -s "$discovery_list" ]; then
        trig_count=0
        while IFS= read -r file; do
            # Skip if already handled
            grep -qF "|$file" "$IN_PROGRESS_FILE" "$PENDING_DELETE_FILE" 2>/dev/null && continue

            if trigger_upload "$file"; then
                log "Triggered: $(basename "$file")"
                trig_count=$((trig_count + 1))
                sleep 2
            fi

            # Throttling
            [ $trig_count -ge $MAX_TRIGGERS_PER_CYCLE ] && break
        done < "$discovery_list"
        [ $trig_count -gt 0 ] && notify "Triggered $trig_count backups."
    fi
    rm -f "$discovery_list"

    sleep $SLEEP_INTERVAL
done
