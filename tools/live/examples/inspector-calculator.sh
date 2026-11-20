#!/bin/sh
# Drive Inspector's layer mode in Calculator and screenshot each step (Inspector must be enabled for Calculator and
# Calculator relaunched since). Hold-mode picking can't be scripted (synthetic key presses release the modifiers),
# so this uses Inspector's toggle notification, the same thing "Inspect This App" posts.
#
#   tools/live/examples/inspector-calculator.sh [out-dir] [tabs]
set -eu
LIVE=$(cd "$(dirname "$0")/.." && pwd)/live
OUT=${1:-$(mktemp -d)/inspector}; TABS=${2:-6}
mkdir -p "$OUT"
"$LIVE" front Calculator
# The "5" key in the scientific layout (674x408 window); adjust for basic mode.
"$LIVE" point Calculator 502 265
"$LIVE" notify local.dynject.inspector.toggle; sleep 0.6
"$LIVE" shot Calculator "$OUT/0-views.png"
"$LIVE" key l; sleep 0.5
"$LIVE" shot Calculator "$OUT/1-layers.png"
i=1
while [ "$i" -le "$TABS" ]; do
  "$LIVE" key tab; sleep 0.35
  "$LIVE" shot Calculator "$OUT/2-tab$(printf %02d "$i").png"
  i=$((i + 1))
done
"$LIVE" key esc
"$LIVE" log local.dynject.inspector 30
echo "screenshots: $OUT"
