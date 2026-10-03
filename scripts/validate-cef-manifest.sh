#!/bin/bash
# Validate Peekr's root CEF manifest without downloading or extracting an
# artifact. `release` additionally requires the external review gate and an
# approved immutable artifact origin.
set -euo pipefail

cd "$(dirname "$0")/.."
MODE="${1:-check}"
case "$MODE" in
  check|release) ;;
  *) echo "usage: $0 [check|release]" >&2; exit 2 ;;
esac

MANIFEST="${PEEKR_CEF_MANIFEST:-$PWD/CEF_VERSION.json}"
test -f "$MANIFEST" || { echo "CEF manifest missing: $MANIFEST" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

MODE="$MODE" python3 - "$MANIFEST" <<'PY'
import hashlib
import json
import os
import re
import sys
from urllib.parse import urlsplit

path = sys.argv[1]
mode = os.environ["MODE"]
with open(path, encoding="utf-8") as stream:
    manifest = json.load(stream)

def fail(message):
    raise SystemExit(f"CEF manifest error: {message}")

if set(manifest.get("platforms", {})) != {"macosarm64"}:
    fail("only platforms.macosarm64 is allowed; x86_64 entries are forbidden")
artifact = manifest["platforms"].get("macosarm64", {}).get("minimal")
if not isinstance(artifact, dict):
    fail("platforms.macosarm64.minimal is required")
name = artifact.get("name", "")
if "_macosarm64_" not in name or "chrome_codecs_minimal.tar.bz2" not in name:
    fail(f"artifact name is not the Peekr arm64 Chrome-codec flavor: {name}")
if not re.fullmatch(r"[0-9a-fA-F]{40}", artifact.get("sha1", "")):
    fail("minimal.sha1 must be 40 hexadecimal characters")
if not re.fullmatch(r"[0-9a-fA-F]{64}", artifact.get("sha256", "")):
    fail("minimal.sha256 must be 64 hexadecimal characters")
if not isinstance(artifact.get("size"), int) or artifact["size"] <= 0:
    fail("minimal.size must be a positive integer")

build = manifest.get("build")
if not isinstance(build, dict):
    fail("build provenance is required")
if not re.fullmatch(r"[0-9a-fA-F]{40}", build.get("sourceRevision", "")):
    fail("build.sourceRevision must be a 40-character commit")
automate_url = build.get("automateGitURL", "")
if not automate_url.startswith("https://"):
    fail("build.automateGitURL must use HTTPS")
if not re.fullmatch(r"[0-9a-fA-F]{64}", build.get("automateGitSHA256", "")):
    fail("build.automateGitSHA256 must be pinned")
defines = set(build.get("gnDefines", []))
required_defines = {
    "proprietary_codecs=true",
    "ffmpeg_branding=Chrome",
}
if not required_defines.issubset(defines):
    fail("build.gnDefines must retain proprietary Chrome-codec flags")

source = artifact.get("source")
if not isinstance(source, dict) or source.get("immutable") is not True:
    fail("minimal.source.immutable must be true")
source_url = os.environ.get("PEEKR_CEF_ARTIFACT_URL") or source.get("url")
approved_origin = os.environ.get("PEEKR_CEF_APPROVED_ORIGIN") or source.get("origin")
if mode == "release":
    if not source_url or not source_url.startswith("https://"):
        fail("release requires an HTTPS immutable artifact URL")
    origin = "{}://{}".format(urlsplit(source_url).scheme, urlsplit(source_url).netloc)
    if not approved_origin or origin != approved_origin:
        fail(f"artifact origin {origin!r} is not approved")
    review = manifest.get("review", {})
    if review.get("codecLicensing") != "approved":
        fail("review.codecLicensing is not approved")
    if review.get("apiCompatibility") != "approved":
        fail("review.apiCompatibility is not approved")
    if review.get("attestation") != "approved":
        fail("review.attestation is not approved")

digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
print(json.dumps({"manifest": os.path.relpath(path), "sha256": digest, "mode": mode}))
PY
