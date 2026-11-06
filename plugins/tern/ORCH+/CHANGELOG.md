# Changelog

## 0.4.0

Requires SPAWN 0.4.0 (new helper modes, capabilities and report kinds: reinstall its mailbox helpers with SPAWN). Quota routing and usage deltas work with USAGE 2.1.0 or later. Stored 0.3.0 settings, workers and landing items are migrated when the store is restored.

Includes all 0.3.1 fixes (listed under 0.3.1 below).

### Changed (breaking)

- **Landing needs a review.** No landing grant is issued without a recorded proof for the exact source revision: by default an approved review from a reviewer worker of a different declared provider family; with **Enforce cross-family review** off, every declared check passing through SPAWN's helper plus an approved review by a reviewer other than the builder. Worker-attested checkpoint checks alone no longer suffice.
- **The release manager merges.** Landing grants go to the session's release manager (a managed worker on a record with `release-manager-v1`, different from the builder's and the reviewer's), never to the builder. Builders request landing; a builder LANDING_RESULT is refused. Without a configured release manager, landing items hold `release_manager_missing`. A grant that 0.3.0 already sent to a builder becomes a `legacy_grant_outstanding` hold, settled only with **Result lost — hold slot…** or **Reconcile observed outcome…**.
- **Coordinators no longer file reviews.** A coordinator REVIEW_RESULT is refused (`review_unauthorized`). An approved `review` proposal opens a review by a separate reviewer worker. Coordinator review results stored by 0.3.0 carry no proof and are dropped at restore.
- **Policy saves are fenced by digest.** The `policy` command takes `expected_policy_sha256` (the `workflow-index` `policy_sha256` of the displayed settings) instead of the full expected policy, and refuses with `policy_conflict` when the saved settings changed. Templates and role guidance save one entry at a time (`template_put`, `template_remove`, `role_guidance_put`).
- **Approved proposals execute.** An approved coordinator `dispatch`, `report`, `review` or `landing` proposal (owner or policy) is carried out exactly once; `rollover` stays record-only. Decisions answered before 0.4.0 are never executed. Gate answers carry a tagged source (owner or policy).
- REVIEW_RESULT now has `review_id`, `round` and `findings` (file and line) instead of `evidence`; DONE may carry `output_ref`.
- Every worker has a role (`builder`, `reviewer`, `release_manager`, `labeller`, `coordinator`); 0.3.0 workers restore as builders or coordinators.

### Added

