#!/usr/bin/env bash
# fm-board-owner-liveness.sh - standing liveness watch for the board acquisition
# owner, a local single-owner job whose silent death would otherwise be noticed
# only when the next task tries to read the board.
#
# Usage:
#   fm-board-owner-liveness.sh [check]   probe, judge, and report a change
#   fm-board-owner-liveness.sh status    live readout plus the durable record
#   fm-board-owner-liveness.sh clear     re-baseline the record, printing nothing
#   fm-board-owner-liveness.sh arm       write and register state/<id>.check.sh
#   fm-board-owner-liveness.sh disarm    retire the check and its record
#   fm-board-owner-liveness.sh --help    print this help
#
# The watched target and both criteria come from the target's own runbook,
# $FM_HOME/data/elmo-board-acquisition-owner-lane/runbook.md, which stays the
# single owner of the target's start/stop procedure and its diagnosis table:
#
#   1. exactly one TCP connection to the board port, owned by the pid recorded in
#      the owner's lock file;
#   2. the owner exit's /api/pipeline-status signalGenSamples counter rises
#      between two reads taken FM_BOARD_OWNER_SAMPLE_GAP_SECS apart.
#
# Both are always read, because either alone is deceived: a socket that is still
# connected can carry no data at all (the owner's reconnect ladder holds the
# connection open while nothing is acquired), and a counter cannot be read at all
# once nothing answers.
#
# This script reports and nothing else. It never starts, stops, restarts, or
# signals the owner, and it never opens a connection to the board port: criterion
# 1 is read from `ss`, criterion 2 from the owner's read-only HTTP exit. The
# runbook's "no TCP probe of 9050" rule is a correctness rule rather than a
# preference, because a connect and close leaves a residual board session that
# makes the next acquisition start with zero blocks.
#
# Reporting is transition-only. One line is printed when the verdict changes
# (healthy -> unhealthy, unhealthy -> healthy, or the first observation of a
# verdict) and nothing at all while the verdict holds, because a watch that
# reported every probe is noise within minutes, and noise is what lets a real
# death go unnoticed. The durable record state/.board-owner-liveness carries the
# verdict and the epoch it began, so "down since" survives restarts of the
# watcher and of the agent; its timestamp is the first observation of the current
# verdict, never a claim about the true drop time.
#
# `arm` writes state/board-owner-liveness.check.sh and binds its bytes with
# fm-check-register.sh, so the watcher dispatches it on its own FM_CHECK_INTERVAL
# cadence and turns its one line into a `check:` wake. A registered custom check
# also counts toward the home's need for a live supervision cycle, so an armed
# home keeps one running; bin/fm-supervision-lib.sh owns that predicate.
#
# Every probe is bounded and the whole check is planned to finish inside the
# watcher's own FM_CHECK_TIMEOUT (default 30s), because a check the watcher kills
# prints nothing and writes no record, which would leave a slow host silent in
# exactly the way this watch exists to prevent. The plan is fitted to the bound
# rather than assumed to fit: the per-probe bound shrinks first, then the sample
# gap.
#
# Environment. The defaults target the one lane this script exists for, and each
# override is a manual-verification affordance: the watcher runs the defaults,
# because a check shim carries no environment of its own.
#   FM_BOARD_OWNER_HOME             owner instance dir (default
#                                   $FM_HOME/data/elmo-board-acquisition-owner-lane/host)
#   FM_BOARD_OWNER_LOCK             file holding the owner pid (default <that dir>/owner.lock)
#   FM_BOARD_OWNER_BOARD_PORT       board port whose connections are counted (default 9050)
#   FM_BOARD_OWNER_API_URL          owner HTTP exit (default http://127.0.0.1:17890)
#   FM_BOARD_OWNER_SAMPLE_GAP_SECS  gap between the two counter reads (default 5, 1..20)
#   FM_BOARD_OWNER_PROBE_BOUND_SECS bound on one ss or curl call (default 4, 1..20)
#   FM_CHECK_TIMEOUT                the watcher's per-check bound the plan fits inside
#                                   (default 30)
#   FM_HOME, FM_STATE_OVERRIDE      home and state root, as every home script reads them
#
# Exit status: 0 when a verdict was produced (an unhealthy one included), 1 when
# the record could not be written or the check could not be armed or retired, and
# 2 for a malformed argument or environment value.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.board-owner-liveness"
CHECK_ID=board-owner-liveness
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
SELF="$SCRIPT_DIR/fm-board-owner-liveness.sh"
RECORD_SCHEMA=fm-board-owner-liveness-v1
# Wide enough for two criterion reasons and both counter readings on one line.
MAX_LINE=240

