#!/usr/bin/env bash
# tests/fm-classify-span-scan.test.sh - the bounded, resumable span scan in
# bin/fm-classify-lib.sh's status_span_first_actionable_record.
#
# The classifier decides which events in a status log's appended span are
# actionable, and that decision needs the span's decision-origin map: the
# position of each key's live declaration, so a superseded declaration is not
# reported as though it were still current. Building that map used to re-read
# and re-fold the WHOLE status log on every classification, so one long-lived
# log could hold the caller - on the watcher, the poll loop and with it the
# liveness beacon - for minutes. These tests drive the REAL function over
# crafted status logs and assert:
#
#   equivalence - the bounded multi-round scan returns byte-for-byte what the
#     unfixed whole-file fold returns, over an input covering every fold shape
#     this path consumes (plain events, decision opens and closes, superseded
#     declarations, reserved keys refused their own close, duplicate lines,
#     blank lines, a final line with no trailing newline) and over a
#     deterministic pseudo-random log;
#   teeth - with FM_CLASSIFY_SPAN_SCAN_FAULT_SKIP_INPUT set, the same
#     equivalence assertion goes red, so it cannot pass vacuously;
#   bounded rounds - an over-budget span is folded in more than one round, each
#     round finishes within its budget, and the beacon the caller touches between
#     rounds keeps advancing instead of freezing for the whole scan;
#   resumption - a scan abandoned mid-span and restarted in a fresh process
#     resumes from its cursor and still reaches the full answer, and a cursor
#     that cannot be trusted restarts safely rather than answering from part of
#     the input;
#   completion hygiene - a finished scan leaves no cursor behind.
#
# The whole-file fold stays reachable only as FM_CLASSIFY_SPAN_SCAN_REFERENCE=
# whole-file, which is the reference these tests compare against. Its cost is
# what the bounded scan exists to remove, so the equivalence cases stay small on
# purpose.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-span-scan-tests)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE" || fail "could not create the test state dir"
CASE=0


# Byte offset at which line <n> (1-based) begins, so a span offset can be chosen
# on a line boundary exactly as a recorded classified position is.
line_offset() {  # <file> <n>
  perl -e '
    my ($path, $want) = @ARGV;
    open(my $fh, "<", $path) or exit 1;
    binmode($fh);
    my ($off, $line) = (0, 1);
    while ($line < $want) {
      my $p = tell($fh);
      my $got = read($fh, my $buf, 65536);
      last if !defined($got) || $got == 0;
      while ($buf =~ /\n/g) {
        $line++;
        $off = $p + pos($buf);
        last if $line >= $want;
      }
      last if $line >= $want;
      seek($fh, $p + $got, 0);
    }
    print $off;
  ' "$1" "$2"
}

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d", time * 1000'
}

# A beacon stamp fine-grained enough to see a touch inside one second.
_fm_span_scan_beat_stamp() {  # <beat-file>
  perl -MTime::HiRes=time -e 'my @s = stat($ARGV[0]); printf "%d.%d", $s[9], $s[10]' "$1"
}

# A status log covering every shape the span fold consumes. <lines> scales it by
# repeating the routine traffic; the decision-bearing skeleton is always present.
build_log() {  # <path> [<routine-lines>]
  local path=$1 repeat=${2:-60} i
  : > "$path" || return 1
  {
    printf 'working: no verb line without a colon\n'
    printf '\n'
    printf 'done: shipped the first slice\n'
    printf 'needs-decision: [key=alpha] choose the migration order\n'
    printf 'working: still waiting on alpha\n'
    printf 'needs-decision: [key=alpha] choose the migration order\n'
    printf 'blocked: [key=beta] upstream service returned 503\n'
    printf 'resolved: [key=alpha] captain picked the safe order\n'
    printf 'blocked: [key=pending-reply-x] words that do not speak the namespace\n'
    printf 'blocked: [key=pending-reply-y] pending-reply-missed: retry window closed\n'
    printf 'resolved: [key=pending-reply-x] cleared by the owner\n'
    printf 'captain-held: [key=gamma] handed to the captain backlog\n'
    printf 'failed: the integration lane went red\n'
    printf 'needs-decision: [key=delta] pick a rollout shape\n'
    printf 'working: routine traffic begins\n'
    for i in $(seq 1 "$repeat"); do
      printf 'working: routine progress line %s with some words in it\n' "$i"
      case $((i % 9)) in
        0) printf 'blocked: [key=blk-%s] waiting on upstream %s\n' "$i" "$i" ;;
        4) printf 'needs-decision: [key=dec-%s] pick a path %s\n' "$i" "$i" ;;
        6) printf 'resolved: [key=blk-%s] cleared\n' "$((i - 9))" ;;
        7) printf 'blocked: [key=pending-reply-z%s] words without the vocabulary\n' "$i" ;;
      esac
    done
    printf 'needs-decision: [key=delta] pick a rollout shape\n'
    printf 'working: trailing line still being appended'
  } >> "$path"
  return 0
}

