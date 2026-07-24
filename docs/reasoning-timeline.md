# Reasoning Timeline

CodexIQ exposes Codex token telemetry through one menu-bar Dashboard popover reached on the first click. The chart shows multiple thread-specific lines on a shared real-time axis. It does not calculate or draw a global aggregate line.

## Data Sources

- `thread/list` from `codex app-server` provides thread discovery, names, previews, `cwd`, rollout paths, and update timestamps.
- `thread/tokenUsage/updated` provides live `tokenUsage.last`, live `tokenUsage.total`, and `modelContextWindow`.
- Local rollout JSONL provides completed turn history, turn metadata, assistant text, and the final `last` and `total` token snapshots.

Discovery and realtime subscriptions share one multiplexed app-server process. Discovery refreshes every three seconds while the Dashboard popover is visible and every fifteen seconds in the background; long-lived `thread/resume` subscriptions continue to deliver events between polls. The client reconstructs stdout through one ordered byte stream so a large JSON response split across pipe chunks cannot be reordered. CodexIQ prefers the Codex Desktop embedded CLI, accepts `CODEX_APP_SERVER_EXECUTABLE` as an explicit override, and falls back to the PATH CLI.

`assistantPreview` is retained metadata only. For completed turns it comes from rollout `agent_message` or `response_item.message.output_text`. For live turns it falls back to the latest known thread message or the `thread/list.preview` value. It is not part of signal evaluation or the compact timeline UI.

## Signal Model

Each timeline item uses one of three signal states:

- `invalid`: the turn was observed live and at least one live sample hit `0` reasoning tokens or a positive multiple of `516`.
- `valid`: the turn was observed live and no captured live sample hit the invalid signal.
- `unknown`: the turn is only known from completed rollout history, so CodexIQ does not infer red or green from the completed aggregate alone.

The invalid signal is process-first. Once a turn is marked `invalid`, later live samples for the same `threadId:turnId` keep the invalid state, and the completed turn history keeps it after reconciliation. The chart preserves the Thread fill and adds a small red status badge instead of recoloring the whole node.

## Multi-Thread Timeline

- The X axis uses Turn completion time or the latest live update. The single logarithmic Y axis is Turn reasoning total, calculated by summing the Turn's internal `last.reasoningOutputTokens` calls. A real value of `0` is plotted at the scale floor (`1`), while the inspector retains the true value.
- Completed rollout history contributes one immutable node per Turn. The node's bounded logarithmic area represents the Turn's complete token count, while color and rings continue to represent Thread and status.
- Realtime updates for the same running `threadId:turnId` update one moving tail node and retain the internal call sequence for inspection.
- Realtime subscriptions cover every discovered running thread, with no three-thread cap. A focused non-running thread is also kept subscribed.
- Repeated subscription updates are coalesced into one reconciliation pass. The first failed discovery refresh keeps the last successful snapshot without showing a banner, while repeated failures still surface and restart the shared app-server client.
- A completed record replaces the corresponding live tail even when its completion timestamp is earlier than the last observed update.
- Points are grouped and time-sorted by `threadId` before drawing, so a line never crosses from one thread into another. Each Thread continuously connects all of its visible Turns with linear interpolation.
- Thread colors are derived deterministically from `threadId` using a high-separation Morandi palette with one cyan, one blue, violet, sage, golden yellow, ivory white, silver gray, and taupe. Every node retains that Thread color: invalid adds a small red badge, unknown adds a small gray badge, and running has an orange ring.
- One fixed-height header row combines the time control with a horizontally scrolling `project / thread` legend. Selecting an item focuses that Thread in place: the active item stays bright and the others dim, without a duplicate selected-Thread badge.
- The process-local default is `1h`. A compact segmented control switches directly among `1h`, `3h`, `6h`, `12h`, and `24h` in the same panel. Expanding the window raises the Thread discovery limit proportionally and reads more rollout history; at most the latest 240 visible Turns are rendered.

## Focus And Inspection

