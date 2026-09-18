#!/bin/zsh
# scripts/make-icon.sh — regenerate the app icon set from docs/design/AppIcon.png.
#
# Writes every macOS size (16…512 pt at 1x and 2x) into
# Sources/DebrisApp/Resources/Assets.xcassets/AppIcon.appiconset and an
# AppIcon.icns next to it in build/ for anything that wants a plain .icns.
# Only sips and iconutil are used, so it runs on any Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=docs/design/AppIcon.png
SET=Sources/DebrisApp/Resources/Assets.xcassets/AppIcon.appiconset
ICONSET=build/AppIcon.iconset
mkdir -p "$SET" "$ICONSET"
entries=()
for pt in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((pt * scale))
    name="icon_${pt}x${pt}@${scale}x.png"
    sips -z "$px" "$px" "$SRC" --out "$SET/$name" >/dev/null
    cp "$SET/$name" "$ICONSET/$name"
    entries+=("    { \"filename\" : \"$name\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${pt}x${pt}\" }")
  done
done
{
  echo '{'
  echo '  "images" : ['
  printf '%s,\n' "${entries[@]}" | sed '$ s/,$//'
  echo '  ],'
  echo '  "info" : { "author" : "xcode", "version" : 1 }'
  echo '}'
} > "$SET/Contents.json"
iconutil -c icns "$ICONSET" -o build/AppIcon.icns
echo "icon set: $SET"
echo "icns:     build/AppIcon.icns"
