# Interactive plan checkpoint contract

Blastworks.ai · MIT. This companion adds a checkpoint block to the existing `/glitch-plan` and `/glitch-execute` workflows. Managed Glitch files stay under engine ownership.

## When writing or deliberately revising an interactive plan

Follow `/glitch-plan` normally: resolve the task/home, settle the owner's choices, write its implementation detail and validation, and retain its Build choices. This companion adds one explicit checkpoint block to that same canonical plan. No additional state file, fleet ticket or task manager is created.

1. Agree the visible checkpoint names with the owner through the planning workflow. Use short English outcome descriptions by default. Never invent an approval or hide a gate to make a checkpoint look finished.
2. Generate a block using the installed reader, for example:

   `todo template --title "CSV import" --step "Implement the parser" --step "Prove the import" --step "Review and land the change"`

   The command only prints a block; it does not write a file. Put that output into the canonical plan through the plan writer's normal permitted write path. Preserve its generated stable `plan_id` for the life of the plan. There must be exactly one `TERN-SESSION` block.
3. Keep detailed implementation steps and dated `## Progress` logs as they are. The checkpoint block is the explicit current-state summary, not a prose parser. Keep the sole START HERE marker under the existing session-hygiene rules.
4. Existing plans gain a block only when explicitly resumed/revised for this workflow. Do not batch-convert old plans or infer checkbox completion from dated prose.

## The detailed block (schema 2)

New plans use `"schema": 2`. `todo template` prints one with the checkpoints; `/glitch-plan` then adds the nested entities it has planned, and `/glitch-execute` keeps them current. A schema-1 block (checkpoints only) stays valid and readable; it gains tasks and steps only when the plan is deliberately revised.

```
checkpoints[]  id, text, state, reason?, tasks?[]
  tasks[]      id, text, state, reason?, items?[]
    items[]    id, kind (file | step | validation), text, state, reason?, path (file items only)
```

- `/glitch-plan` creates every id once: lowercase, `[a-z][a-z0-9_-]{0,39}`, unique across the whole plan (checkpoints, tasks and items share one id space). Use a file change's own entry for each `file` item (with its repository-relative `path`), an implementation step for each `step`, and each acceptance check for a `validation`. Nesting is the parent link; there is no separate parent field.
- `/glitch-execute` changes only `state` (`pending`, `active`, `blocked`, `done`), `reason` and `current`. It sets every entity it is working on `active` (several at once when it runs parallel builders) and may name one of them, or a blocked entity, in `current`, or leave `current` null; ancestors stay as they are until their own outcome is verified. A blocked entity carries a concrete `reason`; no other state carries one. Nothing is inferred from prose or from a green test.
- Renaming an entity edits its `text` and keeps its `id`. Reordering moves the entry and keeps every id. A removed step is deleted from the block, and its board card (when sync is on) is removed with it. A new step gets a new id. Never reuse an id for a different entity.
- Bounds: 30 checkpoints, 20 tasks per checkpoint, 30 items per task, 500 entities in all, 240 characters of text, 400 of reason, one `TERN-SESSION` block, at most 1 MiB of plan file. The reader refuses anything outside the closed shape and the viewer then shows the error, never an earlier plan.

## During interactive execution

The executor that owns the canonical plan owns its checkpoint block. When starting a checkpoint set it `active` and set `current` to its stable id. Several checkpoints may be active when work runs in parallel. If it is waiting, use `blocked` with a concrete `reason`, keeping `current` on that checkpoint. Mark `done` only when the agreed outcome has been verified; clear `current` if no active/blocked checkpoint is current. Preserve ids when editing descriptions or reordering steps.

Update the dated Progress evidence, checkpoint state and START HERE consistently in the same canonical file. Never treat a green test alone as owner acceptance, release permission or a reason to bypass another gate. The view does not write any of these values.

## Publishing and attaching the view

On a qualified native Tern host, Claude's typed `/glitch-execute` and exact `Skill` call deliver the execute argument. Codex uses a leading `$glitch-execute` in the user prompt. The hook takes one literal plan path relative to the verified Glitch root or an absolute path inside its canonical `plans/` area. A bare filename can also match a unique archive entry. Missing, ambiguous and outside paths follow the normal execute resolution flow. An ordinary discussion about the command does not publish.

The hook verifies the live interactive agent's native executable, Tern ancestry, process birth and ownership before publishing. It uses the same block reader and metadata publisher as the generic manual interface. The native binding includes the session identity. A repeated callback for one invocation cannot publish the plan again. Startup and reset clear only an earlier binding for that process. Session end clears only the matching binding. Compaction and ordinary turns keep it. Codex's `/new` clears at the next native session-start event, which can arrive with the first new prompt.

Open TODO and choose the intended session if the selector appears. Native process metadata identifies the session and its execution host. The host resolves the process-owned publication and reads the canonical plan. Missing publication affects the TODO view alone. Invalid or unreadable publication metadata produces an error. **TODO: Open Settings** opens the explicit settings view.

The publication is bound to OS ownership, the agent process birth and its native Tern ancestry. Persisted view identity includes the canonical source/plan id and that process binding, never a bare pane number. Process exit/reuse, clear or a different publication invalidates prior success. A different plan is not adopted automatically.

TODO shows every checkpoint, task, file change, step and validation check in a read-only hierarchy, with its state, the blocked reason, progress totals, the source and the last read time. With **Sync Glitch Plan to Tern Board?** on, TODO mirrors every entity to one managed Tern board per plan, one way and by id; it never writes the plan, and turning sync off leaves the existing cards in place. Remote sessions can be viewed but not synced. Normal canonical edits refresh read-only. The renderer uses the unframed native checklist family used by OMP ACP todos, with Tern's inherited theme and fonts. Native remote-host SSH routes use their own execution filesystem; raw SSH without native Tern ancestry is unsupported. No credentials are copied, new trust accepted, provider work dispatched or model input sent.

## Adoption boundary

The hook leaves canonical content untouched. On an explicit execute of a legacy plan with no markers, it reserves that plan for the current session and supplies one scoped continuation. The executor writes the agreed block through the normal authorized workflow before implementation, then runs the supplied `adopt` command in that session. The command checks the same canonical plan, process chain and one-use reservation. A malformed block produces a diagnostic and no adoption command. Existing plans gain the agreed block only on deliberate resume or revision.

For other interactive agents, use the generic `publish` and `clear` commands in [README.md](README.md). Verify the explicit `--agent-pid` against the caller's live owned Tern ancestry. Clear that binding before a reset or when leaving the plan. The generic interface cannot observe a reset that keeps the same process.
