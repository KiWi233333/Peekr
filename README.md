# Peekr

A blazing-fast, SlidePad-style slide-out web browser for macOS. Pin your web
apps to a dock that lives off the right screen edge; flick the cursor to the
edge (or hit a hotkey) and the panel peeks out — without stealing focus from
whatever you're doing.

Native Swift + AppKit + `WKWebView`. No Electron, no web runtime — a menu-bar
agent with a tiny footprint.

## Features (v0.1)

- **Edge peek** — hover the right screen edge to slide the panel out.
- **Global hotkey** — `⌃⌥Space` toggles the panel from anywhere.
- **Non-activating panel** — appears over your work without taking focus, yet
  you can still type into web apps.
- **Icon dock** — a frosted vertical rail of your web apps; click to switch.
- **Persistent, isolated sessions** — each app gets its own `WKWebsiteDataStore`
  (separate cookies/logins), and web views stay alive across show/hide so
  scroll position and playback are never lost.
- **Pin** — keep the panel open from the menu-bar menu.
- **Auto-hide** — slides away when the cursor leaves (unless pinned).
- **Menu-bar agent** — no Dock icon, no main window.

## Build & run

Requires Xcode 15+ (uses `WKWebsiteDataStore(forIdentifier:)`, macOS 14+).

```bash
make run     # build the .app bundle and launch it (isolated sessions)
make dev     # swift run — fast iteration, shared session
make app     # just build build/Peekr.app
make clean
```

Quit from the menu-bar menu (the sidebar icon) → **Quit Peekr**.

## Default apps

ChatGPT · GitHub · YouTube · Gmail. Use **+** in the rail to add more; the list
is stored at `~/Library/Application Support/Peekr/apps.json`.

## Roadmap toward full SlidePad parity

- [ ] Favicons / custom icons per app (currently coloured monograms)
- [ ] Reorder & remove apps (drag in rail, right-click menu)
- [ ] Configurable trigger edge (left/right), panel width, hotkey
- [ ] Multi-display: remember which screen to peek on
- [ ] Per-app navigation chrome (back/forward/reload/address)
- [ ] Preferences window
- [ ] "Pull" gesture / trigger zone tuning, hover delay
- [ ] Launch at login
- [ ] App groups / spaces

## Project layout

```
Sources/Peekr/
  App/          main, AppDelegate, AppModel (observable state)
  Model/        WebApp
  Store/        AppStore (JSON persistence)
  Panel/        SlidePanel, PanelController, EdgeTrigger, PanelContentView
  Web/          WebViewManager (cached, isolated WKWebViews)
  UI/           SidebarRail (SwiftUI icon dock)
  Input/        GlobalHotKey (Carbon)
  StatusBar/    StatusBarController
```
