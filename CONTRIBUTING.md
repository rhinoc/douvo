# Contributing to Douvo

Thanks for improving Douvo. This is a small native macOS app that touches microphone input, Accessibility APIs, clipboard state, and locally stored Doubao login parameters, so changes should be deliberate and easy to review.

## Development setup

Requirements:

- macOS 13.0 or newer
- Xcode or a compatible Swift 6 toolchain
- Git
- A Doubao account for end-to-end manual testing

The repo is a Swift Package. `Package.swift` declares an executable target named `Douvo`. SPM is how the source is organized; end users run the generated `.app` bundle.

Clone and verify:

```bash
git clone https://github.com/rhinoc/douvo.git
cd douvo
swift build
```

Run during development:

```bash
swift run Douvo
```

Build a local app bundle:

```bash
./scripts/build-app.sh
open .build/release/Douvo.app
```

## Project shape

- `DouvoApp.swift` — app delegate, menu bar item, Settings entry points.
- `WebViewManager.swift` — Doubao login WebView and credential extraction.
- `DoubaoASRClient.swift` — native WebSocket client for Doubao Web ASR.
- `AudioCaptureManager.swift` — microphone capture and PCM conversion.
- `TranscriptionManager.swift` — recording lifecycle and transcript completion.
- `HotkeyManager.swift` / `HotkeyShortcut.swift` — global trigger handling.
- `PasteHelper.swift` — pasteboard insertion and clipboard restoration.
- `ShortcutCapturePanel.swift` — Settings UI.
- `OverlayPanel.swift` — floating recording overlay.

## Pull requests

- Open an issue first for large UI, ASR protocol, credential storage, release, or permission-flow changes.
- Keep pull requests focused on one behavior or one small set of related files.
- Include tests when changing parsing, shortcut encoding, credential serialization, state machines, or build scripts.
- Update `README.md`, `README.zh.md`, or this file when user-facing setup, permissions, diagnostics, or release behavior changes.
- Manual-test the menu bar flow before submitting UI or recording changes.

## Code style

- Prefer the existing SwiftUI/AppKit and `@MainActor` patterns.
- Keep shared state in `AppState` or narrow service objects; avoid new global state unless it matches an existing pattern.
- Keep UI copy short. Settings should expose actions clearly without explaining implementation details in the interface.
- Do not log secrets, full cookies, raw credential values, transcript contents beyond short previews, or private local configuration.
- Do not add compatibility layers or broad abstractions unless they remove real complexity in the current code.

## Credentials and privacy boundaries

Douvo stores extracted Doubao login parameters locally so the app can connect to Doubao Web ASR without keeping a WebView alive. Treat this area as security-sensitive:

- Never print cookie values, `device_id`, `web_id`, or full credential JSON in logs.
- Debug actions should redact values and only expose counts, key names, and local paths.
- Log out should clear stored ASR parameters and Doubao WebView data.
- Do not send diagnostics to a remote service without an explicit product decision and README update.
- Do not add analytics by default.

## Manual test checklist

Before release-oriented changes, verify:

- First launch asks for Microphone permission.
- Accessibility permission status appears correctly in Settings -> Diagnose.
- `Log In` opens Doubao and saves credentials after login.
- `Refresh Credentials` updates account state without closing Settings.
- Trigger key starts and stops recording.
- Escape cancels recording without inserting text.
- Final transcript inserts into a focused text field.
- Empty recognition shows the no-text state instead of inserting a toast-like success state.
- `Copy Last Transcript`, `Copy Login Debug Info`, `Open Log`, and `Copy Log Path` behave as expected.
- Clipboard restoration does not overwrite user clipboard changes made immediately after insertion.

## Release, Sparkle, and signing

Release creation is automated on pushes to `main`. The workflow bumps
`VERSION`, builds a DMG, updates Sparkle `appcast.xml`, uploads a GitHub
Release, then commits the generated version metadata as
`chore: auto release <version>`.

Release and local bundle creation lives in:

- `scripts/build-app.sh`
- `scripts/build-dmg.sh`
- `scripts/update_version.sh`
- `scripts/update_appcast.sh`
- `scripts/commit_release.sh`

Do not commit `.app` bundles, DMGs, certificates, private keys, Sparkle private
key exports, keychain exports, notarization logs, or local signing credentials.

Sparkle setup is documented in **[SPARKLE.md](./SPARKLE.md)**. Changes to
release automation should document:

- The app bundle identifier and display name.
- Signing and notarization requirements.
- Release artifact names.
- Sparkle appcast and update behavior.
- Permission migration notes.

## Third-party references

This project references ideas from:

- [lilong7676/doubao-murmur](https://github.com/lilong7676/doubao-murmur)
- [Open-Less/openless](https://github.com/Open-Less/openless)

Do not copy source files or assets from either project into this repository unless the PR clearly documents license compatibility, attribution, and why vendoring is necessary.

## Security reports

For credential exposure, signing key exposure, or other sensitive issues, avoid posting secrets in public issues. Open a minimal report without private values, or contact the maintainer privately when a private channel is available.
