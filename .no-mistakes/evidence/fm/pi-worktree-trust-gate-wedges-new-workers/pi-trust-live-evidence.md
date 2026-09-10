# Pi project-trust gate: live control/treatment evidence

Change under test: `bin/fm-spawn.sh` now probes the resolved pi executable's
`--help` for `--approve` and carries it on every `pi` / `pi-signed` launch whose
executable advertises it.

Verified 2026-09-11 on Pi **0.85.1** (`/opt/homebrew/bin/pi`), the installed binary.

## 1. The launch command the product actually emits

`capture-launch.sh` runs the **real** `bin/fm-spawn.sh` through the full
spawn path (only the tmux backend and `treehouse` are stubbed, exactly as
`tests/fm-spawn-dispatch-profile.test.sh` does) with the **real** pi on PATH, so
both the `--help` probe and the launch line see the installed binary.

Crewmate ship spawn (`pi-crewmate.launch`):

```text
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI FM_PI_HARNESS=pi '/opt/homebrew/bin/pi' --tui-mode regular --approve -e '.../profile-pi-trustcapture-z9c.pi-ext.ts' "$('.../bin/fm-operational-input.sh' encode launch-brief < '.../launch-brief.md')"
```

Scout spawn (`pi-scout.launch`, the kind in the incident):

```text
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI FM_PI_HARNESS=pi '/opt/homebrew/bin/pi' --tui-mode regular --approve -e '.../profile-pi-trustcapture-z9c.pi-ext.ts' "$('.../bin/fm-operational-input.sh' encode launch-brief < '.../launch-brief.md')"
```

`spawn_exit=0`, `resolved_pi=/opt/homebrew/bin/pi`, `kind=scout`.

## 2. Control vs treatment, driven live

`run-arms.sh` takes that product-composed launch line, strips ` --approve` for
the control arm, and runs each in a **real tmux pane** whose cwd is a fresh,
never-trusted firstmate-shaped slot (`.pi/extensions/trust-probe.ts`, `.pi/`,
`AGENTS.md`) - the shape of a brand-new treehouse slot. `PI_CODING_AGENT_DIR`
points at a throwaway agent dir and `PI_OFFLINE=1` is prefixed; **argv is
otherwise the product's own output**.

```text
arm=control   dialog_seen=1 agent_event_seen=0
arm=treatment dialog_seen=0 agent_event_seen=1
```

Control (`arms.control.pane`) - the reported wedge, reproduced:

```text
 Trust project folder?
 /private/tmp/fm-trust-live/arms/wt

 This allows pi to load .pi settings and resources, install missing project
 packages, and execute project extensions.

 → Trust
   Trust parent folder (/private/tmp/fm-trust-live/arms)
   Trust (this session only)
   Do not trust
   Do not trust (this session only)
```

Treatment (`arms.treatment.pane`) - no dialog, and the worker reaches the brief:

```text
 pi v0.85.1
...
[Context]
  AGENTS.md
[Extensions]
  ... profile-pi-trustcapture-z9c.pi-ext.ts, trust-probe.ts
...
 ⁣FIRSTMATE_OP: v1 launch-brief: # Task
```

The scout launch line reproduces identically (`scout-arms.control.pane` /
`scout-arms.treatment.pane`).

## 3. `--approve` writes no trust store

```text
operator_trust_json_unchanged=yes        # ~/.pi/agent/trust.json untouched (mtime 06:51, run at 07:15)
throwaway_agent_trust_json_present=no    # no trust.json written even in the run's own agent dir
```

## 4. Old-Pi / non-Pi guards

`fm-spawn-dispatch-profile.test.log` - `tests/fm-spawn-dispatch-profile.test.sh`
passes end to end, including `Pi launch probing follows the resolved
executable's advertised flags` (0.78.1 omits `--approve`, 0.82.0 omits
`--tui-mode` but keeps `--approve`) and `Pi and pi-signed launches pre-answer
the project-trust gate; non-Pi launches do not`. Those arms drive a stubbed
executable, so they are automated coverage, not live arms - no pre-0.79 pi is
installed on this host and installing one is outside the write boundary.

No other pi launch composition exists outside `bin/fm-spawn.sh`
(`grep -rn 'tui-mode' bin/` returns nothing outside it).
