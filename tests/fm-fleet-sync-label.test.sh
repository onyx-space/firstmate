#!/usr/bin/env bash
# tests/fm-fleet-sync-label.test.sh - two facts about what fm-fleet-sync.sh
# reports, measured against a real bare origin:
#   1. every verdict line names the directory the run acted on, so a reader can
#      attribute it on an endpoint holding more than one checkout of the same
#      repository;
#   2. a clone that is behind by one or by two commits and is not diverged is
#      fast-forwarded, and a second run of the same clone reports already
#      current - the positive proof that the verdict the two-clone incident
#      mistook for a lie was in fact correct.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SYNC="$ROOT/bin/fm-fleet-sync.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

# A bare origin, a clone of it, and a pusher clone that can add commits.
make_clone() {  # <name> -> echoes the clone path
  local name="$1"
  local remote="$tmp/$name.origin.git"
  local clone="$tmp/$name"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  git clone -q "$remote" "$clone"
  git -C "$clone" config user.email t@example.invalid
  git -C "$clone" config user.name t
  printf 'first\n' > "$clone/README.md"
  git -C "$clone" add -A
  git -C "$clone" commit -qm first
  git -C "$clone" branch -m main
  git -C "$clone" push -q -u origin main
  printf '%s' "$clone"
}

advance() {  # <name> <count> - add <count> commits to origin through a pusher clone
  local name="$1" count="$2" i=0
  local pusher="$tmp/$name.pusher"
  local remote="$tmp/$name.origin.git"
  git clone -q "$remote" "$pusher"
  git -C "$pusher" config user.email t@example.invalid
  git -C "$pusher" config user.name t
  while [ "$i" -lt "$count" ]; do
    i=$((i + 1))
    printf 'line %s\n' "$i" >> "$pusher/CHANGELOG.md"
    git -C "$pusher" add -A
    git -C "$pusher" commit -qm "change $i"
  done
  git -C "$pusher" push -q origin main
}

run_sync() {  # <clone> -> output on stdout, rc in $?
  FM_HOME="$tmp/fm-home" FM_PROJECTS_OVERRIDE="$tmp" "$SYNC" "$1" 2>&1
}

# 1. a clone behind by one commit is fast-forwarded, and the line names the clone.
clone=$(make_clone one)
advance one 1
out=$(run_sync "$clone") || fail "sync of a clone behind by one failed: $out"
case "$out" in *"synced"*) ;; *) fail "one commit behind was not fast-forwarded: $out" ;; esac
case "$out" in *"($clone)"*) ;; *) fail "the verdict line does not name the clone: $out" ;; esac
[ "$(git -C "$clone" rev-parse HEAD)" = "$(git -C "$clone" rev-parse origin/main)" ] || fail "clone is not at origin/main"
ok "a clone one commit behind is fast-forwarded and the line names its directory"

# 2. the second run of the same clone reports already current, still naming it.
out=$(run_sync "$clone") || fail "second sync failed: $out"
case "$out" in *"already current"*) ;; *) fail "second run did not report already current: $out" ;; esac
case "$out" in *"($clone)"*) ;; *) fail "the already-current line does not name the clone: $out" ;; esac
ok "the second run reports already current with the same attribution"

# 3. a clone behind by two commits is fast-forwarded too.
clone=$(make_clone two)
advance two 2
before=$(git -C "$clone" rev-parse --short HEAD)
out=$(run_sync "$clone") || fail "sync of a clone behind by two failed: $out"
case "$out" in *"synced $before.."*) ;; *) fail "two commits behind was not fast-forwarded: $out" ;; esac
[ "$(git -C "$clone" rev-list --count HEAD..origin/main)" = 0 ] || fail "clone still behind after the run"
ok "a clone two commits behind is fast-forwarded, and the verdict is not already current"

printf 'ok\n'
