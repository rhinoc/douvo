#!/usr/bin/env bash
# Commit VERSION and appcast changes after release. The chore message skips release reruns.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(tr -d '[:space:]' <VERSION)"

git config user.name github-actions
git config user.email github-actions@github.com
git add VERSION Sources/Douvo/Info.plist appcast.xml
git commit -m "chore: auto release $VERSION"
git push
