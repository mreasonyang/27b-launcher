# Privacy and local state

[README](../README.md) · Reviewed against 0.10.11 (40), 2026-09-30.

27B Launcher has no analytics or crash-report upload implementation. This claim
covers launcher code. The downloaded runtime, browser, and third-party API clients
have their own behavior and storage.

## Data inventory

| Data | Location / lifetime | Removal |
| --- | --- | --- |
| Runtime, models, adapter, downloads | `~/Library/Application Support/Bonsai2/` | Uninstaller, unless `--keep-data` |
| Selected model location and interrupted copy transaction | `model-location.json` and `model-copy.json` in that support directory | Removed with support data |
| External model files | Directory explicitly selected by the user | Preserved by uninstall; path reported |
| Source copy retained after a failed cleanup | Recorded in model location state and shown in Settings | Remove after checking the active verified copy |
| Language, display, launch settings, deferred/completed onboarding, process identity, damaged-component markers | macOS preferences domain `com.zenxiv.Launcher27B` | Uninstaller, unless `--keep-preferences` |
| API key | Login Keychain, service `com.zenxiv.Launcher27B`, account `llama-server-api-key` | Uninstaller, unless `--keep-preferences` |
| Runtime logs | `~/Library/Logs/Bonsai2/`, owner permissions `0600`, bounded rotation | Removed with support data |
| Copied API key | System clipboard | Cleared after 60 seconds while the launcher stays open, if the clipboard has not changed |
| Chat history, browser settings/cache | Browser storage for the local server origin | Clear in the browser; launcher uninstall cannot remove it |
| Login item registration | macOS Login Items | Disable in the app or System Settings before uninstall |

The key has no plaintext file store. The runtime receives it on standard input
through an anonymous pipe (`--api-key-file /dev/stdin`); it is absent from process
arguments and launcher log headers. Keychain errors stop LAN startup. Local
processes running as the same macOS user are not treated as an isolation boundary.
Other applications may read the clipboard while a copied key remains there.

Logs include times, local filesystem paths, binding mode and runtime warnings or
errors. Normal prompt logging is suppressed, but runtime errors may still contain
sensitive context. Inspect logs before sharing them.

## Network behavior

- Component downloads contact the pinned GitHub/Hugging Face URLs in
  `InstallationCatalog.swift`; those services can observe the connection's IP and
  requested files.
- Loopback mode listens at `127.0.0.1:8080`, without authentication, and offers the
  bundled browser chat. Other local processes can access this endpoint.
- LAN mode listens on all interfaces, requires a Keychain API key, and disables
  the bundled web UI and agent tools. Plain HTTP does not encrypt credentials or
  prompts. Use a trusted network or an independently configured encrypted tunnel.
- `/health` and loopback `/metrics` requests do not include credentials.
  Monitoring refuses redirects and does not use stored credentials or cookies.
  The guide reads `/v1/models` for known local chat services using the same
  credential-free transport rules. LAN token statistics are unavailable because
  the launcher does not send a reusable key to a replaceable local HTTP listener.
- API clients send prompts directly to the configured endpoint. Their own
  synchronization, telemetry, or cloud storage is outside launcher control.

## Onboarding and window lifecycle

First-run completion is a local preference, independent of whether model files
exist. Entering the dashboard from the ready guide or successfully requesting
that the browser open chat records completion. It does not record a successful
conversation. Deferring setup is a separate local preference. Neither action
uploads telemetry; Help → Quick Start can reopen the guide.

Closing the window keeps the launcher, downloads, and monitoring alive. Opening
the app again restores its window. Quitting stops launcher work; downloads can
be resumed on a later launch, and an already running model server remains
running. Use Stop to release the model process. During loading, an early model
process exit ends the health wait and exposes an error and retry action.

Example, API-address, and model-ID copies use the system clipboard. Their brief
“copied” feedback expires after two seconds; this does not clear the clipboard.
The separate API-key clipboard clearing rule is listed above.

## Current storage and lifecycle design

Model relocation copies to a uniquely named staging directory, verifies the
catalogued model digests and every additional file, checks the complete file
manifest and unchanged source, and commits one atomic location record. Only then may
it remove the source. A failed commit retains the source and verified destination.
There are no compatibility links, old preference-domain imports, or old journal
formats. A current transaction journal identifies the copy and its process birth
identity, so recovery cannot reclaim a live peer's copy.

The process manager records the PID, birth identity, executable and actual launch
options. An adopted process has unknown options until explicitly restarted.
Starting cannot silently claim an existing process used newly requested options.
Only the instance holding the filesystem lock may modify managed state.

Download progress and corruption markers use the current JSON schema only.
Unreadable or malformed records, unknown volume identity, missing capacity
measurements and failed writes stop the operation. Metadata is never replaced
with a guessed size. Resumed downloads use strong ETags; weak tags are not
rewritten and Last-Modified is not substituted. HTTP range negotiation and
bounded retries remain part of the current download protocol.

Log rotation preserves and syncs the tail before truncating. A failed rotation
stops the rotation task and reports the error while preserving the live log.
Metrics require all eight observations emitted by the pinned runtime; missing,
non-finite or out-of-range values are unavailable. Invalid saved settings block
launch until explicitly reset in Settings; invalid verification state requires
all components to be checked again. All four locales have complete translation
tables.

## Development and release

Local development packages use an explicit ad-hoc signature. Release CI requires
signing/notarization credentials and fails when they are absent. A local build
and successful tests do not establish notarization or acceptance on another Mac.
