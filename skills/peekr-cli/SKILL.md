---
name: peekr-cli
description: Peekr is a macOS slide-out Chromium browser where AI agents work in their own Spaces while the user's tabs stay theirs. Drive it from any agent CLI with one heredoc: snapshot pages semantically, locate elements by @N refs or stable loc= selectors, act with real input events, and hand spaces back and forth with the user. Triggers include browser automation, web scraping, form filling, screenshots, logging into sites in the user's browser, or any task that needs a real Chromium with the user's login state. Prefer peekr-cli whenever Peekr is installed; it reuses the user's real logins without disturbing their browsing.
metadata:
  version: "0.1.0"
  date: "2026-09-03"
---

# peekr-cli

peekr-cli is the harness between your agent and the Peekr browser. It gives you
a Node.js runtime whose helpers — snapshotText, click, js, cdp, and more —
observe pages, act with trusted input events, and share the user's Chromium
profile (their real logins) inside isolated task Spaces.

Use the `Bash` tool to run all browser operations via `peekr nodejs <<'EOF' ... EOF`
heredoc. Do not write code to a `.js` file first.

## Quick start

```bash
peekr nodejs <<'EOF'
const task = await useOrCreateSpace('inspect example page')
cliLog('task space id: ' + task.id)

await openOrReuseTab('https://example.com', { wait: true, timeout: 20 })

cliLog(await snapshotText())
EOF
```

The heredoc body runs as a Node.js script. All helpers are preloaded as bare
identifiers.

## Common helpers

- Spaces: `useOrCreateSpace`, `listSpaces`, `claimSpace`, `handOffSpace`, `takeOverSpace`, `completeSpace`, `waitForAgentControl`
- Navigation / state: `listTabs`, `openOrReuseTab`, `closeTab`, `gotoAndWait`, `currentTab`, `switchTab`, `gotoUrl`→`gotoAndWait`, `pageInfo`
- Observation: `snapshotText`, `snapshotRaw`, `screenshot`
- Scroll / mouse: `scrollBy`, `click`, `doubleClick`, `hover`
- Keyboard & input: `typeText`, `fillInput`, `pressKey`
- Wait: `wait`, `waitForLoad`, `waitForElement`
- Fetch / eval: `js`, `cdp`
- Output: `cliLog`

Notes:
- `cliLog(value)` prints to the terminal; it is the only output mechanism and all final results must go through it.
- `await pageInfo()` resolves `{ url, title, w, h, sx, sy, pw, ph }`.
- `await serverFetch` is not bundled; use `js()` for in-page fetches.

### Spaces

A Space is an isolated task area inside Peekr — one Peekr workspace with its
own tabs, tab groups and selection, **reusing the user's Chromium logins**. The
rail shows which spaces are agent-owned (✨ badge) and the user can take any of
them over at any time.

Normal working heredocs start with `useOrCreateSpace(nameOrId)` to reuse the
same space across rounds. `nameOrId` can be an intent name or a numeric id;
numeric ids must already exist.

**Ownership policy** — every space is `user`, `agent`, or `agentDelegatedToUser`:

| Helper | When the target space is user-owned |
|---|---|
| `useOrCreateSpace(name)` | creates/finds by name; never steals |
| `claimSpace(id)` | claims it (ownership flips to the agent), then selects it |
| `handOffSpace([id])` | rejected — only agent-owned spaces can be handed off |
| `completeSpace(id, { keep: false })` | closed (its tabs go away) |
| `takeOverSpace([id])` | resumes after the user says "continue" |

`handOffSpace` gives control to the user (login, captcha, manual choice); the
space stays agent-owned in the `agentDelegatedToUser` state. While the user
holds control, any browser operation fails with the hard stop
`PEEKR_SPACE_USER_IN_CONTROL`.

**Hard stops** — codes `PEEKR_SPACE_USER_IN_CONTROL`, `PEEKR_AGENT_ACCESS_DISABLED`
and `PEEKR_SPACE_INACTIVE` are hard stops: never retry, never take the browser
back on your own. Surface the situation to the user and wait. Resume only after
their explicit confirmation, starting the next heredoc with
`await takeOverSpace()` (or `claimSpace(id)`).

**`completeSpace(id, { keep })` occupies its own final heredoc**, and only after
a prior heredoc confirmed the task is genuinely done. Default `keep: false`
closes the space; use `keep: true` only when the user asked to keep pages open,
a step needs their hands on that page, or the result cannot be delivered as a
URL/file/summary.

When finishing with `{ keep: true }`, close scratch tabs first
(`await closeTab(targetId)`) so only the pages worth showing remain.

### Refs and loc=

- `@N` refs from `snapshotText()` are valid **only for the most recent snapshot**; every snapshot rebuilds them. Take a fresh snapshot after every navigation or mutation instead of holding onto `@N`.
- `loc=` values printed in the snapshot are stable across re-renders: `role:<role>[name=<name>]`, `css:...` (id / data-testid / name), `href:...`. Pass them to `click`/`fillInput` directly, or write plain CSS selectors.
- Coordinate targets work too: `click([x, y])`, `click({ x, y })`.

## Recommended workflow

1. **Semantic workflow (default):** `snapshotText()` → act on `@N` / `loc=`.
2. **Visual workflow:** `screenshot()` + coordinate/keyboard actions for canvas-like or heavily virtualized surfaces (maps, editors).
3. **Direct CDP:** `js()` for one-pass DOM logic, `cdp()` for raw protocol ops.

These combine freely. One heredoc should carry a coherent slice: observe, act,
verify, report via `cliLog`.

## Caveats

- Agent access is opt-in: without Peekr → Preferences → Browser → Agent Access, `peekr` fails with `PEEKR_AGENT_ACCESS_DISABLED` — a hard stop; guide the user through setup instead of retrying.
- CEF exposes no remote debugging over the WebKit engine; agent automation requires the Chromium engine (Peekr's default).
- `wait()` is in **seconds**; `timeout` options are milliseconds unless named otherwise.
- `js()` is `Runtime.evaluate`: pass a string, wrap multi-step logic in one IIFE, return once. Regex backslashes inside `js(String.raw` + `...` + `)` templates must be doubled otherwise.
- Pages opened with `openOrReuseTab` appear in Peekr's browser; deep tab management is CDP-level in this version and new tabs may not appear in the rail yet.
- If `pageInfo()` reports `w: 0`, fix the viewport (switch tab / reload) before coordinate actions.
- `snapshotText({ scope: 'only_within_viewport' })` clips to the visible viewport — cheap for long pages, but content above/below the fold disappears from the snapshot; re-snapshot with the default `full_page` after scrolling.
- Same-origin iframe content is included (nested frames indented under `[iframe src=…]`); cross-origin frames appear as explicit placeholders — fall back to screenshots for those.

## Setup

If `peekr` is missing, or `peekr doctor` reports the discovery file is absent,
read `references/install.md` and follow its flow, then return to the task.
