#!/bin/bash
# Build the exact CEF runtime consumed by CefSwift, with the same proprietary
# codec switches used by Chromium's Chrome-branded FFmpeg configuration.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
MANIFEST="${PEEKR_CEF_MANIFEST:-$REPO_ROOT/CEF_VERSION.json}"

test -f "$MANIFEST" || { echo "CEF manifest missing: $MANIFEST" >&2; exit 1; }

manifest_field() {
  python3 - "$MANIFEST" "$1" <<'PY'
import json
import sys

manifest_path, field = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as stream:
    manifest = json.load(stream)
artifact = manifest["platforms"]["macosarm64"]["minimal"]
build = manifest["build"]
values = {
    "cef": manifest["cef"],
    "chromium": manifest["chromium"],
    "sourceRevision": build["sourceRevision"],
    "automateGitURL": build["automateGitURL"],
    "automateGitSHA256": build["automateGitSHA256"],
    "gnDefines": " ".join(build["gnDefines"]),
    "name": artifact["name"],
    "sha1": artifact["sha1"],
    "sha256": artifact["sha256"],
    "size": str(artifact["size"]),
}
print(values[field])
PY
}

"$REPO_ROOT/scripts/validate-cef-manifest.sh" check
CEF_VERSION="$(manifest_field cef)"
CHROMIUM_VERSION="$(manifest_field chromium)"
CEF_BRANCH="$(printf '%s' "$CHROMIUM_VERSION" | cut -d. -f3)"
CEF_COMMIT="$(manifest_field sourceRevision)"
AUTOMATE_URL="$(manifest_field automateGitURL)"
AUTOMATE_SHA256="$(manifest_field automateGitSHA256)"
GN_DEFINES="$(manifest_field gnDefines)"
ARTIFACT_NAME="$(manifest_field name)"
EXPECTED_SHA1="$(manifest_field sha1)"
EXPECTED_SHA256="$(manifest_field sha256)"
EXPECTED_SIZE="$(manifest_field size)"

# Keep the very large Chromium checkout outside tracked source by default. The
# location is configurable so a dedicated volume can be used without changing
# this script. automate-git rejects paths containing spaces.
BUILD_ROOT="${PEEKR_CEF_BUILD_ROOT:-$REPO_ROOT/.cef/source-build}"
case "$BUILD_ROOT" in
  *" "*) echo "PEEKR_CEF_BUILD_ROOT must not contain spaces: $BUILD_ROOT" >&2; exit 2 ;;
esac

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "This pinned build currently supports macOS ARM64 hosts only." >&2
  exit 2
fi

for tool in curl git python3 shasum xcrun; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 2; }
done
xcode-select -p >/dev/null

# Xcode 26 ships the Metal compiler as an on-demand component. A freshly
# downloaded component may also be hidden by xcrun's process cache until it is
# invalidated, so check the actual compiler before starting the multi-hour
# Chromium build.
if ! xcrun metal --version >/dev/null 2>&1; then
  xcrun --kill-cache
fi
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "Missing Xcode Metal Toolchain. Install it, then rerun this script:" >&2
  echo "  xcodebuild -downloadComponent MetalToolchain" >&2
  exit 2
fi

mkdir -p "$BUILD_ROOT"
AVAILABLE_KB="$(df -Pk "$BUILD_ROOT" | awk 'NR == 2 { print $4 }')"
EXISTING_KB="$(du -sk "$BUILD_ROOT" | awk '{ print $1 }')"
TOTAL_BUDGET_KB=$((200 * 1024 * 1024))
MINIMUM_FREE_KB=$((60 * 1024 * 1024))
if [ -z "$AVAILABLE_KB" ] \
  || [ $((AVAILABLE_KB + EXISTING_KB)) -lt "$TOTAL_BUDGET_KB" ] \
  || [ "$AVAILABLE_KB" -lt "$MINIMUM_FREE_KB" ]; then
  echo "CEF needs a 200 GiB free+existing build budget and at least 60 GiB currently free at $BUILD_ROOT." >&2
  echo "Available: $(( ${AVAILABLE_KB:-0} / 1024 / 1024 )) GiB" >&2
  echo "Existing build data: $(( ${EXISTING_KB:-0} / 1024 / 1024 )) GiB" >&2
  exit 1
fi

