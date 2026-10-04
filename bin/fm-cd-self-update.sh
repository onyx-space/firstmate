#!/usr/bin/env bash
# One bounded action that brings this firstmate home to the latest origin/main and
# proves the home still starts Pi without errors.
#
# The chain stops at "installed locally and Pi starts with no error"; restarting
# supervision and taking a session over stay the captain's own actions, so this
# script never arms a watcher, never claims the fleet lock, and never touches a
# running session.
#
# It is one action per event, not a daemon: a doorbell (a merged pull request
# reported to this home) invokes it once. Running it again with nothing new is a
# no-op that says so, so a replayed event or a second caller costs nothing.
#
# Stages, in order, all bounded:
#   1. pull      - fast-forward this home's default branch from origin under the
#                  guarded fast-forward rule (default branch, clean tree, a real
#                  fast-forward). bin/fm-ff-lib.sh owns that rule for the other
#                  sync paths; this stage keeps its own copy because the chain's
#                  untracked launch artifacts must not count as dirty and an
#                  unreachable origin or a failed advance is an alarm here, not a
#                  skip. Keep the two copies in step.
#   2. install   - put the tracked launch surfaces in place: executable bits on
#                  bin/*.sh, the CLAUDE.md pointer to AGENTS.md, the
#                  .claude/skills symlink, and the two project extensions' presence.
#                  Nothing under data/ state/ config/ projects/ .no-mistakes/ is
#                  touched, so a fast-forward never disturbs in-flight work.
#   3. smoke     - start Pi once in this home under a bounded timeout and assert
#                  the four facts the fleet's user-extension chain asserts: exit 0,
#                  no "Error:", no "Warning:", and the expected reply. One run,
#                  no lock, no watcher.
#   4. rollback  - on any failure, return the checkout to the head recorded before
#                  stage 1 (only within the commits this run moved, only with a
#                  clean tree), and write an alarm record.
#   5. report    - one line per stage per machine on stdout, plus one record under
#                  state/, so a caller sees what happened instead of a summary.
#
# Usage: fm-cd-self-update.sh [--reason <text>] [--repo <owner/name>] [--dry-run] [--help]
#   --reason  what invoked this run; recorded verbatim, never interpreted
#   --repo    the repository the event was about, recorded verbatim
#   --dry-run print the resolved plan and exit 0 without changing anything
#   --help    print this header
#
# Environment:
#   FM_CD_SMOKE_TIMEOUT   seconds the smoke run may take (default 90)
#   FM_CD_PI              Pi executable to smoke (default: pi from PATH)
#   FM_CD_SMOKE_LOG       where each attempt is appended (default state/fm-cd-smoke.log)
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SELF_DIR/fm-timeout-lib.sh"
STATE="$ROOT/state"
SMOKE_TIMEOUT="${FM_CD_SMOKE_TIMEOUT:-90}"
case "$SMOKE_TIMEOUT" in ''|*[!0-9]*|0) SMOKE_TIMEOUT=90 ;; esac
PI_BIN="${FM_CD_PI:-pi}"
SMOKE_LOG="${FM_CD_SMOKE_LOG:-$STATE/fm-cd-smoke.log}"
DEFAULT_BRANCH="${FM_CD_DEFAULT_BRANCH:-main}"
REASON=""
REPO=""
DRY_RUN=no

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -n 's/^# \{0,1\}//p' | sed '$d'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason) [ "$#" -ge 2 ] || { echo "fm-cd-self-update: --reason needs a value" >&2; usage >&2; exit 2; }; REASON="$2"; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || { echo "fm-cd-self-update: --repo needs a value" >&2; usage >&2; exit 2; }; REPO="$2"; shift 2 ;;
    --dry-run) DRY_RUN=yes; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "fm-cd-self-update: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say() { printf 'fm-cd: %s\n' "$*"; }
alarm() { printf 'fm-cd: ALARM %s\n' "$*" >&2; }

clean_tree() {
  # The install stage may create the CLAUDE.md pointer and the .claude/skills
  # link, and every run writes its own records under state/; those are this
  # chain's own artifacts, so they must not block the gates this function serves.
  # Everything else counts, including work a person left in the checkout.
  [ -z "$(git -C "$ROOT" status --porcelain -- . \
    ':(exclude)CLAUDE.md' ':(exclude).claude' ':(exclude).claude/**' \
    ':(exclude)state' ':(exclude)state/**' 2>/dev/null)" ]
}
head_now() { git -C "$ROOT" rev-parse HEAD 2>/dev/null; }

mkdir -p "$STATE"
BEFORE="$(head_now)" || { alarm "cannot read HEAD in $ROOT"; exit 1; }
BEFORE_SHORT="$(git -C "$ROOT" rev-parse --short "$BEFORE")"

say "home $ROOT at $BEFORE_SHORT${REASON:+ (reason: $REASON)}${REPO:+ (repo: $REPO)}"
if [ "$DRY_RUN" = yes ]; then
  say "dry-run: would fetch origin $DEFAULT_BRANCH, fast-forward when clean, install tracked launch surfaces, smoke $PI_BIN with a ${SMOKE_TIMEOUT}s bound, and roll back to $BEFORE_SHORT on failure"
  exit 0
fi

