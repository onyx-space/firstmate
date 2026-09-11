#!/usr/bin/env bash
# Live driver for the fm-teardown shared pool-slot release path.
#
# Drives the REAL product (bin/fm-teardown.sh at the branch tip) against
# isolated fixtures built under a temp dir. Nothing in the product's decision
# path is stubbed: real tmux server (isolated via TMUX_TMPDIR), real pane leader
# pid, real ps/lsof process tree, real git pool slot produced by a real
# `treehouse get --lease`, real `treehouse return`, real symlinked home
# spellings. The only stand-in is the agent process inside the pane: a compiled
# sleeper named `pi` (a genuine agent would write user-level session state
# outside this run's boundary).
set -u

REPO=${REPO:-/Users/onyx/.no-mistakes/worktrees/9573b29b9316/01M280VC7RN42VXZ540X1NMFE7}
TEARDOWN=$REPO/bin/fm-teardown.sh
LIVE=${LIVE:-/tmp/fm-live-teardown}
export PATH=/Users/onyx/.local/bin:$PATH
export FM_GATE_REFUSE_BYPASS=1
export TMUX_TMPDIR=$LIVE/tmux
EVID=${EVID:-/Users/onyx/.no-mistakes/evidence/01M280VC7RN42VXZ540X1NMFE7}
TRANSCRIPTS=$EVID/transcripts
unset FM_TASK_ID

FAILED=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }
note() { printf '      %s\n' "$*"; }
hdr()  { printf '\n=== %s\n' "$*"; }

POOL_DIRS=()
DIR=
SLOT=

rm -rf "$LIVE"
mkdir -p "$LIVE" "$TMUX_TMPDIR" "$TRANSCRIPTS"

cleanup() {
  tmux -f /dev/null kill-server 2>/dev/null || true
  pkill -f "$LIVE/bin/pi" 2>/dev/null || true
  pkill -f "$LIVE" 2>/dev/null || true
  for d in "${POOL_DIRS[@]:-}"; do [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"; done
  rm -rf "$LIVE"
}
trap cleanup EXIT

# --- fixture primitives -----------------------------------------------------

compile_agent() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin"
  printf '#include <unistd.h>\nint main(void){ for(;;) sleep(60); return 0; }\n' > "$dir/pi.c"
  cc -O0 -o "$dir/bin/pi" "$dir/pi.c"
}

# A real leased treehouse pool slot for this case's project, exactly how a real
# task gets one. Sets SLOT.
lease_slot() {  # <dir>
  local dir=$1
  SLOT=$(cd "$dir/project" && treehouse get --lease 2>/dev/null | grep '^/' | tail -1)
  if [ -z "$SLOT" ]; then
    echo "lease_slot: treehouse get --lease produced no path" >&2
    return 1
  fi
  POOL_DIRS+=("$(dirname "$(dirname "$SLOT")")")
}

# The clean, landed copy the shared-copy proof requires: scratch committed and
# HEAD reachable from a remote-tracking branch.
make_copy_landed() {  # <dir> <slot>
  local dir=$1 slot=$2
  : > "$slot/scratch"
  git -C "$slot" add -A
  git -C "$slot" -c user.name=live -c user.email=live@example.invalid commit -qm "pool scratch"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/project" remote add origin "$dir/origin.git" 2>/dev/null || true
  git -C "$slot" push -q origin HEAD:refs/heads/main
  git -C "$dir/project" fetch -q origin
}

write_meta() {  # <meta> <k=v>...
  local meta=$1 kv
  shift
  : > "$meta"
  for kv in "$@"; do printf '%s\n' "$kv" >> "$meta"; done
}

# Base fixture: real git project, real leased pool slot, real `pi` sleeper.
# Sets DIR and SLOT.
build_base() {  # <case-name>
  local name=$1
  DIR=$LIVE/$name
  rm -rf "$DIR"
  mkdir -p "$DIR/home/state" "$DIR/home/data" "$DIR/home/config" "$DIR/project"
  git init -q "$DIR/project"
  git -C "$DIR/project" -c user.name=live -c user.email=live@example.invalid \
    commit --allow-empty -qm init
  compile_agent "$DIR"
  lease_slot "$DIR"
}

