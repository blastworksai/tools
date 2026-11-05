# ORCH+ managed worker and coordinator brief

Use only the `report-files-v1` mailbox and the producer helper, literal root, handle and enrolment token in your SPAWN launch preface. Visible pane text is not report intake. The original assignment and its SHA-256 are unchanged by this preface or later control replies. A role grant is not proof of native OS/account isolation.

If the owner attached your existing pane with **Attach pane N as ORCH+ worker…**, the same SPAWN preface and assignment arrive once as a native message in your current conversation instead of a fresh launch. Treat that message as your launch preface: enrol, publish ACCEPTED with its `assignment_sha256` (no handover pair), and follow this brief exactly like a launched worker. Earlier conversation content is not part of the assignment.

Your controller, coordinator, mailbox and SPAWN authority must run on your execution host. Local work uses local ORCH+; remote work uses ORCH+ on the attached remote Tern host, not a local controller launching or polling you through SSH. Ordinary SPAWN SSH launches remain separate and unchanged. Do not move journals, adopt a replacement controller or replay an uncertain effect to change topology; preserve issued identities and unresolved state for explicit recovery.

## Helper flow

On POSIX use `sh "$producer_helper" "$root" "$handle" "$enrolment_token" MODE`. On Windows use `powershell.exe -NoLogo -NoProfile -File <producer_helper> -Root: <root> -Handle: <handle> -Owner: <enrolment_token> -Mode: MODE`, passing each colon-ended parameter and literal value as separate argv elements. These are the existing configured helpers, not a new executable named by ORCH+.

- `init` is only for a genuinely new journal; recovery uses `replay`, never a sequence reset.
- `init` takes no input; piping a report into it is refused. Publish ACCEPTED and every other report with `report`.
- `report` reads one closed JSON object from stdin: `{kind,payload,action_id?,action_revision?,handover_id?,handover_token?}`. The helper supplies the issued binding, sequence and deterministic event ID; it journals immutable bytes and publishes manifest-last. ACCEPTED contains the exact original `assignment_sha256`, without a handover pair on initial launch. A rollover successor's ACCEPTED additionally carries the exact `handover_id` and `handover_token` from its launch preface; no other report may carry them.
- `receipts` independently reads and durably records ACKs, then publishes the cumulative receipt-chain watermark. Keep calling it after your last data report.
- `consume` records a complete typed reply and publishes its correlated `reply_ack` before returning the exact reply bytes. Receipt is not execution. Retained unclaimed replies may be returned again; do not repeat actions. Use the helper's existing `claim`/`resolve` journal when processing a reply; retain uncertainty rather than executing twice.
- With `native-ask-v1`, end the initial turn immediately after ACCEPTED and return idle before awaiting ACK/control. Native notifications require an idle worker. On notification, drain available `receipts` and `consume`, handle claimed control, then return idle when awaiting more control. Do not keep the turn open polling or calling `wait` for the next notification.
- With `worker-poll-v1`, use bounded `wait` (`wait '' 5 30` on POSIX; `-PollMs: 5000 -WaitSeconds: 30` on Windows) in the configured CLI's execution loop. Drain `receipts` and `consume` at checkpoints. Neither transport permits inspecting another pane's screen or transcript to reconstruct protocol state.

The controller implements REGISTER, initial ACCEPTED, READY, HEARTBEAT, WAITING, BLOCKED, ASK, CHECKPOINT, REVIEW_READY, REVIEW_RESULT, DONE, ROLLOVER_REQUEST, LANDING_REQUEST, LANDING_RESULT, reply_ack and the explicitly provisioned coordinator controls below. Reports are structured evidence, never authority to launch, merge, switch profiles, adopt panes or answer native prompts. DONE does not prove native exit, coordinator release or landing. Verified worker rollover is executed by the controller (see below); a ROLLOVER_REQUEST report remains retained evidence and does not start one. Landing runs only through the queue below: you request it, the owner approves it, ORCH+ grants the target's single slot, and you run your own approved project workflow.

