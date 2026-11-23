#!/bin/sh
# Builds libOLEDFinder.dylib: x86_64 + arm64 + arm64e, no exported symbols, zero warnings, signed ad-hoc (or with
# SIGN_IDENTITY="Apple Development: ...").
#
#   ./build.sh        build/libOLEDFinder.dylib (loads only in com.apple.finder)
#   ./build.sh test   also builds a test copy that loads in the test host too (-DOLF_TEST_BUNDLE), builds the test
#                     host app and runs it twice, without and with DYLD_INSERT_LIBRARIES (no Dynject involved).
#                     Output and screenshots: $OLF_TEST_DIR, default <repo>/.build/oledfinder-test.
set -eu
export ZERO_AR_DATE=1   # -g: no object file dates in the debug map, so an unchanged build is byte for byte the same
DIR=$(cd "$(dirname "$0")" && pwd)
OUT="$DIR/build"
SDKDIR="$DIR/../../TweakSDK"
SDK=$(xcrun --show-sdk-path)
CC=$(xcrun -find clang)

# $1 output dylib, rest: extra compiler flags. DynjectHook.m is compiled in (hooks, DH_CTOR's Safe Mode check).
build_dylib() {
  out=$1; shift
  mkdir -p "$(dirname "$out")"
  "$CC" -Wall -Wextra -Werror -g -O2 -fobjc-arc -fvisibility=hidden "$@" -isysroot "$SDK" -I "$SDKDIR/include" \
    -mmacosx-version-min=14.0 -arch x86_64 -arch arm64 -arch arm64e -dynamiclib \
    -install_name @rpath/libOLEDFinder.dylib \
    -framework AppKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
    "$DIR/OLEDFinder.m" "$SDKDIR/DynjectHook.m" -o "$out"
  strip -S "$out"   # the debug map (build paths) goes; the dSYM -g made next to it keeps the symbols
  if [ "${SIGN_IDENTITY:--}" = "-" ]; then codesign --force --sign - --timestamp=none "$out"
    else codesign --force --sign "$SIGN_IDENTITY" --timestamp "$out"; fi
  exported=$(nm -gU "$out" 2>/dev/null | grep -cv -e '^$' -e ':$' || true)
  echo "Built $out ($(lipo -archs "$out"); exported symbols: $exported)"
  [ "$exported" = 0 ] || { nm -gU "$out"; echo "error: exported symbols" >&2; exit 1; }
}

build_dylib "$OUT/libOLEDFinder.dylib"
[ "${1:-}" = "test" ] || exit 0

TEST=${OLF_TEST_DIR:-$DIR/../../.build/oledfinder-test}
mkdir -p "$TEST"
TEST=$(cd "$TEST" && pwd)
build_dylib "$TEST/libOLEDFinder.dylib" '-DOLF_TEST_BUNDLE="local.dynject.oledfinder.testhost"'

HOST="$TEST/OLEDFinderTestHost.app"
rm -rf "$HOST"
mkdir -p "$HOST/Contents/MacOS"
cat > "$HOST/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.dynject.oledfinder.testhost</string>
  <key>CFBundleExecutable</key><string>OLEDFinderTestHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
"$CC" -Wall -Wextra -Werror -fobjc-arc -isysroot "$SDK" -framework AppKit "$DIR/TestHost.m" \
  -o "$HOST/Contents/MacOS/OLEDFinderTestHost"
# Plain ad-hoc signature (no hardened runtime) so DYLD_INSERT_LIBRARIES is honoured for this test app only.
codesign --force --sign - --timestamp=none "$HOST"

EXE="$HOST/Contents/MacOS/OLEDFinderTestHost"
echo "== before (no tweak) =="
OLF_MODE=before OLF_OUT="$TEST" "$EXE"
echo "== after (DYLD_INSERT_LIBRARIES) =="
OLF_MODE=after OLF_OUT="$TEST" DYLD_INSERT_LIBRARIES="$TEST/libOLEDFinder.dylib" "$EXE"
