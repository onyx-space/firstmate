#!/usr/bin/env bash
# tests/fm-wake-drain-inbox-ack.test.sh - a note's SOURCE decides when that note
# is archived, and only the source does.
#
# The incident this pins: a board counting unacknowledged notes kept climbing
# because an acknowledged wake row closed the row while the note it announced
# stayed in state/inbox/ until somebody remembered a second, separate
# acknowledgement. Coupling the two is only safe once a note can say who wrote
# it, because archiving the captain's own words on a row acknowledgement would
# swallow them silently. So: a notification-class note archives with its row, a
# captain-authored note never does, and the automatic archival is always named on
# the acknowledgement's own output.
#
# This is a portable regression driving the real bin/fm-inbox.sh and
# bin/fm-wake-drain.sh over real note records; `wire` is faked only at the process
# boundary, so wire's own map read is not what runs here.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
INBOX="$ROOT/bin/fm-inbox.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-inbox-ack-tests)

# Queue one real note through the public CLI as <source>, or with no --source at
# all when <source> is "-", and echo the note id the CLI printed.
queue_note_now() { # <state> <source|-> <body>
  local state=$1 source=$2 body=$3 out
  if [ "$source" = - ]; then
    out=$(FM_STATE_OVERRIDE="$state" "$INBOX" note "$body") || return 1
  else
    out=$(FM_STATE_OVERRIDE="$state" "$INBOX" note --source "$source" "$body") || return 1
  fi
  printf '%s\n' "$out" | sed -n 's/^queued //p'
}

# Drain the queue, then run the acknowledgement command that drain printed. Echoes
# the path of the acknowledgement's own stderr, which is where an automatic
# archival must be visible.
drain_then_ack() { # <state> <tag>
  local state=$1 tag=$2 dir seq gen
  dir=$(dirname "$state")
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/$tag.drain.out" 2> "$dir/$tag.drain.err" \
    || fail "$tag: the drain failed: $(cat "$dir/$tag.drain.err")"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$dir/$tag.drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$dir/$tag.drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] \
    || fail "$tag: the drain printed no acknowledgement command: $(cat "$dir/$tag.drain.err")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    > "$dir/$tag.ack.out" 2> "$dir/$tag.ack.err" \
    || fail "$tag: the acknowledgement failed: $(cat "$dir/$tag.ack.err")"
  # A note that survives must survive because of its source, not because the
  # acknowledgement was a no-op: if the row is still queued the negative
  # assertions below prove nothing.
  if awk -F '\t' 'NF >= 5 { found = 1 } END { exit !found }' "$state/.wake-queue"; then
    fail "$tag: the acknowledgement consumed no wake row, so the note's survival proves nothing"
  fi
  printf '%s\n' "$dir/$tag.ack.err"
}

# Install the fake `wire` into <dir>/fakebin. `route` answers out of <dir>/routes -
# one "<lane map key>\t<lane>\t<endpoint key>" line per served repository, a
# "<lane map key>\t!<reason>" line for a repository wire answers served:no about,
# and any other key is wire's silent no-entry - so a test owns wire's answer while
# fm-inbox's use of it is what runs. `send` reports the mailbox fact the way real
# wire does - `mailbox: present` unless <dir>/send-mailbox names another value -
# and exits 0 either way, so a test can drive a delivery wire accepted but could
# not make present. Every call lands in <dir>/wire.log.
write_fake_wire() { # <dir>
  local dir=$1
  : > "$dir/routes"
  cat > "$dir/fakebin/wire" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$dir/wire.log"
if [ "\${1:-}" = route ]; then
  repo= ; key= ; lane= ; endpoint=
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --repo) repo=\${2:-}; shift 2; continue ;;
    esac
    shift
  done
  while IFS=\$(printf '\t') read -r key lane endpoint; do
    [ "\$key" = "\$repo" ] || continue
    case "\$lane" in
      '!'*)
        printf 'route:\n  repo: %s\n  served: no\n  lane: none\n  reason: %s\n  detail: %s\n' \\
          "\$repo" "\${lane#!}" "\${lane#!}"
        exit 0
        ;;
    esac
    printf 'route:\n  repo: %s\n  served: yes\n  lane: %s\n  endpoint: %s\n  key: %s\n  registration: checked\n' \\
      "\$repo" "\$lane" "\$endpoint" "\$key"
    exit 0
  done < "$dir/routes"
  printf 'route:\n  repo: %s\n  served: no\n  lane: none\n  reason: no-entry\n  detail: no lane map entry for %s\n' \\
    "\$repo" "\$repo"
  exit 0
