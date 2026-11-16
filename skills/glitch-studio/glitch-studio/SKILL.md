---
name: glitch-studio
description: Use when you want to build a product the studio way, with one orchestrator, frozen contracts, many checked lanes and proof that it works; say "build this the studio way", "studio build", "orchestrate this build" or "spec first, many lanes".
license: MIT
compatibility: Host needs Glitch's /glitch-idea, /glitch-plan and /glitch-execute skills, the ability to load skills, run shell and git, and start fresh sub-agents or sessions. It never needs a named model.
---

# Glitch studio

One orchestrator plans, writes the contracts, reviews and integrates.
Fresh lanes build the parts.
Nothing counts until it is shown working.

This skill runs the method through `/glitch-idea`, `/glitch-plan` and `/glitch-execute`.
It does not repeat them.
It writes its own stages 0, 1, 2, 6, 8 and 9.
For stages 3, 4, 5 and 7 it shapes what goes into those skills.

## Rules

- Never edit `/glitch-idea`, `/glitch-plan` or `/glitch-execute`.
  Never ask the user to edit them.
- Suggest `/glitch-idea` for a new idea.
  Never start it.
- Never run `/glitch-plan` or `/glitch-execute` yourself.
  Give the user the text to paste into a fresh window.
  Every task that changes product code, a repair included, goes through `/glitch-plan` first.
- Reading a project page in a browser needs no yes.
  Every download, clone or install is named to the user (target and licence).
  It waits for the user's yes.
  A yes to one item is not a yes to the rest.
- The orchestrator writes specs, contracts, briefs and reviews.
  It does not write or fix product code.
  A defect goes back as a fix task through `/glitch-plan`.
- Plan by tier (deep, standard, bulk, light).
  Name real models only in the mapping.
  The first mapping goes in file 00.
  The final mapping goes in file 06.
  There is one plan, and `/glitch-execute` runs every builder at the one level it names.
  The tier per part guides the brief's task wording and the critic.
- Ask the user every decision through the structured question tool your host offers.
  Put your recommendation first.
- Say plainly what you did not check.

## Resume rule

Run this first, every time.

1. List the `studio/` folder at the root of the project.
2. If it is missing, begin at stage 0.
3. If it exists, read every file.
   A file without the three ending lines is unfinished.
   Finish it first.
   A `pending` value does not make a file unfinished.
   Stage 7 must replace it.
4. If any of files 03, 04 and 05 says `Plan: not yet made`, continue the `/glitch-plan` hand-off.
   Give the user the brief again.
   When the plan exists, replace the placeholder in all three files before stage 6.
5. If file 07 says `Picked: pending`, STOP until the build and every fix task have run.
   Then update file 07 first.
   Then do the stage 7 resume steps.
6. If file 08 or 09 says `Picked: pending`, STOP until its fix task has run.
   Then review the repair commit as in stage 7 resume step 8, finish the checks in that file, and replace `Picked: pending`.
7. Otherwise continue at the first missing number.
8. Never redo a finished stage, unless the user asks.
9. Tell the user: "Resuming at stage N. Files 00 to N-1 exist."

The ten file paths, the fields each file holds and the ending lines are in [evidence.md](references/evidence.md).
Each stage writes exactly one file.
Each file ends with `Picked:`, `Left out:` and `Why:`.
A stage that does not apply still writes its file, with `Picked: none` and the reason in `Why:`.

## Stage 0 — Frame

Write `studio/00-frame.md`.

1. State your role in one line: you are the orchestrator.
   You write specs, contracts and reviews.
   You spend your own context on integration.
   You do not type the product code.
2. Name the product and its parts in a few lines.
3. Align.
   If the idea is new or unclear, suggest `/glitch-idea` to the user and wait.
   If the user already has an idea record or a clear brief, use it.
4. Ask the user who the product is for and what "done" looks like.
5. Name the hard parts (stage 1 reads them).
6. Name the outside platforms or APIs (stage 2 reads them).
7. Note whether the product has a visual part.
   Note whether it calls a model while it runs.
