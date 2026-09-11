#!/usr/bin/env bash
# fm-damaged-channel-e2e.sh <tree> <label>
#
# The field situation the intent describes: the channel already carries a line
# written BEFORE the fix, with a multibyte character cut in half. The publisher
# must keep working over that file - a bad byte already on disk may not wedge the
# channel - and it must not rewrite the bytes it already published.
set -u

TREE=$1
LABEL=${2:-$TREE}
TREE=$(cd "$TREE" && pwd)
# shellcheck source=tests/lib.sh
. "$TREE/tests/lib.sh"

RECON="$TREE/bin/fm-inactive-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-damaged-channel-e2e)
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

# A line an earlier release published: a 3-byte character cut after its first
# byte, which is what the old fold left on disk.
python3 - "$MATE/state/parent-replies.status" <<'PY'
import sys
head = 'done [key=child-outcome-older-done-abcdef12]: child older done: '.encode()
# 'A' + N 3-byte characters cut at a fixed byte length: the cut lands two bytes
# into a character, exactly what the old fold left on disk.
tail = ('A' + '中' * 400).encode()[:1199]
line = head + tail
try:
    line.decode('utf-8')
    raise SystemExit('fixture is not damaged')
except UnicodeDecodeError:
    pass
open(sys.argv[1], 'wb').write(line + b'\n')
PY
cp "$MATE/state/parent-replies.status" "$WORLD/seeded.bin"

ID=child
fm_write_meta "$MATE/state/$ID.meta" \
  "window=firstmate:fm-$ID" "worktree=$MATE/projects/$ID" "project=alpha" \
  'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' "spawn_gen=s$RANDOM" 'pr='
printf 'done: 修好了：中文不会再被切成半个字\n' > "$MATE/state/$ID.status"
: > "$MATE/state/$ID.turn-ended"
now=$(( $(date +%s) - 120 ))
for f in "$MATE/state/$ID.meta" "$MATE/state/$ID.status" "$MATE/state/$ID.turn-ended"; do
  touch -t "$(date -r "$now" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$now" +%Y%m%d%H%M.%S)" "$f"
done

PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MATE" \
  FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" FM_CONFIG_OVERRIDE="$MATE/config" \
  FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
  FM_FAKE_CREW_STATE=unknown "$RECON" scan > "$WORLD/reconcile.log" 2>&1
echo "reconcile exit=$? stderr=$(tr '\n' '|' < "$WORLD/reconcile.log" | head -c 300)"

python3 - "$MATE/state/parent-replies.status" "$WORLD/seeded.bin" "$LABEL" <<'PY'
import sys
channel, seeded, label = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(channel, 'rb').read()
old = open(seeded, 'rb').read()
problems = []
if not raw.startswith(old):
    problems.append('the publisher rewrote already-published bytes: the seeded line changed')
lines = raw.split(b'\n')
if lines and lines[-1] == b'':
    lines.pop()
if len(lines) != 2:
    problems.append('the channel holds %d lines, expected the seeded line plus one new line' % len(lines))
new_line = lines[-1] if len(lines) > 1 else b''
try:
    new_line.decode('utf-8')
    print('%s: the seeded damaged line is untouched and the new line is %d valid bytes: %r' % (
        label, len(new_line), new_line[:46].decode()))
except UnicodeDecodeError as exc:
    problems.append('the newly published line is not valid UTF-8: %s' % exc)
if b'child child done' not in new_line:
    problems.append('the child outcome was not published over the damaged channel: %r' % new_line[:80])
for p in problems:
    print(f'FAIL({label}): {p}')
sys.exit(1 if problems else 0)
PY
rc=$?
[ "$rc" -eq 0 ] && echo "PASS($LABEL): a channel already carrying an invalid byte still accepts published lines"
exit $rc
