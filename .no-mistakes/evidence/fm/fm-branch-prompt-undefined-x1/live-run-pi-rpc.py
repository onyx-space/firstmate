#!/usr/bin/env python3
"""Live drive: run real `pi` in RPC mode with the firstmate extensions loaded,
trigger a programmatic (custom-message) run from a driver extension, and record
every event pi emits until the run settles.

The scenario under test: Pi's programmatic run raises before_agent_start with
`messageType: "custom"` and NO prompt field. The extension must not report an
extension error for it.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, help="FM root passed to the extension")
    ap.add_argument("--extension", required=True, help="extension file under test")
    ap.add_argument("--driver", required=True)
    ap.add_argument("--home", required=True)
    ap.add_argument("--log", required=True, help="probe log written by the driver")
    ap.add_argument("--events", required=True, help="event stream capture")
    ap.add_argument("--lock", action="store_true", help="driver writes the fleet lock")
    ap.add_argument("--prompt", default=None, help="optional real captain prompt to send first")
    ap.add_argument("--settle-seconds", type=float, default=20.0)
    args = ap.parse_args()

    shutil.rmtree(args.home, ignore_errors=True)
    os.makedirs(os.path.join(args.home, "state"), exist_ok=True)
    os.makedirs(os.path.join(args.home, "config"), exist_ok=True)

    env = dict(os.environ)
    env.update(
        {
            "FM_HOME": args.home,
            "FM_ROOT_OVERRIDE": args.root,
            "FM_STATE_OVERRIDE": os.path.join(args.home, "state"),
            "FM_CONFIG_OVERRIDE": os.path.join(args.home, "config"),
            "FM_PROBE_LOG": args.log,
            "FM_PROBE_LOCK": os.path.join(args.home, "state", ".lock") if args.lock else "",
            "PI_OFFLINE": "1",
        }
    )

    cmd = [
        "pi",
        "--mode",
        "rpc",
        "-ne",
        "--no-tools",
        "--no-session",
        "-e",
        args.driver,
        "-e",
        args.extension,
    ]
    events = open(args.events, "w", encoding="utf-8")
    proc = subprocess.Popen(
        cmd,
        cwd="/tmp",
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    seen = {"types": set(), "settled": False}

    def reader():
        for line in proc.stdout:  # type: ignore[union-attr]
            events.write(line)
            events.flush()
            try:
                obj = json.loads(line)
            except Exception:
                continue
            seen["types"].add(str(obj.get("type")))
            if obj.get("type") in ("agent_settled", "agent_end"):
                seen["settled"] = True

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()

    deadline = time.time() + args.settle_seconds
    if args.prompt:
        time.sleep(0.5)
        payload = json.dumps({"id": "p1", "type": "prompt", "message": args.prompt}) + "\n"
        proc.stdin.write(payload)  # type: ignore[union-attr]
        proc.stdin.flush()  # type: ignore[union-attr]
    while time.time() < deadline and not seen["settled"]:
        time.sleep(0.1)
    # Give the extension handlers a beat to finish before shutdown.
    time.sleep(1.0)
    try:
        proc.stdin.close()  # type: ignore[union-attr]
    except Exception:
        pass
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)
    events.close()
    print(json.dumps({"exit": proc.returncode, "settled": seen["settled"], "types": sorted(seen["types"])}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
