# 27B Launcher 0.10.13

Fixes a startup crash in the installed 0.10.12 app: packaged localization resources
now resolve from the application's Resources directory. CI and release verification
run the packaged executable to catch startup failures before publication.

Requires Apple Silicon and macOS 14 or later.

```sh
brew tap mreasonyang/27b-launcher https://github.com/mreasonyang/27b-launcher
brew install --cask mreasonyang/27b-launcher/27b-launcher
```

For an existing installation, stop the model and quit the launcher, then run
`brew update` and `brew upgrade --cask mreasonyang/27b-launcher/27b-launcher`.
Models and settings are preserved.

263 local tests and source CI passed. The signed/notarized Homebrew app was tested
on an Apple Silicon Mac: upgrade, launch, model load, real chat, restart, stop,
quit/reopen adoption, language/appearance and model-file verification passed.

Detailed scope: [Homebrew acceptance](https://github.com/mreasonyang/27b-launcher/blob/main/docs/HOMEBREW-ACCEPTANCE-0.10.13.zh-CN.md).
