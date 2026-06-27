<div align="center">
  <br />
  <img src="./docs/assets/douvo-icon.png" alt="Douvo icon" width="96" height="96" />
  <h1>Douvo</h1>
  <p>
    A lightweight macOS voice input app with Doubao ASR and optional AI correction.<br />
    Press a key, speak, clean up the transcript, and insert it into the app you are already using.
  </p>
  <p>
    <a href="./README.zh.md">中文</a>
    &nbsp;·&nbsp;
    <a href="./LICENSE">License</a>
    &nbsp;·&nbsp;
    <a href="./CONTRIBUTING.md">Contributing</a>
  </p>
  <br />
</div>

## Capabilities

<table>
  <tr>
    <td align="center">
      <img src="./docs/assets/demo.gif" width="380" alt="Douvo recording and inserting text into another app" />
      <br />
      <sub>Dictate into the current app</sub>
    </td>
    <td align="center">
      <img src="./docs/assets/readme/reduce-emotion.gif" width="380" alt="Douvo reducing emotional wording in AI correction" />
      <br />
      <sub>Reduce emotional wording</sub>
    </td>
  </tr>
</table>

## Features

- 🎙️ **Dictate into any app** — Press one key, speak, and insert the transcript at the current cursor.
- 🧠 **Clean up before paste** — Optional AI correction can fix wording, punctuation, filler words, tone, and style.
- 🗂️ **Use your own vocabulary** — Add project terms, paths, names, and product words so corrections match your work.
- ⚙️ **Choose local or remote AI** — Run MLX models on device, use a local model folder, or connect a remote LLM provider.
- 🪶 **Keep the workflow lightweight** — Menu bar UI, floating recording overlay, clipboard-aware insertion, and local diagnostics.

## Disclaimer

This project depends on Doubao's web product behavior. It is **not** an official Doubao API, SDK, or integration.

- You need a valid Doubao account and must log in yourself.
- Doubao may change its website, authentication flow, WebSocket protocol, ASR payload format, rate limits, or access policy at any time.
- Audio sent for recognition is processed by Doubao's service. Review Doubao's own terms and privacy policy before using this app.
- Extracted login parameters are stored locally so the app can connect to the ASR WebSocket without keeping a browser window open.
- If remote AI correction is enabled, transcript text is sent to the provider and endpoint you configure.
- Local AI correction uses MLX models downloaded from Hugging Face or loaded from a local model folder.
- Use this project at your own risk. The maintainers are not responsible for service availability, account issues, data loss, policy violations, or other consequences.
- This project is not affiliated with, endorsed by, or sponsored by Doubao or ByteDance.

## How it works

Douvo uses Doubao's web product for authentication and ASR, then optionally post-processes the final transcript before insertion.

```mermaid
flowchart TD
    A[Log in with embedded WKWebView] --> B[Store Doubao cookies and browser identifiers locally]
    B --> C[Trigger recording from the menu bar app]
    C --> D[Capture microphone audio with AVAudioEngine]
    D --> E[Stream 16 kHz PCM chunks to Doubao Web ASR]
    E --> F[Show partial transcript in the floating overlay]
    F --> G[Receive final ASR transcript]
    G --> H{AI Correction enabled?}
    H -- No --> L[Apply deterministic punctuation and vocabulary fallback]
    H -- Local --> I[Run local MLX model on device]
    H -- Remote --> J[Send transcript to the configured remote LLM provider]
    I --> K[Clean, validate, and normalize corrected text]
    J --> K
    K --> L
    L --> M[Insert final text with pasteboard and Command-V]
    M --> N[Restore clipboard when safe]
    G --> O[Write local traces, timings, and logs for diagnostics]
```

## Requirements

- Apple Silicon Mac.
- macOS 14.0 or newer.

## Install

Recommended: download the latest **`douvo-<version>-macos.dmg`** from **[GitHub Releases](https://github.com/rhinoc/douvo/releases)**.

1. Open the DMG.
2. Drag **`Douvo.app`** onto the **Applications** shortcut.
3. Eject the disk image, then launch **Douvo** from **Applications** or Spotlight.

The DMG contains `Douvo.app` and an **Applications** shortcut only. Current release builds are not notarized, so macOS may ask you to confirm first launch or remove quarantine manually.

Homebrew is also available if you prefer tap-based installs:

```bash
brew tap rhinoc/tap
brew install --cask douvo
```

Homebrew Cask installs the same DMG artifact from GitHub Releases, not a separately signed package.

In-app updates are handled by Sparkle and use the same DMG artifact published on GitHub Releases.

### First launch and Gatekeeper

Browser and Homebrew downloads can be tagged with Gatekeeper **quarantine** (`com.apple.quarantine`). If macOS warns that Douvo cannot be opened or is from an unidentified developer, remove quarantine after copying or installing the app to **Applications**.

Remove quarantine from the installed app:

```bash
xattr -dr com.apple.quarantine /Applications/Douvo.app
```

## Permissions

macOS needs two permissions before the app can work end to end:

1. **Microphone** — required to capture speech.
2. **Accessibility** — required for the global trigger key and Command-V insertion.

If the trigger key does not work after granting Accessibility, quit and reopen the built `.app`. If macOS still ignores the trigger, remove the old Douvo entry from **System Settings -> Privacy & Security -> Accessibility**, add the current app bundle again, then restart the app.

Local AI correction runs on device. Remote AI correction sends transcript text to the configured remote provider and stores that provider's API key in Keychain.

## Usage

1. Open the menu bar item and choose **Log In**.
2. Complete Doubao login in the popup window.
3. Place your cursor in any text field.
4. Press the trigger key to start recording.
5. Speak.
6. Press the trigger key again to stop and insert the transcript.
7. Press **Escape** while recording to cancel.

Use **Settings...** from the menu bar to change the trigger key, choose a microphone, refresh credentials, copy diagnostics, or open the app log.

### AI Correction

Open **Settings... -> Correction** to configure transcript post-processing:

- Choose **Local** to download a built-in MLX model or add a local MLX model folder.
- Choose **Remote** to add a provider, base URL, model name, and API key.
- Add vocabulary hints for project terms, file paths, product names, and common ASR mistakes.
- Tune punctuation, filler-word removal, emotion softening, and output style.
- Use Correction Debug to test a sample input and inspect the local trace.

## References

This project was built with reference to these open-source projects:

- [lilong7676/doubao-murmur](https://github.com/lilong7676/doubao-murmur)
  - WebView-based Doubao login.
  - Cookie and browser-identifier extraction for native ASR access.
  - Native WebSocket access to Doubao Web ASR.
  - 16 kHz PCM audio streaming and finish-frame behavior.
  - Menu bar voice-input interaction on macOS.
- [Open-Less/openless](https://github.com/Open-Less/openless)
  - Product direction for app-agnostic voice input at the current cursor.
  - Menu bar / tray voice-input workflow.
  - Settings and diagnostics organization.
  - Text insertion reliability ideas, including paste fallback and clipboard restoration.

This repository does not vendor either project. Their code and licenses remain owned by their respective authors.

## Contributing

Development setup, coding conventions, testing, credential-handling rules, and release notes live in **[CONTRIBUTING.md](./CONTRIBUTING.md)**.

## License

Douvo is released under the **MIT License**. See **[LICENSE](./LICENSE)**.
