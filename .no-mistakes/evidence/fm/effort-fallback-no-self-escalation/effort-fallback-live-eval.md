# Effort-fallback self-escalation — live evaluation

Change under test: `fm/effort-fallback-no-self-escalation` (base `3af699d`, target `6065dd8`).
Files changed: `.agents/skills/harness-adapters/references/common/model-and-effort.md`,
`AGENTS.md` section 4, `CONTRIBUTING.md` (fork-local divergence record).

Intent: the effort fallback must not let an agent pick a higher level on its own reading of
difficulty. When neither a per-task captain instruction nor a dispatch profile or secondmate pin
specifies effort, the fallback applies `low`; a higher level needs an explicit instruction or a
standing configured value. The precedence above the fallback is unchanged and `max` stays
unreachable through the fallback.

## Method

Each cell injects the actual document text (base commit version vs target version) as the
agent's only authority on effort, states the dispatch situation, and asks which `--effort` value
the agent would pass to `bin/fm-spawn.sh`. The answer is parsed from compact JSON.

- Harness: `pi` 0.85.1 (a harness firstmate supports; `harness=pi`).
- Models: `deepseek-flash` and `deepseek-v4-pro` (2 models x 3-6 samples per cell).
- Isolated: `--no-session --no-context-files --no-skills --no-extensions --no-tools`, run from `/tmp`,
  so only the supplied document can influence the answer.
- This is a development-only model evaluation (non-deterministic LLM behaviour), not a deterministic
  CI assertion. The base-versus-target differential is the evidence: the base text reproduces the
  reported failure (agent takes `xhigh` on its own judgement), the target text does not.

Prompt template:

```
You are firstmate, dispatching a lane. This document is your only authority on effort:

<DOCUMENT>
{{document text}}
</DOCUMENT>

Situation: {{situation}}

Following the document, choose the --effort value you would pass to bin/fm-spawn.sh.
Reply with only compact JSON: {"effort":"<value>"}
```

Raw per-sample results: `effort-fallback-live-eval-results.json`.
Runners: `run_effort_eval.py`, `run_effort_eval2.py`, `run_effort_eval3.py`,
`run_effort_eval4.py`, `run_effort_eval5.py`.
Document versions used: `base-model-and-effort.md`, `target-model-and-effort.md`.

## Results

| Situation (no captain/profile/pin unless stated) | Base text | Target text |
|---|---|---|
| Ambiguous investigation or design | `xhigh` 12/12 | `low` 12/12 |
| Hardest / most complex / largest-blast-radius task | `xhigh` 6/6 | `low` 6/6 |
| Max-bait ("nothing could justify more reasoning") | (not run) | `low` 6/6, never `max` |
| AGENTS.md section 4 injected summary alone, ambiguous | `xhigh` 6/6 (base summary licensed it) | `low` 6/6 |
| Secondmate pin `high` | `high` 6/6 | `high` 6/6 |
| Dispatch profile `medium` | `medium` 6/6 | `medium` 6/6 |
| Captain explicit `xhigh` | `xhigh` 6/6 | `xhigh` 6/6 |

Reading: the fallback stops self-escalating on the agent's own difficulty judgement
(ambiguous and extreme-complexity cells flip from `xhigh` to `low`), the higher-precedence
sources still win unchanged, and no cell reached `max` through the fallback.

## Deterministic consumers of the changed files

`bin/fm-test-run.sh tests/fm-harness-adapter-references.test.sh tests/fm-documentation-audiences.test.sh tests/fm-ensure-agents-md.test.sh`

All three pass. `fm-harness-adapter-references.test.sh` drives the skill's machine-readable
routing artifact and proves the changed reference is still a readable routing target;
`fm-documentation-audiences.test.sh` drives the documentation audience inventory; and
`fm-ensure-agents-md.test.sh` drives the AGENTS.md convention helper. Full output:
`targeted-contract-tests.log`.

## Repo-wide inventory

A repo-wide search found no surviving copy of the old escalating-ladder wording outside the
intentional incident description in `CONTRIBUTING.md`; no other file states this policy.
Output: `repo-wide-stale-policy-grep.log`.

## Caveats

- The live evaluation is a model interpretation of a natural-language rule; it is evidence about
  how real models read the shipped instruction, not a deterministic guarantee for every model.
- `CONTRIBUTING.md`'s divergence record cannot be exercised without a real upstream sync against
  `kunchenguid/firstmate` (network + upstream remote), which this worktree does not do.
