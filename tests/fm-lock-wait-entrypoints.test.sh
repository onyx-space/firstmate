#!/usr/bin/env bash
# tests/fm-lock-wait-entrypoints.test.sh - the two entry points that hung in the
# field, driven against the PRE-FIX lock library and against this build, with
# every case bounded by its own hard watchdog.
#
# Why this file exists at all. The pre-fix behaviour IS a hang, so a harness that
# demonstrates it without a watchdog deadlocks by construction: two no-mistakes
# agent rounds each burned about twenty of their thirty wall-clock minutes
# blocked on exactly that, one in `wait` on a probe fixture that never wrote its
# release file and one in a driver that re-invoked itself. This fixture makes
# "still running when the bound fires" a RECORDED RESULT - HANG, printed with the
# bound and the elapsed time - so the demonstration can no longer wedge anything,
# and `bin/fm-test-run.sh` alone can reproduce it.
#
# Case shape, all four two-sided:
#
#   teardown / record lock recycled .. base hangs, this build reclaims where the
#                                      host can prove reuse, else refuses bounded
#   send / lease command lock held ... base hangs, this build refuses loudly
#   send / lease command lock recycled  base hangs, this build sends or refuses
#
# "base" is the lock library at this branch's fork point, which is the pre-fix
# library while the branch is unmerged (FM_LOCK_WAIT_BASE_REF overrides the ref).
# Where that baseline cannot be resolved - a merged tree, a shallow or absent
# git, a build that already carries the fix - the file says so and exits 0 rather
# than pretending to have compared anything.
#
# The full-fixture sibling lives in tests/fm-teardown.test.sh, whose
# test_recycled_pid_record_lock_self_heals walks a real isolated worktree through
# the same reclaim path (a completed teardown where the host can prove reuse, a
# bounded refusal where it cannot).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# fm_run_timed is bin/fm-timeout-lib.sh's hard-bound runner: the single owner of
# bounded execution in this repo, so this file does not re-roll one.
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

HEAD_BIN="$ROOT/bin"
BASE_BOUND=8
HEAD_BOUND=20
TMP_ROOT=$(fm_test_tmproot fm-lock-wait-entrypoints)

# The pre-fix lock library, or empty when this tree cannot produce one. Echoes the
# path of a directory holding a full copy of bin/ with that library in place: the
# entry scripts resolve their own directory, so the baseline has to be a tree, not
# a swapped file.
base_bin_root() {  # <case-dir> -> echoes a bin/ root, or nothing
  local case_dir=$1 ref src
  ref=${FM_LOCK_WAIT_BASE_REF:-}
  if [ -z "$ref" ]; then
    command -v git >/dev/null 2>&1 || return 1
    git -C "$ROOT" rev-parse --verify -q origin/main >/dev/null 2>&1 || return 1
    ref=$(git -C "$ROOT" merge-base HEAD origin/main 2>/dev/null) || return 1
  fi
  [ -n "$ref" ] || return 1
  src=$(git -C "$ROOT" show "$ref:bin/fm-wake-lib.sh" 2>/dev/null) || return 1
  # Anything that already carries the bounded wait is not a pre-fix baseline.
  case "$src" in
    *FM_LOCK_ACQUIRE_WAIT_DEFAULT*) return 1 ;;
  esac
  rm -rf "$case_dir/base-bin"
  cp -R "$ROOT/bin" "$case_dir/base-bin" || return 1
  printf '%s\n' "$src" > "$case_dir/base-bin/fm-wake-lib.sh" || return 1
  printf '%s\n' "$case_dir/base-bin"
}

# One isolated home with the single task record the entry points resolve, plus a
# tmux stub so a send can reach its doorbell. Deliberately no git world: teardown
# reaches the record lock - the lock the field hang lived in - before it needs one,
# and stopping there keeps this fixture about the lock.
make_entry_case() {  # <name> -> echoes case dir
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin"
  printf 'manual\n' > "$dir/home/config/backlog-backend"
  printf '%s\n' \
    'window=firstmate:fm-task-x1' \
    'endpoint_task_id=task-x1' \
    'worktree=' \
    'project=' \
    'kind=ship' \
    'mode=local-only' \
    'spawn_gen=entry-fixture' > "$dir/home/state/task-x1.meta"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-task-x1\n' ;;
  display-message) printf 'fakepane\n' ;;
  capture-pane) printf '%s\n' '╭────╮' '│    │' '╰────╯' ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  printf '%s\n' "$dir"
}

