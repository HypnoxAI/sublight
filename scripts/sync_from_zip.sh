#!/usr/bin/env bash
#
# sync_from_zip.sh — sync an extracted update from ~/Downloads/sublight/ into
# this repo for review. Nothing is committed; review the diff first.
#
# Exclusions: .git, .build, and build are local state that must survive the
# sync (build/ also holds the generated Sublight.icns and iconset, which
# make_app.sh regenerates from the committed PNG master).
#
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${HOME}/Downloads/sublight/"

if [ ! -d "${SRC}" ]; then
    echo "error: ${SRC} not found — extract the zip there first" >&2
    exit 1
fi

echo "==> rsync ${SRC} -> $(pwd)"
rsync -a --delete \
    --exclude '.git' \
    --exclude '.build' \
    --exclude 'build' \
    "${SRC}" .

echo
echo "==> git diff --stat"
git diff --stat

echo
echo "Review the diff (git diff) before committing anything."
