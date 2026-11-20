#!/bin/sh
# Builds Dynject Workbench, its dw CLI and the bundled tweaks from source, and installs the app.
#
#   ./scripts/bootstrap.sh                 check, build everything, install the app to ~/Applications
#   ./scripts/bootstrap.sh --check         only check prerequisites
#   ./scripts/bootstrap.sh --no-install    build only (app stays in build/)
#   ./scripts/bootstrap.sh --no-tweaks     skip MenuLoader and the example tweaks
#   ./scripts/bootstrap.sh --dest DIR      install the app into DIR instead of ~/Applications
#
# Signing: ad-hoc by default, which is all a locally built app needs (it isn't quarantined, so Gatekeeper
# doesn't ask). To sign with your own certificate, set SIGN_IDENTITY, e.g.
#   SIGN_IDENTITY="Apple Development: Jane Doe (ABCDE12345)" ./scripts/bootstrap.sh
# (list yours with: security find-identity -v -p codesigning).
#
# Nothing here needs administrator rights, touches the Dynject engine, edits its config or installs tweaks:
# installing a tweak is a separate step that asks for your password (see the printed next steps).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$HOME/Applications"
INSTALL=1 TWEAKS=1 CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --no-install) INSTALL=0 ;;
    --no-tweaks) TWEAKS=0 ;;
    --dest) shift; DEST=${1:?--dest needs a directory} ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
export SIGN_IDENTITY="${SIGN_IDENTITY:--}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; ERRORS=$((ERRORS + 1)); }
WARNINGS=0 ERRORS=0

bold "Checking prerequisites"

# macOS: the package needs 14+; the tweaks rely on private AppKit/Core Animation details only tested on 27.
os=$(sw_vers -productVersion); major=${os%%.*}
if [ "$major" -lt 14 ]; then bad "macOS $os: Dynject Workbench needs macOS 14 or later"
elif [ "$major" -lt 27 ]; then warn "macOS $os: builds, but only macOS 27 has been tested (MenuLoader uses private AppKit API)"
else ok "macOS $os"; fi

arch=$(uname -m)
if [ "$arch" = arm64 ]; then ok "Apple Silicon"
else warn "$arch Mac: builds, but only Apple Silicon has been tested"; fi

# Toolchain: Xcode or the Command Line Tools with Swift 6+.
if ! xcode-select -p >/dev/null 2>&1; then
  bad "no developer tools: install Xcode or run: xcode-select --install"
else
  sfull=$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)
  sv=${sfull%%.*}
  if [ -z "$sv" ]; then bad "swift not found (Xcode or Command Line Tools needed)"
  elif [ "$sv" -lt 6 ]; then bad "Swift $sfull: Swift 6 or later is needed (update Xcode / the Command Line Tools)"
  else ok "Swift $sfull ($(xcode-select -p))"; fi
fi

# Signing identity, if a real one was asked for.
if [ "$SIGN_IDENTITY" = "-" ]; then
  ok "signing: ad-hoc (set SIGN_IDENTITY to use your own certificate)"
elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$SIGN_IDENTITY\""; then
  ok "signing: $SIGN_IDENTITY"
else
  bad "signing identity not found in your keychain: $SIGN_IDENTITY (list: security find-identity -v -p codesigning)"
fi

# The Dynject engine is installed separately; Workbench only manages it.
if [ -x /opt/dynject/bin/dynjectd ] && [ -f /opt/dynject/etc/dynjectd.conf ]; then
  if pgrep -x dynjectd >/dev/null 2>&1; then ok "Dynject engine installed and running"
  else warn "Dynject engine installed but dynjectd isn't running (Workbench → Daemon can restart it)"; fi
  [ -f /Library/LaunchDaemons/com.dynject.dynjectd.plist ] || warn "no /Library/LaunchDaemons/com.dynject.dynjectd.plist: dynjectd won't start at boot"
else
  warn "Dynject engine not found in /opt/dynject: Workbench builds, but can't inject anything until you install it (see README: requirements)"
fi

if [ "$ERRORS" -gt 0 ]; then echo; echo "Fix the ✗ items above, then run this again."; exit 1; fi
[ "$CHECK_ONLY" = 1 ] && { echo; echo "Prerequisites OK ($WARNINGS warning(s))."; exit 0; }

echo
bold "Building Dynject Workbench and dw (release; first build takes a few minutes)"
"$ROOT/scripts/build-app.sh"
APP="$ROOT/build/Dynject Workbench.app"

if [ "$TWEAKS" = 1 ]; then
  echo
  bold "Building tweaks"
  (cd "$ROOT/Tweaks/MenuLoader" && ./build.sh)
  (cd "$ROOT/Examples/TitleBadge" && ./build.sh)
fi

if [ "$INSTALL" = 1 ]; then
  echo
  bold "Installing the app into $DEST"
  target="$DEST/Dynject Workbench.app"
  if pgrep -f "^$target/Contents/MacOS/DynjectWorkbench" >/dev/null 2>&1; then
    echo "Dynject Workbench is running from $target. Quit it, then run this again (or use --no-install)." >&2
    exit 1
  fi
  mkdir -p "$DEST"
  rm -rf "$target"
  ditto "$APP" "$target"
  codesign --verify --strict "$target"
  ok "installed $target"
  APP=$target
fi

DW="$APP/Contents/MacOS/dw"
echo
bold "Done"
cat <<EOF
Next steps:
  1. Open the app:            open "$APP"
  2. Turn on Safe Mode:       Workbench → Safe Mode → Install Watcher (no password; macOS may ask you to
                              allow a background item). It switches a tweak off for an app that it crashes.
  3. Try a tweak, e.g. MenuLoader (adds a "Dynject" submenu to the Apple menu) in TextEdit:
       "$DW" tweak install "$ROOT/Tweaks/MenuLoader" --for com.apple.TextEdit
     One password prompt copies the dylib, declares and enables it in the config and restarts dynjectd; the
     manifest goes to Workbench's Tweaks folder. Add --dry-run to see the plan first. (Or Workbench → Tweaks →
     Install Tweak….) Then relaunch the app: "$DW" respring
  4. Write your own:  "$DW" new MyTweak --app com.apple.TextEdit   (a folder with build.sh and the SDK)
  5. If an app misbehaves: hold Shift while launching it to skip tweaks for that launch, or use the panic
     switch in Workbench → Safe Mode.

  dw is inside the app; to use it from a terminal:  ln -s "$DW" /usr/local/bin/dw   (or add it to your PATH)
EOF
[ "$WARNINGS" -gt 0 ] && echo "(There were $WARNINGS warning(s) above.)"
exit 0
