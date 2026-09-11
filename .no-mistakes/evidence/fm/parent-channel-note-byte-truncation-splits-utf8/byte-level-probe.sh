#!/usr/bin/env bash
# Show the exact bytes each fold leaves at the 1200-byte boundary for a note of
# CJK behind a 13-byte ASCII offset (so a byte cut lands inside a character).
set -u
tree=$1 label=$2
. "$tree/bin/fm-parent-channel-lib.sh"
note="修好了：a$(printf '中%.0s' $(seq 1 1500))"
folded=$(fm_parent_channel_clean_note "$note")
printf '%s | bytes=%s | last 6 bytes: %s | strict-utf8: ' \
  "$label" "$(printf '%s' "$folded" | wc -c | tr -d ' ')" \
  "$(printf '%s' "$folded" | tail -c 6 | od -An -v -tx1 | tr -s ' ')"
printf '%s' "$folded" | python3 -c 'import sys
try:
    sys.stdin.buffer.read().decode("utf-8"); print("VALID")
except UnicodeDecodeError as e:
    print(f"INVALID ({e})")'
