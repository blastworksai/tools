# Changelog

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
- Deadlines count awake time only, so sleep and throttling do not expire effects.
- Bridge panes are bounded: each controller lane reuses an idle bridge, and inert bridges left by earlier reloads are cleaned up.
- The nightly orphan mailbox sweep retires only stopped, settled and unreferenced mailboxes, and keeps a 14-run log.
- Host latency under load is lower: unchanged observations are not committed, only changed views re-render, and the stored-state comparison is done natively.
- The registry is smaller and quieter: settled claim and result outcomes no longer duplicate request and response bytes, polls keep no outcome, and polls of idle workers no longer commit. In a model of a live store this cut the size from 720 KB to 492 KB.
- Storage stays within the 8 MiB authority and 4,096-outcome limits, with reserves kept for settlement. If storage fails, settlement stops safely rather than proceeding on stale facts.
