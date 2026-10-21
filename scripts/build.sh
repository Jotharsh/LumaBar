#!/bin/bash
# Builds dist/LumaBar.app (release, ad-hoc signed so it runs locally).
#
# Optional environment:
#   VERSION=1.0.0        marketing version
#   BUILD_NUMBER=1       build number
#   BUNDLE_ID=...        bundle identifier (default io.github.jotharsh.LumaBar - set your own)
#   ARCHS="arm64"        architectures (default: arm64 x86_64, a universal binary)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="LumaBar"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID:-io.github.jotharsh.LumaBar}"
ARCHS="${ARCHS:-arm64 x86_64}"

APP="dist/$APP_NAME.app"
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

echo "==> swift build -c release (${ARCHS})"
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    echo "    (no Resources/AppIcon.icns - run: swift scripts/make_icon.swift)"
fi

# SwiftPM puts each dependency's resources (e.g. KeyboardShortcuts' strings) in a *.bundle next to
# the binary. The generated lookup code checks Contents/Resources inside an app, so copy them there.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
plutil -lint "$PLIST" >/dev/null

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

echo "Built $APP"
