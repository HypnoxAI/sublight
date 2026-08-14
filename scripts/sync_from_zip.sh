#!/usr/bin/env bash
#
# sync_from_zip.sh — sync an extracted update from ~/Downloads/sublight/ into
# this repo for review. Nothing is committed; review the diff first.
#
# Exclusions: .git, .build, and build are local state that must survive the
# sync. The icon binaries (Sublight.icns, Sublight.iconset,
# sublight-menubar-Template.png, sublight-menubar-preview.png) are generated
# locally by assets/icons/make_icons.sh and absent from upstream zips.
# sublight-hero.png is the same story with higher stakes: generated locally,
# committed because the README embeds it, and absent from upstream zips — so
# without the exclusion, rsync --delete would remove it and break the README.
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
    --exclude 'assets/icons/Sublight.icns' \
    --exclude 'assets/icons/Sublight.iconset' \
    --exclude 'assets/icons/sublight-menubar-Template.png' \
    --exclude 'assets/icons/sublight-menubar-preview.png' \
    --exclude 'assets/icons/sublight-hero.png' \
    "${SRC}" .

echo
echo "==> git diff --stat"
git diff --stat

echo
echo "Review the diff (git diff) before committing anything."
