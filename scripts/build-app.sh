#!/bin/sh
# Builds "build/Dynject Workbench.app" (release, ad-hoc signed).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=${CONFIG:-release}
APP="$ROOT/build/Dynject Workbench.app"

cd "$ROOT"
swift build -c "$CONFIG" --product DynjectWorkbench
BIN=$(swift build -c "$CONFIG" --show-bin-path)/DynjectWorkbench

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DynjectWorkbench"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature with the hardened runtime. No entitlements: not sandboxed, because the app has to
# read /opt/dynject, run ps/lsof/launchctl, and hand protected writes to osascript.
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
