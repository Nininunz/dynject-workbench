#!/bin/sh
# Builds libInspector.dylib: x86_64 + arm64 + arm64e, no exported symbols, zero warnings, signed ad-hoc (or with
# SIGN_IDENTITY="Apple Development: ...").
#
#   ./build.sh        build/libInspector.dylib
#   ./build.sh test   also builds a test copy (-DDYI_TEST: an in-process test channel, a private pasteboard and its own
#                     toggle notification), builds the test host app (AppKit + SwiftUI) and runs it with
#                     DYLD_INSERT_LIBRARIES (no Dynject involved). The host drives the inspector, checks it and takes
#                     screenshots; the hook skeletons it copied are then compiled against DynjectHook.h.
#                     Output: $DYI_TEST_DIR, default <repo>/.build/inspector-test.
set -eu
export ZERO_AR_DATE=1   # -g: no object file dates in the debug map, so an unchanged build is byte for byte the same
DIR=$(cd "$(dirname "$0")" && pwd)
OUT="$DIR/build"
SDKDIR="$DIR/../../TweakSDK"
SDK=$(xcrun --show-sdk-path)
CC=$(xcrun -find clang)
SOURCES="$DIR/Inspector.m $DIR/DYIPicker.m $DIR/DYIPanel.m $DIR/DYIRuntime.m $DIR/DYITrace.m $DIR/DYIMenus.m $DIR/DYIEval.m $SDKDIR/DynjectHook.m"

# $1 output dylib, rest: extra compiler flags. DynjectHook.m is compiled in for DH_CTOR (safe mode, shift bypass).
build_dylib() {
  out=$1; shift
  mkdir -p "$(dirname "$out")"
  # shellcheck disable=SC2086
  "$CC" -Wall -Wextra -Werror -g -O2 -fobjc-arc -fvisibility=hidden "$@" -isysroot "$SDK" -I "$SDKDIR/include" \
    -mmacosx-version-min=14.0 -arch x86_64 -arch arm64 -arch arm64e -dynamiclib \
    -install_name @rpath/libInspector.dylib \
    -framework AppKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
    $SOURCES -o "$out"
  strip -S "$out"   # the debug map (build paths) goes; the dSYM -g made next to it keeps the symbols
  if [ "${SIGN_IDENTITY:--}" = "-" ]; then codesign --force --sign - --timestamp=none "$out"
    else codesign --force --sign "$SIGN_IDENTITY" --timestamp "$out"; fi
  exported=$(nm -gU "$out" 2>/dev/null | grep -cv -e '^$' -e ':$' || true)
  echo "Built $out ($(lipo -archs "$out"); exported symbols: $exported)"
  [ "$exported" = 0 ] || { nm -gU "$out"; echo "error: exported symbols" >&2; exit 1; }
}

build_dylib "$OUT/libInspector.dylib"
[ "${1:-}" = "test" ] || exit 0

TEST=${DYI_TEST_DIR:-$DIR/../../.build/inspector-test}
mkdir -p "$TEST"
TEST=$(cd "$TEST" && pwd)
build_dylib "$TEST/libInspector.dylib" -DDYI_TEST

HOST="$TEST/InspectorTestHost.app"
rm -rf "$HOST" "$TEST/obj" "$TEST/hooks"
mkdir -p "$HOST/Contents/MacOS" "$TEST/obj" "$TEST/hooks"
cat > "$HOST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.dynject.inspector.testhost</string>
  <key>CFBundleExecutable</key><string>InspectorTestHost</string>
  <key>CFBundleName</key><string>InspectorTestHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
ARCH=$(uname -m)
"$CC" -Wall -Wextra -Werror -fobjc-arc -isysroot "$SDK" -arch "$ARCH" -mmacosx-version-min=26.0 \
  -c "$DIR/testhost/TestHost.m" -o "$TEST/obj/TestHost.o"
"$CC" -Wall -Wextra -Werror -fobjc-arc -isysroot "$SDK" -arch "$ARCH" -mmacosx-version-min=26.0 \
  -c "$DIR/testhost/TestHostThrow.mm" -o "$TEST/obj/TestHostThrow.o"
xcrun swiftc -parse-as-library -O -sdk "$SDK" -target "$ARCH-apple-macosx26.0" \
  "$DIR/testhost/TestHostUI.swift" "$TEST/obj/TestHost.o" "$TEST/obj/TestHostThrow.o" -lc++ \
  -framework AppKit -framework SwiftUI -framework QuartzCore -o "$HOST/Contents/MacOS/InspectorTestHost"
# Plain ad-hoc signature (no hardened runtime) so DYLD_INSERT_LIBRARIES is honoured for this test app only.
codesign --force --sign - --timestamp=none "$HOST"

status=0
echo "== test host (DYLD_INSERT_LIBRARIES) =="
DYI_TEST=1 DYI_TEST_OUT="$TEST" DYLD_INSERT_LIBRARIES="$TEST/libInspector.dylib" \
  "$HOST/Contents/MacOS/InspectorTestHost" || status=1

# Every hook skeleton the host copied has to compile as-is (ARC, -Wall -Werror) against DynjectHook.h, with its
# commented DHHookClass line enabled in a function.
echo "== hook skeletons compile =="
n=0
for f in "$TEST"/hooks/*.txt; do
  [ -e "$f" ] || continue
  m="${f%.txt}.m"
  {
    echo '#import <AppKit/AppKit.h>'
    echo '#import <QuartzCore/QuartzCore.h>'
    echo '#import "DynjectHook.h"'
    cat "$f"
    echo 'void DYITestInstall(void);'
    echo 'void DYITestInstall(void) {'
    grep '^//   DHHookClass' "$f" | sed 's#^//   ##' || true
    echo '}'
  } > "$m"
  if "$CC" -Wall -Wextra -Werror -fobjc-arc -isysroot "$SDK" -I "$SDKDIR/include" -c "$m" -o "${m%.m}.o" 2> "${m%.m}.log"; then
    n=$((n + 1)); echo "  ok    $(basename "$f")"
  else
    echo "  FAIL  $(basename "$f")"; sed 's/^/        /' "${m%.m}.log"; status=1
  fi
done
[ "$n" -gt 0 ] || { echo "  FAIL  no hook skeletons were written"; status=1; }
[ "$status" = 0 ] && echo "ALL PASSED" || echo "FAILED"
exit "$status"
