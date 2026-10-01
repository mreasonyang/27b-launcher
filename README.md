<p align="center">
  <img src="design/27b-launcher-icon-1024.png" width="128" height="128" alt="27B Launcher icon">
</p>

# 27B Launcher

**Run Bonsai 2 27B locally on your Mac — native, lightweight, and out of the box.**

27B Launcher is a native macOS application designed for Apple Silicon. It automates model downloads, manages the local inference runtime, and provides a clean desktop control panel for web chat, OpenAI-compatible API access, model storage, and the OrcaBonsai adapter. Inference runs entirely on your Mac; no cloud accounts or API keys required.

**English** · [简体中文](README.zh-CN.md)

[Quick Start](#quick-start) · [Requirements](#requirements) · [FAQ](#frequently-asked-questions)

> **Signature Notice**: Official release packages are signed with an Apple Developer ID and notarized by Apple. The app does not include an in-app auto-updater; update via Homebrew or by installing the latest DMG.

---

## Preview

<p align="center">
  <img src="docs/media/dashboard-en-light.jpg" width="860" alt="27B Launcher dashboard">
</p>

### Browser Chat & Image Understanding

Built-in local web chat supporting both text conversation and vision input:

<p align="center">
  <img src="docs/media/local-chat.gif" width="628" alt="Local Bonsai 2 conversation in browser">
</p>

---

## Features

- **Guided Onboarding**: Automatically downloads the pinned model, vision projector, LoRA adapter, and llama.cpp runtime with resume support and SHA-256 verification.
- **Native Desktop Controls**: Sits in your Dock with simple start, stop, and restart controls, plus real-time generation speed (tokens/s), memory, and context tracking.
- **Built-in Web Chat**: Open local chat in your default browser with a single click, with image attachment support for visual analysis.
- **OpenAI-Compatible API**: Serves a local `/v1` endpoint ready for clients like NextChat, Chatbox, Open WebUI, Cursor, Continue, or custom scripts.
- **OrcaBonsai Adapter Toggle**: Enable or tune the OrcaBonsai LoRA adapter (0.5×–2.0× strength) to reduce refusal behavior on benign prompts.
- **Safe Storage Migration**: Move multi-gigabyte models to an external drive with copy-and-verify safety before switching paths.
- **macOS Polish**: Supports English, 简体中文, 繁體中文, and Español; automatic light/dark mode; accessibility enhancements; optional launch at login.
- **Private & Offline**: No analytics, telemetry, or crash report uploads. Everything stays on your device.

---

## Components

The launcher downloads and coordinates four components automatically:

| Component | File & Size | Description |
| --- | --- | --- |
| **Bonsai 2 27B Base Model** | `Ternary-Bonsai-2-27B-PQ2_0.gguf`<br>~7.21 GB | Prism ML's 27-billion-parameter language model using compact ternary weights (PQ2_0). Handles general text generation, drafting, summaries, and code assistance. |
| **Vision Projector** | `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf`<br>~0.63 GB | The multimodal companion component. Converts image input so the base model can understand screenshots, diagrams, and photos (vision understanding, not image generation). |
| **OrcaBonsai LoRA** | `bonsai-abliterate-lora.gguf`<br>~9.68 MB | A low-rank adapter by Continuum AI that adjusts the model's refusal direction. Toggle it on/off or fine-tune its intensity (0.5×–2.0×) directly from the dashboard. |
| **Prism llama.cpp Runtime** | Prebuilt macOS arm64 binary<br>~11.7 MB | Optimized inference engine compiled for Apple Silicon, responsible for loading weights and serving local requests. |

> **About OrcaBonsai**:  
> Enabled by default at 2.0× strength. You can turn it off anytime to use the pure base model. Adjusting strength or toggling the adapter smoothly restarts the local server. See [Third-Party Components](docs/THIRD_PARTY.md) for pinned versions and hashes.

---

## Requirements

| Requirement | Details |
| --- | --- |
| **Mac Architecture** | Apple Silicon (`arm64`: M1/M2/M3/M4 series). **Intel Macs are not supported.** |
| **Operating System** | macOS 14 (Sonoma) or later |
| **Unified Memory** | **16 GB minimum**, **32 GB or more recommended** (16 GB devices should monitor memory on large contexts) |
| **Disk Space** | ~7.86 GB initial download; recommend **at least 15 GB free space** for runtime and cache |

---

## Quick Start

### 1. Install

#### Option A: Homebrew (Recommended)

```sh
brew tap mreasonyang/27b-launcher https://github.com/mreasonyang/27b-launcher
brew install --cask mreasonyang/27b-launcher/27b-launcher
open "/Applications/27B Launcher.app"
```

#### Option B: DMG Download

Download the latest `.dmg` from [Releases](https://github.com/mreasonyang/27b-launcher/releases/latest) and drag **27B Launcher.app** into your **Applications** folder.

#### Option C: Build from Source

```sh
git clone https://github.com/mreasonyang/27b-launcher.git
cd 27b-launcher
swift test
./scripts/install.sh
open "$HOME/Applications/27B Launcher.app"
```

> See [Homebrew Guide](docs/HOMEBREW.md) for upgrade and uninstall instructions.

---

### 2. First-Run Setup

1. Launch **27B Launcher**. The first-run guide opens automatically.
2. Confirm your storage location (defaults to `~/Library/Application Support/Bonsai2/`).
3. Click **Download and prepare**. The app downloads the components, verifies SHA-256 checksums, and starts the model.
   - You can pause and resume at any time, or click "Set up later" and continue when ready.
4. Once ready, click **Start chatting** to open the web chat in your default browser.

---

### 3. Connect Third-Party Apps (OpenAI-Compatible API)

You can connect 27B Launcher to any OpenAI-compatible app (e.g., NextChat, Chatbox, Open WebUI, Cursor, Bob):

- **Base URL**: `http://127.0.0.1:8080/v1`
- **Model ID**: Click the copy button in the dashboard (or enter `Bonsai-2-27B`)
- **API Key**: Not required in local mode; if your client requires a non-empty field, enter anything (e.g., `local`)

---

### 4. LAN Sharing (Optional)

To access the model from other devices on your local network (e.g., a phone, tablet, or another Mac):

1. In the dashboard, switch the network listening scope to **All network interfaces (0.0.0.0)**.
2. For security, the app automatically generates an API Bearer Key stored in macOS Keychain, and disables the unauthenticated web chat.
3. Connect your other devices using `http://<your-mac-lan-ip>:8080/v1` with the generated API key.

---

## Frequently Asked Questions

### What is the difference between closing the window, quitting, and stopping?
- **Closing the window (Cmd+W)**: Hides the window. Background model inference and ongoing downloads continue uninterrupted. Click the Dock icon to bring it back.
- **Quitting the app (Cmd+Q)**: Exits the launcher interface. The underlying inference engine continues running so API calls remain available.
- **Stopping the model (Stop)**: Click the **Stop** button in the dashboard to terminate the inference process and free all unified memory.

### Can I move model files to an external SSD?
Yes. Go to **Settings (Cmd+,) → Storage** and choose a new destination folder. The launcher safely copies and verifies all files before switching paths, and can be cancelled at any point without risking data loss.

### What happens if the server crashes?
- If the model process exits unexpectedly, the dashboard displays an error with an option to restart. Repeated rapid crashes pause automatic retries to prevent endless loops.
- Click the log icon in the dashboard to inspect detailed runtime logs.
- If you suspect corrupted files, run the integrity check in Settings to re-verify or repair components.

---

## Privacy & Local Data

- **100% Local**: Other than downloading model weights from GitHub and Hugging Face, no network traffic leaves your Mac.
- **Zero Telemetry**: No analytics, tracking pixels, or crash reporting services.
- **Secure Credentials**: LAN API keys are stored securely in macOS Keychain.

For detailed storage paths and network boundaries, see [Privacy and Local State](docs/PRIVACY.md).

---

## License & Acknowledgments

- The launcher source code is released under the [MIT License](LICENSE).
- Downloaded models and runtime binaries retain their respective upstream licenses:
  - **Bonsai 2 27B** by [Prism ML](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf)
  - **OrcaBonsai** by [Continuum AI](https://github.com/Continuum-AI-Corp/OrcaBonsai-27B-Uncensored)
  - **Prism llama.cpp runtime** by [PrismML-Eng](https://github.com/PrismML-Eng/llama.cpp)
  - Full details, checksums, and licenses are documented in [Third-Party Components](docs/THIRD_PARTY.md).
