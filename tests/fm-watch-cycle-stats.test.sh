#!/usr/bin/env bash
# tests/fm-watch-cycle-stats.test.sh - the one-line watcher-cycle self-check.
#
# The arm-owned lifecycle ledger (state/.watch-cycle-exits.log) records
# started_at and ended_at for every observed watcher cycle, so a cycle's
# duration is their difference. Because bin/fm-watch.sh touches the liveness
# beacon at the TOP of every poll, that duration is also how stale the beacon
# got while the cycle ran - which is what makes the median a supervision-health
# number rather than only a performance one. These tests drive the real
# bin/fm-watch-cycle-stats.sh over crafted ledgers and assert the one line it
# reports, the threshold that turns it into an ALERT line, the default threshold
# that follows FM_GUARD_GRACE, the recent-window narrowing, and that malformed
# rows are ignored rather than counted as instant cycles.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATS="$ROOT/bin/fm-watch-cycle-stats.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-cycle-stats-tests)

# Write one ledger holding each given duration, with a plausible row for it.
write_ledger() {  # <state> <duration-seconds>...
  local state=$1 d t=1000
  shift
  : > "$state/.watch-cycle-exits.log" || return 1
  for d in "$@"; do
    printf 'arm_pid=1\twatcher_pid=2\torigin=arm\tstarted_at=%s\tended_at=%s\texit_code=0\tsignal=none\treason=wake\tbeacon_age=0\tlock_before=a\tlock_after=b\tsuccessor=none\n' \
      "$t" "$((t + d))" >> "$state/.watch-cycle-exits.log" || return 1
    t=$((t + d + 5))
  done
}

state="$TMP_ROOT/state"
mkdir -p "$state" || fail "could not create the test state dir"

out=$(FM_STATE_OVERRIDE="$state" "$STATS")
assert_contains "$out" 'EMPTY' "a missing ledger did not report EMPTY"

write_ledger "$state" 10 20 60 || fail "could not write the ledger fixture"
out=$(FM_STATE_OVERRIDE="$state" "$STATS")
assert_contains "$out" 'median 20s' "the median cycle was not reported"
assert_contains "$out" 'mean 30s' "the mean cycle was not reported"
assert_contains "$out" 'max 60s' "the longest cycle was not reported"
assert_contains "$out" 'cycles 3 of 3' "the counted cycles were not reported"
assert_contains "$out" 'threshold 150s' "the default threshold was not half the guard grace"
assert_not_contains "$out" 'ALERT' "a median under the threshold raised ALERT"
pass "cycle stats: one line carries median, mean, max, count, and threshold"

out=$(FM_STATE_OVERRIDE="$state" FM_WATCH_CYCLE_MEDIAN_ALERT_SECS=15 "$STATS")
assert_contains "$out" 'ALERT median 20s >= threshold 15s' \
  "an at-or-over-threshold median did not raise the explicit ALERT line"
pass "cycle stats: a median at the threshold records the ALERT line"

out=$(FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=40 "$STATS")
assert_contains "$out" 'threshold 20s' "the default threshold did not follow FM_GUARD_GRACE"
pass "cycle stats: the default threshold is half FM_GUARD_GRACE"

out=$(FM_STATE_OVERRIDE="$state" "$STATS" --recent 1)
assert_contains "$out" 'median 60s' "the recent window did not narrow the median"
assert_contains "$out" 'cycles 1 of 3' "the recent window did not report how much of the ledger it used"
pass "cycle stats: --recent narrows the window and still reports the total"

# A row without a numeric span is not a cycle: counting it as a zero-length one
# would report an artificially healthy median exactly when the ledger is damaged.
printf 'arm_pid=1\twatcher_pid=2\torigin=arm\tstarted_at=\tended_at=\texit_code=0\tsignal=none\treason=wake\tbeacon_age=0\tlock_before=a\tlock_after=b\tsuccessor=none\n' \
  >> "$state/.watch-cycle-exits.log"
out=$(FM_STATE_OVERRIDE="$state" "$STATS" --recent 1)
assert_contains "$out" 'median 60s' "a malformed row changed the median"
assert_contains "$out" 'cycles 1 of 3' "a malformed row was counted as a cycle"
pass "cycle stats: a malformed ledger row is ignored, never counted as an instant cycle"

printf 'ok - fm-watch-cycle-stats\n'
