# Contributing to Peekr

Thanks for your interest in improving Peekr! This is a small, dependency-free
native macOS app — contributions of all sizes are welcome.

## Getting started

```bash
git clone https://github.com/KiWi233333/Peekr.git
cd Peekr
make build   # quick compile check (swift build)
make run     # build the .app bundle and launch it
```

**Requirements:** macOS 14+, and **Xcode 26** for real Liquid Glass (it builds
and runs below that with the material fallback).

> [!IMPORTANT]
> `make dev` (`swift run`) uses a single **shared** web session and a no-op
> launch-at-login. Only `make run` (the `.app` bundle) exercises **per-app
> isolated, persistent** sessions. Always verify session-isolation or
> launch-at-login changes with `make run`.

## Development workflow

1. **Branch** off `main`: `git checkout -b feat/your-feature`.
2. Make your change. Keep the diff focused.
3. Run `make build` to confirm it compiles (there is no test suite — this is the
   project's "quick verify").
4. For UI / behavior changes, run `make run` and sanity-check by hand.
5. **Commit** using [Conventional Commits](https://www.conventionalcommits.org/)
   (`feat:`, `fix:`, `refactor:`, `docs:`, …). Commit subjects may be in English
   or Chinese, matching the existing history.
6. Open a PR against `main` and fill out the template.

## Code conventions

Peekr follows a strict "one door per concern" rule — **reuse the single entry
point instead of re-implementing**:

| Concern | Single source of truth |
|---|---|
| Orientation / "which side" logic | `PanelAnchor` |
| Panel geometry (frames, regions, snapping) | `PanelGeometry` |
| Glass / material effects | `View.liquidGlass(…)` / `GlassGroup` |
| User-facing copy | `Localized` (add `t(en, zh)` pairs) |
| Omnibox URL-vs-search parsing | `WebViewManager.url(fromOmnibox:)` |

Other guidelines:

- **Comments & docs in English.** Code, identifiers, and commit messages too.
- **Forgiving decode.** When you add a persisted field, add a matching
  `decodeIfPresent(...) ?? fallback` line to the model's hand-rolled
  `init(from:)` so old JSON files still load. See `WebApp` / `SettingsData`.
- **Position ≠ size.** Drag-snapping changes dock position and slide direction
  but must never change the panel's size.
- See [`CLAUDE.md`](CLAUDE.md) for the full architecture tour.

## Reporting bugs / requesting features

Use the [issue templates](https://github.com/KiWi233333/Peekr/issues/new/choose).
Please include your macOS and Xcode versions, and whether you hit the issue with
`make run` or `make dev`.

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE).
