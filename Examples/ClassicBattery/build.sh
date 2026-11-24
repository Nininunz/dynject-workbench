#!/bin/sh
# Builds build/libClassicBattery.dylib: x86_64 + arm64 + arm64e, no exported symbols, signed ad-hoc (or with
# SIGN_IDENTITY="Apple Development: …"). It compiles against the repository's TweakSDK.
set -eu
export ZERO_AR_DATE=1   # -g: no object file dates in the debug map, so an unchanged build is byte for byte the same
DIR=$(cd "$(dirname "$0")" && pwd)
OUT="$DIR/build"
SDK=$(xcrun --show-sdk-path)
CC=$(xcrun -find clang)
mkdir -p "$OUT"

# dylib <output folder> [extra flags]. DynjectHook.m is compiled in (hooks, DH_CTOR's Safe Mode check); with
# -fvisibility=hidden nothing is exported, so several tweaks in one app don't clash.
dylib() {
  out="$1"; shift
  mkdir -p "$out"
  "$CC" -Wall -Wextra -g -O2 -fobjc-arc -fvisibility=hidden -isysroot "$SDK" -I "$DIR/../../TweakSDK/include" "$@" \
    -mmacosx-version-min=14.0 -arch x86_64 -arch arm64 -arch arm64e -dynamiclib \
    -install_name @rpath/libClassicBattery.dylib \
    -framework AppKit -framework Foundation -framework CoreGraphics -framework IOKit -framework QuartzCore \
    "$DIR/ClassicBattery.m" "$DIR/../../TweakSDK/DynjectHook.m" -o "$out/libClassicBattery.dylib"
  strip -S "$out/libClassicBattery.dylib"   # the debug map (build paths) goes; the dSYM -g made next to it keeps the symbols
  if [ "${SIGN_IDENTITY:--}" = "-" ]; then codesign --force --sign - --timestamp=none "$out/libClassicBattery.dylib"
  else codesign --force --sign "$SIGN_IDENTITY" --timestamp "$out/libClassicBattery.dylib"; fi
  exported=$(nm -gU "$out/libClassicBattery.dylib" 2>/dev/null | grep -cv -e '^$' -e ':$' -e ' _CBTestSetState$' -e ' _CBTestSetSettings$' || true)   # the test copy's two exports
  echo "Built $out/libClassicBattery.dylib ($(lipo -archs "$out/libClassicBattery.dylib"); exported symbols: $exported)"
  [ "$exported" = 0 ] || { nm -gU "$out/libClassicBattery.dylib"; echo "error: exported symbols" >&2; exit 1; }
}

dylib "$OUT"
[ "${1:-}" = "test" ] || exit 0

# ./build.sh test: the test copy (TWEAK_TEST, see ClassicBattery.m) and testhost/ as a small app in build/test/, run
# with the test copy injected through DYLD_INSERT_LIBRARIES. No Dynject involved, nothing installed. The host draws
# the item in every state, in dark and light appearance, checks the pixels and saves them in build/test/render/.
T="$OUT/test"
dylib "$T" -DTWEAK_TEST
HOST="$T/ClassicBatteryTestHost.app"
rm -rf "$HOST" "$T/render"
mkdir -p "$HOST/Contents/MacOS" "$T/render"
cat > "$HOST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.dynject.classicbattery.testhost</string>
  <key>CFBundleExecutable</key><string>ClassicBatteryTestHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
"$CC" -Wall -Wextra -fobjc-arc -isysroot "$SDK" -mmacosx-version-min=14.0 -arch arm64 \
  -framework AppKit "$DIR/testhost/TestHost.m" -o "$HOST/Contents/MacOS/ClassicBatteryTestHost"
# A plain ad-hoc signature (no hardened runtime), so DYLD_INSERT_LIBRARIES is honoured for this app.
codesign --force --sign - --timestamp=none "$HOST"
DYLD_INSERT_LIBRARIES="$T/libClassicBattery.dylib" "$HOST/Contents/MacOS/ClassicBatteryTestHost" "$T/render"
