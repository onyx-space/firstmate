#!/usr/bin/env bash
# Live tmux drive: an abort between "endpoint created" and "record published"
# must reclaim the endpoint it created, and the retry must not be blocked by an
# orphan of the abandoned attempt.
#
# usage: abort-driver.sh <engine-repo-root> <evidence-dir>
set -uo pipefail

ENGINE=$1
EVID=$2
D=$(mktemp -d /tmp/fm-abort.XXXXXX)
ID=live2
REAL_TMUX=$(command -v tmux)
SOCKET=fmabort-$$
SES=firstmate
RECORDED_SES=firstmate-other
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

cat > "$D/fmhome/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Confirm a failed rehome leaves no orphan endpoint behind.

## Firstmate spec
Reply READY and stop.
EOF

# The record names an endpoint whose SESSION is alive but whose window is gone:
# a recovery-grade `missing` read. The creation path below resolves a different
# container session ("firstmate"), which is how an orphan ends up outside the
# recorded endpoint.
{
  echo "window=$RECORDED_SES:fm-$ID"
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

# A trust store that is a directory makes the launch refuse AFTER the
# replacement endpoint exists and BEFORE the replacement record is published.
mkdir -p "$D/home/.claude.json"

env HOME="$D/home" PI_CODING_AGENT_DIR="$D/piagent" \
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SES"
env HOME="$D/home" PI_CODING_AGENT_DIR="$D/piagent" \
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$RECORDED_SES"

run() { env -u TMUX PATH="$D/shim:$PATH" FM_HOME="$D/fmhome" HOME="$D/home" \
        FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 "$@"; }
windows() { "$REAL_TMUX" -L "$SOCKET" list-windows -a -F '#{session_name}:#{window_name}' | grep -x ".*:fm-$ID" || true; }

echo "engine: $ENGINE"
echo "### pre-state"
run bash -c '. "'"$ENGINE"'/bin/fm-backend.sh"; printf "recorded endpoint agent-state="; fm_backend_agent_state tmux '"$RECORDED_SES"':fm-'"$ID"'; printf "\n"'
echo "windows named fm-$ID: [$(windows | tr '\n' ' ')]"

echo "### attempt 1: abort between endpoint creation and publication"
run "$ENGINE/bin/fm-control.sh" "$ID" relaunch --note "first attempt, aborts at launch" > "$D/out/attempt1.out" 2>&1
echo "exit=$?"
cat "$D/out/attempt1.out"
echo "windows named fm-$ID after abort: [$(windows | tr '\n' ' ')]"
echo "record still names: $(grep '^window=' "$D/fmhome/state/$ID.meta")"

echo "### attempt 2: retry now that the trust store is valid"
rm -rf "$D/home/.claude.json"
run "$ENGINE/bin/fm-control.sh" "$ID" relaunch --harness pi --note "retry after the aborted attempt" > "$D/out/attempt2.out" 2>&1
echo "exit=$?"
cat "$D/out/attempt2.out"
echo "windows named fm-$ID after retry: [$(windows | tr '\n' ' ')]"
echo "record now names: $(grep '^window=' "$D/fmhome/state/$ID.meta")"
"$REAL_TMUX" -L "$SOCKET" list-windows -a -F 'created endpoint #{session_name}:#{window_name} id=#{window_id} cmd=#{pane_current_command} cwd=#{pane_current_path}'

mkdir -p "$EVID"
{
  echo "=== engine: $ENGINE"
  echo "=== pre-state: recorded $RECORDED_SES:fm-$ID is structurally gone"
  echo "=== attempt 1 output (exit above)"; cat "$D/out/attempt1.out"
  echo "=== attempt 2 output"; cat "$D/out/attempt2.out"
} > "$EVID/abort-$(basename "$ENGINE").txt" 2>/dev/null || true

# tear the whole thing down
run "$ENGINE/bin/fm-control.sh" "$ID" exit >/dev/null 2>&1 || true
"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
echo "sandbox: $D"