8. Read [model-tiers.md](references/model-tiers.md).
   Check which models you can reach.
   Map the four tiers to them.
   Stage 1 uses this mapping.
9. Check that the project is under git.
   If it is not, STOP and ask the user to start a repository.

## Stage 1 — Study reference

Write `studio/01-study-reference.md`.
Read [study-reference.md](references/study-reference.md) and follow it.

1. List the hard parts where strong open source may exist.
2. Send light-tier scouts to list candidates, one part each.
   Use the tier mapping from file 00.
   Scouts may read project pages in a browser.
3. Name each candidate to the user with its licence.
   Wait for the user's yes before any download, clone or install.
4. Send deeper agents to take the best candidates apart.
   Each one leaves a study note.
5. Put every credit and licence in a third-party notices file in the project.

## Stage 2 — Domain skills

Write `studio/02-domain-skills.md`.
Read [domain-skills.md](references/domain-skills.md) and follow it.

1. List each outside platform or API the product touches.
2. For each one, look for an existing skill first.
3. If none exists, write a small domain skill before any product code.
4. A platform that is not touched means `Picked: none`.

## Stages 3, 4, 5 — Parts, contracts, lanes

These three stages are one hand-off to `/glitch-plan`.

1. Split the product into separable parts.
2. Pick the shared types and interfaces that more than one part uses.
   These are the contracts.
   Write their exact text now.
3. If a part is visual, find or write the art-direction file now, before you fill the brief.
   Fix the screenshot sizes in it (see [prove-it.md](references/prove-it.md)).
   Record its path and the sizes in file 03.
   The brief names both.
4. Fill the planning brief from [planning-brief.md](references/planning-brief.md).
   Use this project's parts, contracts, study notes, domain skills and tier mapping.
   The brief carries the exact contract text.
   For each part that calls a model while it runs, the brief asks for the runtime-model rules as tasks.
   See [runtime-models.md](references/runtime-models.md).
   If there is one part and nothing shared, the brief has no contracts checkpoint.
   The freeze point is then the base commit before the first lane.
   There is one plan, and `/glitch-execute` runs every builder at the one level that plan names.
   The user chooses that level at the stop of `/glitch-plan`.
   If any part is deep tier, tell the user to ask `/glitch-plan` for a higher builder level at that stop.
   If no part is deep tier, the default level is fine.
5. Write `studio/03-parts-and-specs.md`.
   It lists the parts and holds the filled brief.
   For a visual part it holds the art-direction path and the screenshot sizes.
6. Write `studio/04-contracts.md`.
   It records the exact contract text, which contracts there are, where they live, and the rule that only the studio orchestrator changes them.
   The first checkpoint's builder writes that text into the contracts place.
   The `/glitch-execute` orchestrator checks that the file equals the text and commits it as the freeze commit.
   Before the build, write `pending` for the freeze commit and "Changes after freeze".
   With no contracts, record the base commit and write `Picked: none` with the reason.
7. Write `studio/05-lanes.md`.
   It records the lanes the brief asks for: one per part, each with one folder scope and a tier from the latest mapping.
   Before the build, write `pending` for "Stops raised".
   If you revise the mapping now, write a revision note here.
8. Give the user the filled brief to paste after `/glitch-plan` in a fresh window.
   Do not paste it yourself.
9. When the plan exists, add its path on a `Plan:` line in files 03, 04 and 05.
   Until then, write `Plan: not yet made`.

The plan is the source of truth for the tasks.
Files 04 and 05 record what was asked and where the plan is.

## Stage 6 — Model per job

Write `studio/06-model-tiers.md`.
Read [model-tiers.md](references/model-tiers.md) and follow it.
This stage runs before the build.
It records what you intend.
Stage 7 resume records what happened.

1. Start from the latest mapping.
   That is file 05's revision note if there is one, else file 00.
2. Give every part one of four tiers: deep, standard, bulk or light.
3. Write the mapping from tier to model.
   Use only models this session can actually reach.
4. Name the model family of each one.
   The critic needs a different family from the author.
