cask "27b-launcher" do
  version "0.10.14"
  sha256 "522da4fc63b75d235f3411d5b3bcb7ff8c3798be8bafbee38f3325e6b3550634"

  url "https://github.com/mreasonyang/27b-launcher/releases/download/v#{version}/27B-Launcher-#{version}-macOS-arm64.dmg"
  name "27B Launcher"
  desc "Native launcher for local 27B models"
  homepage "https://github.com/mreasonyang/27b-launcher"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "27B Launcher.app"
end
