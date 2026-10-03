---
name: peekr-cli
description: Peekr is a macOS slide-out Chromium browser where AI agents work in their own Spaces while the user's tabs stay theirs. Drive it from any agent CLI with one heredoc: snapshot pages semantically, locate elements by @N refs or stable loc= selectors, act with real input events, and hand spaces back and forth with the user. Triggers include browser automation, web scraping, form filling, screenshots, logging into sites in the user's browser, or any task that needs a real Chromium with the user's login state. Prefer peekr-cli whenever Peekr is installed; it reuses the user's real logins without disturbing their browsing.
metadata:
  version: "0.1.0"
  date: "2026-09-27"
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
const task = await taskSpace('inspect example page')
const page = task.page('p1')
await page.goto('https://example.com', { timeout: 20000 })
cliLog({ spaceId: task.id, snapshot: await page.snapshot() })
EOF
```

The heredoc body runs as a Node.js script. All helpers are preloaded as bare
identifiers.

## Page handles

Use `taskSpace(nameOrId)` and `task.page(label)` for new scripts. The label is
scoped to the space and survives CLI process exit. `goto(url)` creates a new
label; other methods require an existing page. A stale/closed label is never
silently rebound: create a new label after `PEEKR_STALE_PAGE`.

- TaskSpace: `id`, `spaceId`, `name`, `ownership`, `page(label)`, `pages()`, `handOff()`, `finish({keep: ['p1']})`.
- Page: `goto`, `info`, `snapshot`, `snapshotRaw`, `screenshot`, `click`, `dblclick`, `hover`, `fill`, `evaluate`, `cdp`, `reload`, `stop`, `close`, `bringToFront`, `goBack`, `goForward`, `clear`, `check`, `uncheck`, `setChecked`, `selectOption`, `setInputFiles`.
- Waits: `waitForFunction(expressionOrFunction, arg?, {timeout}?)`, `waitForURL(exactURL, {timeout}?)`, `waitForSelector(css, {state, timeout}?)`, `waitForLoadState('load' | 'domcontentloaded', {timeout}?)`.
- Input: `keyboard.press(keyOrChord, {delay}?)`, `keyboard.type(text, {delay}?)`, `keyboard.insertText(text)`, `mouse.click(x,y)`, `mouse.wheel(dx,dy)`.

Page timeout options use milliseconds. CSS wait states are attached, detached,
visible and hidden. `networkidle`, keyboard down/up, clipboard paste, download/file chooser APIs,
full frame/OOPIF routing and browser-automation-style locator objects remain unavailable.
Use `peekr help Page` for signatures.

## Common helpers

- Spaces: `useOrCreateSpace`, `listSpaces`, `claimSpace`, `handOffSpace`, `takeOverSpace`, `completeSpace`, `waitForAgentControl`
- Navigation / state: `listTabs`, `openOrReuseTab`, `closeTab`, `gotoAndWait`, `currentTab`, `switchTab`, `pageInfo`
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
same space across rounds. Prefer `taskSpace(nameOrId)` for Page handles. IDs
are native UUIDs; IDs must already exist, and duplicate names require an ID.

**Ownership policy** — every space is `user`, `agent`, or `agentDelegatedToUser`:

| Helper | When the target space is user-owned |
|---|---|
| `useOrCreateSpace(name)` | creates/finds by name; never steals |
| `claimSpace(id)` | claims it (ownership flips to the agent), then selects it |
| `handOffSpace([id])` | rejected — only agent-owned spaces can be handed off |
| `completeSpace(id, { keep: false })` | rejected; user-owned spaces cannot be closed |
| `takeOverSpace([id])` | resumes after the user says "continue" |

`handOffSpace` gives control to the user (login, captcha, manual choice); the
space enters the `agentDelegatedToUser` state. This ends browser work for the
entire CLI round, including other spaces; only output remains permitted. While the user
holds control, any browser operation fails with the hard stop
`PEEKR_SPACE_USER_IN_CONTROL`.

**Hard stops** — codes `PEEKR_SPACE_USER_IN_CONTROL`, `PEEKR_AGENT_ACCESS_DISABLED`
and `PEEKR_SPACE_INACTIVE` are hard stops: never retry, never take the browser
back on your own. Surface the situation to the user and wait. Resume only after
their explicit confirmation, starting the next heredoc with
`await takeOverSpace(id)` (or `claimSpace(id)`), then `taskSpace(id)`.
`claimTaskSpace(id)` and `takeOverTaskSpace(id)` return Page-capable TaskSpace handles; their older `...Space` counterparts return metadata.

**`completeSpace(id, { keep })` occupies its own final heredoc**, and only after
a prior heredoc confirmed the task is genuinely done. Default `keep: false`
closes managed agent tabs and removes an empty space; unmanaged/user tabs
are always preserved. Use `keep: true` only when the user asked to keep pages open,
a step needs their hands on that page, or the result cannot be delivered as a
URL/file/summary.

Prefer `await task.finish({keep: ['p1']})` to retain selected pages and close
managed scratch pages. Kept pages become user-owned. `finish()` also clears the
space ledger and stored refs. `finish({keep: 'all'})` retains all managed pages. It never adopts user tabs by URL or selection. Each space allows 8 managed pages; `PEEKR_TAB_LIMIT` means close a scratch page before creating another.

### Refs and loc=

- Page snapshots persist their most recent `@N` refs by space, target, browser generation and document identity. Page methods restore them across CLI processes only while that document still matches. Navigation/reload invalidates refs; take a new snapshot after DOM changes. Flat helpers do not restore refs across processes: snapshot first in each round.
- `loc=` values printed in the snapshot are stable across re-renders: `role:<role>[name=<name>]`, `css:...` (id / data-testid / name), `href:...`. Pass them to `click`/`fillInput` directly, or write plain CSS selectors.
- Coordinate targets work too: `click([x, y])`, `click({ x, y })`.

### Reliable interaction

Selectors must resolve to exactly one element. `loc=css:`, `role:…[name=…]`,
`href:`, XPath and open shadow roots are supported. Click/fill scroll into view
and reject hidden, disabled or covered elements. These checks do not provide
automatic retries or animation stability guarantees.

- `await page.check('#agree')` / `uncheck` / `setChecked(target, boolean)` are idempotent for native checkbox/radio inputs.
- `await page.selectOption('#plan', {label: 'Pro'})` accepts a value string, `{value}`, `{label}` or `{index}`, or an array for multiple selects. Missing, ambiguous and disabled options fail before mutation.
- `await page.setInputFiles('#upload', ['/absolute/file.txt'])` sets existing readable files. Hidden inputs work; `[]` clears them. Directory inputs and chooser interception are unavailable.
- `await page.keyboard.press('ControlOrMeta+a')` selects all on the current platform. `Cmd`, `Ctrl`, `Alt`, `Shift` and case-insensitive named keys are accepted. Keyboard `delay` is milliseconds.
- `goBack` / `goForward` handle document and same-document history, returning `null` at a boundary. Creation's internal marker page is not a navigation destination.
- Same-origin iframe refs include a document epoch. Navigation inside a frame invalidates its old refs; snapshot again. Cross-origin frames remain placeholders.

## Recommended workflow

1. **Semantic workflow (default):** `snapshotText()` → act on `@N` / `loc=`.
2. **Visual workflow:** `screenshot()` + coordinate/keyboard actions for canvas-like or heavily virtualized surfaces (maps, editors).
3. **Direct CDP:** `js()` for one-pass DOM logic, `cdp()` for raw protocol ops.

These combine freely. One heredoc should carry a coherent slice: observe, act,
verify, report via `cliLog`.

## Caveats

- A native control bridge is mandatory; there is no CDP-only fallback. One CLI round holds a per-browser process lease. Concurrent rounds fail with `PEEKR_BROWSER_BUSY`; a dead process lease is reclaimed. Helpers run FIFO even when called through `Promise.all`.
- Hard-stop failures stay latched even if the script catches them; stdout flushes only after a successful round. SIGINT exits 130, releases the lease and does not replay uncertain actions.
- Restart changes the browser generation. Old labels report `PEEKR_STALE_PAGE`; they are not attached to restored user tabs.
- Raw `cdp` accepts selected page domains, rejects Browser/Target lifecycle and session routing, and invalidates refs. Scripts remain trusted Node code; the helper policy is not an OS sandbox. Spaces share cookies/profile and are not separate security identities.
- Agent access is opt-in: without Peekr → Preferences → Browser → Agent Access, `peekr` fails with `PEEKR_AGENT_ACCESS_DISABLED` — a hard stop; guide the user through setup instead of retrying.
- Agent automation uses Peekr's Chromium/CEF engine.
- `wait()` is in **seconds**; `timeout` options are milliseconds unless named otherwise.
- `js()` is `Runtime.evaluate`: pass a string, wrap multi-step logic in one IIFE, return once. Regex backslashes inside `js(String.raw` + `...` + `)` templates must be doubled otherwise.
- Pages you open with `openOrReuseTab` are mirrored into the active agent space's rail live — the user sees your tabs, follows your navigation, and closing a tab (either side) removes it in both layers.
- If `pageInfo()` reports `w: 0`, fix the viewport (switch tab / reload) before coordinate actions.
- `snapshotText({ scope: 'only_within_viewport' })` clips to the visible viewport — cheap for long pages, but content above/below the fold disappears from the snapshot; re-snapshot with the default `full_page` after scrolling.
- Same-origin iframe content is included (nested frames indented under `[iframe src=…]`); cross-origin frames appear as explicit placeholders — fall back to screenshots for those.

## Setup

If `peekr` is missing, or `peekr doctor` reports the discovery file is absent,
read `references/install.md` and follow its flow, then return to the task.
