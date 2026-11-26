#!/bin/sh
# Builds a universal ShotPrompt.app and ShotPrompt-<version>.dmg in dist/.
#
#   scripts/package.sh 0.4.0
#
# Signing and notarizing happen only when their settings are present:
#   DEVELOPER_ID   "Developer ID Application: Name (TEAMID)", in the keychain
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD (an app-specific password)
# Without DEVELOPER_ID the app is ad-hoc signed, and macOS asks people to
# allow it in System Settings > Privacy & Security on first open.
set -eu
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/package.sh <version>}"
DIST=dist
APP="$DIST/ShotPrompt.app"
DMG="$DIST/ShotPrompt-$VERSION.dmg"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swift build -c release --product ShotPrompt --arch arm64 --arch x86_64
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ShotPrompt" "$APP/Contents/MacOS/ShotPrompt"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s|<key>CFBundleShortVersionString</key><string>[^<]*</string>|<key>CFBundleShortVersionString</key><string>$VERSION</string>|" \
    -e "s|<key>CFBundleVersion</key><string>[^<]*</string>|<key>CFBundleVersion</key><string>$VERSION</string>|" \
    Info.plist > "$APP/Contents/Info.plist"
lipo -archs "$APP/Contents/MacOS/ShotPrompt"

if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
else
  echo "DEVELOPER_ID not set: ad-hoc signing (not notarized)"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

STAGE="$DIST/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname ShotPrompt -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
[ -n "${DEVELOPER_ID:-}" ] && codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_APPLE_ID:-}" ]; then
  xcrun notarytool submit "$DMG" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
    --password "$NOTARY_PASSWORD" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
fi
shasum -a 256 "$DMG"
