# Install peekr-cli

Read this file only when `peekr` isn't installed yet, or when the user asks to
install it. For day-to-day browser work, go back to `SKILL.md`.

peekr-cli ships with the Peekr app. The `peekr` command is a launcher script
around the bundled harness; it needs **Node.js ≥ 22** on PATH.

## What install.sh does

`scripts/install.sh` in this skill directory:

1. Locates the Peekr app (running app bundle → `/Applications` → `~/Applications`).
2. Verifies agent access: reads `~/Library/Application Support/Peekr/agent.json`
   and runs `peekr doctor` against it.
3. Symlinks the bundled CLI to `~/.local/bin/peekr` (creating the directory and
   appending it to `~/.zshrc` PATH only if missing).

Run it:

```bash
sh <skill-dir>/scripts/install.sh
```

## If Agent Access is off

`agent.json` is written only while Agent Access is enabled — a hard stop:

1. Ask the user to open Peekr → Preferences → Browser → Agent Access.
2. Enable "Allow AI agents to drive Chromium pages" (and keep the Chromium engine selected).
3. **Quit and reopen Peekr** (the port is decided at launch).
4. Re-run the install script, then `peekr doctor` and expect `"ok": true`.

Do not retry automation before the user confirms the relaunch happened.

## Verify

```bash
command -v peekr && peekr doctor
```

`ok: true` with a `cdp.pages` list means the environment is ready; return to the
original task and start from `useOrCreateSpace(...)`.

## Troubleshooting

- `command not found` after install: `export PATH="$HOME/.local/bin:$PATH"` and retry.
- `PEEKR_CDP_UNAVAILABLE` in doctor: Peekr is not running or agent.json is stale — reopen Peekr.
- `control API absent in this Peekr build`: the app build predates the spaces bridge; page ops still work, space helpers do not.
