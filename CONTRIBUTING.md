# Contributing to Peekr

Thanks for your interest in improving Peekr! The current source branch is a
native macOS app with one bundled CEF/Chromium backend. Contributions of all
sizes are welcome.

## Getting started

```bash
git clone https://github.com/KiWi233333/Peekr.git
cd Peekr
make build   # quick compile check (swift build)
make dev     # build and launch the InjectionIII hot-reload Debug .app
```

**Requirements:** macOS 14+ and Xcode. The release workflow selects Xcode 26
to compile the Liquid Glass path; macOS 14–25 use the material fallback at
runtime.

> [!IMPORTANT]
> Chromium requires CefSwift's framework and helper bundles, so Peekr cannot
> run as a bare `swift run` executable. `make dev` and `make run` both assemble
> a real `.app`; use `make dev` for a debug bundle and `make run` for release.
> `make dev` follows the Chromium log after launching the InjectionIII-ready
> Debug app. Ctrl+C stops the log follower while Peekr keeps running.
> `make inject` repeats the Xcode Debug build and app relaunch without rebuilding CEF.

The bundle build prepares the pinned CEF runtime. Agent CLI packaging also
needs Node.js 22+ and npm; see [CLI installation](skills/peekr-cli/references/install.md).

## Development workflow

1. **Branch** off `main`: `git checkout -b kiwi/your-feature`.
2. Make your change. Keep the diff focused.
3. Run `swift test` and `make build` to verify tests and compilation.
4. For UI / behavior changes, run `make dev` and sanity-check the debug bundle.
   For CLI changes, also run `cd cli && npm run typecheck && npm test`.
5. **Commit** using [Conventional Commits](https://www.conventionalcommits.org/)
   (`feat:`, `fix:`, `refactor:`, `docs:`, …). Commit subjects may be in English
   or Chinese, matching the existing history.
6. Open a PR against `main` and fill out the template.

### External reference naming

- Commit subjects on the mainline or other shared branches must not name external
  reference products, comparison projects, or third-party software used as a
  design reference.
- Normative, planning, and acceptance documents follow the same rule. Describe
  the source as a “reference implementation”, “peer product”, or “external
  automation harness” instead.
- Keep names of runtime and build dependencies only where they are required for
  an executable build, test, packaging, or security instruction.

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

- **Use English for code and identifiers.** Most developer documentation is
  English; the Chinese README and architecture notes are maintained alongside
  it. Commit subjects may be English or Chinese.
- **Forgiving decode.** When you add a persisted field, add a matching
  `decodeIfPresent(...) ?? fallback` line to the model's hand-rolled
  `init(from:)` so old JSON files still load. See `WebApp`,
  `SettingsData`, and `Workspace`.
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
Please include your macOS and Xcode versions, the Peekr version or source
commit, and whether you hit the issue with `make run` or `make dev`.

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE).
