# Changes: 2026-11-09_20fce10 -> 2026-11-09_cb838e6

Old: sha256 20fce104d48f, 36 files. New: sha256 cb838e6fbce0, 4 files.

What a newer version adds, from the findings both runs already made. Model reads (stage 6) are not compared. A change is a location to read; none is a verdict.

Summary: trifecta leg Can send data out: yes -> no; 32 files removed, 50 phrase hits gone; cost: not used at run time 35 files -> 3 files (39,320 -> 552 tokens).

## What it costs (estimated tokens)

| | Earlier | Now | Change |
|---|---|---|---|
| Every session | 64 | 64 | +0 |
| Every session in this folder | none | none |  |
| Largest at its fullest | 2,042 | 2,042 | +0 |
| Not used at run time | 39,320 | 552 | -38,768 |

## Trifecta legs that changed (1)

- Can send data out: yes -> no

## Install grants removed (2)

- network
- persistence

## Files removed (32)

- walkdown/LOG.md
- walkdown/data/01-inventory.json
- walkdown/data/01-inventory.notes.txt
- walkdown/data/02-reader.json
- walkdown/data/02-reader.notes.txt
- walkdown/data/03-graph.json
- walkdown/data/03-graph.notes.txt
- walkdown/data/04-phrases.json
- walkdown/data/04-phrases.notes.txt
- walkdown/data/05-capability.json
- walkdown/data/05-capability.notes.txt
- walkdown/data/06-packet.md
- walkdown/data/06-soft.json
- walkdown/data/06-soft.notes.txt
- walkdown/data/07-limits.md
- walkdown/data/answers.jsonl
- walkdown/data/capability.json
- walkdown/data/graph.json
- walkdown/data/hits.json
- walkdown/data/normalized/folded/LICENSE.txt
- walkdown/data/normalized/folded/NOTICE.md.txt
- walkdown/data/normalized/folded/README.md.txt
- walkdown/data/normalized/folded/SKILL.md.txt
- walkdown/data/normalized/text/LICENSE.txt
- walkdown/data/normalized/text/NOTICE.md.txt
- walkdown/data/normalized/text/README.md.txt
- walkdown/data/normalized/text/SKILL.md.txt
- walkdown/data/packet.json
- walkdown/details.html
- walkdown/full.md
- walkdown/review.html
- walkdown/summary.html

Phrase hits gone: 50.
