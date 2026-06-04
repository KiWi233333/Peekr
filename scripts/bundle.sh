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

# Sign so WebKit + per-app data stores work. Prefer a real, stable signing
# identity over ad-hoc: macOS binds Automation/TCC grants (e.g. "allow Peekr to
# read Chrome's open tabs") to the sender's code signature. Ad-hoc's cdhash
# changes on every rebuild, so each `make run` silently revokes those grants and
# tab import breaks. A stable identity (Developer ID / Apple Development) keeps a
# constant designated requirement, so a granted permission sticks across builds.
#
# Override with PEEKR_SIGN_IDENTITY; otherwise auto-pick the first available
# stable identity; fall back to ad-hoc only when none exist.
if [ -n "${PEEKR_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$PEEKR_SIGN_IDENTITY"
else
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' \
    | head -1 | tr -d '"')"
fi

if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1
  echo "Signed $APP with \"$IDENTITY\""
else
  echo "Note: no stable signing identity found — ad-hoc signing. Automation grants" >&2
  echo "      (browser-tab import) reset on each rebuild. Set PEEKR_SIGN_IDENTITY to a" >&2
  echo "      Developer ID / Apple Development identity to make grants stick." >&2
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "Built $APP"
