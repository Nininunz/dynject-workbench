#!/bin/sh
# Builds libTitleBadge.dylib (x86_64 + arm64 + arm64e, ad-hoc signed) and, with `test`, runs the
# injection test host (no Dynject involved; uses DYLD_INSERT_LIBRARIES on a local test app).
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
OUT="$DIR/build"
SDK=$(xcrun --show-sdk-path)
CC=$(xcrun -find clang)
mkdir -p "$OUT"

"$CC" -Wall -Wextra -O2 -fobjc-arc -isysroot "$SDK" -I "$DIR/../../TweakSDK/include" \
  -arch x86_64 -arch arm64 -arch arm64e -dynamiclib -install_name @rpath/libTitleBadge.dylib \
  -framework AppKit -framework Foundation "$DIR/TitleBadge.m" -o "$OUT/libTitleBadge.dylib"
codesign --force --sign - --timestamp=none "$OUT/libTitleBadge.dylib"
echo "Built $OUT/libTitleBadge.dylib ($(lipo -archs "$OUT/libTitleBadge.dylib"))"

[ "${1:-}" = "test" ] || exit 0

HOST="$OUT/TitleBadgeTestHost.app"
rm -rf "$HOST"
mkdir -p "$HOST/Contents/MacOS"
cat > "$HOST/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.dynject.titlebadge.testhost</string>
  <key>CFBundleExecutable</key><string>TitleBadgeTestHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
"$CC" -Wall -fobjc-arc -isysroot "$SDK" -framework AppKit "$DIR/TestHost.m" -o "$HOST/Contents/MacOS/TitleBadgeTestHost"
# Plain ad-hoc signature (no hardened runtime) so DYLD_INSERT_LIBRARIES is honoured for this test app only.
codesign --force --sign - --timestamp=none "$HOST"

before=$(defaults read -g dynject.tweak.local.dynject.titlebadge 2>/dev/null | shasum || true)
DYLD_INSERT_LIBRARIES="$OUT/libTitleBadge.dylib" "$HOST/Contents/MacOS/TitleBadgeTestHost"
status=$?
after=$(defaults read -g dynject.tweak.local.dynject.titlebadge 2>/dev/null | shasum || true)
[ "$before" = "$after" ] && echo "settings key restored: yes" || { echo "settings key restored: NO"; status=1; }
exit $status
