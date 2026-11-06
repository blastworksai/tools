# Feature: Demo service 2.0 — synthetic importer fixture

## Overview

Synthetic plan for the ORCH+ plan importer tests. It names no real hosts, people or paths.

### UPDATE workspaces/demo/README.md

## IMPLEMENTATION PLAN

### Checkpoint 1 — Settings and caps

#### Task 1A — settings reducer
**INDEPENDENT** — runs alongside 1B.

### UPDATE workspaces/demo/app/settings.luau

- **IMPLEMENT**: store every new setting.
- **VALIDATE**: native `demo settings` (lead runs at checkpoint end).

#### Task 1B — settings tests
**INDEPENDENT** — written against the settings contract.

### UPDATE workspaces/demo/app/tests/settings.luau
### UPDATE workspaces/demo/app/tests/gates.luau
### UPDATE workspaces/demo/app/tests/health.luau
### UPDATE /srv/demo-evidence/harness.py

- **VALIDATE**: native groups `demo settings`, `demo gates`, `demo health`.

### Checkpoint 2 — Helper modes

#### Task 2A — POSIX helper
**INDEPENDENT** — runs alongside 2B, 2C.

### UPDATE workspaces/demo/helpers/worker.sh

- **VALIDATE**: `python3 workspaces/demo/helpers/tests/posix.py` (lead runs).

#### Task 2B — Windows helper parity
**INDEPENDENT** — runs alongside 2A, 2C.

### UPDATE workspaces/demo/helpers/worker.ps1

- **VALIDATE**: on a disposable test machine, isolated (lead runs): copy the package, then `powershell -File tests/helpers.ps1`; delete the copy afterwards.

#### Task 2C — helper tests
**INDEPENDENT** — runs alongside 2A, 2B.

### UPDATE workspaces/demo/app/tests/transport.luau

- **VALIDATE**: native `demo transport`, `demo reports/alpha`, `demo reports/beta`; `python3 workspaces/demo/helpers/tests/posix.py`.

### Checkpoint 3 — Review flow

#### Task 3A — briefs
**INDEPENDENT** — runs alongside 3B.

### UPDATE workspaces/demo/app/brief.md

- **VALIDATE**: doc review against the contracts.

#### Task 3B — review tests
**INDEPENDENT** — new group file.

### CREATE workspaces/demo/app/tests/workflow.luau

- **VALIDATE**: native `demo workflow/review`.

### Checkpoint 4 — Landing

#### Task 4A — landing reducer
**INDEPENDENT**.

### UPDATE workspaces/demo/app/landing.luau

```text
### UPDATE workspaces/demo/app/fenced.luau
```

- **VALIDATE**: native `demo workflow/release`.

### Checkpoint 5 — Autonomy

#### Task 5A — auto-approval
**INDEPENDENT**.

### REFACTOR workspaces/demo/app/policy.luau

- **VALIDATE**: native `demo workflow/autonomy`.

### Checkpoint 6 — Work sources

#### Task 6A — plan importer
**INDEPENDENT** — runs alongside 6B.

### CREATE workspaces/demo/app/importer.luau

- **VALIDATE**: native `demo workflow/import` (fixtures: this plan, an old plan, a malformed plan).

#### Task 6B — intake
**INDEPENDENT** — runs alongside 6A.

### ADD workspaces/demo/app/intake.luau

- **VALIDATE**: native `demo workflow/intake`.

### Checkpoint 7 — Router

#### Task 7A — router
**INDEPENDENT**.

### MOVE workspaces/demo/app/router.luau

- **VALIDATE**: native `demo workflow/router`.

### Checkpoint 8 — Simplification and release

#### Task 8A — measured simplification
SEQUENTIAL: needs every feature checkpoint landed; one owner for the whole package.

### REFACTOR workspaces/demo/app/dispatch.luau

- **VALIDATE**: full `run_all()`; report before/after numbers in Progress.

#### Task 8B — docs and version
SEQUENTIAL: after 8A so docs describe the final code.

### UPDATE workspaces/demo/CHANGELOG.md

- **VALIDATE**: doc review.

---

## Build choices

home: workspace:demo

## Progress

### Checkpoint 1 — done (progress prose never imports)

#### Task 9Z — never imported
**INDEPENDENT**

### UPDATE workspaces/demo/progress-note.md
