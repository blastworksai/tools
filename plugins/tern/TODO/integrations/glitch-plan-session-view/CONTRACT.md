# Interactive plan checkpoint contract

CodexBWAI, COMMANDER-993. English-first integration contract for the existing `/glitch-plan` and `/glitch-execute` workflows. This is documentation for integrating the existing workflows, not a separate installable skill or an override of managed files.

## When writing or deliberately revising an interactive plan

Follow `/glitch-plan` normally: resolve the task/home, settle the owner's choices, write its implementation detail and validation, and retain its Build choices. This companion adds one explicit checkpoint block to that same canonical plan. No additional state file, fleet ticket or task manager is created.

1. Agree the visible checkpoint names with the owner through the planning workflow. Use short English outcome descriptions by default. Never invent an approval or hide a gate to make a checkpoint look finished.
2. Generate a block using the installed reader, for example:

   `todo template --title "CSV import" --step "Implement the parser" --step "Prove the import" --step "Review and land the change"`

   The command only prints a block; it does not write a file. Put that output into the canonical plan through the plan writer's normal permitted write path. Preserve its generated stable `plan_id` for the life of the plan. There must be exactly one `TERN-SESSION` block.
3. Keep detailed implementation steps and dated `## Progress` logs as they are. The checkpoint block is the explicit current-state summary, not a prose parser. Keep the sole START HERE marker under the existing session-hygiene rules.
4. Existing plans gain a block only when explicitly resumed/revised for this workflow. Do not batch-convert old plans or infer checkbox completion from dated prose.

## During interactive execution

The executor that owns the canonical plan owns its checkpoint block. When starting a checkpoint set it `active` and set `current` to its stable id. At most one checkpoint is active. If it is waiting, use `blocked` with a concrete `reason`, keeping `current` on that checkpoint. Mark `done` only when the agreed outcome has been verified; clear `current` if no active/blocked checkpoint is current. Preserve ids when editing descriptions or reordering steps.

Update the dated Progress evidence, checkpoint state and START HERE consistently in the same canonical file. Never treat a green test alone as owner acceptance, release permission or a reason to bypass another gate. The view does not write any of these values.

## Attaching the view

Click **TODO** in the Files pane, choose the agent session, and let the native Tern metadata request identify its active canonical plan. **TODO: attach to this panel** starts the same query for the focused panel. The operator is not asked for a source or plan path. Native local and remote session-host reads pin the reported stable plan id before the first read.

An explicit no-plan response ends TODO's attachment flow, never the agent pane. Unsupported checkpoint metadata, unavailable/unsafe communication, timeout or changed session ends with an error. A native empty sendable composer must be observed before submission; terminal-only agents without one are currently unsupported, never typed into. The metadata query is expressly authorized; no source write, work adoption, task continuation or fleet dispatch occurs.

The view polls its selected source read-only and displays native active, blocked, pending and done checkpoints. A different plan id at the same source is refused. Raw SSH alone is not an authorized file route; use native Tern remote-host connections. Existing plan gates remain authoritative.

## Deployment boundary

The managed Glitch engine remains read-only. Integrate this companion through a reviewed supported customization or upstream skill change; do not edit a live managed `glitch-plan`/`glitch-execute` file or install hooks automatically. Before claiming end-to-end live adoption, prove an actual new interactive plan receives the block, its executor maintains it and the real local/SSH panel reflects its verified checkpoint changes. Fleet execution uses its own workflow; BWPM/FORGE are not panel sources.


### Owner-authorized discovery update

The TODO Files button selects the agent session, then sends one native Tern metadata request to that agent's communication endpoint. The agent returns its existing canonical plan path and checkpoint plan id using `TODO_PLAN_REPLY v1`, or explicitly reports `none`/`unsupported` as described in agents/INSTRUCTIONS.md. The operator is not asked for the plan. No plan means exit TODO's attachment flow, never close or interrupt the agent pane. This explicit discovery request supersedes older prose forbidding all agent prompts; it authorizes neither work nor automatic continuation. Ordinary canonical checkpoint maintenance remains deliberate. A generic terminal with no native agent communication endpoint is unsupported; never type discovery text into a shell or existing draft.
