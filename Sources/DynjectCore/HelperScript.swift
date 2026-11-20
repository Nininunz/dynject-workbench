import Foundation

/// The only code that runs as root. It is passed inline to `/bin/sh -c` through
/// `do shell script … with administrator privileges`, so there is no script file on disk
/// that another process could swap between authorization and execution.
///
/// Arguments: one or more operations, optionally followed by `restart`, or `restart` alone:
///   install <target> <staged> <new-sha256> <expected-old-sha256|->
///   remove  <target> <expected-sha256>     (only a regular *.dylib file directly in /opt/dynject/lib/tweaks)
///   restart                                (last; stops every dynjectd, starts exactly one)
///
/// Several operations run as one transaction: every operation is checked first (conflict hashes, paths), then
/// every new file is staged next to its target and verified, and only then are they renamed into place and the
/// removals done, in the order given. A failed check or staging writes nothing. `install a s n o restart`
/// (one file and a restart) is the original form.
///
/// Output lines start with "DW " (progress) or "DW-ERROR " (stderr, then non-zero exit).
public enum HelperScript {
    public static let source = #"""
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LABEL=com.dynject.dynjectd
PLIST=/Library/LaunchDaemons/com.dynject.dynjectd.plist
TWEAKS=/opt/dynject/lib/tweaks
B=""
# Test hooks: command stubs and another tweaks folder are honoured only when NOT running as root.
if [ "$(id -u)" != "0" ]; then
  if [ -n "${DW_TEST_BIN:-}" ]; then B="$DW_TEST_BIN/"; PLIST="${DW_TEST_PLIST:-$PLIST}"; fi
  TWEAKS="${DW_TEST_TWEAKS_DIR:-$TWEAKS}"
fi
NL='
'
TMPS=""

say() { printf 'DW %s\n' "$*"; }
cleanup() { [ -n "$TMPS" ] && printf '%s\n' "$TMPS" | while IFS= read -r t; do [ -n "$t" ] && rm -f "$t"; done; TMPS=""; }
fail() { printf 'DW-ERROR %s\n' "$2" >&2; cleanup; exit "$1"; }
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

# Phase 1 (nothing written): the checks for one operation.
check_install() {
  target=$1; staged=$2; old=$4
  case "$target" in /*) ;; *) fail 10 "target must be an absolute path" ;; esac
  case "$target" in *"$NL"*) fail 10 "target must not contain a line break" ;; esac
  [ -f "$staged" ] || fail 10 "staged file is missing: $staged"
  [ -L "$target" ] && fail 11 "refusing to replace a symbolic link: $target"
  if [ "$old" != "-" ]; then
    [ -f "$target" ] || fail 12 "$target no longer exists"
    cur=$(sha "$target")
    [ "$cur" = "$old" ] || fail 12 "$target changed on disk after it was loaded; reload and try again"
  fi
  return 0
}

# A removable file is a regular *.dylib file directly inside $TWEAKS, which must be a real (not symlinked)
# directory, owned by root when we are root.
check_remove() {
  target=$1; old=$2
  case "$target" in "$TWEAKS"/*.dylib) ;; *) fail 30 "refusing to remove $target: only *.dylib files in $TWEAKS can be removed" ;; esac
  name=${target#"$TWEAKS"/}
  case "$name" in */*|.*|*"$NL"*) fail 30 "refusing to remove $target: not a plain file name directly in $TWEAKS" ;; esac
  [ -L "$TWEAKS" ] && fail 31 "$TWEAKS is a symbolic link; not removing anything"
  [ -d "$TWEAKS" ] || fail 31 "$TWEAKS is missing"
  real=$(cd "$TWEAKS" && pwd -P) || fail 31 "cannot resolve $TWEAKS"
  [ "$real" = "$TWEAKS" ] || fail 31 "$TWEAKS resolves to $real; not removing anything"
  if [ "$(id -u)" = "0" ] && [ "$(stat -f '%u' "$TWEAKS")" != "0" ]; then fail 31 "$TWEAKS is not owned by root; not removing anything"; fi
  [ -L "$target" ] && fail 32 "refusing to remove a symbolic link: $target"
  [ -f "$target" ] || fail 33 "$target does not exist or is not a regular file"
  [ "$(sha "$target")" = "$old" ] || fail 34 "$target changed on disk after it was checked; nothing was removed"
  return 0
}

