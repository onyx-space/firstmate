import json, os, re, sys, glob

EV = "/Users/onyx/.no-mistakes/evidence/01M297S7MSZN3AR2EDM8EG6YHT"
WORK = os.path.dirname(os.path.abspath(__file__))

def load(name):
    d = os.path.join(WORK, name)
    out = {"dir": d}
    for f in ("env.txt", "stderr.txt", "stdout.txt", "windows-after.txt"):
        p = os.path.join(d, f)
        out[f] = open(p, errors="replace").read() if os.path.exists(p) else ""
    out["env"] = dict(
        line.split("=", 1) for line in out["env.txt"].splitlines() if "=" in line
    )
    for key in ("pool-state-before.json", "pool-state-after.json"):
        p = os.path.join(d, key)
        out[key] = json.load(open(p)) if os.path.exists(p) else None
    return out

def owner_field(state):
    if not state:
        return None
    w = state["worktrees"][0]
    return w.get("owner_started_at")

def owner_in_stderr_lines(o):
    return [l for l in o["stderr.txt"].splitlines() if l.startswith(("REFUSED", "teardown:", "Treehouse's pool state"))]

checks = []
def check(scn, ok, label, detail=""):
    checks.append({"scenario": scn, "ok": bool(ok), "label": label, "detail": detail})

o = load("01-release-superseded-claim")
check("01", o["env"].get("exit") == "0", "occupant teardown exits 0", o["env"].get("exit", ""))
check("01", "superseded" in o["stderr.txt"], "stderr names the superseded claim")
check("01", owner_field(o["pool-state-before.json"]) is not None, "real treehouse owner stamp present before")
check("01", owner_field(o["pool-state-after.json"]) is None, "real treehouse slot returned (owner stamp cleared)")
check("01", o["env"].get("current_meta_present") == "no", "occupant record removed")
check("01", o["env"].get("stale_meta_present") == "yes", "stale record retained")
check("01", "main:fm-current-task" not in o["windows-after.txt"], "occupant pane killed")

o = load("02-release-base-commit-deadlock")
check("02", o["env"].get("exit") != "0", "pre-fix teardown refuses", o["env"].get("exit", ""))
check("02", "is also task stale-task's recorded worktree" in o["stderr.txt"], "pre-fix refusal is the reported deadlock")
check("02", owner_field(o["pool-state-after.json"]) is not None, "pre-fix slot never returned")
check("02", o["env"].get("current_meta_present") == "yes" and o["env"].get("stale_meta_present") == "yes", "pre-fix both records left stuck")

o = load("03-incident-recovery-both-records")
check("03", o["env"].get("exit") == "0", "first (occupant) teardown exits 0")
check("03", o["env"].get("second_exit") == "0", "second (stale) teardown exits 0", o["env"].get("second_exit", ""))
check("03", o["env"].get("current_meta_present") == "no" and o["env"].get("stale_meta_present_after_second") == "no",
      "both records cleared")

o = load("04-refusal-reverse-superseded-side")
check("04", o["env"].get("exit") != "0", "superseded side refuses")
check("04", "names task current-task as the slot's current occupant" in o["stderr.txt"],
      "refusal names the slot's true occupant")
check("04", owner_field(o["pool-state-after.json"]) is not None, "slot still held after refusal")
check("04", o["env"].get("current_meta_present") == "yes" and o["env"].get("stale_meta_present") == "yes",
      "neither record touched")

for scn, name, label in [
    ("05", "05-refusal-no-owner-record", "no pool owner start: refuses"),
    ("06", "06-refusal-both-claims-predate-owner", "both claims predate the owner: refuses"),
    ("07", "07-refusal-secondmate-co-claimant", "secondmate co-claimant: refuses"),
]:
    o = load(name)
    check(scn, o["env"].get("exit") != "0", label, o["env"].get("exit", ""))
    check(scn, "is also task stale-task's recorded worktree" in o["stderr.txt"], "keeps the slot-collision refusal")
    if scn == "05":
        # this mode strips the owner stamp by construction, so the observable
        # proof that the slot was not returned is that treehouse never ran.
        check(scn, "Worktree returned to pool" not in o["stdout.txt"], "slot not returned (treehouse return never ran)")
    else:
        check(scn, owner_field(o["pool-state-after.json"]) is not None, "slot not returned")
    check(scn, o["env"].get("current_meta_present") == "yes" and o["env"].get("stale_meta_present") == "yes",
          "both records preserved")

o = load("08-refusal-unlanded-shared-copy")
check("08", o["env"].get("exit") != "0", "unlanded shared copy: refuses")
check("08", "uncommitted changes" in o["stderr.txt"], "refusal comes from the shared-copy proof")
check("08", o["env"].get("slot_scratch_present") == "yes", "uncommitted file untouched")
check("08", o["env"].get("current_meta_present") == "yes" and o["env"].get("stale_meta_present") == "yes",
      "both records preserved")

o = load("09-refusal-unowned-slot-process")
check("09", o["env"].get("exit") != "0", "unowned process rooted in the slot: refuses")
check("09", "is still rooted in" in o["stderr.txt"] and "nor a live descendant" in o["stderr.txt"],
      "refusal names the unowned pid")
check("09", o["env"].get("leaked_pid_alive_after") == "yes", "the unaccounted process was not killed")
check("09", owner_field(o["pool-state-after.json"]) is not None, "slot not returned")

o = load("10-no-force-ship-path-reading-engages")
check("10", "superseded" in o["stderr.txt"], "the reading also engages on the ordinary non-force ship path")
check("10", o["env"].get("teardown_force") == "none", "no --force used in that run")

fails = [c for c in checks if not c["ok"]]
for c in checks:
    print(("PASS " if c["ok"] else "FAIL ") + c["scenario"] + " " + c["label"] + ((" :: " + c["detail"]) if c["detail"] else ""))
print("---")
print(f"{len(checks)-len(fails)}/{len(checks)} checks passed")
json.dump({"checks": checks, "failed": len(fails)}, open(os.path.join(WORK, "verify.json"), "w"), indent=2)
sys.exit(1 if fails else 0)
