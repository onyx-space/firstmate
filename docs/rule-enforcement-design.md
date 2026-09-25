# Rule enforcement design: making a declared rule actually run

A rule in an injected file is read once, at the start of a session, as prose.
The behaviour it governs happens much later, one tool call at a time, and nothing between the two connects them.
That gap is the defect this document designs against: the rule text is present and the action still misses it.

The measurements behind the design come from one long firstmate session (1672 assistant messages), and they are the reason the first batch below is what it is:

- The glyph rule (`a reply and its thinking carry no ✓, ✗ or Hmm marks`, as its owning text states it) was broken about 22,833 times inside that scope: 21,889 in thinking, 944 in replies. A further 225 glyphs sat in tool arguments, which the rule as written does not cover and the gate below deliberately adds, so the owning text must be widened before the gate cites it.
- The dispatch-shape rule (a handoff artifact in `~/memory/handoffs/`, plus exactly one `wire send`) ran 111 sends, of which 4 also wrote the artifact.
- Dispatch authorization (information, a question and a report are not a dispatch) was broken twice, and 10 or more questions were asked in chat instead of through `request_user_input`.
- Closing a reply with a menu of choices happened about 6 times; a route that was walked but not reported, 4 to 5 times; a write outside the declared write roots, once; a `查`/`研究` trigger that skipped a read-only check, once.

## 1. The judgeability boundary

Three classes, and the middle one is where most of the value is.

**Text-shaped (mechanical on bytes).** The violation exists as bytes at a known place: a glyph in a file, a missing artifact on disk, a path outside a root, a PR body whose visible part is English, a commit subject with no conventional prefix.
A checker can fail these, because "does this byte exist" needs no judgment.

**Event-shaped (mechanical on an intercepted action).** The violation is a tool call that is about to happen: a `wire send` with no handoff behind it, a write outside the allowed roots, a `cd` into a checkout, a merge with no authorizing instruction, a shell command that arms the watcher by hand.
A PreToolUse hook or a turn-end hook can refuse these *at the moment*, because the harness knows the tool, its arguments, and the turn it is in.

**Judgment-shaped (not mechanizable from the action alone).** Whether a report is a menu, whether the question that was asked was the question to ask, whether a message was an authorization or information, whether a caveat mattered.
No gate can decide these from the call itself: the same bytes are a correct report in one context and a menu in another.
A gate can still key on a mechanical corollary of the shape — a turn's trigger text, the presence of a state-changing call — but that predicate is a **proxy** for the judgment, not the judgment, and the table labels it as one; where no corollary exists the rule is marked **not mechanizable** and the smallest human practice is named instead.

A rule can be text-shaped and event-shaped at once; the placement rule below decides which one a gate uses.

## 2. Where a gate goes

Placement is decided by where the violation first becomes observable, not by where the rule is written:

1. **The violation is bytes in a tracked repository at a known path** (a doc, a script, a workflow, a commit subject, an inventory): a **CI checker**, added to the fleet's read-only check (`~/code/origmd/scripts/check.mjs`) where the repository being checked is a fleet repository, and to that repository's own CI otherwise.
   This is the cheapest rung: no hook, no harness, and it fails the same way for every agent and every human.
