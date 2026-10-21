#!/bin/bash
# Signs LumaBar with a Developer ID certificate (hardened runtime), builds the DMG, notarizes it and staples the ticket.
#
# Credentials come from the environment - nothing is stored in this repo.
#
#   Required:
#     DEVELOPER_ID_APPLICATION   e.g. "Developer ID Application: Your Name (TEAMID)"
#
#   Notarization - either a saved keychain profile (recommended):
#     NOTARY_PROFILE             created once with:
#                                  xcrun notarytool store-credentials "lumabar" \
#                                    --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#   ...or the raw credentials:
#     APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD   (an app-specific password, not your Apple ID password)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your 'Developer ID Application: ...' identity}"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
else
    : "${APPLE_ID:?Set NOTARY_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD}"
    : "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
    : "${APPLE_APP_PASSWORD:?Set APPLE_APP_PASSWORD (app-specific password)}"
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
fi

APP_NAME="LumaBar"
APP="dist/$APP_NAME.app"
DMG="dist/$APP_NAME.dmg"
ENTITLEMENTS="Resources/LumaBar.entitlements"

[ -d "$APP" ] || ./scripts/build.sh

echo "==> Signing (Developer ID, hardened runtime)"
# Sign inside-out rather than with --deep: nested code first, then the app.
shopt -s nullglob
for nested in "$APP"/Contents/Resources/*.bundle "$APP"/Contents/Frameworks/*; do
    codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION" "$nested"
done
shopt -u nullglob
codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_APPLICATION" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Building DMG"
./scripts/make_dmg.sh
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG"

echo "==> Notarizing (this usually takes a few minutes)"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Gatekeeper check"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "Done: $DMG is signed, notarized and stapled."
