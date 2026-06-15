#!/bin/bash
set -e

# Mac Connect DMG Builder
# Usage: ./scripts/build_dmg.sh [release|debug]

CONFIG="${1:-release}"
CONFIG_UPPER=$(echo "$CONFIG" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAC_APP_DIR="$PROJECT_ROOT/MacApp"
OUTPUT_DIR="$PROJECT_ROOT/dist"
PROJECT_NAME="AndroidBridge"          # xcodeproj/scheme name (internal)
APP_DISPLAY_NAME="Mac Connect"        # PRODUCT_NAME → built .app name
VERSION="1.0.0"
DMG_NAME="MacConnect-${VERSION}"

echo "=== Building ${APP_DISPLAY_NAME}.app (${CONFIG_UPPER}) ==="

# Regenerate Xcode project
cd "$MAC_APP_DIR"
xcodegen generate

# Build
xcodebuild -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "$PROJECT_NAME" \
    -destination 'platform=macOS' \
    -configuration "$CONFIG_UPPER" \
    clean build

# Find the built .app (named after PRODUCT_NAME, not the scheme)
DERIVED_DATA=$(xcodebuild -project "${PROJECT_NAME}.xcodeproj" -scheme "$PROJECT_NAME" -showBuildSettings 2>/dev/null | grep " BUILD_DIR" | head -1 | awk '{print $3}')
APP_PATH="${DERIVED_DATA}/${CONFIG_UPPER}/${APP_DISPLAY_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
    # Fallback: search DerivedData
    APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/${PROJECT_NAME}*/Build/Products/${CONFIG_UPPER} -maxdepth 1 -name "${APP_DISPLAY_NAME}.app" 2>/dev/null | head -1)
fi

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Cannot find ${APP_DISPLAY_NAME}.app"
    exit 1
fi

echo "Found app at: $APP_PATH"

# Stage DMG contents: the app + an Applications symlink for drag-install
mkdir -p "$OUTPUT_DIR"
STAGING=$(mktemp -d)
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}.dmg"
rm -f "$DMG_PATH"

echo "=== Creating DMG ==="
hdiutil create -volname "$APP_DISPLAY_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING"

echo ""
echo "=== Done ==="
echo "DMG: $DMG_PATH"
echo "Size: $(du -h "$DMG_PATH" | awk '{print $1}')"
