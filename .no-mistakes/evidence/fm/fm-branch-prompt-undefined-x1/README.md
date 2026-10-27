Targeted validation of the promptless before_agent_start guard
==============================================================

Change under test (target 794d6cb, base 452749b):
  .pi/extensions/fm-branch-supervision.ts   before_agent_start: event.prompt read only when it is a string
  .pi/extensions/fm-primary-pi-watch.ts     before_agent_start: return early when event.prompt is not a string
  tests/fm-pi-branch-extension.test.sh      + test_branch_promptless_programmatic_run_is_not_captain_dialog
  tests/fm-pi-watch-extension.test.sh       + test_pi_programmatic_before_agent_start_consumes_nothing

Product surface
---------------
Both files are Pi extensions. They are loaded by the real `pi` binary (`pi -e <file>`), and Pi itself
raises before_agent_start. A programmatic run (pi.sendMessage(..., {triggerTurn: true}) while idle, which
is how the supervision branch delivers its hidden processing request) raises that event with
messageType=custom and NO prompt field. Pi catches a handler throw and reports it as an
`extension_error` event (console.error in print mode), which is the user-visible failure this change
guards against.

How the live runs were made
---------------------------
1. pi 1.3.0 (real binary), isolated FM_HOME under /tmp, started as
   `--mode rpc -ne --no-tools --no-session -e live-driver-*.ts -e <extension under test>`.
2. live-driver-promptless-run.ts writes the fleet lock for the pi process (the extensions require lock
   ownership to reach the guarded line) and then, once main is idle, sends a custom message with
   triggerTurn:true - the exact shape the branch uses.
3. live-driver-real-prompt.ts (plus an RPC `prompt` command) is the control: a run started by a real
   captain prompt (messageType=user, prompt present).
4. live-run-pi-rpc.py spawned pi, kept stdin open so the process could not exit mid-run, captured every
   event, and shut pi down after the run settled.
5. For the wake-delivery case, FM_ROOT_OVERRIDE pointed at a fixture root whose bin/fm-watch-arm.sh
   (live-watch-arm-fixture.sh) closes with one actionable wake line, which the real extension delivers
   into the real session and consumes.

Results (live-evidence.txt + the .events.jsonl captures)
-------------------------------------------------------
01 PRE-FIX branch supervision, programmatic run      -> 1 extension_error:
     before_agent_start: Cannot read properties of undefined (reading 'trim')
02 FIXED branch supervision, programmatic run        -> 0 extension_errors, run settled normally
03 FIXED primary-pi-watch, programmatic run          -> 0 extension_errors, run settled normally
04 PRE-FIX primary-pi-watch, programmatic run        -> 0 extension_errors (this guard is defensive)
05 FIXED branch supervision, real captain prompt     -> messageType=user, hasPrompt=true, 0 extension_errors
06 FIXED primary-pi-watch, real watcher wake         -> wake delivered as a user run, consumed, 0
                                                        extension_errors, no replacement handoff left behind

Targeted test runs
------------------
  bash tests/fm-pi-branch-extension.test.sh   -> all ok, including
      ok - a promptless programmatic main run neither throws nor enters the captain mirror
  bash tests/fm-pi-watch-extension.test.sh    -> all ok, including
      ok - a promptless before_agent_start neither throws nor consumes a delivered wake

Fails-before / passes-after (same tests, extension files swapped to base 452749b):
  branch test  -> not ok: "before_agent_start threw on {}: Cannot read properties of undefined (reading 'trim')"
  watch test   -> ok (the watcher guard is an invariant, not a failing-before behavior)

Not live-drivable here
----------------------
"a promptless run must not consume a delivered-but-unread wake" needs a wake that Pi has accepted but
whose message_start has not fired yet (main streaming when a followUp is queued). Real Pi always closes
that window at the next message_start, so the window can only be held open by stubbing
sendUserMessage; the repo test does exactly that, and the live runs above confirm the end-to-end path
(wake delivered, consumed, nothing left for a replacement) still works with the guard in place.
