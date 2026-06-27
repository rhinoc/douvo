#!/usr/bin/env bash
# Generate the Homebrew Cask file for the current Douvo release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAP_DIR="${1:?usage: scripts/update_homebrew_cask.sh <homebrew-tap-dir>}"

: "${VERSION:?VERSION not set}"
: "${SHA256:?SHA256 not set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"

CASK_NAME="${CASK_NAME:-douvo}"
APP_NAME="${APP_NAME:-Douvo}"
DESC="${DESC:-Menu bar speech-to-text app}"
HOMEPAGE="${HOMEPAGE:-https://github.com/${GITHUB_REPOSITORY}}"
DMG_NAME="${DMG_NAME:-douvo-${VERSION}-macos.dmg}"
MIN_MACOS="${MIN_MACOS:-sonoma}"
CASK_VERSION_INTERPOLATION='#{version}'
DMG_NAME_TEMPLATE="${DMG_NAME//$VERSION/__VERSION__}"
DMG_NAME_TEMPLATE="${DMG_NAME_TEMPLATE//__VERSION__/$CASK_VERSION_INTERPOLATION}"

PLIST="$ROOT/Sources/Douvo/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"

mkdir -p "$TAP_DIR/Casks"

cat >"$TAP_DIR/Casks/${CASK_NAME}.rb" <<EOF
cask "${CASK_NAME}" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/${GITHUB_REPOSITORY}/releases/download/v#{version}/${DMG_NAME_TEMPLATE}",
      verified: "github.com/${GITHUB_REPOSITORY}/"
  name "${APP_NAME}"
  desc "${DESC}"
  homepage "${HOMEPAGE}"

  depends_on macos: :${MIN_MACOS}
  depends_on arch: :arm64

  app "${APP_NAME}.app"

  zap trash: [
    "~/Library/Caches/${BUNDLE_ID}",
    "~/Library/HTTPStorages/${BUNDLE_ID}",
    "~/Library/Preferences/${BUNDLE_ID}.plist",
    "~/Library/Saved Application State/${BUNDLE_ID}.savedState",
  ]
end
EOF
