<div align="center">

<img src="assets/icon.png" alt="Peekr" width="128" height="128" />

# Peekr

**A native slide-over Chromium browser for macOS.**

Hover at a screen edge or press a hotkey to bring up your sites without moving
away from the app you're using.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Engine](https://img.shields.io/badge/engine-bundled%20Chromium-5C6BC0)](#build-from-source)
[![Release](https://img.shields.io/github/v/release/KiWi233333/Peekr?include_prereleases&sort=semver)](https://github.com/KiWi233333/Peekr/releases)
[![License](https://img.shields.io/github/license/KiWi233333/Peekr?color=blue)](LICENSE)

English · [简体中文](README.zh-CN.md)

<img src="assets/hero.png" alt="Peekr slide-over browser" width="820" />

</div>

## Current source features

These describe the current source branch. Downloaded releases may have a
different feature set; check the [releases](https://github.com/KiWi233333/Peekr/releases)
and [changelog](CHANGELOG.md) for the version you install.

- **Native panel:** SwiftUI and AppKit, a non-activating slide-over panel, six
  dock positions, resizing, pinning, multi-display support, and a configurable
  global hotkey (default `⌃⌥Space`). macOS 26 uses Liquid Glass; older systems
  use a material fallback.
- **Chromium browsing:** bundled CEF, persistent tabs, an omnibox with selectable
  search engine, navigation shortcuts, find in page, bookmarks, favicons, and
  Chrome cookie and bookmark import. Open tabs can also be imported from
  supported browsers.
- **Spaces and tabs:** named Spaces, colored collapsible tab groups, drag
  ordering, tab aliases, and unread counts parsed from page titles. The Spaces
  overview shows an on-demand preview of the active page; other cards use their
  last usable preview or tab details.
- **Optional Agent Access:** agents can work in task Spaces through Chromium's
  DevTools Protocol and the bundled `peekr-cli`. Spaces track user, agent, and
  delegated ownership, with a user takeover control. Agent Access is off by
  default. Spaces share one Chromium profile, including cookies and logins;
  they are organizational boundaries, not separate accounts or security sandboxes.

Agent automation is still being developed. The CLI supports semantic snapshots,
page actions, and task Space handoff, but does not yet cover the full planned
automation surface, cross-origin frames, downloads, or automatic action retries.
See the [implementation status](docs/agent-browser-progress-2026-09-27-interactions.md).

## Install and use

Peekr requires macOS 14 or later. Get an available DMG from
[GitHub Releases](https://github.com/KiWi233333/Peekr/releases) and drag Peekr
to Applications. For reference, [v0.2.1](https://github.com/KiWi233333/Peekr/releases/download/v0.2.1/Peekr-0.2.1.dmg)
has both Chromium and WebKit, and [v0.1.0](https://github.com/KiWi233333/Peekr/releases/download/v0.1.0/Peekr-0.1.0.dmg)
uses WebKit. The current source branch uses Chromium only.

- Hover the docked edge or press `⌃⌥Space` to show Peekr.
- Use the menu bar icon for Preferences (`⌘,`), panel controls, and Quit.
- In the panel, `⌘L` focuses the address bar, `⌘F` finds in the page, `⌘R`
  reloads, `⌘W` closes a tab, and `⌘1`–`⌘9` switch tabs.
- Settings, Spaces/tabs, bookmarks, icons, and the Chromium profile are stored
  under `~/Library/Application Support/Peekr/`.

### Let an agent use Peekr

On a build containing Agent Access, enable **Preferences → Browser → Agent
Access** and restart Peekr. The app writes
`~/Library/Application Support/Peekr/agent.json` while access is enabled. The
DevTools endpoint is local, but other processes on this Mac can attach to it
while it is enabled. Node.js 22 or newer is required for the CLI.

Use **Install Command Line Tool** in that Preferences section to register
`~/.local/bin/peekr`, or run the bundled launcher directly. To install the
`peekr-cli` skill for Codex and Claude Code as well, run:

```bash
peekr install
peekr doctor
```

For example, after `doctor` reports access is ready:

```bash
peekr nodejs <<'EOF'
const task = await taskSpace('example')
const page = task.page('home')
await page.goto('https://example.com')
cliLog(await page.snapshot())
EOF
```

See the [CLI guide](skills/peekr-cli/SKILL.md) and
[installation details](skills/peekr-cli/references/install.md) for the task
Space API and a first heredoc example.

## Build from source

Use macOS 14+ and Xcode. Xcode 26 is required to compile the full macOS 26
Liquid Glass path. The build prepares a pinned CEF distribution and bundles
Chromium's framework and helper processes into a real `.app`; `swift run` alone
cannot launch it.

```bash
# Run these from a checkout containing the current branch's changes.
make build   # quick Swift compile check
make dev     # build and launch the InjectionIII hot-reload Debug .app
make inject  # rebuild and relaunch the injection-ready Debug .app
make app     # build Release build/Peekr.app
make run     # build/open the Release .app
make dmg     # build a Release DMG at dist/Peekr.dmg
swift test
```

`make dev` builds the CEF Debug bundle, builds the Xcode Debug product, opens
InjectionIII with this repository, and launches the injection-ready app. The
terminal follows Chromium's log; `Ctrl+C` stops log output while Peekr keeps
running. Save an injectable SwiftUI view to reload it through InjectionIII.
`make inject` repeats the Xcode build and app relaunch without rebuilding CEF.
Startup code, package changes, and newly added files still require a restart.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md), the [roadmap](ROADMAP.md), and the
[Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) © KiWi233333
