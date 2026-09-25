#!/usr/bin/env bash
# Live drive of bin/fm-inbox.sh + bin/fm-wake-drain.sh with the REAL `wire`
# binary's `route` (reading a real joined lane map under an isolated HOME) and
# the real `wire send`, which for a lane registered on this endpoint (key h)
# delivers into the isolated endpoint's own inbox with no network or fleet write.
set -u

WT=/home/onyx/.no-mistakes/worktrees/42774a4b8442/01M3BZZCVN8XKJ97FZ3Z3SV5QE
INBOX_BIN="$WT/bin/fm-inbox.sh"
DRAIN="$WT/bin/fm-wake-drain.sh"
REAL_WIRE=$(command -v wire)
REAL_WIRE_DIR=$(dirname "$REAL_WIRE")

# shellcheck source=/dev/null
. "$WT/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-lanes)

PASS=0; FAILN=0
say() { printf '\n===== %s =====\n' "$*"; }
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAILN=$((FAILN + 1)); printf 'FAIL  %s -- %s\n' "$1" "$2"; }
check() { if [ "$2" = 1 ]; then ok "$1"; else bad "$1" "$3"; fi; }

new_case() { # <name>
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/home/code/origmd/ref" "$dir/home/.config/wire" "$dir/home/.pi/agent/data"
  printf 'server\n' > "$dir/home/.pi/agent/data/origmd-machine"
  printf '%s\n' "$dir"
}

lane_checkout() { mkdir -p "$1"; git init -q "$1"; git -C "$1" remote add origin "$2"; }

session_for() { # <home> <repo-name> -> session path with a matching basename
  local p="$1/sessions/--code-$2--/lane.jsonl"
  mkdir -p "$(dirname "$p")"; : > "$p"; printf '%s\n' "$p"
}

# full_config <h-sessions-json>: every configured endpoint row carries the fields
# wire's config validation requires.
full_config() {
  printf '{"endpoints":{"h":{"sshAlias":"h","herdrPath":"/usr/local/bin/herdr","firstmateCwdPrefixes":["/home/onyx/code/firstmate"],"sessions":%s},"m":{"sshAlias":"m","herdrPath":"/Users/onyx/.local/bin/herdr","firstmateCwdPrefixes":["/Users/onyx/code/firstmate"]}}}' "$1"
}
write_config() { mkdir -p "$1/.config/wire"; printf '%s' "$2" > "$1/.config/wire/config.json"; chmod 600 "$1/.config/wire/config.json"; }

queue_relay() { HOME="$1" FM_STATE_OVERRIDE="$2" "$INBOX_BIN" note --source relay "$3" | sed -n 's/^queued //p'; }

drain_then_ack() { # <home> <state> <machine> <config> <tag> [path-override] -> ack rc
  local home=$1 state=$2 machine=$3 config=$4 tag=$5 patho=${6:-} dir seq gen rc=0 dpath
  dir=$(dirname "$state")
  dpath="$dir/fakebin:${patho:-$PATH}"
  env HOME="$home" FM_STATE_OVERRIDE="$state" FM_MACHINE_FILE="$machine" \
    FM_WIRE_CONFIG="$config" PATH="$dpath" "$DRAIN" \
    > "$dir/$tag.drain.out" 2> "$dir/$tag.drain.err" || { echo drain-failed; return 9; }
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$dir/$tag.drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$dir/$tag.drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] || { echo no-ack-required; return 9; }
  env HOME="$home" FM_STATE_OVERRIDE="$state" FM_MACHINE_FILE="$machine" \
    FM_WIRE_CONFIG="$config" PATH="$dpath" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    > "$dir/$tag.ack.out" 2> "$dir/$tag.ack.err" || rc=$?
  echo "$rc"
}

inbox_count() { [ -d "$1/.config/wire/inbox" ] && find "$1/.config/wire/inbox" -maxdepth 1 -type f | wc -l | tr -d ' ' || echo 0; }
has_payload() { [ -n "$(grep -rlF "$2" "$1/.config/wire/inbox" 2>/dev/null | head -n1)" ]; }

MERGE_FM='【中继变更】github onyx-space/firstmate#37：open → merged | 标题：x | 链接：https://github.com/onyx-space/firstmate/pull/37'

