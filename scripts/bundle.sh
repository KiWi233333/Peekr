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

test -d "$APP" || { echo "CefSwift did not create $APP" >&2; exit 1; }
test -d "$FRAMEWORK" || { echo "CEF framework missing from $APP" >&2; exit 1; }

# CefSwift generates the CEF-required skeleton plist. Peekr's checked-in plist
# includes those keys plus LSUIElement, icon and Apple Events usage text.
mkdir -p "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ship CEF's BSD license with the product.
CEF_LICENSE="$(find .build/checkouts -path '*/Sources/CCef/LICENSE.CEF.txt' -print -quit)"
if [ -n "$CEF_LICENSE" ]; then
  cp "$CEF_LICENSE" "$APP/Contents/Resources/CEF-LICENSE.txt"
fi

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
  if [ "${PEEKR_HARDENED:-0}" = "1" ] && [ -n "$IDENTITY" ]; then
    sign_one "$helper" "$HELPER_ENT"
  else
    sign_one "$helper"
  fi
done

if [ "${PEEKR_HARDENED:-0}" = "1" ] && [ -n "$IDENTITY" ]; then
  sign_one "$APP" "$APP_ENT"
else
  sign_one "$APP"
fi

codesign --verify --deep --strict "$APP"
echo "Built $APP${IDENTITY:+ and signed with \"$IDENTITY\"}"
