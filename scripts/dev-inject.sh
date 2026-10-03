#!/bin/bash
# Build Peekr with xcodebuild and relaunch it as a bundled app from DerivedData
# so InjectionIII hot reload works end to end.
#
# InjectionIII compiles injected files using the commands in Xcode's build logs
# and links the resulting dylib against Xcode's build products, so the running
# process must be the Xcode-built binary (a swift-build binary fails dlopen with
# symbol mismatches). Xcode's bare executable cannot run either: CEF's
# PreSandboxStartup hard-checks the .app bundle layout. This script satisfies
# both sides by installing the Xcode-built binary into a standard .app layout
# with CEF frameworks/helpers symlinked from build/Peekr.app.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d build/Peekr.app ]; then
    echo "build/Peekr.app missing — run \`make dev\` once first." >&2
    exit 1
fi

DEST='platform=macOS'

# EMIT_FRONTEND_COMMAND_LINES: Xcode 16.3+ omits Swift compile command lines
# from the build logs by default, and InjectionIII cannot locate the compile
# command for a changed file without them.
xcodebuild -scheme Peekr -configuration Debug -destination "$DEST" build EMIT_FRONTEND_COMMAND_LINES=YES

BUILD_DIR=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Peekr-*/Build/Products/Debug 2>/dev/null | head -1)
if [ -z "$BUILD_DIR" ]; then
    echo "Xcode did not produce a Peekr Debug product in DerivedData." >&2
    exit 1
fi

APP="$BUILD_DIR/Peekr.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp build/Peekr.app/Contents/Info.plist "$APP/Contents/Info.plist"
pkill -f "Peekr.app/Contents/MacOS/Peekr" 2>/dev/null || true
cp "$BUILD_DIR/Peekr" "$APP/Contents/MacOS/Peekr"
for item in build/Peekr.app/Contents/Frameworks/*; do
    ln -sfn "$PWD/$item" "$APP/Contents/Frameworks/$(basename "$item")"
done

if ! open -Ra InjectionIII >/dev/null 2>&1; then
    echo "InjectionIII.app is required for make dev hot reload." >&2
    echo "Install it from https://github.com/johnno1962/InjectionIII" >&2
    exit 1
fi
open -a InjectionIII "$PWD" >/dev/null 2>&1 || open -a InjectionIII >/dev/null 2>&1
open "$APP"
echo "Injection-ready app launched: $APP"
