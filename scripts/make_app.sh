#!/usr/bin/env bash
#
# make_app.sh — build the release binary with SwiftPM and wrap it into a
# minimal Sublight.app bundle with an ad-hoc code signature.
#
# Why not an .xcodeproj? A hand-maintained project file is fragile in a
# text-first repo; SwiftPM + this script keeps everything reviewable. If you
# prefer Xcode for development, `open Package.swift` works for editing and
# running the CLI; use this script for the bundled menu bar app.
#
# Ad-hoc signing is fine for the machine you built on. To move the app to
# another Mac without Gatekeeper friction, sign with a Developer ID
# certificate and notarize (paid Apple Developer account required) — see
# docs/SPEC.md §10.
#
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build -c release --product SublightApp"
swift build -c release --product SublightApp

BIN=".build/release/SublightApp"
APP="build/Sublight.app"

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/Sublight"
cp scripts/Info.plist "${APP}/Contents/Info.plist"

echo "==> icons"
# The .icns is a GENERATED artifact built from the committed 1024px PNG master
# with tools every Mac ships (sips + iconutil) — no librsvg needed. It lands
# under build/ (gitignored) and is only regenerated when the master changes.
ICON_SRC="assets/icons/sublight-icon-1024.png"
ICON_SET="build/Sublight.iconset"
ICON_OUT="build/Sublight.icns"
if [ ! -f "$ICON_OUT" ] || [ "$ICON_SRC" -nt "$ICON_OUT" ]; then
  rm -rf "$ICON_SET"
  mkdir -p "$ICON_SET"
  for SZ in 16 32 128 256 512; do
    DB=$((SZ * 2))
    sips -z $SZ $SZ "$ICON_SRC" --out "$ICON_SET/icon_${SZ}x${SZ}.png" > /dev/null
    sips -z $DB $DB "$ICON_SRC" --out "$ICON_SET/icon_${SZ}x${SZ}@2x.png" > /dev/null
  done
  iconutil -c icns "$ICON_SET" -o "$ICON_OUT"
fi
mkdir -p "${APP}/Contents/Resources"
cp "$ICON_OUT" "${APP}/Contents/Resources/Sublight.icns"

echo "==> ad-hoc codesign"
/usr/bin/codesign --force --sign - "${APP}"

echo "==> done: ${APP}"
echo "    open ${APP}"
