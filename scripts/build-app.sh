#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

timer_now() {
  date +%s
}

log_timing() {
  local label="$1"
  local started_at="$2"
  local ended_at
  ended_at="$(timer_now)"
  printf 'release-timing: %s duration=%ss\n' "$label" "$((ended_at - started_at))" >&2
}

TOTAL_STARTED_AT="$(timer_now)"
SWIFT_BUILD_STARTED_AT="$(timer_now)"
swift build -c release --product Douvo
log_timing "swift release build" "$SWIFT_BUILD_STARTED_AT"

MLX_METALLIB_STARTED_AT="$(timer_now)"
"$ROOT/scripts/build-mlx-metallib.sh" release >/dev/null
log_timing "build mlx metallib" "$MLX_METALLIB_STARTED_AT"

APP="$ROOT/.build/release/Douvo.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
BIN="$ROOT/.build/release/Douvo"
SPARKLE_FW="$(dirname "$BIN")/Sparkle.framework"
PLIST_SRC="$ROOT/Sources/Douvo/Info.plist"

ASSEMBLE_STARTED_AT="$(timer_now)"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"
cp "$BIN" "$MACOS/Douvo"
cp "$PLIST_SRC" "$CONTENTS/Info.plist"
cp "$ROOT/assets/Douvo.icns" "$RESOURCES/Douvo.icns"

MLX_METALLIB="$(dirname "$BIN")/default.metallib"
if [[ ! -f "$MLX_METALLIB" ]]; then
  echo "error: MLX metallib not found (expected: $MLX_METALLIB)" >&2
  exit 1
fi
cp "$MLX_METALLIB" "$MACOS/default.metallib"
cp "$MLX_METALLIB" "$MACOS/mlx.metallib"
cp "$MLX_METALLIB" "$RESOURCES/default.metallib"
cp "$MLX_METALLIB" "$RESOURCES/mlx.metallib"
mkdir -p "$RESOURCES/mlx-swift_Cmlx.bundle"
cp "$MLX_METALLIB" "$RESOURCES/mlx-swift_Cmlx.bundle/default.metallib"

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
log_timing "assemble app bundle" "$ASSEMBLE_STARTED_AT"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Douvo Local Code Signing/ { print $2; exit }'
  )"
fi

if [[ -z "$CODESIGN_IDENTITY" && -z "${CODESIGN_KEYCHAIN:-}" ]]; then
  LOCAL_CODESIGN_DIR="${DOUVO_LOCAL_CODESIGN_DIR:-$HOME/Library/Application Support/Douvo/CodeSigning}"
  LOCAL_CODESIGN_KEYCHAIN="${DOUVO_CODESIGN_KEYCHAIN:-$LOCAL_CODESIGN_DIR/douvo-local-code-signing.keychain-db}"
  LOCAL_CODESIGN_PASSWORD_FILE="${DOUVO_LOCAL_CODESIGN_PASSWORD_FILE:-$LOCAL_CODESIGN_DIR/keychain-password}"
  if [[ -f "$LOCAL_CODESIGN_KEYCHAIN" && -f "$LOCAL_CODESIGN_PASSWORD_FILE" ]]; then
    security unlock-keychain -p "$(<"$LOCAL_CODESIGN_PASSWORD_FILE")" "$LOCAL_CODESIGN_KEYCHAIN"
    CODESIGN_KEYCHAIN="$LOCAL_CODESIGN_KEYCHAIN"
    CODESIGN_IDENTITY="$(
      security find-identity -v -p codesigning "$CODESIGN_KEYCHAIN" 2>/dev/null \
        | awk -F'"' '/Douvo Local Code Signing/ { print $1; exit }' \
        | awk '{ print $2 }'
    )"
  fi
fi

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "error: ad-hoc signing is not supported for Douvo app bundles." >&2
  echo "Use a stable local identity. Run scripts/ensure-local-code-signing-identity.sh explicitly if you want the repo to create one." >&2
  exit 1
elif [[ -n "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_STARTED_AT="$(timer_now)"
  codesign_args=(--force --deep)
  if [[ -n "${CODESIGN_KEYCHAIN:-}" ]]; then
    codesign_args+=(--keychain "$CODESIGN_KEYCHAIN")
  fi
  codesign "${codesign_args[@]}" --sign "$CODESIGN_IDENTITY" "$APP" >/dev/null
  log_timing "codesign app bundle" "$CODESIGN_STARTED_AT"
else
  echo "error: no codesigning identity found. Refusing to build an ad-hoc signed app." >&2
  echo "Set CODESIGN_IDENTITY or run scripts/ensure-local-code-signing-identity.sh explicitly." >&2
  echo "See docs/dev-local-build.md for contributor setup details." >&2
  exit 1
fi
log_timing "build app total" "$TOTAL_STARTED_AT"
echo "$APP"
