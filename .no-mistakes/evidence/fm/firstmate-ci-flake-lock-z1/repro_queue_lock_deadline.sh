#!/usr/bin/env bash
set -u
ROOT=$1
LABEL=$2
LIB="$ROOT/bin/fm-wake-lib.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pm-repro-XXXXXX")
STATE="$WORK/state"
mkdir -p "$STATE"
cleanup() {
  [ -z "${STEAL_HOLDER:-}" ] || kill "$STEAL_HOLDER" 2>/dev/null || true
  [ -z "${STEAL_HOLDER:-}" ] || wait "$STEAL_HOLDER" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_append signal task.status "signal: $2/task.status"' _ "$LIB" "$STATE" \
  || { echo "FAIL: could not seed the durable wake"; exit 2; }
bash -c '. "$1"; fm_lock_acquire_wait "$2"; printf "ready\n" > "$3"; exec sleep 30' \
  _ "$LIB" "$STATE/.wake-queue.lock" "$WORK/held.ready" &
HOLDER=$!
for _ in $(seq 1 100); do [ -s "$WORK/held.ready" ] && break; sleep 0.05; done
[ -s "$WORK/held.ready" ] || { echo "FAIL: primary holder never took the lock"; exit 2; }
kill -9 "$HOLDER" 2>/dev/null || true
wait "$HOLDER" 2>/dev/null || true
DEAD_PID=$(cat "$(readlink "$STATE/.wake-queue.lock")/pid" 2>/dev/null || true)
bash -c '. "$1"; fm_lock_acquire_wait "$2"; printf "ready\n" > "$3"; exec sleep 30' \
  _ "$LIB" "$STATE/.wake-queue.lock.steal" "$WORK/steal.ready" &
STEAL_HOLDER=$!
for _ in $(seq 1 100); do [ -s "$WORK/steal.ready" ] && break; sleep 0.05; done
[ -s "$WORK/steal.ready" ] || { echo "FAIL: recovery holder never took the slot"; exit 2; }
STEAL_PID=$(cat "$STATE/.wake-queue.lock.steal/pid" 2>/dev/null || true)
echo "== $LABEL =="
echo "stale (dead) owner pid record : $DEAD_PID"
echo "live recovery-slot holder pid : $STEAL_PID"
FM_ROOT_OVERRIDE="$WORK/not-a-repo" FM_STATE_OVERRIDE="$STATE" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 \
  bash "$DRAIN" > "$WORK/drain.out" 2> "$WORK/drain.err"
RC=$?
echo "drain exit code               : $RC"
echo "drain stdout                  :"
sed 's/^/  | /' "$WORK/drain.out"
echo "drain stderr                  :"
sed 's/^/  | /' "$WORK/drain.err"
if [ -s "$STATE/.wake-queue" ]; then echo "durable wake preserved        : yes"; else echo "durable wake preserved        : NO (queue was consumed)"; fi
exit 0
