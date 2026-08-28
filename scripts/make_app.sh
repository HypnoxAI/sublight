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
# docs/PACKAGING.md. This script never embeds a certificate or password.
#
# Git identity is stamped into Info.plist (SublightGitRevision) from
# `git rev-parse HEAD` at bundle time. Do not put a SHA in source.
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

# Stamp the version from the Swift constant so the bundle and the code can
# never disagree — a wrong version in a bug report costs more to chase than
# this line costs to maintain.
VERSION_SRC="Sources/SublightKit/SublightVersion.swift"
MARKETING=$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' "$VERSION_SRC")
BUILDNUM=$(sed -n 's/.*static let build = "\([^"]*\)".*/\1/p' "$VERSION_SRC")
if [ -z "$MARKETING" ] || [ -z "$BUILDNUM" ]; then
  echo "error: could not read the version from $VERSION_SRC" >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING" \
  "${APP}/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILDNUM" \
  "${APP}/Contents/Info.plist" >/dev/null

# Git identity at BUNDLE time, never a SHA in source. A rebuilt app must be
# distinguishable from yesterday's binary; marketing version alone is not.
GITREV="unknown"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GITREV=$(git rev-parse HEAD)
  if ! git diff --quiet --ignore-submodules HEAD 2>/dev/null \
    || ! git diff --cached --quiet --ignore-submodules 2>/dev/null; then
    GITREV="${GITREV}-dirty"
  fi
fi
if ! /usr/libexec/PlistBuddy -c "Set :SublightGitRevision $GITREV" \
  "${APP}/Contents/Info.plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Add :SublightGitRevision string $GITREV" \
    "${APP}/Contents/Info.plist" >/dev/null
fi
echo "==> version ${MARKETING} (${BUILDNUM})  git ${GITREV}"

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
