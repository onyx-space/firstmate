#!/usr/bin/env bash
# Live drive of the REAL herdr adapter (bin/backends/herdr.sh) against the
# running herdr server and its real pi panes. Read-only: capture + identity +
# composer_state. Writes frames/verdicts next to this script.
set -u
ROOT=/home/onyx/.no-mistakes/worktrees/e7f71fdfbe8f/01M39CXBX2VCWGK13DV6B9HHJV
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

for t in "$@"; do
  safe=${t//:/_}
  identity=$(fm_backend_herdr_composer_identity "$t" 2>/dev/null)
  fm_backend_herdr_capture_ansi "$t" "$FM_COMPOSER_CAPTURE_LINES" > "$OUT/$safe.ansi" 2>/dev/null
  verdict=$(fm_backend_herdr_composer_state "$t" 2>/dev/null)
  printf 'target=%s identity=%s verdict=%s frame_bytes=%s\n' \
    "$t" "${identity:-<none>}" "$verdict" "$(wc -c < "$OUT/$safe.ansi")"
done
