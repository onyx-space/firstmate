#!/usr/bin/env bash
# Adversarial live drive: (1) a notification note is still PRESENTED by the
# drain (only its archival timing changed); (2) when the archival helper cannot
# run, the acknowledgement fails and leaves row + note together.
set -u
ROOT=/Users/onyx/.no-mistakes/worktrees/9573b29b9316/01M2DQ0WYEWNEASYTMNQSCJANK
LIVE=/Users/onyx/.no-mistakes/evidence/01M2DQ0WYEWNEASYTMNQSCJANK/live2
INBOX="$ROOT/bin/fm-inbox.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
export FM_ROOT_OVERRIDE="$LIVE/inert"
export PATH="$LIVE/fakebin:$PATH"
rm -rf "$LIVE"
mkdir -p "$LIVE/inert" "$LIVE/fakebin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$LIVE/fakebin/tmux"
chmod +x "$LIVE/fakebin/tmux"

banner() { printf '\n========== %s ==========\n' "$*"; }
verdict() { if [ "$2" = "$3" ]; then printf '  PASS %s: %s\n' "$1" "$2"; else printf '  FAIL %s: got %s, wanted %s\n' "$1" "$2" "$3"; fi; }

# ---------------------------------------------------------------- I
banner 'I: a notification note is still presented by the drain (timing, not visibility, changed)'
state="$LIVE/I-present/state"; mkdir -p "$state"
id=$(FM_STATE_OVERRIDE="$state" "$INBOX" note --source relay 'relay: a watched PR merged -> https://example.invalid/pr/1' | sed -n 's/^queued //p')
printf '  queued id=%s\n' "$id"
FM_STATE_OVERRIDE="$state" "$DRAIN" > "$LIVE/I-present/drain.out" 2> "$LIVE/I-present/drain.err"
printf '  drain stdout mentions the note payload: %s\n' "$(grep -cF 'a watched PR merged' "$LIVE/I-present/drain.out" || true)"
verdict 'note payload presented before ack' "$(grep -cF 'a watched PR merged' "$LIVE/I-present/drain.out" | tr -d ' ')" 1
verdict 'note still queued before ack' "$([ -f "$state/inbox/$id.note" ] && echo yes || echo no)" yes

# ---------------------------------------------------------------- J
banner 'J: adversarial - an archival helper that cannot run fails the ack and keeps row + note together'
TMP=$(mktemp -d /tmp/fm-ackfail-XXXXXX)
rsync -a --exclude '.git' "$ROOT/" "$TMP/"
state="$LIVE/J-helperfail/state"; mkdir -p "$state"
id=$(FM_STATE_OVERRIDE="$state" "$TMP/bin/fm-inbox.sh" note --source relay 'relay: a watched PR merged' | sed -n 's/^queued //p')
printf '  queued id=%s (rows in queue: %s)\n' "$id" "$(awk 'NF>=5' "$state/.wake-queue" | wc -l | tr -d ' ')"
chmod -x "$TMP/bin/fm-inbox.sh"
FM_STATE_OVERRIDE="$state" "$TMP/bin/fm-wake-drain.sh" > "$LIVE/J-helperfail/drain.out" 2> "$LIVE/J-helperfail/drain.err"
seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$LIVE/J-helperfail/drain.err")
gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$LIVE/J-helperfail/drain.err")
printf '  drain printed ack command: --ack-through %s --recovery-generation %s\n' "$seq" "$gen"
FM_STATE_OVERRIDE="$state" "$TMP/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" \
  > "$LIVE/J-helperfail/ack.out" 2> "$LIVE/J-helperfail/ack.err"
rc=$?
printf '  acknowledgement exit: %s\n' "$rc"
printf '  acknowledgement stderr: %s\n' "$(grep -F 'could not be archived' "$LIVE/J-helperfail/ack.err" || echo '(none)')"
verdict 'acknowledgement failed loudly' "$([ "$rc" -ne 0 ] && echo yes || echo no)" yes
verdict 'wake row NOT consumed' "$(awk 'NF>=5' "$state/.wake-queue" | wc -l | tr -d ' ')" 1
verdict 'note NOT archived' "$([ -f "$state/inbox/$id.note" ] && echo yes || echo no)" yes
chmod +x "$TMP/bin/fm-inbox.sh"
rm -rf "$TMP"

printf '\n========== done ==========\n'