OWNER_HOME="${FM_BOARD_OWNER_HOME:-$FM_HOME/data/elmo-board-acquisition-owner-lane/host}"
OWNER_LOCK="${FM_BOARD_OWNER_LOCK:-$OWNER_HOME/owner.lock}"
BOARD_PORT="${FM_BOARD_OWNER_BOARD_PORT:-9050}"
API_URL="${FM_BOARD_OWNER_API_URL:-http://127.0.0.1:17890}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-board-owner-liveness.sh [check]   probe, judge, and report a change
  fm-board-owner-liveness.sh status    live readout plus the durable record
  fm-board-owner-liveness.sh clear     re-baseline the record, printing nothing
  fm-board-owner-liveness.sh arm       write and register state/<id>.check.sh
  fm-board-owner-liveness.sh disarm    retire the check and its record
  fm-board-owner-liveness.sh --help    print this help

`check` prints one line only when the verdict changes, so the watcher turns that
line into a single `check:` wake and reports nothing while the verdict holds.
The verdict is unhealthy when either criterion from
$FM_HOME/data/elmo-board-acquisition-owner-lane/runbook.md fails:

  1. exactly one TCP connection to the board port, owned by the owner's pid;
  2. signalGenSamples rising between two reads of /api/pipeline-status.

The verdict and the time it began are recorded in state/.board-owner-liveness.
This script never starts, stops, or restarts the owner, and never connects to the
board port. Overrides (FM_BOARD_OWNER_HOME, FM_BOARD_OWNER_LOCK,
FM_BOARD_OWNER_BOARD_PORT, FM_BOARD_OWNER_API_URL,
FM_BOARD_OWNER_SAMPLE_GAP_SECS, FM_BOARD_OWNER_PROBE_BOUND_SECS) exist for manual
verification; the watcher always runs the defaults.
EOF
}

die_usage() {
  printf 'fm-board-owner-liveness: %s\n' "$1" >&2
  usage >&2
  exit 2
}

die_env() {
  printf 'fm-board-owner-liveness: %s\n' "$1" >&2
  exit 2
}

# --- clock and durations ----------------------------------------------------

now_epoch() {
  date +%s
}

# The fleet's one clock: Beijing time carrying its offset. TZ is pinned because
# the offset is appended literally, which keeps the form independent of whatever
# zone the host happens to be set to; China has no daylight saving, so a pinned
# Asia/Shanghai date is always +08:00.
epoch_to_iso() {
  local epoch=$1 stamp
  stamp=$(TZ=Asia/Shanghai date -r "$epoch" +%Y-%m-%dT%H:%M:%S 2>/dev/null)
  if [ -z "$stamp" ]; then
    stamp=$(TZ=Asia/Shanghai date -d "@$epoch" +%Y-%m-%dT%H:%M:%S 2>/dev/null)
  fi
  if [ -z "$stamp" ]; then
    printf '%s\n' "$epoch"
    return 0
  fi
  printf '%s+08:00\n' "$stamp"
}

format_duration() {
  local seconds=${1:-0}
  case "$seconds" in ''|*[!0-9]*) seconds=0 ;; esac
  if [ "$seconds" -ge 86400 ]; then
    printf '%dd%02dh' $((seconds / 86400)) $(((seconds % 86400) / 3600))
  elif [ "$seconds" -ge 3600 ]; then
    printf '%dh%02dm' $((seconds / 3600)) $(((seconds % 3600) / 60))
  elif [ "$seconds" -ge 60 ]; then
    printf '%dm%02ds' $((seconds / 60)) $((seconds % 60))
  else
    printf '%ds' "$seconds"
  fi
}

# --- probe bounds -----------------------------------------------------------

# A value the operator supplied is refused loudly rather than clamped: a
# malformed override is a mistake in a manual run, where the exit status and the
# diagnostic are visible, and the watcher never sets one.
require_bounded_int() {
  local name=$1 value=$2 low=$3 high=$4
  case "$value" in
    ''|*[!0-9]*) die_env "$name must be a whole number from $low to $high" ;;
  esac
  if [ "$value" -lt "$low" ] || [ "$value" -gt "$high" ]; then
    die_env "$name must be a whole number from $low to $high"
  fi
}

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
# fm_run_timed counts a whole second before it alarms, so the plan has to fit
# inside the watcher's own bound with the alarm and kill margins left over.
BUDGET=$((CHECK_TIMEOUT - 3))
[ "$BUDGET" -ge 1 ] || BUDGET=1

