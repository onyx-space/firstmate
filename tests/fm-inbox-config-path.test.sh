#!/usr/bin/env bash
# tests/fm-inbox-config-path.test.sh - the captain-inbox collector follows its
# tool's own name: with no FM_WIRE_CONFIG in the environment, bin/fm-inbox.sh
# resolves $XDG_CONFIG_HOME/olink/config.json, or ~/.config/olink/config.json
# when XDG_CONFIG_HOME is unset, and never a literal wire path. It also works
# while ~/.config/wire is only the transitional symlink onto ~/.config/olink.
# The variable NAME stays FM_WIRE_CONFIG (renaming it would reach call sites
# this change deliberately does not touch); this suite pins the default, not
# the name.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INBOX="$ROOT/bin/fm-inbox.sh"

URL=https://github.com/onyx-space/firstmate.git
TOKEN='github onyx-space/firstmate'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# A home whose machine file declares lane-a at <home>/lane, that lane's checkout
# serving $URL, and fake wire/olink tools at the process boundary: `olink route`
# reports no lane-map entry so the collector falls back to the machine file -
# the code path that reads $FM_WIRE_CONFIG - while `wire send` reports the
# mailbox present. Every call lands in <home>/wire.log.
make_home() {  # <home>
  local home=$1
  mkdir -p "$home/fakebin"
  git init -q "$home/lane" || fail "$home: could not create the lane's checkout"
  git -C "$home/lane" remote add origin "$URL" || fail "$home: could not set the lane's origin"
  cat > "$home/AGENTS.md" <<EOF
- Long-lived maintenance lanes: \`lane-a\` (pane \`w1:p2\`, \`$home/lane\`); captain-owned, not torn down unless stopped.
EOF
  cat > "$home/fakebin/wire" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$home/wire.log"
case "\${1:-}" in
  route)
    printf 'route:\n  repo: unknown\n  served: no\n  lane: none\n  reason: no-entry\n  detail: no lane map entry\n'
    ;;
  send)
    printf 'delivery:\n  delivery_id: 00000000-0000-0000-0000-000000000000\n  recipient: endpoint\n  mailbox: present\n  doorbell: rung\n  queued: no\n'
    ;;
esac
exit 0
SH
  chmod +x "$home/fakebin/wire"
  ln -sf wire "$home/fakebin/olink"
}

# Queue a merge note for $TOKEN under <state> through the public CLI and echo
# the note id it printed.
queue_merge() {  # <state>
  local state=$1 out
  out=$(FM_STATE_OVERRIDE="$state" "$INBOX" note --source relay \
    "【中继变更】${TOKEN}#37：open → merged | 标题：x | 链接：https://github.com/onyx-space/firstmate/pull/37") || return 1
  printf '%s\n' "$out" | sed -n 's/^queued //p'
}

# Run the real notification acknowledgement with <home> as HOME, <xdg> as
# XDG_CONFIG_HOME and <explicit> as FM_WIRE_CONFIG. A literal "-" leaves the
# variable unset. Echoes the acknowledgement's combined output.
run_dispatch() {  # <home> <xdg|-> <explicit|-> <state> <id>
  local home=$1 xdg=$2 explicit=$3 state=$4 id=$5
  (
    if [ "$xdg" = - ]; then unset XDG_CONFIG_HOME; else export XDG_CONFIG_HOME="$xdg"; fi
    if [ "$explicit" = - ]; then unset FM_WIRE_CONFIG; else export FM_WIRE_CONFIG="$explicit"; fi
    HOME="$home" PATH="$home/fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
      FM_MACHINE_FILE="$home/AGENTS.md" \
      "$INBOX" drain --ack-notifications "$id"
  ) 2>&1
}

# Assert the acknowledgement dispatched <id> to lane-a under <endpoint>.
check_dispatched() {  # <home> <state> <id> <endpoint> <label>
  local home=$1 state=$2 id=$3 endpoint=$4 label=$5
  [ -f "$state/inbox/dispatched/$id.note" ] \
    || fail "$label: the note was not recorded as dispatched"
  grep -F -- "send --to $endpoint --session lane-a" "$home/wire.log" >/dev/null \
    || fail "$label: the endpoint key was not read from the resolved config: $(cat "$home/wire.log")"
}

# 1. olink config present, no wire path at all: the olink file is the default.
home="$tmp/a"; state="$home/state"
make_home "$home"
mkdir -p "$home/.config/olink"
printf '{"endpoints":{"h":{"sshAlias":"h","sessions":{"lane-a":"/x/a.jsonl"}}}}\n' > "$home/.config/olink/config.json"
id=$(queue_merge "$state") || fail 'case 1: queueing the merge note failed'
out=$(run_dispatch "$home" - - "$state" "$id") || fail "case 1: dispatch failed: $out"
printf '%s\n' "$out" | grep -F "dispatched $id lane-a" >/dev/null || fail "case 1: no dispatch: $out"
check_dispatched "$home" "$state" "$id" h 'case 1'

# 2. today's layout: ~/.config/wire is the transitional symlink onto olink.
home="$tmp/b"; state="$home/state"
make_home "$home"
mkdir -p "$home/.config/olink"
printf '{"endpoints":{"h":{"sshAlias":"h","sessions":{"lane-a":"/x/b.jsonl"}}}}\n' > "$home/.config/olink/config.json"
ln -s "$home/.config/olink" "$home/.config/wire"
id=$(queue_merge "$state") || fail 'case 2: queueing the merge note failed'
out=$(run_dispatch "$home" - - "$state" "$id") || fail "case 2: dispatch failed: $out"
check_dispatched "$home" "$state" "$id" h 'case 2'

# 3. XDG_CONFIG_HOME is honoured.
home="$tmp/c"; state="$home/state"
make_home "$home"
mkdir -p "$home/xdg/olink"
printf '{"endpoints":{"m":{"sshAlias":"m","sessions":{"lane-a":"/x/c.jsonl"}}}}\n' > "$home/xdg/olink/config.json"
id=$(queue_merge "$state") || fail 'case 3: queueing the merge note failed'
out=$(run_dispatch "$home" "$home/xdg" - "$state" "$id") || fail "case 3: dispatch failed: $out"
check_dispatched "$home" "$state" "$id" m 'case 3'

# 4. an explicit FM_WIRE_CONFIG wins over the default, and the name is unchanged.
home="$tmp/d"; state="$home/state"
make_home "$home"
mkdir -p "$home/.config/olink"
printf '{"endpoints":{"w":{"sshAlias":"w","sessions":{"lane-a":"/x/d-default.jsonl"}}}}\n' > "$home/.config/olink/config.json"
printf '{"endpoints":{"d":{"sshAlias":"d","sessions":{"lane-a":"/x/d-explicit.jsonl"}}}}\n' > "$home/explicit.json"
id=$(queue_merge "$state") || fail 'case 4: queueing the merge note failed'
out=$(run_dispatch "$home" - "$home/explicit.json" "$state" "$id") || fail "case 4: dispatch failed: $out"
check_dispatched "$home" "$state" "$id" d 'case 4'

# 5. no literal wire config path survives in the script. This is the one
# source-content assertion here, kept because the intent explicitly requires
# proof that the old wire default is gone; the four cases above carry the
# behavioral evidence for the resolved default.
if grep -q 'config/wire' "$ROOT/bin/fm-inbox.sh"; then
  fail 'a literal wire config path survives in bin/fm-inbox.sh'
fi

printf 'ok\n'