# Hold one lock with a live process for the whole case. Echoes the holder pid.
hold_lock() {  # <case-dir> <lock-path>
  local dir=$1 lock=$2 holder
  FM_STATE_OVERRIDE="$dir/home/state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 10
    printf "ready\n" > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$dir/holder.ready" "$dir/holder.release" \
    > "$dir/holder.log" 2>&1 &
  holder=$!
  local i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/holder.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/holder.ready" ] || { kill "$holder" 2>/dev/null || true; return 1; }
  printf '%s\n' "$holder"
}

release_lock_holder() {  # <case-dir> <holder-pid>
  : > "$1/holder.release"
  wait "$2" 2>/dev/null || true
}

# Plant the field's stale shape: a lock record whose pid is ALIVE because the
# kernel recycled it to an unrelated process. A reclaim is authorized only by a
# reader-independent identity stamp (the /proc form), so where the host can render
# one the record carries a start field no live process answers to; where it cannot
# - Darwin, BSD - the record is identity-less and the entry point must refuse at
# its bound instead of hanging. Echoes the host's expectation: reclaim | refuse.
plant_recycled_lock() {  # <lock-path> <live-pid>
  local lock=$1 live=$2 owner="$1.owner.FIXTURE" real
  mkdir "$owner"
  printf '%s\n' "$live" > "$owner/pid"
  ln -s "$owner" "$lock"
  real=
  if [ -r "/proc/$live/stat" ] && [ -r "/proc/$live/cmdline" ]; then
    real=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$live" 2>/dev/null || true)
  fi
  case "$real" in
    *' cmdline-hex='*)
      # Tamper only the numeric start field, so the record differs from the live
      # pid in exactly the field the reuse proof compares.
      printf '%s\n' "${real%%=*}=1 cmdline-hex=00" > "$owner/pid-identity"
      printf 'reclaim\n'
      ;;
    *) printf 'refuse\n' ;;
  esac
}

# Run one entry point under the hard bound. Echoes three lines: rc, elapsed, and
# the combined output. Never hangs, whatever the library under test does.
run_bounded() {  # <seconds> <root> <case-dir> <command...>
  local seconds=$1 root=$2 dir=$3 rc elapsed start
  shift 3
  start=$(date +%s)
  (
    PATH="$dir/fakebin:$PATH" \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$dir/home" \
      FM_STATE_OVERRIDE="$dir/home/state" \
      FM_DATA_OVERRIDE="$dir/home/data" \
      FM_CONFIG_OVERRIDE="$dir/home/config" \
      FM_LOCK_ACQUIRE_WAIT_SECS=${FM_LOCK_ACQUIRE_WAIT_SECS:-2} \
      fm_run_timed "$seconds" "$@"
  ) > "$dir/last.out" 2>&1
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  printf 'rc=%s\nelapsed=%s\n' "$rc" "$elapsed"
  cat "$dir/last.out"
}

teardown_case() {  # <case-dir> <seconds> <bin-root>
  local dir=$1 seconds=$2 root=$3
  run_bounded "$seconds" "$root" "$dir" "$root/fm-teardown.sh" task-x1
}

send_case() {  # <case-dir> <seconds> <bin-root>
  local dir=$1 seconds=$2 root=$3
  # A steer only takes the lease command lock in a supervision context.
  PI_CODING_AGENT=true FM_SUPERVISION_ACTOR=main FM_SEND_SETTLE=0 \
    run_bounded "$seconds" "$root" "$dir" "$root/fm-send.sh" fm-task-x1 "must not hang"
}

expect_hang() {  # <label> <bound> <rc> <elapsed> <output>
  local label=$1 bound=$2 rc=$3 elapsed=$4 out=$5
  [ "$rc" = 124 ] || fail "$label: the pre-fix library did not hang (rc=$rc, ${elapsed}s)"$'\n'"$out"
  [ "$elapsed" -ge $((bound - 1)) ] \
    || fail "$label: the pre-fix library returned after ${elapsed}s, before its ${bound}s bound - not the unbounded wait"
  assert_not_contains "$out" "could not acquire" \
    "$label: the pre-fix library produced this build's refusal diagnostic"
  printf 'ok - %s: HANG recorded - killed by its %ss watchdog after %ss\n' "$label" "$bound" "$elapsed"
}

# ---------------------------------------------------------------------------

