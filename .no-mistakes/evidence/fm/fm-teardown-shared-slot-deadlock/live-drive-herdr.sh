#!/usr/bin/env bash
# Live end-to-end drive of the Herdr half of the shared-pool-slot rule against
# the REAL product: a real isolated Herdr lab session (bin/fm-herdr-lab.sh), a
# real Treehouse pool, and real panes whose shells are rooted in the slot. The
# reviewed change added fm_backend_endpoint_root_pid's Herdr branch, and both
# reported deadlock reproductions record backend=herdr, so this drives that
# branch through the real herdr CLI and the real fm-teardown.sh.
set -u

W=/Users/onyx/.no-mistakes/worktrees/9573b29b9316/01M280VC7RN42VXZ540X1NMFE7
EV=/Users/onyx/.no-mistakes/evidence/01M280VC7RN42VXZ540X1NMFE7
LAB="$W/bin/fm-herdr-lab.sh"
TEARDOWN="$W/bin/fm-teardown.sh"
PASSES=0
FAILS=0

ok()  { PASSES=$((PASSES + 1)); printf 'PASS  %s\n' "$*"; }
bad() { FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$*"; }

command -v herdr >/dev/null 2>&1 || { echo "herdr is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fmnm-live-herdr.XXXXXX") || exit 2
ROOT=$(cd -P -- "$ROOT" && pwd -P)
PROJ="$ROOT/proj"
SESSION="$("$LAB" name nmlive)"
CASE="$ROOT/case"

cleanup() {
  "$LAB" teardown "$SESSION" >/dev/null 2>&1 || true
  pkill -f "$ROOT/bin/pi" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

mkdir -p "$ROOT/root" "$PROJ" "$ROOT/bin" "$CASE/home/state" "$CASE/home/data" "$CASE/home/config"
(
  cd "$PROJ" || exit 1
  git init -q -b main
  git -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m init
  printf 'max_trees = 4\nroot = "%s/root"\n' "$ROOT" > treehouse.toml
  git init -q --bare "$ROOT/origin.git"
  git remote add origin "$ROOT/origin.git"
  git push -q origin main
  git fetch -q origin
)

"$LAB" provision "$SESSION" >/dev/null || { echo "herdr lab provision failed" >&2; exit 2; }

printf 'root=%s session=%s\n' "$ROOT" "$SESSION"

slot=$( cd "$PROJ" && TREEHOUSE_NO_UPDATE_CHECK=1 treehouse get --lease 2>/dev/null )
[ -n "$slot" ] || { echo "could not lease a real slot" >&2; exit 2; }
printf 'slot=%s\n' "$slot"

# A real Herdr workspace whose pane shell starts inside the pool slot, then a
# real registered agent on that pane (herdr's own lifecycle API).
ws=$("$LAB" run "$SESSION" workspace create --cwd "$slot" --label fm-nmlive) || exit 2
ws_id=$(printf '%s' "$ws" | jq -r '.result.workspace.workspace_id')
pane_id=$(printf '%s' "$ws" | jq -r '.result.root_pane.pane_id')
tab_id=$(printf '%s' "$ws" | jq -r '.result.root_pane.tab_id')
"$LAB" run "$SESSION" pane report-agent "$pane_id" --source nm-live-drive --agent pi --state idle >/dev/null 2>&1 \
  || { echo "could not register the agent on $pane_id" >&2; exit 2; }
printf 'workspace=%s pane=%s\n' "$ws_id" "$pane_id"

# Live branch check: the new herdr probe must name exactly the pane shell, and
# must prove nothing for a pane that does not exist.
live_root=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_endpoint_root_pid herdr "$2:$3"' _ "$W" "$SESSION" "$pane_id")
live_shell=$(printf '%s' "$ws" | jq -r '.result.root_pane.pane_id' >/dev/null; "$LAB" run "$SESSION" pane process-info --pane "$pane_id" | jq -r '.result.process_info.shell_pid')
if [ -n "$live_root" ] && [ "$live_root" = "$live_shell" ]; then
  ok "H1: fm_backend_endpoint_root_pid (herdr) names the real pane shell pid $live_root"
else
  bad "H1: herdr endpoint root read = '${live_root:-<empty>}', pane shell pid = '$live_shell'"
fi
absent_root=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_endpoint_root_pid herdr "$2:w99:p99"' _ "$W" "$SESSION")
[ -z "$absent_root" ] && ok "H1: an absent pane proves no endpoint root (empty)" || bad "H1: absent pane named root '$absent_root'"
own_state=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state herdr "$2:$3"' _ "$W" "$SESSION" "$pane_id")
[ "$own_state" = alive ] && ok "H1: the live pane reads alive through the recovery classifier" || bad "H1: live pane read '$own_state'"

write_record() {  # <id> <pane> <ws> <tab>
  local id=$1 pane=$2 ws=$3 tab=$4
  {
    printf 'window=%s:%s\n' "$SESSION" "$pane"
    printf 'backend=herdr\n'
    printf 'herdr_session=%s\n' "$SESSION"
    printf 'herdr_workspace_id=%s\n' "$ws"
    printf 'herdr_tab_id=%s\n' "$tab"
    printf 'herdr_pane_id=%s\n' "$pane"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$slot"
    printf 'project=%s\n' "$PROJ"
    printf 'kind=scout\n'
  } > "$CASE/home/state/$id.meta"
}

write_record survivor "$pane_id" "$ws_id" "$tab_id"
write_record departed "w99:p99" "w99" "w99:t99"
printf 'root_shell_cwd_pids='
lsof +d "$slot" 2>/dev/null | awk 'NR>1{print $2}' | sort -u | tr '\n' ' '
printf '\n'

: > "$CASE/runtime.log"
set +e
TREEHOUSE_NO_UPDATE_CHECK=1 FM_GATE_REFUSE_BYPASS=1 \
  FM_HOME="$CASE/home" FM_ROOT_OVERRIDE="$W" FM_RUNTIME_LOG="$CASE/runtime.log" \
  "$TEARDOWN" survivor --force > "$CASE/stdout" 2> "$CASE/stderr"
rc=$?
set -e
printf 'teardown rc=%s\n' "$rc"
cp "$CASE/stderr" "$EV/live-herdr-endtoend.stderr.txt"
grep -v "WATCHER DOWN\|task(s) in flight\|supervision protocol\|supervision warning\|repair a missing\|●\|still down" "$CASE/stderr" > "$EV/live-herdr-endtoend.decision.txt"

if [ "$rc" -eq 0 ]; then
  ok "H2: teardown of the live claimant released the shared Herdr slot (rc=0)"
else
  bad "H2: teardown refused the live claimant (rc=$rc): $(tail -3 "$CASE/stderr")"
fi
grep -q "is the surviving claimant, so cleanup continues" "$CASE/stderr" \
  && ok "H2: the Herdr release was taken by the live-owner proof" \
  || bad "H2: the Herdr release proof never ran"
[ ! -e "$CASE/home/state/survivor.meta" ] && ok "H2: the live record was collected" || bad "H2: the live record survived"
[ -e "$CASE/home/state/departed.meta" ] && ok "H2: the gone record was left for reconciliation" || bad "H2: the gone record was removed"
[ -z "$(lsof +d "$slot" 2>/dev/null | awk 'NR>1{print $2}' | sort -u)" ] \
  && ok "H2: no process is left rooted in the returned slot" \
  || bad "H2: a process is still rooted in the returned slot"
if ( cd "$PROJ" && TREEHOUSE_NO_UPDATE_CHECK=1 treehouse status 2>/dev/null ) | grep -q "leased"; then
  bad "H2: the pool still reports the slot leased"
else
  ok "H2: real treehouse returned the slot (no longer leased)"
fi
if "$LAB" run "$SESSION" pane get "$pane_id" >/dev/null 2>&1; then
  bad "H2: the recorded Herdr pane survived the release"
else
  ok "H2: the recorded Herdr pane was closed"
fi

printf 'live herdr drive: %s passed, %s failed\n' "$PASSES" "$FAILS"
[ "$FAILS" -eq 0 ]
