// Live probe driver for the control scenario: a real captain prompt.
//
// It only establishes fleet-lock ownership (the lock names a pid in this
// process's ancestry) and records the shape of every before_agent_start event.
// The run itself comes from a real RPC `prompt` command, exactly like a captain
// typing into main.
import { appendFileSync, writeFileSync } from "node:fs";

const log = process.env.FM_PROBE_LOG || "/tmp/fm-live-probe.log";

function note(line: string): void {
  try {
    appendFileSync(log, `${line}\n`);
  } catch {}
}

export default function (pi: any) {
  note("driver: loaded");
  pi.on?.("session_start", () => {
    const lockPath = process.env.FM_PROBE_LOCK;
    if (lockPath) {
      writeFileSync(lockPath, `${process.pid}\n`);
      note(`driver: wrote fleet lock pid=${process.pid}`);
    }
  });
  pi.on?.("before_agent_start", (event: any) => {
    note(
      `driver: before_agent_start messageType=${String(event?.messageType)} ` +
        `hasPrompt=${typeof event?.prompt === "string"} ` +
        `prompt=${JSON.stringify(typeof event?.prompt === "string" ? event.prompt : null)}`,
    );
  });
}
