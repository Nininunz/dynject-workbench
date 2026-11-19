#!/bin/sh
# UI smoke test: launches the built app against copies of the config fixtures and drives it
# through its own accessibility tree. Verifies the live Dynject config and daemons are untouched.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/Dynject Workbench.app"
REPORT="$ROOT/build/smoke-report"
LIVE=/opt/dynject/etc/dynjectd.conf

[ -x "$APP/Contents/MacOS/DynjectWorkbench" ] || "$ROOT/scripts/build-app.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dw-smoke.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/Tests/DynjectCoreTests/Fixtures/live.conf" "$WORK/dynjectd.conf"
cp "$ROOT/Tests/DynjectCoreTests/Fixtures/dynjectd-excerpt.log" "$WORK/dynjectd.log"
mkdir -p "$WORK/tweaks"
TWEAK="$WORK/tweaks/example.workbench.plist"
cp "$ROOT/Examples/ExampleTweak.workbench.plist" "$TWEAK"
plutil -replace dylib -string /opt/dynject/lib/tweaks/libBrutalium.dylib "$TWEAK"   # a dylib the fixture config declares
plutil -insert applyCommand -json "[\"/usr/bin/touch\",\"$WORK/applied\"]" "$TWEAK"
rm -rf "$REPORT"; mkdir -p "$REPORT"

live_before=$( [ -f "$LIVE" ] && shasum -a 256 "$LIVE" || echo none)
global_before=$(defaults read -g 2>/dev/null | grep -c "dynject.tweak" || true)
menu_before=$(defaults read -g dynject.menuloader 2>/dev/null | shasum -a 256 || true)
daemons_before=$(pgrep -x dynjectd | sort | tr '\n' ' ' || true)

"$APP/Contents/MacOS/DynjectWorkbench" \
  -DWConfigPath "$WORK/dynjectd.conf" \
  -DWLogPath "$WORK/dynjectd.log" \
  -DWErrorLogPath "$WORK/missing-error.log" \
  -DWSupportDir "$WORK/support" \
  -DWTweaksDir "$WORK/tweaks" \
  -DWSmokeTest "$REPORT" &
pid=$!

i=0
while kill -0 "$pid" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -gt 180 ]; then echo "smoke test timed out"; kill "$pid"; exit 1; fi
  sleep 1
done
wait "$pid" && status=0 || status=$?

live_after=$( [ -f "$LIVE" ] && shasum -a 256 "$LIVE" || echo none)
daemons_after=$(pgrep -x dynjectd | sort | tr '\n' ' ' || true)

if [ "$live_before" != "$live_after" ]; then echo "FAIL: live config changed"; status=1; fi
global_after=$(defaults read -g 2>/dev/null | grep -c "dynject.tweak" || true)
if [ "$global_before" != "$global_after" ]; then echo "FAIL: global preferences gained dynject.tweak keys"; status=1; fi
menu_after=$(defaults read -g dynject.menuloader 2>/dev/null | shasum -a 256 || true)
if [ "$menu_before" != "$menu_after" ]; then echo "FAIL: the real dynject.menuloader key changed"; status=1; fi
if [ "$daemons_before" != "$daemons_after" ]; then echo "FAIL: dynjectd processes changed ($daemons_before -> $daemons_after)"; status=1; fi
echo "live config unchanged: $([ "$live_before" = "$live_after" ] && echo yes || echo NO)"
echo "dynjectd pids unchanged: $daemons_after"
echo "report: $REPORT/report.json"
exit "$status"