5. Record the intended tiers and the builder level you expect the plan to name.
   Write `pending` for "Tiers actually used".

## Stage 7 — Review and integrate

Write `studio/07-review-and-integrate.md`.
This stage is run by `/glitch-execute` with Glitch orchestration.
You shape it; you do not replace it.

1. Check that the plan's build choices say `orchestration: glitch`.
2. Tell the user to run `/glitch-execute` on the plan in a fresh window.
3. Write file 07 now with `Picked: pending` and what it waits for.
   STOP.
   Tell the user to come back to this skill after `/glitch-execute` finishes.
   Stage 8 needs a built product.

On resume after the build, do these steps in order:

1. Fill in file 04 from git history and the build's report: the freeze commit, and "Changes after freeze".
2. Fill in file 05: "Stops raised".
   A lane that needed a contract change stopped and asked.
   Record each stop in file 07 too.
3. Fill in file 06: "Tiers actually used", the builder level the plan actually names, and any revision the build drove.
4. Record the plan's archived path (under `plans/archive/`) in files 03, 04 and 05, beside the original path.
5. Read the lane commits in order from git history.
   On this road, lanes commit in order on the same branch, one commit per lane, scoped to its folder.
   Record in file 07 each lane commit, the commit order and the test result after each lane commit.
6. For each lane commit, check whether the build already ran a read-only review by a different model family.
   If it did not, commission one now.
   It is read-only and reads only that lane's diff.
   Read the family map in file 06.
   Record its findings and result in file 07.
   If no other family is reachable, write same-family and ask the user to decide.
7. A defect goes back as a fix task through `/glitch-plan`.
   Give the user the task text to paste after `/glitch-plan` in a fresh window.
   Then give the `/glitch-execute` line it prints.
   File 07 stays `Picked: pending` until every fix task found at this stage has run.
8. Every repair commit, from stage 7, 8 or 9, gets the same read-only cross-family review.
   Rerun the tests after it.
   Record both in file 07 under its lane, before the stage 8 proof or the finish.
9. File 07 records for each lane: the review result, the findings, the critic's model and family (or "same-family"), the critic's result, the lane commit and the test result after that commit.
   It also records the commit order and the user's decision when a review was same-family.
   Replace `Picked: pending` only when every fix task has run.

## Stage 8 — Prove it

Write `studio/08-proof.md`.
Read [prove-it.md](references/prove-it.md) and follow it.
This stage is never `none`.

1. Visual parts get screenshots at fixed sizes, judged against the art direction.
2. Every other part gets a real run.
3. Record what was shown, how, and where the proof sits.
4. A defect goes back to its lane as a fix task.
   You do not fix product code yourself.
   Give the user the task text to paste after `/glitch-plan` in a fresh window.
   Then give the `/glitch-execute` line it prints.
   Write file 08 with `Picked: pending` and the open fix task.
   STOP until the fix task has run.
   Review the repair commit as in stage 7 resume step 8.
   After that, prove the part again and replace `Picked: pending`.

## Stage 9 — Models inside the product

Write `studio/09-runtime-models.md`.
Read [runtime-models.md](references/runtime-models.md) and follow it.

1. If the product never calls a model when it runs, write `Picked: none` with the reason.
2. If it does, the four rules were asked for as tasks in the planning brief.
   You audit them now.
   Check every runtime model call against all four rules.
   Record one check per rule, with its result.
   Also check least access, reply validation and a fail-closed fallback, and record each result.
3. If a check fails, write a fix task for the owning lane.
   Give the user the task text to paste after `/glitch-plan` in a fresh window.
   Then give the `/glitch-execute` line it prints.
   Write file 09 with `Picked: pending` and the open fix task.
   STOP until the fix task has run.
   After the repair commit, review it as in stage 7 resume step 8.
   Rerun every failed stage 9 check.
   Record the new result and evidence in file 09, and replace `Picked: pending`.
   Then refresh the stage 8 proof for that part.

## Finish

1. Check that all ten files exist and each ends with the three lines.
2. Tell the user which stages passed, which were `none`, and which you could not check.
