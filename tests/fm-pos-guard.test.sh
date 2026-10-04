#!/usr/bin/env bash
# tests/fm-pos-guard.test.sh - a missing positional argument reads as a usage
# error, never as a shell's unbound-variable error or a bare `cd` failure.
#
# The incident: `fm-brief.sh <id> --scout` without its repo died with
# `POS[1]: unbound variable`, and `fm-spawn.sh <id> --scout --harness pi` without
# its project died the same way and then, once a bare name was passed, with
# `cd: firstmate: No such file or directory`. Both read like a broken script
# rather than a wrong call, which is the shape this suite pins.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

# 1. fm-brief.sh without its repo: a named argument, the usage, and a nonzero exit.
out=$(FM_HOME="$tmp/home" "$ROOT/bin/fm-brief.sh" some-task --scout 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "fm-brief.sh accepted a missing <repo-name> (rc=$rc)"
case "$out" in *"unbound variable"*) fail "fm-brief.sh still dies on an unbound variable: $out" ;; esac
case "$out" in *"<repo-name>"*) ;; *) fail "fm-brief.sh did not name the missing argument: $out" ;; esac
case "$out" in *"Usage:"*) ;; *) fail "fm-brief.sh printed no usage: $out" ;; esac
ok "a missing <repo-name> names the argument and prints the usage"

# 2. fm-brief.sh without its task id behaves the same way.
out=$(FM_HOME="$tmp/home" "$ROOT/bin/fm-brief.sh" 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "fm-brief.sh accepted a missing <task-id> (rc=$rc)"
case "$out" in *"<task-id>"*) ;; *) fail "fm-brief.sh did not name the missing task id: $out" ;; esac
ok "a missing <task-id> names the argument"

# 3. fm-spawn.sh without its project dir: named, nonzero, no unbound variable.
out=$(FM_HOME="$tmp/home" "$ROOT/bin/fm-spawn.sh" some-task --scout 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "fm-spawn.sh accepted a missing <project-dir> (rc=$rc)"
case "$out" in *"unbound variable"*) fail "fm-spawn.sh still dies on an unbound variable: $out" ;; esac
case "$out" in *"<project-dir>"*) ;; *) fail "fm-spawn.sh did not name the missing argument: $out" ;; esac
ok "a missing <project-dir> names the argument"

# 4. fm-spawn.sh given a bare name that is not a directory: the refusal names the
#    path expectation instead of a `cd` failure, and nothing is created.
out=$(FM_HOME="$tmp/home" "$ROOT/bin/fm-spawn.sh" some-task definitely-not-here --scout 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "fm-spawn.sh accepted a nonexistent <project-dir> (rc=$rc)"
case "$out" in *"<project-dir>"*) ;; *) fail "fm-spawn.sh did not name the argument: $out" ;; esac
case "$out" in *"existing directory"*) ;; *) fail "fm-spawn.sh did not state the path expectation: $out" ;; esac
case "$out" in *"cd: "*) fail "fm-spawn.sh still fails through a bare cd: $out" ;; esac
[ ! -e "$tmp/home/projects/definitely-not-here" ] || fail "the refusal created a project directory"
ok "a bare name is refused by name, without a cd failure and without side effects"

# 5. the usage states that <project-dir> is a directory.
"$ROOT/bin/fm-spawn.sh" --help > "$tmp/help" 2>&1 || true
grep -q "existing directory" "$tmp/help" || fail "the usage does not describe <project-dir> as a directory"
ok "the usage describes <project-dir> as an existing directory"

printf 'ok\n'
