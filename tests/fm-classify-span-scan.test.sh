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
#   equivalence - the bounded multi-round scan returns byte-for-byte what this
#     test's own whole-file reference fold returns, over an input covering every
#     fold shape this path consumes (plain events, decision opens and closes,
#     superseded declarations, reserved keys refused their own close, duplicate
#     lines, blank lines, a final line with no trailing newline) and over a
#     deterministic pseudo-random log;
#   teeth - a scanner that folds only part of the span returns a different answer
#     than the honest one, so the equivalence assertion cannot pass vacuously;
#   bounded rounds - an over-budget span is folded in more than one round, each
#     round finishes within its budget, and the beacon the caller touches between
#     rounds keeps advancing instead of freezing for the whole scan;
#   resumption - a scan abandoned mid-span and restarted in a fresh process
#     resumes from its cursor and still reaches the full answer, and a cursor
#     that cannot be trusted restarts safely rather than answering from part of
#     the input;
#   isolation - two callers classifying the same log from different start offsets
#     keep separate folded positions and neither restarts;
#   completion hygiene - a finished scan leaves no cursor behind.
#
# The oracle is this test's own reference_whole_file_scan, a copy of the
# pre-change whole-file fold; it re-reads the entire log, which is the unbounded
# cost the bounded scan exists to remove, so the equivalence cases stay small on
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
    [ "$rc" -eq 4 ] || break
    [ "$rounds" -lt "$max" ] || { printf '3||'; return 0; }
  done
  printf '%s|%s|%s' "$rc" "$FM_TEST_RECORD" "$FM_TEST_NEEDS"
}

# The pre-change whole-file fold, owned by this test. It re-reads and re-folds
# the ENTIRE status log on every classification - the unbounded cost the bounded
# scan exists to remove - so it is the oracle the bounded scan must match
# byte-for-byte. It never runs in production.
reference_whole_file_scan() {  # <status-file> <start> <size> <ident> <output-var> <needs-var>
  local f=$1 start=$2 size=$3 ident=$4 output_var=${5-} needs_var=${6-}
  local scratch chunk_file full_file prefix_file result
  local line verb key origins='' folded=0 rc=1 failed=0 prefix_lines=0 line_number=0 live_line='' events=''
  local _line _key _fm_span_needs_decision=0 cur_ident
  scratch=$(_fm_status_span_scratch "$f") || return 2
  chunk_file="${scratch}.span"; full_file="${scratch}.full"; prefix_file="${scratch}.prefix"
  _fm_status_read_span "$f" "$start" "$((size - start))" > "$chunk_file" 2>/dev/null \
    || { rm -f "$chunk_file" "$full_file" "$prefix_file"; return 2; }
  cur_ident=$(_fm_open_decisions_file_ident "$f") || {
    rm -f "$chunk_file" "$full_file" "$prefix_file"; return 2;
  }
  [ "$cur_ident" = "$ident" ] || { rm -f "$chunk_file" "$full_file" "$prefix_file"; return 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    if status_is_captain_held "$line"; then
      _fm_span_needs_decision=1
      continue
    fi
    status_is_captain_relevant "$line" || continue
    verb=$(status_line_verb "$line")
    case "$verb" in
      needs-decision|blocked)
        key=$(_fm_decision_key "$line") || {
          [ -n "$events" ] && events="${events} ; "
          events="${events}${line}"
          [ "$verb" = needs-decision ] && _fm_span_needs_decision=1
          rc=0
          continue
        }
        _fm_decision_key_transition_allowed "$key" "$(status_line_note "$line")" || {
          [ -n "$events" ] && events="${events} ; "
          events="${events}reconciliation-required: ${line}"
          [ "$verb" = needs-decision ] && _fm_span_needs_decision=1
          rc=0
          continue
        }
        if [ "$folded" -eq 0 ]; then
          _fm_status_read_span "$f" 0 "$size" > "$full_file" 2>/dev/null \
            || { failed=1; break; }
          if [ "$start" -gt 0 ]; then
            _fm_status_read_span "$full_file" 0 "$start" > "$prefix_file" 2>/dev/null \
              || { failed=1; break; }
            while IFS= read -r _line || [ -n "$_line" ]; do prefix_lines=$((prefix_lines + 1)); done < "$prefix_file"
          fi
          origins=$(_fm_status_open_decision_origins "$full_file") || { failed=1; break; }
          folded=1
        fi
        live_line=$(while IFS=$(printf '\t') read -r _key _line; do
          [ "$_key" = "$key" ] && { printf '%s' "$_line"; break; }
        done <<EOF
$origins
EOF
)
        [ -n "$live_line" ] && [ "$((prefix_lines + line_number))" -eq "$live_line" ] || continue
        [ -n "$events" ] && events="${events} ; "
        events="${events}${line}"
        if [ "$verb" = needs-decision ] || { [ "$verb" = blocked ] &&
          _fm_is_pending_reply_escalation "$key" "$(status_line_note "$line")"; }; then
          _fm_span_needs_decision=1
        fi
        rc=0
        ;;
      *)
        [ -n "$events" ] && events="${events} ; "
        events="${events}${line}"
        rc=0
        ;;
    esac
  done < "$chunk_file"
  rm -f "$chunk_file" "$full_file" "$prefix_file"
  [ "$failed" -eq 0 ] || return 2
  if [ "$rc" -eq 0 ]; then result="${size}"$'\t'"${ident}"$'\t'"${events}"; else result="${size}"$'\t'"${ident}"; fi
  _fm_span_scan_emit "$result" "$_fm_span_needs_decision" "$output_var" "$needs_var"
  return "$rc"
}

