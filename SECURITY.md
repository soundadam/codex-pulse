# Security and privacy

CodexIQ is a local telemetry viewer. It does not operate a hosted service and does not include analytics or an update channel.

## Data boundary

- App-server requests stay on the local child process launched by CodexIQ.
- Rollout JSONL is read from local paths returned by the local Codex app-server.
- Turn detail cache files stay under `~/Library/Caches/CodexPulse/turn-details`.
- Prompts, assistant messages, rollout content, and token usage are not uploaded by CodexIQ.

The app inherits the permissions of the launching macOS user. Anyone with access to that account and its cache or rollout files may be able to inspect the same metadata.

## Release trust

The historical `v1.0.1` release is universal and hardened-runtime but ad-hoc
signed. It is not Apple-notarized. Homebrew verifies the Cask SHA-256 before
installation; remove quarantine only after installing the official
`soundadam/tap/codex-pulse` Cask. Direct downloads can be checked against the
`.sha256` file attached to the GitHub release. Future public releases are
blocked unless the bundle is Developer ID signed, notarized, stapled, and
accepted by Gatekeeper.

## Reporting a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/soundadam/codex-pulse/security/advisories/new). Do not open a public issue for a report that contains private rollout data, credentials, or a working exploit.
