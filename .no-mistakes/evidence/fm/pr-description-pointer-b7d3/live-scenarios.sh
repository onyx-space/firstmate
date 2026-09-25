#!/usr/bin/env bash
set -u
. /tmp/fm-live-drive.sh

LANES_SERVED='{"github onyx-space/firstmate":{"endpoint":"server","lane":"firstmate-maintenance-lane"}}'
LANES_WIRE='{"github onyx-space/wire":{"endpoint":"server","lane":"wire-maintenance-lane"}}'
LANES_OTHER='{"gitea admin/glitter-relay":{"endpoint":"mac-mini","lane":"relay-maintenance-lane"}}'

# cfg_for <lane>:<repo-name> [<lane>:<repo-name>...] -> one endpoint config.
# The session path must end in `-<repo-name>--` under /sessions/ or wire's own
# registration check refuses the lane (a lane registered for another repository
# is no lane), so the path encodes the repository the lane actually serves.
cfg_for() {
  python3 - "$@" <<'PY'
import json, sys
sessions = {}
for spec in sys.argv[1:]:
    lane, repo = spec.split(":", 1)
    sessions[lane] = f"/home/onyx/.pi/agent/sessions/--home-onyx-code-lanes-{repo}--/fake.jsonl"
print(json.dumps({"endpoints": {"h": {
    "sshAlias": "h",
    "herdrPath": "/nonexistent/herdr",
    "firstmateCwdPrefixes": ["/home/onyx/code/firstmate"],
    "sessions": sessions,
}}}, separators=(",", ":")))
PY
}

# make_home <dir> <lanes-json-file> <config-json>
make_home() {
  local dir=$1 lanes=$2 config=$3
  mkdir -p "$dir/home/.config/wire" "$dir/home/.pi/agent/data" "$dir/home/code/origmd/ref"
  echo server > "$dir/home/.pi/agent/data/origmd-machine"
  if [ -n "$lanes" ]; then cp "$lanes" "$dir/home/code/origmd/ref/lanes.json"; fi
  printf '%s' "$config" > "$dir/home/.config/wire/config.json"
  chmod 600 "$dir/home/.config/wire/config.json"
  mkdir -p "$dir/fmhome/state"
}

mailbox_files() { ls -1 "$1/home/.config/wire/inbox" 2>/dev/null | wc -l; }
wake_rows() { awk -F '\t' 'NF >= 5 { n++ } END { print n + 0 }' "$1/.wake-queue"; }

MERGE_FIRSTMAKE='【中继变更】github onyx-space/firstmate#37：open → merged | 标题：x | 链接：https://github.com/onyx-space/firstmate/pull/37'
CLOSED_FIRSTMAKE='【中继变更】github onyx-space/firstmate#38：open → closed | 标题：y | 链接：https://github.com/onyx-space/firstmate/pull/38'
MERGE_OTHER='【中继变更】gitea admin/glitter-relay#9：open → merged | 标题：z | 链接：http://10.0.99.5:3000/admin/glitter-relay/pulls/9'
MERGE_TITLE_MENTION='【中继变更】github onyx-space/pi#5：open → merged | 标题：follow-up to onyx-space/wire#124 | 链接：https://github.com/onyx-space/wire/pull/124'

SCENARIOS=()
RESULT_OK=0
scenario() { echo; echo "################ $1 ################"; }
note_result() { SCENARIOS+=("$1|$2|$3"); [ "$2" = pass ] || RESULT_OK=1; echo "RESULT $1: $2"; }

