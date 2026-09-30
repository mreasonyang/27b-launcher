# Homebrew installation and releases

This repository is both the application source and a third-party Homebrew tap.
It is not part of the official `homebrew/cask` repository.

```sh
brew tap mreasonyang/27b-launcher https://github.com/mreasonyang/27b-launcher
brew install --cask mreasonyang/27b-launcher/27b-launcher
open "/Applications/27B Launcher.app"
```

Requires Apple Silicon and macOS 14 or later. Installation only installs the
launcher; first-run setup downloads the model and runtime separately. The model
requires at least 16 GiB RAM; 32 GiB or more is recommended.

```sh
brew update
brew upgrade --cask mreasonyang/27b-launcher/27b-launcher
brew uninstall --cask mreasonyang/27b-launcher/27b-launcher
```

Stop the model and quit the launcher before upgrading or uninstalling. Quitting
the launcher alone leaves its model process running. Disable its login item in
the app's settings before uninstalling if enabled.

The cask intentionally has no `zap` or vendor uninstall script. Normal uninstall
removes the installed app and Homebrew's receipt while preserving models,
preferences and Keychain credentials. It does not follow external model paths
or delete `~/Library/Application Support/Bonsai2`. To remove model data, use the
documented application uninstall procedure separately after reviewing its plan.

Homebrew installs to `/Applications` by default. If you already have a source
installation in `~/Applications`, quit it and use the exact Homebrew path above
to avoid launching the older copy. If `/Applications/27B Launcher.app` already
exists outside Homebrew, resolve that conflict before installing; do not use
`--force` to overwrite an unrelated installation.

## Maintainer release procedure

1. Bump `MARKETING_VERSION` and `BUILD_NUMBER` in `scripts/version.sh`.
2. Run local acceptance, including the interactive window gate in
   [CI-VALIDATION.md](CI-VALIDATION.md), and require the main CI run to pass.
3. Push the matching `vMAJOR.MINOR.PATCH` tag. Release Actions uses repository
   Secrets to sign, notarize, staple and verify the App and DMG.
4. The workflow generates a cask from the final DMG's SHA-256, uploads all assets
   to a draft Release, then publishes it. Already-public assets are not replaced.
5. After publication, the workflow commits `Casks/27b-launcher.rb` to `main` using
   the repository's `GITHUB_TOKEN`; no extra credential is needed. Do not move tags.
6. Verify `brew fetch --cask` and installation for the updated tap. A failed tap
   push leaves the prior cask intact; repair the cask from the existing public DMG,
   rather than rebuilding and replacing a released file.

The bot's push does not trigger another push-based Actions run. The tag's source
commit is covered by CI before release; the generated cask is validated against
the public asset after publication. Keep the default branch named `main`.
