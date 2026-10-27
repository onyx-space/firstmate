// Live probe driver: reproduces Pi's programmatic run trigger.
//
// The supervision branch delivers its own hidden processing request with
// pi.sendMessage(..., { triggerTurn: true }) while main is idle. Pi starts that
// run as a CUSTOM message run, so before_agent_start carries `messageType:
// "custom"` and a `message` instead of a `prompt`.
import { appendFileSync, writeFileSync } from "node:fs";

const log = process.env.FM_PROBE_LOG || "/tmp/fm-live-probe.log";

function note(line: string): void {
  try {
    appendFileSync(log, `${line}\n`);
  } catch {}
}

export default function (pi: any) {
  note("driver: loaded");
  pi.on?.("session_start", (_event: unknown, _ctx: unknown) => {
    const lockPath = process.env.FM_PROBE_LOCK;
    if (lockPath) {
      // This process owns the fleet lock: the lock names a pid in its own
      // ancestry, and the extension's walk starts at process.pid.
      writeFileSync(lockPath, `${process.pid}\n`);
      note(`driver: wrote fleet lock pid=${process.pid}`);
    }
    // Deliver once the session is settled and idle, exactly like the branch
    // delivering its hidden request into an idle main.
    const timer = setTimeout(() => {
      note("driver: sending promptless custom run");
      pi.sendMessage(
        {
          customType: "fm-probe-programmatic-request",
          content: "hidden programmatic request from the branch",
          display: false,
        },
        { triggerTurn: true },
      );
    }, 2500);
    timer.unref?.();
  });
  pi.on?.("before_agent_start", (event: any) => {
    note(
      `driver: before_agent_start messageType=${String(event?.messageType)} ` +
        `hasPrompt=${typeof event?.prompt === "string"} ` +
        `keys=${Object.keys(event ?? {}).join(",")}`,
    );
  });
}
