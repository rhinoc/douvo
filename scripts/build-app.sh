#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c release --product Douvo

APP="$ROOT/.build/release/Douvo.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
BIN="$ROOT/.build/release/Douvo"
SPARKLE_FW="$(dirname "$BIN")/Sparkle.framework"
PLIST_SRC="$ROOT/Sources/Douvo/Info.plist"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"
cp "$BIN" "$MACOS/Douvo"
cp "$PLIST_SRC" "$CONTENTS/Info.plist"
cp "$ROOT/assets/Douvo.icns" "$RESOURCES/Douvo.icns"
RESOURCE_BUNDLE="$(dirname "$BIN")/Douvo_Douvo.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "error: resource bundle not found (expected: $RESOURCE_BUNDLE)" >&2
  exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$RESOURCES/"

if [[ ! -d "$SPARKLE_FW" ]]; then
  echo "error: Sparkle.framework not found next to release binary (expected: $SPARKLE_FW)" >&2
  exit 1
fi
cp -R "$SPARKLE_FW" "$FRAMEWORKS/"
install_name_tool -add_rpath @executable_path/../Frameworks "$MACOS/Douvo" 2>/dev/null || true

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Douvo Local Code Signing/ { print $2; exit }'
  )"
fi

if [[ -n "$CODESIGN_IDENTITY" ]]; then
  codesign_args=(--force --deep)
  if [[ -n "${CODESIGN_KEYCHAIN:-}" ]]; then
    codesign_args+=(--keychain "$CODESIGN_KEYCHAIN")
  fi
  codesign "${codesign_args[@]}" --sign "$CODESIGN_IDENTITY" "$APP" >/dev/null
else
  echo "error: no codesigning identity found. Refusing to build an ad-hoc signed app." >&2
  echo "Set CODESIGN_IDENTITY or install 'Douvo Local Code Signing'." >&2
  exit 1
fi
echo "$APP"
