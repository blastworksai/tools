# Evidence files

Each stage writes exactly one file.
Together they show where a build stands.
A checker, or a resumed session, reads them.

## The ten paths

Write them in a `studio/` folder at the root of the project:

- `studio/00-frame.md`
- `studio/01-study-reference.md`
- `studio/02-domain-skills.md`
- `studio/03-parts-and-specs.md`
- `studio/04-contracts.md`
- `studio/05-lanes.md`
- `studio/06-model-tiers.md`
- `studio/07-review-and-integrate.md`
- `studio/08-proof.md`
- `studio/09-runtime-models.md`

Use these names exactly.

## What each file must contain

| File | Fields a checker reads |
| --- | --- |
| 00 | role (orchestrator); product; who it is for; what "done" means; the named hard parts; the named outside platforms or APIs; visual part yes or no; runtime model yes or no; tier-to-model mapping (tier, model, effort, reachable); git state |
| 01 | per hard part: candidates seen, candidate studied, licence, fetch approved (yes or no), study note path; the path of `THIRD_PARTY_NOTICES.md` |
| 02 | per platform: skill path, found or written, endpoints covered, token type, rate limit, what is unverified |
| 03 | per part: part, spec path, folder scope, task count, contracts used, calls a model at runtime (yes or no) |
| 04 | per contract: name, path, producer, readers; the freeze commit (or the base commit when there is one part and nothing shared); a section "Changes after freeze", empty if none, otherwise each change with its reason and the lanes told; or `Picked: none` with the reason |
| 05 | per lane: lane name, spec, branch, worktree path, folder scope, task count, commit count, tier chosen, stops raised; a note if the stage 0 mapping was revised |
| 06 | the final tier-to-model table (tier, model, effort, reachable); a tier per part with one line why; the tiers the lanes actually used; the critic line (model and family, or "none reachable") |
| 07 | per lane: review result, findings, critic model and family (or "same-family"), critic result, merge commit, test result after that merge; the merge order; the user's decision when a review was same-family |
| 08 | per part: kind (visual or run), proof file paths, sizes checked, result, what is wrong; never `Picked: none` |
| 09 | per runtime call: tier, grammar, builder, budget, scoring; one line per rule (five) with its audit result; any fix task and refreshed proof; or `Picked: none` with the reason |

## The ending

Every file ends with three lines, in this order:

```
Picked: <every item you kept, each by name, then the rule you used>
Left out: <what you dropped>
Why: <one sentence>
```

A stage that does not apply still writes its file.
It uses `Picked: none` and gives the reason in `Why:`.
Stage 8 is never `none`.
Visual parts get screenshots at fixed sizes against the art direction.
Every other part gets a real-run proof.

## The resume rule

At the start of a session:

1. Read the `studio/` folder.
2. If a file exists but lacks the three ending lines, it is unfinished: finish it first.
3. Otherwise find the first missing number from 00 to 09 and continue there.
4. Never redo a finished stage unless the user asks.
5. Say in one line where you are.

If the folder is missing, begin at stage 0.

## Worked example

A small product with four parts.
It has a feed that calls an outside weather service, a chart, a card page and a units helper.
`studio/02-domain-skills.md`:

```
| platform | skill path | found or written | endpoints | token type | rate limit | unverified |
| --- | --- | --- | --- | --- | --- | --- |
| weather service | skills/weather/SKILL.md | written | /current, /forecast, /stations | bearer key | 60 per minute | the /stations paging limit |

Picked: weather service, because the feed part calls it.
Left out: the chart library, because it is a library and not a platform.
Why: only an outside service with auth and limits needs a domain skill.
```

`studio/09-runtime-models.md` for the same product:

```
Picked: none
Left out: none
Why: the product calls no model while it runs.
```

## Checks

A good check reads the evidence file on a sample whose answers you know.
It does not read the skill's wording.
It checks the ten paths exist, each ends with the three lines, and the fields above are present.