Ordinary workers finish through the owner's explicit **Finish ordinary worker…** button, not by treating DONE as a stop request. Resolve processed helper claims, fulfill progress requests and settle owner decisions first. After finish is accepted, do not start fresh work or emit fresh progress; continue draining committed ACKs and replies. ORCH+ waits for the exact cumulative report/reply floors, verifies SPAWN's exact native stop outcome, then retires the settled mailbox. Uncertain effects and referenced review/rollover/landing evidence block finish rather than being discarded. A stopped pane alone does not prove mailbox settlement.

## Progress, questions and durable decisions

Send only closed payloads. READY is `{"state":"idle","summary":"Optional short summary","context_used_pct":42}`. HEARTBEAT is `{"state":"working","summary":"Optional short summary","request_id":"issued-request","context_used_pct":42}`; state is `working|idle|waiting|blocked`, and summary, request_id and context_used_pct are optional. WAITING is `{"reason":"What is missing","request_id":"issued-request"}` with optional request_id. BLOCKED is `{"reason":"Specific blocker","evidence":["artifact:reference"]}` with optional evidence. Do not send null for absent fields.

**Context usage.** When omp shows your context usage, include it in every READY and HEARTBEAT as `context_used_pct`: a whole number from 0 to 100 (round the displayed percentage; do not send decimals, strings or values outside 0–100, which reject the whole report). Omit the field when omp does not show it; never estimate. ORCH+ stores only the latest value with its report sequence and displays it as worker-reported evidence; it is not a native measurement. When the owner enables automatic worker rollover in Config, a value at or above the threshold makes an idle, non-excluded ordinary worker eligible for a rollover checkpoint request; it never stops or replaces you by itself.

An immutable `report_request` reply has payload `{request_id,requested_kind,reason}`. Consume/claim it once and echo its **exact request_id** in HEARTBEAT or CHECKPOINT. One request remains outstanding until both its matched reply_ack and its correlated progress response are accepted, in either order. WAITING can name it but does not fulfill it. Unsolicited progress does not fulfill an outstanding request. Replay exact journal bytes after uncertain publication; do not allocate a new event for the same response or invent another request ID.

ASK creates a durable owner gate:

```json
{"kind":"ASK","payload":{"question":"Should I use the reviewed migration?","options":[{"id":"reviewed","label":"Use the reviewed migration"},{"id":"hold","label":"Hold"}],"evidence":["checkpoint:cp-1"]}}
```

The owner answers the exact gate revision and recipient generation through the admitted controller UI. This records an **owner UI workflow source**, not native attestation that a human approved it. The gate progresses `pending → answered → delivery_pending → delivered → acknowledged`. The resulting immutable reply includes gate ID/revision as well as message, reply sequence and action/revision. Publication is not consumption: only the matching reply_ack acknowledges it. Changed/stale answers cannot authorize another operation. Cancellation before an outbox exists sends nothing; cancellation after issuance preserves the immutable possibly delivered decision and its ACK uncertainty. Never interpret a cancelled or superseded decision as a fresh operation grant.

Example complete version-1 reply, with illustrative issued identifiers:

```json
{"version":1,"logical_session_id":"orch-1","worker_id":"worker-1","worker_generation":1,"launch_request_id":"launch-1","work_id":"work-1","message_id":"message-1","reply_seq":1,"action_id":"reply-action-1","action_revision":1,"kind":"owner_decision","gate_id":"gate-1","gate_revision":1,"payload":{"choice_id":"reviewed","answer":"Use only the reviewed migration."}}
```

CHECKPOINT is durable structured handoff evidence. Use a new checkpoint ID when its contents change; IDs are immutable. Completed/remaining/holds are string arrays. Checks are `{check_id,artifact_revision,outcome,evidence_ref}`, with outcome `passed|failed|not_run`. Optional plan_ref and plan_revision must appear together; optional request_id correlates a progress request.

