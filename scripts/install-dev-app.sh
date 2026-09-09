#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_APP="$ROOT/.build/release/Douvo.app"
DEV_APP="${DOUVO_DEV_APP_PATH:-/Applications/Douvo Dev.app}"
DEV_BUNDLE_ID="${DOUVO_DEV_BUNDLE_ID:-local.douvo.dev}"
DEV_DISPLAY_NAME="${DOUVO_DEV_DISPLAY_NAME:-Douvo Dev}"
DEV_OPEN="${DOUVO_DEV_OPEN:-1}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

case "$DEV_APP" in
  /Applications/*.app) ;;
  *)
    echo "error: DOUVO_DEV_APP_PATH must point to an app bundle inside /Applications" >&2
    exit 1
    ;;
esac

if [[ "$DEV_APP" == "/Applications/.app" || "$DEV_APP" == "/Applications/"*"/"* ]]; then
  echo "error: invalid DOUVO_DEV_APP_PATH: $DEV_APP" >&2
  exit 1
fi

"$ROOT/scripts/build-app.sh" >/dev/null

if [[ ! -d "$SRC_APP" ]]; then
  echo "error: built app not found at $SRC_APP" >&2
  exit 1
fi

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" && -z "${CODESIGN_KEYCHAIN:-}" ]]; then
  LOCAL_CODESIGN_DIR="${DOUVO_LOCAL_CODESIGN_DIR:-$HOME/Library/Application Support/Douvo/CodeSigning}"
  LOCAL_CODESIGN_KEYCHAIN="${DOUVO_CODESIGN_KEYCHAIN:-$LOCAL_CODESIGN_DIR/douvo-local-code-signing.keychain-db}"
  LOCAL_CODESIGN_PASSWORD_FILE="${DOUVO_LOCAL_CODESIGN_PASSWORD_FILE:-$LOCAL_CODESIGN_DIR/keychain-password}"
  if [[ -f "$LOCAL_CODESIGN_KEYCHAIN" && -f "$LOCAL_CODESIGN_PASSWORD_FILE" ]]; then
    security unlock-keychain -p "$(<"$LOCAL_CODESIGN_PASSWORD_FILE")" "$LOCAL_CODESIGN_KEYCHAIN"
    security set-key-partition-list \
      -S apple-tool:,apple:,codesign: \
      -s \
      -k "$(<"$LOCAL_CODESIGN_PASSWORD_FILE")" \
      "$LOCAL_CODESIGN_KEYCHAIN" >/dev/null 2>&1
    CODESIGN_KEYCHAIN="$LOCAL_CODESIGN_KEYCHAIN"
    LOCAL_CODESIGN_IDENTITY="${DOUVO_LOCAL_CODESIGN_IDENTITY:-Douvo Local Code Signing}"
    if security find-identity -v -p codesigning "$CODESIGN_KEYCHAIN" 2>/dev/null \
      | awk -v name="$LOCAL_CODESIGN_IDENTITY" 'index($0, "\"" name "\"") { found = 1 } END { exit !found }'; then
      SIGN_IDENTITY="$LOCAL_CODESIGN_IDENTITY"
    fi
  fi
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Douvo Local Code Signing/ { print $2; exit }'
  )"
fi

if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
  echo "error: no stable codesigning identity found. Refusing to install an ad-hoc signed dev app." >&2
  echo "Set CODESIGN_IDENTITY or run scripts/ensure-local-code-signing-identity.sh explicitly." >&2
  echo "See docs/dev-local-build.md for contributor setup details." >&2
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

if [[ "$DEV_OPEN" != "0" ]]; then
  open "$DEV_APP"
fi

echo "$DEV_APP"
