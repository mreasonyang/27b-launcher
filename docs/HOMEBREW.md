# Homebrew Installation and Maintenance

[Back to README](../README.md)

27B Launcher is available as a Homebrew Cask via this repository's tap.

## Installation

```sh
brew tap mreasonyang/27b-launcher https://github.com/mreasonyang/27b-launcher
brew install --cask mreasonyang/27b-launcher/27b-launcher
open "/Applications/27B Launcher.app"
```

### Requirements
- **Apple Silicon Mac** (`arm64`: M1/M2/M3/M4)
- **macOS 14 (Sonoma)** or later
- At least 16 GB unified memory (32 GB+ recommended)

> Note: Installing via Homebrew installs the launcher application (~20 MB). Model weights and the runtime (~7.86 GB) will be downloaded automatically when you first launch the app.

---

## Upgrades

To update to the latest release:

```sh
brew update
brew upgrade --cask mreasonyang/27b-launcher/27b-launcher
```

> **Important**: Before upgrading, make sure to stop any running model instance and quit 27B Launcher.

---

## Uninstallation & Data Management

To remove the app:

```sh
brew uninstall --cask mreasonyang/27b-launcher/27b-launcher
```

### Data Preservation
By design, `brew uninstall` removes only the application bundle from `/Applications`. To prevent accidental loss of downloaded model weights (~8 GB) and preferences, the following user data is preserved:
- Model files and runtime: `~/Library/Application Support/Bonsai2/` (or your custom storage path)
- App preferences: `~/Library/Preferences/com.zenxiv.Launcher27B.plist`
- LAN API keys: Stored securely in macOS Keychain under `com.zenxiv.Launcher27B`

### Completely Deleting All Data
If you want to perform a full cleanup and delete all downloaded models and configurations:

```sh
# 1. Remove support files and model weights
rm -rf ~/Library/Application\ Support/Bonsai2
rm -rf ~/Library/Logs/Bonsai2

# 2. Reset preferences
defaults delete com.zenxiv.Launcher27B
```

Alternatively, you can run the uninstaller script from the repository:
```sh
./scripts/uninstall.sh
```

---

## Troubleshooting

### Conflicts with Source Builds
If you previously installed a build from source into `~/Applications/27B Launcher.app`, quit it before launching the Homebrew version in `/Applications/27B Launcher.app` to ensure macOS opens the updated build.

---

## Maintainer Release Procedure

For maintainers publishing a new version:

1. Update `MARKETING_VERSION` and `BUILD_NUMBER` in `scripts/version.sh`.
2. Ensure local tests and CI pass.
3. Push the version tag (e.g. `git tag v0.10.14 && git push origin v0.10.14`).
4. GitHub Actions will automatically sign, notarize, build the DMG, publish the release, and update `Casks/27b-launcher.rb` on the `main` branch.
5. Verify the cask by running `brew update && brew fetch --cask mreasonyang/27b-launcher/27b-launcher`.
