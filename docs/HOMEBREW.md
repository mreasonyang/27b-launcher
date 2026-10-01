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

## Verified release: 0.10.13 (2026-10-01)

Use 0.10.13 or later. Actual launch testing found that 0.10.12 could crash because
SwiftPM's command-line resource accessor did not resolve resources inside the
installed app. 0.10.13 resolves the packaged bundle in `Contents/Resources` and
adds an actual packaged-executable startup check to CI and release verification.

- [Source CI](https://github.com/mreasonyang/27b-launcher/actions/runs/36808152141)
  and [release workflow](https://github.com/mreasonyang/27b-launcher/actions/runs/36808587005)
  passed. The public release updated this tap automatically.
- DMG SHA-256: `ec47256bcbdc86d3dddd50c2d5e4fb0499e7738fee3017e957b249026aff6508`.
- The old source-installed `~/Applications/27B Launcher.app` was removed, and
  Homebrew installed to `/Applications`. A real Homebrew upgrade from 0.10.12
  to 0.10.13 passed with model data and preferences preserved.
- The installed 0.10.13 passed strict/deep signature verification, staple
  validation and Gatekeeper assessment (`Notarized Developer ID`).
- Installed-app startup, model loading, real browser chat, restart, stop,
  quit/reopen adoption, four languages, appearance/accessibility, checksums and
  LAN-sharing confirmation cancellation passed on this Apple Silicon Mac.
- All 263 local tests and hosted CI passed. See the detailed scope and remaining
  untested paths in [Homebrew acceptance](HOMEBREW-ACCEPTANCE-0.10.13.zh-CN.md).
- Additional same-day testing removed the app and Homebrew receipt, performed a
  fresh cask install, and separately copied the public DMG app using Finder into
  an empty `/Applications` destination. Both installed apps passed launch, model
  load, real chat, restart and stop. Existing model data was retained; this is
  not a fresh-user model-download test. Finder copy installation passed; the
  automated drag gesture did not complete and is not counted as verified.

## Historical packaging verification: 0.10.12 (2026-10-01)

The following checks validated installation and signing only. The subsequent
actual-launch test found the startup failure described above; use 0.10.13.

- [Source CI](https://github.com/mreasonyang/27b-launcher/actions/runs/36766941077)
  completed successfully before the tag was pushed.
- [Release workflow](https://github.com/mreasonyang/27b-launcher/actions/runs/36767708780)
  signed, notarized and stapled the app and DMG, published the assets and committed
  the generated cask to `main`.
- DMG SHA-256: `848d5dc5b598b594ce168cb4515f99aee3f235d51ede68b75e54b954d6ead33d`.
  Homebrew fetched the public Release asset and verified that checksum.
- Homebrew installed the cask into an isolated `--appdir`. The installed app
  reported 0.10.12, passed strict/deep signature verification, staple validation
  and Gatekeeper assessment (`Notarized Developer ID`).
- Normal Homebrew uninstall removed only the test installation; the pre-existing
  `~/Applications/27B Launcher.app` and `~/Library/Application Support/Bonsai2`
  directories remained present.

This checks download, installation, signing and uninstall on the current Mac.
It does not establish another-Mac installation, a full model download, or an
upgrade between two Homebrew-managed versions. Existing app behavior acceptance
is recorded separately in [ACCEPTANCE.zh-CN.md](ACCEPTANCE.zh-CN.md).
