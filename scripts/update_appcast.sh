#!/usr/bin/env bash
# Append a Sparkle <item> for the current release DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${VERSION:?VERSION not set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
: "${SPARKLE_ED_PRIVATE_KEY:?SPARKLE_ED_PRIVATE_KEY not set}"

DMG_NAME="douvo-${VERSION}-macos.dmg"
DMG_PATH="$ROOT/dist/$DMG_NAME"
if [[ ! -f "$DMG_PATH" ]]; then
  echo "Missing DMG at $DMG_PATH" >&2
  exit 1
fi

SPARKLE_VER="${SPARKLE_RELEASE_VERSION:-2.9.3}"
TOOLS="${RUNNER_TEMP:-/tmp}/sparkle-sign-${SPARKLE_VER}"
mkdir -p "$TOOLS"
SIGN_UPDATE="$(find "$TOOLS" -type f -path '*/bin/sign_update' 2>/dev/null | head -n1 || true)"
if [[ -z "$SIGN_UPDATE" || ! -x "$SIGN_UPDATE" ]]; then
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VER}/Sparkle-${SPARKLE_VER}.tar.xz" \
    | tar -xJ -C "$TOOLS"
  SIGN_UPDATE="$(find "$TOOLS" -type f -path '*/bin/sign_update' | head -n1)"
fi
if [[ -z "$SIGN_UPDATE" || ! -x "$SIGN_UPDATE" ]]; then
  echo "Could not locate sign_update under $TOOLS" >&2
  exit 1
fi

ed_sig_length="$(printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$DMG_PATH" | tr -d '\n')"
date="$(LC_ALL=C date +'%a, %d %b %Y %H:%M:%S %z')"
url="https://github.com/${GITHUB_REPOSITORY}/releases/download/v${VERSION}/${DMG_NAME}"

tmp="$(mktemp)"
cat >"$tmp" <<EOF

    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${VERSION}</sparkle:version>
      <pubDate>${date}</pubDate>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure
        url="${url}"
        ${ed_sig_length}
        type="application/octet-stream"/>
    </item>
EOF

sed -i '' -e "/<\\/language>/r $tmp" appcast.xml
rm -f "$tmp"
