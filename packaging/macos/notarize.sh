#!/usr/bin/env bash
#
# Submit a signed artifact (.zip of the .app, or the final .dmg) to Apple's
# notary service, wait for the result, and staple the ticket.
#
# Usage: notarize.sh <artifact-to-submit> [artifact-to-staple]
#   - artifact-to-submit : what notarytool uploads (a .zip or a .dmg)
#   - artifact-to-staple : what gets the ticket stapled (defaults to the
#                          submitted file; for a zipped .app pass the .app)
#
# Auth via App Store Connect API key, supplied through the environment:
#   NOTARY_KEY_ID     — the key ID (e.g. ABC123DEF4)
#   NOTARY_ISSUER_ID  — the issuer UUID
#   NOTARY_KEY_PATH   — path to the .p8 private key file
#
set -euo pipefail

SUBMIT="${1:?artifact to submit required}"
STAPLE="${2:-$SUBMIT}"

: "${NOTARY_KEY_ID:?NOTARY_KEY_ID not set}"
: "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID not set}"
: "${NOTARY_KEY_PATH:?NOTARY_KEY_PATH not set}"

echo "==> Submitting $SUBMIT to the notary service (this can take minutes)"
xcrun notarytool submit "$SUBMIT" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait

echo "==> Stapling ticket to $STAPLE"
xcrun stapler staple "$STAPLE"
xcrun stapler validate "$STAPLE"
echo "Notarized + stapled: $STAPLE"
