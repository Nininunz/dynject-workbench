#!/bin/sh
# Crash frames end to end (TODO: symbolicated tweak crash frames): a tweak built with -g crashes inside a helper its
# DynjectHook hook calls. Its dSYM is moved into a symbol store the crash reporter doesn't look in, so the report has
# the function but no line; `dw safemode explain` must add the line (atos, CrashSymbolicator) and name the hooked
# method (the "dynject.hooks:map" line DynjectHook logged). Writes one crash report, removed afterwards.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/../.." && pwd)
OUT="$DIR/build"
DW=${DW:-$ROOT/.build/debug/dw}
SDK=$(xcrun --show-sdk-path)
CC=$(xcrun -find clang)
REPORTS="$HOME/Library/Logs/DiagnosticReports"
rm -rf "$OUT"
mkdir -p "$OUT/lib/tweaks" "$OUT/manifests"
SYMBOLS=$(mktemp -d)   # not indexed by Spotlight, so the crash reporter can't find the dSYM there
trap 'rm -rf "$SYMBOLS"' EXIT
cc() { "$CC" -Wall -Wextra -Werror -fobjc-arc -isysroot "$SDK" -arch "$(uname -m)" "$@" || exit 1; }
cc -g -O1 -dynamiclib -fvisibility=hidden -I "$ROOT/TweakSDK/include" -framework Foundation -framework CoreGraphics \
  "$DIR/ch.m" "$ROOT/TweakSDK/DynjectHook.m" -o "$OUT/lib/tweaks/libch.dylib"
strip -S "$OUT/lib/tweaks/libch.dylib"
cc -framework Foundation "$DIR/host.m" -o "$OUT/crashhost"
for f in "$OUT/lib/tweaks/libch.dylib" "$OUT/crashhost"; do codesign --force --sign - --timestamp=none "$f" 2>/dev/null; done
[ -x "$DW" ] || { echo "no dw at $DW (swift build --product dw)"; exit 1; }

# The store's layout (TweakSymbolStore): one bundle per build, a link per UUID.
UUID=$(dwarfdump --uuid "$OUT/lib/tweaks/libch.dylib" | awk 'NR==1{print $2}')
mv "$OUT/lib/tweaks/libch.dylib.dSYM" "$SYMBOLS/libch.dylib-${UUID%%-*}.dSYM"
ln -s "libch.dylib-${UUID%%-*}.dSYM" "$SYMBOLS/$UUID.dSYM"

before=$(ls "$REPORTS"/crashhost-*.ips 2>/dev/null | wc -l)
DYLD_INSERT_LIBRARIES="$OUT/lib/tweaks/libch.dylib" "$OUT/crashhost" > "$OUT/host.out" 2>&1
echo "host exited with $?"
REPORT=
for _ in $(seq 60); do
  REPORT=$(ls -t "$REPORTS"/crashhost-*.ips 2>/dev/null | head -1)
  [ -n "$REPORT" ] && [ "$(ls "$REPORTS"/crashhost-*.ips | wc -l)" -gt "$before" ] && break
  REPORT=; sleep 0.5
done
[ -n "$REPORT" ] || { echo "[FAIL] no crash report in $REPORTS"; exit 1; }
sleep 1   # let the reporter finish writing
"$DW" safemode explain "$REPORT" --dylib-dir "$OUT/lib/tweaks" --tweaks-dir "$OUT/manifests" --symbols-dir "$SYMBOLS" > "$OUT/explain.txt" 2>&1
cat "$OUT/explain.txt"
LINE=$(grep -n "CRASH HERE" "$DIR/ch.m" | cut -d: -f1)
python3 -I - "$OUT/explain.txt" "$REPORT" "$LINE" <<'PY'
import json, sys
out = open(sys.argv[1]).read(); line = sys.argv[3]
body = json.loads(open(sys.argv[2]).read().split("\n", 1)[1])
frames = body["threads"][body["faultingThread"]]["frames"]
checks = []
def check(ok, what): checks.append(ok); print(("[PASS] " if ok else "[FAIL] ") + what)
check(not any("sourceLine" in f for f in frames), "the report itself has no source lines (the dSYM was out of the reporter's reach)")
check("crashed in it" in out, "Safe Mode puts the crash in the tweak")
check("CHExplode (ch.m:%s)" % line in out, "the function and its source line: CHExplode (ch.m:%s)" % line)
check("under its hook of -[CHTarget value]" in out, "the hook it ran under: -[CHTarget value]")
print("%d checks, %s" % (len(checks), "all passed" if all(checks) else "FAILED"))
sys.exit(0 if all(checks) else 1)
PY
status=$?
rm -f "$REPORT"
exit $status
