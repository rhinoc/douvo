#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

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

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
RESOURCE_BUNDLE_DIR="$ROOT/Sources/Douvo/Resources/mlx-swift_Cmlx.bundle"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

sources=()
while IFS= read -r source; do
  sources+=("$source")
done < <(find "$METAL_DIR" -name '*.metal' | sort)

if [[ "${#sources[@]}" -eq 0 ]]; then
  echo "error: no MLX Metal source files found in $METAL_DIR" >&2
  exit 1
fi

air_files=()
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

xcrun -sdk macosx metallib "${air_files[@]}" -o "$TMP_DIR/default.metallib"

mkdir -p "$BIN_DIR/mlx-swift_Cmlx.bundle"
mkdir -p "$RESOURCE_BUNDLE_DIR"
cp "$TMP_DIR/default.metallib" "$BIN_DIR/default.metallib"
cp "$TMP_DIR/default.metallib" "$BIN_DIR/mlx.metallib"
cp "$TMP_DIR/default.metallib" "$BIN_DIR/mlx-swift_Cmlx.bundle/default.metallib"
cp "$TMP_DIR/default.metallib" "$RESOURCE_BUNDLE_DIR/default.metallib"

echo "$BIN_DIR/default.metallib"
