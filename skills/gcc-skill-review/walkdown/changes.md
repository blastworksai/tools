# Changes: 2026-11-08_1c82e3f -> 2026-11-08_8dfd6e2

Old: sha256 1c82e3f452fa, 8 files. New: sha256 8dfd6e2ced6d, 8 files.

What a newer version adds, from the findings both runs already made. Model reads (stage 6) are not compared. A change is a location to read; none is a verdict.

Summary: 1 files changed, 2 new phrase hits, 2 phrase hits gone, 2 of the new phrase hits in text a model reads; cost: largest at its fullest 4,536 -> 4,572 tokens (+36).

## What it costs (estimated tokens)

| | Earlier | Now | Change |
|---|---|---|---|
| Every session | 151 | 151 | +0 |
| Every session in this folder | none | none |  |
| Largest at its fullest | 4,536 | 4,572 | +36 |
| Not used at run time | 2,853 | 2,853 | +0 |

## New phrase hits in text a model reads (2)

- gcc-skill-review/SKILL.md:28: phrase.B.defs `Skill runs scripts (needs a shell)? Check now (Linux/WSL; plain Windows: use WSL): 'command -v bwrap socat', and 'sysctl kernel.apparmor_restrict_unprivileged_u...`
- gcc-skill-review/SKILL.md:28: phrase.C.second-order `Skill runs scripts (needs a shell)? Check now (Linux/WSL; plain Windows: use WSL): 'command -v bwrap socat', and 'sysctl kernel.apparmor_restrict_unprivileged_u...`

## Files changed (1)

- gcc-skill-review/SKILL.md (model)

Phrase hits gone: 2.
