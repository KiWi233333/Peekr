# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/KiWi233333/Peekr/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/KiWi233333/Peekr/releases/tag/v0.1.0