test_teardown_record_lock_held() {
  local dir base holder rc elapsed out
  dir=$(make_entry_case teardown-lock-held)
  holder=$(hold_lock "$dir" "$dir/home/state/.meta-task-x1.lock") \
    || fail "teardown-lock-held: the fixture holder never took the record lock"

  base=$(base_bin_root "$dir") || {
    release_lock_holder "$dir" "$holder"
    printf 'ok - teardown record lock held: SKIPPED - no pre-fix baseline library is resolvable in this tree\n'
    return 0
  }
  read -r rc elapsed < <(teardown_case "$dir" "$BASE_BOUND" "$base" | sed -n 's/^rc=//p;s/^elapsed=//p' | paste - -)
  out=$(cat "$dir/last.out")
  expect_hang "teardown record lock held / base" "$BASE_BOUND" "$rc" "$elapsed" "$out"

  read -r rc elapsed < <(teardown_case "$dir" "$HEAD_BOUND" "$HEAD_BIN" | sed -n 's/^rc=//p;s/^elapsed=//p' | paste - -)
  out=$(cat "$dir/last.out")
  release_lock_holder "$dir" "$holder"
  expect_code 124 "$rc" "teardown record lock held / this build must refuse at its bound"
  [ "$elapsed" -lt "$HEAD_BOUND" ] \
    || fail "teardown record lock held / this build: refused only when the ${HEAD_BOUND}s watchdog fired"
  assert_contains "$out" "could not acquire" \
    "teardown record lock held / this build: the refusal did not name the lock it could not take"
  assert_contains "$out" "held by live pid" \
    "teardown record lock held / this build: the refusal did not name the holder"
  assert_absent "$dir/home/state/.control-task-x1.lock" \
    "teardown record lock held / this build: the refused teardown leaked its task control lock"
  pass "teardown behind a held record lock: base HANGs (killed at ${BASE_BOUND}s), this build refuses in ${elapsed}s"
}

test_teardown_record_lock_recycled() {
  local dir base live rc elapsed out owner_pid expectation
  dir=$(make_entry_case teardown-lock-recycled)
  sleep 300 &
  live=$!
  expectation=$(plant_recycled_lock "$dir/home/state/.meta-task-x1.lock" "$live")

  base=$(base_bin_root "$dir") || {
    kill "$live" 2>/dev/null || true
    printf 'ok - teardown record lock recycled: SKIPPED - no pre-fix baseline library is resolvable in this tree\n'
    return 0
  }
  read -r rc elapsed < <(teardown_case "$dir" "$BASE_BOUND" "$base" | sed -n 's/^rc=//p;s/^elapsed=//p' | paste - -)
  out=$(cat "$dir/last.out")
  expect_hang "teardown record lock recycled / base" "$BASE_BOUND" "$rc" "$elapsed" "$out"

  read -r rc elapsed < <(teardown_case "$dir" "$HEAD_BOUND" "$HEAD_BIN" | sed -n 's/^rc=//p;s/^elapsed=//p' | paste - -)
  out=$(cat "$dir/last.out")
  owner_pid=$(cat "$dir/home/state/.meta-task-x1.lock/pid" 2>/dev/null || true)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ "$elapsed" -lt "$HEAD_BOUND" ] \
    || fail "teardown record lock recycled / this build: still running when the ${HEAD_BOUND}s watchdog fired"
  if [ "$expectation" = reclaim ]; then
    assert_not_contains "$out" "could not acquire" \
      "teardown record lock recycled / this build: refused instead of reclaiming the proven-stale owner"
    assert_not_equals "$live" "$owner_pid" \
      "teardown record lock recycled / this build: the recycled-pid lock was not reclaimed"
    assert_contains "$out" "worktree identity" \
      "teardown record lock recycled / this build: teardown never got past the record lock"
    pass "teardown behind a proven-stale record lock: base HANGs (killed at ${BASE_BOUND}s), this build reclaims and proceeds in ${elapsed}s"
  else
    expect_code 124 "$rc" "teardown record lock recycled / this build: an unprovable pid must refuse at the bound"
    assert_contains "$out" "could not acquire" \
      "teardown record lock recycled / this build: the refusal did not name the lock it could not take"
    assert_contains "$out" "records no owner identity" \
      "teardown record lock recycled / this build: the refusal did not report the missing identity proof"
    assert_equals "$live" "$owner_pid" \
      "teardown record lock recycled / this build: an unprovable live pid lost its lock"
    pass "teardown behind an unprovable recycled-pid record lock: base HANGs (killed at ${BASE_BOUND}s), this build refuses in ${elapsed}s"
  fi
}

