#!/bin/sh
# `dw hooks` end to end: a host process with three tweaks injected through DYLD_INSERT_LIBRARIES (A and B on
# DynjectHook, both hooking -[HHTarget value]; C swizzling without it), asked with `dw hooks --pid <pid> --scan --json`.
# No Dynject involved. The dylibs sit in build/lib/tweaks/ because the scan looks at images in lib/tweaks folders.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/../.." && pwd)
OUT="$DIR/build"
DW=${DW:-$ROOT/.build/debug/dw}
SDK=$(xcrun --show-sdk-path)
CC=$(xcrun -find clang)
rm -rf "$OUT"
mkdir -p "$OUT/lib/tweaks"
cc() { "$CC" -Wall -Wextra -Werror -fobjc-arc -isysroot "$SDK" -arch "$(uname -m)" "$@" || exit 1; }
for t in hha hhb; do
  cc -dynamiclib -fvisibility=hidden -I "$ROOT/TweakSDK/include" -framework Foundation -framework CoreGraphics \
    "$DIR/$t.m" "$ROOT/TweakSDK/DynjectHook.m" -o "$OUT/lib/tweaks/lib$t.dylib"
done
cc -dynamiclib -framework Foundation "$DIR/hhc.m" -o "$OUT/lib/tweaks/libhhc.dylib"
cc -framework Foundation "$DIR/host.m" -o "$OUT/host"
for f in "$OUT"/lib/tweaks/*.dylib "$OUT/host"; do codesign --force --sign - --timestamp=none "$f" 2>/dev/null; done
[ -x "$DW" ] || { echo "no dw at $DW (swift build --product dw)"; exit 1; }

L="$OUT/lib/tweaks"
DYLD_INSERT_LIBRARIES="$L/libhha.dylib:$L/libhhb.dylib:$L/libhhc.dylib" DH_DISABLE_SHIFT_BYPASS=1 "$OUT/host" > "$OUT/host.out" &
HOST=$!
for _ in $(seq 50); do grep -q ready "$OUT/host.out" 2>/dev/null && break; sleep 0.1; done
cat "$OUT/host.out"
"$DW" hooks --pid "$HOST" --scan --json > "$OUT/hooks.json"
"$DW" hooks --pid "$HOST" --scan > "$OUT/hooks.txt"
kill "$HOST" 2>/dev/null
cat "$OUT/hooks.txt"
python3 -I - "$OUT/hooks.json" "$OUT/host.out" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); host = open(sys.argv[2]).read()
checks = []
def check(ok, what): checks.append(ok); print(("[PASS] " if ok else "[FAIL] ") + what)
copies = {c["tweakID"]: c for c in r["copies"]}
check("value=111 other=2 third=33 ppid=1" in host, "the host saw the hooks: " + host.strip())
check(set(copies) == {"local.hooks.a", "local.hooks.b"}, "both DynjectHook tweaks answered: %s" % sorted(copies))
check(all(c["complete"] for c in r["copies"]), "both reports complete")
a, b = copies.get("local.hooks.a", {}), copies.get("local.hooks.b", {})
ha = {h["method"]: h for h in a.get("hooks", [])}; hb = {h["method"]: h for h in b.get("hooks", [])}
check(ha.get("-[HHTarget value]", {}).get("state") == "installed" and ha["-[HHTarget value]"]["top"] is False, "A's hook: installed, beneath")
check(hb.get("-[HHTarget value]", {}).get("top") is True, "B's hook: on top")
check(hb.get("-[HHTarget other]", {}).get("state") == "restored" and hb["-[HHTarget other]"].get("group") == "b-off", "B's grouped hook: restored, group b-off")
imp = [i for i in a.get("imports", []) if i["symbol"] == "getppid"]
check(len(imp) == 1 and imp[0]["sites"] >= 1 and imp[0]["active"], "A's import hook on getppid: %s" % imp)
conf = r["conflicts"]
check(len(conf) == 1 and conf[0]["method"] == "-[HHTarget value]" and conf[0]["top"] == "local.hooks.b" and sorted(conf[0]["tweakIDs"]) == ["local.hooks.a", "local.hooks.b"], "the clash on -[HHTarget value], B on top: %s" % conf)
fm = {(f["method"], f["image"].split("/")[-1]) for f in r["foreign"]}
check(("-[HHTarget third]", "libhhc.dylib") in fm, "the scan finds C's swizzle")
check(not any(m == "-[HHTarget value]" for m, _ in fm), "and doesn't repeat what DynjectHook reported")
print("%d checks, %s" % (len(checks), "all passed" if all(checks) else "FAILED"))
sys.exit(0 if all(checks) else 1)
PY
