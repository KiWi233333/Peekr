# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.2]

### Added
- Vertical tabs now support named and colored groups, collapsing, drag reordering,
  duplication, reopening, and independent selection in each workspace.
- The default search engine can be switched between Google, Bing, DuckDuckGo,
  and Baidu for new tabs and omnibox searches.
- The Chromium engine now bundles a self-built CEF with H.264/AAC codec support,
  native permission and authentication prompts, and downloads.

### Changed
- Panel and sidebar transitions now follow native motion timing, respect Reduce
  Motion, and avoid redundant sidebar rendering work.
- Favicons are shared and persisted by normalized domain, while omnibox
  suggestions use stable identities and debounced refreshes.
- Chromium keeps its standard user-agent product token for better website
  compatibility.

### Fixed
- Panel edge and corner resizing now keeps the opposite edges fixed and clamps
  cleanly to the visible screen while preserving Liquid Glass rendering.
- Chromium interaction no longer crashes the app: packaging now uses the CEF
  runtime pinned and validated by CefSwift instead of overriding it with CEF 151.
- Cross-site navigation now swaps the rail title and icon to the destination
  site immediately instead of showing the previous site until the new page's
  title and favicon arrive.

## [0.2.1]

### Added
- Native menu-bar controls for showing or hiding Peekr, keeping the panel open,
  choosing its auto-hide policy, and opening Chrome cookie or bookmark import.
- Chrome bookmark import can select any discovered Chrome profile and refreshes
  that profile's existing imported folder instead of creating duplicates.

### Changed
- Preferences are reorganized into General, Browser, Apps, and About tabs, with
  confirmation before switching browser engines and targeted setting updates.
- Chromium packaging now keeps only the English, Simplified Chinese, and
  Traditional Chinese locale resources, and selects the matching runtime locale.
- DMG compression has been tuned to reduce the download size.

### Fixed
- The About tab now reads the packaged app version instead of showing a
  hard-coded future version.

## [0.2.0]

### Added
- Selectable WebKit and bundled Chromium backends. Chromium is embedded through
  CefSwift/CEF, keeps a persistent profile, and no longer relies on a first-run
  runtime download or a project-owned native shim.
- Chrome cookie import in Preferences → Apps → Import Browser Data. Users choose
  a Chrome Profile and explicitly confirm before Peekr reads the local database
  and requests Chrome Safe Storage access.
- Per-app aliases — give a web app a custom name (in the edit sheet) so
  near-identical sites are tellable apart; the alias replaces the page title
  everywhere it's shown.
- Unread badges — tabs show the unread count parsed from the page title (e.g.
  "(3) Inbox"), so you can see which apps need attention at a glance.
- Configurable auto-hide timing and a styled drag-to-Applications DMG.

### Changed
- GitHub release builds now support optional Developer ID signing,
  notarization, and stapling. Without signing secrets they deliberately publish
  an ad-hoc-signed, unnotarized app; manual validation runs never publish a
  GitHub Release.

### Fixed
- Quit now closes every Chromium browser before CefSwift shuts down, preventing
  the app and helper processes from remaining alive after confirmation.
- Chrome cookie import preserves Chromium's priority values and restricts its
  temporary database snapshot to the current user.

## [0.1.0]

First public release.

### Added
- Edge-slide web panel docked to any screen edge or corner — reveal on hover or a
  global hotkey, without stealing focus from the front app.
- 6-way docking (two side edges + four corners), full-background drag with
  release-to-snap, a resizable panel defaulting to ⅔ of the screen width, and
  native-style edge/corner resize hot-zones.
- Bookmarks with drag-reorder, bookmark / open-tab import from Chrome / Edge /
  Brave / Safari, omnibox suggestions, and an online icon library.
- Browser keyboard shortcuts (`⌘1`–`⌘9`, `⌘L`, `⌘R`, `⌘[` / `⌘]`, `⌘W`, `Esc`),
  mouse side-button back/forward, and a ⌘Q quit confirmation.
- OAuth / `window.open` popup login, per-app persistent web sessions, and
  launch-at-login.
- Monochrome shadcn-style UI with Liquid Glass, English / 简体中文 bilingual
  interface, and circular icons.

### Fixed
- Panel drag/resize jitter — now tracks the absolute cursor position instead of
  gesture deltas.
- Status-bar icon disappearing on launch — removed an invalid occlusion KVC key
  that aborted startup.

[Unreleased]: https://github.com/KiWi233333/Peekr/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/KiWi233333/Peekr/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/KiWi233333/Peekr/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/KiWi233333/Peekr/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/KiWi233333/Peekr/releases/tag/v0.1.0
