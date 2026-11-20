#!/bin/sh
# DynjectBridge end-to-end test: the real broker (`dw bridge serve --test`) as a TEMPORARY LaunchAgent, a sandboxed
# test app with a test tweak injected through DYLD_INSERT_LIBRARIES, and the real SDK (DynjectBridge.m) in between.
# See docs/bridge.md ("end-to-end test").
#
# Everything lives in .build/bridge-e2e/. The broker uses a test service name, test global keys, a fake config and
# Tweaks folder that grant only the test host, and writes settings to a plist file there. Never touched: the real
# agent (local.dynject.bridge), ~/Library/LaunchAgents, the real dynject.* keys, /opt/dynject, the live config,
# real apps. On exit, whatever happened: bootout, test keys deleted, run folder removed (KEEP=1 keeps it).
#
#   .build/bridge-e2e/apps/BridgeE2E Host.app       sandboxed, local.bridge-e2e.host: the config injects the tweak
#   .build/bridge-e2e/apps/BridgeE2E Stranger.app   sandboxed, local.bridge-e2e.stranger: it doesn't
#   .build/bridge-e2e/BridgeE2EProbe                unsandboxed tool with the tweak linked in, no bundle
#   .build/bridge-e2e/libBridgeE2ETweak.dylib       the test tweak (TestTweak.m + DynjectBridge.m)
#   .build/bridge-e2e/run/                          config, Tweaks, plist, settings file, log, broker output
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/scripts/bridge-e2e"
OUT="$ROOT/.build/bridge-e2e"
RUN="$OUT/run"
SDK=$(xcrun --show-sdk-path)
CC=$(xcrun -find clang)
UID_=$(id -u)

LABEL=local.bridge-e2e.service
TOKEN_KEY=local.bridge-e2e.token
VERSION_KEY=local.bridge-e2e.version
NOTE=local.bridge-e2e.changed
TWEAK_ID=local.bridge-e2e.tweak
HOST_ID=local.bridge-e2e.host
# The SDK and the test tweak with the test names compiled in.
cc_test() { "$CC" "-DDB_SERVICE_NAME=\"$LABEL\"" "-DDB_TOKEN_KEY=\"$TOKEN_KEY\"" "-DDB_CHANGED_NOTIFICATION=\"$NOTE\"" "$@"; }

PASS=0
FAIL=0
check() { # pass(0|1) name evidence
  if [ "$1" = 1 ]; then PASS=$((PASS + 1)); echo "  [PASS] $2 — $3"; else FAIL=$((FAIL + 1)); echo "  [FAIL] $2 — $3"; fi
}
readg() { defaults read -g "$1" 2>/dev/null || echo "(absent)"; }
fp() { [ -e "$1" ] && shasum "$1" | cut -c1-12 || echo "(absent)"; }

# What must not change.
REAL_TOKEN_BEFORE=$(readg dynject.bridge.token)
REAL_SETTINGS_BEFORE=$(readg dynject.tweak.$TWEAK_ID)
REAL_AGENT_BEFORE=$(fp "$HOME/Library/LaunchAgents/local.dynject.bridge.plist")
REAL_LOG_BEFORE=$(fp "$HOME/Library/Application Support/Dynject Workbench/Bridge/log.json")
LIVE_CONF_BEFORE=$(fp /opt/dynject/etc/dynjectd.conf)

