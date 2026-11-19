#!/bin/sh
# Builds the test dylib (../build.sh test), the test host app and mltool into testhost/build/, then runs the
# host with the test dylib injected (DYLD_INSERT_LIBRARIES; no Dynject involved). The host cleans up the test
# preferences ("dynject.menuloader.test" and the local.dynject.menuloader.testprefs domain) when it finishes;
# this script does it again in any case.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
OUT="$DIR/build"
SDK=$(xcrun --show-sdk-path)
CC=$(xcrun -find clang)
mkdir -p "$OUT"

"$DIR/../build.sh" test || exit 1

HOST="$OUT/MenuLoaderTestHost.app"
rm -rf "$HOST"
mkdir -p "$HOST/Contents/MacOS"
cat > "$HOST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.dynject.menuloader.testhost</string>
  <key>CFBundleExecutable</key><string>MenuLoaderTestHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
"$CC" -Wall -Wextra -Werror -fobjc-arc -isysroot "$SDK" -arch arm64 -arch arm64e -arch x86_64 \
  -framework AppKit -framework Carbon "$DIR/TestHost.m" -o "$HOST/Contents/MacOS/MenuLoaderTestHost" || exit 1
"$CC" -Wall -Wextra -Werror -fobjc-arc -isysroot "$SDK" -framework Foundation "$DIR/mltool.m" -o "$OUT/mltool" || exit 1
# Plain ad-hoc signatures (no hardened runtime) so DYLD_INSERT_LIBRARIES is honoured for this test app only.
codesign --force --sign - --timestamp=none "$HOST" 2>/dev/null
codesign --force --sign - --timestamp=none "$OUT/mltool" 2>/dev/null

LIB="$DIR/../build/test/libMenuLoader.dylib"
EXE="$HOST/Contents/MacOS/MenuLoaderTestHost"
status=0
echo "== native ($(uname -m)) =="
DYLD_INSERT_LIBRARIES="$LIB" "$EXE" &
wait $! || status=1
# The x86_64 slice too, under Rosetta when it is installed (arch -e passes the variable to the host only).
if arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "== x86_64 (Rosetta) =="
  arch -x86_64 -e DYLD_INSERT_LIBRARIES="$LIB" "$EXE" &
  wait $! || status=1
fi
# Sandboxed smoke test: the same binary as a second, sandboxed app (its own bundle ID, ad-hoc signed with the
# app-sandbox entitlement). macOS creates a container for it under ~/Library/Containers/<bundle ID>.
SBX="$OUT/MenuLoaderSandboxedHost.app"
rm -rf "$SBX"
mkdir -p "$SBX/Contents/MacOS"
sed -e 's/local.dynject.menuloader.testhost</local.dynject.menuloader.testhost.sandboxed</' \
    -e 's/<string>MenuLoaderTestHost</<string>MenuLoaderSandboxedHost</' "$HOST/Contents/Info.plist" > "$SBX/Contents/Info.plist"
cp "$EXE" "$SBX/Contents/MacOS/MenuLoaderSandboxedHost"
cat > "$OUT/sandbox.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST
codesign --force --sign - --timestamp=none --entitlements "$OUT/sandbox.entitlements" "$SBX" 2>/dev/null
cat > "$OUT/list-sandbox.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>formatVersion</key><integer>1</integer>
  <key>submenuTitle</key><string>Sandboxed Test</string>
  <key>items</key><array><dict>
    <key>id</key><string>ping</string><key>title</key><string>Ping</string>
    <key>action</key><string>notify:local.dynject.menuloader.test.sandboxping</string>
    <key>symbol</key><string>bell</string>
    <key>tweakID</key><string>local.test.alpha</string><key>tweakName</key><string>Alpha Tweak</string>
  </dict></array>
</dict></plist>
PLIST
echo "== sandboxed smoke test =="
"$OUT/mltool" publish "$OUT/list-sandbox.plist"
"$OUT/mltool" observe local.dynject.menuloader.test.sandboxping 15 > "$OUT/observe.out" &
obs=$!
sleep 0.3
ML_SMOKE=1 DYLD_INSERT_LIBRARIES="$LIB" "$SBX/Contents/MacOS/MenuLoaderSandboxedHost" &
wait $! || status=1
if wait $obs; then echo "  [PASS] notification posted from the sandbox was received outside it"; else echo "  [FAIL] notification from the sandbox not received"; status=1; fi

"$OUT/mltool" clean
defaults delete local.dynject.menuloader.testprefs >/dev/null 2>&1
rm -f "$HOME/Library/Preferences/local.dynject.menuloader.testprefs.plist"   # the emptied test domain
if defaults read -g dynject.menuloader.test >/dev/null 2>&1; then echo "test key left behind"; status=1; else echo "test key removed: yes"; fi
exit $status
