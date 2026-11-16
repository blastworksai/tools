---
name: studio
description: Use when someone says "build this the studio way", "run this with an orchestrator and lanes", "spec first, many builders", "split this build into parallel lanes" or "make a big product with many agents".
license: MIT
compatibility: The host loads skills, runs shell commands and git, and can start fresh sub-agents or fresh sessions. It needs no particular model.
---

# Studio

One main thread orchestrates.
Fresh lanes build.
Every result is reviewed, integrated and shown working before it counts.

The method comes from the Chatdom.io build write-up (TwitchCon 2026 hackathon, 1st place): https://devpost.com/software/chatdom-io.
The wording here is ours.

## Rules

- The main thread writes specs, contracts and reviews. It does not write product code, except to integrate.
- Each stage writes exactly one evidence file in the `studio/` folder at the project root. Paths and format are in [references/evidence.md](references/evidence.md).
- Never invent a result. If a check did not run, say so in the file.
- Stop and ask the user at every point marked STOP below.
- Plain words. Name the file, the part and the stage.

## Resume rule

At the start, read the `studio/` folder.
If it does not exist, begin at stage 0.
If it exists, read every file.
A file without the three ending lines is unfinished.
Finish it first.
Otherwise continue at the first missing number.
Never redo a finished stage unless the user asks.
Tell the user in one line where you are: "stage 5 of 9 next".

Each evidence file ends with three lines: `Picked: ...`, `Left out: ...`, `Why: ...`.
A stage that does not apply still writes its file, with `Picked: none` and the reason in `Why:`.

## Stage 0. Frame

You are an orchestrator, not a typist.
Spend your context on contracts, review and integration.
Give typing work to lanes.
Ask the user for the product in one paragraph, who it is for and what "done" looks like.
Name the hard parts (stage 1 reads them) and the outside platforms or APIs (stage 2 reads them).
Note whether the product has a visual part and whether it calls a model at runtime.
Write `studio/00-frame.md` with: role, product, who it is for, what "done" means, the hard parts, the outside platforms, the visual and runtime-model notes, and the project's git state.
STOP if the project is not in git. Ask the user to start a repository.

## Stage 1. Study reference

Read [references/study-reference.md](references/study-reference.md).
For each hard part where strong open source exists, scout, choose, take apart, write a study note.
Name every download or clone to the user, with its target and licence.
STOP and wait for a yes before each one.
Write `studio/01-study-reference.md`, and a `THIRD_PARTY_NOTICES.md` in the project for credits and licences.

## Stage 2. Domain skills

Read [references/domain-skills.md](references/domain-skills.md).
For each outside platform or API the product touches, write or find a small domain skill before product code.
Write `studio/02-domain-skills.md`.
With no outside platform, write it with `Picked: none`.

## Stage 3. Parts and specs

Read [references/specs-and-contracts.md](references/specs-and-contracts.md).
Split the product into separable parts.
Write one spec per part, each with a task list where one task is one check and one commit.
If a part calls a model at runtime, write the five runtime-model rules into its spec as tasks (see [references/runtime-models.md](references/runtime-models.md)).
Write `studio/03-parts-and-specs.md`.
STOP and show the user the list of parts. Continue on their yes.

## Stage 4. Frozen contracts

Read the same file, section on contracts.
Write every shared type and interface in one contracts place.
Commit it before any lane starts.
With one part and nothing shared, skip the contracts: record the base commit as the freeze point and write `Picked: none`.
Only you change it from now on.
Write `studio/04-contracts.md`.

## Stage 5. Lanes

Read [references/lanes.md](references/lanes.md).
Give each spec its own worktree and one folder scope.
Before you start any lane, read [references/model-tiers.md](references/model-tiers.md).
Check which models you can reach, map the four tiers to them and pick a tier for each lane.
Start one fresh lane per spec.
A lane follows the loop: take the next task, write its check, see it fail, make it pass, commit, repeat.
A lane never edits outside its scope.
A lane that needs a contract change stops and asks you.
Write `studio/05-lanes.md`: lane, branch, folder scope, task count, tier chosen.

## Stage 6. Model per job

Read [references/model-tiers.md](references/model-tiers.md).
Use four tiers: deep, standard, bulk, light.
The mapping and the lane tiers were chosen in stage 5, before the lanes started.
Write that mapping, tier to model, in `studio/06-model-tiers.md`, and a tier for every part.
Record the tiers the lanes actually used.

## Stage 7. Review and integrate

Read [references/review-and-integrate.md](references/review-and-integrate.md).
Review every lane yourself.
Ask a read-only critic to read it too. Use another model family if one is reachable.
If none is reachable, write that the review is same-family. STOP and let the user decide.
Merge lanes one at a time. Run the tests after each merge.
Write `studio/07-review-and-integrate.md`.

## Stage 8. Prove it

Read [references/prove-it.md](references/prove-it.md).
Done means demonstrated.
Visual parts get screenshots at fixed sizes, judged against the art direction.
Every other part gets a real run, with its output kept.
This stage is never `none`.
Write `studio/08-proof.md`.

## Stage 9. Models inside the product

Read [references/runtime-models.md](references/runtime-models.md).
Do this only if the product itself calls a model.
If not, write `studio/09-runtime-models.md` with `Picked: none` and the reason.
Otherwise audit every runtime model call against all five rules: typed grammar, deterministic builder, two independent reads before a refusal, call budget, code-based scoring.
The rules were written into the specs in stage 3.
Record one check per rule, with its result.
If any check fails, send a fix task to the owning lane and refresh the stage 8 proof for that part.

## When you finish

Tell the user: what was built, which lanes merged, which proof files exist, and what is left out.
Do not call the build done until `studio/08-proof.md` shows real proof for every part.
