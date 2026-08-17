<div align="center">

<img src="assets/icon.png" alt="Peekr" width="128" height="128" />

# Peekr

**A native slide-over browser for macOS, powered by WebKit or Chromium.**

Move the pointer to a screen edge—or press a hotkey—and Peekr slides into view
without stealing focus from your current app.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Engines](https://img.shields.io/badge/engines-WebKit%20%2B%20Chromium-5C6BC0)](#install)
[![Release](https://img.shields.io/github/v/release/KiWi233333/Peekr?include_prereleases&sort=semver)](https://github.com/KiWi233333/Peekr/releases)
[![License](https://img.shields.io/github/license/KiWi233333/Peekr?color=blue)](LICENSE)

English · [简体中文](README.zh-CN.md)

<img src="assets/hero.png" alt="Peekr slide-over browser" width="820" />

</div>

## Highlights

- **Native macOS UI** — Swift, AppKit, SwiftUI, and Liquid Glass; no Electron.
- **Fast access** — hover a screen edge or use the global hotkey (`⌃⌥Space`).
- **Flexible layout** — six docking positions, resizing, pinning, and multi-display support.
- **Browser essentials** — omnibox, navigation shortcuts, favicons, bookmarks, and tab import.
- **Two engines** — use WebKit for a lightweight native experience or Chromium for site compatibility and Chrome cookie import.
- **Persistent sessions** — per-app stores in WebKit and a shared persistent profile in Chromium.

## Install

Requires macOS 14 or later.

- **`v0.2.1` · WebKit + Chromium (recommended):** [Download DMG](https://github.com/KiWi233333/Peekr/releases/download/v0.2.1/Peekr-0.2.1.dmg)
- **`v0.1.0` · WebKit only (Safari engine):** [Download DMG](https://github.com/KiWi233333/Peekr/releases/download/v0.1.0/Peekr-0.1.0.dmg)

> `v0.2.1` is the latest release. `v0.1.0` is the last lightweight WebKit-only
> build and does not include later features or fixes.

## Usage

- Hover the docked edge or press `⌃⌥Space` to show Peekr.
- Open Preferences with `⌘,`; use `⌘L`, `⌘R`, `⌘W`, and `⌘1`–`⌘9` for browsing.
- Peekr stores its data in `~/Library/Application Support/Peekr/`.

## Build from source

The released dual-engine build requires macOS 14+ and Xcode 26 for full Liquid
Glass support.

```bash
git clone https://github.com/KiWi233333/Peekr.git
cd Peekr
git checkout v0.2.1
make run
```

Use `git checkout v0.1.0` before `make run` to build the WebKit-only edition.
Chromium source builds bundle the pinned CefSwift/CEF runtime and therefore run
as a complete `.app`, not through `swift run`.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md),
[ROADMAP.md](ROADMAP.md), and the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) © KiWi233333
