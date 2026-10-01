cask "27b-launcher" do
  version "0.10.13"
  sha256 "ec47256bcbdc86d3dddd50c2d5e4fb0499e7738fee3017e957b249026aff6508"

  url "https://github.com/mreasonyang/27b-launcher/releases/download/v#{version}/27B-Launcher-#{version}-macOS-arm64.dmg"
  name "27B Launcher"
  desc "Native launcher for local 27B models"
  homepage "https://github.com/mreasonyang/27b-launcher"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "27B Launcher.app"
end