say "S1 map-first dispatch (real wire route + real wire send)"
d=$(new_case s1); home="$d/home"; state="$d/state"
lane_checkout "$d/lane-firstmate" "https://github.com/onyx-space/firstmate.git"
printf '{ "github onyx-space/firstmate": { "endpoint": "server", "lane": "firstmate-maintenance-lane" } }\n' > "$home/code/origmd/ref/lanes.json"
write_config "$home" "$(full_config "{\"firstmate-maintenance-lane\":\"$(session_for "$home" firstmate)\"}")"
printf '# no lane declared here; the map must be what answers\n' > "$home/AGENTS.md"
printf 'wire route (real binary):\n'; HOME="$home" "$REAL_WIRE" route --repo github/onyx-space/firstmate
id=$(queue_relay "$home" "$state" "$MERGE_FM")
rc=$(drain_then_ack "$home" "$state" "$home/AGENTS.md" "$home/.config/wire/config.json" s1)
echo "ack rc: $rc"; echo "-- ack stderr --"; cat "$d/s1.ack.err"
echo "-- delivered payload --"; grep -rh '^wire:delivery\|merged' "$home/.config/wire/inbox" 2>/dev/null
check "S1 ack accepted" "$([ "$rc" = 0 ] && echo 1 || echo 0)" "ack rc=$rc"
check "S1 note recorded in dispatched/" "$([ -f "$state/inbox/dispatched/$id.note" ] && echo 1 || echo 0)" "not in dispatched/"
check "S1 note not archived as handled" "$([ ! -e "$state/inbox/handled/$id.note" ] && echo 1 || echo 0)" "handled copy exists"
check "S1 real wire send delivered exactly one payload" "$([ "$(inbox_count "$home")" = 1 ] && echo 1 || echo 0)" "count=$(inbox_count "$home")"
check "S1 payload names the repo and merge" "$(has_payload "$home" 'merge wake: onyx-space/firstmate merged' && echo 1 || echo 0)" "text missing"
check "S1 payload addressed to the mapped lane" "$(has_payload "$home" 'address=firstmate-maintenance-lane' && echo 1 || echo 0)" "address missing"
check "S1 ack names the dispatch" "$(grep -q 'dispatched' "$d/s1.ack.err" && echo 1 || echo 0)" "no dispatched line"

say "S2 map entry naming another machine is not dispatched from here"
d=$(new_case s2); home="$d/home"; state="$d/state"
lane_checkout "$d/lane-wire" "https://github.com/onyx-space/wire.git"
printf -- '- Long-lived maintenance lanes: `wire-maintenance-lane` (pane `w9:pP`, `%s`); captain-owned.\n' "$d/lane-wire" > "$home/AGENTS.md"
printf '{ "github onyx-space/wire": { "endpoint": "mac-mini", "lane": "relay-maintenance-lane" } }\n' > "$home/code/origmd/ref/lanes.json"
write_config "$home" "$(full_config '{}')"
printf 'wire route for the note repo:\n'; HOME="$home" "$REAL_WIRE" route --repo github/onyx-space/wire
id=$(queue_relay "$home" "$state" '【中继变更】github onyx-space/wire#124：open → merged | 标题：x | 链接：https://github.com/onyx-space/wire/pull/124')
rc=$(drain_then_ack "$home" "$state" "$home/AGENTS.md" "$home/.config/wire/config.json" s2)
echo "ack rc: $rc"; cat "$d/s2.ack.err"
check "S2 note archived (another machine owns it)" "$([ -f "$state/inbox/handled/$id.note" ] && echo 1 || echo 0)" "not handled"
check "S2 no dispatched record" "$([ ! -e "$state/inbox/dispatched/$id.note" ] && echo 1 || echo 0)" "dispatch happened"
check "S2 no wire delivery" "$([ "$(inbox_count "$home")" = 0 ] && echo 1 || echo 0)" "count=$(inbox_count "$home")"

