#!/usr/bin/env bash
# Live verification: crew-state-passed-mislabels-unmerged-pr
#
# Drives the REAL bin/fm-crew-state.sh against a REAL `no-mistakes axi status`
# answer read out of a REAL initialized checkout (default /Users/onyx/code/cbm-axi,
# whose checked-out branch tip is exactly the head of a completed run with
# outcome: passed and pr: https://github.com/onyx-space/cbm-axi/pull/2), and
# against the REAL merge-notification path: bin/fm-pr-poll.sh observes the real
# forge with gh, and bin/fm-merge-outcome-lib.sh publishes the merge-notified
# record exactly as bin/fm-watch.sh does.
#
# Every task's meta + merge record lives in an isolated throwaway FM home under
# $TMPDIR, so nothing in the user's real firstmate state is touched.
#
# Usage: live-verify.sh <repo-root> [<second-live-repo-root>]
set -u

REPO=${1:?usage: live-verify.sh <repo-root>}
LIVE_REPO=${2:-/Users/onyx/code/cbm-axi}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-state-live.XXXXXX")
STATE=$WORK/state
mkdir -p "$STATE"
FIXED=$REPO/bin/fm-crew-state.sh

# Two older revisions, for before/after on the same live inputs:
#   BASE  - pre-change, the released behaviour the defect report is against.
#   META1 - the first fix, which bound the merge proof to the task meta pr=
#           instead of the attributed run's own pr: (the reviewed defect).
BASE_REV=aba68fcd639320a06b80156f873dfe53aea74764
META1_REV=e40b4b4
for rev in "$BASE_REV" "$META1_REV"; do
  mkdir -p "$WORK/$rev"
  ( cd "$REPO" && git archive "$rev" bin ) | tar -x -C "$WORK/$rev" \
    || { echo "could not archive $rev"; exit 1; }
done
BASE=$WORK/$BASE_REV/bin/fm-crew-state.sh
META1=$WORK/$META1_REV/bin/fm-crew-state.sh

fail_count=0
ok()   { printf 'PASS  %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fail_count=$((fail_count + 1)); }
check_equals() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1
      expected: $2
      actual:   $3"; fi
}
check_not_contains() { # <label> <needle> <haystack>
  case "$3" in
    *"$2"*) bad "$1 (found '$2' in: $3)" ;;
    *) ok "$1" ;;
  esac
}
check_contains() { # <label> <needle> <haystack>
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 (missing '$2' in: $3)" ;;
  esac
}

crew_state() { # <script> <id> -> one state line
  FM_HOME="$WORK" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$REPO" \
    "$1" "$2"
}

write_meta() { # <id> <worktree> <pr>
  cat > "$STATE/$1.meta" <<EOF
window=fm:fm-$1
worktree=$2
kind=ship
pr=$3
EOF
}

