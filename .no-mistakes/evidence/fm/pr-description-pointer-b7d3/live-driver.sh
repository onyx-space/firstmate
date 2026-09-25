#!/usr/bin/env bash
# Live driver for the fm lane-dispatch change. Uses the REAL `wire` binary with
# an isolated HOME (its own machine key, lane map, and wire config), so wire's
# own map read and send report run for real. herdrPath points at a nonexistent
# binary so a successful mailbox write never rings a real pane.
set -u

ROOT=/home/onyx/.no-mistakes/worktrees/42774a4b8442/01M3BZZCVN8XKJ97FZ3Z3SV5QE
DRAIN="$ROOT/bin/fm-wake-drain.sh"
INBOX="$ROOT/bin/fm-inbox.sh"
EVID=/home/onyx/.no-mistakes/evidence/01M3BZZCVN8XKJ97FZ3Z3SV5QE
OUT=/tmp/fm-live-out
mkdir -p "$EVID" "$OUT"

# shellcheck source=../../tests/wake-helpers.sh
TMP_ROOT=$(mktemp -d /tmp/fm-live-cases.XXXXXX)
. "$ROOT/tests/wake-helpers.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# make_home <dir> [lanes-json] -- isolated HOME with machine key + wire config
make_home() { # <dir> <lanes-json-file>
  local dir=$1 lanes=$2
  mkdir -p "$dir/home/.config/wire" "$dir/home/.pi/agent/data" "$dir/home/code/origmd/ref"
  echo server > "$dir/home/.pi/agent/data/origmd-machine"
  cp "$lanes" "$dir/home/code/origmd/ref/lanes.json"
  cat > "$dir/home/.config/wire/config.json" <<'EOF'
{"endpoints":{"h":{"sshAlias":"h","herdrPath":"/nonexistent/herdr","firstmateCwdPrefixes":["/home/onyx/code/firstmate"],"sessions":{"firstmate-maintenance-lane":"/home/onyx/.pi/agent/sessions/--home-onyx-code-lanes-firstmate--/fake.jsonl"}}}}
EOF
  chmod 600 "$dir/home/.config/wire/config.json"
  mkdir -p "$dir/fmhome/state"
}

# queue <state> <body> -> id
queue() { # <state> <body>
  local state=$1 body=$2 out
  out=$(FM_STATE_OVERRIDE="$state" "$INBOX" note --source relay "$body") || return 1
  printf '%s\n' "$out" | sed -n 's/^queued //p'
}

# run drain + ack; sets RV_ACK_RC, RV_DRAIN_ERR, RV_ACK_OUT, RV_ACK_ERR
run_drain_ack() { # <dir> <state> <tag>
  local dir=$1 state=$2 tag=$3 seq gen
  PATH="$dir/fakebin:$PATH" HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_HOME="$dir/fmhome" \
    "$DRAIN" > "$OUT/$tag.drain.out" 2> "$OUT/$tag.drain.err" \
    || fail "$tag: the drain failed: $(cat "$OUT/$tag.drain.err")"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$OUT/$tag.drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$OUT/$tag.drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] || fail "$tag: the drain printed no acknowledgement command"
  RV_ACK_RC=0
  PATH="$dir/fakebin:$PATH" HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_HOME="$dir/fmhome" \
    "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    > "$OUT/$tag.ack.out" 2> "$OUT/$tag.ack.err" || RV_ACK_RC=$?
}