say "S3 map silent (no-entry) falls back to the machine file + lane checkout"
d=$(new_case s3); home="$d/home"; state="$d/state"
lane_checkout "$d/lane-firstmate" "https://github.com/onyx-space/firstmate.git"
printf -- '- Long-lived maintenance lanes: `firstmate-maintenance-lane` (pane `w9:pZ`, `%s`); captain-owned.\n' "$d/lane-firstmate" > "$home/AGENTS.md"
printf '{ "github onyx-space/wire": { "endpoint": "server", "lane": "wire-maintenance-lane" } }\n' > "$home/code/origmd/ref/lanes.json"
write_config "$home" "$(full_config "{\"firstmate-maintenance-lane\":\"$(session_for "$home" firstmate)\"}")"
printf 'wire route for the note repo (no-entry -> fallback answers):\n'; HOME="$home" "$REAL_WIRE" route --repo github/onyx-space/firstmate
id=$(queue_relay "$home" "$state" "$MERGE_FM")
rc=$(drain_then_ack "$home" "$state" "$home/AGENTS.md" "$home/.config/wire/config.json" s3)
echo "ack rc: $rc"; cat "$d/s3.ack.err"
check "S3 fallback dispatched from the machine file" "$([ -f "$state/inbox/dispatched/$id.note" ] && echo 1 || echo 0)" "not dispatched"
check "S3 fallback addressed the machine-file lane" "$(has_payload "$home" 'address=firstmate-maintenance-lane' && echo 1 || echo 0)" "address missing"

say "S3b fallback lane whose checkout is another repo takes the archive path"
d=$(new_case s3b); home="$d/home"; state="$d/state"
lane_checkout "$d/lane-other" "https://github.com/onyx-space/other.git"
printf -- '- Long-lived maintenance lanes: `firstmate-maintenance-lane` (pane `w9:pZ`, `%s`); captain-owned.\n' "$d/lane-other" > "$home/AGENTS.md"
printf '{}\n' > "$home/code/origmd/ref/lanes.json"
write_config "$home" "$(full_config "{\"firstmate-maintenance-lane\":\"$(session_for "$home" firstmate)\"}")"
id=$(queue_relay "$home" "$state" "$MERGE_FM")
rc=$(drain_then_ack "$home" "$state" "$home/AGENTS.md" "$home/.config/wire/config.json" s3b)
echo "ack rc: $rc"; cat "$d/s3b.ack.err"
check "S3b archived: lane checkout is another repo" "$([ -f "$state/inbox/handled/$id.note" ] && echo 1 || echo 0)" "not handled"
check "S3b no wire delivery" "$([ "$(inbox_count "$home")" = 0 ] && echo 1 || echo 0)" "delivery happened"

say "S4 a non-merge relay note keeps the archive path"
d=$(new_case s4); home="$d/home"; state="$d/state"
printf '{ "github onyx-space/firstmate": { "endpoint": "server", "lane": "firstmate-maintenance-lane" } }\n' > "$home/code/origmd/ref/lanes.json"
write_config "$home" "$(full_config "{\"firstmate-maintenance-lane\":\"$(session_for "$home" firstmate)\"}")"
printf '# no lanes\n' > "$home/AGENTS.md"
id=$(queue_relay "$home" "$state" '【中继变更】github onyx-space/firstmate#38：open → closed | 标题：y | 链接：https://github.com/onyx-space/firstmate/pull/38')
rc=$(drain_then_ack "$home" "$state" "$home/AGENTS.md" "$home/.config/wire/config.json" s4)
echo "ack rc: $rc"; cat "$d/s4.ack.err"
check "S4 closed note archived" "$([ -f "$state/inbox/handled/$id.note" ] && echo 1 || echo 0)" "not handled"
check "S4 no dispatch for a non-merge" "$([ "$(inbox_count "$home")" = 0 ] && echo 1 || echo 0)" "delivery happened"

say "S5 adversarial: title names a served repo, the note's own token names another"
d=$(new_case s5); home="$d/home"; state="$d/state"
printf '{\n "github onyx-space/pi": { "endpoint": "server", "lane": "pi-maintenance-lane" },\n "github onyx-space/wire": { "endpoint": "server", "lane": "wire-maintenance-lane" }\n}\n' > "$home/code/origmd/ref/lanes.json"
write_config "$home" "$(full_config "{\"pi-maintenance-lane\":\"$(session_for "$home" pi)\",\"wire-maintenance-lane\":\"$(session_for "$home" wire)\"}")"
printf '# no lanes\n' > "$home/AGENTS.md"
printf 'wire route for pi (note token):\n'; HOME="$home" "$REAL_WIRE" route --repo github/onyx-space/pi
printf 'wire route for wire (title only):\n'; HOME="$home" "$REAL_WIRE" route --repo github/onyx-space/wire
id=$(queue_relay "$home" "$state" '【中继变更】github onyx-space/pi#5：open → merged | 标题：follow-up to onyx-space/wire#124 | 链接：https://github.com/onyx-space/wire/pull/124')
rc=$(drain_then_ack "$home" "$state" "$home/AGENTS.md" "$home/.config/wire/config.json" s5)
echo "ack rc: $rc"; cat "$d/s5.ack.err"
check "S5 note dispatched" "$([ -f "$state/inbox/dispatched/$id.note" ] && echo 1 || echo 0)" "not dispatched"
check "S5 routed to the own-token lane (pi)" "$(has_payload "$home" 'address=pi-maintenance-lane' && echo 1 || echo 0)" "pi lane got nothing"
check "S5 the title-mention lane (wire) got nothing" "$(has_payload "$home" 'address=wire-maintenance-lane' && echo 0 || echo 1)" "wire lane received a payload"

