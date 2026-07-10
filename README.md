# Codex Pulse

Native macOS menu bar app for live Codex reasoning-token telemetry. It runs as an accessory-only app with a menu bar status item and a compact searchable popover. The main surface is a real-time multi-thread timeline: each thread has its own line and each node represents one turn.

Current milestone: `v0.3`.

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
- Polls `codex app-server thread/list` every three seconds for thread metadata and rollout paths, using a process independent from realtime subscriptions
- Prefers the Codex Desktop embedded CLI so the monitor speaks to the same app-server version as the desktop app; `CODEX_APP_SERVER_EXECUTABLE` can override it, and the PATH CLI remains the fallback
- Parses local rollout JSONL in Swift
- The timeline groups turns by `threadId`; it never connects points from different threads
- Large nodes mark completed Turns or the current running tail and connect only to other large nodes from the same Thread. Each Turn draws its own lightweight internal-call trace; small-node lines use the Turn ID as their series key and never cross a Turn boundary. The global trace is extrema-preserving downsampled to at most 36 samples per Turn
- The X axis uses real time with two independent logarithmic Y axes: the left axis is each large node's Turn reasoning total, computed as the sum of its internal calls; the right axis is each small node's single-call reasoning value. Zero remains visible at each scale floor. Time windows are `15m`, `30m`, and `1h`, with `30m` as the default
- Search filters whole thread lines across projects, paths, titles, models, and assistant previews
- A fixed-height horizontal legend sits above the plotting area in its own scroll view, so long Thread lists neither cover data nor expand the panel; selecting an item focuses the matching line
- Thread lines use a muted Morandi palette of dusty blue, slate, blue-gray, gray-violet, gray, and teal. Red and orange remain exclusive to invalid and running node states
- Internal-call traces render first at low emphasis. The cross-Turn backbone then renders above them using only Turn-total nodes; selecting it makes that backbone substantially thicker, adds a glow and a heading label, and dims other threads. Large Turn nodes render last and retain a larger native hit target than their visible size
- The plot area clips all marks to the active `15m`, `30m`, or `1h` bounds, including smooth interpolation near the edges
- Selecting a large Turn node opens a compact reasoning-only inspector: Turn total, model-call count, min/max range, median, elapsed span, and a log-scale time thumbnail. Cached/input/output token mixes are intentionally omitted
- A turn becomes `invalid` when any observed live sample hits `0` reasoning tokens or a positive multiple of `516`
- A completed turn with no observed live samples stays `unknown` rather than being inferred from the completed aggregate
- Every discovered running thread is subscribed without a three-thread cap; the focused thread is also forced into the subscription set. Full live sample history is retained within the one-hour window
- Subscription reconciliation is coalesced so refreshes cannot send duplicate `thread/resume` requests. Discovery and realtime use independent app-server clients, so a slow subscription cannot block `thread/list`. App-server stdout is reconstructed through one ordered stream, preserving large multi-chunk JSON responses; one failed list refresh keeps the last successful data without showing an error banner, while repeated failures still surface and recover the discovery process
- Realtime samples update the running Turn's large tail node while extending its small-node trace in place
- Refreshes are assembled by the Core repository boundary; an unreadable rollout is isolated and reported without discarding healthy live data
- The status item title uses `Cdx !<invalidCount> ~<runningCount>`, `Cdx ~<runningCount>`, or `Cdx`, and appends `?` on app-server errors

## Interaction

- Click the status item to toggle the popover
- Click a thread line to highlight it and dim the other lines
- Click a legend item to focus its thread
- Click a large node to inspect that Turn's reasoning distribution and time thumbnail; double-click the chart to clear focus
- Search filters complete thread lines; use `15m`, `30m`, or `1h` to change the visible window
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
