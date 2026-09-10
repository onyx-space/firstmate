#!/usr/bin/env bash
# Capture the EXACT launch command bin/fm-spawn.sh composes for a pi crewmate
# when the resolved `pi` on PATH is the REAL installed Pi (not a stub).
# The only stubs are the tmux backend (captures send-keys -l payloads) and
# treehouse (no-op), exactly as tests/fm-spawn-dispatch-profile.test.sh does.
set -u
WTROOT=/Users/onyx/.no-mistakes/worktrees/9573b29b9316/01M26R7BYW6ZWBR8TCR1EQTYG1
. "$WTROOT/tests/fixtures.sh"

OUT=${1:?usage: capture-launch.sh <out-prefix> [spawn-args...]}
shift || true
SPAWN_ARGS=("$@")
if [ "${#SPAWN_ARGS[@]}" -eq 0 ]; then
  SPAWN_ARGS=(--mode no-mistakes --yolo off)
fi
SCRATCH=/tmp/fm-trust-live/capture-$$
mkdir -p "$SCRATCH"

home="$SCRATCH/home"
proj="$SCRATCH/project"
wt="$SCRATCH/wt"
launchlog="$SCRATCH/launch.log"
fakebin=$(fm_fakebin "$SCRATCH")
fm_test_fake_tmux_spawn "$fakebin"
fm_fake_exit0 "$fakebin" treehouse
cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
chmod +x "$fakebin/timeout"

fm_test_spawn_home "$home" pi
fm_git_worktree "$proj" "$wt" "wt-trust-capture"
id=profile-pi-trustcapture-z9c
fm_test_spawn_brief "$home" "$id"

: > "$launchlog"
spawn_home="$home/user-home"
mkdir -p "$spawn_home"
# PATH deliberately does NOT carry a fake `pi`: the real /opt/homebrew/bin/pi
# is what the probe and the launch line see.
FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$spawn_home" \
  CLAUDE_CONFIG_DIR='' \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_LOG="$launchlog" \
  TMUX="${TMUX:-fake,1,0}" \
  PATH="$fakebin:$PATH" \
  "$WTROOT/bin/fm-spawn.sh" "$id" "$proj" "${SPAWN_ARGS[@]}" \
    --harness pi >"$OUT.spawn-out" 2>&1
status=$?
printf 'spawn_exit=%s\n' "$status" >> "$OUT.spawn-out"
printf 'resolved_pi=%s\n' "$(command -v pi)" >> "$OUT.spawn-out"
cp "$launchlog" "$OUT.launch"
printf 'scratch=%s\n' "$SCRATCH"
cat "$OUT.launch"
exit "$status"