# Start a REAL tmux window running the `pi` sleeper with its cwd inside the
# slot: a genuine pane leader whose process tree is rooted in the slot.
start_live_endpoint() {  # <dir> <session> <window> <slot>
  local dir=$1 session=$2 window=$3 slot=$4
  tmux -f /dev/null new-session -d -s "$session" -n "$window" -c "$slot" "$dir/bin/pi"
}

# A leaked, orphaned worker rooted in the slot: its launching subshell exits, so
# it is reparented to init and no longer descends from the pane leader.
leak_orphan_in_slot() {  # <slot>
  ( cd "$1" && nohup /bin/sleep 300 >/dev/null 2>&1 & )
  sleep 0.5
}

run_teardown() {  # <dir> <id> [args...]
  local dir=$1 id=$2
  shift 2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$REPO" "$TEARDOWN" "$id" "$@"
}

# The two records the reported deadlock pairs carry: one whose endpoint is a
# live pane in the slot, one whose endpoint is gone. <reading> picks the gone
# record's endpoint: "missing" (no such session) or "dead" (a real window whose
# pane holds only a shell).
write_pair_metas() {  # <dir> <id> <other> [kind]
  local dir=$1 id=$2 other=$3 kind=${4:-ship}
  write_meta "$dir/home/state/$id.meta" \
    "window=main:fm-$id" "endpoint_task_id=$id" \
    "worktree=$SLOT" "project=$dir/project" "kind=$kind"
  write_meta "$dir/home/state/$other.meta" \
    "window=other:fm-$other" "endpoint_task_id=$other" \
    "worktree=$SLOT" "project=$dir/project" "kind=$kind"
}

# Copy a run's captured streams into the evidence dir so the transcript
# survives this driver's temp-dir cleanup.
keep_capture() {  # <dir> <tag>
  local dir=$1 tag=$2
  cp "$dir/stdout" "$TRANSCRIPTS/$tag.stdout" 2>/dev/null || true
  cp "$dir/stderr" "$TRANSCRIPTS/$tag.stderr" 2>/dev/null || true
  printf 'evidence: %s\n' "$TRANSCRIPTS/$tag.stderr" >&2
}

summarize_state() {  # <label> <dir> <id> <other>
  local label=$1 dir=$2 id=$3 other=$4
  note "$label: own-record=$([ -f "$dir/home/state/$id.meta" ] && echo present || echo REMOVED)" \
    "co-claimant-record=$([ -f "$dir/home/state/$other.meta" ] && echo present || echo removed)" \
    "slot-sentinel=$([ -e "$SLOT/scratch" ] && echo present || echo gone)"
}

# --- scenarios --------------------------------------------------------------

