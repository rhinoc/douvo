#!/usr/bin/env bash
# Build a signed Douvo.app and wrap it in a drag-to-Applications DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_OUTPUT="$("$ROOT/scripts/build-app.sh")"
printf '%s\n' "$APP_OUTPUT" >&2
APP="$(printf '%s\n' "$APP_OUTPUT" | tail -n 1)"
if [[ ! -d "$APP" ]]; then
  echo "error: app bundle was not created at $APP" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG_NAME="douvo-${VERSION}-macos.dmg"
DIST="$ROOT/dist"
DMG="$DIST/$DMG_NAME"
DMG_BACKGROUND="$ROOT/assets/douvo.png"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if [[ ! -f "$DMG_BACKGROUND" ]]; then
  echo "error: missing DMG background at $DMG_BACKGROUND" >&2
  exit 1
fi

mkdir -p "$DIST"
rm -f "$DMG"

DMG_BACKGROUND_COPY="$STAGE/dmg-background.png"
DMG_BACKGROUND_RETINA_COPY="$STAGE/dmg-background@2x.png"
sips -z 373 661 "$DMG_BACKGROUND" --out "$DMG_BACKGROUND_COPY" >/dev/null
sips -z 746 1322 "$DMG_BACKGROUND" --out "$DMG_BACKGROUND_RETINA_COPY" >/dev/null
sips -s dpiWidth 72 -s dpiHeight 72 "$DMG_BACKGROUND_COPY" >/dev/null
sips -s dpiWidth 144 -s dpiHeight 144 "$DMG_BACKGROUND_RETINA_COPY" >/dev/null

APPDMG_JSON="$STAGE/appdmg.json"
cat >"$APPDMG_JSON" <<EOF
{
  "title": "Douvo",
  "background": "$DMG_BACKGROUND_COPY",
  "icon-size": 80,
  "window": {
    "position": { "x": 120, "y": 559 },
    "size": { "width": 661, "height": 379 }
  },
  "format": "UDZO",
  "filesystem": "HFS+",
  "contents": [
    { "x": 180, "y": 197, "type": "file", "path": "$APP" },
    { "x": 480, "y": 197, "type": "link", "path": "/Applications" }
  ]
}
EOF

npx --yes --cache "$STAGE/npm-cache" "appdmg@${APPDMG_VERSION:-0.6.6}" "$APPDMG_JSON" "$DMG" >&2

echo "$DMG"
