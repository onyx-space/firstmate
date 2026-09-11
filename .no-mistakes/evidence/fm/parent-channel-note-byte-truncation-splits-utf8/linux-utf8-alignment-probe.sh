#!/usr/bin/env bash
# Probe: how many cheap ASCII-prefix alignments of a long multibyte note make
# fm_parent_channel_clean_note emit invalid UTF-8, and does the folded line stay
# within its 1200-BYTE bound and on one line?
#
# Usage: bash linux-utf8-alignment-probe.sh <tree> <label>
# <tree> is a checkout of the project; the fold and its assertion are the real
# shipped ones. Run it once per tree and once per locale to compare.
set -u
tree=$1 label=$2
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$tree/bin/fm-parent-channel-lib.sh"

intro='修好了：中文不会再被切成半个字 '
total=0 bad=0 over=0 split=0 lost=0
for len in $(seq 0 20); do
  pad=$(printf '%*s' "$len" '' | tr ' ' A)
  for text in \
    "$intro$pad$(printf '中%.0s' $(seq 1 500))" \
    "$intro$pad$(printf '😀%.0s' $(seq 1 400))"; do
    folded=$(fm_parent_channel_clean_note "$text")
    total=$((total + 1))
    printf '%s' "$folded" | python3 -c 'import sys;sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null \
      || bad=$((bad + 1))
    bytes=$(printf '%s' "$folded" | wc -c | tr -d ' ')
    [ "$bytes" -le 1200 ] || over=$((over + 1))
    case "$folded" in *$'\n'*) split=$((split + 1)) ;; esac
    case "$folded" in *修好了*) ;; *) lost=$((lost + 1)) ;; esac
  done
done
printf '%s: locale=%s total=%d invalid_utf8=%d over_1200_bytes=%d not_one_line=%d note_text_lost=%d\n' \
  "$label" "${LC_ALL:-${LC_CTYPE:-unset}}" "$total" "$bad" "$over" "$split" "$lost"
