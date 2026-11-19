#!/usr/bin/env bash
# Render the Steam library art from art.html with headless Chrome (macOS).
# Output: portrait.png, landscape.png, hero.png, logo.png, icon.png here.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

shot() {
  local asset=$1 w=$2 h=$3 scale=$4

  # The new headless mode counts window chrome in --window-size, so render
  # taller and crop back to the exact size.
  "$chrome" --headless=new --disable-gpu --hide-scrollbars \
    --force-device-scale-factor="$scale" --window-size="$w,$((h + 200))" \
    --default-background-color=00000000 \
    --screenshot="$here/$asset.png" "file://$here/art.html?a=$asset" 2>/dev/null
  magick "$here/$asset.png" -crop "$((w * scale))x$((h * scale))+0+0" +repage "$here/$asset.png"
  echo "$asset.png"
}

shot portrait 600 900 1
shot landscape 920 430 1
shot hero 1920 620 2
shot logo 1280 400 1

# Steam's icon field takes a PNG; Positron's own app icon at 256 px.
magick -background none "/Applications/Positron.app/Contents/Resources/app/out/media/positron-icon.svg" \
  -resize 256x256 "$here/icon.png"
echo icon.png
