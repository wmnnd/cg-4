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
# Auth auto-detects from the environment. Provide EITHER credential set:
#
#   App Store Connect API key (preferred for automation):
#     NOTARY_KEY_PATH   — path to the .p8 private key file
#     NOTARY_KEY_ID     — the key ID
#     NOTARY_ISSUER_ID  — the issuer UUID
#
#   Apple ID + app-specific password (no API-key enrollment needed):
#     NOTARY_APPLE_ID     — the developer account email
#     NOTARY_APP_PASSWORD — an app-specific password (appleid.apple.com)
#     NOTARY_TEAM_ID      — the 10-char Developer Team ID
#
set -euo pipefail

SUBMIT="${1:?artifact to submit required}"
STAPLE="${2:-$SUBMIT}"

# Pick whichever credential set was supplied — API key wins if both are set.
auth=()
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    : "${NOTARY_KEY_ID:?NOTARY_KEY_ID not set (API-key auth)}"
    : "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID not set (API-key auth)}"
    auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    echo "==> Notarizing with App Store Connect API key ($NOTARY_KEY_ID)"
elif [ -n "${NOTARY_APPLE_ID:-}" ]; then
    : "${NOTARY_APP_PASSWORD:?NOTARY_APP_PASSWORD not set (Apple-ID auth)}"
    : "${NOTARY_TEAM_ID:?NOTARY_TEAM_ID not set (Apple-ID auth)}"
    auth=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_APP_PASSWORD" --team-id "$NOTARY_TEAM_ID")
    echo "==> Notarizing with Apple ID + app-specific password ($NOTARY_APPLE_ID)"
else
    echo "error: no notarization credentials in the environment." >&2
    echo "  set NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID (API key), or" >&2
    echo "  NOTARY_APPLE_ID + NOTARY_APP_PASSWORD + NOTARY_TEAM_ID (app-specific password)." >&2
    exit 1
fi

echo "==> Submitting $SUBMIT (this can take minutes)"
xcrun notarytool submit "$SUBMIT" "${auth[@]}" --wait

echo "==> Stapling ticket to $STAPLE"
xcrun stapler staple "$STAPLE"
xcrun stapler validate "$STAPLE"
echo "Notarized + stapled: $STAPLE"
