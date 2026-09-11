#!/usr/bin/env bash
# A second real publisher surface: the captain-hold CLI holds a task with a long
# single-line multibyte reason and that reason is published on the parent
# channel through bin/fm-parent-channel-lib.sh's shared note fold.
# usage: drive_hold.sh <repo-root> <out-dir>
set -u
ROOT=$1
OUT=$2
mkdir -p "$OUT"
WORLD=$(mktemp -d /tmp/fm-hold-world.XXXXXX)
trap 'rm -rf "$WORLD"' EXIT

MAIN="$WORLD/main"
MATE="$WORLD/mate"
mkdir -p "$MAIN"/{state,data,config,projects} "$MATE"/{state,data,config,projects}
cp "$ROOT/.tasks.toml" "$MATE/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$MATE/data/backlog.md"
mkdir -p "$MATE/fakebin"
for tool in tmux treehouse no-mistakes gh gh-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MATE/fakebin/$tool"
  chmod +x "$MATE/fakebin/$tool"
done
printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" \
  > "$MATE/.fm-secondmate-parent"

# 1 ascii pad + prefix + CJK: 1200 - 1 = 1199, not a multiple of 3, so the bound
# lands inside a character under a byte-counting cut.
REASON="A修好了：这条理由很长 $(printf '中%.0s' $(seq 1 600))"
export LC_ALL=C
REASON_BYTES=$(printf '%s' "$REASON" | wc -c | tr -d ' ')

set +e
PATH="$MATE/fakebin:$PATH" REAL_TASKS_AXI="$(command -v tasks-axi)" \
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" \
  FM_CONFIG_OVERRIDE="$MATE/config" \
  "$ROOT/bin/fm-captain-hold.sh" hold sample-long-reason \
    --title "Hold with a long reason" --reason "$REASON" > "$OUT/hold.out" 2>&1
HOLD_RC=$?
set -e

python3 - "$MAIN/state/mate.status" "$OUT" "$HOLD_RC" "$REASON_BYTES" <<'PY'
import json, os, sys
path, out, rc, reason_bytes = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
raw = open(path, "rb").read() if os.path.exists(path) else b""
report = {"hold_rc": rc, "channel_bytes": len(raw), "reason_bytes": reason_bytes,
          "channel_path": path}
report["channel_lines"] = len([l for l in raw.split(b"\n") if l])
try:
    text = raw.decode("utf-8")
    report["strict_decode"] = True
except UnicodeDecodeError as exc:
    text = None
    report["strict_decode"] = False
    report["decode_error"] = "byte %d 0x%02x: %s" % (exc.start, raw[exc.start], exc.reason)
lines = [l for l in raw.split(b"\n") if l]
report["one_line"] = len(lines) == 1
if lines and text is not None:
    line = lines[0]
    marker = b"captain hold sample-long-reason: "
    body = line.split(marker, 1)[1] if marker in line else b""
    reason = body.rsplit(b" [key=", 1)[0]
    report["folded_reason_bytes"] = len(reason)
    report["bound_ok"] = len(reason) <= 1200
    report["human_readable"] = "修好了：这条理由很长".encode("utf-8") in reason
    report["no_embedded_newline_or_tab"] = b"\n" not in reason and b"\t" not in reason
    report["channel_head"] = line[:80].decode("utf-8", "replace")
os.makedirs(out, exist_ok=True)
json.dump(report, open(os.path.join(out, "report.json"), "w"), indent=2)
print(json.dumps(report, indent=2))
PY