say "S6 fail-closed: a dispatch that cannot be made because wire is absent"
d=$(new_case s6); home="$d/home"; state="$d/state"
lane_checkout "$d/lane-firstmate" "https://github.com/onyx-space/firstmate.git"
printf -- '- Long-lived maintenance lanes: `firstmate-maintenance-lane` (pane `w9:pZ`, `%s`); captain-owned.\n' "$d/lane-firstmate" > "$home/AGENTS.md"
printf '{}\n' > "$home/code/origmd/ref/lanes.json"
write_config "$home" "$(full_config "{\"firstmate-maintenance-lane\":\"$(session_for "$home" firstmate)\"}")"
id=$(queue_relay "$home" "$state" "$MERGE_FM")
# A PATH with the harness fakebin and standard tools, but no wire on it.
restricted="/usr/bin:/bin:/usr/sbin:/sbin:$d/fakebin"
rc=$(drain_then_ack "$home" "$state" "$home/AGENTS.md" "$home/.config/wire/config.json" s6 "$restricted")
echo "ack rc: $rc"; echo "-- ack stderr --"; cat "$d/s6.ack.err"
check "S6 ack refused (wire absent)" "$([ "$rc" != 0 ] && [ "$rc" != drain-failed ] && [ "$rc" != no-ack-required ] && echo 1 || echo 0)" "rc=$rc"
check "S6 note still queued in state/inbox/" "$([ -f "$state/inbox/$id.note" ] && echo 1 || echo 0)" "note not in inbox/"
check "S6 wake row still queued" "$(awk -F '\t' 'NF>=5{f=1} END{exit !f}' "$state/.wake-queue" && echo 1 || echo 0)" "row consumed"

say "S7 adversarial: a real wire send that cannot write the mailbox"
d=$(new_case s7); home="$d/home"; state="$d/state"
printf '{ "github onyx-space/firstmate": { "endpoint": "server", "lane": "firstmate-maintenance-lane" } }\n' > "$home/code/origmd/ref/lanes.json"
write_config "$home" "$(full_config "{\"firstmate-maintenance-lane\":\"$(session_for "$home" firstmate)\"}")"
printf '# no lanes\n' > "$home/AGENTS.md"
id=$(queue_relay "$home" "$state" "$MERGE_FM")
mkdir -p "$home/.config/wire/inbox"; chmod 500 "$home/.config/wire/inbox"
# Prove the real send cannot write the mailbox in this state, and that wire's
# own exit code still reports success.
probe_rc=0
HOME="$home" "$REAL_WIRE" send --to h --session firstmate-maintenance-lane --text probe \
  > "$d/s7.probe.out" 2>&1 || probe_rc=$?
echo "probe wire-send rc: $probe_rc"
sed -n '1,8p' "$d/s7.probe.out"
rc=$(drain_then_ack "$home" "$state" "$home/AGENTS.md" "$home/.config/wire/config.json" s7)
chmod 700 "$home/.config/wire/inbox"
echo "ack rc: $rc"; echo "-- ack stderr --"; cat "$d/s7.ack.err"
note_survives=$([ -f "$state/inbox/$id.note" ] && echo 1 || echo 0)
dispatched=$([ -e "$state/inbox/dispatched/$id.note" ] && echo 1 || echo 0)
echo "note still in inbox: $note_survives ; recorded dispatched despite delivery failure: $dispatched"
check "S7 refused send keeps note + row retryable" "$([ "$rc" != 0 ] && [ "$note_survives" = 1 ] && echo 1 || echo 0)" "ack rc=$rc note_survives=$note_survives dispatched=$dispatched"

say "SUMMARY pass=$PASS fail=$FAILN"
