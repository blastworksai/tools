# The stage prompts

For an agent that does not load skills.
Paste one prompt at a time, in order, and wait until the agent says the stage is done.
Each prompt names the evidence file the agent must write, in a `studio/` folder at the root of your project.
Every evidence file ends with three lines: `Picked:`, `Left out:`, `Why:`.
A stage that does not apply still writes its file, with `Picked: none` and the reason after `Why:`.

The method comes from the Chatdom.io build write-up (TwitchCon 2026 hackathon, 1st place): https://devpost.com/software/chatdom-io.
The wording here is ours.
MIT, see [LICENSE](LICENSE).

To resume in a new chat: paste the Resume prompt first.

## Resume prompt

Read the `studio/` folder at the root of this project.
If it does not exist, tell me we start at stage 0.
If it exists, read every file.
A file without the three ending lines is unfinished.
Finish it first.
Otherwise find the first missing file number from 00 to 09 and continue there.
Tell me in one line which stage is next.
Do not redo a finished stage unless I ask.

## Prompt 00 of 09 . frame

You are the orchestrator of this build, not a typist.
You write specs, contracts and reviews.
Fresh sessions write the product code.
Ask me for the product in one paragraph, who it is for and what done looks like.
Name the hard parts of the product, for stage 1.
Name every outside platform or API it touches, for stage 2.
Note whether it has a visual part and whether it calls a model while it runs.
Check the project is in git; if it is not, stop and ask me.
List the models you can reach in this session, and map the four tiers (deep, standard, bulk, light) to them, each with an effort setting.
Stages 1 and 5 use this mapping.
Write `studio/00-frame.md` with your role, the product, who it is for, what done means, the hard parts, the outside platforms, the visual and runtime-model notes, the tier-to-model mapping (tier, model, effort, reachable) and the git state.
End the file with the three lines.

## Prompt 01 of 09 . study reference

For each hard part of the product where strong open source exists, do a study pass.
Use a cheap quick helper to list candidates with link, licence and size.
Pick the best one to three per part, preferring permissive licences.
You may read project pages in a browser without asking.
Tell me every download, clone or install you want, with its target and licence, and wait for my yes before each one.
Take each approved candidate apart: how it is built, what to learn, what not to copy.
Write one short study note per part in the project.
Write credits and licences into `THIRD_PARTY_NOTICES.md` in the project.
Write `studio/01-study-reference.md` with a table of part, candidates seen, candidate studied, licence, fetch approved (yes or no) and note path, plus the path of the notices file.
If no part needs this, write the file with `Picked: none`.
End the file with the three lines.

## Prompt 02 of 09 . domain skills

List every outside platform or API the product touches.
For each one, look for an existing skill first.
If none exists, write a small skill before any product code: auth and token types, the endpoints the product uses, scopes, rate limits, payload examples, known traps.
Put no real secret in it.
If you need to read documentation online, tell me the target and wait for my yes.
Write `studio/02-domain-skills.md` with a row per platform: skill path, found or written, endpoints covered, token type, rate limit, what is unverified.
If there is no outside platform, write the file with `Picked: none`.
End the file with the three lines.

## Prompt 03 of 09 . parts and specs

Split the product into separable parts.
Each part lives in one folder and meets the others only through shared types.
Write one spec per part: goal, folder scope, contracts used, domain skills and study notes to read, art direction if visual, and a task list.
One task is one check and one commit.
If a part calls a model at runtime, add five tasks to its spec: a typed grammar the model chooses from and code validates; a deterministic builder; two independent reads that must agree before a refusal; a per-request call budget counted in code; quality scored by code.
Write each spec so a fresh session with no memory can pick it up.
Show me the part list and wait for my yes.
Write `studio/03-parts-and-specs.md` with a row per part: part, spec path, folder scope, task count, contracts used, calls a model at runtime (yes or no).
End the file with the three lines.

