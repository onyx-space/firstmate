#!/usr/bin/env bash
# Live drive of the note-archival product surface: real bin/fm-inbox.sh and
# real bin/fm-wake-drain.sh over real records in an isolated home/state.
set -u
ROOT=/Users/onyx/.no-mistakes/worktrees/9573b29b9316/01M2DQ0WYEWNEASYTMNQSCJANK
LIVE=/Users/onyx/.no-mistakes/evidence/01M2DQ0WYEWNEASYTMNQSCJANK/live
INBOX="$ROOT/bin/fm-inbox.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
export FM_ROOT_OVERRIDE="$LIVE/inert"
export PATH="$LIVE/fakebin:$PATH"
rm -rf "$LIVE"
mkdir -p "$LIVE/inert" "$LIVE/fakebin"
cat > "$LIVE/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$LIVE/fakebin/tmux"

need_state() { # <state> guard: never let an empty override fall through to the repo home
  [ -n "${1:-}" ] || { printf '  !! refusing to run with an empty state dir\n' >&2; exit 1; }
  [ -d "$1" ] || { printf '  !! state dir does not exist: %s\n' "$1" >&2; exit 1; }
}

queue() { # <state> <note args...> ; echoes id
  local state=$1; shift
  need_state "$state"
  FM_STATE_OVERRIDE="$state" "$INBOX" note "$@" | sed -n 's/^queued //p'
}

pending() { # <state> -> count
  need_state "$state"
  FM_STATE_OVERRIDE="$state" "$INBOX" status | sed -n 's/^inbox  *\([0-9][0-9]*\) note(s).*/\1/p'
}

consume_rows() { # <state>  drains, then runs the acknowledgement command the drain printed
  local state=$1 dir seq gen rc
  need_state "$state"
  dir=$(dirname "$state")
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$dir/drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$dir/drain.err")
  if [ -z "$seq" ] || [ -z "$gen" ]; then
    printf '  !! drain printed no acknowledgement command\n' >&2
    printf '  --- drain stderr ---\n' >&2; cat "$dir/drain.err" >&2
    return 1
  fi
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    > "$dir/ack.out" 2> "$dir/ack.err"
  rc=$?
  printf '  acknowledgement exit: %s (--ack-through %s)\n' "$rc" "$seq"
  printf '  acknowledgement stderr: %s\n' "$(grep -F 'archived' "$dir/ack.err" || echo '(no archival line)')"
  return $rc
}

fresh() { # <name> -> echoes state dir
  local name dir
  name=$1
  [ -n "$name" ] || { printf '  !! fresh() needs a name\n' >&2; exit 1; }
  dir="$LIVE/$name"
  rm -rf "$dir"; mkdir -p "$dir/state" || exit 1
  printf '%s' "$dir/state"
}

banner() { printf '\n========== %s ==========\n' "$*"; }
verdict() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf '  PASS %s: %s\n' "$1" "$2"; else printf '  FAIL %s: got %s, wanted %s\n' "$1" "$2" "$3"; fi
}

# ---------------------------------------------------------------- A
banner 'A: captain note (no --source) survives its acknowledged wake row'
state=$(fresh A-captain)
id=$(queue "$state" 'captain wrote this out of band')
printf '  queued id=%s\n' "$id"
printf '  record header: %s\n' "$(sed -n '/^--$/q;p' "$state/inbox/$id.note" | tr '\n' ' ')"
printf '  pending before ack: %s\n' "$(pending "$state")"
consume_rows "$state"
verdict 'note still queued' "$([ -f "$state/inbox/$id.note" ] && echo yes || echo no)" yes
verdict 'note NOT in handled/' "$([ -e "$state/inbox/handled/$id.note" ] && echo yes || echo no)" no
verdict 'pending after ack' "$(pending "$state")" 1

# ---------------------------------------------------------------- B
banner 'B: notification note (--source relay) is archived with its wake row and named'
state=$(fresh B-relay)
id=$(queue "$state" --source relay 'relay: a watched PR merged')
printf '  queued id=%s\n' "$id"
printf '  pending before ack: %s\n' "$(pending "$state")"
consume_rows "$state"
verdict 'note archived to handled/' "$([ -f "$state/inbox/handled/$id.note" ] && echo yes || echo no)" yes
verdict 'note gone from pending' "$([ -e "$state/inbox/$id.note" ] && echo yes || echo no)" no
verdict 'pending after ack (board count falls)' "$(pending "$state")" 0
verdict 'ack line names the archived id' "$(grep -Fc "$id" "$LIVE/B-relay/ack.err")" 1

