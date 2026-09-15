#!/usr/bin/env bash
# Reproduce: a scout brief scaffolded by bin/fm-brief.sh --scout keeps its
# scout-time "# Remote repository authority" sentence after bin/fm-promote.sh
# promotes the task to a PR-opening ship mode. Promotion never re-renders the
# brief, so the promoted worker holds both
#   "This task pushes to no remote and opens no PR"   (original brief)
# and "Completion for mode=no-mistakes is a PR..." / "push your branch and open
# a PR" (ship-instructions.md), the exact contradiction class this change's
# role rendering removed from the scaffold-time briefs.
#
# Usage: reproduce-promoted-scout-contradiction.sh <path-to-firstmate-checkout>
set -eu

ROOT=${1:?usage: $0 <firstmate checkout>}
P=$(mktemp -d /tmp/fm-promote-repro-XXXXXX)
H="$P/home"
mkdir -p "$H/state" "$H/data"

FM_HOME="$H" "$ROOT/bin/fm-brief.sh" scout-p1 some-proj --scout >/dev/null
python3 - "$H/data/scout-p1/brief.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('{TASK}', 'Investigate the PR target.').replace(
    '{FIRSTMATE_SPEC}', 'Confirm origin; report only.')
open(p, 'w').write(s)
PY

for mode in no-mistakes direct-PR local-only; do
  id="scout-$mode"
  rm -rf "$H/data/$id"
  cp -R "$H/data/scout-p1" "$H/data/$id"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$H/state/$id.meta"
  FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" \
    "$ROOT/bin/fm-promote.sh" "$id" --mode "$mode" --yolo on >/dev/null
  echo "=== promoted scout -> $mode ==="
  awk '/^# Remote repository authority$/{i=1;print;next} i && /^# /{exit} i{print}' \
    "$H/data/$id/brief.md"
  grep -E '^Delivery contract:|Completion for mode=|push your branch and open a PR|Do NOT push' \
    "$H/data/$id/ship-instructions.md" | head -3
  echo
done
echo "fixtures kept at: $P"
