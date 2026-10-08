#!/usr/bin/env bash
# Live drive of the REAL bin/fm-supervise-daemon.sh (away-mode supervisor) on a
# private tmux socket. Two lanes, both newest-status "working:" and both with a
# pre-aged away-mode wedge marker: the delivered one (meta carries pr=) must be
# absorbed with no escalation; the undelivered one must still escalate.
set -u
ROOT=/home/onyx/.no-mistakes/worktrees/42774a4b8442/01M4DGGZNVKY8YC11MDN8CNAVA
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
command -v tmux >/dev/null || { echo "skip: no tmux"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-live-daemon-$$"
STATE=$(mktemp -d /tmp/fm-live-daemon.XXXXXX)
FAKEBIN=$(mktemp -d /tmp/fm-live-fakebin.XXXXXX)
SHIM=$(mktemp -d /tmp/fm-live-shim.XXXXXX)
DAEMON_PID=
cleanup() {
  [ -n "${DAEMON_PID:-}" ] && { kill "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; }
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$STATE" "$FAKEBIN" "$SHIM"
}
trap cleanup EXIT

date '+%s' > "$STATE/.afk"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s sess -x 200 -y 50
"$REAL_TMUX" -L "$SOCKET" rename-window -t sess:0 sup
SUPERVISOR_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t sess:sup '#{pane_id}')
"$REAL_TMUX" -L "$SOCKET" new-window -d -n fm-delivered -t sess
"$REAL_TMUX" -L "$SOCKET" new-window -d -n fm-undelivered -t sess
sleep 1

cat > "$SHIM/tmux" <<SHIM
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$SHIM/tmux"
cat > "$FAKEBIN/fm-crew-state.sh" <<'CS'
#!/usr/bin/env bash
printf 'state: working · source: run-step · ci running\n'
CS
chmod +x "$FAKEBIN/fm-crew-state.sh"
cat > "$SHIM/rec" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_WEDGE_ALARM_LOG:-/dev/null}"
REC
chmod +x "$SHIM/rec"
export FM_WEDGE_ALARM_LOG="$STATE/wedge-alarm.log"

# Delivered lane: newest status still working:, metadata carries the PR.
printf 'window=sess:fm-delivered\nkind=ship\npr=https://github.com/onyx-space/firstmate/pull/999\n' > "$STATE/delivered.meta"
printf 'working: still compiling\n' > "$STATE/delivered.status"
# Undelivered control: same shape, no delivery on record.
printf 'window=sess:fm-undelivered\nkind=ship\n' > "$STATE/undelivered.meta"
printf 'working: still compiling\n' > "$STATE/undelivered.status"

# Pre-age an away-mode wedge marker for each lane, as one recorded before the
# delivery existed / before the freeze was noticed.
echo $(( $(date +%s) - 500 )) > "$STATE/.subsuper-stale-delivered"
echo $(( $(date +%s) - 500 )) > "$STATE/.subsuper-stale-undelivered"

PATH="$SHIM:$FAKEBIN:$PATH" \
FM_STATE_OVERRIDE="$STATE" \
FM_SUPERVISOR_TARGET="$SUPERVISOR_PANE" \
FM_SUPERVISOR_BACKEND=tmux \
FM_ESCALATE_BATCH_SECS=0 \
FM_HOUSEKEEPING_TICK=1 \
FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
FM_STALE_ESCALATE_SECS=2 \
FM_INJECT_CONFIRM_SLEEP=0.3 FM_INJECT_CONFIRM_RETRIES=2 \
FM_WEDGE_ALARM_EXEC="$SHIM/rec" \
nohup "$DAEMON" >"$STATE/daemon.out" 2>"$STATE/daemon.err" &
DAEMON_PID=$!
for i in $(seq 1 40); do [ -f "$STATE/.supervise-daemon.pid" ] && break; sleep 0.2; done
[ -f "$STATE/.supervise-daemon.pid" ] || { echo "daemon did not start"; cat "$STATE/daemon.err"; exit 1; }

# Hand the daemon the same stale wakes the away-mode watcher would enqueue.
FM_STATE_OVERRIDE="$STATE" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append stale "sess:fm-delivered" "stale: sess:fm-delivered"; fm_wake_append stale "sess:fm-undelivered" "stale: sess:fm-undelivered"' _ "$ROOT"

sleep 15
kill "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; DAEMON_PID=

echo "===== live away-mode daemon observation ====="
echo "delivered stale marker present:   $([ -e "$STATE/.subsuper-stale-delivered" ] && echo yes || echo no)"
echo "undelivered stale marker present: $([ -e "$STATE/.subsuper-stale-undelivered" ] && echo yes || echo no)"
echo "escalations buffer: [$(cat "$STATE/.subsuper-escalations" 2>/dev/null || true)]"
echo "wedge alarm log:    [$(cat "$STATE/wedge-alarm.log" 2>/dev/null || true)]"
echo "-- daemon log (self-handle / wake lines) --"
grep -E "wake:|self-handle" "$STATE/.supervise-daemon.log" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
