#!/usr/bin/env bash
# Live evidence driver for the keyless-supersede change.
# Drives the REAL bin/fm-wake-drain.sh (the product surface) and the REAL
# bin/fm-classify-lib.sh span-scan entry points over crafted status logs in an
# isolated state directory. Prints a transcript; the transcript is the artifact.
set -u

WT=/home/onyx/.no-mistakes/worktrees/e7f71fdfbe8f/01M42APR2848K68GRK0D6WY7S5
EVID=/home/onyx/.no-mistakes/evidence/01M42APR2848K68GRK0D6WY7S5
DRAIN="$WT/bin/fm-wake-drain.sh"

# shellcheck source=tests/wake-helpers.sh
. "$WT/tests/wake-helpers.sh"
TMP_ROOT="$EVID/live-state"
rm -rf "$TMP_ROOT"
mkdir -p "$TMP_ROOT"

hr() { printf '%s\n' "------------------------------------------------------------------------"; }

run_drain() {  # <case> <label>
  local case=$1 label=$2 dir state out rc
  dir=$(make_case "$case")
  state="$dir/state"
  out="$dir/drain.out"
  cp "$EVID/fixture.status" "$state/task1.status" 2>/dev/null || true
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>"$dir/drain.err"
  rc=$?
  printf '\n### %s\n' "$label"
  printf '$ cat state/task1.status\n'
  sed 's/^/    /' "$state/task1.status"
  printf '$ FM_STATE_OVERRIDE=state bin/fm-wake-drain.sh   (exit=%s)\n' "$rc"
  if [ -s "$out" ]; then sed 's/^/    | /' "$out"; else printf '    (no output)\n'; fi
  printf 'OPEN DECISIONS printed? '
  if grep -qF 'OPEN DECISIONS' "$out"; then printf 'YES\n'; else printf 'no\n'; fi
}

hr
printf 'Scenario 1: exact reported sequence (keyed decision, keyless blocked,\n'
printf 'keyed resolved, task paused). Before the fix the drain listed the\n'
printf 'keyless blocker on every wake.\n'
hr
cat > "$EVID/fixture.status" <<'EOF'
needs-decision [key=dsh-search-cleanup-approval]: approve the cleanup
blocked: dsh-search - w unreachable, remote delete paused
resolved [key=dsh-search-cleanup-approval]: approved, executed
paused: dsh-search cleanup complete
EOF
run_drain s1-exact "reported sequence"

hr
printf 'Scenario 2 (guard): the same keyless blocker with NO later terminal line\n'
printf 'must still be listed - the rule is a supersede, not a blanket suppression.\n'
hr
cat > "$EVID/fixture.status" <<'EOF'
blocked: waiting on the forge
working: polling the forge
EOF
run_drain s2-still-open "keyless blocker, no terminal line"

hr
printf 'Scenario 3 (guard): a later unrelated terminal line must NOT clear a KEYED\n'
printf 'open decision - keyed pairing/closing semantics unchanged.\n'
hr
cat > "$EVID/fixture.status" <<'EOF'
needs-decision [key=api-shape]: pick REST or RPC
done: unrelated later milestone
EOF
run_drain s3-keyed-survives "keyed decision + unrelated done"

hr
printf 'Scenario 4: keyless needs-decision (not only blocked) superseded by done,\n'
printf 'and by failed - both terminal verbs shared with status_is_terminal_verb.\n'
hr
cat > "$EVID/fixture.status" <<'EOF'
needs-decision: choose a release target
done: shipped the release
EOF
run_drain s4a-keyless-nd-done "keyless needs-decision + done"
cat > "$EVID/fixture.status" <<'EOF'
blocked: waiting on the forge
failed: the forge never came back
EOF
run_drain s4b-keyless-blocked-failed "keyless blocked + failed"