AUTOMATE="$BUILD_ROOT/automate-git.py"
AUTOMATE_TMP="$BUILD_ROOT/.automate-git.py.$$"
trap 'rm -f "$AUTOMATE_TMP"' EXIT
curl --fail --location --retry 3 --output "$AUTOMATE_TMP" "$AUTOMATE_URL"
ACTUAL_AUTOMATE_SHA256="$(shasum -a 256 "$AUTOMATE_TMP" | awk '{ print $1 }')"
if [ "$ACTUAL_AUTOMATE_SHA256" != "$AUTOMATE_SHA256" ]; then
  echo "automate-git.py checksum mismatch." >&2
  echo "Expected: $AUTOMATE_SHA256" >&2
  echo "Actual:   $ACTUAL_AUTOMATE_SHA256" >&2
  exit 1
fi
mv -f "$AUTOMATE_TMP" "$AUTOMATE"
chmod 755 "$AUTOMATE"

# CEF's own gn_args.py forces is_component_build=false for binary
# distributions. Chrome branding plus proprietary_codecs enables the H.264/AAC
# demux/decode path missing from Spotify's redistributable CEF builds. ThinLTO
# and symbols are disabled to keep the single-machine build within 32 GiB RAM.
export GN_DEFINES
export CEF_ARCHIVE_FORMAT="tar.bz2"
export CEF_ENABLE_ARM64=1
export SDKROOT="$(xcrun --show-sdk-path --sdk macosx)"

echo "[cef-build] CEF $CEF_VERSION"
echo "[cef-build] Root: $BUILD_ROOT"
echo "[cef-build] GN_DEFINES=$GN_DEFINES"

# --force-build is intentionally incremental: autoninja reuses completed work
# after an interruption, while ensuring a partial out/ directory is not mistaken
# for a finished build. No checkout or output directory is deleted here.
python3 "$AUTOMATE" \
  --download-dir="$BUILD_ROOT" \
  --depot-tools-dir="$BUILD_ROOT/depot_tools" \
  --branch="$CEF_BRANCH" \
  --checkout="$CEF_COMMIT" \
  --arm64-build \
  --with-pgo-profiles \
  --no-debug-build \
  --minimal-distrib-only \
  --no-distrib-symbols \
  --no-distrib-docs \
  --no-chromium-history \
  --distrib-subdir-suffix=chrome_codecs \
  --build-log-file \
  --force-build \
  --force-distrib

BUILT_ARTIFACT="$BUILD_ROOT/chromium/src/cef/binary_distrib/$ARTIFACT_NAME"
test -f "$BUILT_ARTIFACT" || {
  echo "CEF build finished without the expected artifact: $BUILT_ARTIFACT" >&2
  exit 1
}

ARTIFACT_DIR="$REPO_ROOT/.cef/artifacts"
mkdir -p "$ARTIFACT_DIR"
cp -f "$BUILT_ARTIFACT" "$ARTIFACT_DIR/$ARTIFACT_NAME"

ARTIFACT_SHA1="$(shasum -a 1 "$ARTIFACT_DIR/$ARTIFACT_NAME" | awk '{ print $1 }')"
ARTIFACT_SHA256="$(shasum -a 256 "$ARTIFACT_DIR/$ARTIFACT_NAME" | awk '{ print $1 }')"
ARTIFACT_SIZE="$(stat -f %z "$ARTIFACT_DIR/$ARTIFACT_NAME")"

if [ "$ARTIFACT_SHA1" != "$EXPECTED_SHA1" ] \
  || [ "$ARTIFACT_SHA256" != "$EXPECTED_SHA256" ] \
  || [ "$ARTIFACT_SIZE" != "$EXPECTED_SIZE" ]; then
  echo "Built artifact does not match the root CEF_VERSION.json pins." >&2
  echo "Expected size=$EXPECTED_SIZE sha1=$EXPECTED_SHA1 sha256=$EXPECTED_SHA256" >&2
  echo "Actual   size=$ARTIFACT_SIZE sha1=$ARTIFACT_SHA1 sha256=$ARTIFACT_SHA256" >&2
  exit 1
fi

echo "[cef-build] Artifact: $ARTIFACT_DIR/$ARTIFACT_NAME"
echo "[cef-build] Size: $ARTIFACT_SIZE"
echo "[cef-build] SHA-1: $ARTIFACT_SHA1"
echo "[cef-build] SHA-256: $ARTIFACT_SHA256"
