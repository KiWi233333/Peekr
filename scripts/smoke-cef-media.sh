#!/bin/bash
# Exercise H.264 video + AAC audio in a real debug Peekr/CEF browser process.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${1:-build/Peekr.app}"
EXECUTABLE="$APP/Contents/MacOS/Peekr"
FIXTURE="Tests/Fixtures/cef-media-smoke.html"

test -x "$EXECUTABLE" || { echo "Peekr executable missing: $EXECUTABLE" >&2; exit 2; }
test -f "$FIXTURE" || { echo "Smoke fixture missing: $FIXTURE" >&2; exit 2; }
command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg is required for the codec smoke test." >&2; exit 2; }
if [ "$(/usr/bin/plutil -extract PeekrBuildConfiguration raw "$APP/Contents/Info.plist" 2>/dev/null || true)" != "debug" ]; then
  echo "Codec smoke hooks are DEBUG-only; bundle with ./scripts/bundle.sh debug." >&2
  exit 2
fi

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/peekr-cef-media.XXXXXX")"
trap 'rm -R "$SMOKE_ROOT"' EXIT
cp "$FIXTURE" "$SMOKE_ROOT/index.html"
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i "color=c=blue:s=320x180:r=24" \
  -f lavfi -i "sine=frequency=880:sample_rate=48000" \
  -t 2 \
  -c:v libx264 -profile:v baseline -pix_fmt yuv420p \
  -c:a aac -b:a 96k \
  -movflags +faststart \
  "$SMOKE_ROOT/sample.mp4"

SMOKE_URL="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().as_uri())' "$SMOKE_ROOT/index.html")"
PEEKR_SMOKE_DATA_ROOT="$SMOKE_ROOT/data" \
PEEKR_SMOKE_SHOW_PANEL=1 \
PEEKR_SMOKE_URL="$SMOKE_URL" \
PEEKR_SMOKE_QUIT_AFTER=8 \
  "$EXECUTABLE" >"$SMOKE_ROOT/stdout.log" 2>"$SMOKE_ROOT/stderr.log"

RESULT_LOG="$SMOKE_ROOT/data/codec-smoke.log"
test -f "$RESULT_LOG" || {
  echo "CEF smoke result was not created." >&2
  sed -n '1,160p' "$SMOKE_ROOT/stderr.log" >&2
  exit 1
}

cat "$RESULT_LOG"
if ! grep -Eq "__PEEKR_CODEC_SMOKE__:CAN_PLAY:(maybe|probably)" "$RESULT_LOG"; then
  echo "CEF did not advertise H.264/AAC support." >&2
  exit 1
fi
if ! grep -q "__PEEKR_CODEC_SMOKE__:PLAYING" "$RESULT_LOG"; then
  echo "CEF advertised the codec but did not play the generated MP4." >&2
  exit 1
fi
echo "CEF H.264/AAC smoke test passed."