SAMPLE_GAP=${FM_BOARD_OWNER_SAMPLE_GAP_SECS:-5}
require_bounded_int FM_BOARD_OWNER_SAMPLE_GAP_SECS "$SAMPLE_GAP" 1 20
PROBE_BOUND=${FM_BOARD_OWNER_PROBE_BOUND_SECS:-4}
require_bounded_int FM_BOARD_OWNER_PROBE_BOUND_SECS "$PROBE_BOUND" 1 20

# One ss call and two curl calls are bounded; the sample gap is elapsed, not
# bounded, so it is planned separately. The per-probe bound is cut to what the
# budget can carry before the gap is touched, because a shorter gap still reads
# a rising counter while a probe that cannot run reads nothing.
PLAN_CALLS=3
PROBE_CEILING=$(((BUDGET - 1) / PLAN_CALLS))
[ "$PROBE_CEILING" -ge 1 ] || PROBE_CEILING=1
if [ "$PROBE_BOUND" -gt "$PROBE_CEILING" ]; then
  PROBE_BOUND=$PROBE_CEILING
fi
GAP_CEILING=$((BUDGET - PLAN_CALLS * PROBE_BOUND))
[ "$GAP_CEILING" -ge 1 ] || GAP_CEILING=1
if [ "$SAMPLE_GAP" -gt "$GAP_CEILING" ]; then
  SAMPLE_GAP=$GAP_CEILING
fi

# --- criterion 1: the board connection --------------------------------------

# The owner's recorded pid, read from its own lock file. The line is written by
# the owner as `pid=<n> port=<n> started=<...>`; the pid is taken by name rather
# than by position so a reordered line still reads.
read_owner_pid() {
  local line rest
  [ -f "$OWNER_LOCK" ] && [ ! -L "$OWNER_LOCK" ] || return 1
  IFS= read -r line < "$OWNER_LOCK" || return 1
  case "$line" in
    *pid=*) rest=${line#*pid=} ;;
    *) return 1 ;;
  esac
  rest=${rest%% *}
  case "$rest" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$rest"
}

# The board connections, from the kernel's own socket table. Only a socket whose
# PEER address is the board port counts, so an unrelated local socket that
# happens to sit on the same local port is never read as the board session.
# Usage is visible only for this user's own sockets, which is the same user the
# owner runs as here; a socket whose owner cannot be read is reported as not
# owned by the owner rather than assumed to be.
peer_connections() {
  local out rc=0
  command -v ss >/dev/null 2>&1 || return 2
  out=$(fm_run_timed "$PROBE_BOUND" ss -tnp 2>/dev/null) || rc=$?
  # The command's own status is passed through rather than flattened, because a
  # failure a reader has to act on is told apart from the bound being hit.
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$out" | awk -v port=":$BOARD_PORT" 'NF >= 5 && $5 ~ (port "$")'
}

# --- criterion 2: the acquisition counter -----------------------------------

# signalGenSamples out of the owner's pipeline-status payload. The value is read
# through the published read shape rather than a second parse of the JSON: the
# field is a flat top-level integer in a machine-written payload, and a payload
# that does not carry it is reported as missing rather than assumed healthy.
read_gen_samples() {
  local body value rc=0
  command -v curl >/dev/null 2>&1 || return 3
  body=$(fm_run_timed "$PROBE_BOUND" curl -fsS "$API_URL/api/pipeline-status" 2>/dev/null) \
    || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  value=$(printf '%s\n' "$body" \
    | sed -n 's/.*"signalGenSamples": *\([0-9][0-9]*\).*/\1/p' | tail -n 1)
  [ -n "$value" ] || return 2
  printf '%s\n' "$value"
}

# --- the verdict ------------------------------------------------------------

