#!/usr/bin/env bash
# Live drive of the REAL bin/fm-supervise-daemon.sh to exercise the "done:"
# half of task_delivery_recorded: a lane whose newest status line reads done:,
# with a wedge marker recorded BEFORE the line appeared, must be dropped by
# housekeeping instead of escalating.
set -u
ROOT=/home/onyx/.no-mistakes/worktrees/42774a4b8442/01M4DGGZNVKY8YC11MDN8CNAVA
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
command -v tmux >/dev/null || { echo "skip: no tmux"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-live-done-$$"
STATE=$(mktemp -d /tmp/fm-live-done.XXXXXX)
FAKEBIN=$(mktemp -d /tmp/fm-live-done-fakebin.XXXXXX)
SHIM=$(mktemp -d /tmp/fm-live-done-shim.XXXXXX)
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
"$REAL_TMUX" -L "$SOCKET" new-window -d -n fm-doneonly -t sess
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

printf 'window=sess:fm-doneonly\nkind=ship\n' > "$STATE/doneonly.meta"
printf 'done: shipped\n' > "$STATE/doneonly.status"
echo $(( $(date +%s) - 500 )) > "$STATE/.subsuper-stale-doneonly"

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

FM_STATE_OVERRIDE="$STATE" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append stale "sess:fm-doneonly" "stale: sess:fm-doneonly"' _ "$ROOT"

sleep 15
kill "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true; DAEMON_PID=

echo "===== live away-mode done: lane observation ====="
echo "doneonly stale marker present: $([ -e "$STATE/.subsuper-stale-doneonly" ] && echo yes || echo no)"
echo "wedge escalations for doneonly: [$(grep -F 'doneonly' "$STATE/.subsuper-escalations" 2>/dev/null || true)]"
echo "all escalations buffer: [$(cat "$STATE/.subsuper-escalations" 2>/dev/null || true)]"
