#!/system/bin/sh
# Magisk module service script
# Wait for the system to boot
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 10
done

MODDIR=${0%/*}
GPHOTOS="com.google.android.apps.photos"

# Safe boot cleanup
rm -f "$MODDIR/in_progress.txt"
touch "$MODDIR/in_progress.txt"

# Apply system whitelists for background reliability
UID_GPHOTOS=$(pm list packages -U | grep "$GPHOTOS" | sed 's/.*uid:\([0-9]*\).*/\1/')
if [ -n "$UID_GPHOTOS" ]; then
    # Prevent Data Saver and Doze from blocking Photos
    cmd netpolicy add restrict-background-whitelist "$UID_GPHOTOS" >/dev/null 2>&1
    dumpsys deviceidle whitelist +"$GPHOTOS" >/dev/null 2>&1
fi

# Ensure executable and start monitor
chmod 755 "$MODDIR/upload_monitor.sh"
/system/bin/sh "$MODDIR/upload_monitor.sh" &
