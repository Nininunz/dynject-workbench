#!/bin/sh
# Builds SettingsLoader (x86_64 + arm64 + arm64e, ad-hoc signed, no exported symbols) and its stub app.
#
#   ./build.sh             build/libSettingsLoader.dylib and build/SettingsLoader.app (the "Tweaks" extension)
#   ./build.sh register    copies SettingsLoader.app to ~/Library/Application Support/Dynject Workbench/SettingsLoader
#                          and registers its extension with pluginkit (as the user; no administrator rights)
#   ./build.sh unregister  undoes register
#   ./build.sh install     prints the commands that install the dylib; it runs nothing
#
# The tweak links Workbench's own manifest and settings code (Sources/DynjectCore) and settings controls
# (Sources/DynjectSettingsUI), compiled here per architecture into build/obj/<arch> and reused while unchanged.
set -eu
export ZERO_AR_DATE=1
DIR=$(cd "$(dirname "$0")" && pwd)
ROOT="$DIR/../.."
SDKDIR="$ROOT/TweakSDK"
SDK=$(xcrun --show-sdk-path)
CC=$(xcrun -find clang)
SWIFTC=$(xcrun -find swiftc)
OUT="$DIR/build"
APP="$OUT/SettingsLoader.app"
APPEX="$APP/Contents/Extensions/Tweaks.appex"
EXT_ID=local.dynject.settingsloader.extension
REGISTERED="$HOME/Library/Application Support/Dynject Workbench/SettingsLoader/SettingsLoader.app"
ARCHS="x86_64 arm64 arm64e"

case "${1:-release}" in
  release) ;;
  register)
    [ -d "$APP" ] || { echo "error: build first (./build.sh)" >&2; exit 1; }
    mkdir -p "$(dirname "$REGISTERED")"
    rm -rf "$REGISTERED"
    cp -R "$APP" "$REGISTERED"
    pluginkit -a "$REGISTERED/Contents/Extensions/Tweaks.appex"
    echo "Registered $EXT_ID from $REGISTERED"
    pluginkit -m -v -i "$EXT_ID" || true
    exit 0 ;;
  unregister)
    [ -d "$REGISTERED" ] && pluginkit -r "$REGISTERED/Contents/Extensions/Tweaks.appex" || true
    rm -rf "$REGISTERED"
    echo "Unregistered $EXT_ID"
    exit 0 ;;
  install)
    cat <<EOF
Install (one password prompt), register the Tweaks extension, relaunch System Settings:
  dw tweak install "$DIR" --for com.apple.systempreferences
  "$DIR/build.sh" register
  dw respring com.apple.systempreferences
EOF
    exit 0 ;;
  *) echo "usage: $0 [release|register|unregister|install]" >&2; exit 2 ;;
esac

# Rebuilds $1 (a module's static library) when any of the following sources is newer.
stale() {
  lib=$1; shift
  [ -f "$lib" ] || return 0
  for f in "$@"; do [ "$f" -nt "$lib" ] && return 0; done
  return 1
}

