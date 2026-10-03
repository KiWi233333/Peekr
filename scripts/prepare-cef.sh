#!/bin/bash
# Stage Peekr's custom CEF artifact in the cache expected by CefSwift's plugin.
# The plugin still performs its own SHA-1 validation; this script adds SHA-256,
# source control, and cache provenance for the pinned CefSwift package.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
MODE="${1:-stage}"
MANIFEST="${PEEKR_CEF_MANIFEST:-$ROOT/CEF_VERSION.json}"

case "$MODE" in
  stage|record) ;;
  *) echo "usage: $0 [stage|record]" >&2; exit 2 ;;
esac

# No project-level manifest means the package intentionally uses CefSwift's
# upstream pin and downloader. This keeps source checkouts usable before the
# private-codec artifact is configured.
if [ ! -f "$MANIFEST" ]; then
  echo "[cef] No project CEF_VERSION.json; using CefSwift's pinned artifact."
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLATFORM="macosarm64" ;;
  *) echo "Peekr custom CEF requires Darwin-arm64; refusing $(uname -s)-$(uname -m)." >&2; exit 2 ;;
esac

"$ROOT/scripts/validate-cef-manifest.sh" check

manifest_field() {
  python3 - "$MANIFEST" "$PLATFORM" "$1" <<'PY'
import json
import sys

path, platform, field = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    manifest = json.load(stream)
artifact = manifest["platforms"][platform]["minimal"]
source = artifact.get("source") or {}
values = {
    "cef": manifest["cef"],
    "name": artifact["name"],
    "sha1": artifact["sha1"],
    "sha256": artifact.get("sha256", ""),
    "size": str(artifact["size"]),
    "sourceURL": source.get("url") or "",
    "sourceOrigin": source.get("origin") or "",
}
print(values[field])
PY
}

CEF_VERSION="$(manifest_field cef)"
ARTIFACT_NAME="$(manifest_field name)"
EXPECTED_SHA1="$(manifest_field sha1)"
EXPECTED_SHA256="$(manifest_field sha256)"
EXPECTED_SIZE="$(manifest_field size)"
MANIFEST_SOURCE_URL="$(manifest_field sourceURL)"
MANIFEST_SOURCE_ORIGIN="$(manifest_field sourceOrigin)"

case "$EXPECTED_SHA1:$EXPECTED_SHA256" in
  *[!0-9a-fA-F:]*) echo "Invalid checksum characters in $MANIFEST" >&2; exit 1 ;;
esac
if [ "${#EXPECTED_SHA1}" -ne 40 ] || [ "${#EXPECTED_SHA256}" -ne 64 ]; then
  echo "Custom CEF artifacts require 40-character SHA-1 and 64-character SHA-256 pins." >&2
  exit 1
fi
case "$EXPECTED_SIZE" in
  ''|*[!0-9]*) echo "Invalid artifact size in $MANIFEST" >&2; exit 1 ;;
esac

DOWNLOADS="$ROOT/.cef/downloads"
TARGET="$DOWNLOADS/$ARTIFACT_NAME"
DIST="$ROOT/.cef/dist/${CEF_VERSION}_${PLATFORM}_minimal"
PROVENANCE="$DIST/.peekr-artifact-provenance.json"
mkdir -p "$DOWNLOADS"

checksum() {
  shasum -a "$1" "$2" | awk '{ print $1 }'
}

file_size() {
  if stat -f %z "$1" >/dev/null 2>&1; then
    stat -f %z "$1"
  else
    stat -c %s "$1"
  fi
}

matches_manifest() {
  [ -f "$1" ] \
    && [ "$(file_size "$1")" = "$EXPECTED_SIZE" ] \
    && [ "$(checksum 1 "$1")" = "$EXPECTED_SHA1" ] \
    && [ "$(checksum 256 "$1")" = "$EXPECTED_SHA256" ]
}

if [ "$MODE" = "record" ]; then
  test -f "$DIST/.ok" || { echo "CEF distribution is not prepared: $DIST" >&2; exit 1; }
  matches_manifest "$TARGET" || { echo "Cached custom artifact no longer matches the manifest." >&2; exit 1; }
  SOURCE_URL="${PEEKR_CEF_ARTIFACT_URL:-$MANIFEST_SOURCE_URL}"
  SOURCE_ORIGIN="${PEEKR_CEF_APPROVED_ORIGIN:-$MANIFEST_SOURCE_ORIGIN}"
  cat > "$PROVENANCE" <<EOF
{"artifact":"$ARTIFACT_NAME","cef":"$CEF_VERSION","platform":"$PLATFORM","size":$EXPECTED_SIZE,"sha1":"$EXPECTED_SHA1","sha256":"$EXPECTED_SHA256","sourceURL":"$SOURCE_URL","sourceOrigin":"$SOURCE_ORIGIN"}
EOF
  echo "[cef] Recorded prepared artifact provenance: $EXPECTED_SHA256"
  exit 0
