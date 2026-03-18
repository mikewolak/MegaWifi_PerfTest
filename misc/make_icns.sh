#!/bin/bash
# make_icns.sh — Generate AppIcon.icns from a source PNG
#
# Creates all required icon sizes for macOS app bundles:
#   16x16, 32x32, 64x64, 128x128, 256x256, 512x512, 1024x1024
#   plus @2x variants (32, 64, 128, 256, 512, 1024)
#
# Usage:
#   ./make_icns.sh [input.png] [output.icns]
#
# Defaults: ../mac-app/mega.png → ../mac-app/Resources/AppIcon.icns
# Requires: sips, iconutil (macOS built-in)

set -e

INPUT="${1:-../mac-app/mega.png}"
OUTPUT="${2:-../mac-app/Resources/AppIcon.icns}"

ICONSET=$(mktemp -d)/AppIcon.iconset

mkdir -p "$ICONSET"

sips -z   16   16 "$INPUT" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z   32   32 "$INPUT" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z   32   32 "$INPUT" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z   64   64 "$INPUT" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z  128  128 "$INPUT" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z  256  256 "$INPUT" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z  256  256 "$INPUT" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z  512  512 "$INPUT" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z  512  512 "$INPUT" --out "$ICONSET/icon_512x512.png"    >/dev/null
sips -z 1024 1024 "$INPUT" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET" -o "$OUTPUT"
rm -rf "$(dirname "$ICONSET")"

echo "Wrote $OUTPUT"
