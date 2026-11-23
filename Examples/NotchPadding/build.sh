#!/bin/sh
# Builds build/libNotchPadding.dylib: x86_64 + arm64 + arm64e, no exported symbols, signed ad-hoc (or with
# SIGN_IDENTITY="Apple Development: …"). It compiles against the repository's TweakSDK.
set -eu
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
  "$CC" -Wall -Wextra -O2 -fobjc-arc -fvisibility=hidden -isysroot "$SDK" -I "$DIR/../../TweakSDK/include" "$@" \
    -mmacosx-version-min=14.0 -arch x86_64 -arch arm64 -arch arm64e -dynamiclib \
    -install_name @rpath/libNotchPadding.dylib \
    -framework AppKit -framework Foundation -framework CoreGraphics \
    "$DIR/NotchPadding.m" "$DIR/../../TweakSDK/DynjectHook.m" -o "$out/libNotchPadding.dylib"
  if [ "${SIGN_IDENTITY:--}" = "-" ]; then codesign --force --sign - --timestamp=none "$out/libNotchPadding.dylib"
  else codesign --force --sign "$SIGN_IDENTITY" --timestamp "$out/libNotchPadding.dylib"; fi
  exported=$(nm -gU "$out/libNotchPadding.dylib" 2>/dev/null | grep -cv -e '^$' -e ':$' || true)
  echo "Built $out/libNotchPadding.dylib ($(lipo -archs "$out/libNotchPadding.dylib"); exported symbols: $exported)"
  [ "$exported" = 0 ] || { nm -gU "$out/libNotchPadding.dylib"; echo "error: exported symbols" >&2; exit 1; }
}

# ./build.sh demo: build demo/NotchDemo.app (status items and menus that crowd the menu bar, padding buttons) and
# open it. It needs the tweak installed for MenuBarAgent (see README.md); it doesn't build the tweak.
if [ "${1:-}" = "demo" ]; then
  APP="$OUT/NotchDemo.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.dynject.notchpadding.demo</string>
  <key>CFBundleExecutable</key><string>NotchDemo</string>
  <key>CFBundleName</key><string>NotchDemo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  "$CC" -Wall -Wextra -fobjc-arc -isysroot "$SDK" -mmacosx-version-min=14.0 -framework AppKit \
    "$DIR/demo/NotchDemo.m" -o "$APP/Contents/MacOS/NotchDemo"
  codesign --force --sign - --timestamp=none "$APP"
  echo "Built $APP"
  open "$APP"
  exit 0
fi

dylib "$OUT"
[ "${1:-}" = "test" ] || exit 0

# ./build.sh test: the test copy (TWEAK_TEST, see NotchPadding.m) and testhost/ as a small app in build/test/, run with
# the test copy injected through DYLD_INSERT_LIBRARIES. No Dynject involved, nothing installed.
T="$OUT/test"
dylib "$T" -DTWEAK_TEST
HOST="$T/NotchPaddingTestHost.app"
rm -rf "$HOST"
mkdir -p "$HOST/Contents/MacOS"
cat > "$HOST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.dynject.notchpadding.testhost</string>
  <key>CFBundleExecutable</key><string>NotchPaddingTestHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
"$CC" -Wall -Wextra -fobjc-arc -isysroot "$SDK" -mmacosx-version-min=14.0 -arch arm64 -arch x86_64 \
  -framework AppKit "$DIR/testhost/TestHost.m" -o "$HOST/Contents/MacOS/NotchPaddingTestHost"
# A plain ad-hoc signature (no hardened runtime), so DYLD_INSERT_LIBRARIES is honoured for this app.
codesign --force --sign - --timestamp=none "$HOST"

EXE="$HOST/Contents/MacOS/NotchPaddingTestHost"
status=0
echo "== $(uname -m) =="
DYLD_INSERT_LIBRARIES="$T/libNotchPadding.dylib" "$EXE" || status=1
if arch -x86_64 /usr/bin/true 2>/dev/null; then   # the x86_64 slice too, when Rosetta is installed
  echo "== x86_64 (Rosetta) =="
  arch -x86_64 -e DYLD_INSERT_LIBRARIES="$T/libNotchPadding.dylib" "$EXE" || status=1
fi
defaults delete -g dynject.tweak.local.dynject.notchpadding.test 2>/dev/null || true   # in case the host didn't get to it
exit $status
