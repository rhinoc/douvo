#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/douvo-changeset-tests.XXXXXX)"
CHANGESET_DIR="$TEST_ROOT/.changeset"
OUTPUT_PATH="$TEST_ROOT/release-notes.md"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$CHANGESET_DIR"
printf '# Changesets\n' >"$CHANGESET_DIR/README.md"
printf '%s\n' '---' 'type: fixed' '---' '' 'Fix a broken download.' >"$CHANGESET_DIR/fix-download.md"
printf '%s\n' '---' 'type: added' '---' '' 'Add release notes.' >"$CHANGESET_DIR/add-release-notes.md"

CHANGESET_DIR="$CHANGESET_DIR" "$ROOT/scripts/render_changesets.sh" "$OUTPUT_PATH"
expected="$TEST_ROOT/expected.md"
printf '%s\n' \
  '## Added' \
  '' \
  '- Add release notes.' \
  '' \
  '## Fixed' \
  '' \
  '- Fix a broken download.' \
  '' >"$expected"
diff -u "$expected" "$OUTPUT_PATH"

CHANGESET_DIR="$CHANGESET_DIR" "$ROOT/scripts/consume_changesets.sh"
test -f "$CHANGESET_DIR/README.md"
test ! -e "$CHANGESET_DIR/fix-download.md"
test ! -e "$CHANGESET_DIR/add-release-notes.md"

CHANGESET_DIR="$CHANGESET_DIR" "$ROOT/scripts/render_changesets.sh" "$OUTPUT_PATH"
test ! -s "$OUTPUT_PATH"

printf '%s\n' '---' 'type: unsupported' '---' '' 'Invalid type.' >"$CHANGESET_DIR/invalid-type.md"
if CHANGESET_DIR="$CHANGESET_DIR" "$ROOT/scripts/render_changesets.sh" "$OUTPUT_PATH" 2>/dev/null; then
  echo "Expected an unsupported changeset type to fail validation." >&2
  exit 1
fi
rm -f -- "$CHANGESET_DIR/invalid-type.md"

printf '%s\n' '---' 'type: changed' '---' '' 'First line.' 'Second line.' >"$CHANGESET_DIR/multiple-lines.md"
if CHANGESET_DIR="$CHANGESET_DIR" "$ROOT/scripts/render_changesets.sh" "$OUTPUT_PATH" 2>/dev/null; then
  echo "Expected a multi-line changeset summary to fail validation." >&2
  exit 1
fi
rm -f -- "$CHANGESET_DIR/multiple-lines.md"

printf '%s\n' '---' 'type: fixed' '---' '' '修复更新提示。' >"$CHANGESET_DIR/non-english.md"
if CHANGESET_DIR="$CHANGESET_DIR" "$ROOT/scripts/render_changesets.sh" "$OUTPUT_PATH" 2>/dev/null; then
  echo "Expected a non-English changeset summary to fail validation." >&2
  exit 1
fi
