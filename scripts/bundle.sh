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
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" || true

# --- Optional Chromium (CEF) shim --------------------------------------------
# Build + bundle the SMALL native pieces (libpeekr_cef.dylib + Peekr Helper.app);
# the ~180 MB Chromium framework is downloaded on first use, NOT bundled — so the
# default app stays tiny.
#
# Auto-enabled when the CEF SDK is present, so a normal `make run` includes it
# without remembering flags: CEF_ROOT defaults to ~/cef-sdk/cef_binary_*minimal,
# and PEEKR_CEF defaults to "auto" (on iff the SDK is found). PEEKR_CEF=0 forces
# it off (e.g. CI, which has no SDK → Chromium stays unavailable, app unaffected).
if [ -z "${CEF_ROOT:-}" ]; then
  CEF_ROOT="$(ls -d "$HOME"/cef-sdk/cef_binary_*macosarm64*minimal 2>/dev/null | head -1 || true)"
fi
case "${PEEKR_CEF:-auto}" in
  auto) if [ -n "${CEF_ROOT:-}" ]; then PEEKR_CEF=1; else PEEKR_CEF=0; fi ;;
esac

HELPER_APP=""
if [ "$PEEKR_CEF" = "1" ] && [ -n "${CEF_ROOT:-}" ]; then
  echo "Building CEF shim (CEF_ROOT=$CEF_ROOT)…"
  cmake -S cef-shim -B cef-shim/build -DCEF_ROOT="$CEF_ROOT" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DUSE_SANDBOX=OFF >/dev/null
  cmake --build cef-shim/build -j"$(sysctl -n hw.ncpu)" >/dev/null
  mkdir -p "$APP/Contents/Frameworks"
  cp cef-shim/build/libpeekr_cef.dylib "$APP/Contents/Frameworks/"
  HELPER_APP="$APP/Contents/Frameworks/Peekr Helper.app"
  rm -rf "$HELPER_APP"; mkdir -p "$HELPER_APP/Contents/MacOS"
  cp cef-shim/build/peekr_helper "$HELPER_APP/Contents/MacOS/Peekr Helper"
  cat > "$HELPER_APP/Contents/Info.plist" <<'HPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Peekr Helper</string>
<key>CFBundleIdentifier</key><string>com.peekr.app.helper</string>
<key>CFBundleName</key><string>Peekr Helper</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
HPLIST
  echo "Bundled CEF shim + helper into $APP."
fi

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
  # `|| true`: with `set -o pipefail`, grep matching no identity (e.g. on CI, where
  # none exist) exits non-zero and would abort the script before the ad-hoc fallback
  # below ever runs. An empty IDENTITY is the intended "no identity" signal, not an error.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' \
    | head -1 | tr -d '"' || true)"
fi

# Resolve the base codesign args once. Distribution builds (PEEKR_HARDENED=1, set
# by the release pipeline) add the hardened runtime + a secure timestamp —
# notarization prerequisites. Local `make run` leaves it off, so signing stays
# offline-friendly and fast while still using a stable identity for TCC grants.
if [ -n "$IDENTITY" ]; then
  BASE=(--force --sign "$IDENTITY")
  [ "${PEEKR_HARDENED:-0}" = "1" ] && BASE+=(--options runtime --timestamp)
else
  echo "Note: no stable signing identity found — ad-hoc signing. Automation grants" >&2
  echo "      (browser-tab import) reset on each rebuild. Set PEEKR_SIGN_IDENTITY to a" >&2
  echo "      Developer ID / Apple Development identity to make grants stick." >&2
  BASE=(--force --sign -)
fi

# Entitlements (hardened distribution only): CEF helpers need the JIT relaxations;
# the CEF main app needs disable-library-validation to load the downloaded
# framework (app-cef.entitlements), else the plain WebKit entitlements.
HELPER_ENT=""; APP_ENT=""
if [ "${PEEKR_HARDENED:-0}" = "1" ] && [ -n "$IDENTITY" ]; then
  HELPER_ENT="cef-shim/entitlements/helper.entitlements"
  if [ -n "$HELPER_APP" ]; then APP_ENT="cef-shim/entitlements/app-cef.entitlements"
  else APP_ENT="Resources/Peekr.entitlements"; fi
fi

# Sign one target. Entitlements passed as a path string (empty = none) so no empty
# array is ever expanded (bash 3.2 + `set -u` would choke on that).
sign1() {
  local path="$1" ent="${2:-}"
  local args=("${BASE[@]}")
  [ -n "$ent" ] && args+=(--entitlements "$ent")
  if [ "${PEEKR_HARDENED:-0}" = "1" ]; then codesign "${args[@]}" "$path"
  else codesign "${args[@]}" "$path" >/dev/null 2>&1 || true; fi
}

# Inside-out: the bundled CEF pieces first, the main .app last (so it seals
# Contents/Frameworks). `--deep` is deliberately avoided (it breaks nested sigs).
if [ -n "$HELPER_APP" ]; then
  sign1 "$APP/Contents/Frameworks/libpeekr_cef.dylib" ""
  sign1 "$HELPER_APP" "$HELPER_ENT"
fi
sign1 "$APP" "$APP_ENT"
echo "Signed $APP${IDENTITY:+ with \"$IDENTITY\"}"

echo "Built $APP"
