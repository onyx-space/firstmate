#!/usr/bin/env bash
# tests/fm-inbox-config-path.test.sh - the captain-inbox collector follows its
# tool's own name: with no FM_WIRE_CONFIG in the environment, bin/fm-inbox.sh
# resolves $XDG_CONFIG_HOME/olink/config.json, or ~/.config/olink/config.json
# when XDG_CONFIG_HOME is unset, and never a literal wire path. It also works
# while ~/.config/wire is only the transitional symlink onto ~/.config/olink.
# The variable NAME stays FM_WIRE_CONFIG (renaming it would reach call sites
# this change deliberately does not touch); this suite pins the default, not
# the name.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# bin/fm-inbox.sh is a subcommand dispatcher, so its prologue cannot be sourced
# whole. The default line itself is lifted verbatim from the script and
# evaluated, so this suite exercises the shipped line rather than a copy of it.
resolve() {  # <home> [<xdg-config-home>] [<explicit-FM_WIRE_CONFIG>] -> path
  local home=$1 xdg=${2:-} explicit=${3:-} line
  line=$(grep -m1 '^FM_WIRE_CONFIG=' "$ROOT/bin/fm-inbox.sh")
  [ -n "$line" ] || fail 'no FM_WIRE_CONFIG default line in bin/fm-inbox.sh'
  HOME="$home" XDG_CONFIG_HOME="$xdg" FM_WIRE_CONFIG="$explicit" \
    bash -c 'set -u
      if [ -n "${FM_WIRE_CONFIG:-}" ]; then export FM_WIRE_CONFIG; else unset FM_WIRE_CONFIG; fi
      eval "$1"
      printf "%s" "$FM_WIRE_CONFIG"' _ "$line"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 1. olink config present, no wire path at all: the olink file is the default.
mkdir -p "$tmp/a/.config/olink"
printf '{"endpoints":{}}\n' > "$tmp/a/.config/olink/config.json"
got=$(resolve "$tmp/a")
[ "$got" = "$tmp/a/.config/olink/config.json" ] || fail "case 1 resolved '$got'"
[ -r "$got" ] || fail 'case 1 resolved path is not readable'

# 2. today's layout: ~/.config/wire is the transitional symlink onto olink.
mkdir -p "$tmp/b/.config/olink"
printf '{"endpoints":{"h":{"sessions":{}}}}\n' > "$tmp/b/.config/olink/config.json"
ln -s "$tmp/b/.config/olink" "$tmp/b/.config/wire"
got=$(resolve "$tmp/b")
[ "$got" = "$tmp/b/.config/olink/config.json" ] || fail "case 2 resolved '$got'"
grep -q sessions "$got" || fail 'case 2: reading the resolved path misses the olink contents'

# 3. XDG_CONFIG_HOME is honoured.
mkdir -p "$tmp/c/xdg/olink"
printf '{"endpoints":{}}\n' > "$tmp/c/xdg/olink/config.json"
got=$(resolve "$tmp/c" "$tmp/c/xdg")
[ "$got" = "$tmp/c/xdg/olink/config.json" ] || fail "case 3 resolved '$got'"

# 4. an explicit FM_WIRE_CONFIG still wins, and the name is unchanged.
got=$(resolve "$tmp/c" '' /explicit/config.json)
[ "$got" = /explicit/config.json ] || fail "case 4 explicit override lost: '$got'"

# 5. no literal wire config path survives in the script.
if grep -q 'config/wire' "$ROOT/bin/fm-inbox.sh"; then
  fail 'a literal wire config path survives in bin/fm-inbox.sh'
fi

printf 'ok\n'