fi
if [ "\${1:-}" = send ]; then
  mailbox=present
  [ -f "$dir/send-mailbox" ] && mailbox=\$(cat "$dir/send-mailbox")
  printf 'delivery:\n  delivery_id: 00000000-0000-0000-0000-000000000000\n  recipient: endpoint\n  mailbox: %s\n  doorbell: rung\n  queued: no\n' "\$mailbox"
  exit 0
fi
exit 0
SH
  chmod +x "$dir/fakebin/wire"
}

# A wire.log with no `send` line is the negative assertion for "this merge was
# not dispatched": fm-inbox still asks wire for `route` first, so the mere
# presence of the log proves nothing.
assert_no_send() { # <dir> <message>
  if grep -q '^send ' "$1/wire.log" 2>/dev/null; then
    fail "$2: $(cat "$1/wire.log")"
  fi
}

# The lane-dispatch fixture: a machine file declaring one lane, that lane's own
# checkout carrying <repo> as its origin, a wire config registering the lane name
# under this endpoint's key, and a fake wire whose routing table is empty so the
# machine file is what answers. Echoes the case directory; callers read
# "$dir/wire.log" and the inbox destinations under "$dir/state/inbox/".
make_lane_case() { # <name> <lane> <repo>
  local name=$1 lane=$2 repo=$3 dir
  dir=$(make_case "$name")
  mkdir -p "$dir/lane"
  git init -q "$dir/lane" || fail "$name: could not create the lane's checkout"
  git -C "$dir/lane" remote add origin "$repo" || fail "$name: could not set the lane's origin"
  cat > "$dir/machine.md" <<EOF
- Long-lived maintenance lanes: \`$lane\` (pane \`w1:p2\`, \`$dir/lane\`); captain-owned, not torn down unless stopped.
EOF
  printf '{"endpoints":{"h":{"sshAlias":"h","sessions":{"%s":"/x/one.jsonl"}},"m":{"sshAlias":"m"}}}\n' \
    "$lane" > "$dir/wire-config.json"
  write_fake_wire "$dir"
  printf '%s\n' "$dir"
}

# The same drain-then-acknowledge drive as drain_then_ack, with the machine file,
# wire config, routing table and fake wire visible to both the drain and the
# acknowledgement. The machine file, routing table and HOME default to the plain
# fixture, so a case can point at either source or at the endpoint's real shape
# (a symlinked machine file, a ~ directory).
drain_then_ack_with_lanes() { # <dir> <state> <tag> [machine-file] [home]
  local dir=$1 state=$2 tag=$3 machine=${4:-$1/machine.md} home=${5:-$HOME} seq gen
  PATH="$dir/fakebin:$PATH" HOME="$home" FM_STATE_OVERRIDE="$state" FM_MACHINE_FILE="$machine" \
    FM_WIRE_CONFIG="$dir/wire-config.json" "$DRAIN" > "$dir/$tag.drain.out" 2> "$dir/$tag.drain.err" \
    || fail "$tag: the drain failed: $(cat "$dir/$tag.drain.err")"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$dir/$tag.drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$dir/$tag.drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] \
    || fail "$tag: the drain printed no acknowledgement command: $(cat "$dir/$tag.drain.err")"
  PATH="$dir/fakebin:$PATH" HOME="$home" FM_STATE_OVERRIDE="$state" FM_MACHINE_FILE="$machine" \
    FM_WIRE_CONFIG="$dir/wire-config.json" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    > "$dir/$tag.ack.out" 2> "$dir/$tag.ack.err" \
    || fail "$tag: the acknowledgement failed: $(cat "$dir/$tag.ack.err")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "$tag: the acknowledgement consumed no wake row, so the note's fate proves nothing"
  printf '%s\n' "$dir/$tag.ack.err"
}

test_merge_wake_for_a_lane_served_repo_is_dispatched_to_the_lane() {
  local dir state id ackerr
  dir=$(make_lane_case lane-dispatch lane-a https://github.com/onyx-space/firstmate.git)
  state="$dir/state"
  id=$(queue_note_now "$state" relay \
    '【中继变更】github onyx-space/firstmate#37：open → merged | 标题：x | 链接：https://github.com/onyx-space/firstmate/pull/37') \
    || fail "queueing the merge note failed"

  ackerr=$(drain_then_ack_with_lanes "$dir" "$state" merge) || exit 1

  [ -f "$dir/wire.log" ] \
    || fail "a merge in a lane-served repository was never dispatched to the lane"
  grep -F -- '--to h --session lane-a' "$dir/wire.log" >/dev/null \
    || fail "the dispatch did not address the lane by name under this endpoint's key: $(cat "$dir/wire.log")"
  grep -F 'onyx-space/firstmate' "$dir/wire.log" >/dev/null \
    || fail "the dispatched line did not name the repository: $(cat "$dir/wire.log")"
  grep -F 'merged' "$dir/wire.log" >/dev/null \
    || fail "the dispatched line did not name the merge: $(cat "$dir/wire.log")"
  [ -f "$state/inbox/dispatched/$id.note" ] \
    || fail "the dispatched note was not recorded as dispatched"
  [ ! -e "$state/inbox/handled/$id.note" ] \
    || fail "the dispatched note was archived as handled instead"
  grep -F 'dispatched' "$ackerr" >/dev/null \
    || fail "the acknowledgement did not name the dispatch: $(cat "$ackerr")"
  pass "a merge wake for a lane-served repository reaches that lane and is recorded as dispatched"
}

test_a_lane_whose_checkout_is_another_repo_does_not_take_the_wake() {
  local dir state id
  dir=$(make_lane_case lane-other-repo lane-a https://github.com/onyx-space/wire.git)
  state="$dir/state"
  id=$(queue_note_now "$state" relay \
    '【中继变更】github onyx-space/firstmate#37：open → merged | 标题：x | 链接：https://github.com/onyx-space/firstmate/pull/37') \
    || fail "queueing the merge note failed"

  drain_then_ack_with_lanes "$dir" "$state" other-repo >/dev/null || exit 1

  assert_no_send "$dir" "a lane checking out a different repository took the wake"
  [ -f "$state/inbox/handled/$id.note" ] \
    || fail "a merge with no lane for its repository was not archived as before"
  [ ! -d "$state/inbox/dispatched" ] \
    || fail "a merge with no lane for its repository left a dispatched record"
  pass "a lane's own checkout decides: a different repository takes the archive path"
}

test_a_repo_with_no_lane_at_all_archives_as_before() {
  local dir state id
  dir=$(make_case no-lane-at-all)
  write_fake_wire "$dir"
  state="$dir/state"
  printf '# no lanes\n' > "$dir/machine.md"
  printf '{"endpoints":{"h":{"sshAlias":"h"}}}\n' > "$dir/wire-config.json"
  id=$(queue_note_now "$state" relay \
    '【中继变更】gitea admin/origmd#9：open → merged | 标题：z | 链接：http://10.0.99.5:3000/admin/origmd/pulls/9') \
    || fail "queueing the merge note failed"

  drain_then_ack_with_lanes "$dir" "$state" no-lane >/dev/null || exit 1

  [ -f "$state/inbox/handled/$id.note" ] \
    || fail "a merge on a machine declaring no lane was not archived as before"
  assert_no_send "$dir" "a machine with no lane dispatched to wire"
  pass "a machine declaring no lane keeps the pre-existing archive path"
}

test_a_non_merge_relay_note_archives_without_dispatch() {
  local dir state id
  dir=$(make_lane_case lane-non-merge lane-a https://github.com/onyx-space/firstmate.git)
  state="$dir/state"
  id=$(queue_note_now "$state" relay \
    '【中继变更】github onyx-space/firstmate#38：open → closed | 标题：y | 链接：https://github.com/onyx-space/firstmate/pull/38') \
    || fail "queueing the closed note failed"

  drain_then_ack_with_lanes "$dir" "$state" non-merge >/dev/null || exit 1

  [ -f "$state/inbox/handled/$id.note" ] \
    || fail "an ordinary relay notification was not archived as before"
  [ ! -e "$dir/wire.log" ] \
    || fail "an ordinary relay notification was dispatched to a lane: $(cat "$dir/wire.log")"
  pass "only a merge reaches a lane; an ordinary relay notification keeps the archive path"
}

# The endpoint's default machine file is a symlink to the injected copy, so the
# lane list must be read through the link the way ~/AGENTS.md ships.
test_a_symlinked_machine_file_is_read() {
  local dir state id
  dir=$(make_lane_case lane-symlink lane-a https://github.com/onyx-space/firstmate.git)
  ln -s "$dir/machine.md" "$dir/AGENTS.md"
  state="$dir/state"
  id=$(queue_note_now "$state" relay \
    '【中继变更】github onyx-space/firstmate#37：open → merged | 标题：x | 链接：https://github.com/onyx-space/firstmate/pull/37') \
    || fail "queueing the merge note failed"

  drain_then_ack_with_lanes "$dir" "$state" symlink "$dir/AGENTS.md" >/dev/null || exit 1

  [ -f "$state/inbox/dispatched/$id.note" ] \
    || fail "a symlinked machine file, the endpoint's default shape, declared no lane"
  pass "the endpoint's symlinked machine file is read"
}

# The fleet writes lane directories as ~/code/..., so the declared directory has
# to resolve against HOME before the lane's own checkout is read.
test_a_tilde_lane_directory_is_resolved() {
  local dir state id home
  dir=$(make_lane_case lane-tilde lane-a https://github.com/onyx-space/firstmate.git)
  state="$dir/state"
  home="$dir/home"
  mkdir -p "$home"
  mv "$dir/lane" "$home/lane"
  cat > "$dir/machine.md" <<'EOF'
- Long-lived maintenance lanes: `lane-a` (pane `w1:p2`, `~/lane`); captain-owned, not torn down unless stopped.
EOF
  id=$(queue_note_now "$state" relay \
    '【中继变更】github onyx-space/firstmate#37：open → merged | 标题：x | 链接：https://github.com/onyx-space/firstmate/pull/37') \
    || fail "queueing the merge note failed"

  drain_then_ack_with_lanes "$dir" "$state" tilde "$dir/machine.md" "$home" >/dev/null || exit 1

  [ -f "$state/inbox/dispatched/$id.note" ] \
    || fail "a lane declared with ~ did not resolve to its own checkout"
  pass "a lane directory declared with ~ is resolved against HOME"
}

test_an_unregistered_lane_fails_the_acknowledgement_instead_of_losing_the_wake() {
  local dir state id seq gen
  dir=$(make_lane_case lane-unregistered lane-a https://github.com/onyx-space/firstmate.git)
  state="$dir/state"
  # The lane is declared and its checkout serves the repository, but wire's own
  # config does not register the name, so this endpoint's key cannot be known.
  printf '{"endpoints":{"h":{"sshAlias":"h"}}}\n' > "$dir/wire-config.json"
  id=$(queue_note_now "$state" relay \
    '【中继变更】github onyx-space/firstmate#37：open → merged | 标题：x | 链接：https://github.com/onyx-space/firstmate/pull/37') \
    || fail "queueing the merge note failed"

  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_MACHINE_FILE="$dir/machine.md" \
    FM_WIRE_CONFIG="$dir/wire-config.json" "$DRAIN" > "$dir/unregistered.drain.out" 2> "$dir/unregistered.drain.err" \
    || fail "the drain failed: $(cat "$dir/unregistered.drain.err")"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$dir/unregistered.drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$dir/unregistered.drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] || fail "the drain printed no acknowledgement command"

  if PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_MACHINE_FILE="$dir/machine.md" \
    FM_WIRE_CONFIG="$dir/wire-config.json" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    > "$dir/unregistered.ack.out" 2> "$dir/unregistered.ack.err"; then
    fail "an acknowledgement was accepted although its lane dispatch was refused"
  fi
  grep -F 'lane-a' "$dir/unregistered.ack.err" >/dev/null \
    || fail "the refusal did not name the lane it could not reach: $(cat "$dir/unregistered.ack.err")"
  [ -f "$state/inbox/$id.note" ] \
    || fail "a refused dispatch lost the note instead of leaving it retryable"
  awk -F '\t' 'NF >= 5 { found = 1 } END { exit !found }' "$state/.wake-queue" \
    || fail "a refused dispatch consumed the wake row it could not deliver"
  pass "a lane that serves the repository but cannot be reached keeps the note and its row retryable"
}

# The real wire exits 0 while reporting `mailbox: unreadable` when the write to
# the recipient's own inbox failed, so an exit status alone is not delivery. A
# send that reports anything but `mailbox: present` must leave the note and its
# wake row retryable instead of recording a dispatch the lane never received.
test_a_dispatch_wire_did_not_make_present_stays_retryable() {
  local dir state id seq gen
  dir=$(make_lane_case lane-mailbox-unreadable lane-a https://github.com/onyx-space/firstmate.git)
  state="$dir/state"
  printf 'unreadable\n' > "$dir/send-mailbox"
  id=$(queue_note_now "$state" relay \
    '【中继变更】github onyx-space/firstmate#37：open → merged | 标题：x | 链接：https://github.com/onyx-space/firstmate/pull/37') \
    || fail "queueing the merge note failed"

  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_MACHINE_FILE="$dir/machine.md" \
    FM_WIRE_CONFIG="$dir/wire-config.json" "$DRAIN" > "$dir/unreadable.drain.out" 2> "$dir/unreadable.drain.err" \
    || fail "the drain failed: $(cat "$dir/unreadable.drain.err")"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$dir/unreadable.drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$dir/unreadable.drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] || fail "the drain printed no acknowledgement command"

  if PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_MACHINE_FILE="$dir/machine.md" \
    FM_WIRE_CONFIG="$dir/wire-config.json" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    > "$dir/unreadable.ack.out" 2> "$dir/unreadable.ack.err"; then
    fail "an acknowledgement was accepted although wire reported the mailbox unreadable"
  fi
  grep -F 'lane-a' "$dir/unreadable.ack.err" >/dev/null \
    || fail "the refusal did not name the lane whose delivery failed: $(cat "$dir/unreadable.ack.err")"
  grep -F 'unreadable' "$dir/unreadable.ack.err" >/dev/null \
    || fail "the refusal did not carry wire's own mailbox fact: $(cat "$dir/unreadable.ack.err")"
  [ -f "$state/inbox/$id.note" ] \
    || fail "a delivery wire did not make present lost the note instead of leaving it retryable"
  [ ! -e "$state/inbox/dispatched/$id.note" ] \
    || fail "a delivery wire did not make present was still recorded as dispatched"
  awk -F '\t' 'NF >= 5 { found = 1 } END { exit !found }' "$state/.wake-queue" \
    || fail "a delivery wire did not make present consumed the wake row it did not deliver"
  pass "a send wire did not make present leaves the note and its wake row retryable"
}

# A routing table that names a lane dispatches with no lane declared in the
# machine file at all, so wire's own answer is the primary source.
test_wire_route_dispatches_a_merge_with_no_machine_file_lane() {
  local dir state id
  dir=$(make_case joined-lane-map)
  write_fake_wire "$dir"
  state="$dir/state"
  printf '# no lanes declared here\n' > "$dir/machine.md"
  printf '{"endpoints":{"h":{"sshAlias":"h","sessions":{"lane-b":"/x/two.jsonl"}}}}\n' > "$dir/wire-config.json"
  printf 'github onyx-space/firstmate\tlane-b\th\n' > "$dir/routes"
  id=$(queue_note_now "$state" relay \
    '【中继变更】github onyx-space/firstmate#39：open → merged | 标题：x | 链接：https://github.com/onyx-space/firstmate/pull/39') \
    || fail "queueing the merge note failed"

  drain_then_ack_with_lanes "$dir" "$state" joined >/dev/null || exit 1

  grep -F -- 'route --repo github onyx-space/firstmate' "$dir/wire.log" >/dev/null \
    || fail "wire was not asked about the note's own repository: $(cat "$dir/wire.log")"
  grep -F -- '--to h --session lane-b' "$dir/wire.log" >/dev/null \
    || fail "wire's routed lane did not receive the merge: $(cat "$dir/wire.log")"
  grep -F 'onyx-space/firstmate' "$dir/wire.log" >/dev/null \
    || fail "the dispatch did not name the repository: $(cat "$dir/wire.log")"
  [ -f "$state/inbox/dispatched/$id.note" ] \
    || fail "the dispatched note was not recorded as dispatched"
  pass "wire's routed lane dispatches a merge with no machine-file lane to parse"
}

# wire answers for a repository no lane on this endpoint serves; fm-inbox must
# keep the pre-existing archive path rather than guess a lane.
test_a_repository_wire_does_not_serve_keeps_the_archive_path() {
  local dir state id
  dir=$(make_case wire-not-served)
  write_fake_wire "$dir"
  state="$dir/state"
  printf '# no lanes declared here\n' > "$dir/machine.md"
  printf '{"endpoints":{"h":{"sshAlias":"h"}}}\n' > "$dir/wire-config.json"
  id=$(queue_note_now "$state" relay \
    '【中继变更】github onyx-space/firstmate#39：open → merged | 标题：x | 链接：https://github.com/onyx-space/firstmate/pull/39') \
    || fail "queueing the merge note failed"

  drain_then_ack_with_lanes "$dir" "$state" not-served >/dev/null || exit 1

  assert_no_send "$dir" "a repository wire does not serve here was dispatched anyway"
  [ -f "$state/inbox/handled/$id.note" ] \
    || fail "a repository wire does not serve did not take the archive path"
  pass "wire's not-served answer keeps the archive path"
}

# A map entry naming another machine is wire's own definitive "this endpoint
# serves no lane"; the machine-file fallback must not second-guess it into a
# local dispatch the map explicitly placed elsewhere.
test_a_repository_the_map_places_elsewhere_is_not_dispatched_here() {
  local dir state id
  dir=$(make_lane_case lane-remote-entry lane-a https://github.com/onyx-space/firstmate.git)
  state="$dir/state"
  printf 'github onyx-space/firstmate\t!lane-not-registered\n' > "$dir/routes"
  id=$(queue_note_now "$state" relay \
    '【中继变更】github onyx-space/firstmate#37：open → merged | 标题：x | 链接：https://github.com/onyx-space/firstmate/pull/37') \
    || fail "queueing the merge note failed"

  drain_then_ack_with_lanes "$dir" "$state" remote-entry >/dev/null || exit 1

  assert_no_send "$dir" "a map entry naming another machine was dispatched from here anyway"
  [ -f "$state/inbox/handled/$id.note" ] \
    || fail "a repository the map places elsewhere did not take the archive path"
  [ ! -d "$state/inbox/dispatched" ] \
    || fail "a repository the map places elsewhere left a dispatched record"
  pass "a map entry naming another machine is not second-guessed by the machine file"
}

# The regression: a merge note whose free-form title names a lane-served
# repository is routed by the repository its own leading token reports, never by
# the name that merely appears in the text.
test_a_merge_is_routed_by_its_own_token_not_a_title_mention() {
  local dir state id
  dir=$(make_case title-mention)
  write_fake_wire "$dir"
  state="$dir/state"
  printf '# no lanes declared here\n' > "$dir/machine.md"
  printf '{"endpoints":{"h":{"sshAlias":"h","sessions":{"wire-lane":"/x/wire.jsonl"}}}}\n' > "$dir/wire-config.json"
  printf 'github onyx-space/wire\twire-lane\th\n' > "$dir/routes"
  id=$(queue_note_now "$state" relay \
    '【中继变更】github onyx-space/pi#5：open → merged | 标题：follow-up to onyx-space/wire#124 | 链接：https://github.com/onyx-space/wire/pull/124') \
    || fail "queueing the merge note failed"

  drain_then_ack_with_lanes "$dir" "$state" title-mention >/dev/null || exit 1

  grep -F -- 'route --repo github onyx-space/pi' "$dir/wire.log" >/dev/null \
    || fail "the merge was not routed by the note's own repository: $(cat "$dir/wire.log")"
  assert_no_send "$dir" "a merge whose title named a lane-served repository was dispatched to that lane"
  [ -f "$state/inbox/handled/$id.note" ] \
    || fail "a merge for an unserved repository did not take the archive path"
  pass "a merge is routed by its own token, not a repository named in its title"
}

test_captain_note_survives_its_acknowledged_wake_row() {
  local dir state id ackerr
  dir=$(make_case captain-note)
  state="$dir/state"
  id=$(queue_note_now "$state" - 'captain wrote this out of band') \
    || fail "queueing the captain's note failed"
  grep -qx 'source=text' "$state/inbox/$id.note" \
    || fail "a note queued with no --source did not record the captain's default source"

  ackerr=$(drain_then_ack "$state" captain) || exit 1

  [ -f "$state/inbox/$id.note" ] \
    || fail "acknowledging the wake row archived the captain's own note"
  [ ! -e "$state/inbox/handled/$id.note" ] \
    || fail "the captain's own note reached handled/ without an explicit --ack"
  if grep -F 'archived' "$ackerr" >/dev/null; then
    fail "the acknowledgement reported archiving a captain-authored note: $(cat "$ackerr")"
  fi
  pass "a captain-authored note stays in state/inbox/ when its wake row is acknowledged"
}

test_notification_note_is_archived_with_its_wake_row() {
  local dir state id ackerr
  dir=$(make_case notification-note)
  state="$dir/state"
  id=$(queue_note_now "$state" relay 'relay: a watched PR merged') \
    || fail "queueing the notification note failed"
  grep -qx 'source=relay' "$state/inbox/$id.note" \
    || fail "the notification note did not record its source"

  ackerr=$(drain_then_ack "$state" notification) || exit 1

  [ -f "$state/inbox/handled/$id.note" ] \
    || fail "a notification note did not follow its acknowledged wake row into handled/"
  [ ! -e "$state/inbox/$id.note" ] \
    || fail "a notification note stayed in state/inbox/ after its wake row was acknowledged"
  grep -F 'archived 1 notification note(s)' "$ackerr" >/dev/null \
    || fail "the acknowledgement did not name the automatic archival: $(cat "$ackerr")"
  grep -F "$id" "$ackerr" >/dev/null \
    || fail "the archival line did not name the archived note id: $(cat "$ackerr")"
  pass "a notification note is archived with its wake row and the archival is named"
}

test_mixed_batch_archives_only_the_notification() {
  local dir state captain_id relay_id ackerr
  dir=$(make_case mixed-batch)
  state="$dir/state"
  captain_id=$(queue_note_now "$state" - 'captain wrote this out of band') \
    || fail "queueing the captain's note failed"
  relay_id=$(queue_note_now "$state" relay 'relay: upstream left a review comment') \
    || fail "queueing the notification note failed"

  ackerr=$(drain_then_ack "$state" mixed) || exit 1

  [ -f "$state/inbox/handled/$relay_id.note" ] \
    || fail "the notification note was not archived"
  [ -f "$state/inbox/$captain_id.note" ] \
    || fail "the captain's note was archived alongside the notification"
  [ ! -e "$state/inbox/handled/$captain_id.note" ] \
    || fail "the captain's note reached handled/ in a mixed batch"
  grep -F "$relay_id" "$ackerr" >/dev/null \
    || fail "the archival line did not name the archived notification: $(cat "$ackerr")"
  if grep -F "$captain_id" "$ackerr" >/dev/null; then
    fail "the archival line named a captain-authored note as archived: $(cat "$ackerr")"
  fi
  pass "one acknowledged batch archives its notification note and leaves the captain's"
}

test_explicit_ack_still_archives_every_source() {
  local dir state captain_id relay_id
  dir=$(make_case explicit-ack)
  state="$dir/state"
  captain_id=$(queue_note_now "$state" - 'captain wrote this out of band') \
    || fail "queueing the captain's note failed"
  relay_id=$(queue_note_now "$state" relay 'relay: a watched PR merged') \
    || fail "queueing the notification note failed"

  FM_STATE_OVERRIDE="$state" "$INBOX" drain --ack "$captain_id" "$relay_id" >/dev/null \
    || fail "an explicit --ack failed"

  [ -f "$state/inbox/handled/$captain_id.note" ] \
    || fail "an explicit --ack no longer archives a captain-authored note"
  [ -f "$state/inbox/handled/$relay_id.note" ] \
    || fail "an explicit --ack no longer archives a notification note"
  pass "an explicit drain --ack still archives a note of either source"
}

test_a_source_that_could_break_the_record_header_is_refused() {
  local dir state out err
  dir=$(make_case bad-source)
  state="$dir/state"
  err="$dir/bad-source.err"

  if FM_STATE_OVERRIDE="$state" "$INBOX" note --source 'relay
injected=value' 'body' >"$dir/bad-source.out" 2>"$err"; then
    fail "a source carrying a newline was accepted"
  fi
  if [ -e "$state/inbox" ] && [ -n "$(find "$state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null)" ]; then
    fail "a refused source still queued a note"
  fi
  pass "a source that could inject a record header line is refused and queues nothing"
}

test_legacy_record_is_not_classified_by_its_body() {
  local dir state id ackerr
  dir=$(make_case legacy-record)
  state="$dir/state"
  id=$(queue_note_now "$state" - 'captain wrote this out of band') \
    || fail "queueing the captain's note failed"

  # A record queued before the source field existed carries only id/at in its
  # header; the body after the separator is the captain's text and must never
  # decide the record's class.
  {
    printf 'id=%s\n' "$id"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '--\n'
    printf 'source=relay\n'
    printf 'this line is the captain speaking, not a notification\n'
  } > "$state/inbox/$id.note"

  ackerr=$(drain_then_ack "$state" legacy) || exit 1

  [ -f "$state/inbox/$id.note" ] \
    || fail "a header-less legacy record was archived from a body line"
  [ ! -e "$state/inbox/handled/$id.note" ] \
    || fail "a header-less legacy record reached handled/ from a body line"
  if grep -F 'archived' "$ackerr" >/dev/null; then
    fail "the acknowledgement archived a legacy record from its body: $(cat "$ackerr")"
  fi
  pass "a legacy record without a header source is not classified by its body"
}

# The relay producer queues notifications with `fm-inbox.sh note <text>` and no
# `--source`. Until that producer is updated (another lane's work), every note it
# queues must keep counting as the captain's and must never be auto-archived.
test_producer_argv_shape_stays_captain_authored() {
  local dir state id ackerr
  dir=$(make_case producer-argv)
  state="$dir/state"

  id=$(FM_STATE_OVERRIDE="$state" "$INBOX" note 'relay: a watched PR merged' \
    | sed -n 's/^queued //p')
  [ -n "$id" ] || fail "the producer's argv shape did not print a note id"

  ackerr=$(drain_then_ack "$state" producer) || exit 1

  [ -f "$state/inbox/$id.note" ] \
    || fail "a note queued with no --source was archived with its wake row"
  [ ! -e "$state/inbox/handled/$id.note" ] \
    || fail "a note queued with no --source reached handled/ with its wake row"
  if grep -F 'archived' "$ackerr" >/dev/null; then
    fail "the acknowledgement archived a note queued with no --source: $(cat "$ackerr")"
  fi
  pass "a note queued through the producer's argv shape counts as captain-authored"
}

test_captain_note_survives_its_acknowledged_wake_row
test_notification_note_is_archived_with_its_wake_row
test_wire_route_dispatches_a_merge_with_no_machine_file_lane
test_a_repository_wire_does_not_serve_keeps_the_archive_path
test_a_repository_the_map_places_elsewhere_is_not_dispatched_here
test_a_merge_is_routed_by_its_own_token_not_a_title_mention
test_merge_wake_for_a_lane_served_repo_is_dispatched_to_the_lane
test_a_lane_whose_checkout_is_another_repo_does_not_take_the_wake
test_a_repo_with_no_lane_at_all_archives_as_before
test_a_non_merge_relay_note_archives_without_dispatch
test_a_symlinked_machine_file_is_read
test_a_tilde_lane_directory_is_resolved
test_an_unregistered_lane_fails_the_acknowledgement_instead_of_losing_the_wake
test_a_dispatch_wire_did_not_make_present_stays_retryable
test_mixed_batch_archives_only_the_notification
test_explicit_ack_still_archives_every_source
test_a_source_that_could_break_the_record_header_is_refused
test_legacy_record_is_not_classified_by_its_body
test_producer_argv_shape_stays_captain_authored
