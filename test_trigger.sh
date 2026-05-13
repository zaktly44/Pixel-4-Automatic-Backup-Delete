#!/system/bin/sh

# Diagnostic script to test the upload mechanism manually
if [ -z "$1" ]; then
    echo "Usage: su -c ./test_trigger.sh /path/to/image.jpg"
    exit 1
fi

FILEPATH="$1"

if [ ! -f "$FILEPATH" ]; then
    echo "Error: File $FILEPATH not found."
    exit 1
fi

echo "--- GPhotos Backup Manual Test ---"
echo "Testing file: $FILEPATH"

# 1. Get Content URI
echo "1. Resolving Content URI..."
# Escape path for content query
ESCAPED_PATH=$(echo "$FILEPATH" | sed "s/'/''/g")
ID=$(content query --uri content://media/external/file --projection _id --where "_data='$ESCAPED_PATH'" 2>/dev/null | sed -n 's/.*_id=\([0-9]*\).*/\1/p')

if [ -n "$ID" ]; then
    CURI="content://media/external/file/$ID"
    echo "   Success: $CURI"
else
    echo "   Warning: Could not find MediaStore ID. Forcing scan..."
    am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$FILEPATH"
    sleep 2
    ID=$(content query --uri content://media/external/file --projection _id --where "_data='$ESCAPED_PATH'" 2>/dev/null | sed -n 's/.*_id=\([0-9]*\).*/\1/p')
    if [ -n "$ID" ]; then
        CURI="content://media/external/file/$ID"
        echo "   Success after scan: $CURI"
    else
        CURI="file://$FILEPATH"
        echo "   Failed to get content URI. Falling back to $CURI (likely to fail on modern Android)"
    fi
fi

# 2. Trigger Upload
echo "2. Triggering Upload Intent..."
# ADDING --grant-read-uri-permission which is mandatory for content:// URIs
RESULT=$(am start -n com.google.android.apps.photos/com.google.android.apps.photos.upload.UploadContentActivity \
         -a android.intent.action.SEND \
         --eu android.intent.extra.STREAM "$CURI" \
         --grant-read-uri-permission \
         -t "*/*" \
         --user 0 2>&1)

echo "   Result: $RESULT"

# 3. Check for errors
if echo "$RESULT" | grep -q "Error"; then
    echo "   Intent failed. Trying fallback activity..."
    # Fallback to general share handler
    RESULT2=$(am start -n com.google.android.apps.photos/com.google.android.apps.photos.share.handler.ShareHandlerActivity \
             -a android.intent.action.SEND \
             --eu android.intent.extra.STREAM "$CURI" \
             --grant-read-uri-permission \
             -t "*/*" \
             --user 0 2>&1)
    echo "   Fallback Result: $RESULT2"
fi

echo "--- Test Complete ---"
echo "Check your phone. If Google Photos opened to an upload screen, the mechanism is working."
echo "If nothing happened, please share the 'Result' output above."
