#!/usr/bin/env bash
set -u
W=/home/onyx/.no-mistakes/worktrees/42774a4b8442/01M4DGGZNVKY8YC11MDN8CNAVA
. "$W/tests/wake-helpers.sh"
. "$W/bin/fm-classify-lib.sh"
WATCH="$W/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-manual-delivered)
seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1"); size=$(size_of "$1"); ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident" ;;
    *) stat -c '%s:%Y' "$1" 2>/dev/null ;;
  esac
}
hash_text() { printf '%s' "$1" | cksum | tr -d ' \n'; }
drive() {
  local name=$1 metaextra=$2 statusline=$3 dir state fakebin out capture window key pane_hash sig pid
  dir=$(make_case "manual-$name"); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; window="test:fm-$name"
  printf 'idle building output' > "$capture"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/$name.meta"
  [ -z "$metaextra" ] || printf '%s\n' "$metaextra" >> "$state/$name.meta"
  printf '%s\n' "$statusline" > "$state/$name.status"
  sig=$(seen_sig "$state/$name.status"); printf '%s' "$sig" > "$state/.seen-${name}_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working - source: run-step - ci running'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>"$dir/watch.err" &
  pid=$!; sleep 10; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  echo "================ CASE: $name ================"
  echo "meta:"; sed 's/^/    /' "$state/$name.meta"
  echo "status: $statusline"
  echo "watcher stdout (wake reasons): [$(cat "$out")]"
  echo "wake queue present: $([ -s "$state/.wake-queue" ] && echo yes || echo no)"
  echo "wedge escalations file: [$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)]"
  echo "stale-since file present: $([ -s "$state/.stale-since-$key" ] && echo yes || echo no)"
  echo "-- triage log lines for this window --"
  grep -F "$window" "$state/.watch-triage.log" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo "-- triage log total lines --"; wc -l < "$state/.watch-triage.log" 2>/dev/null | sed 's/^/    /'
  echo
}
drive delivered "pr=https://github.com/onyx-space/firstmate/pull/999" "working: still compiling"
drive undelivered "" "working: still compiling"