# Publish a merge-notified record through the REAL firstmate path: the real poll
# program reads the real forge, and the outcome lib records what it observed.
record_real_merge() { # <id> <pr-url>
  local id=$1 url=$2 owner_path number observed rc
  owner_path=${url#https://github.com/}; owner_path=${owner_path%/pull/*}
  number=${url##*/}
  observed=$("$REPO/bin/fm-pr-poll.sh" --validated github "$url" github.com \
    "$owner_path" "$number" 2>/dev/null || true)
  if [ "$observed" != merged ]; then
    printf 'NOTE  %s: the real forge did not report %s as merged (poll said: %s)\n' \
      "$id" "$url" "${observed:-<nothing>}"
    return 1
  fi
  ( . "$REPO/bin/fm-merge-outcome-lib.sh"
    fm_merge_outcome_report "$WORK" "$STATE" "$id" "$url" poll ) || return 1
  rc=0
  [ -f "$STATE/$id.pr-poll-merge-notified" ] || rc=1
  # owner_path/number are used only to print what the record holds.
  printf 'NOTE  %s: merge observed on the real forge (%s/%s) and recorded via fm_merge_outcome_report\n' \
    "$id" "$owner_path" "$number"
  return "$rc"
}

printf '=== live inputs ===\n'
printf '$ no-mistakes axi status            (in %s)\n' "$LIVE_REPO"
( cd "$LIVE_REPO" && no-mistakes axi status 2>&1 | sed -n '1,8p;/^outcome:/p' )
printf '$ gh pr view %s --json state\n' "${LIVE_PR_NUMBER:-2}"
gh pr view 2 --repo onyx-space/cbm-axi --json state,url 2>&1 | head -2
printf 'branch: %s\nhead:   %s\n' \
  "$(git -C "$LIVE_REPO" branch --show-current)" "$(git -C "$LIVE_REPO" rev-parse --short HEAD)"
printf '\n'

PR_MAIN=https://github.com/onyx-space/cbm-axi/pull/2      # the live run's own PR
PR_STALE=https://github.com/onyx-space/tasks-axi/pull/1   # a different, real, merged PR
PR_STALE_REPO=/Users/onyx/code/tasks-axi

if [ -d "$PR_STALE_REPO" ]; then :; else PR_STALE_REPO=; fi

# ---------------------------------------------------------------------------
printf '=== A. terminal passed run, NO merge record: no merge may be claimed ===\n'
write_meta live-a "$LIVE_REPO" "$PR_MAIN"
printf '$ fm-crew-state.sh live-a   (fixed, this branch)\n'
a_new=$(crew_state "$FIXED" live-a); printf '%s\n' "$a_new"
printf '$ fm-crew-state.sh live-a   (base %s, before the change)\n' "${BASE_REV:0:7}"
a_old=$(crew_state "$BASE" live-a); printf '%s\n' "$a_old"
check_equals "A1 fixed: unproven merge reads held-for-merge and names the PR" \
  "state: done · source: run-step · run passed: PR held for merge: $PR_MAIN" "$a_new"
check_not_contains "A2 fixed: the line never claims a merge" "merged" "$a_new"
check_contains "A3 base revision really did mislabel a passed run (the reported defect)" \
  "run passed: PR merged/closed" "$a_old"

# ---------------------------------------------------------------------------
printf '\n=== B. same run, merge now PROVEN by the real poll -> merged may be claimed ===\n'
write_meta live-b "$LIVE_REPO" "$PR_MAIN"
if record_real_merge live-b "$PR_MAIN"; then
  printf '$ cat $STATE/live-b.pr-poll-merge-notified\n'
  sed 's/^/    /' "$STATE/live-b.pr-poll-merge-notified"
  printf '$ fm-crew-state.sh live-b   (fixed)\n'
  b_new=$(crew_state "$FIXED" live-b); printf '%s\n' "$b_new"
  check_equals "B1 a proven merge is reported as merged, naming the proved PR" \
    "state: done · source: run-step · run passed: PR merged: $PR_MAIN" "$b_new"
else
  bad "B0 could not record the real merge observation"
fi

# ---------------------------------------------------------------------------
printf '\n=== C. adversarial: task meta names another (merged) PR, the run works a different one ===\n'
write_meta live-c "$LIVE_REPO" "$PR_STALE"
if record_real_merge live-c "$PR_STALE"; then
  printf '$ fm-crew-state.sh live-c   (fixed)\n'
  c_new=$(crew_state "$FIXED" live-c); printf '%s\n' "$c_new"
  printf '$ fm-crew-state.sh live-c   (meta-first revision %s, the reviewed defect)\n' "$META1_REV"
  c_meta1=$(crew_state "$META1" live-c); printf '%s\n' "$c_meta1"
  check_equals "C1 fixed: only the run's own PR identity can be proved; a stale meta PR proves nothing" \
    "state: done · source: run-step · run passed: PR held for merge: $PR_MAIN" "$c_new"
  check_not_contains "C2 fixed: no merge claim when the run's own PR has no merge record" \
    "merged" "$c_new"
  check_not_contains "C3 fixed: the stale merged PR is never named" "tasks-axi" "$c_new"
  check_contains "C4 meta-first revision really did claim a merge for the stale meta PR (live repro of the reviewed finding)" \
    "run passed: PR merged" "$c_meta1"
else
  bad "C0 could not record the real merge observation for the stale meta PR"
fi

# ---------------------------------------------------------------------------
printf '\n=== D. adversarial: no merge record, unreadable/absent proof stays a hedge ===\n'
write_meta live-d "$LIVE_REPO" "$PR_MAIN"
: > "$STATE/live-d.pr-poll-merge-notified"      # present but empty: not proof
printf '$ fm-crew-state.sh live-d   (fixed, empty merge record)\n'
d_new=$(crew_state "$FIXED" live-d); printf '%s\n' "$d_new"
check_equals "D1 an unreadable merge record is not proof" \
  "state: done · source: run-step · run passed: PR held for merge: $PR_MAIN" "$d_new"

printf '\n=== result: %s ===\n' "$( [ "$fail_count" -eq 0 ] && echo ALL-PASS || echo "$fail_count-FAILED")"
printf 'workdir (removed): %s\n' "$WORK"
rm -rf "$WORK"
[ "$fail_count" -eq 0 ]