# Deterministic pseudo-random traffic so the equivalence assertion is not tuned
# to one hand-written shape.
build_random_log() {  # <path> <lines>
  local path=$1 lines=$2 i seed=1103515245 key
  : > "$path" || return 1
  for (( i = 1; i <= lines; i++ )); do
    seed=$(( (seed * 1103515245 + 12345) % 2147483648 ))
    case $(( seed % 11 )) in
      0) printf 'working: line %s\n' "$i" ;;
      1) printf 'needs-decision: [key=r%s] question %s\n' "$(( seed % 7 ))" "$i" ;;
      2) printf 'blocked: [key=r%s] blocker %s\n' "$(( seed % 7 ))" "$i" ;;
      3) printf 'resolved: [key=r%s] cleared at %s\n' "$(( seed % 7 ))" "$i" ;;
      4) printf 'done: finished %s\n' "$i" ;;
      5) printf 'failed: broke %s\n' "$i" ;;
      6) printf '\n' ;;
      7) printf 'needs-decision [key=r%s]: question after the verb %s\n' "$(( seed % 7 ))" "$i" ;;
      8) printf 'captain-held: [key=r%s] transferred %s\n' "$(( seed % 7 ))" "$i" ;;
      9) printf 'blocked: [key=pending-reply-%s] outside the vocabulary %s\n' "$(( seed % 5 ))" "$i" ;;
      *) printf 'working: no verb free text %s\n' "$i" ;;
    esac
  done >> "$path"
}

# Run the bounded scan to completion the way a caller does, one round per call.
# <max-rounds> guards against a resumption bug turning into an infinite loop.
# FM_TEST_* are the function's own output variables, read in this shell rather
# than inside the command substitution that captures this function's output.
bounded_scan_all() {  # <log> <start> <max-rounds> -> "<rc>|<record>|<needs>"
  local log=$1 start=$2 max=${3:-200} rc rounds=0
  FM_TEST_RECORD=''
  FM_TEST_NEEDS=0
  while :; do
    rounds=$((rounds + 1))
    status_span_first_actionable_record "$log" "$start" FM_TEST_RECORD FM_TEST_NEEDS 2>/dev/null
    rc=$?
    [ "$rc" -eq 2 ] || break
    [ "$rounds" -lt "$max" ] || { printf '3||'; return 0; }
  done
  printf '%s|%s|%s' "$rc" "$FM_TEST_RECORD" "$FM_TEST_NEEDS"
}

reference_scan() {  # <log> <start> -> "<rc>|<record>|<needs>"
  local log=$1 start=$2 rc
  FM_TEST_REF_RECORD=''
  FM_TEST_REF_NEEDS=0
  FM_CLASSIFY_SPAN_SCAN_REFERENCE=whole-file \
    status_span_first_actionable_record "$log" "$start" FM_TEST_REF_RECORD FM_TEST_REF_NEEDS
  rc=$?
  printf '%s|%s|%s' "$rc" "$FM_TEST_REF_RECORD" "$FM_TEST_REF_NEEDS"
}

assert_equivalent() {  # <log> <start> <label>
  local log=$1 start=$2 label=$3 ref new
  ref=$(reference_scan "$log" "$start")
  new=$(bounded_scan_all "$log" "$start")
  assert_equals "$ref" "$new" "$label"
}

# --- equivalence over every fold shape --------------------------------------

case_dir="$STATE/equivalence"
mkdir -p "$case_dir" || fail "could not create $case_dir"
build_log "$case_dir/status.status" 40 || fail "could not build the fixture log"
eq_log="$case_dir/status.status"

assert_equivalent "$eq_log" 0 "whole span: bounded scan equals the whole-file fold"
assert_equivalent "$eq_log" "$(line_offset "$eq_log" 4)" "mid-span start: bounded scan equals the whole-file fold"
assert_equivalent "$eq_log" "$(line_offset "$eq_log" 12)" "late start: bounded scan equals the whole-file fold"
assert_equivalent "$eq_log" 999999 "start past the end: bounded scan equals the whole-file fold"
pass "equivalence: bounded span scan equals the whole-file fold on every start offset"

