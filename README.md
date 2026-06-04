# Peekr

A blazing-fast, SlidePad-style slide-over web browser for macOS, dressed in
**Liquid Glass**. Pin your web apps to a dock that lives off any screen edge or
corner; flick the cursor there (or hit a hotkey) and the panel peeks out —
without stealing focus from whatever you're doing.

Native Swift + AppKit + SwiftUI + `WKWebView`. No Electron, no web runtime — a
menu-bar agent with a tiny footprint (~58 MB idle, 0% CPU, WebViews created
lazily on first peek).

## Design

The navigation layer floats in real macOS 26 **Liquid Glass** (`glassEffect`,
`GlassEffectContainer`) over a full-bleed web "card"; below Tahoe it degrades to
`.ultraThinMaterial`. Both paths go through one `liquidGlass()` modifier. The
signature aqua→blue accent ties to the "peek/water" name.

## Features

- **8-way docking** — dock to any edge **or corner**. Drag the panel by its grip
  and release near any edge/corner to **auto-snap** to the nearest of 8 anchors.
- **Edge peek + hover delay** — hover the docked edge/corner to slide out; the
  dwell delay is configurable.
- **Global hotkey** — re-bindable (default `⌃⌥Space`); record any shortcut.
- **Per-app navigation bar** — glass omnibox with back/forward/reload-stop, a
  load/search address field, progress, and open-in-Safari.
- **Icon dock** — real favicons (auto-fetched + cached) with monogram fallback;
  drag to reorder; right-click to Edit / Reload / Delete; set a **custom icon**.
- **Isolated, persistent sessions** — each app gets its own
  `WKWebsiteDataStore`; web views stay alive across show/hide.
- **Preferences window** — docking grid, panel width, hover delay, edge
  sensitivity, hotkey recorder, auto-hide, follow-cursor, **launch at login**.
- **Multi-display** — follows the cursor's screen, and remembers the last one.
- **Pin & auto-hide** — keep it open, or let it slide away when you leave.
- **Menu-bar agent** — no Dock icon, no main window.

## Build & run

Requires Xcode 26 (real Liquid Glass) — builds and runs below it with the
material fallback. macOS 14+.

```bash
make run     # build the .app bundle and launch it (isolated sessions)
make dev     # swift run — fast iteration, shared session
make app     # just build build/Peekr.app
make clean
```

Quit from the menu-bar item (sidebar icon) → **Quit Peekr**. Open
**Preferences…** (`⌘,`) from the same menu.

State lives in `~/Library/Application Support/Peekr/`
(`apps.json`, `settings.json`, `icons/`).

## Project layout

```
Sources/Peekr/
  App/          main, AppDelegate, AppModel (observable dock state)
  Model/        WebApp, PanelAnchor, Settings, HotKeyConfig
  Store/        AppStore, SettingsStore (JSON persistence)
  Web/          WebViewManager (cached/isolated WebViews + KVO), BrowserState
  Panel/        SlidePanel, PanelController, PanelGeometry, EdgeTrigger
  UI/           PanelRootView, AppRail, NavigationBar, WebContainer, EditAppSheet
  Preferences/  PreferencesWindowController, PreferencesView
  Input/        GlobalHotKey (Carbon)
  StatusBar/    StatusBarController
  Util/         GlassStyle (liquidGlass + theme), IconStore, LaunchAtLogin
```

## Roadmap

- [ ] Keyboard switching (`⌘1`–`⌘9`), `⌘L` focus omnibox, `⌘W` close
- [ ] Per-app unread/notification badges
- [ ] App "hibernation" to free memory for idle apps
- [ ] App icon / DMG packaging & notarization
- [ ] Top/bottom docks with a horizontal rail layout
```
