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
CONFIG="${1:-debug}"
case "$CONFIG" in
  debug|release) ;;
  *)
    echo "error: config must be debug or release (got: $CONFIG)" >&2
    exit 1
    ;;
esac

MLX_SWIFT_DIR="${MLX_SWIFT_DIR:-$ROOT/.build/checkouts/mlx-swift}"
METAL_DIR="${MLX_METAL_SOURCE_DIR:-$MLX_SWIFT_DIR/Source/Cmlx/mlx-generated/metal}"

if [[ ! -d "$METAL_DIR" ]]; then
  echo "error: MLX generated Metal sources not found: $METAL_DIR" >&2
  echo "Run 'swift package resolve' or 'swift build --product Douvo' first." >&2
  exit 1
fi

SHOW_BIN_PATH_STARTED_AT="$(timer_now)"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
log_timing "resolve $CONFIG bin path for mlx metallib" "$SHOW_BIN_PATH_STARTED_AT"
RESOURCE_BUNDLE_DIR="$ROOT/Sources/Douvo/Resources/mlx-swift_Cmlx.bundle"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DISCOVER_SOURCES_STARTED_AT="$(timer_now)"
sources=()
while IFS= read -r source; do
  sources+=("$source")
done < <(find "$METAL_DIR" -name '*.metal' | sort)
log_timing "discover mlx metal sources count=${#sources[@]}" "$DISCOVER_SOURCES_STARTED_AT"

if [[ "${#sources[@]}" -eq 0 ]]; then
  echo "error: no MLX Metal source files found in $METAL_DIR" >&2
  exit 1
fi

air_files=()
COMPILE_METAL_STARTED_AT="$(timer_now)"
for source in "${sources[@]}"; do
  relative="${source#$METAL_DIR/}"
  air_name="$(printf "%s" "$relative" | sed 's#[/.]#_#g').air"
  air_path="$TMP_DIR/$air_name"
  xcrun -sdk macosx metal \
    -x metal \
    -Wall \
    -Wextra \
    -fno-fast-math \
    -Wno-c++17-extensions \
    -Wno-c++20-extensions \
    -mmacosx-version-min=14.0 \
    -c "$source" \
    -I"$METAL_DIR" \
    -o "$air_path"
  air_files+=("$air_path")
done
log_timing "compile mlx metal sources count=${#sources[@]}" "$COMPILE_METAL_STARTED_AT"

LINK_METALLIB_STARTED_AT="$(timer_now)"
xcrun -sdk macosx metallib "${air_files[@]}" -o "$TMP_DIR/default.metallib"
log_timing "link mlx metallib" "$LINK_METALLIB_STARTED_AT"

COPY_METALLIB_STARTED_AT="$(timer_now)"
mkdir -p "$BIN_DIR/mlx-swift_Cmlx.bundle"
mkdir -p "$RESOURCE_BUNDLE_DIR"
cp "$TMP_DIR/default.metallib" "$BIN_DIR/default.metallib"
cp "$TMP_DIR/default.metallib" "$BIN_DIR/mlx.metallib"
cp "$TMP_DIR/default.metallib" "$BIN_DIR/mlx-swift_Cmlx.bundle/default.metallib"
cp "$TMP_DIR/default.metallib" "$RESOURCE_BUNDLE_DIR/default.metallib"
log_timing "copy mlx metallib outputs" "$COPY_METALLIB_STARTED_AT"
log_timing "build mlx metallib total" "$TOTAL_STARTED_AT"

echo "$BIN_DIR/default.metallib"
