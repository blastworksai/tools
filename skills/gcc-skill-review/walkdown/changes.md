# Changes: 2026-11-08_8dfd6e2 -> 2026-11-08_9eed3f2

Old: sha256 8dfd6e2ced6d, 8 files. New: sha256 9eed3f2f4465, 8 files.

What a newer version adds, from the findings both runs already made. Model reads (stage 6) are not compared. A change is a location to read; none is a verdict.

Summary: 2 files changed, 2 new phrase hits, 2 phrase hits gone, 2 of the new phrase hits in text a model reads; cost: largest at its fullest 4,572 -> 4,602 tokens (+30); not used at run time 5 files -> 5 files (2,853 -> 2,866 tokens).

## What it costs (estimated tokens)

| | Earlier | Now | Change |
|---|---|---|---|
| Every session | 151 | 151 | +0 |
| Every session in this folder | none | none |  |
| Largest at its fullest | 4,572 | 4,602 | +30 |
| Not used at run time | 2,853 | 2,866 | +13 |

## New phrase hits in text a model reads (2)

- gcc-skill-review/SKILL.md:28: phrase.B.defs `Skill runs scripts (needs a shell)? Check now (Linux/WSL; plain Windows: use WSL): 'command -v bwrap socat', and 'sysctl kernel.apparmor_restrict_unprivileged_u...`
- gcc-skill-review/SKILL.md:28: phrase.C.second-order `Skill runs scripts (needs a shell)? Check now (Linux/WSL; plain Windows: use WSL): 'command -v bwrap socat', and 'sysctl kernel.apparmor_restrict_unprivileged_u...`

## Files changed (2)

- README.md (human)
- gcc-skill-review/SKILL.md (model)

Phrase hits gone: 2.
