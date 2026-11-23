#!/bin/sh
# test-all: every test that leaves the live system alone, one summary at the end.
#
#   scripts/test-all.sh           unit tests, the app, every bundled tweak's build and test host, and a fresh
#                                 `dw new` tweak taken through build, install, list and uninstall in a fake root
#                                 (~2 min). the test hosts are accessory apps: they never take focus.
#   scripts/test-all.sh --quick   unit tests and builds only (no test hosts)
#   scripts/test-all.sh --all     also respring-e2e, bridge-e2e and the ui smoke test. those open test apps, load
#                                 a temporary agent and drive workbench's ui (accessibility permission).
#   scripts/test-all.sh --stop    stop at the first failure
#
# never touched: /opt/dynject, the live config, real apps, the real agents and dynject.* keys.
# logs: .build/test-all/<step>.log. exit 1 if anything failed.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOGS="$ROOT/.build/test-all"
mode=default stop=0
for a in "$@"; do
  case $a in
    --quick) mode=quick ;; --all) mode=all ;; --stop) stop=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "test-all: unknown option $a (see --help)" >&2; exit 2 ;;
  esac
done
rm -rf "$LOGS"; mkdir -p "$LOGS"
passed=0 failed=0 failures="" start=$(date +%s)

finish() {
  echo
  echo "$passed passed, $failed failed in $(( $(date +%s) - start ))s ($mode)"
  [ "$failed" -eq 0 ] || { printf 'failed:%s\n' "$failures"; exit 1; }
  exit 0
}

# What a passing step's log says about itself, for the summary line.
note() {
  case $1 in
    swift-test)
      awk "/Test Suite '.*\\.xctest' (passed|failed)/{x=1;next} x&&/Executed/{n+=\$2;x=0} END{if(n)print \"  \" n \" tests\"}" "$2" ;;
    *-host)
      awk '/[0-9]+ checks/{for(i=1;i<NF;i++)if($(i+1)~/^checks/&&$i~/^[0-9]+$/){n+=$i}} END{if(n)print "  " n " checks"}' "$2" ;;
  esac
}

# step <name> <command...>: runs it from the repo root, output to its log.
step() {
  name=$1; shift
  log="$LOGS/$name.log"
  printf '%-22s ' "$name"
  t0=$(date +%s)
  (cd "$ROOT" && "$@") >"$log" 2>&1; rc=$?
  dt=$(( $(date +%s) - t0 ))
  if [ "$rc" -eq 0 ]; then
    passed=$((passed + 1)); printf '✓ %4ss%s\n' "$dt" "$(note "$name" "$log")"
  else
    failed=$((failed + 1)); failures="$failures $name"
    printf '✗ %4ss  exit %s, log: %s\n' "$dt" "$rc" "${log#"$ROOT"/}"
    tail -20 "$log" | sed 's/^/      /'
    [ "$stop" -eq 0 ] || finish
  fi
}

# shellcheck disable=SC2329  # called through step
in_dir() { (cd "$1" && shift && "$@"); }

# A tweak as an author starts one: dw new, build, then install, list and uninstall against a fake root
# (restarts simulated, no administrator prompt).
# shellcheck disable=SC2329  # called through step
template() {
  dw="$ROOT/.build/debug/dw" t="$LOGS/template"
  swift build --product dw &&
  "$dw" new TestAllTweak --app com.apple.TextEdit --dir "$t/TestAllTweak" &&
  in_dir "$t/TestAllTweak" ./build.sh &&
  # dynjectd won't run with no dylib line, so uninstall refuses to remove the last one: start with another.
  mkdir -p "$t/root/etc" && echo "dylib:/opt/dynject/lib/tweaks/libOther.dylib:deny" > "$t/root/etc/dynjectd.conf" &&
  "$dw" tweak install "$t/TestAllTweak" --root "$t/root" &&
  "$dw" tweak list --root "$t/root" | tee "$t/list.txt" &&
  grep -q "DynjectHook" "$t/list.txt" &&
  "$dw" tweak uninstall "$t/TestAllTweak/TestAllTweak.workbench.plist" --root "$t/root" &&
  ! grep -q TestAllTweak "$t/root/etc/dynjectd.conf"
}

# The generated tweak's own test host (`./build.sh test`), in the folder the template step made.
template_host() {
  in_dir "$LOGS/template/TestAllTweak" ./build.sh test
}

# One `dw dev` round on that tweak (build, test host, install into a fake root), then a second that finds nothing
# to install.
dev_once() {
  dw="$ROOT/.build/debug/dw" t="$LOGS/template"
  mkdir -p "$t/devroot/etc" && echo "dylib:/opt/dynject/lib/tweaks/libOther.dylib:deny" > "$t/devroot/etc/dynjectd.conf" &&
  "$dw" dev "$t/TestAllTweak" --once --root "$t/devroot" &&
  grep -q TestAllTweak "$t/devroot/etc/dynjectd.conf" &&
  "$dw" dev "$t/TestAllTweak" --once --root "$t/devroot" | tee "$t/dev2.txt" &&
  grep -q "unchanged, skipped" "$t/dev2.txt"
}

echo "test-all ($mode), logs in ${LOGS#"$ROOT"/}/"
echo
step swift-test        swift test
step app               scripts/build-app.sh
step menuloader        in_dir Tweaks/MenuLoader ./build.sh
step inspector         in_dir Tweaks/Inspector ./build.sh
step oledfinder        in_dir Examples/OLEDFinder ./build.sh
step titlebadge        in_dir Examples/TitleBadge ./build.sh
step notchpadding      in_dir Examples/NotchPadding ./build.sh
step template          template

if [ "$mode" != quick ]; then
  step menuloader-host Tweaks/MenuLoader/testhost/run.sh
  step inspector-host  in_dir Tweaks/Inspector ./build.sh test
  step oledfinder-host in_dir Examples/OLEDFinder ./build.sh test
  step titlebadge-host in_dir Examples/TitleBadge ./build.sh test
  step notchpadding-host in_dir Examples/NotchPadding ./build.sh test
  step imports-host    Tests/ImportHost/run.sh
  step template-host   template_host
  step dev-once        dev_once
  step hooks-host      Tests/HooksHost/run.sh
fi

if [ "$mode" = all ]; then
  step respring-e2e    scripts/respring-e2e.sh
  step bridge-e2e      scripts/bridge-e2e.sh
  step ui-smoke        scripts/ui-smoke-test.sh
fi

finish