fi

if matches_manifest "$TARGET"; then
  echo "[cef] Using verified custom artifact: $TARGET"
else
  STAGING="$(mktemp "$DOWNLOADS/.${ARTIFACT_NAME}.XXXXXX")"
  trap 'rm -f "$STAGING"' EXIT

  if [ -n "${PEEKR_CEF_ARTIFACT:-}" ]; then
    SOURCE_FILE="$PEEKR_CEF_ARTIFACT"
  elif [ -f "${PEEKR_CEF_ARTIFACT_DIR:-$ROOT/.cef/artifacts}/$ARTIFACT_NAME" ]; then
    SOURCE_FILE="${PEEKR_CEF_ARTIFACT_DIR:-$ROOT/.cef/artifacts}/$ARTIFACT_NAME"
  else
    SOURCE_FILE=""
  fi

  if [ -n "$SOURCE_FILE" ]; then
    test -f "$SOURCE_FILE" || { echo "Custom CEF artifact not found: $SOURCE_FILE" >&2; exit 1; }
    echo "[cef] Staging custom artifact from $SOURCE_FILE"
    cp "$SOURCE_FILE" "$STAGING"
  else
    if [ -n "${PEEKR_CEF_ARTIFACT_URL:-}" ]; then
      SOURCE_URL="$PEEKR_CEF_ARTIFACT_URL"
    elif [ -n "${PEEKR_CEF_BASE_URL:-}" ]; then
      ENCODED_NAME="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$ARTIFACT_NAME")"
      SOURCE_URL="${PEEKR_CEF_BASE_URL%/}/$ENCODED_NAME"
    else
      SOURCE_URL="$MANIFEST_SOURCE_URL"
    fi
    if [ -z "$SOURCE_URL" ]; then
      echo "No source configured for custom CEF artifact $ARTIFACT_NAME." >&2
      echo "Set PEEKR_CEF_ARTIFACT, PEEKR_CEF_ARTIFACT_DIR, PEEKR_CEF_ARTIFACT_URL, or PEEKR_CEF_BASE_URL." >&2
      exit 1
    fi
    case "$SOURCE_URL" in
      https://*) ;;
      *) echo "Custom CEF artifact sources must use HTTPS: $SOURCE_URL" >&2; exit 1 ;;
    esac
    SOURCE_ORIGIN="$(python3 -c 'import sys, urllib.parse; u=urllib.parse.urlsplit(sys.argv[1]); print(f"{u.scheme}://{u.netloc}")' "$SOURCE_URL")"
    APPROVED_ORIGIN="${PEEKR_CEF_APPROVED_ORIGIN:-$MANIFEST_SOURCE_ORIGIN}"
    [ -n "$APPROVED_ORIGIN" ] || {
      echo "Set PEEKR_CEF_APPROVED_ORIGIN for the immutable artifact origin: $SOURCE_ORIGIN" >&2
      exit 1
    }
    [ "$SOURCE_ORIGIN" = "$APPROVED_ORIGIN" ] || {
      echo "Unapproved CEF artifact origin: $SOURCE_ORIGIN (expected $APPROVED_ORIGIN)" >&2
      exit 1
    }
    echo "[cef] Downloading custom artifact from $SOURCE_ORIGIN"
    curl --fail --location --retry 3 --progress-bar --output "$STAGING" "$SOURCE_URL"
  fi

  if ! matches_manifest "$STAGING"; then
    echo "Custom CEF artifact failed size/SHA-1/SHA-256 verification." >&2
    echo "Expected size=$EXPECTED_SIZE sha1=$EXPECTED_SHA1 sha256=$EXPECTED_SHA256" >&2
    echo "Actual   size=$(file_size "$STAGING") sha1=$(checksum 1 "$STAGING") sha256=$(checksum 256 "$STAGING")" >&2
    exit 1
  fi
  mv -f "$STAGING" "$TARGET"
  trap - EXIT
  echo "[cef] Verified and cached custom artifact: $TARGET"
fi

# CefSwift keys extracted distributions by CEF version/platform/flavor, not by
# artifact hash. Invalidate only its completion marker when provenance differs;
# the plugin will atomically rebuild this cache entry from the verified tarball.
if [ -f "$DIST/.ok" ]; then
  RECORDED_SHA256="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])) .get("sha256", ""))' "$PROVENANCE" 2>/dev/null || true)"
  if [ "$RECORDED_SHA256" != "$EXPECTED_SHA256" ]; then
    rm -f "$DIST/.ok" "$PROVENANCE"
    echo "[cef] Invalidated stale extracted CEF cache for the new artifact."
  fi
fi
