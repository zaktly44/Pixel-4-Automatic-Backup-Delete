#!/system/bin/sh
# Magisk module service script
# Wait for the system to boot
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
done

MODDIR=${0%/*}

# Clear logs and state on boot for a fresh start during debugging
rm -f "$MODDIR/monitor.log"
rm -f "$MODDIR/in_progress.txt"
touch "$MODDIR/in_progress.txt"

echo "$(date) - Service starting" >> "$MODDIR/monitor.log"

# Start the monitor script from the module directory
/system/bin/sh "$MODDIR/upload_monitor.sh" &
