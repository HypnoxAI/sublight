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
# The .icns and the menu-bar template PDF are GENERATED artifacts — they are
# not checked in, so a fresh clone or a re-extracted archive won't have them
# and the app would silently fall back to an SF Symbol. Generate them here
# instead of relying on the human remembering a separate command.
if [ ! -f assets/icons/Sublight.icns ] || [ ! -f assets/icons/sublight-menubar-Template.png ]; then
  if command -v rsvg-convert >/dev/null 2>&1; then
    echo "    generating icon assets…"
    bash assets/icons/make_icons.sh || echo "    (icon generation failed — continuing with SF Symbol fallback)"
  else
    echo "    rsvg-convert not found — install with:  brew install librsvg"
    echo "    (continuing; the app will use an SF Symbol fallback)"
  fi
fi

if [ -f assets/icons/Sublight.icns ]; then
  cp assets/icons/Sublight.icns "${APP}/Contents/Resources/Sublight.icns"
else
  echo "    (no Sublight.icns — run assets/icons/make_icons.sh to generate)"
fi
if [ -f assets/icons/sublight-menubar-Template.png ]; then
  cp assets/icons/sublight-menubar-Template.png "${APP}/Contents/Resources/"
else
  echo "    (no menu-bar template — app will fall back to an SF Symbol)"
fi

echo "==> ad-hoc codesign"
/usr/bin/codesign --force --sign - "${APP}"

echo "==> done: ${APP}"
echo "    open ${APP}"
