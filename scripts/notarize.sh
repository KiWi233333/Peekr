#!/bin/bash
# Notarize and staple a distributable artifact (a .dmg or .app), then verify.
#
# Fully gated: a NO-OP (exit 0) when notary credentials are absent, so local
# builds and CI runs without secrets behave exactly as before. Run AFTER signing
# with the hardened runtime (see scripts/bundle.sh PEEKR_HARDENED=1) — notarytool
# rejects anything not hardened-runtime-signed with a Developer ID.
#
# Credentials, either set:
#   App Store Connect API key (preferred):
#     AC_API_KEY_ID, AC_API_ISSUER_ID, AC_API_KEY_PATH (path to the .p8)
#   Apple ID app-specific password:
#     AC_APPLE_ID, AC_TEAM_ID, AC_APP_PASSWORD
set -euo pipefail

ARTIFACT="${1:?usage: notarize.sh <path-to-.dmg-or-.app>}"

if [ -n "${AC_API_KEY_ID:-}" ] && [ -n "${AC_API_ISSUER_ID:-}" ] && [ -n "${AC_API_KEY_PATH:-}" ]; then
  AUTH=(--key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID")
elif [ -n "${AC_APPLE_ID:-}" ] && [ -n "${AC_TEAM_ID:-}" ] && [ -n "${AC_APP_PASSWORD:-}" ]; then
  AUTH=(--apple-id "$AC_APPLE_ID" --team-id "$AC_TEAM_ID" --password "$AC_APP_PASSWORD")
else
  echo "Note: no notary credentials — skipping notarization of $ARTIFACT (current behavior)." >&2
  exit 0
fi

echo "Submitting $ARTIFACT to the notary service (this can take several minutes)…"
# notarytool can't ingest a bare .app bundle — zip it for submission, then staple
# the .app itself below (notarization is recorded by cdhash, so the ticket matches
# the unzipped bundle). .dmg/.pkg submit directly.
case "$ARTIFACT" in
  *.app)
    SUBMIT_DIR="$(mktemp -d)"
    SUBMIT_ZIP="$SUBMIT_DIR/$(basename "$ARTIFACT").zip"
    ditto -c -k --keepParent "$ARTIFACT" "$SUBMIT_ZIP"
    xcrun notarytool submit "$SUBMIT_ZIP" "${AUTH[@]}" --wait
    rm -rf "$SUBMIT_DIR" ;;
  *)
    xcrun notarytool submit "$ARTIFACT" "${AUTH[@]}" --wait ;;
esac

# Staple the ticket so Gatekeeper validates offline. notarytool accepts a .dmg or
# .zip for submission, but a .zip cannot be stapled — staple the .app/.dmg itself.
case "$ARTIFACT" in
  *.dmg|*.app|*.pkg)
    xcrun stapler staple "$ARTIFACT"
    xcrun stapler validate "$ARTIFACT"
    echo "Stapled $ARTIFACT" ;;
  *)
    echo "Note: $ARTIFACT is not staplable (.zip) — notarized but unstapled; staple the .app before zipping if offline Gatekeeper matters." >&2 ;;
esac
