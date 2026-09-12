#!/usr/bin/env bash
# Live tmux drive of the guards this change must not weaken:
#   a) `fm-control <id> exit` still refuses a structurally gone endpoint
#      (that refusal is the other half of the deadlock and is unchanged).
#   b) `fm-spawn --relaunch` still refuses an endpoint with a live agent, so a
#      rebuild can never become a duplicate agent onto a live worktree.
#
# usage: guards-driver.sh <engine-repo-root> <evidence-dir>
set -uo pipefail

ENGINE=$1
EVID=$2
D=$(mktemp -d /tmp/fm-guards.XXXXXX)
ID=live5
REAL_TMUX=$(command -v tmux)
SOCKET=fmguards-$$
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
Guards.

## Firstmate spec
Reply READY.
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
cp "$D/fmhome/state/$ID.meta" "$D/out/meta.before"

env HOME="$D/home" PI_CODING_AGENT_DIR="$D/piagent" \
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SES"

run() { env -u TMUX PATH="$D/shim:$PATH" FM_HOME="$D/fmhome" HOME="$D/home" \
        FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 "$@"; }
state_of() { run bash -c '. "'"$ENGINE"'/bin/fm-backend.sh"; fm_backend_agent_state tmux '"$1"''; }

out=$EVID/live-guards-$(basename "$ENGINE").txt
{
  echo "engine: $ENGINE   (real tmux on a private socket)"
  echo
  echo "### a) fm-control exit on a structurally gone endpoint"
  echo "    recorded endpoint: $SES:fm-$ID  (no such window)"
  echo "    agent-state: $(state_of "$SES:fm-$ID")"
  run "$ENGINE/bin/fm-control.sh" "$ID" exit > "$D/out/exit.out" 2>&1
  echo "    exit=$?"
  sed 's/^/    /' "$D/out/exit.out"
  echo
  echo "### b) fm-spawn --relaunch with a LIVE agent at the recorded endpoint"
  # A real pi process occupies the recorded endpoint, started directly in the
  # pane (a real agent process, no model call).
  env HOME="$D/home" PI_CODING_AGENT_DIR="$D/piagent" \
    "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SES:" -n "fm-$ID" -c "$D/wt" \
    "$(command -v pi)"
  sleep 3
  echo "    agent-state: $(state_of "$SES:fm-$ID")"
  run "$ENGINE/bin/fm-spawn.sh" "$ID" --relaunch > "$D/out/spawn.out" 2>&1
  echo "    exit=$?"
  sed 's/^/    /' "$D/out/spawn.out"
  echo
  echo "    window inventory after both refusals:"
  "$REAL_TMUX" -L "$SOCKET" list-windows -a -F '#{session_name}:#{window_name} id=#{window_id} cmd=#{pane_current_command}' | sed 's/^/      /'
  echo "    record unchanged: $(diff -q "$D/out/meta.before" "$D/fmhome/state/$ID.meta" >/dev/null && echo yes || echo NO)"
} > "$out" 2>&1
cat "$out"

"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
echo "sandbox: $D"
