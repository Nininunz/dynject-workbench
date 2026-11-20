#!/bin/sh
# Respring end-to-end test: the real engine (quit, reopen, lsof) against two test apps it builds itself.
# Never touches any other app, the live config, or /opt/dynject. See docs/respring.md ("End-to-end test").
#
#   .build/respring/e2e/apps/RespringE2E Plain.app      quits when asked
#   .build/respring/e2e/apps/RespringE2E Stubborn.app   answers NSTerminateLater and quits 8 s later
#   .build/respring/e2e/tweaks/libRespringE2ETweak.dylib
#   .build/respring/e2e/RespringE2E                     the driver (links DynjectCore built from source)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/scripts/respring-e2e"
OUT="$ROOT/.build/respring/e2e"
OBJ="$OUT/obj"
SDK=$(xcrun --show-sdk-path)

rm -rf "$OUT"
mkdir -p "$OBJ" "$OUT/apps" "$OUT/tweaks"

echo "building the test tweak"
clang -dynamiclib -O1 -o "$OUT/tweaks/libRespringE2ETweak.dylib" "$SRC/TestTweak.c"

echo "building the test apps"
swiftc -O -sdk "$SDK" -o "$OBJ/RespringE2EApp" "$SRC/TestApp.swift"
make_app() { # name bundle-id quit-delay
  app="$OUT/apps/RespringE2E $1.app"
  mkdir -p "$app/Contents/MacOS"
  cp "$OBJ/RespringE2EApp" "$app/Contents/MacOS/RespringE2E$1"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>RespringE2E$1</string>
<key>CFBundleName</key><string>RespringE2E $1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>RespringE2EQuitDelay</key><integer>$3</integer>
</dict></plist>
EOF
  # Ad-hoc, no hardened runtime: DYLD_INSERT_LIBRARIES has to work.
  codesign --force --sign - --timestamp=none "$app"
}
make_app Plain local.dynject.respring.e2e.plain 0
make_app Stubborn local.dynject.respring.e2e.stubborn 8

echo "building the driver (DynjectCore from source)"
swiftc -sdk "$SDK" -swift-version 5 -parse-as-library -emit-library -static -module-name DynjectCore \
  -emit-module -emit-module-path "$OBJ/DynjectCore.swiftmodule" -o "$OBJ/libDynjectCore.a" \
  "$ROOT"/Sources/DynjectCore/*.swift
swiftc -sdk "$SDK" -swift-version 5 -I "$OBJ" -L "$OBJ" -lDynjectCore -o "$OUT/RespringE2E" "$SRC/Driver.swift"

echo
"$OUT/RespringE2E" "$OUT"
