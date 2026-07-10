cask "codex-pulse" do
  version "1.0.1"
  sha256 "0837101042307819ad8d3497573a0892d6541f09ad7fde6f91fd2b3539538b60"

  url "https://github.com/soundadam/codex-pulse/releases/download/v#{version}/Codex-Pulse-#{version}-macOS-universal.zip"
  name "Codex Pulse"
  desc "Live reasoning-token telemetry for Codex"
  homepage "https://github.com/soundadam/codex-pulse"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Codex Pulse.app"

  zap trash: [
    "~/Library/Caches/CodexPulse",
    "~/Library/Preferences/com.soundadam.codex-pulse.plist",
  ]

  caveats <<~EOS
    Codex Pulse 1.0.1 is ad-hoc signed but not Apple-notarized.
    Before first launch, remove quarantine explicitly:
      xattr -dr com.apple.quarantine "/Applications/Codex Pulse.app"
  EOS
end
