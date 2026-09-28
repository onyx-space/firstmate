#!/usr/bin/env bash
# Behavior tests for bin/fm-board-owner-liveness.sh, the standing board-owner
# liveness check.
#
# The runbook's two criteria are the surface under test: each case drives them
# through a fake `ss` and a fake `curl`, so the verdict, the reason, and the
# transition-only reporting are read from the executable interface rather than
# from the script's own bytes. The last case drives one real watcher cycle over a
# registered shim, which is what pins the one-line-into-one-wake contract end to
# end; no case touches a board, a real API, or the live owner lane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-board-owner-liveness.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-board-owner-liveness)

# A pid that is alive for the whole run, because the first criterion compares the
# connection's owner against the pid recorded in the owner's own lock file.
OWNER_PID=$$
DEAD_PID=999999

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

write_lock() {  # <path> <pid>
  printf 'pid=%s port=17890 started=2026-09-28T00:00:00Z\n' "$2" > "$1"
}

# default_lock <home>: the lock path the script derives with no override, which
# is the lane's own instance directory under this home.
default_lock() {
  printf '%s\n' "$1/data/elmo-board-acquisition-owner-lane/host/owner.lock"
}

# fake_ss <fakebin> <mode>: one | double | none.
fake_ss() {
  local bin=$1 mode=$2
  case "$mode" in
    one)
      printf 'ESTAB 0 0 192.168.88.78:39957 192.168.88.190:9050 users:(("net2415-acq-own",pid=%s,fd=196))\n' \
        "$OWNER_PID" > "$bin/ss.fixture"
      ;;
    double)
      {
        printf 'ESTAB 0 0 192.168.88.78:39957 192.168.88.190:9050 users:(("net2415-acq-own",pid=%s,fd=196))\n' "$OWNER_PID"
        printf 'ESTAB 0 0 192.168.88.78:41111 192.168.88.190:9050 users:(("rogue-probe",pid=4242,fd=9))\n'
      } > "$bin/ss.fixture"
      ;;
    *) : > "$bin/ss.fixture" ;;
  esac
  cat > "$bin/ss" <<'SH'
#!/usr/bin/env bash
here=$(dirname "${BASH_SOURCE[0]}")
cat "$here/ss.fixture"
SH
  chmod +x "$bin/ss"
}

# fake_curl <fakebin> <mode>: rise | flat | missing | error. `rise` is the only
# mode that answers the second criterion, and it rises on every call (including
# across checks), which is what a real counter does.
fake_curl() {
  local bin=$1 mode=$2
  printf '%s\n' "$mode" > "$bin/curl.mode"
  printf '0\n' > "$bin/counter"
  cat > "$bin/curl" <<'SH'
#!/usr/bin/env bash
here=$(dirname "${BASH_SOURCE[0]}")
mode=$(cat "$here/curl.mode")
n=$(cat "$here/counter" 2>/dev/null || printf 0)
case "$mode" in
  rise)
    n=$((n + 1))
    printf '%s\n' "$n" > "$here/counter"
    printf '{"signalGenBlocks":1,"signalGenSamples":%s}\n' "$n"
    ;;
  flat) printf '{"signalGenBlocks":1,"signalGenSamples":%s}\n' "$n" ;;
  missing) printf '{"signalGenBlocks":1}\n' ;;
  *) exit 22 ;;
esac
SH
  chmod +x "$bin/curl"
}

# fake_tools <home> <ss-mode> <curl-mode>: both stubs in one fakebin.
fake_tools() {
  local home=$1 ss_mode=$2 curl_mode=$3 bin
  bin=$(fm_fakebin "$home")
  fake_ss "$bin" "$ss_mode"
  fake_curl "$bin" "$curl_mode"
  printf '%s\n' "$bin"
}

# run_check <home> <out> [env assignments...]
# env is resolved once: a curated PATH built for the missing-tool case can carry a
# non-executable env from a user bin directory, and PATH resolution would then fail
# a case for a reason that has nothing to do with the check.
ENV_BIN=$(command -v env) || fail "env is required by this suite"
CHECK_STATUS=0
run_check() {
  local home=$1 out=$2
  shift 2
  CHECK_STATUS=0
  "$ENV_BIN" -u FM_BOARD_OWNER_HOME -u FM_BOARD_OWNER_LOCK -u FM_BOARD_OWNER_BOARD_PORT \
    -u FM_BOARD_OWNER_API_URL -u FM_BOARD_OWNER_PROBE_BOUND_SECS \
    FM_BOARD_OWNER_SAMPLE_GAP_SECS=1 \
    FM_HOME="$home" PATH="$home/fakebin:$PATH" "$@" \
    "$CHECK" check >"$out" 2>&1 || CHECK_STATUS=$?
}