# A span that begins mid-line is the one case the two disagree on, and the
# disagreement is one-directional: the whole-file fold compared a span position
# against an absolute one and reported no live declaration at all, while the
# bounded scan's positions are self-consistent and report it. The bounded scan
# must never report less than the fold did.
mid_off=$(( $(line_offset "$eq_log" 4) + 3 ))
mid_ref=$(reference_scan "$eq_log" "$mid_off")
mid_new=$(bounded_scan_all "$eq_log" "$mid_off")
assert_not_contains "$mid_ref" 'needs-decision: [key=dec-4] pick a path 4' \
  "the whole-file fold did not drop the live declaration this case is about"
assert_contains "$mid_new" 'needs-decision: [key=dec-4] pick a path 4' \
  "the bounded scan did not report the live declaration it must never drop"
assert_contains "$mid_new" 'reconciliation-required: blocked: [key=pending-reply-x]' \
  "the bounded scan dropped a plain event the whole-file fold reported"
pass "equivalence: a mid-line span reports the live declarations the absolute-numbered fold dropped"

# The reused path matters: the same log classified twice must not carry state
# from the first pass into the second.
assert_equivalent "$eq_log" 0 "repeated classification of the same log"
pass "equivalence: a completed scan leaves no state that changes the next one"

# --- equivalence over pseudo-random traffic ---------------------------------

random_dir="$STATE/random"
mkdir -p "$random_dir" || fail "could not create $random_dir"
build_random_log "$random_dir/status.status" 120 || fail "could not build the random log"
assert_equivalent "$random_dir/status.status" 0 "random log from the start"
assert_equivalent "$random_dir/status.status" "$(line_offset "$random_dir/status.status" 31)" \
  "random log from a mid-span offset"
pass "equivalence: bounded span scan equals the whole-file fold on pseudo-random traffic"

# --- teeth: the skip-input fault must make the assertion red ---------------

fault_dir="$STATE/fault"
mkdir -p "$fault_dir" || fail "could not create $fault_dir"
build_log "$fault_dir/status.status" 400 || fail "could not build the fault fixture"
fault_log="$fault_dir/status.status"
rm -f "$fault_dir/.status.span-scan-cursor"
FM_TEST_FAULT_RECORD=''
FM_TEST_FAULT_NEEDS=0
FM_CLASSIFY_SPAN_SCAN_FAULT_SKIP_INPUT=1 FM_CLASSIFY_SCAN_BUDGET_SECS=1 \
  status_span_first_actionable_record "$fault_log" 0 FM_TEST_FAULT_RECORD FM_TEST_FAULT_NEEDS 2>/dev/null
fault_rc=$?
rm -f "$fault_dir/.status.span-scan-cursor"
honest=$(bounded_scan_all "$fault_log" 0)
assert_not_equals "$honest" "$fault_rc|$FM_TEST_FAULT_RECORD|$FM_TEST_FAULT_NEEDS" \
  "the skip-input fault produced the same answer as the honest scan"
pass "teeth: the equivalence assertion detects a scan that skips its input"

# --- bounded rounds and a beacon that keeps advancing ----------------------

round_dir="$STATE/rounds"
mkdir -p "$round_dir" || fail "could not create $round_dir"
build_log "$round_dir/status.status" 500 || fail "could not build the round fixture"
round_log="$round_dir/status.status"
beat="$round_dir/.beat"
: > "$beat"

budget=1
max_round_ms=0
rounds=0
total_ms=0
scan_start_ms=$(now_ms)
beat_before=$(_fm_span_scan_beat_stamp "$beat")
while :; do
  rounds=$((rounds + 1))
  start_ms=$(now_ms)
  status_span_first_actionable_record "$round_log" 0 FM_TEST_RECORD FM_TEST_NEEDS 2>/dev/null
  rc=$?
  took=$(( $(now_ms) - start_ms ))
  total_ms=$(( total_ms + took ))
  [ "$took" -gt "$max_round_ms" ] && max_round_ms=$took
  # The caller's poll loop touches its beacon at the top of every cycle, so a
  # scan split across cycles leaves the beacon advancing throughout.
  touch "$beat"
  [ "$rc" -eq 2 ] || break
  [ "$rounds" -lt 400 ] || fail "the bounded scan never completed"
