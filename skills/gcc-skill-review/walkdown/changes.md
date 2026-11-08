# Changes: 2026-11-08_9eed3f2 -> 2026-11-08_9b9cbe3

Old: sha256 9eed3f2f4465, 8 files. New: sha256 9b9cbe361a8f, 8 files.

What a newer version adds, from the findings both runs already made. Model reads (stage 6) are not compared. A change is a location to read; none is a verdict.

Summary: 3 files changed, 3 new phrase hits, 2 phrase hits gone, 3 of the new phrase hits in text a model reads; cost: largest at its fullest 4,602 -> 5,077 tokens (+475); not used at run time 5 files -> 5 files (2,866 -> 2,923 tokens).

## What it costs (estimated tokens)

| | Earlier | Now | Change |
|---|---|---|---|
| Every session | 151 | 151 | +0 |
| Every session in this folder | none | none |  |
| Largest at its fullest | 4,602 | 5,077 | +475 |
| Not used at run time | 2,866 | 2,923 | +57 |

## New phrase hits in text a model reads (3)

- gcc-skill-review/SKILL.md:89: phrase.B.defs `No 'plugin eval' available: five fresh sessions, same checks by hand; say so, and say what differs: the skill is read by path (its description trigger is untest...`
- gcc-skill-review/SKILL.md:80: phrase.J.prohibited `'--no-publish' always (default publishes the report to claude.ai). '--trust-plugin' only for the copy you wrote. A trial-only case beside the counted one: add '...`
- gcc-skill-review/SKILL.md:77: phrase.J.prohibited `claude plugin eval <skill>-review/copy --runs 5 --model <model> --ablation none --no-publish --keep-temp --trust-plugin -j 1 --allow-tools <only the tools the s...`

## Files changed (3)

- README.md (human)
- gcc-skill-review/SKILL.md (model)
- gcc-skill-review/references/plugin-eval.md (model)

Phrase hits gone: 2.
