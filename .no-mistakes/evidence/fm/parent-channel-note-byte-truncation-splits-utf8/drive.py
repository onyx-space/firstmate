#!/usr/bin/env python3
"""End-to-end drive of firstmate's parent channel with long multibyte notes.

usage: drive.py <repo-root> <out-dir>

Builds a real secondmate home (identity marker + local parent binding) with
direct children whose terminal ledger notes are long enough to cross the
channel's 1200-byte bound at several character-splitting alignments, then runs
the REAL bin/fm-inactive-reconcile.sh scanner -- the publisher the watcher runs
on every poll -- and inspects the parent home's channel file.

Every assertion is on the bytes the product wrote.
"""
import codecs
import json
import os
import subprocess
import shutil
import sys
import tempfile

ROOT = os.path.abspath(sys.argv[1])
OUT = os.path.abspath(sys.argv[2])
BOUND = 1200

CJK = "中"
EMOJI = "\U0001f600"
CJK_INTRO = "修好了：中文不会再被切成半个字"
EMOJI_INTRO = "修好了：表情也不会被切成半个"

cases = []
for unit, mod, intro in (("cjk", CJK, CJK_INTRO), ("emoji", EMOJI, EMOJI_INTRO)):
    for k in range(0, 8):
        note = ("A" * k) + (intro + " ") + (mod * 600)
        cases.append({"id": "child-%s-%d" % (unit, k), "unit": unit, "pad": k,
                      "note": note})

