# rocket-fuel run 2026-11-09_e2a595c

Source: /opt/glitch/workspaces/tools--publish-rocket-fuel/skills/rocket-fuel | channel: directory | pinned: sha256 e2a595c030449451d48875673bded87f516a2d8a26db8b3230bb84314b5ca8dd
Walkdown: 0.3.1+blastworks.1 | optional deps: see data/07-limits.md
Expected context: 32,000 tokens
Target hosts: none named
Soft models: none (stage 6 wrote the question packet only)

| Stage | Started | Finished | Output | Result | Validation |
|---|---|---|---|---|---|
| 01-inventory | 2026-11-09T16:46:03+00:00 | 2026-11-09T16:46:03+00:00 | data/01-inventory.json | 9 findings | PASS (gate 26/26, negative 7/7) |
| 02-reader | 2026-11-09T16:46:03+00:00 | 2026-11-09T16:46:03+00:00 | data/02-reader.json | 1 findings | INCOMPLETE (gate 20/31, negative 22/24, recall 1/1; skipped: 13 rows) |
| 03-graph | 2026-11-09T16:46:03+00:00 | 2026-11-09T16:46:03+00:00 | data/03-graph.json | 6 findings | PASS (gate 11/11, negative 7/7) |
| 04-phrases | 2026-11-09T16:46:03+00:00 | 2026-11-09T16:46:04+00:00 | data/04-phrases.json | 13 findings | PASS (gate 153/153, negative 121/121, recall 43/43) |
| 05-capability | 2026-11-09T16:46:04+00:00 | 2026-11-09T16:46:04+00:00 | data/05-capability.json | 17 findings | PASS (gate 81/81, negative 24/24) |
| 06-soft | 2026-11-09T16:46:04+00:00 | 2026-11-09T16:46:04+00:00 | data/06-soft.json | 4 findings | PASS (gate 125/125, negative 11/11, recall 0/165; skipped: 124 rows) |
| 07-limits | | 2026-11-09T16:46:44+00:00 | data/07-limits.md | written | |
| 08-report | | 2026-11-09T16:46:44+00:00 | summary.html, details.html, review.html, full.md | written | |

A report about someone else's repository is not published until its author has seen it.

