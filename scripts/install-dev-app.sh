#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_APP="$ROOT/.build/release/Douvo.app"
DEV_APP="${DOUVO_DEV_APP_PATH:-/Applications/Douvo Dev.app}"
DEV_BUNDLE_ID="${DOUVO_DEV_BUNDLE_ID:-local.douvo.dev}"
DEV_DISPLAY_NAME="${DOUVO_DEV_DISPLAY_NAME:-Douvo Dev}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

"$ROOT/scripts/build-app.sh" >/dev/null

if [[ ! -d "$SRC_APP" ]]; then
  echo "error: built app not found at $SRC_APP" >&2
  exit 1
fi

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Douvo Local Code Signing/ { print $2; exit }'
  )"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "error: no codesigning identity found. Refusing to install an ad-hoc signed dev app." >&2
  echo "Set CODESIGN_IDENTITY or install 'Douvo Local Code Signing'." >&2
  exit 1
fi

osascript -e "tell application id \"$DEV_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
pkill -f "$DEV_APP/Contents/MacOS/Douvo" >/dev/null 2>&1 || true
sleep 1

rm -rf "$DEV_APP"
cp -R "$SRC_APP" "$DEV_APP"

INFO_PLIST="$DEV_APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$DEV_DISPLAY_NAME" "$INFO_PLIST"
plutil -replace CFBundleName -string "$DEV_DISPLAY_NAME" "$INFO_PLIST"
plutil -replace CFBundleIdentifier -string "$DEV_BUNDLE_ID" "$INFO_PLIST"
plutil -replace SUAutomaticallyUpdate -bool NO "$INFO_PLIST"
plutil -replace SUEnableAutomaticChecks -bool NO "$INFO_PLIST"
xattr -dr com.apple.quarantine "$DEV_APP" >/dev/null 2>&1 || true

codesign_args=(--force --deep)
if [[ -n "${CODESIGN_KEYCHAIN:-}" ]]; then
  codesign_args+=(--keychain "$CODESIGN_KEYCHAIN")
fi
codesign "${codesign_args[@]}" --sign "$SIGN_IDENTITY" "$DEV_APP" >/dev/null
codesign --verify --deep --strict "$DEV_APP"

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$DEV_APP" >/dev/null 2>&1 || true
fi

open "$DEV_APP"
echo "$DEV_APP"
