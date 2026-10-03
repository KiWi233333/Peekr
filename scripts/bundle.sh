#!/bin/bash
# Build Peekr through CefSwift's command plugin, assemble the CEF framework and
# five helpers, then apply Peekr's resources and distribution signing policy.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
case "$CONFIG" in
  debug|release) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

APP="build/Peekr.app"
FRAMEWORK="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
HELPER_ENT="Resources/PeekrCEFHelper.entitlements"
APP_ENT="Resources/Peekr.entitlements"

# A project-level CEF_VERSION.json selects Peekr's Chrome-codec build. Stage it
# in CefSwift's cache first because CefSwift's upstream downloader intentionally
# serves only the redistributable codec set.
./scripts/prepare-cef.sh stage

# CefSwift owns the version pin, download/checksum, versioned framework layout,
# helper build and initial inside-out ad-hoc signature. Peekr re-signs below so
# local stable identities and hardened Developer ID releases keep working.
swift package \
  --allow-writing-to-package-directory \
  --allow-network-connections all \
  cef bundle \
  --product Peekr \
  --configuration "$CONFIG" \
  --output build \
  --sign -

# Bind CefSwift's extracted cache entry to the exact custom artifact hash. This
# prevents a same-version official CEF cache from shadowing the codec build.
if [ -f CEF_VERSION.json ]; then
  ./scripts/prepare-cef.sh record
fi

test -d "$APP" || { echo "CefSwift did not create $APP" >&2; exit 1; }
test -d "$FRAMEWORK" || { echo "CEF framework missing from $APP" >&2; exit 1; }

# CefSwift generates the CEF-required skeleton plist. Peekr's checked-in plist
# includes those keys plus LSUIElement, icon and Apple Events usage text.
mkdir -p "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/bin/plutil -replace PeekrBuildConfiguration -string "$CONFIG" "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ship CEF's BSD license with the product.
CEF_LICENSE="Vendor/CefSwift/Sources/CCef/LICENSE.CEF.txt"
if [ -n "$CEF_LICENSE" ]; then
  cp "$CEF_LICENSE" "$APP/Contents/Resources/CEF-LICENSE.txt"
fi

# The binary distribution also carries Chromium/third-party notices. Resolve
# the same manifest/version/platform CefSwift used and ship those exact files;
# this is especially important for the Chrome-branded FFmpeg build.
if [ -f CEF_VERSION.json ]; then
  CEF_MANIFEST="CEF_VERSION.json"
else
  CEF_MANIFEST="Vendor/CefSwift/CEF_VERSION.json"
fi
test -n "$CEF_MANIFEST" || { echo "CEF manifest missing after bundle." >&2; exit 1; }
CEF_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["cef"])' "$CEF_MANIFEST")"
case "$(uname -m)" in
  arm64) CEF_PLATFORM="macosarm64" ;;
  x86_64) CEF_PLATFORM="macosx64" ;;
  *) echo "Unsupported CEF architecture: $(uname -m)" >&2; exit 1 ;;
esac
CEF_DIST=".cef/dist/${CEF_VERSION}_${CEF_PLATFORM}_minimal"
test -f "$CEF_DIST/LICENSE.txt" || { echo "Chromium license missing from $CEF_DIST" >&2; exit 1; }
test -f "$CEF_DIST/CREDITS.html" || { echo "Chromium credits missing from $CEF_DIST" >&2; exit 1; }
cp "$CEF_DIST/LICENSE.txt" "$APP/Contents/Resources/Chromium-LICENSE.txt"
cp "$CEF_DIST/CREDITS.html" "$APP/Contents/Resources/Chromium-CREDITS.html"

# Ship the peekr-cli agent harness: the single-file JS runtime plus a launcher,
# and the skill files install.sh registers with agent CLIs. A build machine
# without npm degrades to "no CLI in bundle" instead of failing the product.
if [ ! -f cli/dist/peekr.js ]; then
  (cd cli && npm run build >/dev/null 2>&1) || true
fi
if [ -f cli/dist/peekr.js ]; then
  CLI_DIR="$APP/Contents/Resources/peekr-cli"
  mkdir -p "$CLI_DIR"
  cp cli/dist/peekr.js "$CLI_DIR/peekr.js"
  cat > "$CLI_DIR/peekr" <<'LAUNCHER'
#!/bin/sh
# Bundled peekr harness launcher; requires Node >= 22 on PATH.
exec /usr/bin/env node "$(dirname "$0")/peekr.js" "$@"
LAUNCHER
  chmod +x "$CLI_DIR/peekr"
  if [ -d skills/peekr-cli ]; then
    mkdir -p "$APP/Contents/Resources/peekr-skills"
    cp -R skills/peekr-cli "$APP/Contents/Resources/peekr-skills/"
  fi
else
  echo "peekr-cli bundle skipped (npm or cli/dist unavailable)" >&2
fi

# Peekr exposes only English and Chinese UI. CEF's redistribution README allows
# shipping only configured locales; prune the other locale packs before the
# framework receives its final signature.
CEF_RESOURCES="$FRAMEWORK/Versions/A/Resources"
test -d "$CEF_RESOURCES" || { echo "CEF resources missing from $FRAMEWORK" >&2; exit 1; }
for required_locale in en.lproj zh_CN.lproj zh_TW.lproj; do
  test -f "$CEF_RESOURCES/$required_locale/locale.pak" \
    || { echo "Required CEF locale missing: $required_locale" >&2; exit 1; }