cleanup() {
  launchctl bootout "gui/$UID_/$LABEL" >/dev/null 2>&1 || true
  for p in ${HOST_PID:-}; do kill "$p" 2>/dev/null || true; done
  defaults delete -g "$TOKEN_KEY" >/dev/null 2>&1 || true
  defaults delete -g "$VERSION_KEY" >/dev/null 2>&1 || true
  if [ "${KEEP:-0}" != 1 ]; then rm -rf "$RUN"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

rm -rf "$OUT"
mkdir -p "$OUT/obj" "$OUT/apps" "$RUN/etc" "$RUN/Tweaks" "$RUN/Bridge"
launchctl bootout "gui/$UID_/$LABEL" >/dev/null 2>&1 || true   # a run that was killed before its trap

echo "building dw"
(cd "$ROOT" && swift build --product dw >/dev/null)
BIN=$(cd "$ROOT" && swift build --show-bin-path)
cp "$BIN/dw" "$OUT/dw"

echo "building the sdk (3 archs, -Wall -Wextra -Werror, hidden)"
SDK_LOG="$OUT/obj/sdk-build.log"
if "$CC" -Wall -Wextra -Werror -O2 -fobjc-arc -fvisibility=hidden -isysroot "$SDK" -I "$ROOT/TweakSDK/include" \
     -mmacosx-version-min=14.0 -arch x86_64 -arch arm64 -arch arm64e -dynamiclib -framework Foundation \
     "$ROOT/TweakSDK/DynjectBridge.m" -o "$OUT/obj/libDynjectBridgeOnly.dylib" >"$SDK_LOG" 2>&1; then
  exported=$(nm -gU "$OUT/obj/libDynjectBridgeOnly.dylib" | grep -cv -e '^$' -e ':$' || true)
  check "$([ "$exported" = 0 ] && echo 1 || echo 0)" "sdk builds clean" "$(lipo -archs "$OUT/obj/libDynjectBridgeOnly.dylib"), 0 warnings, $exported exported symbols"
else
  check 0 "sdk builds clean" "$(head -5 "$SDK_LOG")"
fi

echo "building the test tweak, host apps and probe"
cc_test -Wall -Wextra -Werror -O1 -fobjc-arc -fvisibility=hidden -isysroot "$SDK" -I "$ROOT/TweakSDK/include" \
  -arch arm64 -dynamiclib -framework Foundation "$SRC/TestTweak.m" "$ROOT/TweakSDK/DynjectBridge.m" -o "$OUT/libBridgeE2ETweak.dylib"
codesign --force --sign - --timestamp=none "$OUT/libBridgeE2ETweak.dylib"
"$CC" -Wall -O1 -fobjc-arc -isysroot "$SDK" -arch arm64 -framework Foundation "$SRC/Host.m" -o "$OUT/obj/BridgeE2EHost"
cc_test -Wall -O1 -fobjc-arc -isysroot "$SDK" -I "$ROOT/TweakSDK/include" -arch arm64 -framework Foundation \
  "$SRC/Host.m" "$SRC/TestTweak.m" "$ROOT/TweakSDK/DynjectBridge.m" -o "$OUT/BridgeE2EProbe"
codesign --force --sign - --timestamp=none "$OUT/BridgeE2EProbe"
cat > "$OUT/obj/sandbox.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
EOF
make_app() { # name bundle-id
  app="$OUT/apps/BridgeE2E $1.app"
  mkdir -p "$app/Contents/MacOS"
  cp "$OUT/obj/BridgeE2EHost" "$app/Contents/MacOS/BridgeE2E$1"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>BridgeE2E$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
  # Ad-hoc, sandboxed, no hardened runtime: DYLD_INSERT_LIBRARIES has to work. Signing identifier = bundle ID.
  codesign --force --sign - --timestamp=none --identifier "$2" --entitlements "$OUT/obj/sandbox.entitlements" "$app"
}
make_app Host "$HOST_ID"
make_app Stranger local.bridge-e2e.stranger
HOST_EXE="$OUT/apps/BridgeE2E Host.app/Contents/MacOS/BridgeE2EHost"
STRANGER_EXE="$OUT/apps/BridgeE2E Stranger.app/Contents/MacOS/BridgeE2EStranger"

echo "writing the fake config, manifests and the temporary LaunchAgent"
ELSEWHERE="$OUT/libBridgeE2EElsewhere.dylib"
cp "$OUT/libBridgeE2ETweak.dylib" "$ELSEWHERE"
cat > "$RUN/etc/dynjectd.conf" <<EOF
# bridge e2e: the test tweak goes into the test host only
allow:BridgeE2E
dylib:$OUT/libBridgeE2ETweak.dylib:deny
dylib-override:$OUT/libBridgeE2ETweak.dylib:allow:$HOST_ID
dylib:$ELSEWHERE:deny
EOF
cat > "$RUN/Tweaks/BridgeE2E.workbench.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>formatVersion</key><integer>1</integer>
<key>identifier</key><string>$TWEAK_ID</string>
<key>dylib</key><string>$OUT/libBridgeE2ETweak.dylib</string>
<key>bridge</key><array><string>settings.set</string><string>notify</string><string>open:https</string></array>
<key>sections</key><array><dict><key>items</key><array>
  <dict><key>type</key><string>switch</string><key>key</key><string>enabled</string><key>default</key><true/><key>perApp</key><true/></dict>
  <dict><key>type</key><string>slider</string><key>key</key><string>size</string><key>min</key><integer>0</integer><key>max</key><integer>10</integer></dict>
</array></dict></array>
</dict></plist>
EOF
cat > "$RUN/Tweaks/Elsewhere.workbench.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>formatVersion</key><integer>1</integer>
<key>identifier</key><string>local.bridge-e2e.elsewhere</string>
<key>dylib</key><string>$ELSEWHERE</string>
<key>bridge</key><array><string>notify</string></array>
<key>sections</key><array/>
</dict></plist>
EOF
PLIST="$RUN/$LABEL.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array>
  <string>$OUT/dw</string><string>bridge</string><string>serve</string><string>--test</string>
  <string>--service</string><string>$LABEL</string>
  <string>--token-key</string><string>$TOKEN_KEY</string>
  <string>--version-key</string><string>$VERSION_KEY</string>
  <string>--notification</string><string>$NOTE</string>
  <string>--config</string><string>$RUN/etc/dynjectd.conf</string>
  <string>--tweaks-dir</string><string>$RUN/Tweaks</string>
  <string>--settings-file</string><string>$RUN/tweak-prefs.plist</string>
  <string>--log-file</string><string>$RUN/Bridge/log.json</string>
  <string>--process-burst</string><string>200</string>
  <string>--app-roots</string><string>$OUT/apps</string>
</array>
<key>MachServices</key><dict><key>$LABEL</key><true/></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$RUN/broker.log</string>
<key>StandardErrorPath</key><string>$RUN/broker.log</string>
</dict></plist>
EOF

echo
echo "running"
# Before the broker publishes: a token for another service in the test key must be ignored by the SDK.
defaults write -g "$TOKEN_KEY" "deadbeef;01;00000000;00000000;00000000;000000000000001a;com.apple.app-sandbox.mach;local.other.service"
out=$(BRIDGE_E2E_MODE=badtoken DYLD_INSERT_LIBRARIES="$OUT/libBridgeE2ETweak.dylib" "$HOST_EXE" 2>&1 | grep '^BADTOKEN' || true)
check "$(echo "$out" | grep -q 'available=0 error=2' && echo 1 || echo 0)" "sdk ignores a token for another service" "$out (2 = not installed)"
launchctl bootstrap "gui/$UID_" "$PLIST"
token=""
for _ in $(seq 1 50); do
  token=$(defaults read -g "$TOKEN_KEY" 2>/dev/null || true)
  case "$token" in *";$LABEL") break ;; esac
  sleep 0.1
