#!/bin/sh
# Builds MenuLoader (x86_64 + arm64 + arm64e, ad-hoc signed, no exported symbols).
#
#   ./build.sh          build/libMenuLoader.dylib        (release)
#   ./build.sh test     build/test/libMenuLoader.dylib   (-DML_TEST: key "dynject.menuloader.test", notification
#                       "dynject.menuloader.test.changed", tweak ID "local.dynject.menuloader.test", settings from
#                       the "local.dynject.menuloader.testprefs" domain, actions logged instead of performed)
#   ./build.sh install  prints the commands that install the release build; it runs nothing.
#
# The injection test lives in testhost/ (testhost/run.sh).
set -eu
export ZERO_AR_DATE=1   # -g: no object file dates in the debug map, so an unchanged build is byte for byte the same
DIR=$(cd "$(dirname "$0")" && pwd)
SDKDIR="$DIR/../../TweakSDK"
SDK=$(xcrun --show-sdk-path)
CC=$(xcrun -find clang)

case "${1:-release}" in
  release) OUT="$DIR/build"; DEFS="" ;;
  test)    OUT="$DIR/build/test"; DEFS="-DML_TEST" ;;
  install)
    cat <<EOF
Install by hand (needs administrator rights; nothing here runs it):
  sudo cp "$DIR/build/libMenuLoader.dylib" /opt/dynject/lib/tweaks/
  cp "$DIR/MenuLoader.workbench.plist" ~/Library/Application\ Support/Dynject\ Workbench/Tweaks/
Then declare it in dynjectd.conf (Workbench → Raw Config): "dylib:/opt/dynject/lib/tweaks/libMenuLoader.dylib:deny"
and turn it on per app on the Apps & Injection page (or ":allow" for every app), Save & Restart, relaunch the apps.
EOF
    exit 0 ;;
  *) echo "usage: $0 [release|test|install]" >&2; exit 2 ;;
esac

mkdir -p "$OUT"
# shellcheck disable=SC2086
"$CC" -Wall -Wextra -Werror -g -O2 -fobjc-arc -fvisibility=hidden $DEFS -isysroot "$SDK" -I "$SDKDIR/include" \
  -mmacosx-version-min=14.0 -arch x86_64 -arch arm64 -arch arm64e -dynamiclib \
  -install_name @rpath/libMenuLoader.dylib \
  -framework AppKit -framework Foundation -framework CoreGraphics \
  "$DIR/MenuLoader.m" "$SDKDIR/DynjectHook.m" -o "$OUT/libMenuLoader.dylib"
strip -S "$OUT/libMenuLoader.dylib"   # the debug map (build paths) goes; the dSYM -g made next to it keeps the symbols
if [ "${SIGN_IDENTITY:--}" = "-" ]; then codesign --force --sign - --timestamp=none "$OUT/libMenuLoader.dylib"
    else codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUT/libMenuLoader.dylib"; fi

exported=$(nm -gU "$OUT/libMenuLoader.dylib" 2>/dev/null | grep -cv -e '^$' -e ':$' || true)
echo "Built $OUT/libMenuLoader.dylib ($(lipo -archs "$OUT/libMenuLoader.dylib"); exported symbols: $exported)"
[ "$exported" = 0 ] || { nm -gU "$OUT/libMenuLoader.dylib"; echo "error: exported symbols" >&2; exit 1; }
