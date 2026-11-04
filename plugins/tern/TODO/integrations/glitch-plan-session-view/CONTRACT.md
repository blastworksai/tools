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

## Publishing and attaching the view

After creating or deliberately resuming/revising an agreed checkpoint plan, the planning agent runs `todo publish --agent-pid <verified agent PID> --plan <absolute canonical path>` from its own tool session. When that session stops working on a plan, it runs `todo clear --agent-pid <verified agent PID>`. See README.md beside this contract for the installed companion path. These operations change only metadata, never canonical content or another session's binding.

The Files-pane TODO button first selects the agent session. Native process metadata identifies that session on its Tern execution host; the host resolves its process-owned publication and reads the canonical plan. The operator is not asked for a source or plan path. No publication means a notice and exit from TODO only; the agent stays running. Invalid or unreadable publication metadata fails visibly, without a guessed plan or agent prompt.

The publication is bound to OS ownership, the agent process birth and its native Tern ancestry. Persisted view identity includes the canonical source/plan id and that process binding, never a bare pane number. Process exit/reuse, clear or a different publication invalidates prior success. A different plan is not adopted automatically.

Normal canonical edits refresh read-only. The renderer uses the unframed native checklist family used by OMP ACP todos, with Tern's inherited theme and fonts. Native remote-host SSH routes use their own execution filesystem; raw SSH without native Tern ancestry is unsupported. No credentials are copied, new trust accepted, provider work dispatched or model input sent.

## Adoption boundary

This is an explicit agent-side publication contract with a discoverable local companion. Managed engine skills/hooks stay unchanged. Evidence that the helper and viewer work is separate from evidence that every planning session follows the companion. Existing plans gain the agreed block and publication only on deliberate resume/revision. No fleet/BWPM/FORGE state is read or written.

Publisher identity is explicit (--agent-pid), verified against the caller’s live owned ancestry; it is never selected by shell-name filtering. Identify the durable agent from runtime facts or helper ancestry. Clear before conversation reset/end and on fresh startup. A reset retaining the same process cannot be detected automatically; skipped clearing leaves the old pointer active.
