#!/bin/zsh

set -euo pipefail

REPO_ROOT="${0:A:h:h}"
VERSION="${1:-1.0.1}"
APP_NAME="Codex Pulse.app"
ARCHIVE_NAME="Codex-Pulse-${VERSION}-macOS-universal.zip"
DIST_DIR="$REPO_ROOT/dist"
APP_PATH="$REPO_ROOT/$APP_NAME"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

cd "$REPO_ROOT"
./refresh_codex_pulse_app.sh

BUNDLE_VERSION=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleShortVersionString" \
    "$APP_PATH/Contents/Info.plist")
if [[ "$BUNDLE_VERSION" != "$VERSION" ]]; then
    echo "bundle version $BUNDLE_VERSION does not match requested release $VERSION" >&2
    exit 1
fi

/bin/mkdir -p "$DIST_DIR"
/bin/rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
/usr/bin/ditto \
    -c \
    -k \
    --sequesterRsrc \
    --keepParent \
    "$APP_PATH" \
    "$ARCHIVE_PATH"

/usr/bin/shasum -a 256 "$ARCHIVE_PATH" > "$CHECKSUM_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/CodexPulseRuntime"

echo "release archive: $ARCHIVE_PATH"
echo "checksum: $CHECKSUM_PATH"
