cask "27b-launcher" do
  version "0.10.12"
  sha256 "848d5dc5b598b594ce168cb4515f99aee3f235d51ede68b75e54b954d6ead33d"

  url "https://github.com/mreasonyang/27b-launcher/releases/download/v#{version}/27B-Launcher-#{version}-macOS-arm64.dmg"
  name "27B Launcher"
  desc "Native launcher for local 27B models"
  homepage "https://github.com/mreasonyang/27b-launcher"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "27B Launcher.app"
end