- Clicking a Turn node takes precedence over line hit testing, selects its Turn, and opens the lower inspector. Individual model calls never render in the main chart.
- Clicking a Thread segment modestly thickens its line, dims the other Threads, and clears any selected Turn. The selected line does not use a wide glow.
- The plot area is clipped to the active time domain, preventing marks from drawing into the legend, axes, or panel margins at every history-window boundary.
- Double-clicking the plot clears both selections and restores equal line emphasis.
- The lower inspector has two horizontally paged screens. Reasoning shows Turn reasoning, model-call count, minimum/maximum range, median, elapsed span, and a zero-based linear internal-call chart with a visible reasoning-token Y axis. Invalid internal calls are enlarged red points while the line keeps the selected Thread color. Token Mix shows last-call and Turn-total reasoning, output, cached input, input, all tokens, cached/input ratio, and reasoning/output ratio.
- The inspector is a native horizontal paging scroll view: trackpad movement follows the content continuously and snaps to a full page on release. The lower arrow controls provide the same navigation. Model, effort, Turn ID, timestamp, and rollout access stay visible in the shared card frame.
- Up and down arrows move through visible turns; when a thread is focused, navigation stays within that thread.

## Realtime And Completion Reconciliation

`turn/completed` is a reconciliation trigger, not the source of final token breakdown.

- When a live `turn/completed` arrives, CodexIQ refreshes thread and rollout metadata.
- When refresh later finds the completed turn in rollout history, the overview live residue for that turn is removed.
- The completed turn keeps any previously observed invalid signal.
- The captured live sample sequence remains attached after completion and is reconciled with rollout samples, so the selected Turn's Reasoning thumbnail survives the live-to-completed transition.

This is the fix for the old failure mode where repeated `last=516` live points could remain visible after the conversation had already finished.

## Lazy Turn Detail Cache

- The main snapshot retains only Turn summary fields required by the timeline and Token Mix: timestamps, identity, status, aggregate reasoning, and aggregate token values.
- Completed Turn model-call samples are written as compact JSON records under `~/Library/Caches/CodexPulse/turn-details` during rollout reconciliation, then stripped from the parser's memory cache and the UI snapshot.
- Selecting a node loads only that Turn's sample record. An eight-entry in-memory LRU keeps recently inspected Turns responsive; older details return to disk-only storage.
- Disk detail records expire after seven days and the directory is capped at 128MB. Expanding the history control to an earlier cutoff reparses unchanged rollout files once when the earlier detail range has not yet been cached.
- Live samples remain in the existing one-hour bounded in-memory store and merge with cached completed samples when the selected running Turn completes.

## Resource Lifecycle

- Timeline filtering, Turn de-duplication, ordering, scales, counts, and lookup maps are materialized once. An equivalent polling result leaves that immutable presentation untouched instead of rebuilding it through each SwiftUI body access.
- An unchanged time domain advances only at minute boundaries. Realtime chart publications are coalesced over 250ms while the popover is visible; hidden-state telemetry remains current without constructing a Charts display tree.
- Closing the popover releases its hosting controller, including Charts Canvas and graphics backing stores. Reopening reconstructs the view from the retained summary presentation and lazily reloads selected detail if needed.
- Rollout files are decoded line by line in 256KB chunks. When the same file grows by validated append-only writes, parsing resumes from the previous byte offset; truncation, replacement, or an earlier detail cutoff triggers a full reparse. Each rollout's model-call details reach the disk cache before its in-memory parsed value is stripped, preventing a refresh from retaining several full histories at once.
- The single app-server client replaces the previous duplicate discovery and realtime processes. Background discovery uses a fifteen-second interval while realtime subscriptions preserve timely running-Turn updates.

## Notifications

Notifications are still completion-based. The current notification policy uses completed rollout summaries and persistent dedupe, not the thread-detail signal model. It only fires for newly observed suspicious completed turns and only when CodexIQ is running as a bundled `.app`.

## Bounded Retention

Realtime history is intentionally memory-bounded: samples older than the one-hour lookback are pruned, each live Turn keeps its latest 240 raw samples, the completed-detail LRU holds eight Turns, and the presentation renders at most 240 Turn nodes. Original rollout files remain the durable source; the temporary disk cache accelerates lazy detail inspection.
