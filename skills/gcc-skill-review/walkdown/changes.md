# Changes: 2026-11-08_0e3c732 -> 2026-11-08_176ca16

Old: sha256 0e3c7328c5a5, 7 files. New: sha256 176ca1683a9f, 8 files.

What a newer version adds, from the findings both runs already made. Model reads (stage 6) are not compared. A change is a location to read; none is a verdict.

Summary: 1 files added, 4 files changed, 1 new phrase hits, 0 of the new phrase hits in text a model reads; cost: largest at its fullest 3,854 -> 3,871 tokens (+17); not used at run time 4 files -> 5 files (2,245 -> 2,608 tokens).

## What it costs (estimated tokens)

| | Earlier | Now | Change |
|---|---|---|---|
| Every session | 151 | 151 | +0 |
| Every session in this folder | none | none |  |
| Largest at its fullest | 3,854 | 3,871 | +17 |
| Not used at run time | 2,245 | 2,608 | +363 |

New phrase hits elsewhere: 1 human (scripts, human-facing files, test data).

## Files added (1)

- gcc-skill-review/LICENSE (human)

## Files changed (4)

- README.md (human)
- gcc-skill-review/SKILL.md (model)
- gcc-skill-review/references/plugin-eval.md (model)
- prompts.md (subagent)
