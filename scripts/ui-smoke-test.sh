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
# Safe Mode: a tweak whose dylib contains DynjectHook's key string (supports Safe Mode), an unmanifested dylib,
# and an empty crash-reports folder the smoke test writes synthetic reports into.
mkdir -p "$WORK/dylibs" "$WORK/reports"
printf 'smoke\000dynject.safemode\000dylib\000dynject.safemode:all-tweaks\000' > "$WORK/dylibs/libSafeTweak.dylib"
printf 'smoke dylib without DynjectHook' > "$WORK/dylibs/libLoose.dylib"
SAFE="$WORK/tweaks/safe.workbench.plist"
plutil -create xml1 "$SAFE"
plutil -insert formatVersion -integer 1 "$SAFE"
plutil -insert identifier -string com.example.safetweak "$SAFE"
plutil -insert name -string "Safe Tweak" "$SAFE"
plutil -insert dylib -string "$WORK/dylibs/libSafeTweak.dylib" "$SAFE"
# Respring: made-up running apps (nothing real is listed, quit or opened). TextEdit lacks the tweak the config gives
# it, Stubborn never quits (the timeout path), Finder, Terminal and Workbench itself are excluded by default.
BRUT=/opt/dynject/lib/tweaks/libBrutalium.dylib
cat > "$WORK/respring.json" <<EOF
{"apps": [
  {"bundleID": "com.apple.TextEdit", "launchedMinutesAgo": 90, "loaded": []},
  {"bundleID": "com.apple.finder", "launchedMinutesAgo": 120, "loaded": ["$BRUT"]},
  {"bundleID": "com.apple.Terminal", "launchedMinutesAgo": 300, "loaded": ["$BRUT"]},
  {"bundleID": "com.example.stubborn", "name": "Stubborn", "bundlePath": "/Applications/Stubborn.app",
   "launchedMinutesAgo": 60, "loaded": ["$BRUT"], "refusesToQuit": true},
  {"bundleID": "com.apple.calculator", "launchedMinutesAgo": 10, "loaded": []},
  {"bundleID": "local.dynject.workbench", "name": "Dynject Workbench", "launchedMinutesAgo": 5, "loaded": ["$BRUT"],
   "hostsCaller": true}
]}
EOF
rm -rf "$REPORT"; mkdir -p "$REPORT"

# Real Safe Mode state that must not change: the global key, state.json, the LaunchAgent, its dw copy, launchd.
SM_SUPPORT="$HOME/Library/Application Support/Dynject Workbench"
SM_AGENT="$HOME/Library/LaunchAgents/local.dynject.safemode.plist"
safemode_fingerprint() {
  { defaults read -g dynject.safemode 2>/dev/null || echo "no key"
    for f in "$SM_SUPPORT/SafeMode/state.json" "$SM_AGENT" "$SM_SUPPORT/bin/dw"; do
      [ -f "$f" ] && shasum -a 256 "$f" || echo "missing $f"
    done
    launchctl print "gui/$(id -u)/local.dynject.safemode" >/dev/null 2>&1 && echo "agent loaded" || echo "agent not loaded"
  } | shasum -a 256
}
safemode_before=$(safemode_fingerprint)

live_before=$( [ -f "$LIVE" ] && shasum -a 256 "$LIVE" || echo none)
global_before=$(defaults read -g 2>/dev/null | grep -c "dynject.tweak" || true)
menu_before=$(defaults read -g dynject.menuloader 2>/dev/null | shasum -a 256 || true)
daemons_before=$(pgrep -x dynjectd | sort | tr '\n' ' ' || true)
# Pids of the running regular (Foreground) apps, from Launch Services (read only). None may quit during the test:
# the Respring sheet only simulates.
real_apps() { lsappinfo list 2>/dev/null | awk '/pid = [0-9]+ .*type="Foreground"/ { for (i = 1; i <= NF; i++) if ($i == "pid") print $(i + 2) }' | sort; }
apps_before=$(real_apps)

"$APP/Contents/MacOS/DynjectWorkbench" \
  -DWConfigPath "$WORK/dynjectd.conf" \
  -DWLogPath "$WORK/dynjectd.log" \
  -DWErrorLogPath "$WORK/missing-error.log" \
  -DWSupportDir "$WORK/support" \
  -DWTweaksDir "$WORK/tweaks" \
  -DWReportsDir "$WORK/reports" \
  -DWTweakDylibDir "$WORK/dylibs" \
  -DWRespringFixture "$WORK/respring.json" \
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
if [ "$(safemode_fingerprint)" != "$safemode_before" ]; then echo "FAIL: real Safe Mode state changed (key, state.json, LaunchAgent, bin/dw or launchd)"; status=1; fi
real_apps > "$WORK/apps-after"
gone=$(printf '%s\n' "$apps_before" | comm -23 - "$WORK/apps-after" | tr '\n' ' ' | sed 's/ *$//')
if [ -n "$gone" ]; then echo "FAIL: app processes quit during the test: $gone"; status=1; fi
if [ "$daemons_before" != "$daemons_after" ]; then echo "FAIL: dynjectd processes changed ($daemons_before -> $daemons_after)"; status=1; fi
echo "live config unchanged: $([ "$live_before" = "$live_after" ] && echo yes || echo NO)"
echo "dynjectd pids unchanged: $daemons_after"
echo "app processes unchanged: $([ -z "$gone" ] && echo yes || echo "NO ($gone)")"
echo "real Safe Mode unchanged: $([ "$(safemode_fingerprint)" = "$safemode_before" ] && echo yes || echo NO)"
echo "report: $REPORT/report.json"
exit "$status"
