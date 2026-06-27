# Local Development Builds

Use the dev installer when validating local macOS changes. It produces a separate app identity from the release app, so LaunchServices, Accessibility permissions, and Sparkle updates do not get mixed together.

## App Identity

- Release source identity: `Douvo` / `local.douvo`
- Local dev identity: `Douvo Dev` / `local.douvo.dev`
- Local dev path: `/Applications/Douvo Dev.app`

The source `Info.plist` stays on the release identity. The dev installer patches the copied app bundle after `scripts/build-app.sh` finishes, then signs the patched bundle.

## Signing

Local builds must use a stable signing identity. Ad-hoc signing changes the app's code requirement enough that macOS privacy permissions can appear to reset or point at stale entries.

Preferred local identity name:

```sh
Douvo Local Code Signing
```

`scripts/build-app.sh` and `scripts/install-dev-app.sh` both auto-detect this identity. You can override it with:

```sh
CODESIGN_IDENTITY="Developer ID Application: Example" scripts/install-dev-app.sh
```

If no identity is found, the scripts fail instead of producing an ad-hoc signed app.

## Install And Open

```sh
scripts/install-dev-app.sh
```

The installer:

- builds the release product
- copies `.build/release/Douvo.app` to `/Applications/Douvo Dev.app`
- patches `CFBundleDisplayName`, `CFBundleName`, and `CFBundleIdentifier`
- disables Sparkle automatic checks for the dev bundle
- removes quarantine metadata when present
- signs and verifies the copied app
- registers it with LaunchServices
- opens the dev app

## Permission Notes

macOS permissions are keyed by the app identity and signing requirement. The dev bundle intentionally keeps `local.douvo.dev` stable so repeated local installs can reuse the same Accessibility and Microphone permission rows.

If permissions look stale after changing the bundle ID or signing identity, reset the affected service for the dev bundle and grant it again in System Settings.

```sh
tccutil reset Accessibility local.douvo.dev
tccutil reset Microphone local.douvo.dev
```

Prefer keeping the bundle ID and signing identity stable over resetting permissions during normal development.

## Verification

After installation, these commands should identify the dev app:

```sh
plutil -p "/Applications/Douvo Dev.app/Contents/Info.plist" | rg "CFBundleIdentifier|CFBundleDisplayName|SUAutomaticallyUpdate|SUEnableAutomaticChecks"
codesign --verify --deep --strict "/Applications/Douvo Dev.app"
pgrep -fl "Douvo|douvo"
```
