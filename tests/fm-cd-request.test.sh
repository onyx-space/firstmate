#!/usr/bin/env bash
# tests/fm-cd-request.test.sh - the CD request writer: the shape it lands, the
# atomic landing, the merged-only rule, and the refusals that keep a malformed
# event from installing anything.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WRITER="$ROOT/bin/fm-cd-request.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

req="$tmp/deploy/request.json"

# 1. a merged event lands exactly the fleet's request shape.
"$WRITER" --event merged --repository onyx-space/firstmate --pr 45 \
  --asked-by firstmate@server --path "$req" > "$tmp/out" 2>&1 || fail "merged write failed: $(cat "$tmp/out")"
[ -f "$req" ] || fail "no request file written"
keys=$(python3 -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1])))))' "$req")
[ "$keys" = "asked_by,at,pr,repository" ] || fail "unexpected keys: $keys"
pr=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pr"])' "$req")
[ "$pr" = 45 ] || fail "unexpected pr: $pr"
ok "a merged event lands {repository, pr, asked_by, at}"

# 2. it lands atomically: no temporary file is left beside it.
leftovers=$(find "$tmp/deploy" -maxdepth 1 -name '.request.*' | wc -l)
[ "$leftovers" -eq 0 ] || fail "temporary files left behind: $leftovers"
ok "the request lands by rename and leaves no temporary file"

# 3. a commit-id request carries commit instead of pr.
req2="$tmp/deploy/commit.json"
"$WRITER" --event merged --repository onyx-space/firstmate --commit 645b6a16 \
  --asked-by firstmate@server --path "$req2" > /dev/null 2>&1 || fail "commit write failed"
keys=$(python3 -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1])))))' "$req2")
[ "$keys" = "asked_by,at,commit,repository" ] || fail "unexpected keys for a commit request: $keys"
ok "a commit event carries commit rather than pr"

# 4. every refusal: not a merge, both addresses, neither, a malformed commit.
refuse() {  # <label> <args...>
  local label="$1"; shift
  local target="$tmp/refused-$label.json"
  if "$WRITER" "$@" --path "$target" > "$tmp/out" 2>&1; then
    fail "$label: the writer accepted it"
  fi
  [ ! -f "$target" ] || fail "$label: a file was written anyway"
  grep -q "refused" "$tmp/out" || fail "$label: refusal was not named"
}
refuse closed --event closed --repository onyx-space/firstmate --pr 40
refuse both --event merged --repository onyx-space/firstmate --pr 45 --commit 645b6a16
refuse neither --event merged --repository onyx-space/firstmate
refuse badcommit --event merged --repository onyx-space/firstmate --commit NOT-HEX
refuse badpr --event merged --repository onyx-space/firstmate --pr 4.5
ok "a non-merge event, both addresses, neither address, and malformed ids are refused by name and write nothing"

# 5. the dry run writes nothing.
"$WRITER" --event merged --repository onyx-space/firstmate --pr 45 --path "$tmp/dry/request.json" --dry-run > /dev/null 2>&1 || fail "dry-run failed"
[ ! -e "$tmp/dry/request.json" ] || fail "dry-run wrote a file"
ok "the dry run writes nothing"

printf 'ok\n'
