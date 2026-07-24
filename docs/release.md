# Release, signing, and Homebrew

This document is the maintainer path for a CodexIQ release. The repository, Cask token, bundle identifier, archive naming, and transitional `Codex Pulse.app` filename remain compatibility identifiers; a release may show CodexIQ through `CFBundleDisplayName`, `CFBundleName`, Homebrew display metadata, and release prose without changing them.

## Current publication gate

The maintainer does not currently have a Developer ID Application identity or
notarization profile. The already published `v1.0.1` asset and Cask remain
available and immutable, but they are a historical ad-hoc-signed exception, not
the template for another public release.

Until Developer ID signing and notarization are implemented and verified end to
end, packaging is local-candidate-only. Do not push a new public App tag, create
a new App Release, or update the public Cask. Product development and local
ad-hoc candidates may continue. The tag workflow is intentionally fail-closed
and has read-only repository permissions while this gate is active.

## Build contract

- `CFBundleShortVersionString`, the app-server client version, Git tag, archive name, and Homebrew Cask version use the same semantic version.
- Release binaries are universal `arm64 + x86_64` and target macOS 14 or newer.
- Local candidates are hardened-runtime and ad-hoc signed. A future public
  release must use Developer ID signing and accepted notarization.

Run the complete local validation:

```bash
swift test
./scripts/package_release.sh --local "$VERSION"
```

The local mode rebuilds an ad-hoc-signed development candidate, verifies its
version, integer build number, universal architectures, signature, extracted
archive, and checksum sidecar. It creates
`dist/Codex-Pulse-<version>-macOS-universal.zip` and the matching SHA-256 file.
It is never a public-release input.

Public mode is a separate fail-closed interface:

```bash
CODEXIQ_SIGNING_IDENTITY="Developer ID Application: …" \
CODEXIQ_NOTARY_PROFILE="codexiq-notary" \
  ./scripts/package_release.sh --public "$VERSION"
```

The identity and `notarytool` keychain profile must already be provisioned on
the release runner by the external credential authority. They are selectors,
not secret values, and must not be used to store certificate material in this
repository or its workflow. Public mode signs with a timestamp, submits a
temporary archive to Apple, waits for acceptance, staples the application,
requires both `stapler validate` and Gatekeeper acceptance, then creates and
re-extracts the final distributable. It explicitly refuses to rebuild the
immutable historical `v1.0.1` release.

## GitHub release

The commands below are valid only after the current publication gate is removed.
Create and push the release commit and annotated tag:

```bash
git tag -a "v${VERSION}" -m "CodexIQ ${VERSION}"
git push origin main "v${VERSION}"
```

The release workflow is currently fail-closed. It requires
`CODEXIQ_NOTARIZED_RELEASES_ENABLED=true`, non-secret identity/profile selector
variables, and a runner provisioning step that installs the short-lived
Developer ID and notarization credentials. Do not enable the repository gate
until that provisioning step exists and a dry run passes. The validation job
retains read-only repository permission; only the dependent publication job
receives `contents: write`. Existing releases are never replaced.

## Homebrew Cask

The public install command is:

```bash
brew install --cask soundadam/tap/codex-pulse
xattr -dr com.apple.quarantine "/Applications/Codex Pulse.app"
```

The Cask lives in `soundadam/homebrew-tap/Casks/codex-pulse.rb`. Only after the
publication gate is removed and a notarized release exists:

1. Copy the release archive SHA-256 into the Cask.
2. Update the version and URL if the archive naming contract changes.
3. Download the actual GitHub asset, recalculate its SHA-256, and run
   `scripts/verify_release_archive.sh --public <downloaded.zip> <candidate-cask>`.
4. Run `brew audit --cask --strict --online soundadam/tap/codex-pulse`, then test
   clean install, upgrade from `v1.0.1`, launch, and uninstall/zap. A notarized
   release must not require quarantine removal.
5. Launch the installed application and confirm app-server discovery, realtime subscription, Turn detail loading, rollout opening, preferences continuity, and bounded cache behavior.

## Notarization upgrade

To remove the publication gate, replace ad-hoc signing with Developer ID
signing, notarize the distributable artifact, verify Gatekeeper acceptance on a
clean Homebrew install, and update the release workflow so it cannot publish an
ad-hoc bundle. Remove the quarantine-removal step from public instructions and
Cask caveats only after those checks pass.
