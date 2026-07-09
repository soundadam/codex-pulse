# Codex Rollout Inspector

Native macOS menu bar app for polling recent Codex threads and rolling the latest completed sessions with `tokenUsage.last` and `tokenUsage.total`.

## Stack

- Swift 6
- Swift Package Manager
- AppKit status item + attached popover shell
- SwiftUI panel UI

## Layout

- `Sources/Core`: rollout parsing, completed-session assembly, notification policy, app-server client
- `Sources/CodexRolloutInspectorUI`: app state, status item controller, SwiftUI views
- `Sources/CodexRolloutInspectorApp`: executable entrypoint
- `Tests/*`: parser, snapshot, notification, app-server, and app-model smoke coverage

## Run

```bash
swift build
swift run CodexRolloutInspectorApp
```

## Launch As .app

- Refresh the bundle after code changes:

```bash
cd "/Users/adam/projects/2607-codex-usage/codex-rollout-inspector"
./refresh_codex_rollout_inspector_app.sh
```

- Double-click [Codex Rollout Inspector.app](/Users/adam/projects/2607-codex-usage/codex-rollout-inspector/Codex%20Rollout%20Inspector.app)
- Or run:

```bash
open "/Users/adam/projects/2607-codex-usage/codex-rollout-inspector/Codex Rollout Inspector.app"
```

- The refresh step uses [refresh_codex_rollout_inspector_app.sh](/Users/adam/projects/2607-codex-usage/codex-rollout-inspector/refresh_codex_rollout_inspector_app.sh) to copy the current debug binary into the `.app` bundle.

## Scope

- Polls `codex app-server thread/list` for recent threads
- Parses local rollout JSONL in Swift
- Builds a rolling list of latest completed sessions
- Surfaces `tokenUsage.last` and `tokenUsage.total` in the menu bar panel

## Verify

```bash
swift test
```
