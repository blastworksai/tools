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
| 00 | role (orchestrator), product, visual part yes or no, outside platforms yes or no, runtime model yes or no |
| 01 | per hard part: candidate, licence, fetch approved, study note; path of the notices file |
| 02 | per platform: skill path, endpoints, token type, rate limit |
| 03 | per part: spec path, folder scope, task count |
| 04 | per contract: name, path, producer, readers; the freeze commit; changes after freeze |
| 05 | per lane: spec, branch, folder scope, commits, stops raised |
| 06 | tier-to-model table; a tier per part; the critic line |
| 07 | per lane: review result, critic model and family, merge commit, test result |
| 08 | per part: visual or run, proof files, sizes, result |
| 09 | per runtime call: tier, grammar, builder, budget, scoring; or `Picked: none` |

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
2. Find the first missing number from 00 to 09.
3. Continue there.
4. Never redo a stage whose file exists unless the user asks.
5. Say in one line where you are.

If the folder is missing, begin at stage 0.
If a file exists but lacks the three ending lines, treat it as unfinished and finish it.

## Worked example

A small product with four parts.
It has a feed that calls an outside weather service, a chart, a card page and a units helper.
`studio/02-domain-skills.md`:

```
| platform | skill path | endpoints | token type | rate limit |
| --- | --- | --- | --- | --- |
| weather service | skills/weather/SKILL.md | /current, /forecast, /stations | bearer key | 60 per minute |

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