# probe_once sets VERDICT (healthy|unhealthy|unknown) and REASON. It reads both
# criteria even when the first already failed, because the second reason is what
# separates "nothing is listening" from "something is listening and silent", and
# that difference is the whole reason this watch reads two signals. It touches no
# record: only `check` and `clear` write.
# read_gen_samples' status codes, turned into the counter half of the verdict.
# 2 is a payload that does not carry the field: that is a real reading failure
# and not a missing tool, so it counts against the owner. 3 is a missing curl and
# makes the verdict unknown instead, because nothing about the owner was read.
# 124 is fm_run_timed's own bound being hit, which is reported distinctly from an
# exit the command chose, because the two send a reader to different places.
counter_verdict() {
  local rc=$1
  case "$rc" in
    0) verdict_counter=healthy ;;
    2) verdict_counter=unhealthy; reason_counter="$API_URL/api/pipeline-status carries no signalGenSamples" ;;
    3) verdict_counter=unknown; reason_counter="curl is not installed, so the owner exit cannot be read" ;;
    124) verdict_counter=unhealthy; reason_counter="$API_URL/api/pipeline-status did not answer within ${PROBE_BOUND}s" ;;
    *) verdict_counter=unhealthy; reason_counter="$API_URL/api/pipeline-status did not answer (curl exit $rc)" ;;
  esac
}

probe_once() {
  local owner_pid='' owner_alive=0 pid_reason='' conns='' conns_rc=0 count='' pids=''
  local verdict_peer='' verdict_counter='' reason_peer='' reason_counter=''
  local samples_rc=0 first='' second='' delta=''

  owner_pid=$(read_owner_pid) || owner_pid=
  if [ -z "$owner_pid" ]; then
    # The file's own name identifies it; its full path is in `status`, so a wake
    # line stays short enough to keep both criteria's facts on it.
    pid_reason="no owner pid recorded in ${OWNER_LOCK##*/}"
  elif kill -0 "$owner_pid" 2>/dev/null; then
    owner_alive=1
  else
    pid_reason="owner pid $owner_pid is not running"
  fi

  conns=$(peer_connections) || conns_rc=$?
  case "$conns_rc" in
    2)
      verdict_peer=unknown
      reason_peer="ss is not installed, so the board connection cannot be read"
      ;;
    0)
      count=$(printf '%s\n' "$conns" | grep -c . || true)
      pids=$(printf '%s\n' "$conns" | grep -o 'pid=[0-9][0-9]*' | cut -d= -f2 | sort -u | tr '\n' ' ')
      # The recorded identity comes first when it cannot be trusted, so the
      # reason says both what the record claims and what the kernel shows.
      if [ "$owner_alive" -ne 1 ]; then
        verdict_peer=unhealthy
        if [ "$count" -eq 0 ]; then
          reason_peer="$pid_reason; no TCP connection to :$BOARD_PORT"
        elif [ "$count" -gt 1 ]; then
          reason_peer="$pid_reason; $count TCP connections to :$BOARD_PORT (want exactly 1)"
        else
          reason_peer="$pid_reason; 1 TCP connection to :$BOARD_PORT owned by pid ${pids:-unknown}"
        fi
      elif [ "$count" -eq 0 ]; then
        verdict_peer=unhealthy
        reason_peer="no TCP connection to :$BOARD_PORT"
      elif [ "$count" -gt 1 ]; then
        verdict_peer=unhealthy
        reason_peer="$count TCP connections to :$BOARD_PORT (want exactly 1)"
      elif [ -z "$pids" ]; then
        verdict_peer=unhealthy
        reason_peer="the :$BOARD_PORT connection owner cannot be read; want owner pid $owner_pid"
      elif [ "$pids" != "$owner_pid " ]; then
        verdict_peer=unhealthy
        reason_peer="the :$BOARD_PORT connection is owned by pid ${pids% } rather than owner pid $owner_pid"
      else
        verdict_peer=healthy
      fi
      ;;
    *)
      verdict_peer=unknown
      reason_peer="ss failed to read the board connection (exit $conns_rc)"
      if [ "$conns_rc" -eq 124 ]; then
        reason_peer="ss did not answer within ${PROBE_BOUND}s"
      fi
      ;;
  esac

  first=$(read_gen_samples) || samples_rc=$?
  counter_verdict "$samples_rc"
  if [ "$verdict_counter" = healthy ]; then
    sleep "$SAMPLE_GAP"
    samples_rc=0
    second=$(read_gen_samples) || samples_rc=$?
    counter_verdict "$samples_rc"
    if [ "$verdict_counter" = healthy ]; then
      delta=$((second - first))
      if [ "$delta" -le 0 ]; then
        verdict_counter=unhealthy
        reason_counter="$API_URL/api/pipeline-status signalGenSamples is not rising ($first -> $second over ${SAMPLE_GAP}s)"
      fi
    fi
  fi

  case "$verdict_peer" in healthy) reason_peer=ok ;; esac
  case "$verdict_counter" in healthy) reason_counter=ok ;; esac
  VERDICT=healthy
  if [ "$verdict_peer" = unknown ] || [ "$verdict_counter" = unknown ]; then
    VERDICT=unknown
  elif [ "$verdict_peer" = unhealthy ] || [ "$verdict_counter" = unhealthy ]; then
    VERDICT=unhealthy
  fi
  case "$VERDICT" in
    healthy) REASON=ok ;;
    *)
      if [ "$reason_peer" = ok ]; then
        REASON=$reason_counter
      elif [ "$reason_counter" = ok ]; then
        REASON=$reason_peer
      else
        REASON="$reason_peer; $reason_counter"
      fi
      ;;
  esac
  REASON=$(printf '%s' "$REASON" | tr '\t\r\n' '   ')
  return 0
}