reference_scan() {  # <log> <start> -> "<rc>|<record>|<needs>"
  local log=$1 start=$2 rc size ident
  FM_TEST_REF_RECORD=''
  FM_TEST_REF_NEEDS=0
  size=$(_fm_status_file_size "$log" 2>/dev/null) || { printf '2||'; return 0; }
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) printf '2||'; return 0 ;; esac
  ident=$(_fm_open_decisions_file_ident "$log" 2>/dev/null) || { printf '2||'; return 0; }
  case "$start" in ''|*[!0-9]*) start=0 ;; esac
  [ "$start" -le "$size" ] || start=0
  if [ "$start" -ge "$size" ]; then
    FM_TEST_REF_RECORD="${size}"$'\t'"${ident}"
    printf '1|%s|0' "$FM_TEST_REF_RECORD"
    return 0
  fi
  reference_whole_file_scan "$log" "$start" "$size" "$ident" FM_TEST_REF_RECORD FM_TEST_REF_NEEDS
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

# --- teeth: a scan that skips its input must make the assertion red ---------

# The honest multi-round scan folds the whole span. A scanner that stops at its
# budget and reports the prefix it folded as the whole answer skips the rest of
# the span; this test builds that answer from the test side - the reference fold
# over a truncated log - and asserts it differs from the honest one, so the
# equivalence assertion cannot pass vacuously.
fault_dir="$STATE/fault"
mkdir -p "$fault_dir" || fail "could not create $fault_dir"
build_log "$fault_dir/status.status" 400 || fail "could not build the fault fixture"
fault_log="$fault_dir/status.status"
prefix_log="$fault_dir/prefix.status"
total_lines=$(wc -l < "$fault_log")
head -n $(( total_lines / 4 )) "$fault_log" > "$prefix_log" || fail "could not truncate the fault fixture"
scan_events() {  # <encoded-scan-result>
  local s=$1 rest
  s=${s#*|}; s=${s%|*}
  rest=${s#*$'\t'}
  case "$rest" in
    *$'\t'*) printf '%s' "${rest#*$'\t'}" ;;
    *) printf '' ;;
  esac
}
honest=$(bounded_scan_all "$fault_log" 0)
skipped=$(reference_scan "$prefix_log" 0)
assert_not_equals "$(scan_events "$honest")" "$(scan_events "$skipped")" \
  "a scan that skipped the unfolded tail produced the same answer as the honest scan"
pass "teeth: the equivalence assertion detects a scan that skips its input"

# Deferral is budget-bounded, and the budget is wall clock, so a fixture that
# merely exceeds one round's folding on this host could finish in a single round
# on a faster one - and a fast Linux CI host folds pure bash several times quicker
# than the macOS host these cases were written on. Deferral-dependent cases
# therefore grow their fixture until one round provably cannot finish it, so the
# case asserts a property of the code instead of the speed of the host.
defer_fixture() {  # <path> <seed-repeat> -> echoes the repeat that deferred
  local path=$1 n=$2 rc i=0
  while :; do
    build_log "$path" "$n" || return 1
    FM_CLASSIFY_SCAN_BUDGET_SECS=1 \
      status_span_first_actionable_record "$path" 0 FM_TEST_RECORD FM_TEST_NEEDS 2>/dev/null
    rc=$?
    if [ "$rc" -eq 4 ]; then
      rm -f "$(dirname "$path")"/.*.span-scan-cursor.*
      printf '%s' "$n"
      return 0
    fi
    i=$((i + 1))
    [ "$i" -lt 6 ] || return 1
    n=$((n * 2))
  done
}