# ---------------------------------------------------------------- S1
s1() {
  scenario "S1 joined-map-first dispatch (no machine file at all)"
  local dir state id
  dir=$(make_case s1-map-first)
  printf '%s' "$LANES_SERVED" > "$dir/lanes.json"
  make_home "$dir" "$dir/lanes.json" "$(cfg_for firstmate-maintenance-lane:firstmate)"
  state="$dir/state"
  id=$(queue "$state" "$MERGE_FIRSTMAKE")
  run_drain_ack "$dir" "$state" s1
  echo "ack rc=$RV_ACK_RC"; cat "$OUT/s1.ack.err"
  echo "inbox tree:"; find "$state/inbox" -type f | sed "s#$dir/##" | sort
  echo "real wire mailbox files: $(mailbox_files "$dir")"
  grep -h 'merge wake' "$dir/home/.config/wire/inbox"/* 2>/dev/null | head -2
  if [ "$RV_ACK_RC" = 0 ] && grep -q 'dispatched' "$OUT/s1.ack.err" \
     && [ -f "$state/inbox/dispatched/$id.note" ] && [ ! -e "$state/inbox/handled/$id.note" ] \
     && [ "$(mailbox_files "$dir")" = 1 ] && [ "$(wake_rows "$state")" = 0 ] \
     && grep -q 'merge wake: onyx-space/firstmate merged' "$dir/home/.config/wire/inbox"/*; then
    note_result "S1" pass "ack.err names the dispatch; note in dispatched/; real wire mailbox payload names the merge; wake row consumed"
  else
    note_result "S1" fail "one of the S1 assertions did not hold"
  fi
}

# ---------------------------------------------------------------- S2
s2() {
  scenario "S2 map entry naming another machine is not dispatched from here"
  local dir state id lane_dir
  dir=$(make_case s2-other-machine)
  printf '%s' "$LANES_OTHER" > "$dir/lanes.json"
  make_home "$dir" "$dir/lanes.json" "$(cfg_for relay-maintenance-lane:glitter-relay)"
  # Adversarial: this machine's own machine file declares a lane whose checkout is
  # that repository; the map explicitly places it on mac-mini, so it must not be
  # second-guessed into a local dispatch.
  lane_dir="$dir/lane-relay"
  git init -q "$lane_dir"; git -C "$lane_dir" remote add origin https://github.com/admin/glitter-relay.git
  cat > "$dir/home/AGENTS.md" <<EOF
- Long-lived maintenance lanes: \`relay-maintenance-lane\` (pane \`w1:p2\`, \`$lane_dir\`); captain-owned.
EOF
  state="$dir/state"
  id=$(queue "$state" "$MERGE_OTHER")
  run_drain_ack "$dir" "$state" s2
  echo "ack rc=$RV_ACK_RC"; cat "$OUT/s2.ack.err"
  echo "inbox tree:"; find "$state/inbox" -type f | sed "s#$dir/##" | sort
  echo "real wire mailbox files: $(mailbox_files "$dir")"
  if [ "$RV_ACK_RC" = 0 ] && [ -f "$state/inbox/handled/$id.note" ] \
     && [ ! -d "$state/inbox/dispatched" ] && [ "$(mailbox_files "$dir")" = 0 ]; then
    note_result "S2" pass "map entry on mac-mini archived here; no wire send; no local dispatched record"
  else
    note_result "S2" fail "another machine's repository was dispatched from here"
  fi
}

# ---------------------------------------------------------------- S3
s3() {
  scenario "S3 map silent about the repository -> machine-file fallback dispatches"
  local dir state id lane_dir
  dir=$(make_case s3-fallback)
  printf '{}' > "$dir/lanes.json"
  make_home "$dir" "$dir/lanes.json" "$(cfg_for fallback-lane:firstmate)"
  lane_dir="$dir/lane-firstmate"
  git init -q "$lane_dir"; git -C "$lane_dir" remote add origin https://github.com/onyx-space/firstmate.git
  cat > "$dir/home/AGENTS.md" <<EOF
- Long-lived maintenance lanes: \`fallback-lane\` (pane \`w1:p2\`, \`$lane_dir\`); captain-owned.
EOF
  state="$dir/state"
  id=$(queue "$state" "$MERGE_FIRSTMAKE")
  run_drain_ack "$dir" "$state" s3
  echo "ack rc=$RV_ACK_RC"; cat "$OUT/s3.ack.err"
  echo "inbox tree:"; find "$state/inbox" -type f | sed "s#$dir/##" | sort
  echo "real wire mailbox files: $(mailbox_files "$dir")"
  grep -h 'merge wake' "$dir/home/.config/wire/inbox"/* 2>/dev/null | head -2
  if [ "$RV_ACK_RC" = 0 ] && grep -q 'dispatched .*fallback-lane' "$OUT/s3.ack.err" \
     && [ -f "$state/inbox/dispatched/$id.note" ] && [ "$(mailbox_files "$dir")" = 1 ]; then
    note_result "S3" pass "empty map fell back to the machine file's lane + checkout and dispatched"
  else
    note_result "S3" fail "machine-file fallback did not dispatch"
  fi
}

# ---------------------------------------------------------------- S4
s4() {
  scenario "S4 routed by the note's own token, not a repository named in its title"
  local dir state id lane_dir
  dir=$(make_case s4-title-mention)
  printf '%s' "$LANES_WIRE" > "$dir/lanes.json"
  make_home "$dir" "$dir/lanes.json" "$(cfg_for wire-maintenance-lane:wire)"
  lane_dir="$dir/lane-wire"
  git init -q "$lane_dir"; git -C "$lane_dir" remote add origin https://github.com/onyx-space/wire.git
  cat > "$dir/home/AGENTS.md" <<EOF
- Long-lived maintenance lanes: \`wire-maintenance-lane\` (pane \`w1:p2\`, \`$lane_dir\`); captain-owned.
EOF
  state="$dir/state"
  id=$(queue "$state" "$MERGE_TITLE_MENTION")
  run_drain_ack "$dir" "$state" s4
  echo "ack rc=$RV_ACK_RC"; cat "$OUT/s4.ack.err"
  echo "inbox tree:"; find "$state/inbox" -type f | sed "s#$dir/##" | sort
  echo "real wire mailbox files: $(mailbox_files "$dir")"
  if [ "$RV_ACK_RC" = 0 ] && [ -f "$state/inbox/handled/$id.note" ] \
     && [ ! -d "$state/inbox/dispatched" ] && [ "$(mailbox_files "$dir")" = 0 ]; then
    note_result "S4" pass "note's own repo (pi) is unserved -> archived; the title's wire lane was not used"
  else
    note_result "S4" fail "a repository named only in the title drove the dispatch"
  fi
}

# ---------------------------------------------------------------- S5
s5() {
  scenario "S5 adversarial fail-closed: real wire send with an unreadable mailbox stays retryable"
  local dir state id seq gen
  dir=$(make_case s5-fail-closed)
  printf '%s' "$LANES_SERVED" > "$dir/lanes.json"
  make_home "$dir" "$dir/lanes.json" "$(cfg_for firstmate-maintenance-lane:firstmate)"
  state="$dir/state"
  mkdir -p "$dir/home/.config/wire/inbox"
  id=$(queue "$state" "$MERGE_FIRSTMAKE")
  PATH="$dir/fakebin:$PATH" HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_HOME="$dir/fmhome" \
    "$DRAIN" > "$OUT/s5.drain.out" 2> "$OUT/s5.drain.err" || fail "S5 drain failed"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$OUT/s5.drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$OUT/s5.drain.err")
  chmod 500 "$dir/home/.config/wire/inbox"
  RV_ACK_RC=0
  PATH="$dir/fakebin:$PATH" HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_HOME="$dir/fmhome" \
    "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    > "$OUT/s5.ack.out" 2> "$OUT/s5.ack.err" || RV_ACK_RC=$?
  chmod 700 "$dir/home/.config/wire/inbox"
  echo "ack rc=$RV_ACK_RC"; cat "$OUT/s5.ack.err"
  echo "note still pending: $([ -f "$state/inbox/$id.note" ] && echo yes || echo no)"
  echo "wake rows left: $(wake_rows "$state")"
  echo "dispatched dir: $([ -d "$state/inbox/dispatched" ] && echo present || echo absent)"
  echo "wire mailbox payload count: $(mailbox_files "$dir")"
  if [ "$RV_ACK_RC" != 0 ] && [ -f "$state/inbox/$id.note" ] \
     && [ ! -e "$state/inbox/dispatched/$id.note" ] && [ "$(wake_rows "$state")" -ge 1 ] \
     && grep -q 'unreadable' "$OUT/s5.ack.err" && [ "$(mailbox_files "$dir")" = 0 ]; then
    note_result "S5" pass "real wire reported mailbox: unreadable; ack failed, note and wake row left retryable"
  else
    note_result "S5" fail "a wire send that could not deliver was recorded as a dispatch"
  fi
}

# ---------------------------------------------------------------- S6
s6() {
  scenario "S6 an ordinary (non-merge) relay note keeps the archive path"
  local dir state id
  dir=$(make_case s6-non-merge)
  printf '%s' "$LANES_SERVED" > "$dir/lanes.json"
  make_home "$dir" "$dir/lanes.json" "$(cfg_for firstmate-maintenance-lane:firstmate)"
  state="$dir/state"
  id=$(queue "$state" "$CLOSED_FIRSTMAKE")
  run_drain_ack "$dir" "$state" s6
  echo "ack rc=$RV_ACK_RC"; cat "$OUT/s6.ack.err"
  echo "inbox tree:"; find "$state/inbox" -type f | sed "s#$dir/##" | sort
  echo "real wire mailbox files: $(mailbox_files "$dir")"
  if [ "$RV_ACK_RC" = 0 ] && [ -f "$state/inbox/handled/$id.note" ] \
     && [ ! -d "$state/inbox/dispatched" ] && [ "$(mailbox_files "$dir")" = 0 ]; then
    note_result "S6" pass "closed (non-merge) relay note archived, not dispatched"
  else
    note_result "S6" fail "a non-merge relay note was dispatched"
  fi
}

# ---------------------------------------------------------------- S7
s7() {
  scenario "S7 a repository with no lane at all keeps the archive path"
  local dir state id
  dir=$(make_case s7-no-lane)
  printf '{}' > "$dir/lanes.json"
  make_home "$dir" "$dir/lanes.json" '{"endpoints":{"h":{"sshAlias":"h","herdrPath":"/nonexistent/herdr","firstmateCwdPrefixes":["/home/onyx/code/firstmate"]}}}'
  printf '# no lanes here\n' > "$dir/home/AGENTS.md"
  state="$dir/state"
  id=$(queue "$state" "$MERGE_FIRSTMAKE")
  run_drain_ack "$dir" "$state" s7
  echo "ack rc=$RV_ACK_RC"; cat "$OUT/s7.ack.err"
  echo "inbox tree:"; find "$state/inbox" -type f | sed "s#$dir/##" | sort
  echo "real wire mailbox files: $(mailbox_files "$dir")"
  if [ "$RV_ACK_RC" = 0 ] && [ -f "$state/inbox/handled/$id.note" ] \
     && [ ! -d "$state/inbox/dispatched" ] && [ "$(mailbox_files "$dir")" = 0 ]; then
    note_result "S7" pass "no lane anywhere -> archive, no send"
  else
    note_result "S7" fail "a merge with no lane was dispatched"
  fi
}

# ---------------------------------------------------------------- S8
s8() {
  scenario "S8 no lane map at all -> machine-file fallback dispatches"
  local dir state id lane_dir
  dir=$(make_case s8-no-lane-map)
  make_home "$dir" "" "$(cfg_for fallback-lane:firstmate)"
  # make_home with an empty lanes arg must not leave a map behind.
  rm -f "$dir/home/code/origmd/ref/lanes.json"
  lane_dir="$dir/lane-firstmate"
  git init -q "$lane_dir"; git -C "$lane_dir" remote add origin https://github.com/onyx-space/firstmate.git
  cat > "$dir/home/AGENTS.md" <<EOF
- Long-lived maintenance lanes: \`fallback-lane\` (pane \`w1:p2\`, \`$lane_dir\`); captain-owned.
EOF
  state="$dir/state"
  id=$(queue "$state" "$MERGE_FIRSTMAKE")
  run_drain_ack "$dir" "$state" s8
  echo "ack rc=$RV_ACK_RC"; cat "$OUT/s8.ack.err"
  echo "inbox tree:"; find "$state/inbox" -type f | sed "s#$dir/##" | sort
  echo "real wire mailbox files: $(mailbox_files "$dir")"
  if [ "$RV_ACK_RC" = 0 ] && grep -q 'dispatched .*fallback-lane' "$OUT/s8.ack.err" \
     && [ -f "$state/inbox/dispatched/$id.note" ] && [ "$(mailbox_files "$dir")" = 1 ]; then
    note_result "S8" pass "absent lane map fell back to the machine file and dispatched"
  else
    note_result "S8" fail "absent lane map did not fall back"
  fi
}

s1; s2; s3; s4; s5; s6; s7; s8

echo
echo "================ SUMMARY ================"
for row in "${SCENARIOS[@]}"; do echo "$row"; done
exit $RESULT_OK
