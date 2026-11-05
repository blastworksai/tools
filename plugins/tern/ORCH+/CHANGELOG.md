# Changelog

## 0.3.0

Requires SPAWN 0.3.0 (its mailbox helpers changed: reinstall them with SPAWN). Quota routing works with USAGE 2.1.0 or later.

### Fixed

- Quota-routed launches never started. Their claim carries the USAGE validation it was granted on (`claim.capacity`), and ORCH+ showed that whole claim to SPAWN. SPAWN's window accepts only `{executor,epoch,grant_id}`, so it never authorized the launch: the window challenge expired, SPAWN reported `full` (`window_authorization`, current 1, limit 1), and every automatic recheck ended the same way while provisions still worked. That payload describes the request's own expired challenge; SPAWN has no shared authorization slot. ORCH+ now shows SPAWN exactly `{executor,epoch,grant_id}` and keeps the USAGE validation on the durable claim only. Regression: `dispatch/quota_claim`.
- Never-launched work that continuation could not move no longer stays stuck forever. This covers a launch or provision SPAWN had already received (such as a retried launch whose expired challenge was rechecked) and an adoption whose ask was never sent. Continuation still marks the request as never executed, and the worker now offers **Cancel never-launched work…**. When SPAWN received the request, the window first reads SPAWN's retained status of that exact request. The host cancels only on definitive evidence that it can never run: no SPAWN record, a rejection, or a refusal before any effect, which includes an expired or earlier-boot challenge. A still-live challenge (`authorization_live`) or any other outcome (`spawn_outcome_open`) refuses. Cancelling removes the worker and its settled actions, frees its reservations and, for a coordinator start, releases the orchestrator slot in the same commit. Nothing is stopped, retried or re-sent, and a provisioned mailbox stays unused. Queue the assignment again to get a new worker with a new launch request ID. A launch claimed before the reload stays uncertain and is never cancelled this way. Regression: `dispatch/withdraw_fenced`, `health/withdraw_fenced`.
- Work whose provision SPAWN definitively rejected before any effect (for example a routed provision refused with `binding_mismatch` "Occupied SPAWN controller binding") was held forever. Its routing still read `selected`, so **Cancel this queued work…** refused it. It now offers **Cancel never-launched work…**: no mailbox exists, no launch was built and SPAWN's retained rejection is terminal, so cancelling needs no status read and removes the worker, its settled provision and its reservations. Claimed or uncertain provisions stay strict. Regression: `dispatch/withdraw_fenced`.
- Work whose launch or adoption ask SPAWN definitively rejected after provisioning its mailbox no longer stays held forever. **Cancel never-launched work…** retires the unused mailbox through the exact retirement path without a native stop, because SPAWN stores such a rejection only before any native call. SPAWN now accepts that retirement for a rejected launch with no pane, attachment, acceptance or stop. The worker stays visible with the retirement's outcome. Once SPAWN confirms `retired`, the worker is reclaimed and a coordinator start frees its orchestrator slot. A refused retirement can be retried by cancelling again; a pending or uncertain one is never repeated. Regression: `dispatch/withdraw_fenced`, SPAWN `dispatch/unused_retirement`.
- SPAWN: a window challenge that expired, or was issued before a host restart, no longer holds its bridge pane forever. It can never be consumed, so after its deadline the bridge lease stops reporting `held`, whether or not the window that requested it still exists, and ORCH+ can reuse or close that bridge again. A granted launch, adoption, stop or wake keeps its bridge `live` until SPAWN records its native outcome. Regression: SPAWN `dispatch/bridge_view`.
- With two windows showing the same session (for example a desktop window attached to a remote host and a window on that host), pressing **Continue controller after reload…** or **Guided reload recovery — next step…** in one window could open the picker in the other window and make that window the controller's origin. A button press does not say which window it came from, so these buttons now run only in the window that already owns the controller, like every other dispatch button. After a reload, run the new palette commands **ORCH+ Continue controller in this window** and **ORCH+ Reload recovery guide** in the window you are using; the controller names them where the buttons are. **Inspect**, **Recheck**, **Reveal owner** and **Stop assistance…** likewise run only in the controller's window once it has run its first command; on a controller restored after a host reload they stay open to any window.
- A rollover checkpoint verifies only when every check is fresh and `passed`. A `failed` check now blocks the rollover as `verification_failed`, as it already blocked landing; the checkpoint can be requested again.
- A stopped worker whose helper journal still holds unacknowledged or unresolved messages (typically a rollover predecessor that claimed its checkpoint request but never resolved it) no longer leaves its mailbox retirement uncertain forever. The reviewed helpers report this as a definite pre-effect `producer_unsettled` refusal (reinstall them to get it): the attempt settles as `retirement_refused`, frees its effect slot, keeps the mailbox provisioned and offers **Retry mailbox retirement once…**; the nightly sweep also retries once a day. Rollover predecessors are now told to resolve the claimed request after publishing the checkpoint.
- Managed launches, including rollover successors, no longer take focus: terminals open unfocused, and focus returns to the previously focused pane (normally the controller) after a native agent starts, so controller pickers open without switching back.
- A rollover successor that mistypes its handover token no longer wedges the handover. Its mailbox is now provisioned with the handover ID and a digest of the issued pair, never the token itself. The reviewed SPAWN helpers refuse a mismatched ACCEPTED before publishing it: the stderr line names the wrong field and never repeats a value, and the worker reports again with the exact pair at the same sequence. The launch preface now tells the successor to copy both values verbatim. Reinstall the helpers to get the check.
- When a coordinator rollover's successor exits or is held before accepting, the hold now states that the predecessor is already stopped and retired and no coordinator is active. It shows SPAWN's exact refusal and names the way forward. Fenced recovery of the successor's orchestrator owner closes the rollover and frees the slot, so you can start a new coordinator from the retained checkpoint.

