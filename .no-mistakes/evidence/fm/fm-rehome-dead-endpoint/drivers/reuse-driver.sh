#!/usr/bin/env bash
# Live tmux drive of the reuse boundary: an endpoint that still exists and has
# no agent must be ADOPTED (same window, no second endpoint), never rebuilt.
#
# usage: reuse-driver.sh <engine-repo-root> <evidence-dir>
set -uo pipefail

ENGINE=$1
EVID=$2
D=$(mktemp -d /tmp/fm-reuse.XXXXXX)
ID=live6
REAL_TMUX=$(command -v tmux)
SOCKET=fmreuse-$$
SES=firstmate
mkdir -p "$D/fmhome/state" "$D/fmhome/data/$ID" "$D/fmhome/config" "$D/home" "$D/shim" "$D/piagent" "$D/out"

cat > "$D/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$D/shim/tmux"

cp ~/.pi/agent/models.json ~/.pi/agent/models-store.json ~/.pi/agent/auth.json "$D/piagent/"
printf '{"tuiMode":"fullscreen","defaultProvider":"deepseek","defaultModel":"deepseek/deepseek-flash","enabledModels":["deepseek/deepseek-flash"],"packages":[]}\n' > "$D/piagent/settings.json"

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
Confirm a surviving endpoint is reused.

## Firstmate spec
Reply with the single word READY, then wait. Do not use any tools.
EOF

cat > "$D/fmhome/state/$ID.meta" <<EOF
window=$SES:fm-$ID
endpoint_task_id=$ID
worktree=$D/wt
project=$PROJ
harness=pi
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$ID
model=default
effort=default
EOF

env HOME="$D/home" PI_CODING_AGENT_DIR="$D/piagent" \
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SES"
# The recorded endpoint survives, agent-free, in the recorded worktree.
env HOME="$D/home" PI_CODING_AGENT_DIR="$D/piagent" \
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SES:" -n "fm-$ID" -c "$D/wt"
before=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SES:fm-$ID" '#{window_id}')

run() { env -u TMUX PATH="$D/shim:$PATH" FM_HOME="$D/fmhome" HOME="$D/home" \
        FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 "$@"; }
state_of() { run bash -c '. "'"$ENGINE"'/bin/fm-backend.sh"; fm_backend_agent_state tmux '"$1"''; }

out=$EVID/live-reuse-$(basename "$ENGINE").txt
{
  echo "engine: $ENGINE   (real tmux on a private socket)"
  echo
  echo "### an existing endpoint with no agent (the reuse case)"
  echo "    recorded endpoint: $SES:fm-$ID  id=$before"
  echo "    agent-state before: $(state_of "$SES:fm-$ID")"
  echo
  echo "\$ bin/fm-control.sh $ID relaunch --note \"...\""
  run "$ENGINE/bin/fm-control.sh" "$ID" relaunch --note "reuse the surviving endpoint" > "$D/out/relaunch.out" 2>&1
  echo "    exit=$?"
  sed 's/^/    /' "$D/out/relaunch.out"
  after=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SES:fm-$ID" '#{window_id}')
  echo
  echo "    window id before=$before after=$after"
  echo "    windows named fm-$ID: $("$REAL_TMUX" -L "$SOCKET" list-windows -a -F '#{session_name}:#{window_name}' | grep -c -x ".*:fm-$ID")"
  echo "    agent-state after: $(state_of "$SES:fm-$ID")"
  echo "    record window: $(grep '^window=' "$D/fmhome/state/$ID.meta")"
} > "$out" 2>&1
cat "$out"

run "$ENGINE/bin/fm-control.sh" "$ID" exit >/dev/null 2>&1 || true
"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
echo "sandbox: $D"
