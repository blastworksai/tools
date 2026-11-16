# rocket-fuel run 2026-11-09_cb838e6

Source: /opt/glitch/workspaces/tools--publish-rocket-fuel/skills/rocket-fuel | channel: directory | pinned: sha256 cb838e6fbce026fbcdc7b0271f4a582efe7544e5014ddb5bc7966abd539161c9
Walkdown: 0.3.1+blastworks.1 | optional deps: see data/07-limits.md
Expected context: 32,000 tokens
Target hosts: none named
Soft models: none (stage 6 wrote the question packet only)

| Stage | Started | Finished | Output | Result | Validation |
|---|---|---|---|---|---|
| 01-inventory | 2026-11-09T17:00:10+00:00 | 2026-11-09T17:00:10+00:00 | data/01-inventory.json | 9 findings | PASS (gate 26/26, negative 7/7; measured 2026-11-09, same code and fixtures) |
| 02-reader | 2026-11-09T17:00:10+00:00 | 2026-11-09T17:00:11+00:00 | data/02-reader.json | 1 findings | INCOMPLETE (gate 20/31, negative 22/24, recall 1/1; skipped: 13 rows; measured 2026-11-09, same code and fixtures) |
| 03-graph | 2026-11-09T17:00:11+00:00 | 2026-11-09T17:00:11+00:00 | data/03-graph.json | 6 findings | PASS (gate 11/11, negative 7/7; measured 2026-11-09, same code and fixtures) |
| 04-phrases | 2026-11-09T17:00:11+00:00 | 2026-11-09T17:00:11+00:00 | data/04-phrases.json | 13 findings | PASS (gate 153/153, negative 121/121, recall 43/43; measured 2026-11-09, same code and fixtures) |
| 05-capability | 2026-11-09T17:00:11+00:00 | 2026-11-09T17:00:11+00:00 | data/05-capability.json | 17 findings | PASS (gate 81/81, negative 24/24; measured 2026-11-09, same code and fixtures) |
| 06-soft | 2026-11-09T17:00:11+00:00 | 2026-11-09T17:00:12+00:00 | data/06-soft.json | 4 findings | PASS (gate 125/125, negative 11/11, recall 0/165; skipped: 124 rows; measured 2026-11-09, same code and fixtures) |
| 07-limits | | 2026-11-09T17:00:12+00:00 | data/07-limits.md | written | |
| 08-report | | 2026-11-09T17:00:12+00:00 | summary.html, details.html, review.html, full.md | written | |

A report about someone else's repository is not published until its author has seen it.

