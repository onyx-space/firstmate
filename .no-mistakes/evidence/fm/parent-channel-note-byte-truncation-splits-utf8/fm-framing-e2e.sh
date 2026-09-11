#!/usr/bin/env bash
# fm-framing-e2e.sh <tree> <label>
#
# Adversarial framing check at the publisher level. A child's ledger line is
# written the CRLF way and carries a tab, which reaches the shared fold as a raw
# CR and a raw tab. The fold must turn both into spaces so the published channel
# line stays exactly one line and cannot be broken by a stray CR.
set -u

TREE=$1
LABEL=${2:-$TREE}
TREE=$(cd "$TREE" && pwd)
# shellcheck source=tests/lib.sh
. "$TREE/tests/lib.sh"

RECON="$TREE/bin/fm-inactive-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-framing-e2e)
WORLD="$TMP_ROOT/$LABEL"
MAIN="$WORLD/main"
MATE="$WORLD/mate"
mkdir -p "$WORLD/root" "$MAIN"/{state,data,config,projects} "$MATE"/{state,data,config,projects,bin}
: > "$MATE/AGENTS.md"
FAKEBIN=$(fm_fakebin "$WORLD")
cat > "$FAKEBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: fake\n' "${FM_FAKE_CREW_STATE:-unknown}"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/tmux"
for tool in gh gh-axi curl; do printf '#!/usr/bin/env bash\nexit 97\n' > "$FAKEBIN/$tool"; done
chmod +x "$FAKEBIN"/*
printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$MATE/.fm-secondmate-parent"

ID=child
fm_write_meta "$MATE/state/$ID.meta" \
  "window=firstmate:fm-$ID" "worktree=$MATE/projects/$ID" "project=alpha" \
  'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' "spawn_gen=s$RANDOM" 'pr='
# CRLF line ending plus an inner tab: a raw CR and a raw tab reach the fold.
printf 'done: pick\tone 重来\r\n' > "$MATE/state/$ID.status"
: > "$MATE/state/$ID.turn-ended"
now=$(( $(date +%s) - 120 ))
for f in "$MATE/state/$ID.meta" "$MATE/state/$ID.status" "$MATE/state/$ID.turn-ended"; do
  touch -t "$(date -r "$now" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$now" +%Y%m%d%H%M.%S)" "$f"
done

PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MATE" \
  FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" FM_CONFIG_OVERRIDE="$MATE/config" \
  FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
  FM_FAKE_CREW_STATE=unknown "$RECON" scan > "$WORLD/reconcile.log" 2>&1

python3 - "$MATE/state/parent-replies.status" "$LABEL" <<'PY'
import sys
channel, label = sys.argv[1], sys.argv[2]
try:
    raw = open(channel, 'rb').read()
except FileNotFoundError:
    print(f'FAIL({label}): no parent channel line was published')
    sys.exit(1)
problems = []
try:
    text = raw.decode('utf-8', errors='strict')
except UnicodeDecodeError as exc:
    print(f'FAIL({label}): strict UTF-8 decode of the channel file failed: {exc}')
    sys.exit(1)
if b'\r' in raw:
    problems.append('the channel file carries a raw CR byte: %r' % raw)
if b'\t' in raw:
    problems.append('the channel file carries a raw tab byte: %r' % raw)
lines = text.split('\n')
if lines and lines[-1] == '':
    lines.pop()
if len(lines) != 1:
    problems.append('the channel file holds %d lines, so the note broke the framing' % len(lines))
elif 'pick one 重来' not in lines[0].replace('  ', ' '):
    problems.append('the folded line did not carry the note text: %r' % lines[0])
else:
    print('%s: 1 line, no CR, no tab, note reads %r' % (
        label, lines[0][lines[0].find('pick') - 4:lines[0].find('重来') + 2]))
for p in problems:
    print(f'FAIL({label}): {p}')
sys.exit(1 if problems else 0)
PY
rc=$?
[ "$rc" -eq 0 ] && echo "PASS($LABEL): a CRLF ledger line with a tab stays one clean channel line"
exit $rc