done
check "$([ -n "$token" ] && echo 1 || echo 0)" "broker publishes the token" "$TOKEN_KEY: ${#token} characters, version $(readg "$VERSION_KEY")"
broker_pid() { launchctl print "gui/$UID_/$LABEL" 2>/dev/null | sed -n 's/^	pid = //p' | head -1; }
PID1=$(broker_pid)

# The host runs the scenario; at READY_FOR_RESTART the broker is restarted under it.
HOST_OUT="$RUN/host.out"
BRIDGE_E2E_MODE=host DYLD_INSERT_LIBRARIES="$OUT/libBridgeE2ETweak.dylib" "$HOST_EXE" >"$HOST_OUT" 2>&1 &
HOST_PID=$!
restarted=0
for _ in $(seq 1 300); do
  if [ "$restarted" = 0 ] && grep -q '^READY_FOR_RESTART' "$HOST_OUT"; then
    launchctl kickstart -k "gui/$UID_/$LABEL" >/dev/null
    restarted=1
  fi
  kill -0 "$HOST_PID" 2>/dev/null || break
  sleep 0.2
done
wait "$HOST_PID" 2>/dev/null && host_status=0 || host_status=$?
HOST_PID=""
grep '^CHECK ' "$HOST_OUT" | sed 's/^CHECK //' | while IFS= read -r line; do
  case "$line" in PASS\ *) echo "  [PASS] ${line#PASS }" ;; *) echo "  [FAIL] ${line#FAIL }" ;; esac
done
PASS=$((PASS + $(grep -c '^CHECK PASS' "$HOST_OUT" || true)))
FAIL=$((FAIL + $(grep -c '^CHECK FAIL' "$HOST_OUT" || true)))
check "$([ "$host_status" = 0 ] && grep -q '^DONE 0' "$HOST_OUT" && echo 1 || echo 0)" "host scenario finished" "exit $host_status, $(grep -c '^CHECK ' "$HOST_OUT" || true) checks"
PID2=$(broker_pid)
check "$([ -n "$PID1" ] && [ -n "$PID2" ] && [ "$PID1" != "$PID2" ] && echo 1 || echo 0)" "broker restarted by launchd" "pid $PID1 -> $PID2"

