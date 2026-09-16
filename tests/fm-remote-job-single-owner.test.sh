#!/usr/bin/env bash
# Behavior tests for exclusive remote job worker ownership and claim recovery.
#
# A remote queue is served by exactly one worker per state root. Two live
# workers on one queue race the same job records: each clears the other's
# claim, neither publishes a result, and the caller is told its job stopped even
# though the bytes were already produced. Four cases pin that invariant:
# concurrent starts agree on one owner, a live owner is never displaced by a
# replacement's staleness guess, a claim in flight is never erased by a sibling,
# and ownership survives a host whose mkdir reports success for a directory
# another process created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-job-single-owner)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/state"
LYING_BIN="$TMP_ROOT/lying-bin"
STARTED_PIDS=()
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME" "$LYING_BIN"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-record-job.sh" <<'SH'
#!/bin/bash
sleep "$1"
printf 'ran\n' > "$2"
SH
# A host whose mkdir cannot decide ownership: it hands every caller of a
# contended path a success, as WSL2 with a cargo-built coreutils did (5 of 12
# concurrent creators told they had created one directory).
cat > "$LYING_BIN/mkdir" <<'SH'
#!/bin/bash
/bin/mkdir "$@" 2>/dev/null
exit 0
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh "$LYING_BIN/mkdir"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'remote job fixture'

# Each worker is its own process group, so this reaches the lane children as
# well: a lane that outlives its worker keeps writing into the fixture and makes
# the fixture removal race its own output.
stop_started_workers() {
  local pid
  for pid in "${STARTED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -CONT "$pid" 2>/dev/null || true
    kill -TERM -- "-$pid" 2>/dev/null || true
  done
  sleep 0.2
  for pid in "${STARTED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
  done
  sleep 0.2
}

cleanup_single_owner_fixture() {
  stop_started_workers
  fm_test_cleanup
}
trap cleanup_single_owner_fixture EXIT

export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

# start_serve <tag> <state-root> [path-prefix]: start one serving worker on the
# given state root and record it in SERVE_PID and STARTED_PIDS.
#
# The pid is reported through a variable rather than standard output because
# every call site would otherwise capture it with a command substitution, and
# the STARTED_PIDS append would then run in that subshell: the parent's array
# would stay empty, cleanup would reap nothing, and the worker would outlive the
# fixture.
SERVE_PID=
start_serve() {
  local tag=$1 root=$2 prefix=${3:-} launch_path=$PATH
  [ -z "$prefix" ] || launch_path="$prefix:$PATH"
  set -m
  HOME="$ACCOUNT_HOME" PATH="$launch_path" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
    FM_REMOTE_JOB_STATE_ROOT="$root" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
    > "$TMP_ROOT/$tag.out" 2> "$TMP_ROOT/$tag.err" &
  SERVE_PID=$!
  set +m
  STARTED_PIDS+=("$SERVE_PID")
}

# alive_count <pid...>: how many of the given processes are still running
alive_count() {
  local pid alive=0
  for pid in "$@"; do
    kill -0 "$pid" 2>/dev/null && alive=$((alive + 1))
  done
  printf '%s\n' "$alive"
}

