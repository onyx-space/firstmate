#!/usr/bin/env bash
# tests/fm-cd-self-update.test.sh - the CD chain's contract: one bounded action
# per event, a smoke run that asserts each of the four facts separately, a
# rollback limited to this run's own commits and a clean tree, and a failure
# record. The Pi under test is a fake, so no real session starts here.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHAIN="$ROOT/bin/fm-cd-self-update.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

# A throwaway home shaped like the real one: its own git repository with a bare
# origin it can fast-forward from, the chain script under bin/, the two project
# extensions, and state/.
new_home() {  # <name> -> echoes the home path
  local home="$tmp/$1" remote="$tmp/$1.origin.git"
  mkdir -p "$home/bin" "$home/.pi/extensions" "$home/state"
  cp "$CHAIN" "$home/bin/fm-cd-self-update.sh"
  chmod +x "$home/bin/fm-cd-self-update.sh"
  printf 'export const x = 1;\n' > "$home/.pi/extensions/fm-primary-turnend-guard.ts"
  printf 'export const y = 1;\n' > "$home/.pi/extensions/fm-primary-pi-watch.ts"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  git -C "$home" init -q
  git -C "$home" config user.email t@example.invalid
  git -C "$home" config user.name t
  git -C "$home" add -A
  git -C "$home" commit -qm init
  git -C "$home" branch -m main
  git -C "$home" remote add origin "$remote"
  git -C "$home" push -q origin main
  printf '%s' "$home"
}

# One commit pushed to the home's origin by a second clone, so the next chain run
# has a real fast-forward to make.
advance_origin() {  # <name>
  local home="$tmp/$1" remote="$tmp/$1.origin.git" work="$tmp/$1.pusher"
  git clone -q "$remote" "$work"
  git -C "$work" config user.email t@example.invalid
  git -C "$work" config user.name t
  printf 'changelog\n' > "$work/CHANGELOG.md"
  git -C "$work" add -A
  git -C "$work" commit -qm second
  git -C "$work" push -q origin main
}

# A fake Pi that answers whatever the case under test needs.
fake_pi() {  # <path> <stdout text> <exit code>
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\nexit %s\n' "$2" "$3" > "$1"
  chmod +x "$1"
}

run_chain() {  # <home> <fake pi> -> rc on stdout, output in $tmp/out
  FM_CD_PI="$2" FM_CD_SMOKE_TIMEOUT=10 "$1/bin/fm-cd-self-update.sh" --reason test > "$tmp/out" 2>&1
  printf '%s' "$?"
}

# 1. a clean fake Pi: the chain reports success and every stage, and it carries
#    the home across a real fast-forward.
home=$(new_home happy); fake_pi "$tmp/pi-ok" OK 0
before=$(git -C "$home" rev-parse HEAD)
advance_origin happy
rc=$(run_chain "$home" "$tmp/pi-ok")
[ "$rc" = 0 ] || fail "happy path exited $rc: $(cat "$tmp/out")"
grep -q "pull: fast-forwarded" "$tmp/out" || fail "happy path did not fast-forward: $(cat "$tmp/out")"
[ "$(git -C "$home" rev-parse HEAD)" != "$before" ] || fail "the home did not move to the new commit"
[ "$(git -C "$home" rev-parse HEAD)" = "$(git -C "$home" rev-parse origin/main)" ] || fail "the home is not at origin/main"
grep -q "install:" "$tmp/out" || fail "happy path printed no install line"
grep -q "smoke: .*answered OK" "$tmp/out" || fail "happy path printed no smoke line"
ok "a clean Pi run fast-forwards, reports pull, install and smoke, and exits 0"

# 2. each of the four smoke facts fails the chain on its own.
while IFS=: read -r label text code; do
  home=$(new_home "bad-$label"); fake_pi "$tmp/pi-$label" "$text" "$code"
  rc=$(run_chain "$home" "$tmp/pi-$label")
  [ "$rc" != 0 ] || fail "$label: chain exited 0"
  grep -q "ALARM" "$tmp/out" || fail "$label: no alarm line"
  grep -q "fm-cd-failures.log" "$tmp/out" || fail "$label: no failure record named"
  [ -f "$home/state/fm-cd-failures.log" ] || fail "$label: failure record missing"
  git -C "$home" diff --quiet HEAD -- ':!state' 2>/dev/null || fail "$label: the run changed tracked content"
  ok "$label fails the chain with an alarm and a recorded failure"
done <<'CASES'
nonzero-exit:OK:3
carries-error:Error: boom:0
carries-warning:Warning: slow:0
missing-ok:all good:0
CASES

# 3. a failing run leaves the checkout at the head it started from.
home=$(new_home rollback); fake_pi "$tmp/pi-bad" "Error: boom" 0
before=$(git -C "$home" rev-parse HEAD)
run_chain "$home" "$tmp/pi-bad" >/dev/null
after=$(git -C "$home" rev-parse HEAD)
[ "$before" = "$after" ] || fail "rollback moved HEAD from $before to $after"
ok "a failed run leaves the checkout at its starting head"

# 4. an executable-bit mismatch on a git-recorded 100755 file is repaired, and a
#    100644 library is left alone (the mistake that would dirty the tree).
home=$(new_home modes)
mkdir -p "$home/bin"
printf '#!/usr/bin/env bash\ntrue\n' > "$home/bin/fm-entry.sh"
printf '#!/usr/bin/env bash\ntrue\n' > "$home/bin/fm-lib.sh"
git -C "$home" add -A
git -C "$home" update-index --chmod=+x bin/fm-entry.sh
git -C "$home" update-index --chmod=-x bin/fm-lib.sh
git -C "$home" commit -qm modes
chmod -x "$home/bin/fm-entry.sh"
fake_pi "$tmp/pi-ok2" OK 0
FM_CD_PI="$tmp/pi-ok2" FM_CD_SMOKE_TIMEOUT=10 "$home/bin/fm-cd-self-update.sh" > "$tmp/out" 2>&1 || fail "modes run failed: $(cat "$tmp/out")"
[ -x "$home/bin/fm-entry.sh" ] || fail "the 100755 entry point was not repaired"
[ ! -x "$home/bin/fm-lib.sh" ] || fail "a 100644 library was made executable"
git -C "$home" diff --quiet HEAD -- ':!state' 2>/dev/null || fail "the install stage changed tracked content"
ok "install repairs only what git records as executable and leaves the tree clean"

printf 'ok\n'
