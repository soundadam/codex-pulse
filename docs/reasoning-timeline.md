# Reasoning Timeline

Codex Pulse exposes Codex token telemetry through a menu bar popover. The UI has two surfaces:

- `All Turns`: a compact global timeline of recent live samples and completed turns.
- `Thread Detail`: a searchable three-pane explorer that lists threads and turns and shows the selected turn's sample curve and token breakdown.

## Data Sources

- `thread/list` from `codex app-server` provides thread discovery, names, previews, `cwd`, rollout paths, and update timestamps.
- `thread/tokenUsage/updated` provides live `tokenUsage.last`, live `tokenUsage.total`, and `modelContextWindow`.
- Local rollout JSONL provides completed turn history, turn metadata, assistant text, and the final `last` and `total` token snapshots.

`assistantPreview` is text metadata only. For completed turns it comes from rollout `agent_message` or `response_item.message.output_text`. For live turns it falls back to the latest known thread message or the `thread/list.preview` value. It supports search and detail display only; it is not part of signal evaluation.

## Signal Model

Each timeline item uses one of three signal states:

- `invalid`: the turn was observed live and at least one live sample hit `0` reasoning tokens or a positive multiple of `516`.
- `valid`: the turn was observed live and no captured live sample hit the invalid signal.
- `unknown`: the turn is only known from completed rollout history, so Codex Pulse does not infer red or green from the completed aggregate alone.

The invalid signal is process-first. Once a turn is marked `invalid`, later live samples for the same `threadId:turnId` stay red, and the completed turn history also stays red after reconciliation.

## All Turns

`All Turns` is the lightweight global lane.

- It combines recent completed turns with sampled live timeline items instead of letting live cache completely replace completed history.
- The line chart plots `tokenUsage.last.reasoningOutputTokens`.
- Live overview sampling is conservative: for the same `threadId:turnId`, a new live point replaces the previous one unless signal state changes, the time gap reaches the configured minimum, or the reasoning delta reaches the configured threshold.
- Completed history is limited to the recent window only.

This view is intentionally coarse. It is for “what is happening across recent turns,” not for replaying every token update.

## Thread Detail

`Thread Detail` is the inspection lane.

- The left column lists recent threads.
- The middle column lists the selected thread's turns.
- The detail pane shows the selected turn's live sample sequence, `last` breakdown, `total` breakdown, model, effort, timestamps, rollout path, and assistant preview.
- Threads and turn lists automatically filter out items whose latest activity is older than the current one-hour lookback window.
- Live sample capture is independent of UI selection. Every subscribed thread retains up to 240 samples per turn inside the lookback window, so a turn can be inspected after it finishes even if it was never selected while running.

Per-turn breakdown uses:

- `Reasoning`
- `Output`
- `Cached`
- `Input`
- `Total`

If a turn has live samples, the detail pane uses those live samples directly. If a turn is completed but was never observed live, the pane still shows the completed `last` and `total` snapshots, but the signal state remains `unknown`.

## Realtime And Completion Reconciliation

`turn/completed` is a reconciliation trigger, not the source of final token breakdown.

- When a live `turn/completed` arrives, Codex Pulse marks the matching `threadId:turnId` as pending completion and refreshes metadata.
- When refresh later finds the completed turn in rollout history, the overview live residue for that turn is removed.
- The completed turn keeps any previously observed invalid signal.
- The selected thread's captured live sample sequence is retained so the detail pane can still show what happened during the turn.

This is the fix for the old failure mode where repeated `last=516` live points could remain visible after the conversation had already finished.

## Notifications

Notifications are still completion-based. The current notification policy uses completed rollout summaries and persistent dedupe, not the thread-detail signal model. It only fires for newly observed suspicious completed turns and only when Codex Pulse is running as a bundled `.app`.

## Bounded Retention

Realtime detail history is intentionally memory-bounded: samples older than the one-hour lookback are pruned and each turn keeps its latest 240 samples. Completed rollout parsing remains the durable source for final turn metadata and aggregate token snapshots; realtime capture is the authority for within-turn signal history.
