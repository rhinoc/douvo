#!/usr/bin/env bash
# Delete pending changesets after all release artifacts have been published.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGESET_DIR="${CHANGESET_DIR:-$ROOT/.changeset}"
changesets=()

while IFS= read -r changeset; do
  changesets+=("$changeset")
done < <(find "$CHANGESET_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' -print | LC_ALL=C sort)

if (( ${#changesets[@]} == 0 )); then
  echo "No pending changesets to consume." >&2
  exit 1
fi

for changeset in "${changesets[@]}"; do
  case "$changeset" in
    "$CHANGESET_DIR"/*.md)
      rm -f -- "$changeset"
      ;;
    *)
      echo "Refusing to remove unexpected path: $changeset" >&2
      exit 1
      ;;
  esac
done
