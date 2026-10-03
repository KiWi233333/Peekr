#!/bin/bash
# Check the latest stable arm64 CEF metadata without changing the manifest.
set -euo pipefail

cd "$(dirname "$0")/.."
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/peekr-cef-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
curl --fail --location --retry 3 --silent --show-error \
  --output "$TMP/index.json" \
  "https://cef-builds.spotifycdn.com/index.json"

python3 - "CEF_VERSION.json" "$TMP/index.json" <<'PY'
import json
import sys

manifest_path, index_path = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as stream:
    manifest = json.load(stream)
with open(index_path, encoding="utf-8") as stream:
    index = json.load(stream)

def version_key(value):
    return tuple(int(part) for part in value.split("+")[0].split("."))

versions = []
for entry in index.get("macosarm64", {}).get("versions", []):
    files = {item.get("type"): item for item in entry.get("files", [])}
    if entry.get("channel") == "stable" and "minimal" in files:
        versions.append((version_key(entry["cef_version"]), entry, files["minimal"]))
if not versions:
    raise SystemExit("no stable macosarm64 minimal CEF artifact found")

_, latest, artifact = max(versions, key=lambda item: item[0])
current = manifest["cef"]
print(json.dumps({
    "current": current,
    "latestStableArm64": latest["cef_version"],
    "chromium": latest.get("chromium_version"),
    "artifact": artifact.get("name"),
    "updateAvailable": latest["cef_version"] != current,
}, sort_keys=True))
PY