```json
{"kind":"CHECKPOINT","payload":{"checkpoint_id":"cp-1","task_ref":"task:assigned","project_id":"project-1","worktree_ref":"worktree:assigned","artifact_revision":"revision-1","completed":["Implemented the assigned change"],"remaining":["Owner runs native acceptance"],"holds":[],"checks":[{"check_id":"native","artifact_revision":"revision-1","outcome":"not_run","evidence_ref":"owner:acceptance"}]}}
```

REVIEW_READY (`{checkpoint_id,artifact_revision,summary?}`), DONE (`{checkpoint_id,artifact_revision,summary}`) and ROLLOVER_REQUEST (`{checkpoint_id,reason}`) must reference retained checkpoint evidence; the artifact revision must match when present. REVIEW_RESULT requires the exact action/revision of an acknowledged, approved typed coordinator review proposal decision and its pinned artifact revision. LANDING_RESULT requires the exact action/revision of your own issued `landing_grant` (see **Landing queue**). Both remain **reported evidence**, not native effect attestation; ordinary report requests and unrelated answers cannot authorize them. The coordinator brief lists the proposal contract.

## Verified worker rollover

Rollover replaces an ordinary worker with a **fresh** successor context. It is started by the owner's **Roll over worker…** control or, when enabled, by the session policy; coordinators use the separate non-overlapping coordinator rollover in [`coordinator-brief.md`](coordinator-brief.md). No transcript is transferred: the successor receives only your checkpoint.

**As the predecessor**, you receive an ordinary `report_request` whose `requested_kind` is `CHECKPOINT` and whose reason names the rollover. Consume/claim it once, then publish one CHECKPOINT echoing its exact `request_id`. A rollover checkpoint must name completed and/or remaining work, keep holds/blockers explicit, and include at least one check; every check's `artifact_revision` must equal the checkpoint's `artifact_revision` with outcome `passed`. A `failed`, `not_run` or stale check blocks the rollover: report BLOCKED or fix the failure first rather than handing over failing work. ORCH+ records these outcomes as **worker-attested**, not independent verification, and never runs a check you name. Once the CHECKPOINT is published, **`resolve` the claimed request** (and every other processed control message) in the helper journal: you get no later chance, because ORCH+ stops your pane without another turn, and SPAWN refuses to retire a stopped mailbox whose journal still holds unacknowledged or unresolved messages (`producer_unsettled`). After that, start no new work, send no further progress reports and stay idle while draining `receipts`/`consume`. ORCH+ stops your exact pane through the normal finish path only after the successor's handover acceptance is recorded and the successor is observed alive. If the rollover is held or cancelled you keep running; a blocked checkpoint may be requested again with a new `request_id`.

**As the successor**, your assignment begins with `ORCH+ verified worker rollover <handover_id>` followed by the predecessor's checkpoint payload. Report ACCEPTED with this assignment's `assignment_sha256` plus the `handover_id`/`handover_token` pair from your launch preface, for example:

```json
{"kind":"ACCEPTED","handover_id":"handover-1","handover_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","payload":{"assignment_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}
```

A missing or different pair is rejected. Then continue only the checkpoint's remaining work in the same project/worktree, respecting every hold. Do not contact, inspect or control the predecessor pane.

## Landing queue

Landing is per project, repository and target ref, in FIFO order, with **one granted slot per target** in this session. ORCH+ never runs git, never merges and never infers landing from REVIEW_READY, DONE, idle or a closed pane: you perform your own approved project merge/rebase workflow and report the exact outcome.

