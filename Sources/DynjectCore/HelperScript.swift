import Foundation

/// The only code that runs as root. It is passed inline to `/bin/sh -c` through
/// `do shell script … with administrator privileges`, so there is no script file on disk
/// that another process could swap between authorization and execution.
///
/// Commands:
///   install <target> <staged> <new-sha256> <expected-old-sha256|-> [restart]
///   restart
///
/// Output lines start with "DW " (progress) or "DW-ERROR " (stderr, then non-zero exit).
public enum HelperScript {
    public static let source = #"""
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LABEL=com.dynject.dynjectd
PLIST=/Library/LaunchDaemons/com.dynject.dynjectd.plist
B=""
# Test hook: command stubs are honoured only when NOT running as root.
if [ "$(id -u)" != "0" ] && [ -n "${DW_TEST_BIN:-}" ]; then B="$DW_TEST_BIN/"; PLIST="${DW_TEST_PLIST:-$PLIST}"; fi

say() { printf 'DW %s\n' "$*"; }
fail() { printf 'DW-ERROR %s\n' "$2" >&2; exit "$1"; }
sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/cut -c1-64; }
pids_of() { ${B}pgrep -x "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'; }
count_of() { ${B}pgrep -x "$1" 2>/dev/null | wc -l | tr -d ' '; }

# wait_gone NAME TENTHS -> 0 when no process NAME remains
wait_gone() {
  i=0
  while ${B}pgrep -x "$1" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt "$2" ]; then return 1; fi
    ${B}sleep 0.1
  done
  return 0
}

do_install() {
  target=$1; staged=$2; want=$3; old=$4
  case "$target" in /*) ;; *) fail 10 "target must be an absolute path" ;; esac
  [ -f "$staged" ] || fail 10 "staged file is missing: $staged"
  [ -L "$target" ] && fail 11 "refusing to replace a symbolic link: $target"
  if [ "$old" != "-" ]; then
    [ -f "$target" ] || fail 12 "$target no longer exists"
    cur=$(sha "$target")
    [ "$cur" = "$old" ] || fail 12 "$target changed on disk after it was loaded; reload and try again"
  fi
  dir=$(dirname "$target"); base=$(basename "$target")
  tmp=$(mktemp "$dir/.$base.dw.XXXXXX") || fail 13 "cannot create a temporary file in $dir"
  if ! cat "$staged" > "$tmp"; then rm -f "$tmp"; fail 13 "could not copy the staged file"; fi
  got=$(sha "$tmp")
  if [ "$got" != "$want" ]; then rm -f "$tmp"; fail 14 "staged content changed after validation; nothing was written"; fi
  if [ -e "$target" ]; then
    owner=$(stat -f '%u:%g' "$target"); mode=$(stat -f '%Lp' "$target")
  else
    owner="0:0"; mode=644
  fi
  if ! chown "$owner" "$tmp" || ! chmod "$mode" "$tmp"; then rm -f "$tmp"; fail 15 "could not set owner/mode on the new file"; fi
  if ! mv -f "$tmp" "$target"; then rm -f "$tmp"; fail 16 "atomic rename failed"; fi
  [ "$(sha "$target")" = "$want" ] || fail 17 "verification after write failed"
  say "installed $target sha256=$want owner=$owner mode=$mode"
}

# dynject_loader (the launchd job) spawns a detached dynjectd and exits, so launchd
# reports the job as not running and `kickstart -k` cannot stop the old daemon.
# Stop every dynjectd ourselves, confirm none remain, then start the job once.
do_restart() {
  wait_gone dynject_loader 100 || fail 20 "dynject_loader is still running after 10s; not restarting"
  before=$(pids_of dynjectd)
  say "running-before ${before:-none}"
  if [ -n "$before" ]; then
    ${B}kill -TERM $before 2>/dev/null
    if ! wait_gone dynjectd 50; then
      rest=$(pids_of dynjectd)
      say "sigkill $rest"
      ${B}kill -KILL $rest 2>/dev/null
      wait_gone dynjectd 30 || fail 21 "could not stop dynjectd ($(pids_of dynjectd)); not starting another"
    fi
  fi
  say "stopped-all"
  if ${B}launchctl print "system/$LABEL" >/dev/null 2>&1; then
    ${B}launchctl kickstart "system/$LABEL" >/dev/null || fail 23 "launchctl kickstart failed"
    say "kickstarted system/$LABEL"
  else
    [ -f "$PLIST" ] || fail 22 "$PLIST is missing"
    ${B}launchctl bootstrap system "$PLIST" || fail 22 "launchctl bootstrap failed"
    say "bootstrapped $PLIST"
  fi
  i=0
  while :; do
    n=$(count_of dynjectd)
    if [ "$n" -ge 1 ] && ! ${B}pgrep -x dynject_loader >/dev/null 2>&1; then break; fi
    i=$((i + 1))
    if [ "$i" -gt 150 ]; then break; fi
    ${B}sleep 0.1
  done
  n=$(count_of dynjectd)
  [ "$n" -ge 1 ] || fail 24 "dynjectd did not start; check /opt/dynject/log/dynjectd.error.log and the config"
  if [ "$n" -gt 1 ]; then
    newest=$(${B}pgrep -n -x dynjectd)
    extra=$(${B}pgrep -x dynjectd | grep -vx "$newest" | tr '\n' ' ')
    say "duplicate-after-start keeping=$newest stopping=$extra"
    ${B}kill -TERM $extra 2>/dev/null
    j=0
    while [ "$(count_of dynjectd)" -gt 1 ]; do
      j=$((j + 1)); if [ "$j" -gt 50 ]; then break; fi
      ${B}sleep 0.1
    done
  fi
  after=$(pids_of dynjectd)
  say "running-after $after"
  [ "$(count_of dynjectd)" -eq 1 ] || fail 25 "expected exactly one dynjectd, found: $after"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  install)
    [ $# -ge 4 ] || fail 2 "usage: install target staged new-sha old-sha [restart]"
    do_install "$1" "$2" "$3" "$4"
    shift 4
    if [ "${1:-}" = "restart" ]; then do_restart; fi
    ;;
  restart)
    do_restart
    ;;
  *)
    fail 2 "usage: install ... | restart"
    ;;
esac
say "ok"
"""#
}