world = tempfile.mkdtemp(prefix="fm-utf8-world-")
main = os.path.join(world, "main")
mate = os.path.join(world, "mate")
try:
    for path in ("state", "data", "config"):
        os.makedirs(os.path.join(main, path), exist_ok=True)
        os.makedirs(os.path.join(mate, path), exist_ok=True)

    with open(os.path.join(mate, ".fm-secondmate-home"), "w") as fh:
        fh.write("mate\n")
    with open(os.path.join(mate, ".fm-secondmate-parent"), "w") as fh:
        fh.write("schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n" % main)

    for case in cases:
        cid = case["id"]
        with open(os.path.join(mate, "state", cid + ".meta"), "w") as fh:
            fh.write("window=firstmate:fm-%s\n" % cid)
            fh.write("worktree=%s/projects/%s\n" % (mate, cid))
            fh.write("project=alpha\nharness=codex\nkind=ship\n")
            fh.write("mode=no-mistakes\nyolo=off\nspawn_gen=s4242.%d\n" % case["pad"])
            fh.write("pr=https://example.test/owner/repo/pull/1\n")
        # The child's own terminal ledger line, with the long note in it.
        with open(os.path.join(mate, "state", cid + ".status"), "wb") as fh:
            fh.write(b"working: delegated scope\n")
            fh.write(b"done: " + case["note"].encode("utf-8") + b"\n")

    env = dict(os.environ)
    env.update({
        "FM_ROOT_OVERRIDE": ROOT,
        "FM_HOME": mate,
        "FM_STATE_OVERRIDE": os.path.join(mate, "state"),
        "FM_DATA_OVERRIDE": os.path.join(mate, "data"),
        "FM_CONFIG_OVERRIDE": os.path.join(mate, "config"),
    })
    scan = subprocess.run([os.path.join(ROOT, "bin", "fm-inactive-reconcile.sh"), "scan"],
                          env=env, cwd=world, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    channel = os.path.join(main, "state", "mate.status")
    first = open(channel, "rb").read() if os.path.exists(channel) else b""
    first_lines = len([l for l in first.split(b"\n") if l])

    # At-most-once: with the delivery receipt gone, the same outcome is offered
    # to the channel again, so the fold has to reproduce the same bytes for the
    # exact-content append to suppress it. A fold that depended on the caller's
    # locale would append a duplicate line here.
    shutil.rmtree(os.path.join(mate, "state", "terminal-outcomes"), ignore_errors=True)
    subprocess.run([os.path.join(ROOT, "bin", "fm-inactive-reconcile.sh"), "scan"],
                   env=env, cwd=world, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    raw = open(channel, "rb").read() if os.path.exists(channel) else b""

    def expected_fold(text):
        folded = text.replace("\t", " ").replace("\r", " ").replace("\n", " ")
        data = folded.encode("utf-8")
        if len(data) <= BOUND:
            return folded.encode("utf-8")
        # The largest prefix of <= 1200 bytes that ends on a character boundary.
        return codecs.getincrementaldecoder("utf-8")().decode(data[:BOUND], False).encode("utf-8")

    lines = raw.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()

    results = []
    for case in cases:
        cid = case["id"]
        prefix = ("]: child %s done: " % cid).encode("utf-8")
        hits = [ln for ln in lines if prefix in ln]
        entry = {"id": cid, "pad": case["pad"], "unit": case["unit"], "lines": len(hits)}
        if len(hits) != 1:
            entry["result"] = "missing"
            results.append(entry)
            continue
        body = hits[0].split(prefix, 1)[1]
        note = body.split(b" pr=", 1)[0]
        want = expected_fold(case["note"])
        entry["note_bytes"] = len(note)
        entry["want_bytes"] = len(want)
        entry["bound_ok"] = len(note) <= BOUND
        entry["deterministic"] = note == want
        entry["human_readable"] = (CJK_INTRO.encode() in note) or (EMOJI_INTRO.encode() in note)
        try:
            note.decode("utf-8")
            entry["note_valid"] = True
        except UnicodeDecodeError as exc:
            entry["note_valid"] = False
            entry["error_at"] = "%d..%d" % (exc.start, exc.end)
        entry["result"] = "pass" if (entry["bound_ok"] and entry["deterministic"]
                                     and entry["human_readable"] and entry["note_valid"]) else "fail"
        results.append(entry)

    # A consumer that strictly decodes the whole record, as the field failure
    # describes: one bad byte in one line makes every line unreadable.
    try:
        text = raw.decode("utf-8")
        whole_ok = True
        whole_note = "decoded %d bytes, %d lines" % (len(raw), len(text.splitlines()))
    except UnicodeDecodeError as exc:
        whole_ok = False
        whole_note = "UnicodeDecodeError: %s at byte %d (0x%02x) of %d" % (
            exc.reason, exc.start, raw[exc.start], len(raw))

    # The fold through the production library itself: preserved behaviour that
    # no CLI publisher can carry multi-line text into on these hosts.
    lib_probe = subprocess.run(
        ["bash", "-c", '. "$1/bin/fm-parent-channel-lib.sh"; fm_parent_channel_clean_note "$2"',
         "_", ROOT, "第一行\n第二行\t末"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    exact = subprocess.run(
        ["bash", "-c", '. "$1/bin/fm-parent-channel-lib.sh"; fm_parent_channel_clean_note "$2"',
         "_", ROOT, "B" * 1200],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    report = {
        "root": ROOT,
        "scan_rc": scan.returncode,
        "channel": channel,
        "channel_bytes": len(raw),
        "channel_lines": len(lines),
        "channel_lines_after_replay": len([l for l in raw.split(b"\n") if l]),
        "channel_lines_first_pass": first_lines,
        "at_most_once": first_lines == len(lines),
        "whole_file_strict_decode": whole_ok,
        "whole_file_note": whole_note,
        "cases": results,
        "cases_pass": sum(1 for r in results if r.get("result") == "pass"),
        "cases_fail": sum(1 for r in results if r.get("result") == "fail"),
        "cases_missing": sum(1 for r in results if r.get("result") == "missing"),
        "fold_collapses_newline_and_tab": lib_probe.stdout == "第一行 第二行 末\n".encode("utf-8"),
        "fold_collapse_output": lib_probe.stdout.decode("utf-8", "replace").rstrip("\n"),
        "fold_at_exact_bound_unchanged": exact.stdout == (b"B" * 1200 + b"\n"),
        "scan_output": scan.stdout.decode("utf-8", "replace")[-800:],
    }
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "report.json"), "w") as fh:
        json.dump(report, fh, indent=2)
    with open(os.path.join(OUT, "channel.bytes"), "wb") as fh:
        fh.write(raw)
    print(json.dumps(report, indent=2))
finally:
    shutil.rmtree(world, ignore_errors=True)
