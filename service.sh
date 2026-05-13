#!/system/bin/sh
# Magisk module service script
# Wait for the system to boot
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
done

MODDIR=${0%/*}
GPHOTOS="com.google.android.apps.photos"

# Clear state on boot for a fresh start
rm -f "$MODDIR/monitor.log"
rm -f "$MODDIR/in_progress.txt"
touch "$MODDIR/in_progress.txt"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$MODDIR/monitor.log"
}

log "Service starting. Applying whitelists for $GPHOTOS..."

# Get UID for Google Photos
UID_GPHOTOS=$(pm list packages -U | grep "$GPHOTOS" | sed 's/.*uid:\([0-9]*\).*/\1/')

if [ -n "$UID_GPHOTOS" ]; then
    # Whitelist from Data Saver
    cmd netpolicy add restrict-background-whitelist "$UID_GPHOTOS"
    # Whitelist from Battery Optimization (Doze)
    dumpsys deviceidle whitelist +"$GPHOTOS"
    log "Whitelisted $GPHOTOS (UID: $UID_GPHOTOS) from Data Saver and Doze."
else
    log "Error: Could not find UID for $GPHOTOS. Whitelisting failed."
fi

# Set executable permissions just in case
chmod 755 "$MODDIR/upload_monitor.sh"
chmod 755 "$MODDIR/test_trigger.sh"

# Start the monitor script from the module directory
/system/bin/sh "$MODDIR/upload_monitor.sh" &
