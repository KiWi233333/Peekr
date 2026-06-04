<!-- Thanks for contributing to Peekr! -->

## Summary

<!-- What does this PR do, and why? -->

## Related issues

<!-- e.g. Closes #12 -->

## Type of change

- [ ] 🐞 Bug fix (`fix:`)
- [ ] ✨ New feature (`feat:`)
- [ ] ♻️ Refactor (`refactor:`)
- [ ] 📝 Docs (`docs:`)
- [ ] 🔧 Chore / build (`chore:`)

## How was this tested?

- [ ] `make build` passes (compile check)
- [ ] Verified by hand with `make run` (`.app` bundle)
- [ ] N/A

<!-- Describe the manual steps you ran, if any. -->

## Checklist

- [ ] Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
- [ ] Reused existing single entry points (`PanelAnchor`, `PanelGeometry`, `liquidGlass`, `Localized`, `WebViewManager.url(fromOmnibox:)`) rather than re-implementing
- [ ] Added a `decodeIfPresent(...) ?? fallback` line if I added a persisted field
- [ ] New user-facing copy goes through `Localized` (EN + ZH)
- [ ] Updated docs / README if behavior changed

## Screenshots

<!-- For UI changes, before/after screenshots or a short clip. -->