# ---------------------------------------------------------------- C
banner "C: real producer argv shape (fm-inbox.sh note <text>, no --source at all)"
state=$(fresh C-producer)
id=$(FM_STATE_OVERRIDE="$state" "$INBOX" note 'relay: a watched PR merged -> https://example.invalid/pr/1' | sed -n 's/^queued //p')
printf '  queued id=%s\n' "$id"
printf '  record header: %s\n' "$(sed -n '/^--$/q;p' "$state/inbox/$id.note" | tr '\n' ' ')"
consume_rows "$state"
verdict 'producer-shaped note still pending' "$([ -f "$state/inbox/$id.note" ] && echo yes || echo no)" yes
verdict 'producer-shaped note NOT in handled/' "$([ -e "$state/inbox/handled/$id.note" ] && echo yes || echo no)" no
verdict 'pending after ack' "$(pending "$state")" 1

# ---------------------------------------------------------------- D
banner 'D: mixed batch archives only the notification note'
state=$(fresh D-mixed)
c=$(queue "$state" 'captain wrote this out of band')
r=$(queue "$state" --source relay 'relay: upstream left a review comment')
printf '  captain id=%s relay id=%s pending=%s\n' "$c" "$r" "$(pending "$state")"
consume_rows "$state"
verdict 'relay archived' "$([ -f "$state/inbox/handled/$r.note" ] && echo yes || echo no)" yes
verdict 'captain kept' "$([ -f "$state/inbox/$c.note" ] && echo yes || echo no)" yes
verdict 'captain not in handled/' "$([ -e "$state/inbox/handled/$c.note" ] && echo yes || echo no)" no
verdict 'pending after ack' "$(pending "$state")" 1

# ---------------------------------------------------------------- E
banner 'E: adversarial - an unknown source is treated as the captain and kept'
state=$(fresh E-unknown-source)
id=$(queue "$state" --source webhook 'a third integration nobody registered')
printf '  queued id=%s header: %s\n' "$id" "$(sed -n '/^--$/q;s/^source=//p' "$state/inbox/$id.note")"
consume_rows "$state"
verdict 'unknown-source note kept' "$([ -f "$state/inbox/$id.note" ] && echo yes || echo no)" yes
verdict 'pending after ack' "$(pending "$state")" 1

# ---------------------------------------------------------------- F
banner 'F: adversarial - a legacy record with no source header is not classified by its body'
state=$(fresh F-legacy)
id=$(queue "$state" 'captain wrote this out of band')
{ printf 'id=%s\n' "$id"; printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; printf -- '--\n'; printf 'source=relay\n'; printf 'captain text that merely mentions source=relay\n'; } > "$state/inbox/$id.note"
consume_rows "$state"
verdict 'legacy record kept' "$([ -f "$state/inbox/$id.note" ] && echo yes || echo no)" yes
verdict 'pending after ack' "$(pending "$state")" 1

# ---------------------------------------------------------------- G
banner 'G: adversarial - a source that could inject a record header line is refused'
state=$(fresh G-badsource)
if FM_STATE_OVERRIDE="$state" "$INBOX" note --source "$(printf 'relay\ninjected=1')" body > "$LIVE/G-badsource/out" 2> "$LIVE/G-badsource/err"; then
  printf '  FAIL: injected source accepted\n'
else
  printf '  refused: %s\n' "$(cat "$LIVE/G-badsource/err")"
fi
verdict 'no note queued' "$(find "$state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')" 0
verdict 'pending' "$(pending "$state")" 0

# ---------------------------------------------------------------- H
banner 'H: explicit drain --ack still archives either source'
state=$(fresh H-explicit)
c=$(queue "$state" 'captain wrote this out of band')
r=$(queue "$state" --source relay 'relay: a watched PR merged')
printf '  before: %s\n' "$(FM_STATE_OVERRIDE="$state" "$INBOX" drain --ack "$c" "$r")"
verdict 'captain archived' "$([ -f "$state/inbox/handled/$c.note" ] && echo yes || echo no)" yes
verdict 'relay archived' "$([ -f "$state/inbox/handled/$r.note" ] && echo yes || echo no)" yes
verdict 'pending' "$(pending "$state")" 0

printf '\n========== done ==========\n'
