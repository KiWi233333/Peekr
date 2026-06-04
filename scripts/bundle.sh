#!/bin/bash
# Build Peekr and assemble a runnable .app bundle (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Peekr.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Peekr" "$APP/Contents/MacOS/Peekr"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so WebKit + per-app data stores work.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
