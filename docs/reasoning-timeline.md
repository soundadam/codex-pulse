# Reasoning Timeline

Codex Pulse exposes Codex token telemetry through one compact menu bar timeline. The chart shows multiple thread-specific lines on a shared real-time axis. It does not calculate or draw a global aggregate line.

## Data Sources

- `thread/list` from `codex app-server` provides thread discovery, names, previews, `cwd`, rollout paths, and update timestamps.
- `thread/tokenUsage/updated` provides live `tokenUsage.last`, live `tokenUsage.total`, and `modelContextWindow`.
- Local rollout JSONL provides completed turn history, turn metadata, assistant text, and the final `last` and `total` token snapshots.

Discovery and realtime subscriptions run on independent app-server processes. Discovery refreshes every three seconds, while the realtime process can hold long-lived `thread/resume` subscriptions without delaying `thread/list`. Each process reconstructs stdout through one ordered byte stream so a large JSON response split across pipe chunks cannot be reordered. Codex Pulse prefers the Codex Desktop embedded CLI, accepts `CODEX_APP_SERVER_EXECUTABLE` as an explicit override, and falls back to the PATH CLI.

`assistantPreview` is text metadata only. For completed turns it comes from rollout `agent_message` or `response_item.message.output_text`. For live turns it falls back to the latest known thread message or the `thread/list.preview` value. It supports search and detail display only; it is not part of signal evaluation.

## Signal Model

Each timeline item uses one of three signal states:

- `invalid`: the turn was observed live and at least one live sample hit `0` reasoning tokens or a positive multiple of `516`.
- `valid`: the turn was observed live and no captured live sample hit the invalid signal.
- `unknown`: the turn is only known from completed rollout history, so Codex Pulse does not infer red or green from the completed aggregate alone.

The invalid signal is process-first. Once a turn is marked `invalid`, later live samples for the same `threadId:turnId` stay red, and the completed turn history also stays red after reconciliation.

## Multi-Thread Timeline

- The X axis uses each `token_count` observation time; large Turn nodes use completion time or the latest live update. The chart has two independent logarithmic Y mappings: the left axis is Turn reasoning total, calculated by summing the Turn's internal `last.reasoningOutputTokens` calls, while the right axis is the individual call value. A real value of `0` is plotted at its scale floor (`1`), while the inspector retains the true value.
- Completed rollout history contributes one immutable large node per Turn plus the Turn's internal `token_count` reasoning samples. Each small-node trace is keyed by its Turn ID, so samples never connect across Turn boundaries. Samples are extrema-preserving downsampled to at most 36 marks in the global chart.
- Realtime updates for the same running `threadId:turnId` update one moving large tail node and extend its small-node trace in place.
- Realtime subscriptions cover every discovered running thread, with no three-thread cap. A focused non-running thread is also kept subscribed.
- Repeated subscription updates are coalesced into one reconciliation pass. Discovery and realtime timeouts are isolated; the first failed discovery refresh keeps the last successful snapshot without showing a banner, while repeated failures still surface and trigger recovery.
- A completed record replaces the corresponding live tail even when its completion timestamp is earlier than the last observed update.
- Points are grouped by `threadId` before drawing, so a line never crosses from one thread into another.
- Thread colors are derived deterministically from `threadId` using a muted Morandi palette of dusty blue, slate, blue-gray, gray-violet, neutral gray, and teal. It avoids the red and orange status colors: invalid nodes are red, unknown nodes are hollow gray, and running nodes have an orange ring.
- A fixed-height horizontal legend above the plot maps each visible Thread name to its stable color. It scrolls horizontally instead of wrapping or expanding the panel, and selecting an item is equivalent to selecting that Thread's Turn-total backbone.
- The visible range is `15m`, `30m`, or `1h`, with `30m` as the process-local default. At most the latest 240 visible turns are rendered.
- Search matches the point metadata but retains the entire matching thread line inside the active window.

## Focus And Inspection

- Clicking a large node takes precedence over line hit testing, selects its Turn, and immediately opens the reasoning inspector. Small sample nodes are visual context rather than individual interaction targets; their curve remains available for Thread focus.
- Internal-call traces render below the cross-Turn backbone. The backbone is built exclusively from the large Turn-total nodes of one Thread; clicking it makes it substantially thicker, adds a wide low-opacity glow and a heading label, dims the other lines, and clears any selected Turn. Large nodes render above all call traces and keep oversized hit areas.
- The plot area is clipped to the active time domain, preventing smooth traces from drawing into the legend, axes, or panel margins at `15m`, `30m`, and `1h` boundaries.
- Double-clicking the plot clears both selections and restores equal line emphasis.
- The reasoning inspector shows the Turn total, model-call count, minimum/maximum range, median, elapsed span, model, effort, Turn ID, rollout access, and a log-scale reasoning-over-time thumbnail.
- Cached input, input, output, totals, assistant previews, and token ratios stay out of the default inspector to keep the panel focused on reasoning distribution.
- Up and down arrows move through visible turns; when a thread is focused, navigation stays within that thread.

## Realtime And Completion Reconciliation

`turn/completed` is a reconciliation trigger, not the source of final token breakdown.

- When a live `turn/completed` arrives, Codex Pulse refreshes thread and rollout metadata.
- When refresh later finds the completed turn in rollout history, the overview live residue for that turn is removed.
- The completed turn keeps any previously observed invalid signal.
- The captured live sample sequence remains attached after completion and is reconciled with rollout samples, so both the global trace and selected-Turn thumbnail survive the live-to-completed transition.

This is the fix for the old failure mode where repeated `last=516` live points could remain visible after the conversation had already finished.

## Notifications

Notifications are still completion-based. The current notification policy uses completed rollout summaries and persistent dedupe, not the thread-detail signal model. It only fires for newly observed suspicious completed turns and only when Codex Pulse is running as a bundled `.app`.

## Bounded Retention

Realtime history is intentionally memory-bounded: samples older than the one-hour lookback are pruned, each turn keeps its latest 240 raw samples, and the presentation renders at most 240 turn nodes. Completed rollout parsing remains the durable source for final turn metadata and aggregate token snapshots; realtime capture is the authority for within-turn signal history.
