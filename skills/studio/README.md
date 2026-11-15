# STUDIO

**Build big things with one orchestrator and many small, checked lanes.**

> **The method comes from the Chatdom.io build write-up (TwitchCon 2026 hackathon, 1st place): https://devpost.com/software/chatdom-io. The wording here is ours; none of the write-up's text or code is copied.**
> The write-up describes a four-day build that one main thread steered.
> This skill turns that method into stages any agent can follow, on any model.

## Why

One long agent session does not scale.
Its context fills up, its early decisions drift, and nobody can say which part is done.
Many agents at once do not fix this by themselves.
Without shared types and clear folders, they collide.

This skill gives the main thread one job: be the orchestrator.
It writes specs and contracts, hands small tasks to fresh lanes, reviews what comes back and proves it works.
It does not type the product itself.

## What it does

It runs ten stages, 0 to 9.
Each stage writes one evidence file, so you can see where a build stands and a stopped session can resume.

0. **Frame.** The main thread is an orchestrator, not a typist.
1. **Study reference.** Before a hard part is specified, find strong open source, take the best apart and leave a study note. Every download waits for your yes.
2. **Domain skills.** For each outside platform, write or find a small skill (auth, endpoints, limits, payloads) before product code.
3. **Parts and specs.** Split the work into parts. Each part gets a spec and a task list. One task is one check and one commit.
4. **Frozen contracts.** Shared types live in one place, written by the orchestrator before any lane starts.
5. **Lanes.** One worktree per spec, one folder scope. Take the next task, write its check, see it fail, make it pass, commit, repeat.
6. **Model per job.** Four tiers: deep, standard, bulk, light. The agent maps them to the models it can reach.
7. **Review and integrate.** The orchestrator reviews every lane. A read-only critic of another model family reads it too. Lanes merge one at a time, with tests after each merge.
8. **Prove it.** Done means demonstrated: screenshots at fixed sizes for what you see, a real run for everything else.
9. **Models inside the product.** Only when the product itself calls a model: a typed grammar, deterministic builders, two reads before a refusal, a call budget, quality scored by code.

## How to use it

**An agent that loads skills:** copy the inner [`studio/`](studio/) folder into your agent's skills folder (for example `~/.claude/skills/`), then say "build this the studio way" and describe the product.

**Any other agent:** the prompts are in [`prompts.md`](prompts.md).
Paste them one stage at a time, in order, and let the agent finish each stage before the next.

Each stage writes a file into a `studio/` folder at the root of your project, from `studio/00-frame.md` to `studio/09-runtime-models.md`.
To resume, start the skill again in the same project.
It reads that folder and continues at the first missing number.
It never redoes a stage whose file exists unless you ask.
The file format is in [`studio/references/evidence.md`](studio/references/evidence.md).

## You need

- An agent that can read and write files, run shell commands and use git.
- A way to start fresh sub-agents or fresh sessions for the lanes. Without it, the skill still works, but you run each lane yourself in a new chat.
- A project in a git repository.

## The limits

The skill does not make a weak idea good.
It does not prove the method is faster for you.
A critic of the same model family as the author is weaker than one of another family; the skill says so and asks you.
Stage 1 reads outside code only with your yes, and it never copies code without its licence.

## Credits

- **Method:** the Chatdom.io build write-up, https://devpost.com/software/chatdom-io.
- **Packaging:** [blastworks.ai](https://www.blastworks.ai/).
- MIT licence, see [`LICENSE`](LICENSE).