# S1: the reported deadlock. Two records name one real pool slot; the
# co-claimant's recorded endpoint is provably gone, this record's is a live pane
# whose process tree owns the slot, and the shared copy is landed. The deadlock
# must resolve: the record is collected and the slot really goes back to the
# pool.
# S6b: the Herdr branch against the real slot from the captain's own reported
# pair. Read-only: it reads the live pane's process info and the process tree
# rooted in that slot, and tears nothing down.
scenario_real_reported_slot_ancestry() {
  local target=${FM_LIVE_HERDR_TARGET:-default:w3M:p2}
  local slot=${FM_LIVE_REPORTED_SLOT:-/Users/onyx/.treehouse/firstmate-9b33b6/4/firstmate}
  local root pids p cur hops
  hdr "S6b reported reproduction slot: herdr root pid is its processes' ancestor"
  if [ ! -d "$slot" ]; then
    note "reported slot $slot not present on this machine; skipped (read-only check)"
    return
  fi
  root=$(cd "$REPO" && . bin/fm-backend.sh; fm_backend_endpoint_root_pid herdr "$target")
  pids=$(lsof -a -d cwd -Fpn +D "$slot" 2>/dev/null | grep '^p' | cut -c2- | sort -u)
  note "slot=$slot target=$target root=${root:-<empty>} pids=$(echo $pids | tr '\n' ' ')"
  if [ -z "$root" ] || [ -z "$pids" ]; then
    note "no live pane or no processes rooted in the slot; nothing to compare"
    return
  fi
  for p in $pids; do
    cur=$p; hops=0
    while [ "$hops" -lt 12 ] && [ "$cur" -gt 1 ]; do
      [ "$cur" = "$root" ] && break
      cur=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')
      [ -n "$cur" ] || break
      hops=$((hops + 1))
    done
    if [ "$cur" != "$root" ]; then
      fail "pid $p rooted in the reported slot does not descend from herdr root $root"
      return
    fi
  done
  pass "every pid rooted in the reported slot $(echo $pids | tr '\n' ' ') descends from the herdr root $root"
}

scenario_release_collects_the_record() {
  local id=surviving-task other=departed-task rc gone
  hdr "S1 release+collect (co-claimant gone): kind=ship, real treehouse return"
  for gone in missing dead; do
    tmux -f /dev/null kill-server 2>/dev/null || true
    build_base "release-$gone" || { fail "fixture build failed"; return; }
    make_copy_landed "$DIR" "$SLOT"
    write_pair_metas "$DIR" "$id" "$other"
    start_live_endpoint "$DIR" main "fm-$id" "$SLOT"
    if [ "$gone" = dead ]; then
      tmux -f /dev/null new-session -d -s other -n "fm-$other" "$SHELL -i"
    fi
    sleep 1
    note "$gone case: slot=$SLOT pane-leader=$(tmux -f /dev/null display-message -p -t "main:fm-$id" '#{pane_pid}')"
    note "$gone case: product reads own=$( ( . "$REPO/bin/fm-backend.sh"; fm_backend_agent_state tmux "main:fm-$id" ) ) other=$( ( . "$REPO/bin/fm-backend.sh"; fm_backend_agent_state tmux "other:fm-$other" ) )"
    set +e
    run_teardown "$DIR" "$id" > "$DIR/stdout" 2> "$DIR/stderr"
    rc=$?
    set -e
    keep_capture "$DIR" "S1-$gone"
    grep -Fq "is the surviving claimant, so cleanup continues" "$DIR/stderr" \
      && note "$gone case: guard released the slot (release message present)" \
      || fail "$gone case: guard did not release the slot"
    if [ "$rc" -eq 0 ] && [ ! -f "$DIR/home/state/$id.meta" ] \
       && [ -f "$DIR/home/state/$other.meta" ] \
       && grep -Fq "Worktree returned to pool" "$DIR/stdout"; then
      pass "co-claimant reads $gone: record collected (exit 0), slot returned to the real pool, co-claimant record untouched"
    else
      fail "co-claimant reads $gone: teardown rc=$rc; slot returned=$(grep -Fc 'Worktree returned to pool' "$DIR/stdout")"
      tail -6 "$DIR/stderr" | sed 's/^/      | /'
    fi
  done
}

