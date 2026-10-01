# Privacy and Local State

[Back to README](../README.md)

27B Launcher is designed with a **privacy-first, offline-by-default** philosophy. All AI generation, image processing, and inference take place entirely on your Mac's hardware.

## Core Privacy Guarantees

- **No Analytics or Telemetry**: 27B Launcher contains zero code for collecting or uploading telemetry, usage metrics, or user activity.
- **No Crash Reporting Services**: No automatic crash dumps or error reports are transmitted to external servers.
- **Offline Inference**: Prompts, messages, images, and model outputs never leave your machine unless you explicitly connect a third-party client over the network.

---

## Local Data Inventory

| Data Type | Storage Location | Retention / Deletion |
| --- | --- | --- |
| **Model weights & runtime** | `~/Library/Application Support/Bonsai2/` (or user-selected external folder) | Retained until manually deleted or cleaned via uninstaller script. |
| **Application preferences** | `com.zenxiv.Launcher27B` (in macOS `UserDefaults`) | Language, appearance, and window preferences; preserved across updates. |
| **LAN API Key** | macOS Login Keychain (`com.zenxiv.Launcher27B`) | Generated only when enabling LAN sharing; stored securely in system Keychain. |
| **Runtime logs** | `~/Library/Logs/Bonsai2/` | Local inference process logs (file permissions `0600`), automatically rotated. |
| **Web chat history** | Browser local storage (for `http://127.0.0.1:8080`) | Managed by your web browser; can be cleared in your browser settings. |

---

## Network Activity

### Outbound Network Requests
- **Component Downloads**: During first-run setup or integrity repairs, the app downloads verified runtime binaries and GGUF model files directly from official GitHub Releases and Hugging Face repositories.
- **No Other Outbound Requests**: Once components are downloaded, the application initiates zero outbound internet connections.

### Inbound Network Binding
- **Local Loopback (`127.0.0.1:8080`, Default)**:
  - Accessible only by applications and browsers running on the same Mac.
  - Requires no API key; bundled web chat is enabled.
- **LAN Sharing (`0.0.0.0:8080`, Optional)**:
  - Allows devices on your local network to send inference requests.
  - Requires an API Bearer Key (stored in Keychain).
  - Unauthenticated built-in web chat is automatically disabled in LAN mode.
  - Note: LAN traffic uses standard HTTP. On untrusted Wi-Fi networks, consider using an encrypted tunnel (e.g., SSH tunnel or VPN).

---

## Security Details

- **Secure API Key Handling**: The bearer key used for LAN access is generated locally, stored in macOS Keychain, and passed to the inference runtime via standard input pipe. It is never written to plain text configuration files or exposed in process arguments.
- **Clipboard Safety**: When you copy the LAN API key from the settings panel, it is automatically cleared from the macOS system clipboard after 60 seconds if the clipboard has not changed.

---

## Removing All Data

To completely remove the app and all associated local files:

```sh
# 1. Remove the application
rm -rf "/Applications/27B Launcher.app"

# 2. Remove downloaded model weights and logs
rm -rf ~/Library/Application\ Support/Bonsai2
rm -rf ~/Library/Logs/Bonsai2

# 3. Reset application preferences
defaults delete com.zenxiv.Launcher27B
```