# --- the durable record -----------------------------------------------------

# A record is read defensively: it is a state file the check itself writes, but
# an unknown status or a non-numeric epoch would otherwise be evaluated as
# arithmetic later. A value that does not have the expected shape is dropped, so
# the worst case is a repeated first-observation report rather than a check that
# dies silently.
record_read() {
  local line first=1
  REC_STATUS=
  REC_SINCE_EPOCH=
  REC_SINCE=
  REC_CHECKED=
  REC_REASON=
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      status=healthy|status=unhealthy|status=unknown) REC_STATUS=${line#status=} ;;
      since_epoch=*) REC_SINCE_EPOCH=${line#since_epoch=} ;;
      since=*) REC_SINCE=${line#since=} ;;
      checked=*) REC_CHECKED=${line#checked=} ;;
      reason=*) REC_REASON=${line#reason=} ;;
    esac
  done < "$RECORD"
  case "$REC_SINCE_EPOCH" in
    ''|*[!0-9]*) REC_SINCE_EPOCH= ;;
  esac
  return 0
}

# record_write <verdict> <since-epoch> <since-iso> <checked-iso> <reason>
record_write() {
  local verdict=$1 since_epoch=$2 since_iso=$3 checked_iso=$4 reason=$5 tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-board-owner-liveness.XXXXXX" 2>/dev/null) || return 1
  if ! {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'status=%s\n' "$verdict"
    printf 'since_epoch=%s\n' "$since_epoch"
    printf 'since=%s\n' "$since_iso"
    printf 'checked=%s\n' "$checked_iso"
    printf 'reason=%s\n' "$reason"
  } > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

# --- actions ----------------------------------------------------------------

# The comparison is against the recorded verdict alone, so a verdict that holds
# stays silent no matter how many probes run, and every change is news exactly
# once. The line is printed BEFORE the record is written, so a record that cannot
# be written costs a repeated report rather than a lost one.
action_check() {
  local now now_iso line='' since_epoch previous
  mkdir -p "$STATE" || return 1
  probe_once
  now=$(now_epoch)
  now_iso=$(epoch_to_iso "$now")
  record_read
  previous=$REC_STATUS
  if [ -z "$previous" ]; then
    case "$VERDICT" in
      healthy) line="board-owner healthy (first observed $now_iso)" ;;
      unhealthy) line="board-owner down (first observed $now_iso): $REASON" ;;
      *) line="board-owner liveness unknown (first observed $now_iso): $REASON" ;;
    esac
    since_epoch=$now
  elif [ "$previous" = "$VERDICT" ]; then
    since_epoch=${REC_SINCE_EPOCH:-$now}
  else
    since_epoch=$now
    case "$VERDICT" in
      healthy)
        if [ "$previous" = unhealthy ]; then
          line="board-owner recovered after $(format_duration $((now - ${REC_SINCE_EPOCH:-$now}))) (down since ${REC_SINCE:-unknown})"
        else
          line="board-owner healthy again after $(format_duration $((now - ${REC_SINCE_EPOCH:-$now}))) (was unknown)"
        fi
        ;;
      unhealthy) line="board-owner down since $now_iso: $REASON" ;;
      *) line="board-owner liveness unknown since $now_iso: $REASON" ;;
    esac
  fi
  if [ -n "$line" ]; then
    fm_cap_line_var "board-owner-liveness: $line" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
  fi
  record_write "$VERDICT" "$since_epoch" "$(epoch_to_iso "$since_epoch")" "$now_iso" "$REASON" || {
    printf 'fm-board-owner-liveness: could not write %s\n' "$RECORD" >&2
    return 1
  }
  return 0
}

