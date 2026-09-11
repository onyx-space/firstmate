#!/usr/bin/env bash
# Live driver for the fm-teardown superseded-slot-claim change.
#
# Topology per case (all real, isolated under a fresh mktemp root):
#   * a real git project with a real treehouse.toml pinned to an isolated root
#   * a real `treehouse get` that stamps the pool's own owner_started_at
#   * a real tmux server (isolated via TMUX_TMPDIR) whose panes run an
#     agent-named process the product's own tmux classifier reads as alive
#   * real firstmate task records in a real FM_HOME
#   * the real bin/fm-teardown.sh executable and the real treehouse return
#
# Usage: fm-live-superseded.sh <mode> <outdir> [teardown-root]
#   modes: release reverse no-owner-record both-predate secondmate unlanded
#          unowned-process
set -u

MODE=${1:?mode}
OUT=${2:?outdir}
ROOT=${3:-${FM_LIVE_ROOT:-/Users/onyx/.no-mistakes/worktrees/9573b29b9316/01M297S7MSZN3AR2EDM8EG6YHT}}
TEARDOWN="$ROOT/bin/fm-teardown.sh"
mkdir -p "$OUT"

CASE=$(cd "$(mktemp -d /tmp/fm-live-case-XXXXXX)" && pwd -P)

cleanup() {
  [ -n "${TMUXSOCKDIR:-}" ] && TMUX_TMPDIR="$TMUXSOCKDIR" tmux kill-server 2>/dev/null
  [ -n "${OWNER_PID:-}" ] && kill "$OWNER_PID" 2>/dev/null
  pkill -f "$CASE" 2>/dev/null
  if [ "${FM_LIVE_KEEP:-}" = 1 ]; then echo "kept case at $CASE"; else rm -rf "$CASE"; fi
}
trap cleanup EXIT

mkdir -p "$CASE/project" "$CASE/fakebin" "$CASE/home/state" "$CASE/home/data" \
  "$CASE/home/config" "$CASE/tmuxsock"
# An agent-named process: the product's tmux classifier reads a pane whose
# process name / argv0 is `pi` as a live agent.
ln -s /bin/sleep "$CASE/fakebin/pi"

cd "$CASE/project"
git init -q -b main .
git config user.name test
git config user.email test@example.invalid
echo "fixture" > a.txt
printf 'max_trees = 2\nroot = "%s"\n' "$CASE" > treehouse.toml
git add -A
git commit -qm fixture
git init -q --bare "$CASE/origin.git"
git remote add origin "$CASE/origin.git"
git push -q origin main

