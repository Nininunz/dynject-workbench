#!/bin/sh
# Builds "build/Dynject Workbench.app" (release). Signed ad-hoc by default; set SIGN_IDENTITY to a codesigning
# identity (e.g. "Developer ID Application: Your Name (TEAMID)" or "Apple Development: …") to sign with your own.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=${CONFIG:-release}
APP="$ROOT/build/Dynject Workbench.app"
SIGN_IDENTITY=${SIGN_IDENTITY:--}
# A real identity gets a secure timestamp; ad-hoc signatures can't have one.
if [ "$SIGN_IDENTITY" = "-" ]; then TS=--timestamp=none; else TS=--timestamp; fi

cd "$ROOT"
swift build -c "$CONFIG" --product DynjectWorkbench
swift build -c "$CONFIG" --product dw
BINDIR=$(swift build -c "$CONFIG" --show-bin-path)
BIN=$BINDIR/DynjectWorkbench

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DynjectWorkbench"
# The dw CLI, which Safe Mode's "Install Watcher" copies to ~/Library/Application Support/Dynject Workbench/bin.
cp "$BINDIR/dw" "$APP/Contents/MacOS/dw"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Signature with the hardened runtime. No entitlements: not sandboxed, because the app has to
# read /opt/dynject, run ps/lsof/launchctl, and hand protected writes to osascript.
# Nested code first: the bundle's signature seals the already-signed dw.
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$TS" --identifier local.dynject.dw "$APP/Contents/MacOS/dw"
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$TS" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