## Prompt 04 of 09 . frozen contracts

If there is one part and nothing is shared, write no contracts: record the base commit before the first lane as the freeze point and write `Picked: none` with the reason.
Otherwise write every shared type and interface in one contracts place in the project.
Give each a short comment saying who produces it and who reads it.
Add a small check that the contracts compile or validate.
Commit them before any lane starts.
From now on only you change the contracts.
A lane that needs a change must stop and ask you.
Write `studio/04-contracts.md` with each contract's name, path, producer and readers, the freeze commit, and a section "Changes after freeze" (empty if none, otherwise each change with its reason and the lanes told).
End the file with the three lines.

## Prompt 05 of 09 . lanes

Before you start any lane, pick a tier for each lane from the mapping in `studio/00-frame.md`.
You may revise the mapping; if you do, say so.
For each spec, make a git worktree on its own branch, cut from the freeze commit recorded in stage 4 (the base commit when there are no contracts).
Start one fresh session per spec, at the lane's tier, and give it the spec path and its folder scope.
Each lane follows this loop: take the next task, write its check, see it fail, make it pass, commit, repeat.
A lane never edits outside its folder scope and never edits the contracts.
A lane that needs a contract change stops and tells you.
Write `studio/05-lanes.md` with a row per lane: lane, spec, branch, worktree, folder scope, task count, commits, tier chosen, stops raised.
End the file with the three lines.

## Prompt 06 of 09 . model per job

You made the tier mapping in stage 0, and stage 5 may have revised it; write the final mapping down now.
Use four tiers: deep for contracts, the parts that must be right and the critic; standard for most features, integration and merges; bulk for volume work fanned out with one folder each; light for scouting and summaries.
Write each tier's model from the final mapping, with an effort setting.
Give every part a tier and one line why.
Record the tier each lane actually used.
Name the critic's model and family.
If no second family is reachable, say the review will be same-family and ask me.
Write `studio/06-model-tiers.md` with the mapping table (tier, model, effort, reachable), the tier per part with one line why, the tier each lane used, and the critic line.
End the file with the three lines.

## Prompt 07 of 09 . review and integrate

Review every lane against its spec.
Check each commit touched only the lane's folder and left the contracts alone.
Run the lane's checks yourself.
Then start a read-only critic, of another model family if one is reachable, with the spec, contracts and diff.
Do not tell it your conclusion.
If only the same family is reachable, write that and ask me before going on.
Merge lanes one at a time and run the full tests after each merge.
Write `studio/07-review-and-integrate.md` with a row per lane: review result, findings, critic model and family (or same-family), critic result, merge commit, test result after that merge.
Also write the merge order and, if any review was same-family, what I decided.
End the file with the three lines.

## Prompt 08 of 09 . prove it

Done means demonstrated.
For each visual part, run the real product, take screenshots at fixed sizes (at least one small and one large), check the real image sizes from the file headers, and judge each against the art direction.
For every other part, run the real code with real input, keep the command and its output, and include one case that should fail.
Write `studio/08-proof.md` with a row per part: kind (visual or run), proof files, sizes checked, result, what is wrong.
This file is never `Picked: none`.
End the file with the three lines.

## Prompt 09 of 09 . models inside the product

Only if the product itself calls a model while it runs, audit every runtime model call against the five rules that stage 3 put into the specs: the model chooses from a typed grammar and code validates it; deterministic code builds the result; two independent reads must agree before a refusal; each request has a call budget counted in code; code scores quality, not the model.
If the product calls no model at runtime, write `studio/09-runtime-models.md` with `Picked: none` and the reason.
Otherwise write each runtime call with its tier, grammar, builder, budget and scoring, and one line per rule with its audit result.
If any rule fails, send a fix task to the owning lane, then refresh the stage 8 proof for that part after the fix is merged.
Record in the file each fix task you sent and the refreshed proof file.
End the file with the three lines.