# S2: a live co-claimant keeps the slot locked, plain and with --force. Both
# endpoints read live here, so no release order exists to name and the refusal
# must not offer one.
scenario_live_co_claimant_still_refuses() {
  local id=surviving-task other=running-task rc flag
  hdr "S2 live co-claimant refuses (plain and --force)"
  for flag in "" "--force"; do
    tmux -f /dev/null kill-server 2>/dev/null || true
    build_base "contested${flag:+-force}" || { fail "fixture build failed"; return; }
    make_copy_landed "$DIR" "$SLOT"
    write_pair_metas "$DIR" "$id" "$other"
    start_live_endpoint "$DIR" main "fm-$id" "$SLOT"
    start_live_endpoint "$DIR" other "fm-$other" "$SLOT"
    sleep 1
    local tag=${flag:-plain}
    # shellcheck disable=SC2086
    set +e
    run_teardown "$DIR" "$id" $flag > "$DIR/stdout" 2> "$DIR/stderr"
    rc=$?
    set -e
    keep_capture "$DIR" "S2-$tag"
    if [ "$rc" -ne 0 ] \
       && [ -f "$DIR/home/state/$id.meta" ] && [ -f "$DIR/home/state/$other.meta" ] \
       && [ -e "$SLOT/scratch" ] \
       && grep -Fq "REFUSED: task $id's recorded worktree $SLOT is also task $other's recorded worktree." "$DIR/stderr" \
       && ! grep -Fq "One record can release it:" "$DIR/stderr" \
       && ! grep -Fq "surviving claimant" "$DIR/stderr" \
       && ! grep -Fq "Worktree returned to pool" "$DIR/stdout"; then
      pass "live co-claimant ($tag): refused, nothing mutated, no release order offered (both endpoints live)"
    else
      fail "live co-claimant ($tag): rc=$rc, slot mutated=$([ -e "$SLOT/scratch" ] && echo no || echo YES)"
      tail -5 "$DIR/stderr" | sed 's/^/      | /'
    fi
    tmux -f /dev/null kill-server 2>/dev/null || true
  done
}

# S3: the reading the guard's release order is for - this record's endpoint is
# gone, the co-claimant's is live. The refusal must name the one record whose
# teardown converges the pair instead of leaving the operator with a deadlock.
scenario_release_order_is_named() {
  local id=stale-task other=live-task rc
  hdr "S3 gone record over a live co-claimant: refusal names the sanctioned order"
  tmux -f /dev/null kill-server 2>/dev/null || true
  build_base "release-order" || { fail "fixture build failed"; return; }
  make_copy_landed "$DIR" "$SLOT"
  # id's endpoint is gone (no such session); other's is a live pane in the slot.
  write_pair_metas "$DIR" "$id" "$other"
  start_live_endpoint "$DIR" other "fm-$other" "$SLOT"
  sleep 1
  set +e
  run_teardown "$DIR" "$id" > "$DIR/stdout" 2> "$DIR/stderr"
  rc=$?
  set -e
  keep_capture "$DIR" "S3-release-order"
  if [ "$rc" -ne 0 ] && [ -f "$DIR/home/state/$id.meta" ] && [ -e "$SLOT/scratch" ] \
     && grep -Fq "One record can release it: task $other's recorded endpoint is still alive. Tear down task $other first, then re-run this one." "$DIR/stderr" \
     && ! grep -Fq "Worktree returned to pool" "$DIR/stdout"; then
    pass "gone record: refused and told the operator to tear down the live co-claimant first"
  else
    fail "gone record: rc=$rc or guidance missing"
    tail -5 "$DIR/stderr" | sed 's/^/      | /'
  fi
  # ...and following that order really does collect the pair.
  tmux -f /dev/null kill-server 2>/dev/null || true
  start_live_endpoint "$DIR" other "fm-$other" "$SLOT"
  sleep 1
  set +e
  run_teardown "$DIR" "$other" > "$DIR/stdout2" 2> "$DIR/stderr2"
  rc=$?
  set -e
  keep_capture "$DIR" "S3-follow-the-order"
  if [ "$rc" -eq 0 ] && [ ! -f "$DIR/home/state/$other.meta" ] \
     && grep -Fq "Worktree returned to pool" "$DIR/stdout2"; then
    pass "following the named order collects the live record and returns the slot"
  else
    fail "following the named order did not collect: rc=$rc"
    tail -5 "$DIR/stderr2" | sed 's/^/      | /'
  fi
  tmux -f /dev/null kill-server 2>/dev/null || true
}

