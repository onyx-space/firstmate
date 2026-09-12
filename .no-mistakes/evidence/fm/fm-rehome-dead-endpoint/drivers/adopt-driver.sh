#!/usr/bin/env bash
# Live tmux drive: an abort on a relaunch that ADOPTS an existing, agent-free
# endpoint must never reclaim that endpoint. This is the dangerous direction of
# the abort-cleanup change.
#
# usage: adopt-driver.sh <engine-repo-root> <evidence-dir>
set -uo pipefail

ENGINE=$1
EVID=$2
D=$(mktemp -d /tmp/fm-adopt.XXXXXX)
ID=live3
REAL_TMUX=$(command -v tmux)
SOCKET=fmadopt-$$
SES=firstmate
mkdir -p "$D/fmhome/state" "$D/fmhome/data/$ID" "$D/fmhome/config" "$D/home" "$D/shim" "$D/piagent" "$D/out"

cat > "$D/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$D/shim/tmux"

PROJ=$D/proj
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
printf 'fixture\n' > "$PROJ/README.md"
git -C "$PROJ" -c user.name='Live Test' -c user.email='live@example.invalid' add README.md
git -C "$PROJ" -c user.name='Live Test' -c user.email='live@example.invalid' commit -qm init
git -C "$PROJ" worktree add -q -b "task-$ID" "$D/wt"

cat > "$D/fmhome/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Confirm an adopted endpoint survives an aborted relaunch.

## Firstmate spec
Reply READY and stop.
EOF

{
  echo "window=$SES:fm-$ID"
  echo "endpoint_task_id=$ID"
  echo "worktree=$D/wt"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "tasktmp=/tmp/fm-$ID"
  echo "model=default"
  echo "effort=default"
} > "$D/fmhome/state/$ID.meta"

mkdir -p "$D/home/.claude.json"

env HOME="$D/home" PI_CODING_AGENT_DIR="$D/piagent" \
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SES"
# The recorded endpoint already exists, agent-free, sitting in the recorded
# worktree: the "adopt, do not rebuild" case.
env HOME="$D/home" PI_CODING_AGENT_DIR="$D/piagent" \
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SES:" -n "fm-$ID" -c "$D/wt"
before_id=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SES:fm-$ID" '#{window_id}')

run() { env -u TMUX PATH="$D/shim:$PATH" FM_HOME="$D/fmhome" HOME="$D/home" \
        FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 "$@"; }

echo "engine: $ENGINE"
echo "### pre-state: adopted endpoint $SES:fm-$ID id=$before_id, agent-state=$(run bash -c '. "'"$ENGINE"'/bin/fm-backend.sh"; fm_backend_agent_state tmux '"$SES"':fm-'"$ID"'')"
echo "### abort at the pre-publication trust refusal"
run "$ENGINE/bin/fm-control.sh" "$ID" relaunch --note "aborts after adopting the endpoint" > "$D/out/adopt-abort.out" 2>&1
echo "exit=$?"
cat "$D/out/adopt-abort.out"
echo "window inventory:"
"$REAL_TMUX" -L "$SOCKET" list-windows -a -F '#{session_name}:#{window_name} id=#{window_id} cmd=#{pane_current_command} cwd=#{pane_current_path}'
if "$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SES:fm-$ID" '#{window_id}' >/dev/null 2>&1; then
  echo "RESULT: the adopted endpoint survived (id=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SES:fm-$ID" '#{window_id}'))"
else
  echo "RESULT: the adopted endpoint was reclaimed (BUG)"
fi
echo "record still names: $(grep '^window=' "$D/fmhome/state/$ID.meta")"

mkdir -p "$EVID"
cat "$D/out/adopt-abort.out" > "$EVID/adopt-abort-$(basename "$ENGINE").txt"

"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
echo "sandbox: $D"
