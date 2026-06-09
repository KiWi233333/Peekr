#!/bin/bash
# Build a styled Peekr install DMG: brand background, centered app icon and an
# /Applications drop target with a drag arrow between them. Single entry point
# for DMG assembly — the release pipeline calls this instead of a bare
# `hdiutil create`, so local `make dmg` and CI produce an identical window.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Peekr.app}"
OUT="${2:-dist/Peekr.dmg}"
VOLNAME="${3:-Peekr}"
BG="assets/dmg/background.tiff"

[ -d "$APP" ] || { echo "make-dmg: app not found: $APP" >&2; exit 1; }
[ -f "$BG" ]  || { echo "make-dmg: background not found: $BG (run rsvg-convert + tiffutil)" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
RW="$(mktemp -u "${TMPDIR:-/tmp}/peekr-dmg.XXXXXX").dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/peekr-stage.XXXXXX")"
trap 'rm -rf "$STAGE" "$RW"' EXIT

# Stage contents: the app, an Applications symlink, and the hidden background.
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp "$BG" "$STAGE/.background/background.tiff"

APP_NAME="$(basename "$APP")"

# Writable DMG sized to fit, then Finder-styled while mounted.
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" \
  -fs HFS+ -format UDRW -ov "$RW" >/dev/null

MOUNT_DIR="/Volumes/$VOLNAME"
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep '/Volumes/' | head -1 | awk '{print $1}')"

# Give Finder a moment to register the volume before scripting it.
sleep 2

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {300, 140, 900, 540}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set text size of theViewOptions to 12
    set background picture of theViewOptions to file ".background:background.tiff"
    set position of item "$APP_NAME" of container window to {178, 212}
    set position of item "Applications" of container window to {422, 212}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

# Flush Finder's .DS_Store and detach.
sync
hdiutil detach "$DEVICE" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true

# Compress to the final read-only DMG.
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
echo "Built $OUT"
