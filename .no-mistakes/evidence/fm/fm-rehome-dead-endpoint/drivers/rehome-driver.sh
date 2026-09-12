#!/usr/bin/env bash
# Live tmux drive of the user intent: a task whose recorded endpoint is
# structurally gone ("missing") is restarted by `fm-control <id> relaunch`
# itself, which rebuilds the endpoint and republishes the record - no hand
# editing of state/<id>.meta.
#
# usage: rehome-driver.sh <engine-repo-root> <evidence-dir>
set -uo pipefail

ENGINE=$1
EVID=$2
D=$(mktemp -d /tmp/fm-rehome.XXXXXX)
ID=live1
REAL_TMUX=$(command -v tmux)
SOCKET=fmrehome-$$
SES=firstmate
RECORDED_SES=firstmate-old
mkdir -p "$D/fmhome/state" "$D/fmhome/data/$ID" "$D/fmhome/config" "$D/home" "$D/shim" "$D/piagent" "$D/out"

cat > "$D/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$D/shim/tmux"

cp ~/.pi/agent/models.json ~/.pi/agent/models-store.json ~/.pi/agent/auth.json "$D/piagent/"
cat > "$D/piagent/settings.json" <<'JSON'
{
  "tuiMode": "fullscreen",
  "theme": "dark",
  "defaultProvider": "deepseek",
  "defaultModel": "deepseek/deepseek-flash",
  "enabledModels": ["deepseek/deepseek-flash"],
  "packages": []
}
JSON

PROJ=$D/proj
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
printf 'fixture\n' > "$PROJ/README.md"
git -C "$PROJ" -c user.name='Live Test' -c user.email='live@example.invalid' add README.md
git -C "$PROJ" -c user.name='Live Test' -c user.email='live@example.invalid' commit -qm init
git -C "$PROJ" worktree add -q -b "task-$ID" "$D/wt"
printf 'uncommitted work that must survive\n' > "$D/wt/wip.txt"

cat > "$D/fmhome/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Confirm a task whose endpoint vanished can be restarted without hand editing.

## Firstmate spec
Reply with the single word READY, then wait. Do not use any tools.
EOF

# The record names a window in a session that no longer holds it: the
# recovery-grade `missing` read from the report. Nothing else is recorded.
cat > "$D/fmhome/state/$ID.meta" <<EOF
window=$RECORDED_SES:fm-$ID
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
cp "$D/fmhome/state/$ID.meta" "$D/out/meta.before"

env HOME="$D/home" PI_CODING_AGENT_DIR="$D/piagent" \
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SES"
env HOME="$D/home" PI_CODING_AGENT_DIR="$D/piagent" \
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$RECORDED_SES"

run() { env -u TMUX PATH="$D/shim:$PATH" FM_HOME="$D/fmhome" HOME="$D/home" \
        FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 "$@"; }
state_of() { run bash -c '. "'"$ENGINE"'/bin/fm-backend.sh"; fm_backend_agent_state tmux '"$1"''; }
windows() { "$REAL_TMUX" -L "$SOCKET" list-windows -a -F '#{session_name}:#{window_name}'; }

branch=$(basename "$ENGINE")
out=$EVID/live-rehome-$branch.txt
{
  echo "############################################################"
  echo "# engine: $ENGINE"
  echo "# real tmux server: $REAL_TMUX -L $SOCKET (private socket, real panes)"
  echo "# isolated home: FM_HOME=$D/fmhome   HOME=$D/home"
  echo "############################################################"
  echo
  echo "### 1. the reported state: the task's endpoint is entirely gone"
  echo "\$ tmux list-windows -a"
  windows | sed 's/^/    /'
  echo "\$ recorded endpoint: $RECORDED_SES:fm-$ID"
  printf "    agent-state of the recorded endpoint: %s\n" "$(state_of "$RECORDED_SES:fm-$ID")"
  echo "    (the window does not exist anywhere; nothing to stop and nothing to relaunch into)"
  echo
  echo "### 2. restart it through the supported path"
  echo "\$ bin/fm-control.sh $ID relaunch --note \"...\""
  run "$ENGINE/bin/fm-control.sh" "$ID" relaunch --note "the agent exited and its pane went with it" > "$D/out/relaunch.out" 2>&1
  rc=$?
  sed 's/^/    /' "$D/out/relaunch.out"
  echo "    exit=$rc"
  echo
  echo "### 3. what the restart left behind"
  echo "\$ tmux list-windows -a  (with pane state)"
  "$REAL_TMUX" -L "$SOCKET" list-windows -a -F '#{session_name}:#{window_name} id=#{window_id} cmd=#{pane_current_command} cwd=#{pane_current_path}' | sed 's/^/    /'
  echo "    agent-state of the rebuilt endpoint: $(state_of "$SES:fm-$ID")"
  echo
  echo "\$ state/$ID.meta before -> after (the record, not a hand edit)"
  diff <(sed 's/^/    - /' "$D/out/meta.before") <(sed 's/^/    + /' "$D/fmhome/state/$ID.meta") | grep -v '^ *[0-9]' || true
  echo
  echo "\$ state/$ID.control-relaunch (transaction journal)"
  sed 's/^/    /' "$D/fmhome/state/$ID.control-relaunch"
  echo
  echo "\$ git status in the recorded worktree (uncommitted work preserved)"
  git -C "$D/wt" status --short | sed 's/^/    /'
  echo "    wip.txt: $(cat "$D/wt/wip.txt")"
  echo
  echo "### 4. what a live agent is doing in the rebuilt endpoint"
  sleep 2
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SES:fm-$ID" -S -20 | tail -8 | sed 's/^/    /'
} > "$out" 2>&1
cat "$out"

run "$ENGINE/bin/fm-control.sh" "$ID" exit >/dev/null 2>&1 || true
"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
echo "sandbox: $D"
