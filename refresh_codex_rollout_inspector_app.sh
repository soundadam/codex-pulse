#!/bin/zsh

set -euo pipefail

REPO_ROOT="/Users/adam/projects/2607-codex-usage/codex-rollout-inspector"
APP_BUNDLE_PATH="$REPO_ROOT/Codex Rollout Inspector.app"
APP_BINARY_PATH="$APP_BUNDLE_PATH/Contents/MacOS/CodexRolloutInspectorRuntime"
BUILD_BINARY_PATH="$REPO_ROOT/.build/debug/CodexRolloutInspectorApp"

cd "$REPO_ROOT"
/usr/bin/xcrun swift build --product CodexRolloutInspectorApp

if [[ ! -x "$BUILD_BINARY_PATH" ]]; then
    echo "missing build output: $BUILD_BINARY_PATH" >&2
    exit 1
fi

/bin/mkdir -p "$APP_BUNDLE_PATH/Contents/MacOS"
/bin/rm -f "$APP_BINARY_PATH"
/bin/cp "$BUILD_BINARY_PATH" "$APP_BINARY_PATH"
/bin/chmod +x "$APP_BINARY_PATH"

echo "refreshed $APP_BUNDLE_PATH"