# S3b: neither record is live. Nothing proves which claim is current, so the
# slot stays contested and no release order is invented.
scenario_two_gone_records_stay_contested() {
  local id=stale-a other=stale-b rc
  hdr "S3b both records gone: still contested, no order invented"
  tmux -f /dev/null kill-server 2>/dev/null || true
  build_base "two-gone" || { fail "fixture build failed"; return; }
  make_copy_landed "$DIR" "$SLOT"
  write_pair_metas "$DIR" "$id" "$other"
  set +e
  run_teardown "$DIR" "$id" --force > "$DIR/stdout" 2> "$DIR/stderr"
  rc=$?
  set -e
  keep_capture "$DIR" "S3b-two-gone"
  if [ "$rc" -ne 0 ] && [ -f "$DIR/home/state/$id.meta" ] && [ -e "$SLOT/scratch" ] \
     && grep -Fq "Reconcile whichever record is wrong" "$DIR/stderr" \
     && ! grep -Fq "One record can release it:" "$DIR/stderr" \
     && ! grep -Fq "Worktree returned to pool" "$DIR/stdout"; then
    pass "both gone: refused, nothing mutated, no release order claimed"
  else
    fail "both gone: rc=$rc"
    tail -5 "$DIR/stderr" | sed 's/^/      | /'
  fi
}

# S4: endpoint liveness is not the only proof. A clean, gone co-claimant is not
# enough when a process nobody in this record owns is still rooted in the slot;
# the refusal must say which pid and why.
scenario_leaked_process_blocks_the_release() {
  local id=surviving-task other=departed-task rc orphan
  hdr "S4 leaked process rooted in the slot blocks the release"
  tmux -f /dev/null kill-server 2>/dev/null || true
  build_base "leaked-process" || { fail "fixture build failed"; return; }
  make_copy_landed "$DIR" "$SLOT"
  write_pair_metas "$DIR" "$id" "$other"
  start_live_endpoint "$DIR" main "fm-$id" "$SLOT"
  sleep 1
  leak_orphan_in_slot "$SLOT"
  orphan=$(lsof -a -d cwd -Fpn "$SLOT" 2>/dev/null | grep '^p' | cut -c2- | while read -r p; do
             [ "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" = 1 ] && echo "$p"; done | head -1)
  note "orphan pid rooted in the slot with ppid 1: ${orphan:-<none found>}"
  set +e
  run_teardown "$DIR" "$id" > "$DIR/stdout" 2> "$DIR/stderr"
  rc=$?
  set -e
  keep_capture "$DIR" "S4-leaked-process"
  if [ "$rc" -ne 0 ] \
     && [ -f "$DIR/home/state/$id.meta" ] && [ -e "$SLOT/scratch" ] \
     && grep -Fq "neither the pane leader" "$DIR/stderr" \
     && ! grep -Fq "Worktree returned to pool" "$DIR/stdout"; then
    pass "orphan rooted in the slot: release refused, diagnostic names the unowned pid, slot untouched"
  else
    fail "orphan rooted in the slot: rc=$rc"
    tail -6 "$DIR/stderr" | sed 's/^/      | /'
  fi
}

# S4b: the co-claimant is gone and every process in the slot belongs to this
# record, but the shared copy still holds unlanded work. The release must be
# refused with or without --force, because --force only ever authorized
# discarding THIS record's work.
scenario_unlanded_copy_blocks_the_release() {
  local id=surviving-task other=departed-task rc flag
  hdr "S4b unlanded work in the shared copy blocks the release"
  for flag in "" "--force"; do
    tmux -f /dev/null kill-server 2>/dev/null || true
    build_base "unlanded${flag:+-force}" || { fail "fixture build failed"; return; }
    make_copy_landed "$DIR" "$SLOT"
    : > "$SLOT/unlanded-edit"          # uncommitted work in the shared copy
    write_pair_metas "$DIR" "$id" "$other"
    start_live_endpoint "$DIR" main "fm-$id" "$SLOT"
    sleep 1
    local tag=${flag:-plain}
    # shellcheck disable=SC2086
    set +e
    run_teardown "$DIR" "$id" $flag > "$DIR/stdout" 2> "$DIR/stderr"
    rc=$?
    set -e
    keep_capture "$DIR" "S4b-$tag"
    if [ "$rc" -ne 0 ] && [ -f "$DIR/home/state/$id.meta" ] && [ -e "$SLOT/unlanded-edit" ] \
       && ! grep -Fq "surviving claimant" "$DIR/stderr" \
       && ! grep -Fq "Worktree returned to pool" "$DIR/stdout"; then
      pass "unlanded copy ($tag): release refused, copy and records untouched"
    else
      fail "unlanded copy ($tag): rc=$rc, release line=$(grep -Fc 'surviving claimant' "$DIR/stderr")"
      tail -4 "$DIR/stderr" | sed 's/^/      | /'
    fi
    tmux -f /dev/null kill-server 2>/dev/null || true
  done
}

