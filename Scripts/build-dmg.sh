#!/bin/bash
set -euo pipefail

# Glint — Build, sign, notarize, and package as branded DMG.
#
# Usage:
#   ./Scripts/build-dmg.sh                  # full build + notarize
#   ./Scripts/build-dmg.sh --skip-notarize  # build + sign only
#   ./Scripts/build-dmg.sh --setup          # store notarytool credentials
#
# Auto-detects your Developer ID from Keychain.
# Stores notarytool credentials under the "Glint" keychain profile.

cd "$(dirname "$0")/.."

APP_NAME="Glint"
SCHEME="Glint"
BUNDLE_ID="com.blainemiller.Glint"
VOLNAME="Glint"
BUILD_DIR="build"
DIST_DIR="dist"
ASSETS_DIR="$BUILD_DIR/assets"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
DMG_TEMP="$BUILD_DIR/glint-temp"
CREDENTIALS_PROFILE="Glint"
SKIP_NOTARIZE=false
RUN_SETUP=false

for arg in "$@"; do
    case $arg in
        --skip-notarize) SKIP_NOTARIZE=true ;;
        --setup) RUN_SETUP=true ;;
    esac
done

# ---------------------------------------------------------------------------
# Auto-detect Developer ID
# ---------------------------------------------------------------------------

detect_identity() {
    local identity
    identity=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
    if [ -z "$identity" ]; then
        echo ""
    else
        echo "$identity"
    fi
}

detect_team_id() {
    local identity="$1"
    echo "$identity" | grep -oE '\([A-Z0-9]+\)$' | tr -d '()'
}

DEVELOPER_ID_APP=$(detect_identity)
if [ -n "$DEVELOPER_ID_APP" ]; then
    TEAM_ID=$(detect_team_id "$DEVELOPER_ID_APP")
    echo "✅ Developer ID: $DEVELOPER_ID_APP"
else
    echo "⚠️  No Developer ID Application certificate found in Keychain."
    echo "   Install one from developer.apple.com or use Xcode → Settings → Accounts."
    echo "   Building with ad-hoc signing (won't be notarizable)."
    DEVELOPER_ID_APP="-"
    TEAM_ID=""
fi

# ---------------------------------------------------------------------------
# Setup mode: store notarytool credentials
# ---------------------------------------------------------------------------

if [ "$RUN_SETUP" = true ]; then
    echo ""
    echo "=== Notarytool Credential Setup ==="
    echo "This stores your Apple ID credentials in the macOS Keychain"
    echo "so builds can be notarized automatically."
    echo ""

    if [ -z "$TEAM_ID" ]; then
        echo "Enter your Apple Developer Team ID (e.g., 8ZVSPZYSVF):"
        read -r TEAM_ID
    else
        echo "Detected Team ID: $TEAM_ID"
    fi

    echo ""
    echo "You'll need an app-specific password from appleid.apple.com → Security → App-Specific Passwords"
    echo ""

    xcrun notarytool store-credentials "$CREDENTIALS_PROFILE" \
        --team-id "$TEAM_ID"

    echo ""
    echo "✅ Credentials stored as \"$CREDENTIALS_PROFILE\" in Keychain."
    echo "   Run ./Scripts/build-dmg.sh to build and notarize."
    exit 0
fi

# ---------------------------------------------------------------------------
# Check notarytool credentials
# ---------------------------------------------------------------------------

has_credentials() {
    xcrun notarytool history --keychain-profile "$CREDENTIALS_PROFILE" >/dev/null 2>&1
}

if [ "$SKIP_NOTARIZE" = false ] && [ "$DEVELOPER_ID_APP" != "-" ]; then
    if ! has_credentials; then
        echo ""
        echo "⚠️  No notarytool credentials found for profile \"$CREDENTIALS_PROFILE\"."
        echo "   Run: ./Scripts/build-dmg.sh --setup"
        echo "   Or skip with: ./Scripts/build-dmg.sh --skip-notarize"
        echo ""
        echo "   Continuing without notarization..."
        SKIP_NOTARIZE=true
    fi
fi

mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ---------------------------------------------------------------------------
# Generate brand assets
# ---------------------------------------------------------------------------

echo ""
echo "=== Generating brand assets ==="
swift Scripts/generate-assets.swift "$ASSETS_DIR"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

echo ""
echo "=== Building $APP_NAME ==="

# Build with signing disabled — we copy to /tmp and sign there to avoid
# xattr issues from iCloud Drive / APFS filesystems
xcodebuild -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tail -5

SRC_APP_PATH=$(find "$BUILD_DIR/DerivedData" -name "$APP_NAME.app" -type d | head -1)
if [ -z "$SRC_APP_PATH" ]; then
    echo "❌ Could not find $APP_NAME.app"
    exit 1
fi

