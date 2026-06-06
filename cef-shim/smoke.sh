#!/bin/bash
# smoke.sh — build the shim, assemble a minimal CEF .app, and launch it to render
# a page through peekr_cef. Run this from YOUR interactive GUI session (a Terminal
# you're logged into) — a window opens and renders the URL; nav callbacks stream
# to the log. (Driving it from a detached/agent shell doesn't get a usable window
# server, which is why this is a script for you to run.)
#
# Usage:
#   CEF_ROOT=/path/to/cef_binary_..._macosarm64_minimal ./cef-shim/smoke.sh [url]
set -euo pipefail
cd "$(dirname "$0")"

CEF_ROOT="${CEF_ROOT:?Set CEF_ROOT to the extracted CEF SDK dir}"
URL="${1:-https://example.com}"
APP=/tmp/PeekrCEF.app
LOG=/tmp/peekr_cef_smoke.log

echo "==> building shim (CEF_ROOT=$CEF_ROOT)"
cmake -B build -DCEF_ROOT="$CEF_ROOT" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES=arm64 -DUSE_SANDBOX=OFF >/dev/null
cmake --build build -j"$(sysctl -n hw.ncpu)" >/dev/null
echo "    built: build/libpeekr_cef.dylib, build/peekr_helper, build/peekr_smoke"

echo "==> assembling $APP"
pkill -9 -f "PeekrCEF" 2>/dev/null || true
sleep 1
rm -rf "$APP" "$LOG" /tmp/peekr-cef-root /tmp/peekr-cef-cache
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp build/peekr_smoke "$APP/Contents/MacOS/PeekrCEF"
cp build/libpeekr_cef.dylib "$APP/Contents/Frameworks/"
cp -R "$CEF_ROOT/Release/Chromium Embedded Framework.framework" "$APP/Contents/Frameworks/"
H="$APP/Contents/Frameworks/Peekr Helper.app"
mkdir -p "$H/Contents/MacOS"
cp build/peekr_helper "$H/Contents/MacOS/Peekr Helper"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PeekrCEF</string>
<key>CFBundleIdentifier</key><string>com.peekr.cef.test</string>
<key>CFBundleName</key><string>PeekrCEF</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
P
cat > "$H/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Peekr Helper</string>
<key>CFBundleIdentifier</key><string>com.peekr.cef.test.helper</string>
<key>CFBundleName</key><string>Peekr Helper</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
P
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/PeekrCEF" 2>/dev/null || true
codesign -f -s - "$APP/Contents/Frameworks/Chromium Embedded Framework.framework" >/dev/null 2>&1
codesign -f -s - "$APP/Contents/Frameworks/libpeekr_cef.dylib" >/dev/null 2>&1
codesign -f -s - "$H" >/dev/null 2>&1
codesign -f -s - "$APP" >/dev/null 2>&1

FW="$APP/Contents/Frameworks"
HX="$FW/Peekr Helper.app/Contents/MacOS/Peekr Helper"
echo "==> launching via open (LaunchServices → proper app/window-server context)"
echo "    a window should open and render: $URL"
echo "    nav callbacks → $LOG"
# Launch via `open`, NOT direct exec: CEF requires a LaunchServices-launched .app
# (and an NSApplication, which the harness sets up). A bare exec / pure-C caller
# trips a CefInitialize CHECK (SIGTRAP).
open "$APP" --args "$FW" "$HX" "/tmp/peekr-cef-cache" "$URL" "$LOG"
sleep 3
echo "==> nav callbacks so far (the window keeps running; re-run 'cat $LOG' to see more):"
cat "$LOG" 2>/dev/null || true
