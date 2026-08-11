#!/bin/bash
# Prove media permission requests reach Peekr's native Swift prompt. A debug-only
# hook clicks Deny so CI/local verification never grants a sensitive capability.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${1:-build/Peekr.app}"
EXECUTABLE="$APP/Contents/MacOS/Peekr"
test -x "$EXECUTABLE" || { echo "Peekr executable missing: $EXECUTABLE" >&2; exit 2; }
if [ "$(/usr/bin/plutil -extract PeekrBuildConfiguration raw "$APP/Contents/Info.plist" 2>/dev/null || true)" != "debug" ]; then
  echo "Permission smoke hooks are DEBUG-only; bundle with ./scripts/bundle.sh debug." >&2
  exit 2
fi

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/peekr-cef-permissions.XXXXXX")"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -R "$SMOKE_ROOT"
}
trap cleanup EXIT

cp Tests/Fixtures/cef-permission-smoke.html "$SMOKE_ROOT/index.html"
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
PEEKR_SMOKE_QUIT_AFTER=10 \
PEEKR_SMOKE_CLICK=1 \
PEEKR_SMOKE_AUTO_DENY_PERMISSIONS=1 \
  "$EXECUTABLE" >"$SMOKE_ROOT/stdout.log" 2>"$SMOKE_ROOT/stderr.log"

PROMPT_LOG="$SMOKE_ROOT/data/permission-smoke.log"
RESULT_LOG="$SMOKE_ROOT/data/permission-result.log"
test -f "$PROMPT_LOG" || { echo "Native permission prompt was not reached." >&2; exit 1; }
test -f "$RESULT_LOG" || { echo "Permission result was not reported." >&2; exit 1; }
cat "$PROMPT_LOG"
cat "$RESULT_LOG"

test "$(grep -c '^__PEEKR_PERMISSION_PROMPT__:' "$PROMPT_LOG")" -ge 2 || {
  echo "Expected both user-media and display-media native prompts." >&2
  exit 1
}
grep -q 'camera or screen' "$PROMPT_LOG" || { echo "Camera/screen permission was not labeled." >&2; exit 1; }
grep -q 'microphone or shared audio' "$PROMPT_LOG" || { echo "Microphone/audio permission was not labeled." >&2; exit 1; }
grep -q '__PEEKR_PERMISSION_SMOKE__:USER_MEDIA_NATIVE_DENY:PASS' "$RESULT_LOG"
grep -q '__PEEKR_PERMISSION_SMOKE__:DISPLAY_MEDIA_NATIVE_DENY:PASS' "$RESULT_LOG"
echo "CEF native permission smoke test passed."
