#!/usr/bin/env bash
# Bump patch in repo-root VERSION (semver x.y.z). Prints new version to stdout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
current="$(tr -d '[:space:]' <"$VERSION_FILE")"
IFS='.' read -r major minor patch <<<"$current"
if [[ -z "${major:-}" || -z "${minor:-}" || -z "${patch:-}" ]]; then
  echo "VERSION must be semver x.y.z (got '$current')" >&2
  exit 1
fi

new="${major}.${minor}.$((patch + 1))"
printf '%s\n' "$new" >"$VERSION_FILE"

INFO_PLIST="$ROOT/Sources/Douvo/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $new" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $new" "$INFO_PLIST"

printf '%s' "$new"
