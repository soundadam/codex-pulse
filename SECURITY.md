# Security and privacy

Codex Pulse is a local telemetry viewer. It does not operate a hosted service and does not include analytics or an update channel.

## Data boundary

- App-server requests stay on the local child process launched by Codex Pulse.
- Rollout JSONL is read from local paths returned by the local Codex app-server.
- Turn detail cache files stay under `~/Library/Caches/CodexPulse/turn-details`.
- Prompts, assistant messages, rollout content, and token usage are not uploaded by Codex Pulse.

The app inherits the permissions of the launching macOS user. Anyone with access to that account and its cache or rollout files may be able to inspect the same metadata.

## Release trust

Version 1.0 is universal and hardened-runtime but ad-hoc signed. It is not Apple-notarized. Verify release downloads against the `.sha256` file attached to the GitHub release, and use the documented `HOMEBREW_CASK_OPTS="--no-quarantine"` installation only for the official `soundadam/codex-pulse` release asset.

## Reporting a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/soundadam/codex-pulse/security/advisories/new). Do not open a public issue for a report that contains private rollout data, credentials, or a working exploit.