1. Publish a CHECKPOINT for the exact artifact you want to land, with at least one required check whose `artifact_revision` equals it and outcome `passed`, and no holds. `not_run`, `failed`, stale checks, holds, a newer checkpoint for another revision or a BLOCKED report block the grant with a visible reason; nothing passes by default. Checks are worker-attested, not independent verification.
2. Request landing with LANDING_REQUEST naming that checkpoint, the exact source ref/revision (the checkpoint's `artifact_revision`) and the exact target repository, ref and **expected head revision**. No action/handover fields:

```json
{"kind":"LANDING_REQUEST","payload":{"checkpoint_id":"cp-3","project_id":"project-1","repo_ref":"git@example:project-1.git","target_ref":"refs/heads/main","target_revision":"1a2b3c","source_ref":"refs/heads/work-1","source_revision":"4d5e6f","summary":"Ready to land"}}
```

3. The request becomes a durable `landing_approval` owner gate for that exact request. Consume its `owner_decision` like any other; it is information, not permission. ORCH+ has no automatic landing policy, so nothing lands without the owner's approval. A reject (or a cancelled gate) withdraws the request.
4. When your request is the queue head, approved, and your latest checkpoint is still fresh, ORCH+ issues one immutable `landing_grant` reply: `{landing_id,grant_id,project_id,checkpoint_id,repo_ref,target_ref,target_revision,source_ref,source_revision}`. Consume/claim it once; consumption is not landing. Land only that exact source revision onto that exact target, and only if the target head still equals `target_revision`.
5. Report exactly one LANDING_RESULT correlated to the grant's `action_id`/`action_revision`, echoing `landing_id`, `grant_id`, `project_id`, `repo_ref`, `target_ref`, `target_revision` and `source_revision`, plus `evidence` and optional `pr_ref`/`summary`:
   - `landed` with `result_revision` (the resulting target head; no `reason`);
   - `rejected` with `reason` (for example conflicts or failing checks);
   - `stale_target` with `observed_target_revision` (the moved head, different from `target_revision`) and optional `reason`;
   - `uncertain` with `reason` when you cannot tell whether it landed.

```json
{"kind":"LANDING_RESULT","action_id":"reply-action-7","action_revision":1,"payload":{"landing_id":"landing-5","grant_id":"landing-grant-6","project_id":"project-1","repo_ref":"git@example:project-1.git","target_ref":"refs/heads/main","target_revision":"1a2b3c","source_revision":"4d5e6f","outcome":"landed","result_revision":"7a8b9c","evidence":["ci:run-42"]}}
```

`landed` records the new head and frees the slot. `rejected` fails the item. `stale_target` frees the slot and keeps your item in place as **needing refresh**: rebase or rebuild as your workflow requires, publish a fresh CHECKPOINT and a fresh LANDING_REQUEST for the same target expecting the new head; it needs a new owner approval. Never re-run a merge because a reply or result seemed lost.

When another request lands (or the owner records a head) while yours is still ungranted and expects the old head, your item is blocked as `target_moved` and ORCH+ issues **one** immutable `landing_refresh` reply to your generation: `{landing_id,project_id,repo_ref,target_ref,expected_revision,current_revision,reason}`, where `expected_revision` is the head your request expects and `current_revision` the recorded new head. Consume/claim it once and acknowledge it like any reply; it is information, never permission to push. Then rebase or rebuild onto `current_revision`, publish a fresh CHECKPOINT with a **new** `checkpoint_id` and fresh checks for the rebuilt artifact, and send a fresh LANDING_REQUEST for the same target with `target_revision` equal to `current_revision`. That rebinds your existing item at its queue position and needs a new owner approval; wait for a `landing_grant` before landing. Replays never repeat the notice; if the target moves again after you refreshed, you receive one new `landing_refresh` for the new head only. Example complete version-1 reply, with illustrative issued identifiers:

```json
{"version":1,"logical_session_id":"orch-1","worker_id":"worker-2","worker_generation":1,"launch_request_id":"launch-2","work_id":"work-2","message_id":"message-9","reply_seq":2,"action_id":"reply-action-10","action_revision":1,"kind":"landing_refresh","payload":{"landing_id":"landing-6","project_id":"project-1","repo_ref":"git@example:project-1.git","target_ref":"refs/heads/main","expected_revision":"1a2b3c","current_revision":"7a8b9c","reason":"Target moved (landed via landing-5). Rebase or rebuild onto current_revision, publish a fresh CHECKPOINT and a fresh LANDING_REQUEST expecting current_revision; it needs new owner approval. Never push without a landing_grant."}}
```

While you hold a grant: do not send DONE (DONE without a result leaves the slot uncertain), do not finish, and expect rollover to be refused. An `uncertain` result, a lost worker (exit, stop, held or rejected report) or the owner's **Result lost** mark holds the slot until the owner inspects the target read-only and reconciles it as landed (with head) or not landed. A later result for that grant is kept as evidence only. Do not send another LANDING_REQUEST for a target whose grant you hold. An ungranted request may be reordered or cancelled by the owner.

An ungranted request is held while its worker is part of an unfinished rollover. A rollover successor (same work) re-publishes a fresh CHECKPOINT and LANDING_REQUEST for the same target; that refresh rebinds the existing queue item to the successor at its current position and needs a new owner approval.

## Framing, bounds and freshness

The helper builds version-3 report envelopes. This is a parseable envelope example; identifiers/digests below are illustrative and must be replaced with the issued binding and the helper's deterministic event ID:

```json
{"version":3,"logical_session_id":"orch-1","worker_id":"worker-1","worker_generation":1,"launch_request_id":"launch-1","enrolment_token":"issued_enrolment_token_1234","work_id":"work-1","event_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","seq":2,"kind":"HEARTBEAT","payload":{"state":"working","summary":"Working within the assigned scope","request_id":"report-request-1"}}
```

Its matched version-1 ACK has the complete exact-byte report SHA-256, original committed revision and cumulative receipt chain, not a loose success flag:

```json
{"version":1,"logical_session_id":"orch-1","worker_id":"worker-1","worker_generation":1,"launch_request_id":"launch-1","work_id":"work-1","event_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","seq":2,"event_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","committed_revision":42,"disposition":"accepted","receipt_chain_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}
```

All messages are manifest-last, including small ones: at most 65,536 logical UTF-8 bytes, 32 slices of 2,048 raw bytes, 4,096-byte chunk JSON, 2,048-byte control/manifest JSON and an 8,192-byte bridge. The producer retains eight data reports plus eight reserved reply-ACK reports; the authority retains at most eight unacknowledged replies per generation. Full means backpressure, not permission to discard source bytes or reset a journal. Each work thread retains at most 128 entries. Generic acknowledged or safely cancelled gates may be reclaimed at the 64-gate bound; their original report receipt/cursor still prevents a repeated ASK from creating another question. At most 16 live checkpoints per worker are retained; checkpoint-ID immutability and typed rollover, review and landing references remain pinned, with explicit full backpressure until the lifecycle owner settles those references. Fully stopped, mailbox-retired and unreferenced generations may be reclaimed at worker admission; their generated identities never repeat.

Session defaults are poll=5,000ms, heartbeat=60,000ms, stale=180,000ms, automatic_reports=false and paused=false. Policy bounds are poll 1,000..60,000ms, heartbeat 5,000..3,600,000ms, stale at least heartbeat and at most 86,400,000ms. Pause stops new tasks/proposals/requests, not intake, existing replies, owner answers or safety observations. Automatic requests require explicit policy and a safe observed native idle worker or configured worker polling; working, waiting-input, exited and unsupported/unconfirmed native input are never interrupted. The host uses epoch-bound monotonic time, not worker or window wall timestamps. After restart freshness is unconfirmed until fresh evidence arrives. Missing/moved pane evidence is unknown/awaiting-window, not exit.

Native permission/authentication gates require the owner to open the exact relevant pane and act there. **I resolved this — recheck** only asks for a new native lifecycle observation. It never logs in, answers a prompt or retries an uncertain operation. Health keeps separate native and reported facts; READY cannot override native waiting-input or exit.
An exact native exit is retained as a separate terminal lifecycle fact even when later observations are unknown or progress reports say READY. Missing/moved panes never establish exit. Restart makes freshness unconfirmed without erasing a previously confirmed exit.

Known durable ACK/reply publication is separate from a native notification that has not begun. ORCH+ retains at most 32 pending notification obligations per generation; idle-only `native_wake` grants use the ordinary one-generation/four-host execution limits. Busy workers can still exchange mailbox reads/receipts while notification waits. A started or uncertain notification keeps its execution slot; it is never repeated because a status record is missing. For native workers, return idle after draining each turn so pending ACKs and decisions can trigger their safe notification.

A fully assembled rejected report is retained with its exact bytes and a visible diagnostic. Its completed read releases the execution slot, but its acceptance cursor and receipt stay unchanged: there is no rejection ACK, silent skip, sequence reset or permission to overwrite the immutable producer event. Receipt-watermark settlement remains available while the owner inspects the hold.

Reload continuation is explicit owner recovery. The owner first continues the same controller identity after verifying old executors are stopped/retired, then reads retained outcomes and individually resolves unknown executors through the existing recovery controls. SPAWN's Config recovery may also require explicit executor fencing. The owner selects the exact worker's current pane and confirms a worker-scoped attachment proof; unrelated health ticks do not invalidate that proof, but changes to its owner, generation, gate or effect evidence do. Attachment retains the original launch/mailbox/enrolment identity and pending immutable decisions; it records a separate current control route. It neither reactivates uncertain coordinator authority nor authorizes replay of an old effect. Workers keep their existing producer journal and tokens unchanged.

## Coordinator activation and normal finish

Only records explicitly configured and provisioned with `coordinator-control-v1` can be started as coordinators. Ordinary `report-files-v1` workers and coordinators from earlier builds do not acquire this authority implicitly.

The paired coordinator owner ID/generation in the launch enrolment makes this a coordinator assignment. ACCEPT the exact assignment, then **wait for and claim typed activation before performing coordinator work**. After ACCEPTED/ACK/semantic acceptance, ORCH+ issues one immutable `coordinator_activation` reply. Its payload contains exactly `owner_id`, `owner_generation`, `activation_token` and `instructions`. Retain its action ID/revision, token and owner identity; `consume` must durably acknowledge activation before release is accepted. The token is typed data, not an instruction hidden in the original assignment. Ordinary work on the same capable record has no coordinator pair and must not wait for activation.

Do not independently orchestrate Tern, create agents, switch sessions or launch native orchestration commands. Work only within the assigned task. When that task finishes or a typed retirement requests stop, quiesce and send this object through **report**, substituting values from the exact activation (or retirement) reply. Idle alone is not task completion:

```json
{"kind":"COORDINATOR_RELEASE","action_id":"reply-action-1","action_revision":1,"payload":{"owner_id":"owner-1","owner_generation":1,"activation_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","quiescent":true}}
```

Use the actual issued revisions/generation, not the illustrative `1`. Release is cooperative quiescence and intent, not proof of native exit. DONE, idle, pane absence and generic task completion never release the coordinator slot.

Before reporting release, **resolve the claimed activation and every processed retirement/control message in the producer helper's execution journal**, addressed by its `message_id`. Keep the issued action ID/revision, owner/generation and activation token separately so resolving the journal does not lose release correlation. Only resolve work that is actually complete and quiescent; uncertainty must remain unresolved. For a retirement reply arriving after self-finish, claim and resolve that control message once quiescent without emitting another release event. Resolve all consumed messages before draining their final ACK receipts/watermarks. Native stop alone does not settle a producer execution journal: authorized mailbox retirement refuses any remaining pending reports or unacknowledged/unresolved consumed execution.

An owner's **Request graceful coordinator retirement** creates a typed `coordinator_retirement` reply with the same owner/generation/token and a reason. Stop taking fresh work, quiesce, then report release correlated to that reply or the original activation. Continue draining already-committed replies and ACKs even if retirement arrives after self-finish. Never submit a second release as a new event: replay the immutable original if its ACK is missing. A retirement request alone neither stops you nor clears ownership.

After release, only outstanding reply acknowledgements may follow. Keep `receipts`/`consume` running until the final release ACK and any later reply_ack ACKs have been durably received and cumulatively watermarked. ORCH+ then authorizes SPAWN to stop the exact native pane once, retire its settled mailbox, and clear only that coordinator owner/generation. A replacement is always a separate explicit start. Do not revive or reset a retired mailbox. Uncertain stop, missing grant, restoration or storage failure retains occupancy for inspection; never infer permission from silence.

This documents the source contract, not runtime proof on any platform.
