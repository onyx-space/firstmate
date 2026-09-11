#!/usr/bin/env bash
# fm-fold-e2e.sh <tree> <label>
#
# Drives the REAL publisher end to end: a remote-bound secondmate home whose
# child reaches a terminal state, so bin/fm-inactive-reconcile.sh folds that
# child's ledger note onto one line and appends it to the home's parent channel
# (state/parent-replies.status). The persisted channel file is then read back by
# a strict UTF-8 decoder - the consumer the field failure reported - and the
# folded note is compared with an independently computed fold.
#
# Several ASCII-prefix alignments (and a 4-byte-character shape) are driven,
# because with 3-byte characters two of every three prefixes push the byte bound
# into the middle of a character.
set -u

TREE=$1
LABEL=${2:-$TREE}
TREE=$(cd "$TREE" && pwd)

# The tree's own test library supplies only fixtures (temp roots, meta writers,
# stub tools). The code under test is the real reconcile + channel library.
# shellcheck source=tests/lib.sh
. "$TREE/tests/lib.sh"

RECON="$TREE/bin/fm-inactive-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-fold-e2e)
FAILURES=0
ALIGNMENTS=0

# note_for <pad> <cjk|emoji|two-byte>: a ledger note whose 1200-byte bound lands
# in the middle of a character for this alignment.
note_for() {  # <pad> <cjk|emoji|two-byte>
  python3 - "$1" "$2" <<'PY'
import sys
pad, shape = int(sys.argv[1]), sys.argv[2]
intro = '修好了：中文不会再被切成半个字 '
body = {'cjk': '中' * 900, 'emoji': '\U0001f600' * 700, 'two-byte': '\u00e9' * 900}[shape]
sys.stdout.write('A' * pad + intro + body)
PY
}

# fold_expected <note>: the fold contract, computed independently of the shell
# implementation - collapse tab/CR/LF to a space, then keep the longest prefix
# that is whole characters and at most 1200 bytes.
fold_expected() {
  python3 - "$1" <<'PY'
import sys
text = sys.argv[1].replace('\t', ' ').replace('\r', ' ').replace('\n', ' ')
out, size = [], 0
for ch in text:
    b = len(ch.encode())
    if size + b > 1200:
        break
    out.append(ch)
    size += b
sys.stdout.write(''.join(out))
PY
}

drive_one() {  # <pad> <shape>
  local pad=$1 shape=$2 world main mate fakebin note id now expected
  ALIGNMENTS=$((ALIGNMENTS + 1))
  world="$TMP_ROOT/$LABEL-$shape-$pad"
  main="$world/main"
  mate="$world/mate"
  mkdir -p "$world/root" "$main"/{state,data,config,projects} "$mate"/{state,data,config,projects,bin}
  : > "$mate/AGENTS.md"
  fakebin=$(fm_fakebin "$world")
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: fake\n' "${FM_FAKE_CREW_STATE:-unknown}"
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"
  local tool
  for tool in gh gh-axi curl; do printf '#!/usr/bin/env bash\nexit 97\n' > "$fakebin/$tool"; done
  chmod +x "$fakebin"/*
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$mate/.fm-secondmate-parent"

  note=$(note_for "$pad" "$shape")
  id=child
  fm_write_meta "$mate/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$mate/projects/$id" "project=alpha" \
    'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' "spawn_gen=s$RANDOM" 'pr='
  printf 'done: %s\n' "$note" > "$mate/state/$id.status"
  : > "$mate/state/$id.turn-ended"
  now=$(( $(date +%s) - 120 ))
  for f in "$mate/state/$id.meta" "$mate/state/$id.status" "$mate/state/$id.turn-ended"; do
    touch -t "$(date -r "$now" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$now" +%Y%m%d%H%M.%S)" "$f"
  done

  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$world/root" FM_HOME="$mate" \
    FM_STATE_OVERRIDE="$mate/state" FM_DATA_OVERRIDE="$mate/data" FM_CONFIG_OVERRIDE="$mate/config" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE=unknown "$RECON" scan > "$world/reconcile.log" 2>&1

  expected=$(fold_expected "$note")
  printf '%s' "$note" > "$world/note.txt"
  printf '%s' "$expected" > "$world/expected.txt"
  python3 - "$mate/state/parent-replies.status" "$world/note.txt" "$world/expected.txt" "$LABEL" "$shape" "$pad" <<'PY'
import sys
channel, note_path, expected_path, label, shape, pad = sys.argv[1:7]
where = f'{label}/{shape}/pad={pad}'
try:
    raw = open(channel, 'rb').read()
except FileNotFoundError:
    print(f'FAIL({where}): no parent channel line was published')
    sys.exit(1)
problems = []
try:
    text = raw.decode('utf-8', errors='strict')
except UnicodeDecodeError as exc:
    fault = raw[max(0, exc.start - 6):exc.start + 6]
    print(f'FAIL({where}): strict UTF-8 decode of the whole channel file failed: {exc}')
    print('  bytes at the fault: %s' % ' '.join(str(b) for b in fault))
    sys.exit(1)
lines = [ln for ln in text.split('\n') if ln]
if len(lines) != 1:
    problems.append('the channel held %d lines, not the one published outcome' % len(lines))
marker = 'child child done: '
folded = ''
if marker not in lines[0]:
    problems.append('the published line is not the expected child outcome: ' + lines[0][:70])
else:
    folded = lines[0].split(marker, 1)[1].split(' pr=')[0].split(' mode=')[0]
    expected = open(expected_path, encoding='utf-8').read()
    if folded != expected:
        problems.append('the folded note is not the whole-character prefix of the note '
                        '(%d vs %d bytes, identical prefix %d)'
                        % (len(folded.encode()), len(expected.encode()),
                           len(''.join(a for a, b in zip(folded, expected) if a == b))))
    if len(folded.encode()) > 1200:
        problems.append('the folded note is %d bytes, past its 1200-byte bound' % len(folded.encode()))
    if '\\u' in folded or '\\x' in folded:
        problems.append('the folded note was escaped rather than kept as text')
print('%s note=%d bytes chars=%d tail-bytes=%s' % (
    where, len(folded.encode()), len(folded), ' '.join(str(b) for b in folded.encode()[-4:])))
if problems:
    for p in problems:
        print(f'FAIL({where}): {p}')
    sys.exit(1)
print(f'PASS({where})')
PY
  if [ "$?" -ne 0 ]; then FAILURES=$((FAILURES + 1)); fi
}

for pad in 0 1 2 3; do
  for shape in ${FM_E2E_SHAPES:-cjk emoji}; do
    drive_one "$pad" "$shape"
  done
done

echo "=== $LABEL: alignments=$ALIGNMENTS failures=$FAILURES"
[ "$FAILURES" -eq 0 ]
