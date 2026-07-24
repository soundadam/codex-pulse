#!/bin/zsh

set -euo pipefail

REPO_ROOT="${0:A:h}"
APP_BUNDLE_PATH="$REPO_ROOT/Codex Pulse.app"
APP_BINARY_PATH="$APP_BUNDLE_PATH/Contents/MacOS/CodexPulseRuntime"
BUILD_BINARY_PATH="$REPO_ROOT/.build/apple/Products/Release/CodexPulseApp"
APP_RESOURCES_PATH="$APP_BUNDLE_PATH/Contents/Resources"
ICON_SOURCE_PATH="$REPO_ROOT/Resources/AppIcon.icns"
SIGNING_MODE="${CODEXIQ_SIGNING_MODE:-adhoc}"
SIGNING_IDENTITY="${CODEXIQ_SIGNING_IDENTITY:-}"

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

case "$SIGNING_MODE" in
    adhoc)
        /usr/bin/codesign \
            --force \
            --deep \
            --options runtime \
            --timestamp=none \
            --sign - \
            "$APP_BUNDLE_PATH"
        ;;
    developer-id)
        if [[ -z "$SIGNING_IDENTITY" ]]; then
            echo "CODEXIQ_SIGNING_IDENTITY is required for Developer ID signing" >&2
            exit 1
        fi
        if ! /usr/bin/security find-identity -v -p codesigning \
            | /usr/bin/grep -Fq "\"$SIGNING_IDENTITY\""; then
            echo "Developer ID signing identity is unavailable: $SIGNING_IDENTITY" >&2
            exit 1
        fi
        /usr/bin/codesign \
            --force \
            --deep \
            --options runtime \
            --timestamp \
            --sign "$SIGNING_IDENTITY" \
            "$APP_BUNDLE_PATH"
        ;;
    *)
        echo "unsupported CODEXIQ_SIGNING_MODE: $SIGNING_MODE" >&2
        exit 2
        ;;
esac
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE_PATH"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    SIGNING_DETAILS=$(/usr/bin/codesign -d --verbose=4 "$APP_BUNDLE_PATH" 2>&1)
    if ! /usr/bin/grep -Fq "Authority=Developer ID Application:" <<<"$SIGNING_DETAILS"; then
        echo "bundle is not signed by a Developer ID Application identity" >&2
        exit 1
    fi
fi

echo "refreshed $APP_BUNDLE_PATH ($SIGNING_MODE signing)"
