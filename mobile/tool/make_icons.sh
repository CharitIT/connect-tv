#!/bin/bash
# Renders the app icon from assets/icon/*.svg into the Android and iOS icon files.
# Needs Google Chrome (for SVG → PNG) and macOS `sips`. No Flutter packages.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
SRC=assets/icon
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

render() { # svg out.png
  "$CHROME" --headless --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --window-size=1024,1024 --screenshot="$2" "file://$PWD/$1" >/dev/null 2>&1
}
resize() { sips -z "$2" "$2" "$1" --out "$3" >/dev/null; }

render $SRC/icon_full.svg    "$TMP/full.png"
render $SRC/icon_rounded.svg "$TMP/rounded.png"
render $SRC/adaptive_bg.svg  "$TMP/bg.png"
render $SRC/adaptive_fg.svg  "$TMP/fg.png"

# iOS icons must have no transparency: round-trip through JPEG to drop the alpha channel.
sips -s format jpeg -s formatOptions 100 "$TMP/full.png" --out "$TMP/full.jpg" >/dev/null
sips -s format png "$TMP/full.jpg" --out "$TMP/full_opaque.png" >/dev/null
IOS=ios/Runner/Assets.xcassets/AppIcon.appiconset
for f in "$IOS"/Icon-App-*.png; do
  name=$(basename "$f" .png)              # Icon-App-83.5x83.5@2x
  pt=${name#Icon-App-}; pt=${pt%%x*}      # 83.5
  scale=${name##*@}; scale=${scale%x}     # 2
  px=$(awk "BEGIN{printf \"%d\", $pt*$scale + 0.5}")
  resize "$TMP/full_opaque.png" "$px" "$f"
done

# Android: legacy icons plus adaptive (API 26+) layers.
RES=android/app/src/main/res
for pair in mdpi:48:108 hdpi:72:162 xhdpi:96:216 xxhdpi:144:324 xxxhdpi:192:432; do
  IFS=: read -r d legacy layer <<<"$pair"
  resize "$TMP/rounded.png" "$legacy" "$RES/mipmap-$d/ic_launcher.png"
  resize "$TMP/bg.png" "$layer" "$RES/mipmap-$d/ic_launcher_background.png"
  resize "$TMP/fg.png" "$layer" "$RES/mipmap-$d/ic_launcher_foreground.png"
done
mkdir -p "$RES/mipmap-anydpi-v26"
cat > "$RES/mipmap-anydpi-v26/ic_launcher.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
XML
echo "Icons updated."