2. **The violation is a tool call the harness is about to make** (a shell command, a file write, a dispatch, a subagent launch): a **PreToolUse seatbelt**, in the harness the action is performed through, with the *policy* owned once (the existing shape: `bin/fm-arm-command-policy.mjs` owns the classification, `bin/fm-arm-pretool-check.sh` renders each harness's answer).
   The seatbelt reads the call, never the conversation: this is what keeps its false-positive rate and its cost small.
3. **The violation is only visible once the turn is over** (a reply shipped with no artifact, a promise with no follow-up, a glyph in the answer): a **turn-end / Stop hook**, which runs on the finished turn and either appends a corrective line to the model's own context or records the miss.
   A Stop hook cannot un-send a reply, so its value is correction and measurement, not prevention.
4. **The violation is only visible to a reader's intent**: **one injected line at the moment of the decision** is the last resort, and it is a reinforcement, not a gate.
   A rule that needs it is also a candidate for the "not mechanizable" line: an injected line that has already failed once at scale is evidence about the rule's shape, not about the model's diligence.
5. **Nothing**: the rule is marked not mechanizable, and the smallest human practice is named.

Two constraints hold at every rung.
The rule's text stays owned by origmd — `~/code/origmd/rules/*.md`, the injected `~/code/origmd/inject/global-core.md`, or the fleet skill that owns it — rather than copied here (a checker cites the rule; it never restates it, and firstmate adds no second copy).
And no gate may block a *repair*: if the only way to return a system to a good state is the action the gate refuses, the gate is wrong, not the repair.

## 3. The table

`落点` names the enforcement point; `验收` names the observation that proves it, and every acceptance is written so a recorded instance can be replayed against it.

| 规则 | 可判形式 | 落点 | 验收怎么证 |
|---|---|---|---|
| A reply and its thinking carry no `✓` / `✗` / `Hmm`; the gate also reads tool arguments, a widening the owning text must make before the gate cites it | the glyphs, in the finished turn's own text and its tool arguments, matched as bytes | **Stop hook** (pi: the turn-end extension; other harnesses: their turn-end hook) appends one corrective line; **session-log counter** in the fleet's check reports the rate | replay a recorded reply that carried a `✗`: the corrective line appears in the model's next context; the checker's count for that session drops to zero on a re-run of the fixture |
| A dispatch is a handoff artifact in `~/memory/handoffs/` **plus one** `wire send` | the `wire send` call whose body is task-shaped, checked against an existing `~/memory/handoffs/…` path named in the same body | **PreToolUse** on `wire send` (`bin/fm-arm-command-policy.mjs` classifies; a sibling policy owns this predicate) | replay a recorded send with no artifact → refused, naming the missing artifact and the rule; the 4 recorded sends that carried an artifact → allowed |
| Information, a question and a report are not a dispatch | **proxy** for the authorization judgment (itself not mechanizable): the turn's trigger text (captain message) plus the presence of a state-changing call in the same turn | **PreToolUse**, turn-scoped: the seatbelt marks a `查`/`研究`/report-shaped turn read-only and refuses write, dispatch and card changes in it | replay a recorded read-only turn with a write injected → refused; an ordinary turn is untouched |
| A question is asked through `request_user_input`, not in chat, and a reply does not close with a menu | **not mechanizable** from the call: the same bytes are a question or a report depending on what the reader already knows | none | smallest practice: before sending a reply that ends with choices, the agent rereads the captain's last message and asks whether a decision is actually open; the fleet's own `/ahoy` recap is the human backstop |
| A written artifact lands in a declared write root | the target path, against the declared roots (already enforced by `~/code/origmd/extensions/write-scope.ts`, the pi `tool_call` guard that reads the list out of the injected file) | **PreToolUse / harness write gate** (existing: `~/code/origmd/extensions/write-scope.ts`) | already proven: a write outside the roots is refused by name; the design adds only the missing half below |
| The list the write-root refusal reads back is the list the rule states | the same text, parsed by the checker's reader and by the refusal's own reader | **CI checker** in the fleet's check (`~/code/origmd/scripts/check.mjs`, write routing) | add a root to a bullet's tail, or name one this endpoint lacks → the checker fails on that list; the read-back stays in step |
| A commit subject carries a conventional prefix; a commit body does not carry an agent co-author | the subject line and the trailer set, in the repository's own history | **CI checker** (fleet check, run over the pushed range) | replay a bad subject and a `Co-Authored-By` trailer on a scratch branch → refused by name; the repository's own history passes |
| The visible part of a captain-owned repository's PR description is Chinese and the English body is folded | the PR body's shape: the fold marker, and the text before it | **CI checker** (the repository's own workflow, beside the existing attestation check) | a body with no fold → fails naming the shape; a compliant body (PR #37 is the recorded sample) passes, and the attestation check keeps passing because the comment stays in the body |
| A merge names a current authorizing instruction, or the standing posture | **not mechanizable** as intent; the *mechanical* half is that every merge goes through the guarded entrypoint | **PreToolUse** on the lower-level forge merge command, and the existing `bin/fm-pr-merge.sh` guard | a direct `gh pr merge` is refused naming the entrypoint; a merge through it records the authorizing line (already the case for the red-check refusal) |
| A route that was walked is reported, and a route that was not walked does not appear | **not mechanizable**: this is a comparison between what was done and what is claimed | none | smallest practice: the reply's own report lists the actions taken in the order taken, so an omission is a missing line rather than a hidden one |
| A `查`/`研究` trigger performs its read-only check | the turn's trigger, plus at least one read-only tool call in it | **Stop hook**: a turn triggered read-only that ends with no read-only call gets one corrective line | replay the recorded `fleet-accent` turn → the corrective line appears; an ordinary turn is unaffected |

## 4. False positives and cost

A gate is only worth building when the cost of its false block is smaller than the cost of the miss it prevents, and that comparison is different per rung.

- **CI checker**: a false failure blocks a pull request, and the reader pays in one round trip; the escape is a deliberate, visible edit to the checker (a pull request of its own), which is why checkers must assert only what the fleet is willing to defend in public.
- **PreToolUse seatbelt**: a false refusal blocks a *tool call*, and the agent pays immediately by re-wording it; the escape must be a named, attended override (the existing shape: an explicit captain instruction naming the single check waived), never an environment variable a session can set for itself.
- **Stop hook**: a false correction costs one wasted sentence and cannot lose work, so it is the right rung for a rule whose detection is uncertain.
- **Injected line**: a false line blocks nothing, so its cost is not a refusal but clutter that dulls every later line; the escape is to delete the line once the rule is gated elsewhere, and a line that has survived two sessions without moving the miss rate is evidence about the rule's shape rather than a reason to keep it.
- **Never**: a gate whose refusal can strand a system (a merge the captain ordered, a repair of a broken state) is not built, or is built as a warning plus a recorded miss.

Every refusal names three things: the rule's own file and line, the exact condition that fired, and the smallest change that satisfies it.
A gate that cannot name those three is a gate whose false positives will be worked around blindly, which is worse than the miss.

## 5. The first batch

Cheapest first, each with its acceptance.

1. **Glyph rule at the turn end.** The violation is a byte in text the harness already holds when the turn ends, and the correction is one line.
   Placement: the pi turn-end extension (`.pi/extensions/fm-primary-turnend-guard.ts`), with the predicate owned once so other harnesses' turn-end hooks reuse it.
   Acceptance: replay a recorded reply that carried a glyph and show the corrective line in the next context; then show the session-log count for a clean fixture at zero.
   Cost: no new process, no new repository, and a false positive costs one sentence.
2. **Dispatch pairing at `wire send`.** The rule is the fleet's own (`~/code/origmd/rules/long-lived-lanes.md`: the artifact in `~/memory/handoffs/` plus one `wire send`), the violation is a single call, and the measurement is already in hand (4 of 111).
   Placement: a PreToolUse policy beside `bin/fm-arm-command-policy.mjs`; the predicate refuses a task-shaped `wire send` that names no existing handoff artifact.
   Acceptance: replay the recorded sends without an artifact and show each refused with the missing path named; replay the 4 that carried one and show them allowed; show one ordinary chat-shaped `wire send` unaffected.
   Cost: refusal is re-worded in place, and the escape is the captain naming the action.
3. **Read-only turn gate.** The trigger is in the harness's own hands and the check is a tool-call class, so both halves are mechanical.
   Placement: the same PreToolUse policy, turn-scoped by the trigger text.
   Acceptance: inject a write into a recorded `查` turn and show it refused; run an ordinary turn and show no change.
   Cost: a misread trigger costs one re-statement; the trigger's own words are quoted in the refusal.

## 6. Boundaries

- No new resident process: every gate above runs per event (a tool call, a turn end, a CI job) and exits.
- No new repository: the CI-side checks join `~/code/origmd/scripts/check.mjs`, the hook-side policies join `bin/` in the repository whose harness performs the action, and the vault's own rules are not restated anywhere.
- The rule text stays owned by origmd — `~/code/origmd/rules/*.md`, the injected `~/code/origmd/inject/global-core.md`, or the fleet skill that owns it — rather than copied here; a checker cites it and a hook names it.
- The existing gates are read before a new one is written: `bin/fm-arm-pretool-check.sh` with `bin/fm-arm-command-policy.mjs` (shell policy), `bin/fm-cd-pretool-check.sh` (`docs/cd-guard.md`), `bin/fm-subagent-pretool-check.sh` (`docs/subagent-guard.md`), the turn-end hooks (`docs/turnend-guard.md`), `~/code/origmd/extensions/write-scope.ts` (the write-root refusal), and `~/code/origmd/scripts/check.mjs`.
- This document designs; it implements nothing. Each item above is a task for a later, separately authorized change.