# The same growth for a log whose decision sits at its END: every round must stop
# short of the tail on any host.
defer_tail_fixture() {  # <path> <seed-lines> -> echoes the line count that deferred
  local path=$1 n=$2 rc i=0 j
  while :; do
    {
      j=0
      while [ "$j" -lt "$n" ]; do
        printf 'working: routine progress line %s with some words in it\n' "$j"
        j=$((j + 1))
      done
      printf 'needs-decision: [key=tail] pick the release target\n'
    } > "$path" || return 1
    FM_CLASSIFY_SCAN_BUDGET_SECS=1 \
      status_span_first_actionable_record "$path" 0 FM_TEST_RECORD FM_TEST_NEEDS 2>/dev/null
    rc=$?
    if [ "$rc" -eq 4 ]; then
      rm -f "$(dirname "$path")"/.*.span-scan-cursor.*
      printf '%s' "$n"
      return 0
    fi
    i=$((i + 1))
    [ "$i" -lt 8 ] || return 1
    n=$((n * 2))
  done
}

# --- bounded rounds and a beacon that keeps advancing ----------------------

round_dir="$STATE/rounds"
mkdir -p "$round_dir" || fail "could not create $round_dir"
defer_fixture "$round_dir/status.status" 400 >/dev/null \
  || fail "no fixture size in this range deferred the round"
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
  FM_CLASSIFY_SCAN_BUDGET_SECS="$budget" \
    status_span_first_actionable_record "$round_log" 0 FM_TEST_RECORD FM_TEST_NEEDS 2>/dev/null
  rc=$?
  took=$(( $(now_ms) - start_ms ))
  total_ms=$(( total_ms + took ))
  [ "$took" -gt "$max_round_ms" ] && max_round_ms=$took
  # The caller's poll loop touches its beacon at the top of every cycle, so a
  # scan split across cycles leaves the beacon advancing throughout.
  touch "$beat"
  [ "$rc" -eq 4 ] || break
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

rm -f "$round_dir/.status.span-scan-cursor".*
assert_equals "$(bounded_scan_all "$round_log" 0 | sed 's/^[0-9]*|//')" \
  "$(reference_scan "$round_log" 0 | sed 's/^[0-9]*|//')" \
  "a multi-round scan of an over-budget span reaches the whole-file answer"

# --- resumption across a process boundary ----------------------------------

resume_dir="$STATE/resume"
mkdir -p "$resume_dir" || fail "could not create $resume_dir"
defer_fixture "$resume_dir/status.status" 400 >/dev/null \
  || fail "no fixture size in this range deferred the resume round"
resume_log="$resume_dir/status.status"
cursor="$resume_dir/.status.span-scan-cursor.0"
# One round in its own process, then abandon that process entirely: everything
# the second round knows must come from the cursor on disk.
record=$(FM_CLASSIFY_SCAN_BUDGET_SECS=1 bash -c \
  '. "$1/bin/fm-classify-lib.sh"; status_span_first_actionable_record "$2" 0' \
  _ "$ROOT" "$resume_log" 2>/dev/null)
first_rc=$?
[ "$first_rc" -eq 4 ] || fail "the first round completed instead of deferring"
if [ -e "$cursor" ]; then :; else fail "an unfinished round left no cursor to resume from"; fi
resumed=$(bounded_scan_all "$resume_log" 0)
assert_equals "$(reference_scan "$resume_log" 0)" "$resumed" \
  "a fresh process resumed the abandoned scan and reached the whole-file answer"
if [ -e "$cursor" ]; then fail "a completed scan left its cursor behind"; fi
pass "resumption: an abandoned round resumes from its cursor and still reaches the full answer"

# An untrustworthy cursor must restart from the beginning, never answer from a
# partial prefix: point one at a different span start and classify anyway.
printf 'version=%s\nident=stale\nstart=999\nsize=999\nline=999\nnd=0\nndp=0\n' \
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
  printf 'start=0\nsize=%s\nline=9999\nnd=0\nndp=0\n' "$size"
} > "$cursor"
assert_equivalent "$resume_log" 0 "a cursor positioned past the log's own lines restarted safely"
if [ -e "$cursor" ]; then fail "a completed scan left a stale-position cursor behind"; fi
pass "resumption: a cursor positioned past the log's lines restarts instead of answering empty"

