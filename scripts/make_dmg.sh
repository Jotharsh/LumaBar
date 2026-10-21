#!/bin/bash
# Packages dist/LumaBar.app into dist/LumaBar.dmg with a shortcut to /Applications.
# Uses create-dmg (brew install create-dmg) for a styled window if it's installed, else plain hdiutil.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="LumaBar"
OUT_DIR="${OUT_DIR:-dist}"
APP="$OUT_DIR/$APP_NAME.app"
DMG="$OUT_DIR/$APP_NAME.dmg"
STAGE="$OUT_DIR/dmg-stage"

[ -d "$APP" ] || { echo "error: $APP not found - run scripts/build.sh first" >&2; exit 1; }

rm -rf "$DMG" "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

if command -v create-dmg >/dev/null 2>&1; then
    echo "==> create-dmg"
    create-dmg \
        --volname "$APP_NAME" \
        --window-size 560 340 \
        --icon-size 112 \
        --icon "$APP_NAME.app" 150 160 \
        --app-drop-link 410 160 \
        --hide-extension "$APP_NAME.app" \
        "$DMG" "$STAGE"
else
    echo "==> hdiutil (install create-dmg for a styled window)"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
fi

rm -rf "$STAGE"
hdiutil verify "$DMG" >/dev/null
echo "Created $DMG"
