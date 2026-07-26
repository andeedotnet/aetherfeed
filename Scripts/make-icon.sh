#!/bin/zsh
# Creates Resources/AppIcon.icns from the rendered 1024px PNG (sips + iconutil).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! swift --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

PNG=Resources/icon-1024.png
swift Scripts/render-icon.swift "$PNG"

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "OK: Resources/AppIcon.icns"
