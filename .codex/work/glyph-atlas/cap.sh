#!/bin/zsh
# cap.sh <mode idle|orbit> <scale 1|2> <label>
# Launches headless Chrome against the editor bench harness, forces continuous
# frame production via a pending --screenshot, captures after the badge settles,
# and crops the bottom-left FPS badge for reading.
mode=$1; scale=$2; label=$3
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DIR=/Users/priamc/Code/kira-projects/kira-zig/.codex/work/glyph-atlas
out=$DIR/cap-$label.png
udd=/tmp/kx-$label
rm -rf "$udd" "$out"
"$CHROME" --headless=new --no-sandbox --enable-unsafe-webgpu --use-angle=metal \
  --disable-background-timer-throttling --disable-renderer-backgrounding \
  --disable-backgrounding-occluded-windows \
  --disable-gpu-vsync \
  --force-device-scale-factor=$scale --window-size=1400,900 \
  --user-data-dir="$udd" --timeout=15000 --screenshot="$out" \
  --enable-logging=stderr --v=0 \
  "http://127.0.0.1:8161/bench.html?mode=$mode" > "$DIR/cap-$label.log" 2>&1
# crop bottom-left badge (full image is 1400*scale x 900*scale)
if [ -f "$out" ]; then
  W=$(sips -g pixelWidth "$out" | awk '/pixelWidth/{print $2}')
  H=$(sips -g pixelHeight "$out" | awk '/pixelHeight/{print $2}')
  # badge sits ~bottom-left; crop a 260x90 (scaled) box near bottom-left
  cw=$((130*scale)); ch=$((45*scale))
  oy=$((H - 30*scale - ch))
  sips -c $ch $cw --cropOffset $oy $((8*scale)) "$out" --out "$DIR/badge-$label.png" >/dev/null 2>&1
  echo "captured $out  ${W}x${H}  resets=$(grep -c 'atlas full' "$DIR/cap-$label.log")"
else
  echo "NO SCREENSHOT for $label"
fi
