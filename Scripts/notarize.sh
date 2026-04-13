#!/bin/bash
set -euo pipefail

# Glint Notarization Script
# Prerequisites:
#   1. Apple Developer ID Application certificate in Keychain
#   2. App-specific password stored: xcrun notarytool store-credentials "Glint"
#      (follow prompts for Apple ID, team ID, app-specific password)

APP_NAME="Glint"
SCHEME="Glint"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
CREDENTIALS_PROFILE="Glint"

echo "=== Building $APP_NAME ==="
xcodebuild archive \
    -scheme "$SCHEME" \
    -archivePath "$ARCHIVE_PATH" \
    -configuration Release \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_STYLE=Manual

echo "=== Exporting archive ==="
cat > "$BUILD_DIR/ExportOptions.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

echo "=== Creating DMG ==="
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$EXPORT_PATH/$APP_NAME.app" \
    -ov -format UDZO \
    "$DMG_PATH"

echo "=== Signing DMG ==="
codesign --sign "Developer ID Application" "$DMG_PATH"

echo "=== Submitting for notarization ==="
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$CREDENTIALS_PROFILE" \
    --wait

echo "=== Stapling ==="
xcrun stapler staple "$DMG_PATH"

echo ""
echo "Done! Notarized DMG: $DMG_PATH"