test_send_lease_lock_held() {
  local dir base holder rc elapsed out
  dir=$(make_entry_case send-lease-held)
  holder=$(hold_lock "$dir" "$dir/home/state/.fm-lease-command.lock") \
    || fail "send-lease-held: the fixture holder never took the lease command lock"

  base=$(base_bin_root "$dir") || {
    release_lock_holder "$dir" "$holder"
    printf 'ok - send behind a held lease lock: SKIPPED - no pre-fix baseline library is resolvable in this tree\n'
    return 0
  }
  read -r rc elapsed < <(send_case "$dir" "$BASE_BOUND" "$base" | sed -n 's/^rc=//p;s/^elapsed=//p' | paste - -)
  out=$(cat "$dir/last.out")
  expect_hang "send behind a held lease lock / base" "$BASE_BOUND" "$rc" "$elapsed" "$out"

  read -r rc elapsed < <(send_case "$dir" "$HEAD_BOUND" "$HEAD_BIN" | sed -n 's/^rc=//p;s/^elapsed=//p' | paste - -)
  out=$(cat "$dir/last.out")
  release_lock_holder "$dir" "$holder"
  expect_code 124 "$rc" "send behind a held lease lock / this build must refuse at its bound"
  [ "$elapsed" -lt "$HEAD_BOUND" ] \
    || fail "send behind a held lease lock / this build: refused only when the ${HEAD_BOUND}s watchdog fired"
  assert_contains "$out" "could not acquire" \
    "send behind a held lease lock / this build: the refusal did not name the lock it could not take"
  assert_absent "$dir/home/state/task-x1.inbox" \
    "send behind a held lease lock / this build: a refused steer still created an inbox"
  pass "steer behind a held lease lock: base HANGs (killed at ${BASE_BOUND}s), this build refuses in ${elapsed}s"
}

test_send_lease_lock_recycled() {
  local dir base live rc elapsed out expectation
  dir=$(make_entry_case send-lease-recycled)
  sleep 300 &
  live=$!
  expectation=$(plant_recycled_lock "$dir/home/state/.fm-lease-command.lock" "$live")

  base=$(base_bin_root "$dir") || {
    kill "$live" 2>/dev/null || true
    printf 'ok - send behind a proven-stale lease lock: SKIPPED - no pre-fix baseline library is resolvable in this tree\n'
    return 0
  }
  read -r rc elapsed < <(send_case "$dir" "$BASE_BOUND" "$base" | sed -n 's/^rc=//p;s/^elapsed=//p' | paste - -)
  out=$(cat "$dir/last.out")
  expect_hang "send behind a proven-stale lease lock / base" "$BASE_BOUND" "$rc" "$elapsed" "$out"

  read -r rc elapsed < <(send_case "$dir" "$HEAD_BOUND" "$HEAD_BIN" | sed -n 's/^rc=//p;s/^elapsed=//p' | paste - -)
  out=$(cat "$dir/last.out")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ "$elapsed" -lt "$HEAD_BOUND" ] \
    || fail "send behind a proven-stale lease lock / this build: still running when the ${HEAD_BOUND}s watchdog fired"
  if [ "$expectation" = reclaim ]; then
    expect_code 0 "$rc" "send behind a proven-stale lease lock / this build must reclaim it and send"
    assert_present "$dir/home/state/task-x1.inbox" \
      "send behind a proven-stale lease lock / this build: the steer was reported sent with no inbox record"
    pass "steer behind a proven-stale lease lock: base HANGs (killed at ${BASE_BOUND}s), this build sends and exits 0 in ${elapsed}s"
  else
    expect_code 124 "$rc" "send behind a proven-stale lease lock / this build: an unprovable pid must refuse at the bound"
    assert_contains "$out" "could not acquire" \
      "send behind a proven-stale lease lock / this build: the refusal did not name the lock it could not take"
    assert_absent "$dir/home/state/task-x1.inbox" \
      "send behind a proven-stale lease lock / this build: a refused steer still created an inbox"
    pass "steer behind an unprovable recycled-pid lease lock: base HANGs (killed at ${BASE_BOUND}s), this build refuses in ${elapsed}s"
  fi
}

test_teardown_record_lock_held
test_send_lease_lock_held
test_teardown_record_lock_recycled
test_send_lease_lock_recycled