hr
printf 'Scenario 5 (adversarial): a fresh keyless decision raised AFTER a terminal\n'
printf 'line is a NEW decision and must list again.\n'
hr
cat > "$EVID/fixture.status" <<'EOF'
blocked: first wait
paused: first wait cleared
blocked: the forge went down again
EOF
run_drain s5-reopen "keyless reopen after a pause"

hr
printf 'Scenario 6: span-scan consistency (the watcher/daemon path). The bounded\n'
printf 'span scan must agree with the whole-file fold on the reported sequence.\n'
hr
span_dir="$TMP_ROOT/span"
mkdir -p "$span_dir"
cat > "$span_dir/reported.status" <<'EOF'
needs-decision [key=dsh-search-cleanup-approval]: approve the cleanup
blocked: dsh-search - w unreachable, remote delete paused
resolved [key=dsh-search-cleanup-approval]: approved, executed
paused: dsh-search cleanup complete
EOF
cat > "$span_dir/keyed.status" <<'EOF'
needs-decision [key=api-shape]: pick REST or RPC
done: unrelated later milestone
EOF
for f in reported keyed; do
  rec=$(bash -c '. "$1"; status_span_first_actionable "$2"' _ "$WT/bin/fm-classify-lib.sh" "$span_dir/$f.status")
  rc=$?
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ "$WT/bin/fm-classify-lib.sh" "$span_dir/$f.status")
  printf '\n$ _fm span scan on %s.status (start offset 0)\n' "$f"
  printf '    rc=%s  actionable_record=%q\n' "$rc" "$rec"
  printf '    whole-file fold lists=%q\n' "$open"
done
printf '\nExpected: reported -> rc=1 and no fold record; keyed -> rc=0 naming the\n'
printf 'api-shape decision while the keyless default record stays retired.\n'

hr
printf 'Scenario 7: persisted span-scan cursor migration. A cursor written under\n'
printf 'the previous scanner version (2) must be discarded and the span rebuilt,\n'
printf 'not trusted with a stale live keyless origin.\n'
hr
mig_dir="$TMP_ROOT/migrate"
mkdir -p "$mig_dir"
cat > "$mig_dir/status.status" <<'EOF'
blocked: dsh-search - w unreachable, remote delete paused
paused: dsh-search cleanup complete
EOF
ident=$(bash -c '. "$1"; _fm_open_decisions_file_ident "$2"' _ "$WT/bin/fm-classify-lib.sh" "$mig_dir/status.status")
size=$(wc -c < "$mig_dir/status.status" | tr -d ' ')
cursor="$mig_dir/.status.span-scan-cursor.0"
{
  printf 'version=2\n'
  printf 'ident=%s\n' "$ident"
  printf 'start=0\n'
  printf 'size=%s\n' "$size"
  printf 'line=1\n'
  printf 'nd=0\n'
  printf 'ndp=0\n'
  printf 'o\tdefault\tblocked\t%s\n' 'dsh-search - w unreachable, remote delete paused'
  printf 'p\tdefault\t1\n'
  printf 'e\tD\tdefault\t1\tblocked\tblocked: dsh-search - w unreachable, remote delete paused\n'
} > "$cursor"
printf '$ pre-fix cursor:\n'
sed 's/^/    /' "$cursor"
rec=$(bash -c '. "$1"; status_span_first_actionable "$2" 0' _ "$WT/bin/fm-classify-lib.sh" "$mig_dir/status.status")
rc=$?
printf '$ span scan with that pre-fix cursor present: rc=%s record=%q\n' "$rc" "$rec"
printf '$ cursor after the scan (must be gone: the scan completed from a rebuild):\n'
if [ -e "$cursor" ]; then sed 's/^/    /' "$cursor"; else printf '    (no cursor left)\n'; fi
printf 'Expected: rc=1, no actionable record - the version bump forced a rebuild\n'
printf 'that saw the later pause supersede the keyless blocker.\n'

hr
printf 'DONE\n'