record_field() {  # <home> <field>
  sed -n "s/^$2=//p" "$1/state/.board-owner-liveness" 2>/dev/null | head -n 1
}

test_help_and_usage() {
  local out rc=0
  out=$("$CHECK" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "check" "--help lists the check action"
  assert_contains "$out" "status" "--help lists the status action"
  assert_contains "$out" "clear" "--help lists the clear action"
  assert_contains "$out" "arm" "--help lists the arm action"
  rc=0
  out=$("$CHECK" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action must exit 2"
  assert_contains "$out" "unknown action" "unknown action is refused loudly"
  pass "fm-board-owner-liveness: help and usage plumbing"
}

test_healthy_owner_reports_a_first_observation_then_stays_silent() {
  local home out bin
  home=$(make_home healthy)
  bin=$(fake_tools "$home" one rise)
  write_lock "$home/owner.lock" "$OWNER_PID"
  out="$home/out1.txt"
  run_check "$home" "$out" "FM_BOARD_OWNER_LOCK=$home/owner.lock"
  expect_code 0 "$CHECK_STATUS" "a healthy check must exit 0"
  assert_contains "$(cat "$out")" "board-owner healthy (first observed " \
    "the first observation of a healthy owner is reported once"
  [ "$(record_field "$home" status)" = healthy ] || fail "the record must hold the healthy verdict"
  [ -n "$(record_field "$home" since_epoch)" ] || fail "the record must hold the epoch the verdict began"

  out="$home/out2.txt"
  run_check "$home" "$out" "FM_BOARD_OWNER_LOCK=$home/owner.lock"
  [ ! -s "$out" ] || fail "a verdict that holds must report nothing: $(cat "$out")"
  pass "fm-board-owner-liveness: healthy is reported once and then stays silent"
}

test_default_target_is_the_owner_lane_under_this_home() {
  local home out lock
  home=$(make_home default-target)
  fake_tools "$home" none rise >/dev/null
  lock=$(default_lock "$home")
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "no owner pid recorded in owner.lock" \
    "with no override the check reads the lane's own instance directory"
  assert_contains "$(cat "$out")" "no TCP connection to :9050" \
    "a missing board connection is named"
  [ ! -e "$lock" ] || fail "the case must not have written the default lock"
  assert_contains "$(record_field "$home" reason)" "no owner pid recorded in owner.lock" \
    "the record keeps the reason the line was cut from"
  pass "fm-board-owner-liveness: the default target is this home's owner lane"
}

test_connected_but_silent_counter_is_reported_and_recovery_is_reported() {
  local home out bin
  home=$(make_home silent)
  bin=$(fake_tools "$home" one flat)
  write_lock "$home/owner.lock" "$OWNER_PID"
  out="$home/out1.txt"
  run_check "$home" "$out" "FM_BOARD_OWNER_LOCK=$home/owner.lock"
  assert_contains "$(cat "$out")" "signalGenSamples is not rising" \
    "a connected owner whose counter is flat is reported, not assumed healthy"
  assert_contains "$(cat "$out")" "board-owner down (first observed " \
    "the first observation of an unhealthy owner names the drop"
  [ "$(record_field "$home" status)" = unhealthy ] || fail "the record must hold the unhealthy verdict"

  out="$home/out2.txt"
  run_check "$home" "$out" "FM_BOARD_OWNER_LOCK=$home/owner.lock"
  [ ! -s "$out" ] || fail "a verdict that still holds must not report again: $(cat "$out")"

  printf 'rise\n' > "$bin/curl.mode"
  out="$home/out3.txt"
  run_check "$home" "$out" "FM_BOARD_OWNER_LOCK=$home/owner.lock"
  assert_contains "$(cat "$out")" "board-owner recovered after " "recovery is reported"
  assert_contains "$(cat "$out")" "down since " "recovery names when the drop began"
  [ "$(record_field "$home" status)" = healthy ] || fail "the record must return to healthy"
  pass "fm-board-owner-liveness: a silent owner is reported and its recovery is reported"
}

test_two_connections_to_the_board_are_reported() {
  local home out
  home=$(make_home two-connections)
  fake_tools "$home" double rise >/dev/null
  write_lock "$home/owner.lock" "$OWNER_PID"
  out="$home/out.txt"
  run_check "$home" "$out" "FM_BOARD_OWNER_LOCK=$home/owner.lock"
  assert_contains "$(cat "$out")" "2 TCP connections to :9050 (want exactly 1)" \
    "a second connection to the board is reported"
  pass "fm-board-owner-liveness: a second board connection is reported"
}

test_a_dead_owner_pid_is_reported() {
  local home out
  home=$(make_home dead-pid)
  fake_tools "$home" one rise >/dev/null
  write_lock "$home/owner.lock" "$DEAD_PID"
  out="$home/out.txt"
  run_check "$home" "$out" "FM_BOARD_OWNER_LOCK=$home/owner.lock"
  assert_contains "$(cat "$out")" "owner pid $DEAD_PID is not running" \
    "a recorded pid that is gone is reported as the owner being down"
  pass "fm-board-owner-liveness: a dead owner pid is reported"
}

test_a_missing_probe_tool_is_unknown_rather_than_healthy() {
  local home out bin saved_path
  home=$(make_home no-ss)
  bin=$(fake_tools "$home" one rise)
  rm -f "$bin/ss"
  write_lock "$home/owner.lock" "$OWNER_PID"
  # The host's own ss would answer next on PATH and be read as this case's probe,
  # so the tool is hidden from the whole path rather than only from the fakebin.
  saved_path=$PATH
  PATH=$(fm_test_base_path_sans "$PATH" ss)
  out="$home/out.txt"
  run_check "$home" "$out" "FM_BOARD_OWNER_LOCK=$home/owner.lock"
  PATH=$saved_path
  assert_contains "$(cat "$out")" "ss is not installed" \
    "a probe that cannot read the connection says so"
  assert_contains "$(cat "$out")" "liveness unknown" "a missing tool is unknown, never healthy"
  [ "$(record_field "$home" status)" = unknown ] || fail "the record must hold the unknown verdict"
  pass "fm-board-owner-liveness: a missing probe tool is unknown, not healthy"
}

test_a_failing_probe_is_unknown_or_down_rather_than_healthy() {
  local home out bin
  home=$(make_home probe-failed)
  bin=$(fake_tools "$home" one rise)
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/ss"
  chmod +x "$bin/ss"
  write_lock "$home/owner.lock" "$OWNER_PID"
  out="$home/out.txt"
  run_check "$home" "$out" "FM_BOARD_OWNER_LOCK=$home/owner.lock"
  assert_contains "$(cat "$out")" "ss failed to read the board connection" \
    "a failing probe is reported by name"
  assert_contains "$(cat "$out")" "liveness unknown" "a failing probe is unknown, never healthy"

  # The owner exit is part of the owner's liveness, so a curl that cannot answer is
  # the owner being unreachable rather than an unreadable probe tool.
  home=$(make_home curl-failed)
  bin=$(fake_tools "$home" one rise)
  printf '#!/usr/bin/env bash\nexit 7\n' > "$bin/curl"
  chmod +x "$bin/curl"
  write_lock "$home/owner.lock" "$OWNER_PID"
  out="$home/out.txt"
  run_check "$home" "$out" "FM_BOARD_OWNER_LOCK=$home/owner.lock"
  assert_contains "$(cat "$out")" "did not answer (curl exit 7)" \
    "a failing owner exit is reported with its own status"
  assert_contains "$(cat "$out")" "board-owner down" "an unreachable owner exit is the owner being down"
  pass "fm-board-owner-liveness: unreadable probes are reported as unknown or down, never healthy"
}

test_clear_records_the_verdict_without_printing_and_the_next_change_reports() {
  local home out
  home=$(make_home clear)
  fake_tools "$home" none rise >/dev/null
  write_lock "$home/owner.lock" "$OWNER_PID"
  out="$home/out1.txt"
  run_check "$home" "$out" "FM_BOARD_OWNER_LOCK=$home/owner.lock"
  assert_contains "$(cat "$out")" "board-owner down" "the drop is reported first"

  out="$home/out2.txt"
  run_clear() {
    env -u FM_BOARD_OWNER_HOME -u FM_BOARD_OWNER_LOCK -u FM_BOARD_OWNER_BOARD_PORT \
      -u FM_BOARD_OWNER_API_URL -u FM_BOARD_OWNER_PROBE_BOUND_SECS \
      FM_BOARD_OWNER_SAMPLE_GAP_SECS=1 FM_HOME="$home" PATH="$home/fakebin:$PATH" \
      FM_BOARD_OWNER_LOCK="$home/owner.lock" "$CHECK" clear
  }
  run_clear >"$out" 2>&1 || fail "clear must succeed"
  assert_contains "$(cat "$out")" "cleared: recorded board-owner-liveness unhealthy" \
    "clear records the verdict it saw"
  assert_not_contains "$(cat "$out")" "board-owner down" "clear prints no wake line"

  # The cleared baseline is the same verdict, so the watch stays quiet; the next
  # CHANGE is what reports again.
  out="$home/out3.txt"
  run_check "$home" "$out" "FM_BOARD_OWNER_LOCK=$home/owner.lock"
  [ ! -s "$out" ] || fail "a cleared verdict that still holds must not report again: $(cat "$out")"
  fake_ss "$home/fakebin" one
  out="$home/out4.txt"
  run_check "$home" "$out" "FM_BOARD_OWNER_LOCK=$home/owner.lock"
  assert_contains "$(cat "$out")" "board-owner recovered after " \
    "a change after a clear still reports"
  pass "fm-board-owner-liveness: clear silences an acknowledged verdict and never a later change"
}

test_arm_writes_a_registered_shim_and_disarm_retires_it() {
  local home out
  home=$(make_home arm)
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/board-owner-liveness.check.sh" "arm names the shim it wrote"
  assert_present "$home/state/board-owner-liveness.check.sh" "arm writes the check shim"
  assert_present "$home/state/board-owner-liveness.check-trust" "arm binds the shim for the watcher"
  assert_contains "$(cat "$home/state/board-owner-liveness.check.sh")" "fm-board-owner-liveness.sh check" \
    "the shim dispatches the check action"
  assert_contains "$(cat "$home/state/board-owner-liveness.check.sh")" "FM_HOME=$home" \
    "the shim pins the absolute home"

  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "re-arm must succeed: $out"
  assert_contains "$out" "armed" "re-arm stays armed"

  out=$(FM_HOME="$home" "$CHECK" disarm 2>&1) || fail "disarm must succeed: $out"
  assert_absent "$home/state/board-owner-liveness.check.sh" "disarm removes the check shim"
  assert_absent "$home/state/board-owner-liveness.check-trust" "disarm removes the trust binding"
  pass "fm-board-owner-liveness: arm writes and binds, re-arm is idempotent, disarm removes"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home target out rc=0
  home=$(make_home symlink)
  target="$TMP_ROOT/symlink-outside"
  mkdir -p "$target"
  printf '#!/usr/bin/env bash\n' > "$target/board-owner-liveness.check.sh"
  ln -s "$target/board-owner-liveness.check.sh" "$home/state/board-owner-liveness.check.sh"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse a symlink at the shim path"
  assert_contains "$out" "could not write" "arm reports the shim write failure"
  assert_absent "$home/state/board-owner-liveness.check-trust" \
    "no trust binding is left behind by a refused arm"
  pass "fm-board-owner-liveness: arm refuses a symlink at the shim path"
}

test_a_malformed_override_is_refused() {
  local home out rc=0
  home=$(make_home malformed)
  out=$(FM_HOME="$home" FM_BOARD_OWNER_SAMPLE_GAP_SECS=abc "$CHECK" check 2>&1) || rc=$?
  expect_code 2 "$rc" "a malformed override must exit 2"
  assert_contains "$out" "must be a whole number" "a malformed override is refused loudly"
  pass "fm-board-owner-liveness: a malformed override is refused"
}

# The one-line-into-one-wake contract: a registered shim that prints one line
# must arrive at the supervisor as one `check:` wake, which is why this check
# needs no schedule of its own.
test_registered_check_turns_one_line_into_one_wake() {
  local home out status=0 lock
  home=$(make_home watcher)
  fake_tools "$home" none rise >/dev/null
  lock=$(default_lock "$home")
  mkdir -p "$(dirname "$lock")"
  write_lock "$lock" "$OWNER_PID"
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || fail "arm must succeed for the watcher case"
  out="$home/watcher.txt"
  env FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    PATH="$home/fakebin:$PATH" "$CHECKPOINT" --seconds 20 >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "an actionable wake must end the checkpoint"
  assert_contains "$(cat "$out")" "check: " "the watcher turned the check line into a check wake"
  assert_contains "$(cat "$out")" "board-owner down" "the wake carries the check's own line"
  pass "fm-board-owner-liveness: the watcher turns the check's one line into one wake"
}

test_help_and_usage
test_healthy_owner_reports_a_first_observation_then_stays_silent
test_default_target_is_the_owner_lane_under_this_home
test_connected_but_silent_counter_is_reported_and_recovery_is_reported
test_two_connections_to_the_board_are_reported
test_a_dead_owner_pid_is_reported
test_a_missing_probe_tool_is_unknown_rather_than_healthy
test_a_failing_probe_is_unknown_or_down_rather_than_healthy
test_clear_records_the_verdict_without_printing_and_the_next_change_reports
test_arm_writes_a_registered_shim_and_disarm_retires_it
test_arm_refuses_a_symlink_at_the_shim_path
test_a_malformed_override_is_refused
test_registered_check_turns_one_line_into_one_wake
