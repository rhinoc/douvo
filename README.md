<div align="center">
  <br />
  <img src="./docs/assets/douvo-icon.png" alt="Douvo icon" width="96" height="96" />
  <h1>Douvo</h1>
  <p>
    A tiny Doubao-powered voice input app for macOS.<br />
    Press a key, speak, and drop the transcript into the app you are already using.
  </p>
  <img src="./docs/assets/demo.gif" alt="Douvo demo" width="760" />
  <p>
    <a href="./README.zh.md">中文</a>
    &nbsp;·&nbsp;
    <a href="./LICENSE">License</a>
    &nbsp;·&nbsp;
    <a href="./CONTRIBUTING.md">Contributing</a>
  </p>
  <br />
</div>

## Features

- 🎙️ **Speak anywhere** — Put your cursor in a text field, trigger recording, and insert the final transcript into the focused app.
- ⌨️ **One-key trigger** — Use right Option by default, or set another single key from Settings.
- 🪶 **Small menu bar app** — No main window, no heavy workspace, just a compact menu bar utility and a floating recording overlay.
- 🧩 **Native macOS pipeline** — `AVAudioEngine` captures audio, `URLSessionWebSocketTask` streams ASR traffic, and AppKit handles the menu bar shell.
- 🛠️ **Practical Settings** — Configure trigger key, microphone, account login, diagnostics, logs, and app version in one place.
- 📋 **Clipboard-aware insertion** — Inserts through pasteboard + Command-V and restores the previous text clipboard when it is still safe.

## Disclaimer

This project depends on Doubao's web product behavior. It is **not** an official Doubao API, SDK, or integration.

- You need a valid Doubao account and must log in yourself.
- Doubao may change its website, authentication flow, WebSocket protocol, ASR payload format, rate limits, or access policy at any time.
- Audio sent for recognition is processed by Doubao's service. Review Doubao's own terms and privacy policy before using this app.
- Extracted login parameters are stored locally so the app can connect to the ASR WebSocket without keeping a browser window open.
- Use this project at your own risk. The maintainers are not responsible for service availability, account issues, data loss, policy violations, or other consequences.
- This project is not affiliated with, endorsed by, or sponsored by Doubao or ByteDance.

## How it works

Douvo uses Doubao's web product as the authentication and ASR source, but keeps the app itself native and lightweight:

1. **Log in** through an embedded `WKWebView` opened to `https://www.doubao.com/chat`.
2. **Extract local credentials** from the WebView session: Doubao cookies plus browser identifiers needed by the ASR WebSocket.
3. **Close the WebView** after login so the app does not need to keep a browser view alive while dictating.
4. **Stream microphone audio** as 16 kHz PCM chunks to Doubao's streaming ASR endpoint.
5. **Show partial transcripts** in the floating overlay while recording.
6. **Insert the final transcript** into the focused app when recording ends.

## Install

With Homebrew:

```bash
brew tap rhinoc/tap
brew install --cask douvo
```

Douvo ships as a macOS disk image. Download the latest **`douvo-<version>-macos.dmg`** from **[GitHub Releases](https://github.com/rhinoc/douvo/releases)**.

1. Open the DMG.
2. Drag **`Douvo.app`** onto the **Applications** shortcut.
3. Eject the disk image, then launch **Douvo** from **Applications** or Spotlight.

The DMG contains `Douvo.app` and an **Applications** shortcut only. Homebrew Cask installs the same DMG artifact.

In-app updates are handled by Sparkle and use the same DMG artifact published on GitHub Releases.

### First launch and Gatekeeper

Browser and Homebrew downloads can be tagged with Gatekeeper **quarantine** (`com.apple.quarantine`). If macOS warns that Douvo cannot be opened or is from an unidentified developer, remove quarantine after copying or installing the app to **Applications**.

Remove quarantine from the installed app:

```bash
xattr -dr com.apple.quarantine /Applications/Douvo.app
```

### Build locally

For development or local testing, build the app bundle yourself:

```bash
./scripts/build-app.sh
open .build/release/Douvo.app
```

The build script creates and signs a local `.app` bundle at:

```text
.build/release/Douvo.app
```

For development setup, tests, and release boundaries, see **[CONTRIBUTING.md](./CONTRIBUTING.md)**.

## Permissions

macOS needs two permissions before the app can work end to end:

1. **Microphone** — required to capture speech.
2. **Accessibility** — required for the global trigger key and Command-V insertion.

If the trigger key does not work after granting Accessibility, quit and reopen the built `.app`. If macOS still ignores the trigger, remove the old Douvo entry from **System Settings -> Privacy & Security -> Accessibility**, add the current app bundle again, then restart the app.

## Usage

1. Open the menu bar item and choose **Log In**.
2. Complete Doubao login in the popup window.
3. Place your cursor in any text field.
4. Press the trigger key to start recording.
5. Speak.
6. Press the trigger key again to stop and insert the transcript.
7. Press **Escape** while recording to cancel.

Use **Settings...** from the menu bar to change the trigger key, choose a microphone, refresh credentials, copy diagnostics, or open the app log.

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