done
scan_ms=$(( $(now_ms) - scan_start_ms ))

[ "$rounds" -ge 2 ] \
  || fail "an over-budget span finished in one round (records a scan that never yields)"
beat_after=$(_fm_span_scan_beat_stamp "$beat")
assert_not_equals "$beat_before" "$beat_after" "the beacon did not advance during the scan"
# The whole scan is longer than one budget, so it genuinely needed splitting; no
# single round may hold the beacon for the whole scan's cost. A round's fold is
# bounded by the budget, and its remaining work - reading the span, loading and
# saving the round state, and assembling the record - is proportional to the
# lines that fold produced, so the whole round stays a small multiple of the
# budget rather than approaching the unbounded fold's cost.
[ "$scan_ms" -gt $(( budget * 1000 )) ] \
  || fail "the fixture scan finished inside one budget, so it proves no split"
round_ceiling_ms=$(( budget * 1000 + 6000 ))
[ "$max_round_ms" -le "$round_ceiling_ms" ] \
  || fail "a round outran its budget: ${max_round_ms}ms > ${round_ceiling_ms}ms (rounds:${rounds})"
pass "bounded rounds: ${rounds} rounds over ${scan_ms}ms, slowest round ${max_round_ms}ms of a ${budget}s budget"

rm -f "$round_dir/.status.span-scan-cursor"
assert_equals "$(bounded_scan_all "$round_log" 0 | sed 's/^[0-9]*|//')" \
  "$(reference_scan "$round_log" 0 | sed 's/^[0-9]*|//')" \
  "a multi-round scan of an over-budget span reaches the whole-file answer"

# --- resumption across a process boundary ----------------------------------

resume_dir="$STATE/resume"
mkdir -p "$resume_dir" || fail "could not create $resume_dir"
build_log "$resume_dir/status.status" 400 || fail "could not build the resume fixture"
resume_log="$resume_dir/status.status"
cursor="$resume_dir/.status.span-scan-cursor"
# One round in its own process, then abandon that process entirely: everything
# the second round knows must come from the cursor on disk.
record=$(FM_CLASSIFY_SCAN_BUDGET_SECS=1 bash -c \
  '. "$1/bin/fm-classify-lib.sh"; status_span_first_actionable_record "$2" 0' \
  _ "$ROOT" "$resume_log" 2>/dev/null)
first_rc=$?
[ "$first_rc" -eq 2 ] || fail "the first round completed instead of deferring"
if [ -e "$cursor" ]; then :; else fail "an unfinished round left no cursor to resume from"; fi
resumed=$(bounded_scan_all "$resume_log" 0)
assert_equals "$(reference_scan "$resume_log" 0)" "$resumed" \
  "a fresh process resumed the abandoned scan and reached the whole-file answer"
if [ -e "$cursor" ]; then fail "a completed scan left its cursor behind"; fi
pass "resumption: an abandoned round resumes from its cursor and still reaches the full answer"

# An untrustworthy cursor must restart from the beginning, never answer from a
# partial prefix: point one at a different span start and classify anyway.
printf 'version=%s\nident=stale\nstart=999\nsize=999\nline=999\nnd=0\n' \
  "$FM_CLASSIFY_SPAN_SCAN_VERSION" > "$cursor"
assert_equivalent "$resume_log" 0 "a cursor built for another span restarted safely"
if [ -e "$cursor" ]; then fail "a completed scan left a replaced cursor behind"; fi
pass "resumption: an untrustworthy cursor restarts safely instead of answering in part"

# A cursor that passes every identity check but claims more lines than the log
# holds is stale state from a rewritten log: it must restart, never report the
# empty remainder as the answer.
size=$(wc -c < "$resume_log" | tr -d ' ')
{
  printf 'version=%s\n' "$FM_CLASSIFY_SPAN_SCAN_VERSION"
  printf 'ident=%s\n' "$(_fm_open_decisions_file_ident "$resume_log")"
  printf 'start=0\nsize=%s\nline=9999\nnd=0\n' "$size"
} > "$cursor"
assert_equivalent "$resume_log" 0 "a cursor positioned past the log's own lines restarted safely"
if [ -e "$cursor" ]; then fail "a completed scan left a stale-position cursor behind"; fi
pass "resumption: a cursor positioned past the log's lines restarts instead of answering empty"

printf 'ok - fm-classify-span-scan\n'