# Phase 2 (only temporary files): copy a staged file next to its target, verify it, set owner and mode.
stage_install() {
  target=$1; staged=$2; want=$3
  dir=$(dirname "$target"); base=$(basename "$target")
  tmp=$(mktemp "$dir/.$base.dw.XXXXXX") || fail 13 "cannot create a temporary file in $dir"
  TMPS="$TMPS$tmp$NL"
  cat "$staged" > "$tmp" || fail 13 "could not copy the staged file"
  got=$(sha "$tmp")
  [ "$got" = "$want" ] || fail 14 "staged content changed after validation; nothing was written"
  if [ -e "$target" ]; then
    owner=$(stat -f '%u:%g' "$target"); mode=$(stat -f '%Lp' "$target")
  else
    # A new file is root's (the invoking user's when not root, i.e. in tests).
    owner="$(id -u):$(id -g)"; mode=644
  fi
  if ! chown "$owner" "$tmp" || ! chmod "$mode" "$tmp"; then fail 15 "could not set owner/mode on the new file"; fi
  STAGED_TMP=$tmp; STAGED_OWNER=$owner; STAGED_MODE=$mode
}

# Phase 3: rename into place / remove, in the order given.
commit_install() {
  target=$1; want=$3; tmp=$2
  if ! mv -f "$tmp" "$target"; then fail 16 "atomic rename failed for $target"; fi
  [ "$(sha "$target")" = "$want" ] || fail 17 "verification after write failed: $target"
}

commit_remove() {
  target=$1; old=$2
  [ -L "$target" ] && fail 32 "refusing to remove a symbolic link: $target"
  [ "$(sha "$target")" = "$old" ] || fail 34 "$target changed on disk after it was checked"
  rm -f "$target" || fail 35 "could not remove $target"
  [ -e "$target" ] && fail 35 "$target is still there after removal"
  say "removed $target sha256=$old"
}

# Runs PASS (check, stage or commit) over every operation in the argument list.
each_op() {
  pass=$1; shift
  n=0
  while [ $# -gt 0 ]; do
    case "$1" in
      install)
        [ $# -ge 5 ] || fail 2 "usage: install target staged new-sha old-sha"
        n=$((n + 1))
        case "$pass" in
          check) check_install "$2" "$3" "$4" "$5" ;;
          stage)
            stage_install "$2" "$3" "$4"
            INFO="$INFO$2 sha256=$4 owner=$STAGED_OWNER mode=$STAGED_MODE$NL" ;;
          commit)
            tmp=$(printf '%s' "$TMPS" | sed -n "${n}p")
            commit_install "$2" "$tmp" "$4"
            say "installed $(printf '%s' "$INFO" | sed -n "${n}p")" ;;
        esac
        shift 5 ;;
      remove)
        [ $# -ge 3 ] || fail 2 "usage: remove target expected-sha"
        case "$pass" in
          check) check_remove "$2" "$3" ;;
          commit) commit_remove "$2" "$3" ;;
        esac
        shift 3 ;;
      restart)
        [ $# -eq 1 ] || fail 2 "restart must come last"
        shift ;;
      *) fail 2 "unknown operation: $1" ;;
    esac
  done
}

# dynject_loader (the launchd job) spawns a detached dynjectd and exits, so launchd
# reports the job as not running and `kickstart -k` cannot stop the old daemon.
# Stop every dynjectd ourselves, confirm none remain, then start the job once.
do_restart() {
  wait_gone dynject_loader 100 || fail 20 "dynject_loader is still running after 10s; not restarting"
  # dynject_loader patches amfid before it starts dynjectd and gives up ("amfid not found") when amfid,
  # which launchd starts on demand and stops when idle, isn't running. Start it first, before stopping
  # the old daemon, so a failure here leaves the running dynjectd alone.
  if ! ${B}pgrep -x amfid >/dev/null 2>&1; then
    ${B}launchctl kickstart system/com.apple.MobileFileIntegrity >/dev/null 2>&1
    k=0
    while ! ${B}pgrep -x amfid >/dev/null 2>&1; do
      k=$((k + 1))
      if [ "$k" -gt 50 ]; then fail 25 "amfid did not start; dynject_loader needs it. dynjectd was left running"; fi
      ${B}sleep 0.1
    done
    say "started amfid"
  fi
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

[ $# -gt 0 ] || fail 2 "usage: [install target staged new-sha old-sha | remove target sha]... [restart]"
INFO=""
each_op check "$@"
each_op stage "$@"
each_op commit "$@"
TMPS=""
for last in "$@"; do :; done
if [ "$last" = "restart" ]; then do_restart; fi
say "ok"
"""#
}
