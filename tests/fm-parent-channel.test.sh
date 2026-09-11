#!/usr/bin/env bash
# tests/fm-parent-channel.test.sh - a remote secondmate home's OWN parent-channel
# outbound log (state/parent-replies.status) is a stream that home PUBLISHES its
# captain-facing outcomes on, not one of its task supervision logs. The home it
# publishes to does the classifying, on the parent's own state/<mate-id>.status
# file (docs/secondmate-parent-channel.md).
#
# Before this guard the channel file fell inside the mate home's own
# state/*.status walks and was classified as a task named `parent-replies`: a
# phantom `signal parent-replies.status` wake from the per-poll scan, a phantom
# open decision the wake drain offered to answer with `fm-send --resolve-key`,
# and a phantom row in the heartbeat backstop. The rule is now one predicate,
# bin/fm-parent-channel-lib.sh's fm_parent_channel_is_own_log, and every one of
# those walks consults it. Scoping matters as much as the exclusion does: only a
# remote-route mate home owns such a log, so a main home's same-named file and
# every ordinary <task>.status log keep being scanned exactly as before.
#
# The scans are driven by sourcing the REAL watcher and classifier in a fresh
# process per call, so these exercise production code rather than a
# re-implementation of it. There is no harness and no backend here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$ROOT/bin/fm-parent-channel-lib.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-parent-channel-tests)
mkdir -p "$TMP_ROOT"

# A syntactically valid correlation token payload: 16 hex characters.
CORR=c44897ee2db4326b

# make_home <name> <route>: a make_case world (a home root with state/ and
# fakebin/) plus, for a "local" or "remote" route, the secondmate identity marker
# and parent binding that home carries. "main" leaves it a primary-shaped home.
# Echoes the home path.
make_home() {  # <name> <route>
  local name=$1 route=$2 home
  home=$(make_case "$name")
  case "$route" in
    main) ;;
    local|remote)
      printf 'sm-a1\n' > "$home/.fm-secondmate-home"
      if [ "$route" = local ]; then
        printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$TMP_ROOT/parent" \
          > "$home/.fm-secondmate-parent"
      else
        printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=host-a\n' \
          > "$home/.fm-secondmate-parent"
      fi
      ;;
    *) fail "make_home: unknown route '$route'" ;;
  esac
  printf '%s\n' "$home"
}

# The channel log's own content: the lines a remote mate home publishes upward,
# every one of them something a task-state scan would otherwise surface.
write_channel_log() {  # <home>
  local state=$1/state
  {
    printf 'done [corr=%s]: child finished\n' "$CORR"
    printf 'needs-decision [key=captain-hold-x-1]: captain hold x: pick one\n'
    printf 'note: judgement the mate appended itself\n'
  } > "$state/parent-replies.status"
}

# A real task log beside it, so every case has a positive control: the exclusion
# must be exactly as narrow as the one file.
write_task_log() {  # <home>
  {
    printf 'working: step 1\n'
    printf 'blocked: waiting on creds\n'
    printf 'note: read me\n'
  } > "$1/state/t1.status"
}

# make_populated_home <name>: a remote mate home carrying the parent-channel log
# and a real task log beside it. Echoes the home path.
make_populated_home() {  # <name>
  local home
  home=$(make_home "$1" remote)
  write_channel_log "$home"
  write_task_log "$home"
  printf '%s\n' "$home"
}

# Run ONE production task-state scan against <home> in its own process, with the
# watcher's own state override, and print the rows it found. A fresh process per
# call because the watcher binds its state directory when it is sourced.
scan_rows() {  # <home> <scan>
  local home=$1 scan=$2
  PATH="$home/fakebin:$PATH" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" \
    bash -c '
      state=$3/state
      . "$1/bin/fm-watch.sh"
      case "$2" in
        signals) scan_signals ;;
        heartbeat)
          heartbeat_scan_finds_actionable && printf "%s\n" "$FM_HEARTBEAT_SURFACE_ENDPOINTS"
          ;;
        open) scan_open_decisions "$state" ;;
        open-incremental) scan_open_decisions_incremental "$state" ;;
        unread) scan_unread_surface_lines "$state" ;;
        snapshot) status_presentation_snapshot "$state" ;;
        *) printf "unknown scan: %s\n" "$2" >&2; exit 2 ;;
      esac
    ' _ "$ROOT" "$scan" "$home"
}

