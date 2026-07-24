#!/bin/zsh

set -euo pipefail

REPO_ROOT="${0:A:h:h}"
MODE="${1:-}"
VERSION="${2:-}"
APP_NAME="Codex Pulse.app"
ARCHIVE_NAME="Codex-Pulse-${VERSION}-macOS-universal.zip"
DIST_DIR="$REPO_ROOT/dist"
APP_PATH="$REPO_ROOT/$APP_NAME"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

usage() {
    echo "usage: $0 --local|--public <semantic-version>" >&2
}

if [[ "$MODE" != "--local" && "$MODE" != "--public" ]] || [[ -z "$VERSION" ]]; then
    usage
    exit 2
fi
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
    echo "invalid semantic version: $VERSION" >&2
    exit 2
fi
if [[ "$MODE" == "--public" && "$VERSION" == "1.0.1" ]]; then
    echo "v1.0.1 is an immutable historical release and cannot be repackaged" >&2
    exit 1
fi

if [[ "$MODE" == "--public" ]]; then
    if [[ -z "${CODEXIQ_SIGNING_IDENTITY:-}" ]]; then
        echo "CODEXIQ_SIGNING_IDENTITY is required for a public package" >&2
        exit 1
    fi
    if [[ -z "${CODEXIQ_NOTARY_PROFILE:-}" ]]; then
        echo "CODEXIQ_NOTARY_PROFILE is required for a public package" >&2
        exit 1
    fi
    export CODEXIQ_SIGNING_MODE=developer-id
else
    export CODEXIQ_SIGNING_MODE=adhoc
fi

cd "$REPO_ROOT"
./refresh_codex_pulse_app.sh

BUNDLE_VERSION=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleShortVersionString" \
    "$APP_PATH/Contents/Info.plist")
if [[ "$BUNDLE_VERSION" != "$VERSION" ]]; then
    echo "bundle version $BUNDLE_VERSION does not match requested release $VERSION" >&2
    exit 1
fi
BUNDLE_BUILD=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleVersion" \
    "$APP_PATH/Contents/Info.plist")
if [[ ! "$BUNDLE_BUILD" =~ '^[0-9]+$' ]]; then
    echo "CFBundleVersion must be a positive integer: $BUNDLE_BUILD" >&2
    exit 1
fi

ARCHITECTURES=$(/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/CodexPulseRuntime")
if [[ " $ARCHITECTURES " != *" arm64 "* || " $ARCHITECTURES " != *" x86_64 "* ]]; then
    echo "release executable is not universal: $ARCHITECTURES" >&2
    exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "$MODE" == "--public" ]]; then
    NOTARIZATION_DIR=$(/usr/bin/mktemp -d -t codexiq-notarization)
    SUBMISSION_ARCHIVE="$NOTARIZATION_DIR/submission.zip"
    trap '/bin/rm -rf "$NOTARIZATION_DIR"' EXIT
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
        "$APP_PATH" "$SUBMISSION_ARCHIVE"
    /usr/bin/xcrun notarytool submit "$SUBMISSION_ARCHIVE" \
        --keychain-profile "$CODEXIQ_NOTARY_PROFILE" \
        --wait
    /usr/bin/xcrun stapler staple "$APP_PATH"
    /usr/bin/xcrun stapler validate "$APP_PATH"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH"
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

(
    cd "$DIST_DIR"
    /usr/bin/shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
"$REPO_ROOT/scripts/verify_release_archive.sh" "$MODE" "$ARCHIVE_PATH"
echo "architectures: $ARCHITECTURES"
echo "mode: ${MODE#--}"

echo "release archive: $ARCHIVE_PATH"
echo "checksum: $CHECKSUM_PATH"
