# Contributing to Peekr

Thanks for your interest in improving Peekr! This is a small native macOS app
with WebKit and bundled Chromium backends — contributions of all sizes are
welcome.

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
> Chromium requires CefSwift's framework and helper bundles, so Peekr cannot
> run as a bare `swift run` executable. `make dev` and `make run` both assemble
> a real `.app`; use `make dev` for a debug bundle and `make run` for release.

## Development workflow

1. **Branch** off `main`: `git checkout -b feat/your-feature`.
2. Make your change. Keep the diff focused.
3. Run `swift test` and `make build` to verify tests and compilation.
4. For UI / behavior changes, run `make dev` and sanity-check the debug bundle.
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

## Release signing

Tag releases always publish a DMG and app zip. With no signing certificate
configured, GitHub Actions deliberately uses an ad-hoc signature and skips
notarization. A manual **Release** workflow run builds and uploads the same
artifacts without creating a GitHub Release. Configure these repository settings
for a Developer ID release:

- Secret `MACOS_CERTIFICATE_P12`: base64-encoded Developer ID Application `.p12`
- Secret `MACOS_CERTIFICATE_PASSWORD`: password for that `.p12`
- Variable `MACOS_SIGN_IDENTITY`: optional exact identity, for example
  `Developer ID Application: lizhi diao (7WM9244FKK)`
- Secrets `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, and `AC_API_KEY_BASE64`: optional
  App Store Connect API key fields; set all three to notarize and staple the app
  and DMG

A configured but invalid certificate, a missing selected identity, or a partial
notarization configuration fails the release instead of silently downgrading it.

## Reporting bugs / requesting features

Use the [issue templates](https://github.com/KiWi233333/Peekr/issues/new/choose).
Please include your macOS and Xcode versions, selected browser engine, and
whether you hit the issue with `make run` or `make dev`.

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE).