build_arch() {
  arch=$1
  obj="$OUT/obj/$arch"
  mkdir -p "$obj"
  target="$arch-apple-macos14.0"
  swiftflags="-O -g -sdk $SDK -target $target -swift-version 5 -parse-as-library -I $obj"
  core="$ROOT/Sources/DynjectCore"/*.swift
  # shellcheck disable=SC2086
  if stale "$obj/libDynjectCore.a" $core; then
    "$SWIFTC" $swiftflags -emit-library -static -module-name DynjectCore -emit-module \
      -emit-module-path "$obj/DynjectCore.swiftmodule" $core -o "$obj/libDynjectCore.a"
  fi
  ui="$ROOT/Sources/DynjectSettingsUI"/*.swift
  # shellcheck disable=SC2086
  if stale "$obj/libDynjectSettingsUI.a" $ui "$obj/libDynjectCore.a"; then
    "$SWIFTC" $swiftflags -emit-library -static -module-name DynjectSettingsUI -emit-module \
      -emit-module-path "$obj/DynjectSettingsUI.swiftmodule" $ui -o "$obj/libDynjectSettingsUI.a"
  fi
  # shellcheck disable=SC2086
  "$SWIFTC" $swiftflags -c -module-name SettingsLoader "$DIR/SettingsLoader.swift" -o "$obj/SettingsLoaderSwift.o"
  "$CC" -c -Wall -Wextra -Werror -g -O2 -fobjc-arc -fvisibility=hidden -isysroot "$SDK" -I "$SDKDIR/include" \
    -mmacosx-version-min=14.0 -arch "$arch" "$DIR/SettingsLoader.m" -o "$obj/SettingsLoader.o"
  "$CC" -c -Wall -g -O2 -fobjc-arc -fvisibility=hidden -isysroot "$SDK" -I "$SDKDIR/include" \
    -mmacosx-version-min=14.0 -arch "$arch" "$SDKDIR/DynjectHook.m" -o "$obj/DynjectHook.o"
  : > "$obj/exports"   # nothing exported
  # shellcheck disable=SC2086
  "$SWIFTC" -sdk "$SDK" -target "$target" -emit-library -g \
    "$obj/SettingsLoader.o" "$obj/DynjectHook.o" "$obj/SettingsLoaderSwift.o" \
    "$obj/libDynjectSettingsUI.a" "$obj/libDynjectCore.a" \
    -framework AppKit -framework SwiftUI -framework ExtensionFoundation -framework CoreGraphics \
    -Xlinker -dead_strip -Xlinker -exported_symbols_list -Xlinker "$obj/exports" \
    -Xlinker -install_name -Xlinker @rpath/libSettingsLoader.dylib \
    -o "$obj/libSettingsLoader.dylib"
}

mkdir -p "$OUT"
pids=""
for arch in $ARCHS; do
  build_arch "$arch" > "$OUT/build-$arch.log" 2>&1 &
  pids="$pids $!"
done
failed=0
for pid in $pids; do wait "$pid" || failed=1; done
if [ "$failed" = 1 ]; then
  for arch in $ARCHS; do grep -E 'error|warning: unre' "$OUT/build-$arch.log" | head -20; done
  echo "error: build failed (logs: $OUT/build-<arch>.log)" >&2
  exit 1
fi

DYLIB="$OUT/libSettingsLoader.dylib"
# shellcheck disable=SC2046
lipo -create $(for a in $ARCHS; do echo "$OUT/obj/$a/libSettingsLoader.dylib"; done) -output "$DYLIB"
rm -rf "$DYLIB.dSYM"
dsymutil "$DYLIB" -o "$DYLIB.dSYM" 2>/dev/null || true
strip -S "$DYLIB"
sign() {
  if [ "${SIGN_IDENTITY:--}" = "-" ]; then codesign --force --sign - --timestamp=none "$1"
  else codesign --force --sign "$SIGN_IDENTITY" --timestamp "$1"; fi
}
sign "$DYLIB"

# The stub app and its extension: same executable, never meant to run.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APPEX/Contents/MacOS"
"$CC" -O2 -isysroot "$SDK" -mmacosx-version-min=14.0 -arch arm64 -arch x86_64 "$DIR/Extension/stub.c" -o "$APP/Contents/MacOS/SettingsLoader"
cp "$APP/Contents/MacOS/SettingsLoader" "$APPEX/Contents/MacOS/SettingsLoaderExtension"
cp "$DIR/Extension/Info.plist" "$APPEX/Contents/Info.plist"
cp "$DIR/Extension/App-Info.plist" "$APP/Contents/Info.plist"
sign "$APPEX"
sign "$APP"

exported=$(nm -gU "$DYLIB" 2>/dev/null | grep -cv -e '^$' -e ':$' || true)
echo "Built $DYLIB ($(lipo -archs "$DYLIB"); exported symbols: $exported) and $APP"
[ "$exported" = 0 ] || { nm -gU "$DYLIB"; echo "error: exported symbols" >&2; exit 1; }
