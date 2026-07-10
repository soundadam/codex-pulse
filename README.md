# Codex Pulse

Native macOS menu bar app for live Codex reasoning-token telemetry. It runs as an accessory-only app with a menu bar status item and a searchable popover. The panel provides a global reasoning timeline plus a three-pane thread explorer for inspecting full turn history without leaving the menu bar flow.

## Stack

- Swift 6
- Swift Package Manager
- AppKit status item + attached popover shell
- SwiftUI panel UI

## Layout

- `Sources/Core`: rollout parsing, completed-session assembly, notification policy, app-server client
- `Sources/CodexPulseUI`: app state, status item controller, SwiftUI views
- `Sources/CodexPulseApp`: executable entrypoint
- `Tests/*`: parser, snapshot, notification, app-server, and app-model smoke coverage
- `docs/reasoning-timeline.md`: reasoning timeline model, signal rules, and reconciliation notes

## Run

```bash
swift build
swift run CodexPulseApp
```

## Launch As .app

- Refresh the bundle after code changes:

```bash
cd "/Users/adam/projects/2607-codex-usage/codex-pulse"
./refresh_codex_pulse_app.sh
```

- Double-click [Codex Pulse.app](/Users/adam/projects/2607-codex-usage/codex-pulse/Codex%20Pulse.app)
- Or run:

```bash
open "/Users/adam/projects/2607-codex-usage/codex-pulse/Codex Pulse.app"
```

- The refresh step uses [refresh_codex_pulse_app.sh](/Users/adam/projects/2607-codex-usage/codex-pulse/refresh_codex_pulse_app.sh) to copy the current debug binary into the `.app` bundle.

## Current Behavior

- Uses `codex app-server thread/tokenUsage/updated` as the realtime lane
- Polls `codex app-server thread/list` at `1Hz` for thread metadata and rollout paths
- Parses local rollout JSONL in Swift
- The timeline plots recent live samples and completed turns, with explicit invalid, observed, and unknown signal states
- Timeline and thread views share one search field across projects, paths, titles, models, and assistant previews
- Selecting a node expands the current thread's recent turns and the selected turn's `last` / `total` breakdown inline
- The thread explorer exposes recent threads, their turns, live sample curves, token breakdowns, metadata, and rollout access
- A turn becomes `invalid` when any observed live sample hits `0` reasoning tokens or a positive multiple of `516`
- A completed turn with no observed live samples stays `unknown` rather than being inferred from the completed aggregate
- Full live sample history is retained for every subscribed thread within the one-hour window, so inspection does not depend on selecting a thread before its turn runs
- Refreshes are assembled by the Core repository boundary; an unreadable rollout is isolated and reported without discarding healthy live data
- The status item title uses `Cdx !<invalidCount> ~<runningCount>`, `Cdx ~<runningCount>`, or `Cdx`, and appends `?` on app-server errors

## Interaction

- Click the status item to toggle the popover
- Switch between `Timeline` and `Threads` with the segmented control
- Search across the active surface from the shared search field
- `Escape` closes the popover
- `Command-R` refreshes
- Up and down arrows move the current selection
- `Return` opens the selected rollout file

## See Also

- [Reasoning timeline design](docs/reasoning-timeline.md)

## Verify

```bash
swift test
```
