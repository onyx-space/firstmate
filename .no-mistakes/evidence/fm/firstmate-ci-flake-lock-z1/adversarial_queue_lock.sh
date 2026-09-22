#!/usr/bin/env bash
# adversarial_queue_lock.sh <repo-root>
# Drives bin/fm-wake-drain.sh over the boundary shapes around the changed
# bounded-acquire verdict. Prints rc, stdout, stderr for each case.
set -u
ROOT=$1
LIB="$ROOT/bin/fm-wake-lib.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pm-adv-XXXXXX")
HOLDER_PID=
cleanup() {
  [ -z "${HOLDER_PID:-}" ] || kill "$HOLDER_PID" 2>/dev/null || true
  [ -z "${HOLDER_PID:-}" ] || wait "$HOLDER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

seed() { # <state>
  FM_STATE_OVERRIDE="$1" bash -c '. "$1"; fm_wake_append signal task.status "signal: $2/task.status"' \
    _ "$LIB" "$1" || return 1
}
start_hold() { # <lockpath> <readyfile> -> sets HOLDER_PID
  bash -c '. "$1"; fm_lock_acquire_wait "$2"; printf "ready\n" > "$3"; exec sleep 30' \
    _ "$LIB" "$1" "$2" >/dev/null 2>&1 &
  HOLDER_PID=$!
  local n=0
  while [ "$n" -lt 100 ] && [ ! -s "$2" ]; do sleep 0.05; n=$((n + 1)); done
  [ -s "$2" ]
}
stop_hold() {
  [ -z "${HOLDER_PID:-}" ] || kill "$HOLDER_PID" 2>/dev/null || true
  [ -z "${HOLDER_PID:-}" ] || wait "$HOLDER_PID" 2>/dev/null || true
  HOLDER_PID=
}
run() { # <state> <label> <timeout> [KEY=VAL ...]
  local state=$1 label=$2 to=$3
  shift 3
  echo "---- $label ----"
  FM_ROOT_OVERRIDE="$WORK/not-a-repo" FM_STATE_OVERRIDE="$state" \
    FM_STATUS_PRESENTATION_LOCK_TIMEOUT="$to" env "$@" \
    bash "$DRAIN" > "$WORK/out" 2> "$WORK/err"
  local rc=$?
  echo "exit: $rc"
  echo "stdout:"; sed 's/^/  | /' "$WORK/out"
  echo "stderr:"; sed 's/^/  | /' "$WORK/err"
  if [ -s "$state/.wake-queue" ]; then echo "durable wake preserved: yes"; else echo "durable wake preserved: no"; fi
  echo
}

# 1) Malformed (non-lock) queue path: the refusal guarantee must be untouched.
S1="$WORK/malformed"; mkdir -p "$S1"; seed "$S1" || exit 2
: > "$S1/.wake-queue.lock"
run "$S1" "malformed queue lock (regular file) => unsafe verdict expected" 1

# 2) A present firstmate-shaped lock with no nameable live holder: the new
#    unnamed-contention wording, drain still skipped, wake preserved.
S2="$WORK/unnamed"; mkdir -p "$S2"; seed "$S2" || exit 2
mkdir "$S2/.wake-queue.lock"
run "$S2" "fresh directory-shaped queue lock, no pid => unnamed contention" 1 \
  FM_LOCK_STALE_AFTER=60

# 3) A dead owner record with no live recovery: reclaimable, so the round must
#    run normally - a dead pid must never be reported as a live holder.
S3="$WORK/dead"; mkdir -p "$S3"; seed "$S3" || exit 2
start_hold "$S3/.wake-queue.lock" "$WORK/h3.ready" || { echo "FAIL: holder3"; exit 2; }
kill -9 "$HOLDER_PID" 2>/dev/null || true; wait "$HOLDER_PID" 2>/dev/null || true; HOLDER_PID=
run "$S3" "dead-owner queue lock only => reclaimed, round runs" 5

# 4) A live owner: ordinary contention, named pid.
S4="$WORK/live"; mkdir -p "$S4"; seed "$S4" || exit 2
start_hold "$S4/.wake-queue.lock" "$WORK/h4.ready" || { echo "FAIL: holder4"; exit 2; }
run "$S4" "live queue-lock owner => contention naming the live pid" 1
stop_hold

# 5) The second changed call site: status-presentation lock, present and
#    unnameable => the drain keeps the round and says it is still held.
S5="$WORK/presentation"; mkdir -p "$S5"; seed "$S5" || exit 2
mkdir "$S5/.status-presentation-lock"
run "$S5" "fresh directory-shaped status-presentation lock, no pid" 1 \
  FM_LOCK_STALE_AFTER=60

exit 0
