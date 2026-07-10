#!/bin/zsh

set -euo pipefail

REPO_ROOT="/Users/adam/projects/2607-codex-usage/codex-pulse"
APP_BUNDLE_PATH="$REPO_ROOT/Codex Pulse.app"
APP_BINARY_PATH="$APP_BUNDLE_PATH/Contents/MacOS/CodexPulseRuntime"
BUILD_BINARY_PATH="$REPO_ROOT/.build/apple/Products/Release/CodexPulseApp"
APP_RESOURCES_PATH="$APP_BUNDLE_PATH/Contents/Resources"
ICON_SOURCE_PATH="$REPO_ROOT/Resources/AppIcon.icns"

cd "$REPO_ROOT"
/usr/bin/xcrun swift build \
    -c release \
    --arch arm64 \
    --arch x86_64 \
    --product CodexPulseApp

if [[ ! -x "$BUILD_BINARY_PATH" ]]; then
    echo "missing build output: $BUILD_BINARY_PATH" >&2
    exit 1
fi

/bin/mkdir -p "$APP_BUNDLE_PATH/Contents/MacOS"
/bin/mkdir -p "$APP_RESOURCES_PATH"
/bin/rm -f "$APP_BINARY_PATH"
/bin/cp "$BUILD_BINARY_PATH" "$APP_BINARY_PATH"
/bin/chmod +x "$APP_BINARY_PATH"

if [[ -f "$ICON_SOURCE_PATH" ]]; then
    /bin/cp "$ICON_SOURCE_PATH" "$APP_RESOURCES_PATH/AppIcon.icns"
fi

/usr/bin/codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp=none \
    --sign - \
    "$APP_BUNDLE_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE_PATH"

echo "refreshed $APP_BUNDLE_PATH"
