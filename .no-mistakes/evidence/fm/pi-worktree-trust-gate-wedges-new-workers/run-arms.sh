#!/usr/bin/env bash
# Live arms: run the launch command bin/fm-spawn.sh actually composes for a pi
# crewmate against the REAL installed Pi, in a real tmux pane, with the pane's
# cwd set to a fresh, never-trusted directory that holds trust-requiring
# project resources (.pi/ + AGENTS.md) - the shape of a brand-new treehouse slot.
#
#   arm 1 (control)   : the composed launch line with --approve removed
#   arm 2 (treatment) : the composed launch line, byte for byte
#
# Only the pty transport is ours: the command is the product's own output.
# PI_CODING_AGENT_DIR is pointed at a throwaway agent dir so neither arm can
# reach (or write) the operator's own ~/.pi/agent/trust.json, and PI_OFFLINE=1
# keeps the startup from reaching the network. Neither touches argv.
set -u

CMD_FILE=${1:?usage: run-arms.sh <launch-command-file> <out-prefix>}
OUT=${2:?usage: run-arms.sh <launch-command-file> <out-prefix>}
WTROOT=/Users/onyx/.no-mistakes/worktrees/9573b29b9316/01M26R7BYW6ZWBR8TCR1EQTYG1

SCRATCH=/tmp/fm-trust-live/arms
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/agent"
SOCK="$SCRATCH/tmux.sock"
export TMUX="$SOCK,$$,0"

# A fresh firstmate-shaped slot: project-local resources Pi must trust.
WT="$SCRATCH/wt"
mkdir -p "$WT/.pi/extensions" "$WT/.agents"
cp -R "$WTROOT/.pi/." "$WT/.pi/" 2>/dev/null || true
cp "$WTROOT/AGENTS.md" "$WT/AGENTS.md" 2>/dev/null || true
printf 'export default function(){};\n' > "$WT/.pi/extensions/trust-probe.ts"
git -C "$WT" init -q 2>/dev/null || true

CMD=$(cat "$CMD_FILE")
CTRL=${CMD/ --approve/}

trust_before=$(shasum -a 256 "$HOME/.pi/agent/trust.json" 2>/dev/null | awk '{print $1}')

run_arm() {  # <name> <command>
  local name=$1 cmd=$2 ses="arm-$1" cap
  tmux new-session -d -s "$ses" -c "$WT" -x 140 -y 45
  tmux send-keys -t "$ses" -l "PI_CODING_AGENT_DIR='$SCRATCH/agent' PI_OFFLINE=1 $cmd"
  sleep 1
  tmux send-keys -t "$ses" Enter
  sleep 12
  cap=$(tmux capture-pane -p -t "$ses" -S -400)
  printf '%s\n' "$cap" > "$OUT.$name.pane"
  tmux kill-session -t "$ses" 2>/dev/null || true
  printf 'arm=%s dialog_seen=%s agent_event_seen=%s\n' "$name" \
    "$(printf '%s\n' "$cap" | grep -c 'Trust project folder')" \
    "$(printf '%s\n' "$cap" | grep -Ec 'esc to interrupt|Working|Thinking|pi ·|composer')"
}

run_arm control   "$CTRL"
run_arm treatment "$CMD"

tmux kill-server 2>/dev/null || true

trust_after=$(shasum -a 256 "$HOME/.pi/agent/trust.json" 2>/dev/null | awk '{print $1}')
printf '\ncontrol_command (--approve removed):\n%s\n\ntreatment_command (product output):\n%s\n' "$CTRL" "$CMD" > "$OUT.commands"
printf 'operator_trust_json_unchanged=%s\n' "$([ "$trust_before" = "$trust_after" ] && echo yes || echo no)" > "$OUT.isolation"
printf 'throwaway_agent_trust_json_present=%s\n' "$([ -e "$SCRATCH/agent/trust.json" ] && echo yes || echo no)" >> "$OUT.isolation"
cat "$OUT.isolation"