# await_single_owner <state-root> <pid...>: exactly one given pid is alive and
# it is the recorded owner of the queue. The three conditions are checked
# together because a loser exits long before the winner finishes publishing:
# waiting only for the alive count to drop would sample the queue mid-publish.
await_single_owner() {
  local root=$1 owner alive
  shift
  for _ in $(seq 1 220); do
    owner=$(cat "$root/worker.pid" 2>/dev/null || true)
    if [ -n "$owner" ] && [ "$(alive_count "$@")" -eq 1 ] \
      && [ "$(cat "$root/worker.lock/pid" 2>/dev/null || true)" = "$owner" ]; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

# --- concurrent starts agree on one owner ---------------------------------
#
# Every starter runs the same first-time preparation of the queue. A starter
# that failed on the EEXIST its own sibling had just created reported the queue
# as unsafe and exited, which left the launcher retrying a worker that was never
# broken. All six must reach the ownership decision instead.
BURST_PIDS=()
for i in 1 2 3 4 5 6; do
  start_serve "burst-$i" "$STATE_ROOT"
  BURST_PIDS+=("$SERVE_PID")
done
await_single_owner "$STATE_ROOT" "${BURST_PIDS[@]}" \
  || fail "concurrent starters did not settle on one serving worker"
for i in 1 2 3 4 5 6; do
  for pattern in 'remote job queue is unsafe' 'remote job sequence claims are unsafe' \
    'remote job log directory is unsafe' 'cannot acquire or safely reclaim worker ownership'; do
    assert_no_grep "$pattern" "$TMP_ROOT/burst-$i.err" \
      "concurrent start $i failed on state it should have shared: $pattern"
  done
done
pass "concurrent starters collapse onto one owner without state-prep race errors"

# --- a live owner is never displaced by a staleness guess -----------------
#
# The replacement decision used to read a stale readiness heartbeat and an old
# lock directory as proof the owner was gone, then deleted that live owner's
# ownership record. The owner here is paused long enough for both signals to go
# stale, and its command record is left unmatchable on purpose: the identity
# that decides ownership has to be the live pid, never a rendering of it.
OWNER=$(cat "$STATE_ROOT/worker.pid")
SIDE_EFFECT="$TMP_ROOT/recorded-job"
kill -STOP "$OWNER" || fail "the ownership fixture could not pause the live owner"
touch -t 200001010000 "$STATE_ROOT/worker.ready" "$STATE_ROOT/worker.lock"
printf 'unmatchable-record\n' >> "$STATE_ROOT/worker.lock/command"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-record-job.sh 3 "$SIDE_EFFECT" < /dev/null > /dev/null \
  || fail "$FM_REMOTE_JOB_ERROR"
JOB_ID=$FM_REMOTE_JOB_ID
start_serve outsider "$STATE_ROOT"
OUTSIDER=$SERVE_PID
sleep 1.5
[ "$(cat "$STATE_ROOT/worker.lock/pid")" = "$OWNER" ] \
  || fail "a replacement displaced a live owner's ownership record"
[ "$(cat "$STATE_ROOT/worker.pid")" = "$OWNER" ] \
  || fail "a replacement claimed the queue while its live owner still served it"
kill -CONT "$OWNER"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the interrupted job did not run to a normal completion"
assert_present "$SIDE_EFFECT" "the job owned by a live worker never ran"
for log in "$TMP_ROOT"/burst-*.err "$TMP_ROOT/outsider.err"; do
  assert_no_grep 'could not publish result' "$log" "two owners raced the same job record: $log"
  assert_no_grep 'File exists' "$log" "two owners raced the same claim or pipe: $log"
  assert_no_grep 'No such file or directory' "$log" \
    "two owners erased each other's claim records: $log"
done
kill -TERM "$OUTSIDER" 2>/dev/null || true
wait "$OUTSIDER" 2>/dev/null || true
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || true
pass "a live owner keeps the queue against a replacement's staleness guess"

# --- a freshly published claim is never erased by a sibling ----------------
#
# A claimant creates its claim directory before it can publish the owner record
# inside it. Judging that window as an abandoned claim is what let two workers
# erase each other: the sibling's record vanished mid-publish and it then failed
# on its own half-written claim. The fresh claim must hold the job until the
# grace passes, and an aged one must still be recovered.
CLAIM_JOB_EFFECT="$TMP_ROOT/claim-job"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-record-job.sh 0 "$CLAIM_JOB_EFFECT" < /dev/null > /dev/null \
  || fail "$FM_REMOTE_JOB_ERROR"
CLAIM_JOB_ID=$FM_REMOTE_JOB_ID
CLAIM_JOB_DIR="$STATE_ROOT/jobs/$CLAIM_JOB_ID"
mkdir "$CLAIM_JOB_DIR/.claim"
sleep 1
assert_present "$CLAIM_JOB_DIR/.claim" "a sibling erased a claim that was still being published"
assert_absent "$CLAIM_JOB_EFFECT" "a job was run while a sibling's in-flight claim still held it"
touch -t 200001010000 "$CLAIM_JOB_DIR/.claim"
fm_remote_job_wait "$ACCOUNT_HOME" "$CLAIM_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the recovered claim's job did not complete"
assert_present "$CLAIM_JOB_EFFECT" "an abandoned claim was never recovered"
fm_remote_job_reap "$ACCOUNT_HOME" "$CLAIM_JOB_ID" || true
pass "a claim in flight is held for the grace and recovered after it"

# --- ownership survives a host whose mkdir cannot decide it ----------------
#
# The host this worker runs on may hand every concurrent mkdir of one path a
# success. Ownership has to rest on an exclusive create that cannot admit two
# winners, so the same burst must still leave exactly one serving worker.
LYING_STATE="$TMP_ROOT/lying-state"
mkdir -p "$LYING_STATE"
LYING_PIDS=()
for i in 1 2 3 4 5 6; do
  start_serve "lying-$i" "$LYING_STATE" "$LYING_BIN"
  LYING_PIDS+=("$SERVE_PID")
done
await_single_owner "$LYING_STATE" "${LYING_PIDS[@]}" \
  || fail "a host whose mkdir always reports success left more than one owner"
for i in 1 2 3 4 5 6; do
  assert_no_grep 'could not publish result' "$TMP_ROOT/lying-$i.err" \
    "lying-mkdir start $i lost a job it owned"
done
pass "ownership survives a host whose mkdir reports false success"

# --- several replacements on one stale record leave one owner ---------------
#
# A crash leaves a lock whose owner is gone, and every replacement that sees it
# may decide to displace it. Displacement has to be one atomic act that exactly
# one of them can win: the check-then-act version deleted records by path, so a
# replacement that lost the removal race deleted the record the winner had just
# published, and both served.
STALE_STATE="$TMP_ROOT/stale-state"
mkdir -p "$STALE_STATE/worker.lock"
sleep 0.1 &
STALE_PID=$!
wait "$STALE_PID" 2>/dev/null || true
printf '%s\n' "$STALE_PID" > "$STALE_STATE/worker.lock/pid"
printf 'dead-owner-start\n' > "$STALE_STATE/worker.lock/start"
printf 'dead-owner-command\n' > "$STALE_STATE/worker.lock/command"
STALE_PIDS=()
for i in 1 2 3 4 5 6; do
  start_serve "stale-$i" "$STALE_STATE"
  STALE_PIDS+=("$SERVE_PID")
done
await_single_owner "$STALE_STATE" "${STALE_PIDS[@]}" \
  || fail "replacements racing one stale record did not settle on one owner"
for log in "$TMP_ROOT"/stale-*.err; do
  assert_no_grep 'cannot acquire or safely reclaim' "$log" \
    "a replacement reported the reclaim it lost as a startup failure: $log"
done
[ -f "$STALE_STATE/worker.ready" ] \
  || fail "the winner of a stale-record displacement never became ready"
assert_absent "$STALE_STATE/worker.lock/.reclaim" \
  "a reclaim left its own gate behind in the lock it removed"
pass "replacements racing one stale record leave exactly one owner"

# --- a live pid the record cannot disprove is never displaced ---------------
#
# A record whose live pid the reader-independent stamp cannot disprove is held,
# not reclaimed, even when its rendered start and command disagree with the live
# process: that text is recomputed from the reader's clock domain, so it can
# describe a live owner wrongly. The record must survive untouched, the process
# answering the pid must not be signalled, and the loop must report why it
# refused instead of quietly yielding.
REFUSE_STATE="$TMP_ROOT/refuse-state"
mkdir -p "$REFUSE_STATE/worker.lock"
sleep 20 &
REFUSED_PID=$!
printf '%s\n' "$REFUSED_PID" > "$REFUSE_STATE/worker.lock/pid"
printf 'rendered-elsewhere\n' > "$REFUSE_STATE/worker.lock/start"
printf 'rendered-elsewhere\n' > "$REFUSE_STATE/worker.lock/command"
chmod 700 "$REFUSE_STATE/worker.lock"
chmod 600 "$REFUSE_STATE/worker.lock/pid" "$REFUSE_STATE/worker.lock/start" \
  "$REFUSE_STATE/worker.lock/command"
start_serve refuse "$REFUSE_STATE"
for _ in $(seq 1 200); do
  grep -Fq 'cannot prove that pid gone' "$TMP_ROOT/refuse.err" 2>/dev/null && break
  sleep 0.05
done
[ "$(cat "$REFUSE_STATE/worker.lock/pid")" = "$REFUSED_PID" ] \
  || fail "a live pid the record could not disprove was displaced"
[ "$(cat "$REFUSE_STATE/worker.lock/start")" = 'rendered-elsewhere' ] \
  || fail "a refusal rewrote the record it refused to displace"
kill -0 "$REFUSED_PID" 2>/dev/null || fail "the process answering the recorded pid was signalled"
assert_grep 'cannot prove that pid gone' "$TMP_ROOT/refuse.err" \
  "the refusing worker did not report why it refused: $(cat "$TMP_ROOT/refuse.err")"
assert_grep "remove $REFUSE_STATE/worker.lock by hand" "$TMP_ROOT/refuse.err" \
  "the refusal did not name the safe manual recovery: $(cat "$TMP_ROOT/refuse.err")"
kill "$REFUSED_PID" 2>/dev/null || true
wait "$REFUSED_PID" 2>/dev/null || true
pass "a live pid the record cannot disprove is held, not displaced"

# --- a live sibling's running job is never reclaimed ------------------------
#
# The claim's owner is the lane that executes the job and publishes it, so a
# replacement must leave the job alone for as long as that owner is alive, even
# when the rendered owner identity disagrees with the live lane: killing it
# discards a result that was about to land and publishes the caller-visible
# 'stopped before this job completed'.
LIVE_STATE="$TMP_ROOT/live-owner-state"
LIVE_JOB="$LIVE_STATE/jobs/job-liveowner"
mkdir -p "$LIVE_JOB/.claim" "$LIVE_STATE/logs"
sleep 20 &
LIVE_LANE_PID=$!
printf 'running\n' > "$LIVE_JOB/state"
printf '%s\n' "$LIVE_LANE_PID" > "$LIVE_JOB/.claim/owner"
printf 'rendered-elsewhere\n' > "$LIVE_JOB/.claim/owner_start"
: > "$LIVE_JOB/stdout"
: > "$LIVE_JOB/stderr"
chmod 700 "$LIVE_JOB" "$LIVE_JOB/.claim"
chmod 600 "$LIVE_JOB/state" "$LIVE_JOB/.claim/owner" "$LIVE_JOB/.claim/owner_start" \
  "$LIVE_JOB/stdout" "$LIVE_JOB/stderr"
start_serve live-owner "$LIVE_STATE"
for _ in $(seq 1 200); do
  grep -Fq 'leaving job' "$TMP_ROOT/live-owner.err" 2>/dev/null && break
  sleep 0.05
done
[ "$(cat "$LIVE_JOB/state")" = running ] \
  || fail "a live sibling's running job was reclaimed"
assert_absent "$LIVE_JOB/exit" "a live sibling's running job published a result"
[ "$(cat "$LIVE_JOB/.claim/owner")" = "$LIVE_LANE_PID" ] \
  || fail "a live sibling's claim was erased"
kill -0 "$LIVE_LANE_PID" 2>/dev/null || fail "a live sibling's lane was signalled"
assert_grep 'leaving job' "$TMP_ROOT/live-owner.err" \
  "the replacement did not report the reclaim it refused: $(cat "$TMP_ROOT/live-owner.err")"
kill "$LIVE_LANE_PID" 2>/dev/null || true
wait "$LIVE_LANE_PID" 2>/dev/null || true
pass "a running job whose claim owner is alive is left to publish its result"

# Every worker this case started must be gone once its group is signalled. The
# assertion is what catches a fixture that recorded nothing to clean up.
stop_started_workers
for pid in "${STARTED_PIDS[@]}"; do
  kill -0 "$pid" 2>/dev/null && fail "worker $pid outlived the case that started it"
done
pass "every worker this case started was reaped"

echo "ALL TESTS PASSED"
