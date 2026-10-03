# Roadmap

Peekr's direction is guided by recurring requests from users of slide-over
browsers. Priorities may change; dates and version numbers below are deliberately
omitted. Suggest or vote on a [feature request](https://github.com/KiWi233333/Peekr/issues/new?template=feature_request.yml).

## Current source branch

These capabilities are implemented in the current checkout. This section is
**not a release announcement**; use the [changelog](CHANGELOG.md) and
[GitHub Releases](https://github.com/KiWi233333/Peekr/releases) to check a
downloaded version.

- A Chromium-only browser in a non-activating, six-position slide-over panel,
  with resizing, pinning, hotkey access, bookmarks, import, and native macOS UI.
- Named Spaces with independent tabs and selection; colored, collapsible tab
  groups; tab aliases; and unread counts parsed from page titles.
- A Spaces overview with an on-demand image of the active page. Other Spaces
  show a cached preview or tab information; the app does not continuously
  capture every background page.
- Opt-in Agent Access, task Space ownership and handoff, plus a bundled
  `peekr-cli` for semantic snapshots and common page actions. All Spaces use
  the same persistent Chromium profile and login state.

The Agent implementation is partial: full cross-origin frame support, advanced
events, downloads, automatic action retries, and release acceptance remain
open. See the [implementation plan](docs/plan-agent-browser-replica.md) and
[verified progress](docs/agent-browser-progress-2026-09-27-interactions.md).

## Planned

- **Per-app panel size memory:** restore each site's preferred width and height.
- **Real hibernation and hotkey:** suspend inactive web apps and expose their
  awake/asleep state, targeting background memory and CPU use.
- **Onboarding and in-app help:** make first-run setup and bookmark management
  easier to discover.
- **Custom CSS/JS by URL pattern:** user styles and scripts scoped to sites.
- **Content blocking:** request and page policies for ads and cookie banners.
- **Quick switcher:** fuzzy switching beyond the existing number shortcuts.

## Exploring

- Separate account profiles for the same site. Current Spaces share one
  Chromium profile; profile partitioning needs its own design.
- Per-app rules for mute, reload, notifications, zoom, and user agent.
- Optional sync, reading mode, and cross-platform support.

See [README.md](README.md) for current usage and [CONTRIBUTING.md](CONTRIBUTING.md)
for development.