enabled=$(/usr/libexec/PlistBuddy -c "Print :dynject.tweak.$TWEAK_ID:values:enabled" "$RUN/tweak-prefs.plist" 2>/dev/null || echo "?")
override=$(/usr/libexec/PlistBuddy -c "Print :dynject.tweak.$TWEAK_ID:perApp:$HOST_ID:enabled" "$RUN/tweak-prefs.plist" 2>/dev/null || echo "?")
size=$(/usr/libexec/PlistBuddy -c "Print :dynject.tweak.$TWEAK_ID:values:size" "$RUN/tweak-prefs.plist" 2>/dev/null || echo "?")
bogus=$(/usr/libexec/PlistBuddy -c "Print :dynject.tweak.$TWEAK_ID:values:bogus" "$RUN/tweak-prefs.plist" 2>/dev/null || echo "absent")
check "$([ "$enabled" = false ] && [ "$override" = true ] && { [ "$size" = 7 ] || [ "$size" = 7.000000 ]; } && [ "$bogus" = absent ] && echo 1 || echo 0)" \
  "settings written to the test file only" "values.enabled=$enabled perApp.$HOST_ID.enabled=$override values.size=$size bogus=$bogus"

out=$(BRIDGE_E2E_MODE=probe DYLD_INSERT_LIBRARIES="$OUT/libBridgeE2ETweak.dylib" "$STRANGER_EXE" 2>&1 | grep '^PROBE' || true)
check "$(echo "$out" | grep -q '^PROBE not-injected' && echo 1 || echo 0)" "sandboxed app the config doesn't list is denied" "$out"
out=$(BRIDGE_E2E_MODE=probe "$OUT/BridgeE2EProbe" 2>&1 | grep '^PROBE' || true)
check "$(echo "$out" | grep -q '^PROBE identity-mismatch' && echo 1 || echo 0)" "unsandboxed tool outside any app is denied" "$out"

sleep 1.5   # the broker saves its log within a second
LOG="$RUN/Bridge/log.json"
allowed=$(grep -c '"allowed" : true' "$LOG" 2>/dev/null || true)
denied=$(grep -c '"allowed" : false' "$LOG" 2>/dev/null || true)
reasons=$(grep '"reason"' "$LOG" 2>/dev/null | sed 's/.*: "\(.*\)".*/\1/' | sort -u | tr '\n' ' ')
check "$([ "${allowed:-0}" -gt 0 ] && [ "${denied:-0}" -gt 0 ] && echo "$reasons" | grep -q rate-limited && echo "$reasons" | grep -q unknown-tweak \
  && ! echo "$reasons" | grep -q identity-mismatch && echo 1 || echo 0)" \
  "decision log persisted, unidentified callers kept out" "$allowed allowed, $denied denied entries; reasons: $reasons"

launchctl bootout "gui/$UID_/$LABEL" >/dev/null 2>&1 || true
gone=$(launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1 && echo 0 || echo 1)
check "$gone" "temporary agent booted out" "$LABEL"
check "$([ "$(readg dynject.bridge.token)" = "$REAL_TOKEN_BEFORE" ] && [ "$(readg dynject.tweak.$TWEAK_ID)" = "$REAL_SETTINGS_BEFORE" ] \
  && [ "$(fp "$HOME/Library/LaunchAgents/local.dynject.bridge.plist")" = "$REAL_AGENT_BEFORE" ] \
  && [ "$(fp "$HOME/Library/Application Support/Dynject Workbench/Bridge/log.json")" = "$REAL_LOG_BEFORE" ] \
  && [ "$(fp /opt/dynject/etc/dynjectd.conf)" = "$LIVE_CONF_BEFORE" ] && echo 1 || echo 0)" \
  "nothing real touched" "dynject.bridge.token, dynject.tweak.$TWEAK_ID, real agent plist, real log, live config unchanged"

if [ "$FAIL" != 0 ]; then
  echo
  echo "host output:"; sed 's/^/  | /' "$HOST_OUT"
  echo "broker output:"; sed 's/^/  | /' "$RUN/broker.log" 2>/dev/null || true
fi
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
