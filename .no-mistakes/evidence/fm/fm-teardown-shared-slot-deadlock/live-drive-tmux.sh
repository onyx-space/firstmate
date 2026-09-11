#!/usr/bin/env bash
# Live end-to-end drive of bin/fm-teardown.sh's shared-pool-slot rule against
# the REAL product: a real tmux server (real panes, real pane_pid ancestry), a
# real Treehouse pool (real `treehouse get --lease` / `treehouse return`), and
# real processes rooted in the slot. Nothing about the teardown decision is
# stubbed; the only shim is a PATH wrapper that pins bare `tmux` to this run's
# private socket, and the external `treehouse` CLI is the real binary.
set -u

W=/Users/onyx/.no-mistakes/worktrees/9573b29b9316/01M280VC7RN42VXZ540X1NMFE7
EV=/Users/onyx/.no-mistakes/evidence/01M280VC7RN42VXZ540X1NMFE7
TEARDOWN="$W/bin/fm-teardown.sh"
REAL_TMUX=$(command -v tmux) || { echo "tmux is required" >&2; exit 2; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fmnm-live-tmux.XXXXXX") || exit 2
ROOT=$(cd -P -- "$ROOT" && pwd -P)   # canonical: the product canonicalizes FM_HOME
PROJ="$ROOT/proj"
SOCKET="$ROOT/tmux.sock"
SHIM="$ROOT/shim"
PASSES=0
FAILS=0

note() { printf '%s\n' "$*"; }
ok()   { PASSES=$((PASSES + 1)); printf 'PASS  %s\n' "$*"; }
bad()  { FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$*"; }

cleanup() {
  "$REAL_TMUX" -S "$SOCKET" kill-server 2>/dev/null || true
  pkill -f "$ROOT/bin/pi" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

# --- real project + real Treehouse pool + real "agent" process --------------
mkdir -p "$ROOT/root" "$PROJ" "$ROOT/bin" "$ROOT/home/state" "$ROOT/home/data" \
  "$ROOT/home/config" "$SHIM"
(
  cd "$PROJ" || exit 1
  git init -q -b main
  git -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m init
  printf 'max_trees = 8\nroot = "%s/root"\n' "$ROOT" > treehouse.toml
  git init -q --bare "$ROOT/origin.git"
  git remote add origin "$ROOT/origin.git"
  git push -q origin main
  git fetch -q origin
)
# A real long-lived process whose name the tmux classifier reads as an agent.
# (A copy of /bin/sleep is killed by macOS code signing; a compiled binary is not.)
printf '#include <unistd.h>\nint main(void){ for(;;) pause(); }\n' > "$ROOT/pi.c"
cc -O0 -o "$ROOT/bin/pi" "$ROOT/pi.c" || { echo "cc is required" >&2; exit 2; }

cat > "$SHIM/tmux" <<EOF
#!/usr/bin/env bash
printf 'tmux' >> "\${FM_RUNTIME_LOG:-/dev/null}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:-/dev/null}"
printf '\n' >> "\${FM_RUNTIME_LOG:-/dev/null}"
cd "$ROOT"
exec "$REAL_TMUX" -S "$SOCKET" "\$@"
EOF
chmod +x "$SHIM/tmux"

"$REAL_TMUX" -S "$SOCKET" new-session -d -s fmlive -n control -c "$ROOT"

new_slot() {  # -> prints a real leased pool slot
  ( cd "$PROJ" && TREEHOUSE_NO_UPDATE_CHECK=1 treehouse get --lease 2>/dev/null )
}

slot_lease() {  # <slot-parent-pool>  -> "N <state> <path> | none"
  ( cd "$PROJ" && TREEHOUSE_NO_UPDATE_CHECK=1 treehouse status 2>/dev/null ) \
    | awk -v pat="$1" 'index($0, pat) > 0 { print }' | head -1
}

new_window() {  # <name> <cwd>
  "$REAL_TMUX" -S "$SOCKET" new-window -d -t fmlive: -n "$1" -c "$2" -- "$ROOT/bin/pi"
}

pane_root() {  # <window>
  "$REAL_TMUX" -S "$SOCKET" display-message -p -t "fmlive:$1" '#{pane_pid}' 2>/dev/null \
    | tr -d '[:space:]'
}

window_exists() {  # <window>
  "$REAL_TMUX" -S "$SOCKET" list-windows -t fmlive -F '#{window_name}' 2>/dev/null | grep -Fqx "$1"
}

write_record() {  # <case-dir> <id> <window> <slot>
  local dir=$1 id=$2 window=$3 slot=$4
  {
    printf 'window=%s\n' "$window"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$slot"
    printf 'project=%s\n' "$PROJ"
    printf 'kind=scout\n'
  } > "$dir/home/state/$id.meta"
}

# --------------------------------------------------------------------------
# C1: the reported deadlock. Two records name one real pool slot; one pane is
# live (an agent) and the other is gone; the copy is clean and landed. Teardown
# of the live record must release the slot.
# --------------------------------------------------------------------------
case_c1_release() {
  local dir slot id=survivor other=departed rc
  dir="$ROOT/cases/c1"; mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  slot=$(new_slot); [ -n "$slot" ] || { bad "C1: could not lease a real slot"; return; }
  new_window "fm-$id" "$slot"
  write_record "$dir" "$id" "fmlive:fm-$id" "$slot"
  write_record "$dir" "$other" "fmlive:fm-$other" "$slot"
  : > "$dir/runtime.log"
  set +e
  TREEHOUSE_NO_UPDATE_CHECK=1 FM_GATE_REFUSE_BYPASS=1 \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$W" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$SHIM:$PATH" "$TEARDOWN" "$id" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then ok "C1: teardown of the live claimant released the shared slot (rc=0)"; else bad "C1: teardown refused instead of releasing (rc=$rc)"; fi
  grep -q "is the surviving claimant, so cleanup continues" "$dir/stderr" \
    && ok "C1: the release was taken by the live-owner proof" \
    || bad "C1: the release proof never ran"
  [ ! -e "$dir/home/state/$id.meta" ] && ok "C1: the live record was collected" || bad "C1: the live record survived"
  [ -e "$dir/home/state/$other.meta" ] && ok "C1: the gone record was left for reconciliation" || bad "C1: the gone record was removed"
  window_exists fm-survivor && bad "C1: the endpoint pane was not reaped" || ok "C1: the endpoint pane was reaped"
  [ -z "$(lsof +d "$slot" 2>/dev/null | awk 'NR>1{print $2}' | sort -u)" ] \
    && ok "C1: no process is left rooted in the returned slot" \
    || bad "C1: a process is still rooted in the returned slot"
  if slot_lease "$slot" | grep -q "leased"; then bad "C1: the pool still reports the slot leased: $(slot_lease "$slot")"; else ok "C1: real treehouse returned the slot (no longer leased)"; fi
  cp "$dir/stderr" "$EV/live-tmux-c1-release.stderr.txt"
}

# --------------------------------------------------------------------------
# C2: adversarial. The stale record is torn down while the co-claimant's pane
# is live: must refuse, must offer the one release order that works, and must
# change nothing.
# --------------------------------------------------------------------------
case_c2_live_co_claimant() {
  local dir slot id=stale other=live rc
  dir="$ROOT/cases/c2"; mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  slot=$(new_slot); [ -n "$slot" ] || { bad "C2: could not lease a real slot"; return; }
  new_window "fm-$other" "$slot"
  write_record "$dir" "$id" "fmlive:fm-$id" "$slot"
  write_record "$dir" "$other" "fmlive:fm-$other" "$slot"
  : > "$dir/runtime.log"
  set +e
  TREEHOUSE_NO_UPDATE_CHECK=1 FM_GATE_REFUSE_BYPASS=1 \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$W" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$SHIM:$PATH" "$TEARDOWN" "$id" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "C2: teardown refused while the co-claimant's pane is live" || bad "C2: a live co-claimant's slot was released"
  grep -q "Tear down task $other first, then re-run this one" "$dir/stderr" \
    && ok "C2: the refusal names the release order (tear down $other first)" \
    || bad "C2: the refusal hides the sanctioned exit"
  [ -e "$dir/home/state/$id.meta" ] && [ -e "$dir/home/state/$other.meta" ] \
    && ok "C2: both records survived" || bad "C2: a record was mutated"
  window_exists fm-live && ok "C2: the live pane survived" || bad "C2: the live pane was killed"
  slot_lease "$slot" | grep -q "leased" && ok "C2: the slot is still leased" || bad "C2: the slot was released"
  grep -Eq "tmux <(kill-window|kill-session)>|treehouse <return>" "$dir/runtime.log" \
    && bad "C2: a mutating command ran on a refusal" || ok "C2: no mutating command ran"
  cp "$dir/stderr" "$EV/live-tmux-c2-live-co-claimant.stderr.txt"
}

# --------------------------------------------------------------------------
# C3: adversarial. Same release reading, but an orphaned process (reparented to
# launchd, so not a descendant of the pane leader) is rooted in the slot. The
# return would kill it, so teardown must refuse, name the pid, and not offer
# the release order (this record IS the live claimant).
# --------------------------------------------------------------------------
case_c3_unowned_process() {
  local dir slot id=survivor other=departed rc orphan
  dir="$ROOT/cases/c3"; mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  slot=$(new_slot); [ -n "$slot" ] || { bad "C3: could not lease a real slot"; return; }
  new_window "fm-$id" "$slot"
  # Orphan: the launching shell exits at once, so the sleep reparents to pid 1.
  ( cd "$slot" && sleep 120 < /dev/null > /dev/null 2>&1 & ) 
  sleep 0.5
  orphan=$(lsof +d "$slot" 2>/dev/null | awk 'NR>1{print $2}' | sort -u | while read -r p; do
    [ "$p" = "$(pane_root "fm-$id")" ] && continue
    ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    printf '%s %s\n' "$p" "$ppid"
  done)
  write_record "$dir" "$id" "fmlive:fm-$id" "$slot"
  write_record "$dir" "$other" "fmlive:fm-$other" "$slot"
  : > "$dir/runtime.log"
  set +e
  TREEHOUSE_NO_UPDATE_CHECK=1 FM_GATE_REFUSE_BYPASS=1 \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$W" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$SHIM:$PATH" "$TEARDOWN" "$id" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "C3: teardown refused with an unowned process rooted in the slot" || bad "C3: the slot was released over an unowned process"
  grep -q "is neither the pane leader" "$dir/stderr" \
    && ok "C3: the refusal explains which process it could not account for" \
    || bad "C3: the process proof refused silently"
  grep -q "does not own it" "$dir/stderr" && ok "C3: the refusal names the ownership proof" || bad "C3: no ownership diagnostic"
  grep -q "One record can release it:" "$dir/stderr" \
    && bad "C3: the release order was offered where it cannot be followed" \
    || ok "C3: the release order is not offered on this reading"
  slot_lease "$slot" | grep -q "leased" && ok "C3: the slot is still leased" || bad "C3: the slot was released"
  note "C3 orphan root scan (pid ppid): ${orphan:-<none>}"
  cp "$dir/stderr" "$EV/live-tmux-c3-unowned-process.stderr.txt"
}

# --------------------------------------------------------------------------
# C4: adversarial. Same release reading, but the shared copy holds uncommitted
# work: the release must refuse on the copy proof.
# --------------------------------------------------------------------------
case_c4_unlanded_copy() {
  local dir slot id=survivor other=departed rc
  dir="$ROOT/cases/c4"; mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  slot=$(new_slot); [ -n "$slot" ] || { bad "C4: could not lease a real slot"; return; }
  new_window "fm-$id" "$slot"
  printf 'unlanded\n' > "$slot/uncommitted-marker"
  write_record "$dir" "$id" "fmlive:fm-$id" "$slot"
  write_record "$dir" "$other" "fmlive:fm-$other" "$slot"
  : > "$dir/runtime.log"
  set +e
  TREEHOUSE_NO_UPDATE_CHECK=1 FM_GATE_REFUSE_BYPASS=1 \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$W" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$SHIM:$PATH" "$TEARDOWN" "$id" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "C4: teardown refused with unlanded work in the shared copy" || bad "C4: a shared slot with unlanded work was released"
  grep -q "uncommitted changes" "$dir/stderr" && ok "C4: the refusal is the shared-copy proof" || bad "C4: wrong refusal"
  [ -e "$slot/uncommitted-marker" ] && ok "C4: the unlanded copy survived" || bad "C4: the unlanded copy was reset"
  slot_lease "$slot" | grep -q "leased" && ok "C4: the slot is still leased" || bad "C4: the slot was released"
  cp "$dir/stderr" "$EV/live-tmux-c4-unlanded-copy.stderr.txt"
}

# --------------------------------------------------------------------------
# C5: adversarial. Both records' panes are live: no one is the surviving
# claimant, so the collision stays refused and the message offers no order.
# --------------------------------------------------------------------------
case_c5_both_live() {
  local dir slot id=live-a other=live-b rc
  dir="$ROOT/cases/c5"; mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  slot=$(new_slot); [ -n "$slot" ] || { bad "C5: could not lease a real slot"; return; }
  new_window "fm-$id" "$slot"
  new_window "fm-$other" "$slot"
  write_record "$dir" "$id" "fmlive:fm-$id" "$slot"
  write_record "$dir" "$other" "fmlive:fm-$other" "$slot"
  : > "$dir/runtime.log"
  set +e
  TREEHOUSE_NO_UPDATE_CHECK=1 FM_GATE_REFUSE_BYPASS=1 \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$W" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$SHIM:$PATH" "$TEARDOWN" "$id" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "C5: teardown refused while both claimants are live" || bad "C5: a live shared slot was released"
  grep -q "One record can release it:" "$dir/stderr" \
    && bad "C5: the release order was offered where it cannot be followed" \
    || ok "C5: no release order offered (neither record is the live one this pick can use)"
  slot_lease "$slot" | grep -q "leased" && ok "C5: the slot is still leased" || bad "C5: the slot was released"
  cp "$dir/stderr" "$EV/live-tmux-c5-both-live.stderr.txt"
}

note "root=$ROOT"
case_c1_release
case_c2_live_co_claimant
case_c3_unowned_process
case_c4_unlanded_copy
case_c5_both_live
note "live tmux drive: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