# Real treehouse owner: stamps owner_started_at in the pool's own state file.
mkfifo "$CASE/getin"
( cd "$CASE/project" && exec treehouse get < "$CASE/getin" > "$CASE/get.log" 2>&1 ) &
OWNER_PID=$!
exec 3> "$CASE/getin"
STATE_FILE=
for _ in $(seq 1 40); do
  STATE_FILE=$(ls "$CASE"/.treehouse/*/treehouse-state.json 2>/dev/null | head -1)
  [ -n "$STATE_FILE" ] && grep -q owner_started_at "$STATE_FILE" && break
  sleep 0.5
done
if [ -z "$STATE_FILE" ] || ! grep -q owner_started_at "$STATE_FILE"; then
  echo "SETUP-FAIL: real treehouse never stamped owner_started_at" | tee -a "$OUT/env.txt"
  exit 1
fi
# Move the owner shell's cwd out of the slot so only the occupant's own pane
# process is rooted there at teardown time.
printf 'cd %s && exec /bin/sleep 900\n' "$CASE" >&3
sleep 1

SLOT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['worktrees'][0]['path'])" "$STATE_FILE")
OWNER_MS=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['worktrees'][0]['owner_started_at'])" "$STATE_FILE")
OWNER_SEC=$((OWNER_MS / 1000))
{
  echo "scenario=${MODE}"
  echo "teardown_root=$ROOT"
  echo "case_root=$CASE"
  echo "slot=$SLOT"
  echo "owner_started_at_ms=$OWNER_MS"
  echo "owner_started_at_s=$OWNER_SEC"
} > "$OUT/env.txt"

# The slot copy carries no unlanded work: clean and fully pushed.
{
  echo "slot_git_status=[$(git -C "$SLOT" status --porcelain | tr '\n' ';')]"
  echo "slot_unpushed=[$(git -C "$SLOT" log --oneline HEAD --not --remotes | tr '\n' ';')]"
} >> "$OUT/env.txt"

export TMUX_TMPDIR="$CASE/tmuxsock"
TMUXSOCKDIR="$CASE/tmuxsock"
unset TMUX TMUX_PANE
# Occupant pane: the occupant record's own endpoint, rooted in the slot.
tmux new-session -d -s main -n "fm-current-task" "cd $SLOT && exec $CASE/fakebin/pi 900"
# Stale record's own endpoint: a live window whose process is NOT in the slot.
tmux new-session -d -s other -n "fm-stale-task" "cd $CASE && exec $CASE/fakebin/pi 900"
sleep 1.5
PANE=$(tmux display-message -p -t main:fm-current-task '#{pane_pid}')
echo "occupant_pane_leader=$PANE" >> "$OUT/env.txt"
echo "occupant_endpoint_state=$(bash -c ". $ROOT/bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux main:fm-current-task")" >> "$OUT/env.txt"
echo "stale_endpoint_state=$(bash -c ". $ROOT/bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux other:fm-stale-task")" >> "$OUT/env.txt"

OWN_EPOCH=$((OWNER_SEC + 30))
OTHER_EPOCH=$((OWNER_SEC - 46800))

case "$MODE" in
  no-owner-record)
    # The pool state names no owner start for the slot at all.
    python3 - "$STATE_FILE" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for w in d["worktrees"]:
    w.pop("owner_started_at", None); w.pop("owner_pid", None)
json.dump(d, open(p, "w"), indent=2)
PY
    ;;
  both-predate)
    # A third party holds the slot: neither record's claim reaches the owner.
    OWN_EPOCH=$((OWNER_SEC - 10))
    OTHER_EPOCH=$((OWNER_SEC - 20))
    ;;
esac

fm_meta() {  # <id> <window> <spawn_gen> [kind] [home]
  local id=$1 window=$2 gen=$3 kind=${4:-scout} home=${5:-}
  {
    printf 'window=%s\n' "$window"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$SLOT"
    [ -z "$home" ] || printf 'home=%s\n' "$home"
    printf 'project=%s\n' "$CASE/project"
    printf 'kind=%s\n' "$kind"
    printf 'spawn_gen=%s\n' "$gen"
  } > "$CASE/home/state/$id.meta"
}

KIND=${FM_LIVE_KIND:-scout}
OTHER_KIND=$KIND
OTHER_HOME=
[ "$MODE" = secondmate ] && { OTHER_KIND=secondmate; OTHER_HOME=$SLOT; }
FORCE=--force
[ "${FM_LIVE_NOFORCE:-}" = 1 ] && FORCE='' 

fm_meta current-task main:fm-current-task "s$OWN_EPOCH.4242.1"
fm_meta stale-task other:fm-stale-task "s$OTHER_EPOCH.4242.2" "$OTHER_KIND" "$OTHER_HOME"

if [ "$MODE" = unlanded ]; then
  # Unlanded work in the shared copy: the destruction proof must still refuse.
  : > "$SLOT/scratch"
fi
if [ "$MODE" = unowned-process ]; then
  # A leftover process rooted in the slot that belongs to no one this record's
  # endpoint owns: the exact leak the destruction proof must refuse.
  ( cd "$SLOT" && exec /bin/sleep 900 ) &
  LEAK=$!
  echo "leaked_pid=$LEAK" >> "$OUT/env.txt"
fi

if [ "${FM_LIVE_REPORT:-}" = 1 ]; then
  mkdir -p "$CASE/home/data/current-task" "$CASE/home/data/stale-task"
  printf '# report\n' > "$CASE/home/data/current-task/report.md"
  printf '# report\n' > "$CASE/home/data/stale-task/report.md"
fi
cp "$STATE_FILE" "$OUT/pool-state-before.json"
python3 - "$SLOT" >> "$OUT/env.txt" <<'PY'
import os,subprocess,sys
slot=os.path.realpath(sys.argv[1])
out=subprocess.run(["lsof","-a","-d","cwd","-Fpn"],capture_output=True,text=True).stdout
pid=None; hits=[]
for line in out.splitlines():
    if line.startswith("p"): pid=line[1:]
    elif line.startswith("n") and line[1:].startswith(slot): hits.append(pid)
print("rooted_in_slot_before=%r" % (hits,))
PY

TARGET=current-task
[ "$MODE" = reverse ] && TARGET=stale-task
if [ "$MODE" = recover-both ]; then
  # The full incident recovery: collect the occupant, then the stale record.
  TARGET=current-task
fi
TRACE=
[ "${FM_LIVE_TRACE:-}" = 1 ] && TRACE="bash -x"

# FM_GATE_REFUSE_BYPASS mirrors tests/lib.sh: this validation runs FROM a
# no-mistakes gate worktree, the exact environment that guard refuses.
env FM_HOME="$CASE/home" FM_ROOT_OVERRIDE="$ROOT" TMUX_TMPDIR="$TMUXSOCKDIR" \
  FM_GATE_REFUSE_BYPASS=1 PATH="$PATH" $TRACE "$TEARDOWN" $TARGET ${FORCE:+$FORCE} \
  > "$OUT/stdout.txt" 2> "$OUT/stderr.txt"
RC=$?
echo "teardown_target=$TARGET" >> "$OUT/env.txt"
echo "teardown_force=${FORCE:-none}" >> "$OUT/env.txt"
echo "teardown_kind=$KIND" >> "$OUT/env.txt"
echo "exit=$RC" >> "$OUT/env.txt"
cp "$STATE_FILE" "$OUT/pool-state-after.json"
{
  echo "current_meta_present=$([ -f "$CASE/home/state/current-task.meta" ] && echo yes || echo no)"
  echo "stale_meta_present=$([ -f "$CASE/home/state/stale-task.meta" ] && echo yes || echo no)"
  echo "slot_scratch_present=$([ -f "$SLOT/scratch" ] && echo yes || echo no)"
  echo "slot_dir_present=$([ -d "$SLOT" ] && echo yes || echo no)"
  echo "owner_field_after=$([ -n "$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));w=d['worktrees'][0];print(w.get('owner_started_at',''))" "$STATE_FILE")" ] && echo yes || echo no)"
  [ -z "${LEAK:-}" ] || echo "leaked_pid_alive_after=$(kill -0 "$LEAK" 2>/dev/null && echo yes || echo no)"
} >> "$OUT/env.txt"
tmux list-windows -a -F '#{session_name}:#{window_name}' > "$OUT/windows-after.txt" 2>&1 || true
if [ "$MODE" = recover-both ]; then
  env FM_HOME="$CASE/home" FM_ROOT_OVERRIDE="$ROOT" TMUX_TMPDIR="$TMUXSOCKDIR" \
    FM_GATE_REFUSE_BYPASS=1 PATH="$PATH" "$TEARDOWN" stale-task ${FORCE:+$FORCE} \
    > "$OUT/stdout-second.txt" 2> "$OUT/stderr-second.txt"
  RC2=$?
  echo "second_exit=$RC2" >> "$OUT/env.txt"
  echo "stale_meta_present_after_second=$([ -f "$CASE/home/state/stale-task.meta" ] && echo yes || echo no)" >> "$OUT/env.txt"
  cp "$STATE_FILE" "$OUT/pool-state-after-second.json"
fi
cat "$OUT/env.txt"
exit 0
