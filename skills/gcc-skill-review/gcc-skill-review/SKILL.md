---
name: gcc-skill-review
description: Per-step reliability eval of a user's own skill or workflow. Maps steps as deterministic/probabilistic, adds one evidence file per step, writes per-step claude plugin eval checks against a known-answer sample, runs 5 fresh sessions per model, fixes the earliest failing step (one sentence or code), reruns to prove it. Use for "review my skill", "find the weak step", "test my skill", "skill is unreliable", "different answer every run", "eval my skill", "GCC skill review", "Kem's skill review". Not for code diffs (code-review), untrusted repos (danger-protocol), or explaining a project (gcc-walk).
---

# Find the weak step

Per step ask: probabilistic (model judgement: choosing, summarising, recommending), deterministic (code: listing, counting, sorting, arithmetic, saving a file), or could it be deterministic?

## Rules

- Never touch the original skill. All changes go in a copy; the original changes only on the person's yes after the proof.
- Never make anything up. Verdicts quote the step's file; counts come from runs that happened; an unfinished run is reported as unfinished.
- Open the step's file before believing a failed check. Read one passing run in full before believing a pass.
- Fix the earliest fault only; later failures may be its echo.
- One change per round (one sentence, one step made code, or one check fixed), then rerun. Never a rewrite.
- Plain words: "step 3 picked the wrong five".

## Before you start

Read the skill's `SKILL.md` and every file it points at.
Ask for whatever is missing, in one structured question:

1. The skill, by name or path.
2. One sample input with known right answers. If none, offer to invent a small one with planted answers (shape: `references/example.md`) and have them confirm the answers.
3. Models. Recommend their usual model plus Haiku (the smallest model is the one that trips where the others do not).

Skill runs scripts (needs a shell)? Check now (Linux/WSL; plain Windows: use WSL): `command -v bwrap socat`, and `sysctl kernel.apparmor_restrict_unprivileged_userns` must not be 1 (Ubuntu 24.04+ default; every sandboxed shell command then fails with `apply-seccomp … setgroups`). The sandbox also cannot read the user's home or reach the network, so a skill that installs or downloads at run time cannot run there. Either tool missing → the eval refuses every run at 0 turns; any of these → tell the person before stage 1 and offer, in one structured question: fresh sessions instead (one at a time, each unsandboxed on its own throwaway copy of the sample, scored by the same checks; say the isolation is weaker), fixing the host (installing `socat` or changing AppArmor needs their go), or stopping after stage 3 with the pattern checks proven on hand-written good and wrong files.

Working folder (`<skill>-review/` below): never inside the original, never in `.claude/skills/` or `.agents/skills/` (it would load as a skill). In Glitch: `_local/gcc-skill-review/<skill>-review/`; elsewhere: `<skill>-review/` in the project root.
Save each stage's output there before the next stage.

## 1. Map

List every step in order: code or judgement, what it takes in, what it leaves that could be checked.
List what the skill leaves unsaid, ranked by how likely it is to change the result; flag the top three.
Mermaid flowchart: `["…"]` code-able, `("…")` judgement, `{{"unsaid: …"}}` flags.
Save `map.md`; show it; the flags are the first suspects.
Usual unsaid: where a file is saved, whether a small or odd item counts, which formula, how best/worst is measured.

## 2. Evidence

Copy the skill to `<skill>-review/copy/`; change only the copy.
Each step saves its result to its own file before the next starts, keeping existing file names, ending with:

```
Picked: every item kept, by name, then the rule used.
Left out: what was dropped.
Why: one sentence.
```

Write them at fixed paths in the folder the session starts in (e.g. `evidence/03-top-five.md`): a check cannot follow a name the model chooses.
A step with two outputs, or whose result is the person's own words: one labelled line per output, e.g. `Picked (offered): …` and `Picked (chosen): …`; aim each check at its label (`^Picked \(chosen\):`).
Fix nothing else, even what you can see is unsaid.

## 3. Checks

Per step: one check that everything in the known answer was picked, one that nothing outside it was.
Fact → pattern check aimed at the `Picked:` line (a whole-file pattern passes a name found in a raw ranking but dropped from the pick).
Judgement → short `llm` rubric.
No known answer for a step → ask; never invent it.
Write them as `claude plugin eval` cases in `<skill>-review/copy/evals/` (shapes: `references/plugin-eval.md`; `--help` wins on conflict).
Break it first: run once (this is also stage 4's trial), show every check passes on the good files; hand-write one wrong file per step, show its check fails. A check that passes a wrong file is fixed before going on.

## 4. Five runs

Get a yes on the cost first (runs × models, each a full session on their subscription), in one structured question. Recommend 5 per model.
One trial run, then:

```
claude plugin eval <skill>-review/copy --runs 5 --model <model> --ablation none --no-publish --keep-temp --trust-plugin --allow-tools Write Edit Bash --json <skill>-review/runs/<model>-before.json </dev/null
```

`--no-publish` always (default publishes the report to claude.ai). `--trust-plugin` only for the copy you wrote.
Copy each kept run's step files into `<skill>-review/runs/`, then delete the kept folders.
Trial produced no step files → suspect the case first: runs start in an empty folder and find the sample only by its full path in the prompt.

Table: one row per check in step order, passes out of finished runs (e.g. 3/4 when one of five was refused), one column per model.
Count a run only if its first step's evidence file exists: a run refused at 0 turns, or one that ended normally having done nothing, still passes every `not_contains` check and can pass a rubric.
Each failure: quote its `Picked:` line, give exactly one verdict: the step was wrong · the skill left it open · an earlier step handed it a wrong input · the check was wrong.
Read one all-pass run in full; report anything wrong no check caught.
Save `counts-before.md`.
No `plugin eval` available: five fresh sessions, same checks by hand; say so.

## 5. Fix and prove

Target: earliest "step was wrong" or "skill left it open"; if all passed, what you found in the all-pass run.

1. Write the missing check; show it fails on the kept runs.
2. Find the sentence that allowed it.
3. A rule only the person knows → ask (one structured question, your proposal first). Never choose it.
4. Change only what the failing runs show, in the copy.
5. Arithmetic, sorting, counting, listing or saving a file → say it should be code; offer the script as the fix.
6. A wrong check → fix it, say so.
7. Rerun 5 per model, same flags.

Every check before and after, side by side → `counts-after.md`.

## Hand back

First line: the weak step, the change, the count before → after.
Then: the map with steps to move into code; the sentence before/after or the script; anything a passing run got wrong that no check caught; what was not proven.
Then one structured question: apply to the original (recommend when the after-count is clean), keep in the copy, or run more. Change the original only on yes.

Always state: 5 runs shows a weak step, not a rate (10–20 before quoting a number); wording has a limit, so file locations and arithmetic belong in code; pattern checks are weak on judgement steps.
