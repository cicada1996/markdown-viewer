#!/bin/bash
# Renders Resources/icon.svg into Resources/AppIcon.icns using only
# built-in macOS tools (QuickLook + iconutil).
set -euo pipefail
cd "$(dirname "$0")"

TMP="build/icon-tmp"
ICONSET="$TMP/AppIcon.iconset"
rm -rf "$TMP"
mkdir -p "$ICONSET"

render() {
    qlmanage -t -s "$1" -o "$TMP" Resources/icon.svg >/dev/null 2>&1
    mv "$TMP/icon.svg.png" "$ICONSET/$2"
}

render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil --convert icns --output Resources/AppIcon.icns "$ICONSET"
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns"
