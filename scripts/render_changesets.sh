#!/usr/bin/env bash
# Validate pending changesets and render them as user-facing Markdown.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGESET_DIR="${CHANGESET_DIR:-$ROOT/.changeset}"
OUTPUT_PATH="${1:?usage: scripts/render_changesets.sh <output-path>}"

if [[ ! -d "$CHANGESET_DIR" ]]; then
  echo "Missing changeset directory: $CHANGESET_DIR" >&2
  exit 1
fi

added_entries=()
changed_entries=()
fixed_entries=()
# Bash 3.2 treats empty array expansion as unbound when nounset is enabled.
added_count=0
changed_count=0
fixed_count=0

while IFS= read -r changeset; do
  first_line="$(sed -n '1p' "$changeset")"
  type_line="$(sed -n '2p' "$changeset")"
  third_line="$(sed -n '3p' "$changeset")"

  if [[ "$first_line" != "---" || "$third_line" != "---" ]]; then
    echo "Invalid changeset front matter: $changeset" >&2
    exit 1
  fi

  summary="$(
    awk '
      NR >= 4 && $0 !~ /^[[:space:]]*$/ {
        count += 1
        if (count == 1) line = $0
      }
      END {
        if (count != 1) exit 1
        print line
      }
    ' "$changeset"
  )" || {
    echo "Changeset must contain exactly one non-empty summary line: $changeset" >&2
    exit 1
  }

  summary="$(printf '%s' "$summary" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [[ "$summary" == "- "* || "$summary" == "* "* ]]; then
    echo "Changeset summary must not include a Markdown list marker: $changeset" >&2
    exit 1
  fi
  if ! printf '%s' "$summary" | LC_ALL=C grep -Eq '^[ -~]+$'; then
    echo "Changeset summary must use ASCII English: $changeset" >&2
    exit 1
  fi

  case "$type_line" in
    "type: added")
      added_entries+=("$summary")
      ((added_count += 1))
      ;;
    "type: changed")
      changed_entries+=("$summary")
      ((changed_count += 1))
      ;;
    "type: fixed")
      fixed_entries+=("$summary")
      ((fixed_count += 1))
      ;;
    *)
      echo "Unsupported changeset type in $changeset: $type_line" >&2
      exit 1
      ;;
  esac
done < <(find "$CHANGESET_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' -print | LC_ALL=C sort)

mkdir -p "$(dirname "$OUTPUT_PATH")"

render_section() {
  local title="$1"
  shift
  (( $# > 0 )) || return 0

  printf '## %s\n\n' "$title"
  local entry
  for entry in "$@"; do
    printf -- '- %s\n' "$entry"
  done
  printf '\n'
}

{
  if (( added_count > 0 )); then
    render_section "Added" "${added_entries[@]}"
  fi
  if (( changed_count > 0 )); then
    render_section "Changed" "${changed_entries[@]}"
  fi
  if (( fixed_count > 0 )); then
    render_section "Fixed" "${fixed_entries[@]}"
  fi
} >"$OUTPUT_PATH"
