cask "codex-pulse" do
  version "1.0.0"
  sha256 "741223d8d1bcba40f9893ec4e6a0b223f9166561be7646e7b5df93d6254172f2"

  url "https://github.com/soundadam/codex-pulse/releases/download/v#{version}/Codex-Pulse-#{version}-macOS-universal.zip",
      verified: "github.com/soundadam/codex-pulse/"
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
    Codex Pulse 1.0 is ad-hoc signed but not Apple-notarized.
    Install this personal-tap release with Homebrew's --no-quarantine option.
  EOS
end