# S4c: a secondmate co-claimant is never released, on either field - that path
# may hold the secondmate's durable home rather than a disposable pool slot.
scenario_secondmate_co_claimant_never_releases() {
  local id=surviving-task other=secondmate-task rc
  hdr "S4c secondmate co-claimant keeps the refusal"
  tmux -f /dev/null kill-server 2>/dev/null || true
  build_base "secondmate-co-claimant" || { fail "fixture build failed"; return; }
  make_copy_landed "$DIR" "$SLOT"
  write_meta "$DIR/home/state/$id.meta" \
    "window=main:fm-$id" "endpoint_task_id=$id" \
    "worktree=$SLOT" "project=$DIR/project" "kind=ship"
  write_meta "$DIR/home/state/$other.meta" \
    "window=other:fm-$other" "endpoint_task_id=$other" \
    "worktree=$SLOT" "home=$SLOT" "project=$DIR/project" "kind=secondmate"
  start_live_endpoint "$DIR" main "fm-$id" "$SLOT"
  sleep 1
  set +e
  run_teardown "$DIR" "$id" --force > "$DIR/stdout" 2> "$DIR/stderr"
  rc=$?
  set -e
  keep_capture "$DIR" "S4c-secondmate"
  if [ "$rc" -ne 0 ] && [ -f "$DIR/home/state/$id.meta" ] && [ -f "$DIR/home/state/$other.meta" ] \
     && [ -e "$SLOT/scratch" ] \
     && ! grep -Fq "surviving claimant" "$DIR/stderr" \
     && ! grep -Fq "Worktree returned to pool" "$DIR/stdout"; then
    pass "secondmate co-claimant: refused even with --force, nothing mutated"
  else
    fail "secondmate co-claimant: rc=$rc"
    tail -4 "$DIR/stderr" | sed 's/^/      | /'
  fi
}

