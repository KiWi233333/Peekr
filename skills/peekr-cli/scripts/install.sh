#!/bin/sh
# Registers the peekr CLI bundled with the Peekr app onto PATH and verifies
# the loopback endpoints. Never launches Peekr itself; never touches settings.
set -eu

BIN_DIR="$HOME/.local/bin"
APP_DIRS="/Applications/Peekr.app "$HOME"/Applications/Peekr.app"
PEEKR_SUPPORT="${PEEKR_SMOKE_DATA_ROOT:-$HOME/Library/Application Support/Peekr}"

log() { printf '%s\n' "$*"; }

find_cli() {
  # 1) An already-running/installed app bundle.
  for app in $APP_DIRS; do
    if [ -x "$app/Contents/Resources/peekr-cli/peekr" ]; then
      echo "$app/Contents/Resources/peekr-cli/peekr"
      return 0
    fi
  done
  # 2) A source checkout next to this skill (repo layout: skills/peekr-cli/scripts → repo root).
  here="$(cd "$(dirname "$0")/../../.." && pwd)"
  if [ -x "$here/cli/dist/peekr.js" ]; then
    mkdir -p "$here/cli/dist"
    printf '#!/bin/sh\nexec /usr/bin/env node "%s/cli/dist/peekr.js" "$@"\n' "$here" > "$here/cli/dist/peekr"
    chmod +x "$here/cli/dist/peekr"
    echo "$here/cli/dist/peekr"
    return 0
  fi
  return 1
}

node_major="$(/usr/bin/env node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "${node_major:-0}" -lt 22 ]; then
  log "error: Node.js >= 22 is required on PATH (found: ${node_major:-none})."
  exit 1
fi

cli="$(find_cli)" || { log "error: peekr CLI not found. Install Peekr.app first."; exit 1; }
log "cli: $cli"

mkdir -p "$BIN_DIR"
ln -sf "$cli" "$BIN_DIR/peekr"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) log "note: $BIN_DIR is not on PATH; add it to your shell profile." ;;
esac

if [ ! -f "$PEEKR_SUPPORT/agent.json" ]; then
  log "warning: $PEEKR_SUPPORT/agent.json missing."
  log "Open Peekr → Preferences → Browser → Agent Access, enable it, then relaunch Peekr."
  exit 2
fi

log "verifying with peekr doctor:"
exec "$BIN_DIR/peekr" doctor
