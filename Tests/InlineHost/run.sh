#!/bin/sh
# DHHookFunction (inline hooks): builds host.m + fns.s with DynjectHook.m compiled in, for arm64 and, where it runs,
# arm64e, and runs the checks. No Dynject involved.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/../.." && pwd)
OUT="$DIR/build"
SDK=$(xcrun --show-sdk-path)
CC=$(xcrun -find clang)
rm -rf "$OUT"
mkdir -p "$OUT"
status=0
for arch in arm64 arm64e; do
  "$CC" -Wall -Wextra -Werror -fobjc-arc -fvisibility=hidden -isysroot "$SDK" -arch "$arch" -I "$ROOT/TweakSDK/include" \
    -framework Foundation -framework CoreGraphics "$DIR/host.m" "$DIR/fns.s" "$ROOT/TweakSDK/DynjectHook.m" \
    -o "$OUT/host-$arch" || exit 1
  codesign --force --sign - --timestamp=none "$OUT/host-$arch" 2>/dev/null
  echo "== $arch =="
  "$OUT/host-$arch"
  rc=$?
  if [ "$arch" = arm64e ] && [ $rc -ge 128 ]; then
    echo "(arm64e: this Mac doesn't run third-party arm64e executables, exit $rc; skipped)"
  elif [ $rc -ne 0 ]; then
    status=1
  fi
done
exit $status
