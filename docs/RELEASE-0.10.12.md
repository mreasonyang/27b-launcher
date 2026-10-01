# 27B Launcher 0.10.12

**Superseded by 0.10.13:** actual installed-app testing found a localization-resource
startup crash in this version. Please install or upgrade to 0.10.13 or later.

First public Developer ID signed and Apple-notarized release, with Homebrew
installation support. Requires Apple Silicon and macOS 14 or later. Model setup
requires at least 16 GiB RAM; 32 GiB or more is recommended.

## Install with Homebrew

```sh
brew tap mreasonyang/27b-launcher https://github.com/mreasonyang/27b-launcher
brew install --cask mreasonyang/27b-launcher/27b-launcher
open "/Applications/27B Launcher.app"
```

Or download the DMG below and drag **27B Launcher.app** to **Applications**.
The ZIP contains the same stapled app. SHA-256 files accompany both packages.
The launcher downloads models and runtime components separately on first setup.

## Changes

- Added a same-repository Homebrew Cask and automatic checksum updates after
  successful publication.
- Fixed SwiftPM resource packaging and localization lookup across build layouts.
- Documented hosted CI boundaries and interactive local window acceptance.
- Added release credential cleanup and prevented replacement of public assets.

## Verification

Source CI passed before tagging. App and DMG were accepted by Apple notarization,
stapled, and assessed by Gatekeeper. Homebrew download, isolated installation and
normal uninstall were verified on an Apple Silicon Mac. This does not establish
acceptance on every supported Mac or an upgrade between Homebrew versions.

Upgrade with `brew update` followed by
`brew upgrade --cask mreasonyang/27b-launcher/27b-launcher`. Stop the model and quit
the launcher first. Normal Homebrew uninstall preserves model data and settings.

Details: [installation and maintenance](https://github.com/mreasonyang/27b-launcher/blob/main/docs/HOMEBREW.md).
