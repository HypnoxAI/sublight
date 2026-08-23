#!/usr/bin/env bash
#
# capture_screenshots.sh — timed full-screen captures for the README gallery.
#
# Full-screen and timed on purpose. A menu bar popover closes the instant it
# loses focus, so an interactive capture ("select a window") cannot photograph
# one; a countdown lets you open the popover, pose it, and step back. Every
# shot is captured whole at the display's native Retina resolution and cropped
# afterwards, so the crop is reproducible and the source frame is kept.
#
# macOS requires Screen Recording permission for whichever app runs this. If
# the output looks like an empty desktop, that permission is missing: grant it
# in System Settings → Privacy & Security → Screen Recording and re-run.
#
# Usage:  scripts/capture_screenshots.sh <name> [delay-seconds]
# Output: build/screenshots/<name>.png   (gitignored working directory)
#
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Hypnox Technologies LLC

set -euo pipefail

name="${1:-}"
delay="${2:-8}"
out_dir="${SUBLIGHT_SHOT_DIR:-build/screenshots}"

if [ -z "$name" ]; then
  echo "usage: scripts/capture_screenshots.sh <name> [delay-seconds]" >&2
  exit 1
fi

mkdir -p "$out_dir"
path="$out_dir/$name.png"

echo "Capturing '$name' in ${delay}s — pose the screen now."
for i in $(seq "$delay" -1 1); do
  printf '\r  %2ds …' "$i"
  sleep 1
done
printf '\r        \r'

screencapture -x "$path"

if [ ! -s "$path" ]; then
  echo "error: no image was written to $path" >&2
  exit 2
fi

echo "wrote $path"
if command -v sips >/dev/null; then
  sips -g pixelWidth -g pixelHeight "$path" 2>/dev/null | tail -2 | sed 's/^/  /'
fi
