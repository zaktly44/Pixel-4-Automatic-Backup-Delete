#!/system/bin/sh
# Magisk module service script
# Wait for the system to boot
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
done

MODDIR=${0%/*}
GPHOTOS="com.google.android.apps.photos"

# Clear state on boot
rm -f "$MODDIR/monitor.log"
rm -f "$MODDIR/in_progress.txt"
touch "$MODDIR/in_progress.txt"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$MODDIR/monitor.log"
}

log "Service starting. Applying whitelists..."

# Whitelist Google Photos from Data Saver and Doze
UID_GPHOTOS=$(pm list packages -U | grep "$GPHOTOS" | sed 's/.*uid:\([0-9]*\).*/\1/')
if [ -n "$UID_GPHOTOS" ]; then
    cmd netpolicy add restrict-background-whitelist "$UID_GPHOTOS"
    dumpsys deviceidle whitelist +"$GPHOTOS"
    log "Whitelisted $GPHOTOS."
fi

# Ensure executable permissions
chmod 755 "$MODDIR/upload_monitor.sh"
chmod 755 "$MODDIR/test_trigger.sh"

# Start monitor
/system/bin/sh "$MODDIR/upload_monitor.sh" &
