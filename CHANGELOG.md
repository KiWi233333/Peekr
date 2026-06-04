# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Bookmarks & open-tab import from Chrome / Edge / Brave / Safari.
- Browser keyboard shortcuts (`⌘1`–`⌘9`, `⌘L`, `⌘R`, `⌘[` / `⌘]`, `⌘W`, `Esc`).

## [0.2.0]

### Added
- 6-way docking (two side edges + four corners), full-background drag with
  release-to-snap, and a resizable panel defaulting to ⅔ of the screen width.
- Monochrome shadcn-style redesign, English / 简体中文 bilingual UI, circular icons.

### Fixed
- Panel drag/resize jitter — now tracks the absolute cursor position instead of
  gesture deltas.
- Status-bar icon disappearing on launch — removed an invalid occlusion KVC key
  that aborted startup.

[Unreleased]: https://github.com/KiWi233333/Peekr/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/KiWi233333/Peekr/releases/tag/v0.2.0
