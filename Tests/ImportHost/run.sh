#!/bin/sh
# Import hooks (DHHookImport) in real processes: a host executable and dylibs built here, a probe tweak injected with
# DYLD_INSERT_LIBRARIES (no Dynject involved). Runs the arm64e host (pointer authentication: signed __auth_got
# entries), the arm64 host, and the x86_64 host under Rosetta when it is installed.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
OUT="$DIR/build"
SDK=$(xcrun --show-sdk-path)
CC=$(xcrun -find clang)
ARCHS="-arch arm64 -arch arm64e -arch x86_64"
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/bin"
cc() { "$CC" -Wall -Wextra -Werror -isysroot "$SDK" "$@" || exit 1; }

cc $ARCHS -dynamiclib -install_name "$OUT/lib/libDHIHProvider.dylib" "$DIR/provider.c" -o "$OUT/lib/libDHIHProvider.dylib"
cc $ARCHS -dynamiclib -install_name "$OUT/lib/libDHIHCaller.dylib" "$DIR/caller.c" "$OUT/lib/libDHIHProvider.dylib" -o "$OUT/lib/libDHIHCaller.dylib"
cc $ARCHS -dynamiclib -install_name "$OUT/lib/libDHIHLate.dylib" "$DIR/late.c" "$OUT/lib/libDHIHProvider.dylib" -o "$OUT/lib/libDHIHLate.dylib"
cc $ARCHS -fobjc-arc -dynamiclib -I "$DIR/../../TweakSDK/include" -framework Foundation -framework CoreGraphics \
  "$DIR/probe.m" "$DIR/../../TweakSDK/DynjectHook.m" -o "$OUT/lib/libDHIHProbe.dylib"
LINK="$OUT/lib/libDHIHProvider.dylib $OUT/lib/libDHIHCaller.dylib"
# A third-party binary with an arm64 slice runs as arm64, so the arm64e host is a binary of its own.
cc -arch arm64e "$DIR/host.c" $LINK -o "$OUT/bin/host-arm64e"
cc -arch arm64 -arch x86_64 "$DIR/host.c" $LINK -o "$OUT/bin/host"
for f in "$OUT"/lib/*.dylib "$OUT"/bin/*; do codesign --force --sign - --timestamp=none "$f" 2>/dev/null; done

PROBE="$OUT/lib/libDHIHProbe.dylib"
status=0
echo "== arm64e =="
DYLD_INSERT_LIBRARIES="$PROBE" "$OUT/bin/host-arm64e" "$OUT/lib/libDHIHLate.dylib" || status=1
echo "== arm64 =="
DYLD_INSERT_LIBRARIES="$PROBE" "$OUT/bin/host" "$OUT/lib/libDHIHLate.dylib" || status=1
if arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "== x86_64 (Rosetta) =="
  arch -x86_64 -e DYLD_INSERT_LIBRARIES="$PROBE" "$OUT/bin/host" "$OUT/lib/libDHIHLate.dylib" || status=1
else
  echo "== x86_64: skipped, Rosetta isn't installed =="
fi
exit $status
