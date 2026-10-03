# Install peekr-cli

Read this when the `peekr` command or its agent Skill is missing. For browser
operations, return to [SKILL.md](../SKILL.md).

Current source bundles the Node.js harness in
`Peekr.app/Contents/Resources/peekr-cli/` when the bundle build can produce
`cli/dist/peekr.js`. The launcher requires **Node.js 22+** on `PATH`.
Check the bundle before trying to register a missing CLI.

## Register the command

In Peekr, open **Preferences → Browser → Agent Access** and click
**Install Command Line Tool**. This creates
`~/.local/bin/peekr` pointing at the bundled launcher. Add
`~/.local/bin` to your shell `PATH` if needed.

You can also run the launcher directly from a source build:

```bash
./build/Peekr.app/Contents/Resources/peekr-cli/peekr install
```

`peekr install` creates a launcher in `~/.local/bin` and installs the
`peekr-cli` Skill for Codex and Claude Code in their user skill directories.
Use `peekr install --help` for target, scope, and PATH options. Its access
check is informational: installation can succeed before Agent Access is on.
The in-app button only registers the command; it does not install either Skill.

The older `scripts/install.sh` in this Skill finds an installed app or source
CLI, links the command, and runs `peekr doctor`. It does not install agent
Skills. Prefer the bundled `peekr install` command when available.

## Enable Agent Access

1. Open **Peekr → Preferences → Browser → Agent Access** and enable it.
2. Quit and reopen Peekr. CEF reads the DevTools port at startup.
3. Run `peekr doctor`. Expect `"ok": true` and a reachable control API on
   current builds.

Peekr writes `~/Library/Application Support/Peekr/agent.json` only while
Agent Access is active. Its local control token is not a security boundary
against other processes running as the same user; the Chromium profile and
logins are shared across Spaces. If `doctor` reports a missing discovery file
or unreachable CDP endpoint, check that the app is running with Agent Access
enabled, then relaunch it.

## Verify

```bash
command -v peekr
peekr doctor
```

If `peekr` is missing from the shell, add `~/.local/bin` to `PATH` or use
the bundle launcher directly. A `control API absent in this Peekr build`
message means that build predates the Spaces bridge.