test_exclusion_is_scoped_to_a_remote_mate_home() {
  local mate mainmate localmate
  mate=$(make_home pc-scope-remote remote)
  mainmate=$(make_home pc-scope-main main)
  localmate=$(make_home pc-scope-local local)

  fm_parent_channel_is_own_log "$mate/state" "$mate/state/parent-replies.status" \
    || fail "a remote mate home's own parent-channel log was not recognized"
  fm_parent_channel_is_own_log "$mate/state" "$mate/state/t1.status" \
    && fail "an ordinary task log was treated as the parent channel"
  fm_parent_channel_is_own_log "$mate/state" "$mate/state/parent-replies.status.bak" \
    && fail "a lookalike file name was treated as the parent channel"
  fm_parent_channel_is_own_log "$mainmate/state" "$mainmate/state/parent-replies.status" \
    && fail "a MAIN home's same-named file was excluded from its scans"
  fm_parent_channel_is_own_log "$localmate/state" "$localmate/state/parent-replies.status" \
    && fail "a LOCAL-route mate home's same-named file was excluded - only the remote route publishes on this path"

  pass "only a remote mate home's own parent-channel log is recognized"
}

test_watcher_scans_skip_the_channel_log_and_still_see_a_task() {
  local home rows
  home=$(make_populated_home pc-watcher-scan)

  rows=$(scan_rows "$home" signals)
  assert_not_contains "$rows" "parent-replies" \
    "the per-poll signal scan classified the mate's own parent-channel log as a task"
  assert_contains "$rows" "t1.status" \
    "the per-poll signal scan stopped seeing an ordinary task log beside the channel"

  rows=$(scan_rows "$home" heartbeat)
  assert_not_contains "$rows" "parent-replies" \
    "the heartbeat backstop surfaced the mate's own parent-channel log"
  assert_contains "$rows" "t1.status" \
    "the heartbeat backstop stopped seeing an ordinary task log beside the channel"

  pass "the watcher's scans skip the parent-channel log and keep scanning a task log"
}

test_classify_scans_skip_the_channel_log_and_still_see_a_task() {
  # Each scan gets its own home: these scans share byte cursors under state/, so
  # one scan's cursor could otherwise decide what the next one reports.
  local home rows

  home=$(make_populated_home pc-classify-open)
  rows=$(scan_rows "$home" open)
  assert_not_contains "$rows" "parent-replies" \
    "the whole-file open-decision fold folded an outbound report into an open decision"
  assert_contains "$rows" "t1" \
    "the whole-file open-decision fold stopped seeing a task's open decision"

  home=$(make_populated_home pc-classify-open-incremental)
  rows=$(scan_rows "$home" open-incremental)
  assert_not_contains "$rows" "parent-replies" \
    "the cursor-backed open-decision fold folded an outbound report into an open decision"
  assert_contains "$rows" "t1" \
    "the cursor-backed open-decision fold stopped seeing a task's open decision"

  home=$(make_populated_home pc-classify-unread)
  rows=$(scan_rows "$home" unread)
  assert_not_contains "$rows" "parent-replies" \
    "the unread-status scan surfaced the mate's own outbound reports as unread status"
  assert_contains "$rows" "t1" \
    "the unread-status scan stopped seeing a task's own note"

  home=$(make_populated_home pc-classify-snapshot)
  rows=$(scan_rows "$home" snapshot)
  assert_not_contains "$rows" "parent-replies" \
    "the presentation snapshot minted a task identity for the mate's own outbound log"
  assert_contains "$rows" "t1" \
    "the presentation snapshot stopped covering a real task"

  pass "the classifier's fleet-wide scans skip the parent-channel log and keep scanning a task log"
}