done
for locale_dir in "$CEF_RESOURCES"/*.lproj; do
  [ -d "$locale_dir" ] || continue
  case "$(basename "$locale_dir")" in
    en.lproj|zh_CN.lproj|zh_TW.lproj) ;;
    *) rm -R "$locale_dir" ;;
  esac
done
echo "[cef] Kept locales: en, zh_CN, zh_TW"

# When the variable is present, its value is authoritative: an empty value or
# "-" explicitly forces ad-hoc signing (CI uses this for the no-secret path).
# When it is absent, prefer Apple Development for local TCC stability, then
# Developer ID, finally ad-hoc.
if [ "${PEEKR_SIGN_IDENTITY+x}" = "x" ]; then
  case "$PEEKR_SIGN_IDENTITY" in
    ""|-) IDENTITY="" ;;
    *) IDENTITY="$PEEKR_SIGN_IDENTITY" ;;
  esac
else
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"(Apple Development|Developer ID Application)[^"]*"' \
    | head -1 | tr -d '"' || true)"
fi

if [ -n "$IDENTITY" ]; then
  BASE=(--force --sign "$IDENTITY")
  if [ "${PEEKR_HARDENED:-0}" = "1" ]; then
    BASE+=(--options runtime)
    [ "${PEEKR_NO_TIMESTAMP:-0}" = "1" ] || BASE+=(--timestamp)
  fi
else
  echo "Note: no stable signing identity found; using an ad-hoc signature." >&2
  BASE=(--force --sign -)
fi

# Chromium's macOS Touch ID WebAuthn backend requires the app identifier
# prefix on its two keychain groups. Keep the checked-in entitlement portable
# and resolve the prefix from the selected signing identity at bundle time.
APP_ENT_RESOLVED=""
if [ -n "$IDENTITY" ]; then
  TEAM_ID="$(printf '%s' "$IDENTITY" | sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\))$/\1/p')"
  if [ -n "$TEAM_ID" ]; then
    APP_ENT_RESOLVED="$(mktemp "${TMPDIR:-/tmp}/peekr-app-entitlements.XXXXXX")"
    cp "$APP_ENT" "$APP_ENT_RESOLVED"
    /usr/bin/plutil -replace keychain-access-groups -xml \
      "<array><string>${TEAM_ID}.org.chromium.Chromium.webauthn</string><string>${TEAM_ID}.org.chromium.Chromium.webauthn-uvk</string></array>" \
      "$APP_ENT_RESOLVED"
  else
    echo "Warning: could not derive a team ID from signing identity; Touch ID WebAuthn will remain unavailable." >&2
  fi
fi

# Only hardened, identity-signed bundles can satisfy Chromium's validation
# category checks. The app reads this before CefInitialize and otherwise passes
# no_sandbox=1 for reliable local/ad-hoc development.
if [ "${PEEKR_HARDENED:-0}" = "1" ] && [ -n "$IDENTITY" ]; then
  /usr/bin/plutil -replace PeekrCEFSandboxEnabled -bool true "$APP/Contents/Info.plist"
else
  /usr/bin/plutil -replace PeekrCEFSandboxEnabled -bool false "$APP/Contents/Info.plist"
fi

sign_one() {
  local path="$1" entitlements="${2:-}"
  local args=("${BASE[@]}")
  [ -n "$entitlements" ] && args+=(--entitlements "$entitlements")

  if [ "${PEEKR_HARDENED:-0}" = "1" ] && [ -n "$IDENTITY" ]; then
    local attempt=0 max_attempts=6 output
    until output="$(codesign "${args[@]}" "$path" 2>&1)"; do
      attempt=$((attempt + 1))
      if [ "$attempt" -ge "$max_attempts" ] || ! printf '%s' "$output" | grep -qi timestamp; then
        echo "$output" >&2
        return 1
      fi
      echo "Timestamp service retry $attempt/$((max_attempts - 1)): $(basename "$path")" >&2
      sleep $((attempt * 3))
    done
  else
    codesign "${args[@]}" "$path"
  fi
}

# Re-sign inside-out. Hardened helper processes receive the V8 JIT
# entitlements; the main app only needs its Apple Events entitlement because
# the bundled CEF framework is re-signed with the same team identity.
while IFS= read -r -d '' library; do
  sign_one "$library"
done < <(find "$FRAMEWORK" -type f -name '*.dylib' -print0)
sign_one "$FRAMEWORK"

for helper in "$APP"/Contents/Frameworks/Peekr\ Helper*.app; do
  [ -d "$helper" ] || continue
  # Media capture happens in Chromium helper processes. Mirror the main app's
  # TCC usage strings before the helpers receive their final signature.
  for usage_key in NSBluetoothAlwaysUsageDescription NSCameraUsageDescription NSMicrophoneUsageDescription NSLocationUsageDescription NSScreenCaptureUsageDescription; do
    usage_value="$(/usr/bin/plutil -extract "$usage_key" raw "$APP/Contents/Info.plist")"
    /usr/bin/plutil -replace "$usage_key" -string "$usage_value" "$helper/Contents/Info.plist"
  done
  if [ "${PEEKR_HARDENED:-0}" = "1" ] && [ -n "$IDENTITY" ]; then
    sign_one "$helper" "$HELPER_ENT"
  else
    sign_one "$helper"
  fi
done

if [ -n "$APP_ENT_RESOLVED" ]; then
  sign_one "$APP" "$APP_ENT_RESOLVED"
else
  sign_one "$APP"
fi

codesign --verify --deep --strict "$APP"
echo "Built $APP${IDENTITY:+ and signed with \"$IDENTITY\"}"
