# Roadmap

This roadmap turns real-world user needs — distilled from reviews and feature
requests across **SlidePad**, **MenubarX**, and **FloatBrowser** — into Peekr's
plan. Each item notes the pain point it answers, so we build what users have
actually been asking the category for.

It is a direction, not a contract: priorities shift, and dates are intentionally
omitted. Want something moved up? Open or 👍 a
[Feature request](https://github.com/KiWi233333/Peekr/issues/new?template=feature_request.yml).

## Legend

| Mark | Meaning |
|------|---------|
| ✅ | Shipped (see [CHANGELOG](CHANGELOG.md)) |
| 🚧 | In progress |
| 📋 | Planned |
| 🔬 | Exploratory — not committed |

## Guiding principle

> Users don't want *more* features — they want **lighter, distinguishable,
> focus-preserving, and trustworthy**. The first three are SlidePad's top pain
> points; the fourth (open-source, native, no Electron) is the gap across the
> whole category. Peekr's bets all sit on that intersection.

---

## Now — `v0.3.0`

Close the highest-frequency pain points that Peekr's architecture is already
positioned to win.

- 📋 **Per-app panel size memory** — remember width/height per web app and
  restore it on activation, instead of one global size.
  *Pain: SlidePad users asked for "dimensions that change as you activate a tab."*
- 📋 **Real hibernation + hotkey** — fully suspend a web app (stop the process,
  not just pause) with a bindable sleep/wake shortcut, and surface which apps are
  awake. *Pain: SlidePad's #1 complaint — high memory and background CPU even
  when "sleeping."*
- 📋 **App identity & badges** — per-app aliases, clearer active-app emphasis,
  and unread/notification badges so near-identical sites are tellable apart.
  *Pain: identical favicons/titles make tabs indistinguishable.*
- 📋 **Onboarding & in-app help** — first-run guide and discoverable bookmark
  management. *Pain: "zero documentation… can't figure out how to save a bookmark."*

## Next — `v0.4.0`

Power-user stickiness the category keeps wishing for but nobody ships well.

- 📋 **Custom CSS / JS injection per URL pattern** — userstyles/userscripts
  scoped by host. *Pain: requested for both SlidePad and MenubarX, unmet by both.*
- 📋 **Content blocking** — built-in ad/cookie-banner blocking via WebKit content
  rules. *Pain: a recurring MenubarX request.*
- 📋 **App quick-switcher** — an Arc-style fuzzy switcher on top of the existing
  `⌘1`–`⌘9`. *Pain: SlidePad users asked for a better quick switcher.*
- 🔬 **Multiple accounts per app** — more than one isolated session for the same
  site, building on the existing per-app `WKWebsiteDataStore`.

## Later — `v0.5.0+`

- 🔬 **Per-app behavior rules** — auto-mute, auto-reload, notification policy,
  default zoom, custom user-agent.
- 🔬 **Workspaces / profiles** — grouped sets of apps you can switch between.
- 🔬 **Sync** — optional iCloud sync of apps and settings across Macs.

## Exploratory / under consideration

Real demand exists, but each is a large bet not yet committed.

- 🔬 **Cross-platform (Windows / ARM tablets)** — frequently requested
  (e.g. Surface Pro X), but Peekr is pure AppKit; this means a substantial
  rewrite, not a port. Tracked as a long-horizon question.
- 🔬 **Reading / focus mode**, **command palette**, **drag-and-drop between apps**.

---

## Shipped

See the [CHANGELOG](CHANGELOG.md) for full history. Highlights:

- ✅ Bookmarks & open-tab import (Chrome / Edge / Brave / Safari)
- ✅ Browser keyboard shortcuts (`⌘1`–`⌘9`, `⌘L`, `⌘R`, `⌘[`/`⌘]`, `⌘W`, `Esc`)
- ✅ 6-way docking with release-to-snap and a resizable panel
- ✅ Non-activating panel that never steals focus
- ✅ Isolated, persistent per-app sessions
- ✅ Liquid Glass with graceful fallback, bilingual UI, launch at login
