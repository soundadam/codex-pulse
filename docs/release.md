# Release, signing, and Homebrew

This document is the maintainer path for a Codex Pulse release.

## Build contract

- `CFBundleShortVersionString`, the app-server client version, Git tag, archive name, and Homebrew Cask version use the same semantic version.
- Release binaries are universal `arm64 + x86_64` and target macOS 14 or newer.
- The bundle is hardened-runtime and ad-hoc signed until a Developer ID Application identity and notarization profile are available.

Run the complete local validation:

```bash
swift test
./scripts/package_release.sh 1.0.0
```

The packaging script rebuilds the bundle, verifies its version and signature, creates `dist/Codex-Pulse-<version>-macOS-universal.zip`, and writes the matching SHA-256 file.

## GitHub release

Create and push the release commit and annotated tag:

```bash
git tag -a v1.0.0 -m "Codex Pulse 1.0.0"
git push origin main v1.0.0
```

The release workflow validates the package and publishes both files from `dist/`. Release notes come from the matching section in `CHANGELOG.md`.

## Homebrew Cask

The public install command is:

```bash
HOMEBREW_CASK_OPTS="--no-quarantine" brew install --cask soundadam/tap/codex-pulse
```

The Cask lives in `soundadam/homebrew-tap/Casks/codex-pulse.rb`. After publishing a new release:

1. Copy the release archive SHA-256 into the Cask.
2. Update the version and URL if the archive naming contract changes.
3. Run `brew audit --cask --strict --online soundadam/tap/codex-pulse` and `HOMEBREW_CASK_OPTS="--no-quarantine" brew install --cask soundadam/tap/codex-pulse`.
4. Launch the installed application and confirm app-server discovery, realtime subscription, Turn detail loading, and rollout opening.

## Notarization upgrade

When a Developer ID Application certificate is available, replace ad-hoc signing with Developer ID signing, submit the zip with `notarytool`, staple the result, and remove the `HOMEBREW_CASK_OPTS` override from the public installation command and Cask caveats.
