# GCC SKILL REVIEW

**Find the weak step in your own skill.**

> **The method is Kem's.**
> The approach, the five prompts and the worked example come from Kem's lab page **"Find the Weak Step"** (5 October 2026) for the **[Glitch Cat Club](https://glitchcatclub.com)**.
> Follow Kem on Instagram: **[@kem_glitch](https://www.instagram.com/kem_glitch/)**.
> Published here with Kem's permission, under MIT.
> [blastworks.ai](https://www.blastworks.ai/) packaged it as a skill and added the guard rails and the `claude plugin eval` reference.

## Why

You build a skill.
It works.
The next run gives a different answer or a worse one, and nothing tells you why.
The final answer never shows you which step moved.

> If you want reliability you need verifiability.

This skill looks at your skill one step at a time.
It marks which steps are deterministic (code could do them) and which are probabilistic (they need the model's judgement).
It checks every step as well as the result, then fixes the one that lets you down.

## What it does

1. **Map.** Lists your skill's steps, marks each one deterministic or probabilistic, and flags the three things the skill leaves unsaid that are most likely to change the result. You get a Mermaid diagram.
2. **Evidence.** Makes a copy of your skill in which every step saves its own file, ending in `Picked:` / `Left out:` / `Why:`.
3. **Checks.** Writes one or two checks per step against a sample input where you already know the right answers. It proves each check passes on a good file and fails on a broken one before trusting it.
4. **Five runs.** Runs the copy five times in fresh sessions with `claude plugin eval` and counts passes per step. Each failure gets one of four verdicts: the step was wrong, the skill left it open, an earlier step handed it a wrong input, or the check was wrong.
5. **Fix one step.** Changes one sentence, or turns the step into code, then runs it five times again and shows every check before and after.

Your original skill is never touched.
Everything happens on a copy, and the original changes only when you say yes at the end.

## How to use it

**Claude Code or Glitch:** copy the inner [`gcc-skill-review/`](gcc-skill-review/) folder into your `.claude/skills/` folder, then say "review my skill" or "find the weak step" and name the skill.

**Any other agent:** the five prompts are in [`prompts.md`](prompts.md). Paste them one at a time, in order, with your skill open.

## You need

- Your skill.
- One sample input where you already know the right answers. If you have none, the skill helps you invent one with planted answers.
- Claude Code for the fresh runs (they use your own subscription; the skill asks you to confirm the number of runs before it starts). Outside Claude Code, five fresh chats and the same checks by hand do the same job.
- On Windows, use WSL: a skill that runs its own scripts can't be tested this way on plain Windows.

## Things we learned packaging it

Kem's page says "run it five times with `claude plugin eval`".
Making that work on Claude Code 2.1.319 turned up three traps, now handled in the skill ([`references/plugin-eval.md`](gcc-skill-review/references/plugin-eval.md)):

- **The eval report is published to claude.ai by default.** The skill always passes `--no-publish`.
- **Every run starts in an empty throwaway folder.** Your sample input has to sit inside the eval case folder, granted with `add_dirs` and named by its full path in the prompt. Otherwise the model never finds it, and every check fails because of the test setup, not your skill.
- **Run files are deleted when the run ends** unless you pass `--keep-temp`, and the page tells you to keep them.

## The limits

Five runs is enough to show a weak step, not enough to quote as a rate.
Wording has a limit: where a file goes, or anything that is counting, sorting or arithmetic, belongs in code.
A pattern check is weak on a judgement step; a rubric judged by a second model suits those better.

## Credits

- **Method, prompts and worked example:** Kem, [Glitch Cat Club](https://glitchcatclub.com) · [@kem_glitch](https://www.instagram.com/kem_glitch/).
- **Packaging, guard rails, eval reference:** [blastworks.ai](https://www.blastworks.ai/).
- MIT licence, see [`LICENSE`](LICENSE).