# ---------------------------------------------------------------- 1. pull
pull_stage() {
  local branch
  branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$branch" != "$DEFAULT_BRANCH" ]; then
    say "pull: skipped: on $branch, expected $DEFAULT_BRANCH"
    return 0
  fi
  if ! clean_tree; then
    say "pull: skipped: uncommitted changes in this home"
    return 0
  fi
  if ! git -C "$ROOT" fetch --quiet origin "$DEFAULT_BRANCH" 2>/dev/null; then
    alarm "pull: fetch from origin failed"
    return 1
  fi
  local remote="origin/$DEFAULT_BRANCH"
  if [ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse "$remote")" ]; then
    say "pull: already current at $(git -C "$ROOT" rev-parse --short HEAD)"
    return 0
  fi
  if ! git -C "$ROOT" merge-base --is-ancestor HEAD "$remote" 2>/dev/null; then
    say "pull: skipped: $remote is not ahead of HEAD (diverged)"
    return 0
  fi
  if ! git -C "$ROOT" merge --ff-only "$remote" >/dev/null 2>&1; then
    alarm "pull: fast-forward to $remote failed"
    return 1
  fi
  say "pull: fast-forwarded $(git -C "$ROOT" rev-parse --short "$BEFORE")..$(git -C "$ROOT" rev-parse --short HEAD)"
  return 0
}

# ------------------------------------------------------------- 2. install
install_stage() {
  # Only the files git records as executable (mode 100755) are meant to run, so
  # only those are repaired; the 100644 entries are libraries meant to be sourced,
  # and setting a bit on one of them would dirty the tree this stage keeps clean.
  local rc=0 mode path line
  local listing
  # --format keeps the mode and the path apart without parsing git's tab-separated
  # record; a path holding a space is deferred: none exists in this repository.
  listing="$(git -C "$ROOT" ls-files --format='%(objectmode) %(path)' 'bin/*.sh' 2>/dev/null)" || listing=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mode=${line%% *}
    path=${line#* }
    case "$mode" in 100755) ;; *) continue ;; esac
    [ -f "$ROOT/$path" ] || continue
    if [ ! -x "$ROOT/$path" ]; then
      chmod +x "$ROOT/$path" || { alarm "install: cannot repair the executable bit on $path"; rc=1; continue; }
      say "install: repaired the executable bit on $path (git records 100755)"
    fi
  done <<EOF_MODE
$listing
EOF_MODE
  if [ ! -e "$ROOT/CLAUDE.md" ]; then
    if printf '@AGENTS.md\n' > "$ROOT/CLAUDE.md"; then
      say "install: wrote the CLAUDE.md pointer"
    else
      alarm "install: cannot write CLAUDE.md"
      rc=1
    fi
  fi
  if [ ! -e "$ROOT/.claude/skills" ]; then
    if mkdir -p "$ROOT/.claude" && ln -sfn ../.agents/skills "$ROOT/.claude/skills"; then
      say "install: relinked .claude/skills"
    else
      alarm "install: cannot link .claude/skills"
      rc=1
    fi
  fi
  for f in "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ROOT/.pi/extensions/fm-primary-pi-watch.ts"; do
    if [ ! -r "$f" ]; then alarm "install: missing project extension $(basename "$f")"; rc=1; fi
  done
  [ "$rc" -eq 0 ] && say "install: tracked launch surfaces in place"
  return "$rc"
}

# --------------------------------------------------------------- 3. smoke
smoke_stage() {
  if ! command -v "$PI_BIN" >/dev/null 2>&1; then
    alarm "smoke: $PI_BIN is not on PATH"
    return 1
  fi
  local out rc=0
  out="$(cd "$ROOT" && fm_run_timed "$SMOKE_TIMEOUT" "$PI_BIN" -p "reply with OK" --no-session < /dev/null 2>&1)" || rc=$?
  {
    printf '=== %s rc=%s head=%s\n' "$(date -u +%FT%TZ)" "$rc" "$(git -C "$ROOT" rev-parse --short HEAD)"
    printf '%s\n' "$out"
  } >> "$SMOKE_LOG"
  if [ "$rc" -ne 0 ]; then alarm "smoke: $PI_BIN exited $rc"; return 1; fi
  case "$out" in *"Error:"*) alarm "smoke: output carries an Error:"; return 1 ;; esac
  case "$out" in *"Warning:"*) alarm "smoke: output carries a Warning:"; return 1 ;; esac
  if ! printf '%s\n' "$out" | grep -qx 'OK'; then alarm "smoke: reply did not carry an OK line"; return 1; fi
  say "smoke: $PI_BIN started clean and answered OK (head $(git -C "$ROOT" rev-parse --short HEAD))"
  return 0
}

# ------------------------------------------------------------ 4. rollback
rollback() {
  local after
  after="$(head_now)"
  if [ "$after" = "$BEFORE" ]; then
    say "rollback: nothing to undo, still at $BEFORE_SHORT"
    return 0
  fi
  if ! clean_tree; then
    alarm "rollback: refused: this home has uncommitted changes; left at $(git -C "$ROOT" rev-parse --short "$after")"
    return 1
  fi
  if git -C "$ROOT" reset --keep "$BEFORE" >/dev/null 2>&1; then
    say "rollback: returned to $BEFORE_SHORT"
    return 0
  fi
  alarm "rollback: reset --keep $BEFORE_SHORT failed"
  return 1
}

result=ok
if ! pull_stage; then result=failed; fi
if [ "$result" = ok ] && ! install_stage; then result=failed; fi
if [ "$result" = ok ] && ! smoke_stage; then result=failed; fi
if [ "$result" != ok ]; then
  rollback || true
  {
    printf '%s\tfailed\thead=%s\tbefore=%s\treason=%s\trepo=%s\n' \
      "$(date -u +%FT%TZ)" "$(git -C "$ROOT" rev-parse --short HEAD)" "$BEFORE_SHORT" "${REASON:-none}" "${REPO:-none}"
  } >> "$STATE/fm-cd-failures.log"
  alarm "chain failed; see $STATE/fm-cd-failures.log"
  exit 1
fi

say "done: head $(git -C "$ROOT" rev-parse --short HEAD), smoke clean"
exit 0
