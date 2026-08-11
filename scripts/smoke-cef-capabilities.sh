#!/bin/bash
# Exercise core Chromium web-platform, input and download paths in Peekr/CEF.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${1:-build/Peekr.app}"
EXECUTABLE="$APP/Contents/MacOS/Peekr"
FIXTURE_DIR="Tests/Fixtures"

test -x "$EXECUTABLE" || { echo "Peekr executable missing: $EXECUTABLE" >&2; exit 2; }
if [ "$(/usr/bin/plutil -extract PeekrBuildConfiguration raw "$APP/Contents/Info.plist" 2>/dev/null || true)" != "debug" ]; then
  echo "Capability smoke hooks are DEBUG-only; bundle with ./scripts/bundle.sh debug." >&2
  exit 2
fi

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/peekr-cef-capabilities.XXXXXX")"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -R "$SMOKE_ROOT"
}
trap cleanup EXIT

cp "$FIXTURE_DIR/cef-capability-smoke.html" "$SMOKE_ROOT/index.html"
cp "$FIXTURE_DIR/service-worker.js" "$SMOKE_ROOT/service-worker.js"
printf 'Peekr CEF download smoke\n' > "$SMOKE_ROOT/download.txt"
mkdir -p "$SMOKE_ROOT/downloads"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SMOKE_ROOT" \
  >"$SMOKE_ROOT/http.log" 2>&1 &
SERVER_PID="$!"

for _ in 1 2 3 4 5; do
  if curl --silent --fail "http://127.0.0.1:$PORT/index.html" >/dev/null; then break; fi
  sleep 0.2
done
curl --silent --fail "http://127.0.0.1:$PORT/index.html" >/dev/null

PEEKR_SMOKE_DATA_ROOT="$SMOKE_ROOT/data" \
PEEKR_SMOKE_SHOW_PANEL=1 \
PEEKR_SMOKE_URL="http://127.0.0.1:$PORT/index.html" \
PEEKR_SMOKE_QUIT_AFTER=12 \
PEEKR_SMOKE_CLICK=1 \
PEEKR_SMOKE_DOWNLOAD_DIR="$SMOKE_ROOT/downloads" \
  "$EXECUTABLE" >"$SMOKE_ROOT/stdout.log" 2>"$SMOKE_ROOT/stderr.log"

# Relaunch against the same isolated Chromium profile to prove browser storage
# survives a complete application/CEF shutdown rather than only a page reload.
PEEKR_SMOKE_DATA_ROOT="$SMOKE_ROOT/data" \
PEEKR_SMOKE_SHOW_PANEL=1 \
PEEKR_SMOKE_URL="http://127.0.0.1:$PORT/index.html?phase=2" \
PEEKR_SMOKE_QUIT_AFTER=8 \
  "$EXECUTABLE" >>"$SMOKE_ROOT/stdout.log" 2>>"$SMOKE_ROOT/stderr.log"

RESULT_LOG="$SMOKE_ROOT/data/cef-smoke.log"
test -f "$RESULT_LOG" || {
  echo "CEF capability smoke result was not created." >&2
  sed -n '1,200p' "$SMOKE_ROOT/stderr.log" >&2
  exit 1
}
cat "$RESULT_LOG"

required=(
  LOCAL_STORAGE INDEXED_DB CACHE_STORAGE SERVICE_WORKER WEB_ASSEMBLY WEB_WORKER
  WEBGL2 WEBGPU_API WEBRTC GET_USER_MEDIA_API GET_DISPLAY_MEDIA_API FILE_INPUT_API
  FILE_SYSTEM_ACCESS_API NOTIFICATIONS_API USER_AGENT_CHROME_148 NO_ELECTRON_RUNTIME
  NATIVE_MOUSE_CLICK FILE_CHOOSER_NATIVE DOWNLOAD PERSISTENT_STORAGE
)
for capability in "${required[@]}"; do
  grep -q "__PEEKR_CEF_SMOKE__:${capability}:PASS" "$RESULT_LOG" || {
    echo "CEF capability smoke failed: $capability" >&2
    exit 1
  }
done

test "$(cat "$SMOKE_ROOT/downloads/peekr-cef-smoke.txt")" = "Peekr CEF download smoke" || {
  echo "CEF download contents did not match." >&2
  exit 1
}
echo "CEF capability smoke test passed."