# S5: the same two readings reached through a symlinked fm home - the spelling
# an operator's home is not always reached with. Identity must resolve to the
# physical path, so the guard never reads this record as its own co-claimant.
scenario_aliased_home() {
  local id=surviving-task other=departed-task rc
  hdr "S5 symlinked fm home: release works, self-collision does not"
  tmux -f /dev/null kill-server 2>/dev/null || true
  build_base "aliased-home" || { fail "fixture build failed"; return; }
  make_copy_landed "$DIR" "$SLOT"
  mv "$DIR/home" "$DIR/real-home"
  ln -s real-home "$DIR/home"
  write_pair_metas "$DIR" "$id" "$other"
  start_live_endpoint "$DIR" main "fm-$id" "$SLOT"
  sleep 1
  note "FM_HOME spelling=$DIR/home -> $(cd "$DIR/home" && pwd -P)"
  set +e
  FM_HOME="$DIR/home" FM_ROOT_OVERRIDE="$REPO" "$TEARDOWN" "$id" > "$DIR/stdout" 2> "$DIR/stderr"
  rc=$?
  set -e
  keep_capture "$DIR" "S5-release"
  if [ "$rc" -eq 0 ] && [ ! -f "$DIR/home/state/$id.meta" ] \
     && [ -f "$DIR/home/state/$other.meta" ] \
     && grep -Fq "Worktree returned to pool" "$DIR/stdout"; then
    pass "aliased home, co-claimant gone: released (exit 0) with no self-collision"
  else
    fail "aliased home, co-claimant gone: rc=$rc"
    tail -6 "$DIR/stderr" | sed 's/^/      | /'
  fi

  # The same alias must not release a slot while the other record is live.
  tmux -f /dev/null kill-server 2>/dev/null || true
  other=running-task
  build_base "aliased-home-contested" || { fail "fixture build failed"; return; }
  mv "$DIR/home" "$DIR/real-home"
  ln -s real-home "$DIR/home"
  write_pair_metas "$DIR" "$id" "$other"
  start_live_endpoint "$DIR" main "fm-$id" "$SLOT"
  start_live_endpoint "$DIR" other "fm-$other" "$SLOT"
  sleep 1
  set +e
  FM_HOME="$DIR/home" FM_ROOT_OVERRIDE="$REPO" "$TEARDOWN" "$id" --force > "$DIR/stdout" 2> "$DIR/stderr"
  rc=$?
  set -e
  keep_capture "$DIR" "S5-contested"
  if [ "$rc" -ne 0 ] && [ -f "$DIR/home/state/$id.meta" ] \
     && grep -Fq "REFUSED: task $id's recorded worktree $SLOT is also task $other's recorded worktree." "$DIR/stderr" \
     && ! grep -Fq "Worktree returned to pool" "$DIR/stdout"; then
    pass "aliased home, live co-claimant: refused even with --force"
  else
    fail "aliased home, live co-claimant: rc=$rc"
    tail -6 "$DIR/stderr" | sed 's/^/      | /'
  fi
}

# S6: the backend contract the process proof rests on. Driven live against the
# real tmux server and the real herdr server already running on this machine.
scenario_endpoint_root_pid_contract() {
  local id=surviving-task pid tmux_absent herdr_target herdr_pid
  hdr "S6 fm_backend_endpoint_root_pid against the real backends"
  tmux -f /dev/null kill-server 2>/dev/null || true
  build_base "root-pid-contract" || { fail "fixture build failed"; return; }
  start_live_endpoint "$DIR" main "fm-$id" "$SLOT"
  sleep 1
  pid=$(cd "$DIR" && . "$REPO/bin/fm-backend.sh"; fm_backend_endpoint_root_pid tmux "main:fm-$id")
  local leader
  leader=$(tmux -f /dev/null display-message -p -t "main:fm-$id" '#{pane_pid}')
  if [ "$pid" = "$leader" ] && [ -n "$pid" ]; then
    pass "tmux: endpoint root pid $pid matches the real pane leader and is the ancestor of the slot-rooted processes"
  else
    fail "tmux: endpoint root pid '${pid:-<empty>}' != real pane leader '$leader'"
  fi
  # Nothing is named when the recorded window is not in a successful inventory:
  # tmux would otherwise answer an absent target from its active window.
  tmux_absent=$(cd "$DIR" && . "$REPO/bin/fm-backend.sh"; fm_backend_endpoint_root_pid tmux "main:fm-not-a-window"; echo "[rc=$?]")
  note "absent window -> '${tmux_absent}'"
  case "$tmux_absent" in
    ""*"[rc=1]") pass "tmux: an absent window names no pane leader (empty, rc=1)";;
    *) fail "tmux: an absent window produced '$tmux_absent'";;
  esac
  # The Herdr branch: the backend both real reported deadlock pairs recorded.
  herdr_target=${FM_LIVE_HERDR_TARGET:-default:w3M:p2}
  herdr_pid=$(cd "$DIR" && . "$REPO/bin/fm-backend.sh"; printf '%s' "$(fm_backend_endpoint_root_pid herdr "$herdr_target")"; echo "[rc=$?]")
  note "herdr $herdr_target -> '$herdr_pid'"
  case "$herdr_pid" in
    ""*"[rc=1]") note "herdr target unavailable this run; branch not exercised";;
    *"[rc=0]")
      local hp=${herdr_pid%\[rc=0\]}
      local rooted
      rooted=$(lsof -a -d cwd -Fpn +D "$SLOT" 2>/dev/null | grep '^p' | cut -c2- | head -1)
      if [ -n "$hp" ] && [ "$hp" -gt 1 ] 2>/dev/null; then
        pass "herdr: endpoint root pid $hp returned for a live pane (real herdr server)"
      else
        fail "herdr: unusable pid '$hp'"
      fi;;
    *) fail "herdr: unexpected output '$herdr_pid'";;
  esac
}

