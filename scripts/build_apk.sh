#!/bin/bash
set -e

# Mac Connect APK Builder
# Usage: ./scripts/build_apk.sh [release|debug]
# Requires: Android SDK with build tools installed (via Android Studio)

CONFIG="${1:-debug}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$PROJECT_ROOT/AndroidApp"
OUTPUT_DIR="$PROJECT_ROOT/dist"
APP_NAME="MacConnect"
VERSION="1.0.0"

# Java 17 + Android SDK (Gradle needs JDK 17 on this machine)
export JAVA_HOME="${JAVA_HOME:-/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

echo "=== Building Mac Connect APK (${CONFIG}) ==="

cd "$ANDROID_DIR"

# Check for gradle wrapper
if [ ! -f "gradlew" ]; then
    echo "Gradle wrapper not found. Generating..."
    gradle wrapper --gradle-version 8.9 2>/dev/null || {
        echo "ERROR: 'gradle' command not found."
        echo "Please install Android Studio and ensure Gradle is available."
        echo "Or download the Gradle wrapper manually."
        exit 1
    }
fi

# Build
if [ "$CONFIG" = "release" ]; then
    ./gradlew assembleRelease
    APK_PATH="$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk"
else
    ./gradlew assembleDebug
    APK_PATH="$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
fi

if [ ! -f "$APK_PATH" ]; then
    echo "ERROR: APK not found at $APK_PATH"
    echo "Check the build output above for errors."
    exit 1
fi

# Copy to dist
mkdir -p "$OUTPUT_DIR"
DEST="${OUTPUT_DIR}/${APP_NAME}-${VERSION}-${CONFIG}.apk"
cp "$APK_PATH" "$DEST"

echo ""
echo "=== Done ==="
echo "APK: $DEST"
echo "Size: $(du -h "$DEST" | awk '{print $1}')"
echo ""
echo "Install on device:"
echo "  adb install $DEST"
