#!/usr/bin/env python3
"""Adversarial probes for the shared note fold through the real production library.

usage: drive_edge.py <repo-root> <out-dir>

Every probe calls fm_parent_channel_clean_note out of bin/fm-parent-channel-lib.sh
in a fresh real bash, exactly as the publishers do, and asserts on the bytes it
prints. Cases are chosen to try to break the byte bound or the character
boundary rather than to confirm the happy path.
"""
import codecs
import json
import os
import subprocess
import sys
import time

ROOT = os.path.abspath(sys.argv[1])
OUT = os.path.abspath(sys.argv[2])
BOUND = 1200


def fold(text, locale=None, via_stdin=False):
    env = dict(os.environ)
    env.pop("LC_ALL", None)
    env.pop("LANG", None)
    if locale:
        env["LC_ALL"] = locale
    started = time.time()
    cmd = ["bash", "-c",
           '. "$1/bin/fm-parent-channel-lib.sh"; fm_parent_channel_clean_note "$2"',
           "_", ROOT, text]
    stdin = None
    if via_stdin:
        cmd = ["bash", "-c",
               '. "$1/bin/fm-parent-channel-lib.sh"; x=$(cat); fm_parent_channel_clean_note "$x"',
               "_", ROOT]
        stdin = text.encode("utf-8")
    proc = subprocess.run(cmd, input=stdin,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    return proc, time.time() - started


def expected(text):
    folded = text.replace("\t", " ").replace("\r", " ").replace("\n", " ")
    data = folded.encode("utf-8")
    if len(data) <= BOUND:
        return data
    return codecs.getincrementaldecoder("utf-8")().decode(data[:BOUND], False).encode("utf-8")


def valid(data):
    try:
        data.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


results = []


def probe(name, text, locale=None, expect_lines=1, check_bound=True, via_stdin=False):
    proc, seconds = fold(text, locale, via_stdin)
    raw = proc.stdout
    body = raw[:-1] if raw.endswith(b"\n") else raw
    entry = {"name": name, "locale": locale or "ambient", "rc": proc.returncode,
             "seconds": round(seconds, 2), "bytes": len(body)}
    notes = []
    if proc.returncode != 0:
        notes.append("exit %d: %s" % (proc.returncode, proc.stderr.decode("utf-8", "replace")[:120]))
    if check_bound and len(body) > BOUND:
        notes.append("output %d bytes exceeds the %d-byte bound" % (len(body), BOUND))
    if not valid(body):
        notes.append("output is not valid UTF-8")
    if body != expected(text):
        notes.append("output is not the boundary-truncated input")
    if expect_lines == 1 and b"\n" in body:
        notes.append("output carries a line break")
    entry["result"] = "pass" if not notes else "fail"
    entry["notes"] = notes
    results.append(entry)
    return entry


# A cut that leaves exactly one, two, and three bytes of a three-byte character
# in place, and the same for a four-byte character.
for unit, width in (("中", 3), ("\U0001f600", 4)):
    for pad in range(0, width):
        probe("pad %d then %d-byte characters" % (pad, width),
              ("A" * pad) + unit * 900)

# Exactly at the bound, one byte over, and one byte over where the dropped byte
# is the leading byte of a character rather than a whole ASCII byte.
probe("ascii exactly at the bound", "B" * 1200)
probe("ascii one byte over the bound", "B" * 1201)
probe("bound cuts a character whose leading byte is the 1201st",
      ("中" * 400) + "C", check_bound=True)
probe("bound falls exactly on a character boundary", "中" * 400)

# The fold's declared scope: it bounds text, it does not repair bytes the caller
# already had. A lone 0xFF must not hang it or lose the whole note.
probe("input already carries an undecodable byte", ("A" * 1195) + "\ufffd" + ("中" * 10))
probe("input ends inside a character it did not create", ("A" * 1198) + "中")

# Size: a note far past the bound must stay bounded and must not take long.
probe("1 MiB of multibyte text", "中" * 350000, via_stdin=True)

# Locale independence: the same note must fold to the same bytes whatever the
# caller's locale, because the old fold's cut inherited it.
locales = ["C", "C.UTF-8", "en_US.UTF-8", "POSIX"]
loc_outputs = {}
for loc in locales:
    proc, _ = fold(("A" * 1) + "中" * 600, loc)
    loc_outputs[loc] = proc.stdout
same = len(set(loc_outputs.values())) == 1
results.append({
    "name": "identical output under every caller locale",
    "result": "pass" if same else "fail",
    "bytes": {k: len(v) - 1 for k, v in loc_outputs.items()},
    "valid": all(valid(v[:-1]) for v in loc_outputs.values()),
    "notes": [] if same else ["fold output differs by locale"],
})

report = {"root": ROOT, "probes": results,
          "pass": sum(1 for r in results if r["result"] == "pass"),
          "fail": sum(1 for r in results if r["result"] == "fail")}
os.makedirs(OUT, exist_ok=True)
json.dump(report, open(os.path.join(OUT, "report.json"), "w"), indent=2)
print(json.dumps(report, indent=2))