# A rejected cursor must contribute NOTHING to the answer, including the records
# it already holds. This cursor sits at the path for the tail span being
# classified but claims start 0, so the loader reads it, accumulates its records,
# and then rejects the identity mismatch. Those records must be discarded: the
# answer has to equal the whole-file fold - which never sees the cursor - and so
# report no record at all, not surface alpha's stale event as this span's own.
leak_dir="$STATE/cursor-leak"
mkdir -p "$leak_dir" || fail "could not create $leak_dir"
leak_log="$leak_dir/status.status"
{
  printf 'needs-decision: [key=alpha] question one\n'
  i=0
  while [ "$i" -lt 30 ]; do printf 'working: filler line %s\n' "$i"; i=$((i + 1)); done
} > "$leak_log" || fail "could not build the cursor-leak fixture"
leak_start=$(line_offset "$leak_log" 2)
leak_cursor="$leak_dir/.status.span-scan-cursor.$leak_start"
{
  printf 'version=%s\n' "$FM_CLASSIFY_SPAN_SCAN_VERSION"
  printf 'ident=%s\n' "$(_fm_open_decisions_file_ident "$leak_log")"
  printf 'start=0\nsize=999\nline=1\nnd=0\nndp=0\n'
  printf 'o\talpha\tneeds-decision\tquestion one\n'
  printf 'p\talpha\t1\n'
  printf 'e\tD\talpha\t1\tneeds-decision\tneeds-decision: [key=alpha] question one\n'
} > "$leak_cursor"
assert_equivalent "$leak_log" "$leak_start" \
  "a rejected cursor contributed none of its own records to the answered span"
if [ -e "$leak_cursor" ]; then fail "the classification left a rejected cursor behind"; fi
pass "resumption: a rejected cursor's records never leak into the answered span"

# --- progress is isolated per span start ------------------------------------

# Two callers classify the same log from different start offsets. A caller's
# bounded round must persist its own folded position without rejecting,
# overwriting, or deleting another caller's; a differing start must never
# silently degrade into a full rescan from line 0.
iso_dir="$STATE/isolation"
mkdir -p "$iso_dir" || fail "could not create $iso_dir"
defer_fixture "$iso_dir/status.status" 400 >/dev/null \
  || fail "no fixture size in this range deferred the isolation round"
iso_log="$iso_dir/status.status"
iso_start_a=0
iso_start_b=$(line_offset "$iso_log" 2)
a_cursor="$iso_dir/.status.span-scan-cursor.$iso_start_a"
b_cursor="$iso_dir/.status.span-scan-cursor.$iso_start_b"

FM_CLASSIFY_SCAN_BUDGET_SECS=1 \
  status_span_first_actionable_record "$iso_log" "$iso_start_a" FM_TEST_RECORD FM_TEST_NEEDS 2>/dev/null
[ "$?" -eq 4 ] || fail "A's first isolation round completed instead of deferring"
[ -e "$a_cursor" ] || fail "A's round persisted no per-start progress cursor"
a_line=$(sed -n 's/^line=//p' "$a_cursor")
[ "${a_line:-0}" -gt 0 ] || fail "A's cursor recorded no folded lines"

FM_CLASSIFY_SCAN_BUDGET_SECS=1 \
  status_span_first_actionable_record "$iso_log" "$iso_start_b" FM_TEST_RECORD FM_TEST_NEEDS 2>/dev/null
[ "$?" -eq 4 ] || fail "B's first isolation round completed instead of deferring"
[ -e "$b_cursor" ] || fail "B's round persisted no per-start progress cursor"
b_line=$(sed -n 's/^line=//p' "$b_cursor")
[ "${b_line:-0}" -gt 0 ] || fail "B's cursor recorded no folded lines"
[ "$(sed -n 's/^line=//p' "$a_cursor")" = "$a_line" ] \
  || fail "B's round rejected or overwrote A's folded position"

FM_CLASSIFY_SCAN_BUDGET_SECS=1 \
  status_span_first_actionable_record "$iso_log" "$iso_start_a" FM_TEST_RECORD FM_TEST_NEEDS 2>/dev/null
[ "$?" -eq 4 ] || fail "A's resumed isolation round completed instead of deferring"
a_advanced=$(sed -n 's/^line=//p' "$a_cursor")
[ "${a_advanced:-0}" -gt "$a_line" ] || fail "A restarted instead of resuming its folded position"
[ "$(sed -n 's/^line=//p' "$b_cursor")" = "$b_line" ] \
  || fail "A's round rejected or overwrote B's folded position"

