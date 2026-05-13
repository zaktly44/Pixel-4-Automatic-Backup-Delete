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

# Ensure state files exist
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
    # Check both filepath and local_path
    "$SQLITE" "$PHOTOS_DB" "SELECT filepath FROM local_media WHERE state IN (3,4) OR remote_url IS NOT NULL OR remote_media_key IS NOT NULL UNION SELECT local_path FROM local_media WHERE state IN (3,4) OR remote_url IS NOT NULL OR remote_media_key IS NOT NULL;" > "$results_file" 2>/dev/null

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
        # Try finding by name if path match fails (sometimes MediaStore paths are weird)
        local fname=$(basename "$filepath")
        id=$(/system/bin/content query --uri content://media/external/file --projection _id --where "_display_name='$fname'" 2>/dev/null | sed -n 's/.*_id=\([0-9]*\).*/\1/p' | head -n 1)
        [ -n "$id" ] && echo "content://media/external/file/$id" || echo ""
    fi
}

trigger_single_upload() {
    local filepath="$1"
    local curi=$(get_content_uri "$filepath")

    if [ -z "$curi" ]; then
        log "Warning: No MediaStore ID for $filepath. Forcing scan..."
        scan_file "$filepath"
        sleep 2
        curi=$(get_content_uri "$filepath")
    fi

    # Final fallback if scan didn't work immediately
    [ -z "$curi" ] && curi="file://$filepath"

    log "Triggering upload for: $filepath (URI: $curi)"

    # Try multiple known activity names for compatibility
    local success=0
    for act in "com.google.android.apps.photos/com.google.android.apps.photos.upload.UploadContentActivity" \
               "com.google.android.apps.photos/com.google.android.apps.photos.external.ExternalUploadActivity" \
               "com.google.android.apps.photos/.share.handler.ShareHandlerActivity"; do

        local out=$(/system/bin/am start -n "$act" \
                 -a android.intent.action.SEND \
                 --eu android.intent.extra.STREAM "$curi" \
                 --grant-read-uri-permission \
                 -t "*/*" \
                 --user 0 2>&1)

        if echo "$out" | grep -q "Error"; then
            log "Activity $act failed: $out"
        else
            log "Activity $act triggered successfully."
            success=1
            break
        fi
    done

    if [ "$success" -eq 1 ]; then
        echo "$(date +%s)|$filepath" >> "$IN_PROGRESS_FILE"
        return 0
    else
        log "Error: All upload activities failed for $filepath"
        return 1
    fi
}

# Main loop
log "--- Monitor Start (Individual Uploads for Stability) ---"

while true; do
    now=$(date +%s)

    # 1. Cleanup confirmed files
    if [ -s "$PENDING_DELETE_FILE" ]; then
        tmp_pending=$(mktemp)
        deleted=0
        while IFS='|' read -r timestamp file; do
            if [ $((now - timestamp)) -ge $CLEANUP_DELAY ]; then
                if [ -f "$file" ]; then
                    rm -f "$file"
                    log "Deleted: $file"
                fi
                deleted=$((deleted+1))
            else
                echo "$timestamp|$file" >> "$tmp_pending"
            fi
        done < "$PENDING_DELETE_FILE"
        mv "$tmp_pending" "$PENDING_DELETE_FILE"
        [ $deleted -gt 0 ] && notify "Cleanup: $deleted files removed."
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
                log "Backup confirmed: $file"
                echo "$(date +%s)|$file" >> "$PENDING_DELETE_FILE"
            elif [ $((now - timestamp)) -gt 3600 ]; then
                log "Timeout: $file. Removing from in-progress to allow retry."
            else
                echo "$timestamp|$file" >> "$tmp_new_progress"
            fi
        done < "$IN_PROGRESS_FILE"
        mv "$tmp_new_progress" "$IN_PROGRESS_FILE"
        rm -f "$tmp_check" "$backed_up_files"
    fi

    # 3. Discovery
    discovery_list=$(mktemp)
    for dir in $SOURCE_DIRS; do
        if [ -d "$dir" ]; then
            /system/bin/find "$dir" -maxdepth 1 -type f ! -name ".*" >> "$discovery_list"
        fi
    done

    triggered_count=0
    if [ -s "$discovery_list" ]; then
        while IFS= read -r file; do
            if grep -qF "|$file" "$IN_PROGRESS_FILE" "$PENDING_DELETE_FILE" 2>/dev/null; then
                continue
            fi

            # Discovery log
            log "New file found: $file"

            # Stability check
            s1=$(stat -c%s "$file" 2>/dev/null || echo 0)
            [ "$s1" -eq 0 ] && continue
            sleep 1
            s2=$(stat -c%s "$file" 2>/dev/null || echo 0)
            if [ "$s1" != "$s2" ]; then
                log "Skipping $file (still writing)."
                continue
            fi

            if trigger_single_upload "$file"; then
                triggered_count=$((triggered_count + 1))
                # Small delay between intents to avoid system stress
                sleep 2
            fi

            # Limit triggers per cycle to avoid blocking the loop too long
            [ $triggered_count -ge 10 ] && break
        done < "$discovery_list"
    fi
    rm -f "$discovery_list"

    if [ "$triggered_count" -gt 0 ]; then
        notify "Triggered backup for $triggered_count files."
        if /system/bin/dumpsys display | grep -q "mScreenState=ON"; then
            sleep 1
            /system/bin/input keyevent KEYCODE_HOME
        fi
    fi

    sleep $SLEEP_INTERVAL
done
