# Feature: Demo service 1.0 — legacy-convention fixture

## Implementation plan

### Checkpoint 1 — canonical package

#### Task 1A — source import

SEQUENTIAL: establishes canonical files before builders edit them.

### CREATE workspaces/demo/service

- VALIDATE at checkpoint integration with V1/V2 below.

#### Task 1B — durable state

INDEPENDENT of 1C; owns `state.luau`.

### UPDATE workspaces/demo/service/state.luau

- VALIDATE: V2 group `state,transport` after 1C integrates.

#### Task 1C — controller

INDEPENDENT of 1B against its frozen interfaces.

### UPDATE workspaces/demo/service/host.luau

- VALIDATE: V1/V2.

### Checkpoint 2 — dispatch

#### Task 2A — bridge

INDEPENDENT of 2B.

### CREATE workspaces/demo/bridge/dispatch.luau

- VALIDATE: focused bridge groups.

#### Task 2B — client

AFTER 2A; INDEPENDENT of everything else.

### UPDATE workspaces/demo/service/window.luau

- VALIDATE: V3.

### Checkpoint 3 — cutover

SEQUENTIAL: one owner performs deployment.

### UPDATE _local/demo-service

### UPDATE C:/Users/demo/plugins/demo-service

- VALIDATE: V1–V5.

## Build choices

home: workspace:other

## Progress

### Notes

### UPDATE workspaces/demo/notes.md
