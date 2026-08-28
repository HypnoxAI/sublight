#!/usr/bin/env bash
#
# make_dmg.sh — wrap build/Sublight.app (from make_app.sh) into a DMG.
#
# macOS only. The Cursor cloud VM is Linux and cannot codesign, notarize, or
# run hdiutil — this script exits 1 there with a pointer at docs/PACKAGING.md.
#
# Local path (default): keep the ad-hoc signature make_app.sh already applied.
# Shareable path: pass --sign (and optionally --notarize) with an identity the
# OPERATOR supplies. Never a cert or password in this repo.
#
#   ./scripts/make_app.sh
#   ./scripts/make_dmg.sh
#   ./scripts/make_dmg.sh --sign
#   ./scripts/make_dmg.sh --sign --notarize
#
# Identity, in order:
#   1. SUBLIGHT_SIGN_IDENTITY  (env — "Developer ID Application: Name (TEAMID)")
#   2. `security find-identity -v -p codesigning` if exactly one Developer ID
#      Application identity is present
#   otherwise --sign fails and lists what was found.
#
# Notarization uses a notarytool keychain profile, not a password in the
# environment of this script:
#   SUBLIGHT_NOTARY_PROFILE   (default: sublight-notary)
#   xcrun notarytool store-credentials "$SUBLIGHT_NOTARY_PROFILE"   # once
#
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: DMG packaging requires macOS (hdiutil / codesign / notarytool)." >&2
  echo "This host is $(uname -s). Ad-hoc signing lives in scripts/make_app.sh;" >&2
  echo "Developer ID + notarize is documented in docs/PACKAGING.md." >&2
  echo "This script does not invent Apple credentials and will not run here." >&2
  exit 1
fi

SIGN=0
NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --sign) SIGN=1 ;;
    --notarize) NOTARIZE=1; SIGN=1 ;;
    --help|-h)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "usage: $0 [--sign] [--notarize]" >&2
      exit 1
      ;;
  esac
done

APP="build/Sublight.app"
if [ ! -d "$APP" ]; then
  echo "error: ${APP} not found. Run ./scripts/make_app.sh first." >&2
  exit 1
fi

VERSION_SRC="Sources/SublightKit/SublightVersion.swift"
MARKETING=$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' "$VERSION_SRC")
BUILDNUM=$(sed -n 's/.*static let build = "\([^"]*\)".*/\1/p' "$VERSION_SRC")
DMG="build/Sublight-${MARKETING}-${BUILDNUM}.dmg"
VOL="Sublight ${MARKETING}"
STAGING="build/dmg-staging"

resolve_identity() {
  if [ -n "${SUBLIGHT_SIGN_IDENTITY:-}" ]; then
    echo "$SUBLIGHT_SIGN_IDENTITY"
    return 0
  fi
  # `security find-identity` prints "hash \"Name (TEAMID)\"". We want the
  # quoted name so codesign --sign can consume it. Exactly one Developer ID
  # Application identity is unambiguous; anything else must be chosen by hand.
  local lines
  lines=$(security find-identity -v -p codesigning | grep "Developer ID Application:" || true)
  local count
  count=$(printf '%s\n' "$lines" | grep -c "Developer ID Application:" || true)
  if [ "$count" = "1" ]; then
    printf '%s\n' "$lines" | sed -n 's/.*"\(Developer ID Application: .*\)".*/\1/p'
    return 0
  fi
  echo "error: set SUBLIGHT_SIGN_IDENTITY to a Developer ID Application identity." >&2
  echo "Found ${count} matching identities:" >&2
  security find-identity -v -p codesigning >&2 || true
  echo "Example: export SUBLIGHT_SIGN_IDENTITY='Developer ID Application: Name (TEAMID)'" >&2
  return 1
}

if [ "$SIGN" = "1" ]; then
  IDENTITY=$(resolve_identity)
  echo "==> Developer ID sign with: ${IDENTITY}"
  # Hardened Runtime is required for notarization. Ad-hoc (make_app.sh) does
  # not set it; this is the shareable path replacing that signature.
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo "==> assembling ${DMG}"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/Sublight.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
# RW then convert so the Applications symlink survives compression.
SCRATCH="build/Sublight-scratch.dmg"
rm -f "$SCRATCH"
hdiutil create -volname "$VOL" -srcfolder "$STAGING" -ov -format UDRW "$SCRATCH" >/dev/null
hdiutil convert "$SCRATCH" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$SCRATCH"
rm -rf "$STAGING"

if [ "$SIGN" = "1" ]; then
  echo "==> signing DMG"
  /usr/bin/codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

if [ "$NOTARIZE" = "1" ]; then
  PROFILE="${SUBLIGHT_NOTARY_PROFILE:-sublight-notary}"
  echo "==> notarize with keychain profile '${PROFILE}'"
  echo "    (create once: xcrun notarytool store-credentials ${PROFILE})"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  echo "==> staple"
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
fi

echo "==> done: ${DMG}"
echo "    open ${DMG}"