iso_a_final=$(bounded_scan_all "$iso_log" "$iso_start_a")
iso_b_final=$(bounded_scan_all "$iso_log" "$iso_start_b")
[ "${iso_a_final%%|*}" = 0 ] || [ "${iso_a_final%%|*}" = 1 ] \
  || fail "A did not complete after B's round interleaved: $iso_a_final"
[ "${iso_b_final%%|*}" = 0 ] || [ "${iso_b_final%%|*}" = 1 ] \
  || fail "B did not complete after A's rounds interleaved: $iso_b_final"
pass "isolation: two callers keep separate span progress without restarting"


# --- a deferral is not an unreadable log ------------------------------------

# Callers branch on this verdict: the watcher routes a deferral, the away daemon
# explains it, and the push paths mark surfaced positions from it. A readable log
# whose classification is still running must therefore never report the same
# value a genuinely unreadable status object does.
verdict_dir="$STATE/verdicts"
mkdir -p "$verdict_dir" || fail "could not create $verdict_dir"
defer_fixture "$verdict_dir/status.status" 400 >/dev/null \
  || fail "no fixture size in this range deferred the verdict round"
verdict_log="$verdict_dir/status.status"
FM_CLASSIFY_SPAN_SCAN_NOTICE=''
FM_TEST_RECORD=''
FM_TEST_NEEDS=0
FM_CLASSIFY_SCAN_BUDGET_SECS=1 \
  status_span_first_actionable_record "$verdict_log" 0 FM_TEST_RECORD FM_TEST_NEEDS 2>/dev/null
defer_rc=$?
[ "$defer_rc" -eq 4 ] \
  || fail "a readable over-budget span did not report the deferral verdict (got $defer_rc)"
[ -n "$FM_CLASSIFY_SPAN_SCAN_NOTICE" ] || fail "a deferral reported no reason"
assert_contains "$FM_CLASSIFY_SPAN_SCAN_NOTICE" 'scan budget exceeded' \
  "the deferral reason did not name the budget"

unreadable_log="$verdict_dir/unreadable.status"
ln -s "$verdict_dir/absent.status" "$unreadable_log" || fail "could not build the unreadable fixture"
FM_TEST_RECORD=''
FM_TEST_NEEDS=0
status_span_first_actionable_record "$unreadable_log" 0 FM_TEST_RECORD FM_TEST_NEEDS 2>/dev/null
unreadable_rc=$?
[ "$unreadable_rc" -eq 2 ] \
  || fail "an unreadable status object did not report the unreadable verdict (got $unreadable_rc)"
rm -f "$unreadable_log" "$verdict_dir/.status.span-scan-cursor.0"
pass "verdicts: a bounded deferral reports 4, a genuinely unreadable log still reports 2"

# --- a decision in the span's TAIL is reached by resuming -------------------

# The reported workload is a long log whose decision sits at the END of the span,
# and a log that stops growing afterwards. One bounded round must not answer for
# a tail it never folded, and the resumed rounds must find it exactly as the
# whole-file fold does.
tail_dir="$STATE/tail-decision"
mkdir -p "$tail_dir" || fail "could not create $tail_dir"
tail_log="$tail_dir/status.status"
defer_tail_fixture "$tail_log" 2000 >/dev/null \
  || fail "no fixture size in this range kept the decision out of the first round"

FM_TEST_RECORD=''
FM_TEST_NEEDS=0
FM_CLASSIFY_SCAN_BUDGET_SECS=1 \
  status_span_first_actionable_record "$tail_log" 0 FM_TEST_RECORD FM_TEST_NEEDS 2>/dev/null
tail_first_rc=$?
[ "$tail_first_rc" -eq 4 ] \
  || fail "the tail fixture finished in one round, so it proves nothing"
[ "$FM_TEST_NEEDS" -eq 0 ] \
  || fail "an unfinished round reported a decision it had not folded yet"
tail_final=$(bounded_scan_all "$tail_log" 0)
assert_contains "$tail_final" 'needs-decision: [key=tail] pick the release target' \
  "the resumed scan never reached the decision at the span's tail"
assert_equals "$(reference_scan "$tail_log" 0)" "$tail_final" \
  "a tail decision reached by resuming differs from the whole-file fold"
[ "${tail_final##*|}" = 1 ] || fail "the tail decision was not reported as decision-owned"
if [ -e "$tail_dir/.status.span-scan-cursor.0" ]; then
  fail "the resumed tail scan left a cursor behind"
fi
pass "tail decision: resuming reaches a decision in the span's tail, and an unfinished round reports none of it"

printf 'ok - fm-classify-span-scan\n'