## 0.2.0

First public release of ORCH+, the managed orchestration layer for Tern that runs on top of SPAWN.

### Controller and Config

- One durable controller per logical session, owned by the host and written to storage before it is granted. Duplicate views show the same owner read-only and can reveal the controller.
- The **Open ORCH+ Config** button in the Files pane header opens the session Config page. The **ORCH+** palette command opens the controller. Both reveal an existing view in the current session rather than opening another.
- All controls are native buttons; there are no `orchplus://` links and no ⌘-click. Each dispatch or assistance button publishes a bounded one-shot operator intent that the window owning the controller runs once. Large Save and Attach requests are no longer dropped. An intent whose confirmation does not reach the host within 30 s expires with a visible notice that it will not run later. A button rendered before the latest host update is refused as stale.
- The Config page covers rollover, quota routing, scheduling, the nightly mailbox sweep and the pane orchestration list, using checkbox, −/+ and bounded-value editing. A save is refused if the settings changed in the meantime. Policies stored by earlier builds migrate on restore.

### Dispatch and workflow

- Tasks and coordinator starts are dispatched through SPAWN's revision-pinned catalog, with configured directory and placement. There are no raw commands or credentials.
- Workers report through private report-files-v1 mailboxes: structured reports, exact ACKs, immutable replies and cumulative receipt watermarks. ORCH+ reads no transcripts and does no screen scraping.
- Questions, proposals, quota fallbacks and landing approvals become owner gates. Coordinators activate through typed replies and retire gracefully.
- **Finish ordinary worker…** stops the exact native pane and then retires the settled mailbox.
- Health shows native state, worker-reported state and context use, freshness and pending gates separately. Automatic progress requests are optional.

### Rollover and landing

- Verified worker rollover: a worker-attested checkpoint, a fresh successor on the same record, and the predecessor stopped only after the successor accepts the exact handover. Rollover is manual or triggered at a configurable context threshold.
- Verified coordinator rollover never runs two coordinators at once.
- Landing queue per session, project, repository and target branch: one granted slot per target, owner approval for every grant, fresh passing checks required, and a single `landing_refresh` notice when the target moves.
- Explicit verified attach of a hand-opened agent pane as a managed worker.

### Quota routing

- Optional routing on USAGE capacity v1 evidence. The evidence must be identity-bound, fresh and integrity-checked, and USAGE validates it again before each launch.
- Alternatives come only from explicit allowlists with separate provider, account and model permissions, defined independently for initial dispatch, worker rollover and coordinator rollover. The allowed alternative with the earliest weekly reset is preferred.
- A per-session concurrency limit applies to routed work.

### Recovery and robustness

- Effects run exactly once: a durable request and an exclusive claim exist before every effect, outcomes are retained until the host receipt arrives, and uncertain effects are reconciled automatically with bounded read-only status reads. They are never retried.
- **Guided reload recovery** walks you through continuing the controller, recovering the SPAWN owner and reattaching workers. Reads left uncertain by a previous window resolve without blocking reattachment.
- Expired or revoked SPAWN authorizations are reissued on the continued route instead of holding the worker.
- Work queued but not yet launched when the controller is continued after a window reload moves to the continued window: its unclaimed provision and launch run there, and a provision already claimed in the old window settles first. Such work and its quota reservation no longer get stuck on the old window. A claimed launch keeps its strict fencing.
- Deadlines count awake time only, so sleep and throttling do not expire effects.
- Bridge panes are bounded: each controller lane reuses an idle bridge, and inert bridges left by earlier reloads are cleaned up.
- The nightly orphan mailbox sweep retires only stopped, settled and unreferenced mailboxes, and keeps a 14-run log.
- Host latency under load is lower: unchanged observations are not committed, only changed views re-render, and the stored-state comparison is done natively.
- The registry is smaller and quieter: settled claim and result outcomes no longer duplicate request and response bytes, polls keep no outcome, and polls of idle workers no longer commit. In a model of a live store this cut the size from 720 KB to 492 KB.
- Storage stays within the 8 MiB authority and 4,096-outcome limits, with reserves kept for settlement. If storage fails, settlement stops safely rather than proceeding on stale facts.