- Config v4: 46 settings (from 27), with new cards Loops, Review & proof, Release, Checkouts, Autonomy, Work sources, Routing, Role guidance and Templates; a 48 KiB bound on the saved policy.
- Loop caps: every loop that re-engages a model or worker (rollover checkpoint and report re-requests, owner retries, landing refreshes, check rework, review rounds, deploy retries, labeller retries, template chains) stops at `loop_cap` with one `loop_cap` owner gate.
- Stale-claim alert: a claim older than `stale_claim_min` raises one `stale_claim` gate; ORCH+ never takes over a claim.
- Code-proven checks and checkout facts: work declares files, scope and checks; ORCH+ sends SPAWN an authenticated assignment manifest; the builder's SPAWN helper reports CHECKOUT and CHECK_RESULT from git and the manifest's exact argv. New gates `shared_checkout` (checkout roots), `file_overlap` and `scope`; `checkout_mismatch` and `scope_open` landing holds.
- Cross-family review: a fresh reviewer worker per round answers one fixed question with findings tied to file and line; reviewers are chosen from **Reviewer records** in order under a declared family map; `reviewer_unavailable` and `family_unknown` gates; typed `rework` carrying only findings and failed checks; `review_rounds` cap; reviewers finish automatically.
- Deploys: after `landed`, one `deploy_grant` per attempt to the release manager, DEPLOY_RESULT (`deployed`, `held`, `not_applicable`, `failed`), a `deploy_hold` owner gate, owner retries capped by `loop_cap`, and read-only lost/reconcile controls.
- Autonomy inside plan scope: `auto_approve_kinds` lets the session policy answer in-scope `dispatch`, `report`, `review` and `landing` decisions, visibly tagged as policy answers.
- Work sources: **Start work…** imports a `/glitch-plan` file (checkpoints in order, INDEPENDENT tasks in parallel, stable check IDs), uses a Tern board or starts a saved template (also from **Start…** on a Config → Templates row); an inbox folder; durable, deduplicated intake with an optional intake gate; template chains bounded at 8 steps. New module `plan_import.luau`.
- Imported plans are shown on the controller: one **Imported plan · <title>** card per plan with its checkpoints and tasks, eight rows per page.
- Config record pickers offer only suitable records: the release-manager picker lists records with `release-manager-v1` that are not reviewer records, and the reviewer picker leaves out the release manager.
- Checkout facts without a manifest `base_ref`: the first `checkout` pins the launch HEAD, so later checkouts report committed (including out-of-scope) files, not only uncommitted ones.
- Work-class router and labeller: routes map a class to a record; a board card routes only by a `class-<class>` tag (optionally `#`-prefixed), an inbox file by a `**CLASS**:` line; intake without a class is labelled by a short-lived labeller worker; `label_unknown` gate.
- Role guidance per role, prepended to every assignment of that role: typed tasks, coordinator starts, attached panes, approved dispatch proposals, and reviewer, release-manager, labeller, plan, board, inbox and template assignments.
- Pause answers nothing by policy; on resume each still-pending in-scope proposal is policy-evaluated once against the current `auto_approve_kinds`.
- Review voids record their cause: `{artifact_revision}` when a newer checkpoint voided the approval, `{target_revision}` when a landing refresh did.
- Per-worker USAGE deltas: account readings at launch and DONE, shown per quota window on the health card with the number of workers that shared the account.
- Worker and landing cards show role, declared family, review and proof status, release manager and deploy status. A landing row whose approval a refresh voided reads "approval void — awaiting fresh review/request".
- Gate answers that ORCH+ refused itself read "Refused by ORCH+ (<code>), not an owner answer: <reason>".
- New native test group `workflow`.

### Fixed

- A `stale_target` landing result now sends the builder one `landing_refresh` notice, as `target_moved` already did; previously the item waited for a refresh nobody was told about.
- A coordinator proposal sent while the session is paused (`session_paused`), or naming work without a retained CHECKPOINT of its project (`scope_mismatch`), is now refused definitely: ORCH+ answers its gate `reject` itself (source `refusal`), delivers one `owner_decision`, and the coordinator's report lane is no longer held until the owner re-checks. The coordinator may propose again, even with the same `proposal_id`.
- An untouched window no longer stalls orchestration. Tern does not wake an idle window for a due window timer, so ORCH+'s 500 ms observation loop stopped until someone next used the window. Under Xvfb, a worker HEARTBEAT went unread for minutes and actions sat in backpressure for about 30 minutes. Now, while the window drives an active controller with timed work, it keeps one short argv-only wait child in flight, whose exit wakes the window. The child is `sleep 2`, or `ping -n 3 127.0.0.1` on Windows. The Health card shows **Idle-wake helper active: …**. The helper never runs without such work, for a controller awaiting continuation, in host VMs, or after a failed child. Regression: `health/idle_wake`.
- Finish no longer fails silently: a refused Finish (for example on a reattached worker held `target_unavailable` or holding an uncertain old effect) always shows its reason, and the mailbox-retirement retry is sent instead of being refused in the window. Regression: `health/finish_refusal`.
- Intake inbox and board polling now keep the idle-wake helper running in an untouched window with no workers. Regression: `health/idle_wake`.

### Known limits

- Windows without an active ORCH+ controller (for example a window showing only SPAWN) get no idle-wake helper and can still stall until they are used; the underlying Tern timer issue is not fixed.

## 0.3.1

Requires SPAWN 0.3.1 (its unused-mailbox retirement now accepts a launch whose window challenge expired unconsumed).

### Fixed

