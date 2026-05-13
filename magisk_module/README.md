# Google Photos Auto Backup (Root)

This Magisk module automatically monitors specific folders and uploads new files to Google Photos.

## Features
- **Monitors**: `/sdcard/SendAnywhere` and `/sdcard/Download` (Blip).
- **Background-like Operation**: Uses intents to trigger Google Photos' internal upload activity and minimizes the app automatically.
- **Smart Deletion**: Only deletes local files after confirming they exist in the Google Photos database (`gphotos0.db`).
- **Batch Support**: Handles up to 500 files or 3GB per session.
- **Progress Notifications**: Shows status in the notification bar.

## Requirements
- **Root**: Required for database access and triggering intents.
- **sqlite3**: (Recommended) For automatic deletion. If not found, the module will still upload files but won't delete them automatically. You can install a `sqlite3` Magisk module if your ROM doesn't have it.

## Configuration
The monitor runs every 15 seconds. Logs can be found at `/data/adb/modules/gphotos_auto_backup/monitor.log`.
