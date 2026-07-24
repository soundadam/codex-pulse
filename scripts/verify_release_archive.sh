#!/bin/zsh

set -euo pipefail

MODE="${1:-}"
ARCHIVE_PATH="${2:-}"
CASK_PATH="${3:-}"

if [[ "$MODE" != "--local" && "$MODE" != "--public" ]] || [[ -z "$ARCHIVE_PATH" ]]; then
    echo "usage: $0 --local|--public <archive.zip> [cask.rb]" >&2
    exit 2
fi

ARCHIVE_PATH="${ARCHIVE_PATH:A}"
if [[ ! -f "$ARCHIVE_PATH" ]]; then
    echo "archive does not exist: $ARCHIVE_PATH" >&2
    exit 1
fi

ARCHIVE_NAME="${ARCHIVE_PATH:t}"
if [[ ! "$ARCHIVE_NAME" =~ '^Codex-Pulse-([0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?)-macOS-universal\.zip$' ]]; then
    echo "archive does not follow the release naming contract: $ARCHIVE_NAME" >&2
    exit 1
fi
VERSION="$match[1]"
ARCHIVE_SHA=$(/usr/bin/shasum -a 256 "$ARCHIVE_PATH" | /usr/bin/awk '{print $1}')

CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
if [[ -f "$CHECKSUM_PATH" ]]; then
    EXPECTED_CHECKSUM="$ARCHIVE_SHA  $ARCHIVE_NAME"
    ACTUAL_CHECKSUM=$(/bin/cat "$CHECKSUM_PATH")
    if [[ "$ACTUAL_CHECKSUM" != "$EXPECTED_CHECKSUM" ]]; then
        echo "checksum sidecar does not match the archive" >&2
        exit 1
    fi
fi

EXTRACT_DIR=$(/usr/bin/mktemp -d -t codexiq-release-verification)
trap '/bin/rm -rf "$EXTRACT_DIR"' EXIT
/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$EXTRACT_DIR"

APP_PATH="$EXTRACT_DIR/Codex Pulse.app"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/CodexPulseRuntime"
if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    echo "archive does not contain the expected executable" >&2
    exit 1
fi

BUNDLE_VERSION=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleShortVersionString" \
    "$APP_PATH/Contents/Info.plist")
if [[ "$BUNDLE_VERSION" != "$VERSION" ]]; then
    echo "archive version $VERSION does not match bundle version $BUNDLE_VERSION" >&2
    exit 1
fi
BUNDLE_IDENTIFIER=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleIdentifier" \
    "$APP_PATH/Contents/Info.plist")
BUNDLE_NAME=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleDisplayName" \
    "$APP_PATH/Contents/Info.plist")
MINIMUM_SYSTEM=$(/usr/libexec/PlistBuddy \
    -c "Print :LSMinimumSystemVersion" \
    "$APP_PATH/Contents/Info.plist")
if [[ "$BUNDLE_IDENTIFIER" != "com.soundadam.codex-pulse" ]]; then
    echo "unexpected bundle identifier: $BUNDLE_IDENTIFIER" >&2
    exit 1
fi
if [[ "$BUNDLE_NAME" != "CodexIQ" ]]; then
    echo "unexpected product display name: $BUNDLE_NAME" >&2
    exit 1
fi
if [[ "$MINIMUM_SYSTEM" != "14.0" ]]; then
    echo "unexpected minimum macOS version: $MINIMUM_SYSTEM" >&2
    exit 1
fi

ARCHITECTURES=$(/usr/bin/lipo -archs "$EXECUTABLE_PATH")
if [[ " $ARCHITECTURES " != *" arm64 "* || " $ARCHITECTURES " != *" x86_64 "* ]]; then
    echo "archive executable is not universal: $ARCHITECTURES" >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "$MODE" == "--public" ]]; then
    SIGNING_DETAILS=$(/usr/bin/codesign -d --verbose=4 "$APP_PATH" 2>&1)
    if ! /usr/bin/grep -Fq "Authority=Developer ID Application:" <<<"$SIGNING_DETAILS"; then
        echo "public archive is not Developer ID Application signed" >&2
        exit 1
    fi
    /usr/bin/xcrun stapler validate "$APP_PATH"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH"
fi

if [[ -n "$CASK_PATH" ]]; then
    CASK_PATH="${CASK_PATH:A}"
    CASK_VERSION=$(/usr/bin/sed -nE 's/^[[:space:]]*version "([^"]+)"/\1/p' "$CASK_PATH")
    CASK_SHA=$(/usr/bin/sed -nE 's/^[[:space:]]*sha256 "([0-9a-f]{64})"/\1/p' "$CASK_PATH")
    if [[ "$CASK_VERSION" != "$VERSION" || "$CASK_SHA" != "$ARCHIVE_SHA" ]]; then
        echo "Cask version or SHA-256 does not match the archive" >&2
        exit 1
    fi
fi

echo "verified $ARCHIVE_NAME"
echo "version: $VERSION"
echo "bundle: $BUNDLE_IDENTIFIER ($BUNDLE_NAME)"
echo "sha256: $ARCHIVE_SHA"
echo "architectures: $ARCHITECTURES"
echo "trust mode: ${MODE#--}"
