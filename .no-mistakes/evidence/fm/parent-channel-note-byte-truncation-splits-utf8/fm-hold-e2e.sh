#!/usr/bin/env bash
# fm-hold-e2e.sh <tree> <label>
#
# Drives a SECOND publisher end to end: bin/fm-captain-hold.sh publishes a
# captain hold's reason on the parent channel of a remote-bound secondmate home,
# through the same shared fold. This is a different call site from the reconcile
# publisher's clean_field, and unlike that one it leaves the caller's ambient
# locale alone.
set -u

TREE=$1
LABEL=${2:-$TREE}
TREE=$(cd "$TREE" && pwd)
# shellcheck source=tests/lib.sh
. "$TREE/tests/lib.sh"

TASKS_AXI_BIN=$(command -v tasks-axi || true)
command -v tasks-axi >/dev/null 2>&1 || { echo "SKIP($LABEL): tasks-axi is not installed"; exit 2; }

TMP_ROOT=$(fm_test_tmproot fm-hold-e2e)
HOME_DIR="$TMP_ROOT/$LABEL"
mkdir -p "$HOME_DIR"/{data,state,config,projects}
cp "$TREE/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '# Synthetic secondmate home\n' > "$HOME_DIR/AGENTS.md"
printf 'mate\n' > "$HOME_DIR/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$HOME_DIR/.fm-secondmate-parent"
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
FAKEBIN=$(fm_fakebin "$HOME_DIR")
fm_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes gh gh-axi

REASON=$(python3 - <<'PY'
import sys
sys.stdout.write('A' + '修好了：中文不会再被切成半个字 ' + '中' * 900)
PY
)

PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  "$TREE/bin/fm-captain-hold.sh" hold fold-call --title "长中文理由" --reason "$REASON" --repo sample \
  > "$TMP_ROOT/hold.out" 2>&1
echo "hold exit=$? out=$(tr '\n' '|' < "$TMP_ROOT/hold.out" | head -c 300)"

CHANNEL="$HOME_DIR/state/parent-replies.status"
python3 - "$CHANNEL" "$LABEL" <<'PY'
import sys
channel, label = sys.argv[1], sys.argv[2]
try:
    raw = open(channel, 'rb').read()
except FileNotFoundError:
    print(f'FAIL({label}): the hold published nothing on the parent channel')
    sys.exit(1)
try:
    text = raw.decode('utf-8', errors='strict')
except UnicodeDecodeError as exc:
    print(f'FAIL({label}): strict UTF-8 decode of the channel file failed: {exc}')
    print('  bytes at the fault: %s' % ' '.join(str(b) for b in raw[max(0, exc.start - 6):exc.start + 6]))
    sys.exit(1)
lines = [ln for ln in text.split('\n') if ln]
marker = 'captain hold fold-call: '
line = [ln for ln in lines if marker in ln]
if not line:
    print(f'FAIL({label}): no captain-hold line on the channel: {lines[:1]}')
    sys.exit(1)
folded = line[0].split(marker, 1)[1]
problems = []
if len(folded.encode()) > 1200:
    problems.append('the folded note is %d bytes, past its 1200-byte bound' % len(folded.encode()))
if '\\u' in folded or '\\x' in folded:
    problems.append('the folded note was escaped rather than kept as text')
if not folded.endswith(tuple('修好了：中文不会再被切成半个字 ')) and '中' not in folded:
    problems.append('the folded note is not the note text')
print('%s note=%d bytes chars=%d lines=%d tail-bytes=%s' % (
    label, len(folded.encode()), len(folded), len(lines),
    ' '.join(str(b) for b in folded.encode()[-4:])))
for p in problems:
    print(f'FAIL({label}): {p}')
sys.exit(1 if problems else 0)
PY
rc=$?
[ "$rc" -eq 0 ] && echo "PASS($LABEL): the captain-hold publisher writes a valid, bounded channel note"
echo "=== $LABEL rc=$rc"
exit $rc