# Copy to /tmp to escape iCloud Drive xattr injection
STAGE_DIR=$(mktemp -d /tmp/glint-build.XXXXXX)
APP_PATH="$STAGE_DIR/$APP_NAME.app"
cp -R "$SRC_APP_PATH" "$APP_PATH"
xattr -cr "$APP_PATH" 2>/dev/null || true

# Replace icon with generated .icns
if [ -f "$ASSETS_DIR/AppIcon.icns" ]; then
    mkdir -p "$APP_PATH/Contents/Resources"
    cp "$ASSETS_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_PATH/Contents/Info.plist"
    echo "  Icon: replaced"
fi

# Sign the app with Developer ID
if [ "$DEVELOPER_ID_APP" != "-" ]; then
    codesign --force --deep --sign "$DEVELOPER_ID_APP" --options runtime --timestamp "$APP_PATH"
    echo "  Signed: $DEVELOPER_ID_APP"
else
    codesign --force --deep --sign "-" "$APP_PATH"
    echo "  Signed: ad-hoc"
fi

APP_SIZE=$(du -sh "$APP_PATH" | cut -f1)
echo "  App: $APP_PATH ($APP_SIZE)"

# ---------------------------------------------------------------------------
# Create branded DMG
# ---------------------------------------------------------------------------

echo ""
echo "=== Creating branded DMG ==="
rm -f "${DMG_TEMP}.dmg" "$DMG_PATH"

hdiutil create -volname "$VOLNAME" -fs HFS+ -fsargs "-c c=64,a=16,e=16" \
    -size 50m "${DMG_TEMP}.dmg" -quiet

VOLUME="/Volumes/$VOLNAME"

ATTACH_OUT=$(hdiutil attach -readwrite -noverify "${DMG_TEMP}.dmg")
DEVICE=$(echo "$ATTACH_OUT" | head -1 | awk '{print $1}')

cp -R "$APP_PATH" "$VOLUME/"

rm -f "${VOLUME}/Applications"
osascript -e 'tell application "Finder" to make alias file to (path to applications folder) at POSIX file "'"${VOLUME}"'" with properties {name:"Applications"}' 2>/dev/null \
    || ln -s /Applications "${VOLUME}/Applications"

if [ -f "$ASSETS_DIR/dmg-background.jpg" ]; then
    mkdir -p "${VOLUME}/.background"
    COPYFILE_DISABLE=1 cp "$ASSETS_DIR/dmg-background.jpg" "${VOLUME}/.background/background.jpg"
    SetFile -a V "${VOLUME}/.background" 2>/dev/null || true
fi

sleep 3

osascript <<APPLESCRIPT || true
tell application "Finder"
    tell disk "$VOLNAME"
        open
        delay 3
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 200, 860, 600}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 100
        try
            set background picture of viewOptions to file ".background:background.jpg"
        end try
        try
            set position of item "$APP_NAME.app" of container window to {145, 185}
        end try
        try
            set position of item "Applications" of container window to {515, 185}
        end try
        try
            set position of item ".background" of container window to {999, 999}
        end try
        close
        delay 2
        open
        delay 2
        close
    end tell
end tell
APPLESCRIPT

osascript -e 'tell application "Finder" to close every window' 2>/dev/null || true
sleep 3; sync; sync; sleep 2

diskutil unmount "$DEVICE" 2>/dev/null \
    || diskutil unmount force "$DEVICE" 2>/dev/null \
    || hdiutil detach "$DEVICE" -force 2>/dev/null \
    || true
sleep 1

if [ -d "$VOLUME" ]; then
    hdiutil detach "$DEVICE" -force 2>/dev/null || true
    sleep 2
fi

hdiutil convert "${DMG_TEMP}.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" -quiet

if [ "$DEVELOPER_ID_APP" != "-" ]; then
    codesign --force --sign "$DEVELOPER_ID_APP" --timestamp "$DMG_PATH"
fi

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo "  DMG: $DMG_PATH ($DMG_SIZE)"

# ---------------------------------------------------------------------------
# Notarize
# ---------------------------------------------------------------------------

if [ "$SKIP_NOTARIZE" = true ] || [ "$DEVELOPER_ID_APP" = "-" ]; then
    echo ""
    [ "$DEVELOPER_ID_APP" = "-" ] && echo "⏭️  Skipping notarization (no Developer ID)"
    [ "$SKIP_NOTARIZE" = true ] && echo "⏭️  Skipping notarization (--skip-notarize)"
    echo ""
    echo "✅ Done! DMG: $DMG_PATH ($DMG_SIZE)"
    exit 0
fi

echo ""
echo "=== Notarizing ==="
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$CREDENTIALS_PROFILE" \
    --wait

echo "=== Stapling ==="
xcrun stapler staple "$DMG_PATH"

echo ""
echo "✅ Done! Notarized DMG: $DMG_PATH ($DMG_SIZE)"