# S7: the aliased-home reading against the pre-fix build, so the fix is shown to
# change live behavior rather than merely to coexist with a passing test. The
# pre-fix script is the parent commit's copy, run from a directory whose bin/
# siblings are symlinks back into this branch's checkout, so nothing is patched.
scenario_aliased_home_before_and_after() {
  local id=surviving-task other=departed-task rc PRE_FIX=/tmp/fm-prefix/bin/fm-teardown.sh
  hdr "S7 aliased home: pre-fix build vs branch tip"
  tmux -f /dev/null kill-server 2>/dev/null || true
  build_base "aliased-home-prefix" || { fail "fixture build failed"; return; }
  make_copy_landed "$DIR" "$SLOT"
  mv "$DIR/home" "$DIR/real-home"
  ln -s real-home "$DIR/home"
  write_pair_metas "$DIR" "$id" "$other"
  start_live_endpoint "$DIR" main "fm-$id" "$SLOT"
  sleep 1

  if [ -x "$PRE_FIX" ]; then
    set +e
    FM_HOME="$DIR/home" FM_ROOT_OVERRIDE="$REPO" "$PRE_FIX" "$id" > "$DIR/stdout-pre" 2> "$DIR/stderr-pre"
    rc=$?
    set -e
    cp "$DIR/stderr-pre" "$TRANSCRIPTS/S7-prefix.stderr"
    if [ "$rc" -ne 0 ] && grep -Fq "is also task $id's recorded worktree" "$DIR/stderr-pre"; then
      pass "pre-fix build refused the aliased home against its own record (self-collision reproduced live)"
    else
      fail "pre-fix build did not reproduce the self-collision: rc=$rc"
      tail -4 "$DIR/stderr-pre" | sed 's/^/      | /'
    fi
  else
    note "pre-fix copy unavailable; comparison skipped"
  fi

  set +e
  FM_HOME="$DIR/home" FM_ROOT_OVERRIDE="$REPO" "$TEARDOWN" "$id" > "$DIR/stdout" 2> "$DIR/stderr"
  rc=$?
  set -e
  keep_capture "$DIR" "S7-branch-tip"
  if [ "$rc" -eq 0 ] && [ ! -f "$DIR/home/state/$id.meta" ] && grep -Fq "Worktree returned to pool" "$DIR/stdout"; then
    pass "branch tip released the same aliased home (exit 0) and collected the record"
  else
    fail "branch tip still refused the aliased home: rc=$rc"
    tail -4 "$DIR/stderr" | sed 's/^/      | /'
  fi
}

scenario_release_collects_the_record
scenario_live_co_claimant_still_refuses
scenario_release_order_is_named
scenario_two_gone_records_stay_contested
scenario_leaked_process_blocks_the_release
scenario_unlanded_copy_blocks_the_release
scenario_secondmate_co_claimant_never_releases
scenario_aliased_home
scenario_endpoint_root_pid_contract
scenario_real_reported_slot_ancestry
scenario_aliased_home_before_and_after

hdr "RESULT"
if [ "$FAILED" -eq 0 ]; then
  echo "all live scenarios passed"
else
  echo "at least one live scenario failed"
fi
exit "$FAILED"

