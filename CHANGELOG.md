# Changelog

## 1.0.1 — 2026-07-10

- Replaced the cryptic `Cdx !1 ~3?` menu-bar shorthand with a native pulse icon and readable `Idle`, `running`, `issue`, and `Sync issue` states.
- Added accessible menu-bar labels and descriptive hover text.
- Licensed the project under `AGPL-3.0-only`.

## 1.0.0 — 2026-07-10

Codex Pulse 1.0 establishes the stable product surface.

### Highlights

- Replaced the original Timeline/Threads split with one compact multi-Thread reasoning timeline.
- Added a real-time logarithmic reasoning axis and total-token node-area encoding.
- Added stable high-separation Thread colors with local invalid, unknown, and running accents.
- Added node-first and line-segment hit testing, Thread focus, keyboard navigation, and double-click reset.
- Added a horizontally paged Turn inspector for model-call reasoning distribution and Token Mix ratios.
- Added the fading macOS-style `1h` to `24h` history wheel.
- Added lazy per-Turn disk detail caching with bounded memory, age, and disk size.
- Added incremental append-only rollout parsing and lightweight snapshot assembly.
- Consolidated discovery and realtime subscriptions into one multiplexed app-server process.
- Added adaptive foreground/background polling and full Charts teardown when the popover closes.
- Added universal Intel and Apple Silicon Release packaging, Homebrew Cask support, and GitHub release automation.

### Validation

- 51 Swift tests across parser, timeline, app-server, snapshot, cache, notification, and app-model behavior.
- Debug and universal Release builds.
- Ad-hoc hardened-runtime signing and strict bundle verification.

## 0.3.0 — 2026-07-10

- Introduced the compact 760×520 multi-Thread timeline direction.
- Removed the separate Thread Explorer workflow.

## 0.2.0

- Added the original Timeline and Threads views.

## 0.1.0

- Initial native macOS menu-bar monitor.
