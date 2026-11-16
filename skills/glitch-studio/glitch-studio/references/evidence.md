# Evidence files

Each stage writes exactly one file in a `studio/` folder at the root of the project.
The names are fixed.
They are the same in the neutral studio skill and in this one.

## The ten paths

| Stage | Path | Must contain |
| --- | --- | --- |
| 0 | `studio/00-frame.md` | `Role:` orchestrator; the product; who it is for; what "done" means; the named hard parts; the named outside platforms or APIs; visual part yes or no; runtime model yes or no; the first tier-to-model mapping (tier, model, family, reachable); git state |
| 1 | `studio/01-study-reference.md` | per hard part: candidates seen, candidate studied, licence, fetch approved (yes or no, with the date), study note path (`studio/notes/<part>-<candidate>.md`); the path of the notices file |
| 2 | `studio/02-domain-skills.md` | per platform: skill path, found or written, endpoints covered, token types, rate limits, what is unverified |
| 3 | `studio/03-parts-and-specs.md` | per part: name, folder scope, tier, calls a model at runtime (yes or no), contracts used; the filled planning brief; for a visual part, the art-direction path and the fixed screenshot sizes; `Plan:` line (and the archived plan path after the build) |
| 4 | `studio/04-contracts.md` | the exact contract text; per contract: name, path, producer, readers; the freeze commit (`pending` until the build) (or the base commit when there is one part and nothing shared); the rule that only the orchestrator changes a contract; a section "Changes after freeze" (`pending` until the build, then empty if none); or `Picked: none` with the reason; `Plan:` line (and the archived plan path after the build) |
| 5 | `studio/05-lanes.md` | per lane: name, part, folder scope, tier chosen; stops raised (`pending` until the build); a revision note if the stage 0 mapping changed; `Plan:` line (and the archived plan path after the build) |
| 6 | `studio/06-model-tiers.md` | the final tier-to-model table (tier, model, family, reachable); a tier per part with one line why; the builder level the plan names (the level it actually names after the build); the tiers the lanes actually used (`pending` until the build); a revision note if the mapping changed, or `none`; the critic line (model and family, or `none reachable`); same-family review yes or no |
| 7 | `studio/07-review-and-integrate.md` | per lane: review result, findings, critic model and family (or "same-family"), critic result, lane commit, test result after that commit; the commit order; any stop; the user's decision when a review was same-family; the review and test result of every repair commit, under its lane; `Picked: pending` until every fix task found at stage 7 has run |
| 8 | `studio/08-proof.md` | per part: kind (visual or behaviour), proof file paths or command, sizes checked, judged against, result, what is wrong; never `Picked: none` |
| 9 | `studio/09-runtime-models.md` | per runtime call: tier, grammar, builder, refusal rule, budget, scoring; one line per rule (four) with its audit result; one audit line each for least access, reply validation and fail-closed fallback, with evidence; any fix task; the rerun of each failed check with its new result and evidence; the refreshed stage 8 proof; or `Picked: none` with the reason |

## The ending

Every file ends with three lines, in this order:

```
Picked: <what was chosen>
Left out: <what was considered and not chosen>
Why: <the reason, in one or two sentences>
```

A stage that does not apply still writes its file.
It says `Picked: none`, and `Why:` gives the reason.
Stage 8 is never `none`.

## In this skill

Files 03, 04 and 05 record what the planning brief asked for.
They also carry a `Plan:` line that points at the plan once `/glitch-plan` has made it.
Until then the line reads `Plan: not yet made`.
After the build, the archived plan path under `plans/archive/` is added beside it.
Before the build, files 04 and 05 may hold `pending` for the freeze commit, "Changes after freeze" and "Stops raised", and file 06 for "tiers actually used".
A `pending` value does not make a file unfinished.
The three ending lines decide that.
Stage 7 resume must replace every `pending` value.
File 07 records the reviews and the lane commit order from the build run by `/glitch-execute`.
There are no lane merges.

## The resume rule

1. On start, list the `studio/` folder.
2. If it is missing, begin at stage 0.
3. Otherwise read every file.
   A file without the three ending lines is unfinished.
   Finish it first.
4. If any of files 03, 04 and 05 says `Plan: not yet made`, continue the `/glitch-plan` hand-off.
   Replace the placeholder in all three when the plan exists, before stage 6.
5. If file 07 says `Picked: pending`, STOP until the build and every fix task have run.
   Then update file 07 first, and do the stage 7 resume steps.
6. Then continue at the first missing number.
7. Never redo a finished stage, unless the user asks.
8. Say which stage you resume at.

## A worked example

A small product with a weather feed and a card screen.
This is `studio/02-domain-skills.md`:

```
Platform: weather-feed
Skill: skills/weather-feed/SKILL.md
Found or written: written
Endpoints: GET /current, GET /forecast, GET /stations
Token types: one bearer token, valid for one hour
Limits: 60 calls per minute
Unverified: the paging limit of GET /stations

Picked: one domain skill, for weather-feed
Left out: the card screen, which uses no outside platform
Why: only the feed is an outside service, and its limits shape the lane that calls it.
```

## How a checker reads them

A checker reads the file, never the skill's wording.
It looks for the fields in the table, the three ending lines, and the `Plan:` lines.
It compares the values with a sample whose answers are known.