test_drain_reports_no_open_decision_for_the_channel_log() {
  local home out
  home=$(make_populated_home pc-drain-open)

  out=$(FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>&1) \
    || fail "the drain failed over the mate home"

  assert_not_contains "$out" "parent-replies" \
    "the drain offered the mate's own outbound reports as open decisions awaiting an answer"
  assert_contains "$out" "t1" \
    "the drain stopped folding a real task's open decision"

  pass "the drain folds no open decision from the mate's own parent-channel log"
}

# --- the note fold -----------------------------------------------------------
#
# fm_parent_channel_clean_note folds arbitrary text onto one bounded line for the
# channel, so the bound has to land on a UTF-8 character boundary. It used to be
# `LC_ALL=C cut -c1-1200`, which counts bytes and then cuts at whatever byte came
# 1200th: a multibyte character straddling the bound was split in half and the
# channel carried invalid UTF-8, one bad byte that made a consumer strictly
# decoding the file fail on the whole record. GNU cut counts bytes while BSD cut
# counts characters, so the split reproduced only on Linux - these cases are a
# real guard in CI and happen to pass on macOS, where the old code was safe by
# accident.

# utf8_well_formed <file>: true only when <file> is well-formed UTF-8. The
# assertion is on the fold's OUTPUT BYTES, never on how the fold is written.
utf8_well_formed() {  # <file>
  local line byte need=0
  while IFS= read -r line; do
    for byte in $line; do
      if [ "$need" -gt 0 ]; then
        [ $((byte & 192)) -eq 128 ] || return 1
        need=$((need - 1))
        continue
      fi
      if [ "$byte" -lt 128 ]; then
        continue
      elif [ "$byte" -ge 192 ] && [ "$byte" -lt 224 ]; then
        need=1
      elif [ "$byte" -ge 224 ] && [ "$byte" -lt 240 ]; then
        need=2
      elif [ "$byte" -ge 240 ] && [ "$byte" -lt 248 ]; then
        need=3
      else
        return 1
      fi
    done
  done < <(LC_ALL=C od -An -v -tu1 < "$1")
  [ "$need" -eq 0 ]
}

test_folded_note_never_splits_a_multibyte_character() {
  local len pad text folded bytes alignments=0
  local intro='修好了：中文不会再被切成半个字 '
  # Every cheap alignment of an ASCII prefix against the 1200-byte bound. With a
  # three-byte character two of every three prefixes push the bound into the
  # middle of one, so a fold that cuts on a byte count cannot pass this.
  for len in $(seq 0 20); do
    pad=$(printf '%*s' "$len" '' | tr ' ' A)
    for text in \
      "$intro$pad$(printf '中%.0s' $(seq 1 500))" \
      "$intro$pad$(printf '😀%.0s' $(seq 1 400))"; do
      folded=$(fm_parent_channel_clean_note "$text")
      printf '%s' "$folded" > "$TMP_ROOT/folded-note.bin"
      utf8_well_formed "$TMP_ROOT/folded-note.bin" \
        || fail "the fold split a multibyte character at ASCII-prefix $len, so the channel line carried invalid UTF-8"
      bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/folded-note.bin" | tr -d ' ')
      [ "$bytes" -le 1200 ] \
        || fail "the folded line grew past its byte bound: $bytes bytes at ASCII-prefix $len"
      case "$folded" in
        *$'\n'*) fail "the folded note kept a line break at ASCII-prefix $len" ;;
      esac
      assert_contains "$folded" "修好了" \
        "the fold lost the note's own text at ASCII-prefix $len"
      alignments=$((alignments + 1))
    done
  done

  assert_equals "$(fm_parent_channel_clean_note 'done [key=x]: 修好了')" 'done [key=x]: 修好了' \
    "the fold changed a note that already fits"
  assert_equals "$(fm_parent_channel_clean_note $'第一行\n第二行\t末')" '第一行 第二行 末' \
    "the fold stopped collapsing line breaks and tabs into one line"

  pass "the note fold keeps a bounded one-line note that is valid UTF-8 ($alignments boundary alignments)"
}

test_exclusion_is_scoped_to_a_remote_mate_home
test_watcher_scans_skip_the_channel_log_and_still_see_a_task
test_classify_scans_skip_the_channel_log_and_still_see_a_task
test_drain_reports_no_open_decision_for_the_channel_log
test_folded_note_never_splits_a_multibyte_character