- **ORCH+ Reload recovery guide** with nothing left to do showed a red error toast, which read like a failure. The empty branch only raised a dispatch notice at error level. It now opens a picker saying "No reload recovery step remains (controller, SPAWN owner and every worker are settled)" with a **Close** item, and shows an info toast titled **ORCH+ Reload recovery guide**; the controller's notice line still updates, and a step still being read keeps its text in the picker's placeholder. Regression: `health/guided_recovery_empty`.
- After a reload, a stopped worker was still listed as `accepted`. The worker row showed the last recorded phase, which restore never changes. The row now shows `retired` once the mailbox is retired and `stopped` once the native stop is verified (`absent` or `exited`); live workers are unchanged. Ordinary workers with a requested stop also show "Native stop: … · mailbox: …" whenever no finish line already shows it. The change is view-only; stored state is untouched. Regression: `health/stopped_worker_view`.
- SPAWN: managed launches, including rollover successors, could still take focus when the new agent tab grabbed it after the launch returned (seen on macOS). Focus was checked once, right after the start. SPAWN now keeps a short focus guard for each new pane: for 5 seconds, if focus lands on that pane, it is returned once to the previously focused pane (normally the controller). The guard is dropped as soon as you focus a third pane yourself, so a deliberate move is never undone. Back-to-back launches return focus to the original pane, not to an earlier worker. Ordinary SPAWN launches still focus their tab. Regression: SPAWN `window_dispatch`.
- **Cancel never-launched work…** on fenced work (continuation proved its launch or adoption never ran) whose mailbox was already provisioned removed the worker and left that mailbox provisioned and unused in SPAWN, still counting against its generations. ORCH+ now keeps the worker and retires the never-used mailbox through the exact retirement path, without a native stop. After the same evidence checks as before (including the read of SPAWN's retained status when SPAWN received the request), the cancel answers `withdrawal_retiring` and keeps the fenced action, so the work never re-enters routing or holds a concurrency reservation. Once SPAWN confirms `retired`, the worker is reclaimed and a coordinator start frees its orchestrator slot. A refused retirement can be retried by cancelling again; a pending or uncertain one is never repeated (`retirement_unresolved`). The withdrawal survives an ORCH+ restart. Fenced work without a mailbox is still removed directly. SPAWN: unused-mailbox retirement now also accepts a launch that was only staged: no execution or ORCH+ claim, no pane, attachment, acceptance or stop, and a requested window challenge that expired or was issued before a host restart. The accepting save fences that challenge and rejects the launch (`authorization_revoked`), so it can never be re-staged and authorized while its mailbox retires; a live challenge or a claimed launch is still refused. Regression: `dispatch/withdraw_fenced`, `health/withdraw_fenced`, SPAWN `dispatch/unused_retirement`.
- SPAWN: a request the host had already refused, left pending in the window by an interruption such as a host restart, blocked every new request until it was acknowledged by hand under Transport review. A definitive refusal changed nothing, so the window now acknowledges it automatically, shows one info toast "Cleared an earlier refused SPAWN request" naming the operation and error, and continues with the new request. An admitted (`ok`) reply or a reply not yet visible still needs manual review, and that refusal now names the operation and the way to Transport review. Regression: SPAWN `behavior` (`refused_pending`), plus an isolated live fault-injection check.

### Added

- SPAWN: after the execution host's Tern daemon restarted, every agent launched before it showed as a separate `Unknown` attempt, and each one blocked a new launch of its account as a `duplicate` until it was marked one by one. SPAWN now records the daemon identity with each attempt and recognises attempts lost to a restart (Unknown, recorded under a different, known daemon identity). The window shows one info toast "Host restarted — N SPAWN agents were lost", and **Running agents** gets a **Host restart** item whose confirmed **Mark all N lost agents no longer running** releases exactly those reservations, all-or-nothing (Config's Running agents page offers the same action with two clicks). It never closes a pane or stops a program; a stale list or any attempt that is not lost is refused with nothing changed. Hosts whose daemon identity cannot be read (non-Linux) keep the per-attempt **Mark no longer running**. Before downgrading SPAWN, settle pending window requests and acknowledge retained replies (see SPAWN's bridge notes). Regression: SPAWN `authority/lost_release`, `host_editor`.
- SPAWN: **Spawn all** now waits 5 seconds after each launch reaches the host before starting the next, so agent start-up memory spikes don't stack. Skipped, duplicate and disabled records don't wait, the first launch and **Spawn specific** start at once, and no ticket or admission exists during the wait. Checked on an isolated live host.

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
