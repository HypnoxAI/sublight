#!/usr/bin/env bash
# Generate macOS icon assets from the SVG masters.
# Requires: rsvg-convert (brew install librsvg) and iconutil (built into macOS).
set -euo pipefail
cd "$(dirname "$0")"

command -v rsvg-convert >/dev/null || { echo "Need rsvg-convert:  brew install librsvg"; exit 1; }

# 1) App icon → Sublight.icns
ICONSET="Sublight.iconset"
rm -rf "$ICONSET"; mkdir "$ICONSET"
gen() { rsvg-convert -w "$2" -h "$2" sublight-appicon.svg -o "$ICONSET/$1"; }
gen icon_16x16.png       16
gen icon_16x16@2x.png    32
gen icon_32x32.png       32
gen icon_32x32@2x.png    64
gen icon_128x128.png    128
gen icon_128x128@2x.png 256
gen icon_256x256.png    256
gen icon_256x256@2x.png 512
gen icon_512x512.png    512
gen icon_512x512@2x.png 1024
iconutil -c icns "$ICONSET" -o Sublight.icns
echo "wrote Sublight.icns"

# 2) Menu-bar glyph → PNG template.
#
# Deliberately a PNG, not a PDF. The glyph is built from an SVG <mask>, and
# rsvg-convert flattens masks into PDF soft-masks that NSImage does not
# reliably rasterise — the result is a PDF that exists (so no SF Symbol
# fallback) but draws nothing, i.e. an invisible menu bar icon. Rasterising
# here resolves the mask once, at build time, and a template PNG's alpha
# channel is exactly what macOS wants for menu bar tinting.
#
# 36px tall = 2x of the 18pt display size, so it is crisp on Retina.
rsvg-convert -h 32 sublight-menubar.svg -o sublight-menubar-Template.png
SZ=$(wc -c < sublight-menubar-Template.png | tr -d ' ')
if [ "$SZ" -lt 400 ]; then
  echo "WARNING: sublight-menubar-Template.png is only ${SZ} bytes — it may be blank."
else
  echo "wrote sublight-menubar-Template.png (${SZ} bytes)"
fi

# A larger preview for eyeballing the artwork directly.
rsvg-convert -h 96 sublight-menubar.svg -o sublight-menubar-preview.png
echo "wrote sublight-menubar-preview.png (visual check)"

# 3) README hero. A PNG rather than the SVG: GitHub's markdown renderer is
# inconsistent about inline SVG, and a broken hero image is the first thing a
# visitor sees.
rsvg-convert -h 260 sublight-hero-mono.svg -o sublight-hero.png
echo "wrote sublight-hero.png (README)"

# Remove any stale PDF from earlier builds so the app cannot pick it up.
rm -f sublight-menubar-Template.pdf