# A live readout for a human: the verdict now, and what the durable record holds.
# It deliberately writes nothing, so an observation never consumes the change
# that `check` still owes the supervisor.
action_status() {
  local now verdict_since
  probe_once
  now=$(now_epoch)
  record_read
  printf 'board-owner-liveness: %s - %s\n' "$VERDICT" "$REASON"
  printf 'checked now: %s\n' "$(epoch_to_iso "$now")"
  if [ -z "$REC_STATUS" ]; then
    printf 'record: %s (no record yet)\n' "$RECORD"
  else
    verdict_since=${REC_SINCE_EPOCH:-}
    case "$verdict_since" in
      ''|*[!0-9]*) printf 'record: %s status=%s since=%s\n' "$RECORD" "$REC_STATUS" "${REC_SINCE:-unknown}" ;;
      *)
        printf 'record: %s status=%s since=%s (%s ago)\n' "$RECORD" "$REC_STATUS" \
          "${REC_SINCE:-unknown}" "$(format_duration $((now - verdict_since)))"
        ;;
    esac
    printf 'record reason: %s\n' "${REC_REASON:-}"
    printf 'record checked: %s\n' "${REC_CHECKED:-unknown}"
  fi
  printf 'watching: port=%s api=%s lock=%s gap=%ss probe=%ss\n' \
    "$BOARD_PORT" "$API_URL" "$OWNER_LOCK" "$SAMPLE_GAP" "$PROBE_BOUND"
  return 0
}

# The manual clear: record the verdict that is true now without printing it, so
# an alarm the operator has already seen stops being news and the next CHANGE is
# what wakes the supervisor. It never suppresses a future change.
action_clear() {
  local now now_iso
  mkdir -p "$STATE" || return 1
  probe_once
  now=$(now_epoch)
  now_iso=$(epoch_to_iso "$now")
  record_write "$VERDICT" "$now" "$now_iso" "$now_iso" "$REASON" || {
    printf 'fm-board-owner-liveness: could not write %s\n' "$RECORD" >&2
    return 1
  }
  printf 'cleared: recorded board-owner-liveness %s as of %s with no wake line\n' "$VERDICT" "$now_iso"
  return 0
}

# --- arming -----------------------------------------------------------------

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-board-owner-liveness.sh - board-owner liveness check shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SELF") check"
}

SHIM_WRITE_TMP=

# Write the shim the way this repo writes its other trusted check shims: the
# guards run before anything is written, so a symlink at the shim path is refused
# instead of followed, and the bytes arrive by rename so the watcher never reads a
# half-written shim and rejects it as unauthenticated.
shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-board-owner-liveness.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes the supervisor about an unauthenticated state check. So the one rule
# after a failed or interrupted arm is that the home never holds a shim without a
# matching trust binding, and the guarded unregister owner - never a hand-built
# rm of a state artifact - is what puts that right.
#
# deferred: no byte copy of a previously armed shim is kept. A failed re-arm
# therefore ends unarmed rather than restored, and re-running arm is the recovery.
arm_rollback() {
  local home=$1
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  FM_HOME="$home" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null 2>&1 || {
    printf 'fm-board-owner-liveness: state/%s.check.sh could not be retired after a failed arm; retire it with %s unregister\n' \
      "$CHECK_ID" "$UNREGISTER_BIN" >&2
    return 1
  }
  return 0
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback "${ARM_HOME:-$FM_HOME}"
  printf 'fm-board-owner-liveness: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  [ -x "$SELF" ] || {
    printf 'fm-board-owner-liveness: the check script is missing at %s; cannot arm\n' "$SELF" >&2
    return 1
  }
  [ -x "$REGISTER_BIN" ] || {
    printf 'fm-board-owner-liveness: %s is missing; cannot arm\n' "$REGISTER_BIN" >&2
    return 1
  }
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-board-owner-liveness: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_HOME=$home
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback "$home" || true
    printf 'fm-board-owner-liveness: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback "$home" || true
    printf 'fm-board-owner-liveness: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  local rc=0
  FM_HOME="$FM_HOME" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null || rc=$?
  rm -f -- "$RECORD"
  [ "$rc" -eq 0 ] || return "$rc"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  status) action_status ;;
  clear) action_clear ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
