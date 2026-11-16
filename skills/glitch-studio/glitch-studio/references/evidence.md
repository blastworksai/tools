# Evidence files

Each stage writes exactly one file in a `studio/` folder at the root of the project.
The names are fixed.
They are the same in the neutral studio skill and in this one.

## The ten paths

| Stage | Path | Must contain |
| --- | --- | --- |
| 0 | `studio/00-frame.md` | `Role:` orchestrator; the product; its parts |
| 1 | `studio/01-study-reference.md` | parts studied, candidates with licences, fetches with the user's yes, notes paths, notices file |
| 2 | `studio/02-domain-skills.md` | per platform: skill, endpoints, token types, limits |
| 3 | `studio/03-parts-and-specs.md` | the parts, one folder each, and the filled planning brief; `Plan:` line |
| 4 | `studio/04-contracts.md` | each contract, where it lives, the frozen rule; `Plan:` line |
| 5 | `studio/05-lanes.md` | one lane per part, one folder scope each; `Plan:` line |
| 6 | `studio/06-model-tiers.md` | tier mapping, tier per part, the critic and its family |
| 7 | `studio/07-review-and-integrate.md` | each review, the critic's family, the merge order, any stop |
| 8 | `studio/08-proof.md` | per part: kind, proof, judged against, result |
| 9 | `studio/09-runtime-models.md` | the four rules as built, or `Picked: none` |

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
File 07 records the reviews and merge order from the build run by `/glitch-execute`.

## The resume rule

1. On start, list the `studio/` folder.
2. If it is missing, begin at stage 0.
3. Otherwise continue at the first missing number.
4. Never redo a stage whose file exists, unless the user asks.
5. Say which stage you resume at.

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

Picked: one domain skill, for weather-feed
Left out: the card screen, which uses no outside platform
Why: only the feed is an outside service, and its limits shape the lane that calls it.
```

## How a checker reads them

A checker reads the file, never the skill's wording.
It looks for the fields in the table, the three ending lines, and the `Plan:` lines.
It compares the values with a sample whose answers are known.
