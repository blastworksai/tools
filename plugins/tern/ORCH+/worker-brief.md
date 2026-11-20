# ORCH+ managed worker and coordinator brief

Use only the `report-files-v1` mailbox and the producer helper, literal root, handle and enrolment token in your SPAWN launch preface. Visible pane text is not report intake. The original assignment and its SHA-256 are unchanged by this preface or later control replies. A role grant is not proof of native OS/account isolation.

**Open a conversation** and **Enable managed coordination** use a fixed enrollment assignment: preserve the current conversation's task and context, enroll with the supplied instructions, then wait for the user's task. Do not create, edit or delete files merely to enroll. An idle recognized native agent receives those instructions once by native ask; another provider's terminal receives one owner-requested clipboard copy for the owner to paste. A copy or submission is not acceptance. Publish ACCEPTED using the exact supplied assignment SHA-256; never substitute the old conversation transcript or replay its prior task. Do not initialize a replacement token after uncertainty. An untouched pending capability can be revoked without stopping the existing conversation; a consumed capability must settle its original journal.

Your controller, coordinator, mailbox and SPAWN authority must run on your execution host. Local work uses local ORCH+; remote work uses ORCH+ on the attached remote Tern host, not a local controller launching or polling you through SSH. Ordinary SPAWN SSH launches remain separate and unchanged. Do not move journals, adopt a replacement controller or replay an uncertain effect to change topology; preserve issued identities and unresolved state for explicit recovery.

Projects are explicit work containers, not provider or account identities. Associating a busy or unsupported conversation is allowed without enabling managed coordination; it cannot infer an account or release held source work. Imported plans, board cards, inbox tasks, templates and approved passive coordinator proposals wait for project START by default. ACTIVE may mean an attached conversation is already active, not that new work has been started. START while paused records intent but produces no new effect until Resume. A saved explicit auto-start policy is separate from attachment. Text/research conversations need no Git checkout or release manager.

Plan re-import matches uniquely unchanged semantic tasks across inserted or renumbered checkpoints, retaining existing work, completion and immutable worker/report identities. Changed or ambiguous managed tasks remain held; never restart completed work or rebind an old receipt to a different task. Template custom fields are actual prompt/output inputs: each template supplies its own defaults, and only explicit invocation overrides carry to the next template. A previous template's default must not overwrite the next one's.


## Helper flow

On POSIX use `sh "$producer_helper" "$root" "$handle" "$enrolment_token" MODE`. On Windows use `powershell.exe -NoLogo -NoProfile -File <producer_helper> -Root: <root> -Handle: <handle> -Owner: <enrolment_token> -Mode: MODE`, passing each colon-ended parameter and literal value as separate argv elements. These are the existing configured helpers, not a new executable named by ORCH+.

- `init` is only for a genuinely new journal; recovery uses `replay`, never a sequence reset.
- `init` takes no input; piping a report into it is refused. Publish ACCEPTED and every other report with `report`.
- A coordinator proposal the helper refuses as `invalid_schema` carries a second line naming the field and the rule it broke (for example `payload.checks[0].argv: must hold 1 to 16 entries, has 49`); other reports name a missing or unknown field the same way. Fix that field and send the report again; nothing was published.
- `report` reads one closed JSON object from stdin: `{kind,payload,action_id?,action_revision?,handover_id?,handover_token?}`. The helper supplies the issued binding, sequence and deterministic event ID; it journals immutable bytes and publishes manifest-last. ACCEPTED contains the exact original `assignment_sha256`, without a handover pair on initial launch. A rollover successor's ACCEPTED additionally carries the exact `handover_id` and `handover_token` from its launch preface; no other report may carry them.
- `receipts` independently reads and durably records ACKs, then publishes the cumulative receipt-chain watermark. Keep calling it after your last data report.
- `consume` records a complete typed reply and publishes its correlated `reply_ack` before returning the exact reply bytes. Receipt is not execution. Retained unclaimed replies may be returned again; do not repeat actions. Use the helper's existing `claim`/`resolve` journal when processing a reply; retain uncertainty rather than executing twice.
- With `native-ask-v1`, end the initial turn immediately after ACCEPTED and return idle before awaiting ACK/control. Native notifications require an idle worker. On notification, drain available `receipts` and `consume`. Once the producer journal confirms ACCEPTED acknowledged, continue the original authorized assignment; no additional assignment reply is required. Required typed coordinator activation, landing grants and other control gates still apply. Handle claimed control, then return idle only when awaiting future control. Do not keep the turn open polling or calling `wait` for the next notification.
- With `worker-poll-v1`, use bounded `wait` (`wait '' 5 30` on POSIX; `-PollMs: 5000 -WaitSeconds: 30` on Windows) in the configured CLI's execution loop. Drain `receipts` and `consume` at checkpoints. Neither transport permits inspecting another pane's screen or transcript to reconstruct protocol state.

## Roles and task instructions

ORCH+ sets your role: builder, reviewer, release_manager or coordinator. Historical classifier work remains settleable; no new classifier sessions are launched. Follow the actual task instructions and built-in role/review guidance; optional global role-instruction overrides are retired. These instructions do not grant tool or account permissions. Class is optional task metadata; plans, board/inbox intake and templates use the Preferred Worker and explicitly permitted alternatives, not task-type routes. SPAWN owns provider_family and agent model/profile configuration.

**Scope.** Work only inside the declared `scope.paths` (by default the declared `files`). Systems listed in `scope.systems` are named for you only; ORCH+ code cannot see them. **Before touching any system not listed there** — another repository, service, host, account, database or deployment target — publish ASK and wait for the owner's decision. Needing to change a path outside the declared scope is likewise an ASK, never a silent widening.

## Builder checks and rework

These steps apply to repository-backed builder work on records carrying `check-runner-v1`, not to enrollment or text/research conversations. Every declared check needs successful helper evidence at the submitted revision in every review mode; worker-attested CHECKPOINT checks are not a substitute. Check argv come from the reviewed structured assignment, never an unreviewed command invented to open a conversation.

- Run the helper's `checkout` mode after ACCEPTED and again **before each CHECKPOINT**. It publishes CHECKOUT (`worktree_path`, `common_dir`, `branch`, `head`, `base`, `changed_files`, `changed_overflow`, `changed_total`, `dirty`) from git itself; ORCH+ uses it for the shared-checkout, file-overlap and scope gates. Do not try to publish CHECKOUT with `report`: it is refused.
- Run the helper's `run-checks` mode once for **every declared check**, passing that check's `check_id` as the mode argument (POSIX: `sh "$producer_helper" "$root" "$handle" "$enrolment_token" run-checks <check_id>`). The helper runs the argv from the authenticated assignment manifest (never argv you supply), without a shell, in your checkout, and publishes CHECK_RESULT (`check_id`, `argv_sha256`, `exit_code`, `output_sha256`, `head`, `ran_at_ms`). An unknown check ID or a `manifest_mismatch` is refused; report BLOCKED rather than working around it. CHECK_RESULT cannot be sent with `report`. Re-run every check after each new commit: a result counts only for the `head` it ran on.
- With require_code_review=true, publish CHECKPOINT then REVIEW_READY for independent review. A different declared SPAWN provider family is required when require_other_family=true. With both false, publish CHECKPOINT then LANDING_REQUEST without inventing a reviewer. You never review your own work. Merge only when this exact accepted session receives an eligible landing_grant and has managed release-manager-v1 capability.
- A `rework` reply has `{review_id?,round,artifact_revision,failed_checks,findings}`, with failed checks `{check_id,exit_code}`. Check repair is independent of reviewer availability; `review_id` is absent/nil without review, never fabricated. Consume/claim once. **Fix only the named failed checks and findings**, then run `checkout`, re-run every declared check and publish a fresh CHECKPOINT with a new ID for the new revision. Request review only when required, then request landing. A new revision invalidates earlier approval and check proof. Rework and review loops are capped; at the cap the owner decides.


The controller implements REGISTER, initial ACCEPTED, READY, HEARTBEAT, WAITING, BLOCKED, ASK, CHECKPOINT, CHECKOUT, CHECK_RESULT, REVIEW_READY, REVIEW_RESULT, LABEL, DONE, ROLLOVER_REQUEST, LANDING_REQUEST, LANDING_RESULT, DEPLOY_RESULT, reply_ack and the explicitly provisioned coordinator controls below. Reports are structured evidence, never authority to launch, merge, switch profiles, adopt panes or answer native prompts. DONE does not prove native exit, coordinator release or landing. Verified worker rollover is executed by the controller (see below); a ROLLOVER_REQUEST report remains retained evidence and does not start one. Landing runs only through the queue below: the builder requests it, the owner (or the owner's auto-approval policy) approves it, ORCH+ grants the target's single slot to the session's release manager, and the release manager merges under the repository's own rules.

Ordinary workers finish through the owner's explicit **Finish ordinary worker…** button, not by treating DONE as a stop request. Resolve processed helper claims, fulfill progress requests and settle owner decisions first. After finish is accepted, do not start fresh work or emit fresh progress; continue draining committed ACKs and replies. ORCH+ waits for the exact cumulative report/reply floors, verifies SPAWN's exact native stop outcome, then retires the settled mailbox. Uncertain effects and referenced review/rollover/landing evidence block finish rather than being discarded. A stopped pane alone does not prove mailbox settlement.

The configurable logical-task limit and retained-worker history are not physical launch capacity. SPAWN's existing allocation domain remains bounded to sixteen live generations, 64 MiB and 16,384 files. ORCH+ conservatively counts queued/uncertain preparations and reserves transient review/rollover progress plus each active selected-release session's future manager. Ordinary, coordinator and enrollment admissions can wait for agent space. DONE keeps its native conversation and allocation; only the existing explicit Finish, settled ACK floors, exact native exit and positive retirement free that space. Do not close conversations, replay startup or invent capacity to evade the bound.

## Progress, questions and durable decisions

Send only closed payloads. READY is `{"state":"idle","summary":"Optional short summary","context_used_pct":42}`. HEARTBEAT is `{"state":"working","summary":"Optional short summary","request_id":"issued-request","context_used_pct":42}`; state is `working|idle|waiting|blocked`, and summary, request_id and context_used_pct are optional. WAITING is `{"reason":"What is missing","request_id":"issued-request"}` with optional request_id. BLOCKED is `{"reason":"Specific blocker","evidence":["artifact:reference"]}` with optional evidence. Do not send null for absent fields.

**Runtime context.** READY, HEARTBEAT and CHECKPOINT may include `context_snapshot: {current_tokens,window_tokens,observed_at_ms,first_turn_tokens?}`. Use actual runtime context occupancy and capacity, in whole tokens, with the measurement's execution-host Unix time in milliseconds. Capture the first-turn occupancy for this exact conversation/generation after its first turn, including startup instructions; retain that baseline and window unchanged. Include it with subsequent snapshots when available. Do not substitute billed input/output totals, cumulative usage, a guessed window, transcript length or an estimate. If only an actual current runtime percentage is available, `context_used_pct` (whole 0–100) is allowed instead of a snapshot, but supports only a numerical override, never the calculated default. Omit unavailable measurements; a READY/HEARTBEAT without one makes current context unknown. A CHECKPOINT without one retains the preceding sample only until it becomes stale. Invalid or changed baseline/window measurements cannot authorize rollover. The calculated default is `current_tokens >= first_turn_tokens + 0.55 * (window_tokens - first_turn_tokens)`; 1–99 overrides compare actual current percent. Workers wait for the next completed-work CHECKPOINT boundary after threshold, then idle native state and settled controls. For neutral work, the checkpoint describes actual completed bounded work and remaining work, not an invented plan checkpoint. No measurement capability is implied by helper preparation: if your runtime does not expose these measurements, report progress without them and leave context unknown.

**When to suggest a fresh session — first matching rule wins.** (1) If context appears poisoned—for example, you revive an assumption that was already corrected—suggest a fresh session immediately, name the observed symptom, and label a suspicion as a suspicion. (2) Otherwise, evaluate context-based renewal only at a completed checkpoint: suggest it when reliable runtime measurements meet the calculated 55%-of-remaining-headroom rule or the explicit numerical override. If measurement is unavailable, say context is unknown; do not estimate. (3) Otherwise continue. Completing a task or checkpoint alone is not a reason to suggest renewal. A suggestion grants no restart authority and never bypasses checkpoint, retirement, activation or in-flight-effect safeguards.

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

### Recording a decision in its existing document

Only a record already provisioned with `coordinator-control-v1` can receive `record_ruling`. This does not activate coordinator authority. An `owner_decision` alone is not a document-write grant: wait for the separately issued, gate-correlated `record_ruling` reply addressed to your exact worker generation. Its closed payload is `{path,marker,entry,expected_document_sha256,expected_non_rulings_sha256}`. It authorizes only that entry in the existing document you own, not a new document, another task or a wider operation.

Consume and claim that immutable reply once. Use the exact absolute `path`; missing files, read-only files, ambiguous aliases, unsaved edits or an unknown writer remain blocked. Do not create a substitute, inspect/control another pane, force-save a buffer or take over another writer.

Before the one write, read the current document bytes and require their SHA-256 to equal `expected_document_sha256`. The bytes outside the recognized, outside-fence ruling block—including removal of that block's own leading separator—must hash to `expected_non_rulings_sha256`. A changed document, duplicate block, existing marker, malformed block or unterminated fenced example means stop for owner inspection, not refresh the hashes or retry with new authority.

Insert the exact supplied quoted `entry` immediately before the single `<!-- /orchplus-operator-rulings v1 -->` closing delimiter. If no ruling block exists, append a separator newline and one block delimited by `<!-- orchplus-operator-rulings v1 -->` and `<!-- /orchplus-operator-rulings v1 -->`, outside fenced examples. Preserve the document's consistent LF or CRLF style, converting only the supplied entry's line endings. Preserve every non-ruling byte; do not rewrite executable plan content, regenerate the document or manufacture different decision text.

After writing, verify one exact marker/entry and unchanged non-ruling bytes. Resolve the helper claim only when your one write has actually completed and these checks pass; otherwise retain uncertainty and report the concrete hold. Reply ACK or worker-reported success is not durable document confirmation: ORCH+ independently inspects the native document/buffer and disk. Lost callbacks, process exit or an already present marker never authorize a second append. The owner must settle the original writer and inspect the original intent before any explicit recovery.

### Checkpoints and task results

CHECKPOINT is durable structured handoff evidence. Use a new checkpoint ID when its contents change; IDs are immutable. Completed/remaining/holds are string arrays. Checks are `{check_id,artifact_revision,outcome,evidence_ref}`, with outcome `passed|failed|not_run`. Optional plan_ref and plan_revision must appear together; optional request_id correlates a progress request.

```json
{"kind":"CHECKPOINT","payload":{"checkpoint_id":"cp-1","task_ref":"task:assigned","project_id":"project-1","worktree_ref":"worktree:assigned","artifact_revision":"revision-1","completed":["Implemented the assigned change"],"remaining":["Owner runs native acceptance"],"holds":[],"checks":[{"check_id":"native","artifact_revision":"revision-1","outcome":"not_run","evidence_ref":"owner:acceptance"}]}}
```

REVIEW_READY, DONE and ROLLOVER_REQUEST must reference retained checkpoint evidence at the matching artifact revision. DONE may name a relative template output_ref (≤256 characters), matching the resolved template output path. REVIEW_RESULT is only from the independent reviewer. LANDING_RESULT/DEPLOY_RESULT are only from the exact grant holder: the existing accepted builder by default, or an optionally selected release agent. These reports remain evidence, never authority to execute an unrelated action.

## Verified worker rollover

Rollover replaces an ordinary worker with a **fresh** successor context. It is started by the owner's **Roll over worker…** control or, when enabled, by the session policy; coordinators use the separate non-overlapping coordinator rollover in [`coordinator-brief.md`](coordinator-brief.md). No transcript is transferred: the successor receives only your checkpoint.

**As the predecessor**, you receive an ordinary `report_request` whose `requested_kind` is `CHECKPOINT` and whose reason names the rollover. Consume/claim it once, then publish one CHECKPOINT echoing its exact `request_id`. A rollover checkpoint must name completed and/or remaining work, keep holds/blockers explicit, and include at least one check; every check's `artifact_revision` must equal the checkpoint's `artifact_revision` with outcome `passed`. A `failed`, `not_run` or stale check blocks the rollover: report BLOCKED or fix the failure first rather than handing over failing work. ORCH+ records these outcomes as **worker-attested**, not independent verification, and never runs a check you name. Once the CHECKPOINT is published, **`resolve` the claimed request** (and every other processed control message) in the helper journal: you get no later chance, because ORCH+ stops your pane without another turn, and SPAWN refuses to retire a stopped mailbox whose journal still holds unacknowledged or unresolved messages (`producer_unsettled`). After that, start no new work, send no further progress reports and stay idle while draining `receipts`/`consume`. ORCH+ stops your exact pane through the normal finish path only after the successor's handover acceptance is recorded and the successor is observed alive. If the rollover is held or cancelled you keep running; a blocked checkpoint may be requested again with a new `request_id`.

**As the successor**, your assignment begins with `ORCH+ verified worker rollover <handover_id>` followed by the predecessor's checkpoint payload. Report ACCEPTED with this assignment's `assignment_sha256` plus the `handover_id`/`handover_token` pair from your launch preface, for example:

```json
{"kind":"ACCEPTED","handover_id":"handover-1","handover_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","payload":{"assignment_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}
```

A missing or different pair is rejected. Then continue only the checkpoint's remaining work in the same project/worktree, respecting every hold. Do not contact, inspect or control the predecessor pane.

A failed successor is not permission to create another. The controller may read its exact retained allocation metadata without replaying provisioning or inferring native launch absence. Unknown allocation or native launch effects stay held. Only definitive unused-startup proof with no pane/ACCEPTED, pending/unknown native startup or open gate permits the owner's existing cancellation/retirement path; the owner separately closes the handover after positive retirement or exact absence proof. The predecessor is never stopped by that cleanup.

## Landing queue

Landing uses the project's verified canonical repository/target and current target queue, with expected-old head, passing exact-revision checks, independent review when required and exact approval. By default the existing builder receives eligible merge/deploy grants: no additional manager session starts. The actor needs actual managed release-manager-v1 capability and current identity/continuation. A separately selected release actor is optional; neither actor can review its own revision. Repository protection and external merge queues remain binding.

As a **builder**:

1. Publish a CHECKPOINT for the exact artifact, with at least one required check whose `artifact_revision` equals it and outcome `passed`, and no holds. `not_run`, `failed`, stale checks, holds, a newer checkpoint for another revision or a BLOCKED report block the grant. Every declared check also needs a passing helper CHECK_RESULT on that head in every mode. Approved exact-revision review is additionally required only with `require_code_review=true`, with a different declared family when `require_other_family=true`.
2. Request landing with LANDING_REQUEST naming that checkpoint, the exact source ref/revision (the checkpoint's `artifact_revision`) and the exact target repository, ref and **expected head revision**. No action/handover fields:

```json
{"kind":"LANDING_REQUEST","payload":{"checkpoint_id":"cp-3","project_id":"project-1","repo_ref":"git@example:project-1.git","target_ref":"refs/heads/main","target_revision":"1a2b3c","source_ref":"refs/heads/work-1","source_revision":"4d5e6f","summary":"Ready to land"}}
```

3. The request becomes a durable `landing_approval` owner gate for that exact request. Consume its `owner_decision` like any other; it is information, not permission. Nothing lands without approval (the owner's, or the owner's in-scope auto-approval policy). A reject (or a cancelled gate) withdraws the request.
4. When your request is queue-head, approved and proven with a fresh current artifact, ORCH+ grants your exact existing session in worker mode, or the optional selected release actor. Never merge/push before the exact landing_grant. A predecessor and successor are not interchangeable, and uncertainty never authorizes a replacement launch or replay.

As the **exact granted merge actor**, consume/claim landing_grant once. It binds landing_id,grant_id,project_id,checkpoint_id,repo_ref,target_ref,target_revision,source_ref,source_revision,builder_work_id,proof and optional review identifiers. In review_disabled those identifiers are absent, not synthetic. Land only the exact source onto the exact target whose head still equals target_revision. Policy changes never rewrite issued grants; retain uncertain work for explicit recovery.

5. Report exactly one LANDING_RESULT correlated to the grant's `action_id`/`action_revision`, echoing `landing_id`, `grant_id`, `project_id`, `repo_ref`, `target_ref`, `target_revision` and `source_revision`, plus `evidence` and optional `pr_ref`/`summary`:
   - `landed` with `result_revision` (the resulting target head; no `reason`);
   - `rejected` with `reason` (for example conflicts or failing checks);
   - `stale_target` with `observed_target_revision` (the moved head, different from `target_revision`) and optional `reason`;
   - `uncertain` with `reason` when you cannot tell whether it landed.

```json
{"kind":"LANDING_RESULT","action_id":"reply-action-7","action_revision":1,"payload":{"landing_id":"landing-5","grant_id":"landing-grant-6","project_id":"project-1","repo_ref":"git@example:project-1.git","target_ref":"refs/heads/main","target_revision":"1a2b3c","source_revision":"4d5e6f","outcome":"landed","result_revision":"7a8b9c","evidence":["ci:run-42"]}}
```

`landed` records the new head, frees the slot and starts the deploy step (see **Release manager**). `rejected` fails the item. `stale_target` frees the slot and keeps the item in place as **needing refresh**; the builder then receives one `landing_refresh` exactly as for `target_moved` below. Never re-run a merge because a reply or result seemed lost.

When another request lands (or the owner records a head) while yours is ungranted and expects the old head, or after `stale_target`, ORCH+ issues one immutable `landing_refresh` to the builder: `{landing_id,project_id,repo_ref,target_ref,expected_revision,current_revision,reason}`. Consume/claim and acknowledge once; it is information, never permission to push. Rebase or rebuild onto `current_revision`, publish a fresh CHECKPOINT with a new ID and fresh helper checks, and publish REVIEW_READY only if current policy requires review. Send a fresh LANDING_REQUEST with `target_revision=current_revision`. This rebinds your existing queue item and needs a new owner approval and fresh grant. Replays never repeat the notice; a later target change after refresh can issue a new one. Refresh cycles are capped. Example complete version-1 reply, with illustrative issued identifiers:

```json
{"version":1,"logical_session_id":"orch-1","worker_id":"worker-2","worker_generation":1,"launch_request_id":"launch-2","work_id":"work-2","message_id":"message-9","reply_seq":2,"action_id":"reply-action-10","action_revision":1,"kind":"landing_refresh","payload":{"landing_id":"landing-6","project_id":"project-1","repo_ref":"git@example:project-1.git","target_ref":"refs/heads/main","expected_revision":"1a2b3c","current_revision":"7a8b9c","reason":"Target moved (landed via landing-5). Rebase or rebuild onto current_revision, publish a fresh CHECKPOINT and a fresh LANDING_REQUEST expecting current_revision; it needs new owner approval. Never push without a landing_grant."}}
```

While the exact merge actor holds a grant it must not send DONE (DONE without a result leaves the slot uncertain) or finish, and its rollover never transfers an issued grant: an uncertain grant stays with the holder generation that claimed it. An `uncertain` result, a lost holder (exit, stop, held or rejected report) or the owner's **Result lost** mark holds the slot until the owner inspects the target read-only and reconciles it as landed (with head) or not landed. A later result for that grant is kept as evidence only. A builder does not send another LANDING_REQUEST for a target while its item is granted. An ungranted request may be reordered or cancelled by the owner.

An ungranted request is held while its builder is part of an unfinished rollover. A rollover successor (same work) re-publishes a fresh CHECKPOINT and LANDING_REQUEST for the same target; that refresh rebinds the existing queue item to the successor at its current position and needs a new owner approval.

## Reviewer

A `reviewer` worker judges one builder's change and never edits it. After ACCEPTED, consume/claim the `review_request` reply once: `{review_id,round,question_id,builder_work_id,task_ref,plan_ref?,plan_revision?,source_ref,artifact_revision,scope_paths,findings_prev}`. `question_id` is `implements_task_v1`. Answer **only** this fixed question, with the request's values substituted:

> Does the change at `<source_ref>@<artifact_revision>` implement `<task_ref>` as specified, without changes outside `<scope_paths>`? Answer approved, or changes_required with findings tied to file and line.

Do not answer a different or broader question, rate style, or hunt for problems to have something to report. Give **no score and no confidence**. Every finding names a repository-relative `path`, a `line` where one applies and a `summary` of at most 400 characters; in round 2, check whether `findings_prev` were fixed. Read the change at that exact revision; never review your own work.

Publish exactly **one** REVIEW_RESULT, correlated to the `review_request`'s `action_id`/`action_revision`:

```json
{"kind":"REVIEW_RESULT","action_id":"reply-action-3","action_revision":1,"payload":{"review_id":"review-1","round":1,"artifact_revision":"revision-1","outcome":"changes_required","findings":[{"finding_id":"f-1","path":"src/parse.luau","line":42,"summary":"Empty input is not rejected as the task specifies."}],"summary":"One requirement is missing."}}
```

`outcome` is `approved` or `changes_required`; `changes_required` needs at least one finding (at most 32). Replay the immutable original after uncertainty instead of sending a second result. After its acceptance and your final ACK/watermark drain, ORCH+ finishes you automatically; do not start other work.

## Release manager

A separately selected release_manager is optional. In worker mode the existing accepted builder performs these same grant-bound merge/deploy steps without an extra launch. Both modes require real release-manager-v1 capability; the reviewer cannot be the actor. Selected-record mode additionally keeps the release actor separate from the builder.

**Merge.** For each `landing_grant`, merge exactly `source_ref@source_revision` into `target_ref` following the repository's own rules: its AGENTS.md/CLAUDE.md, branch protection, required reviews and status checks, and PR requirements. **Never merge a revision other than the granted one**, never rebase or amend it yourself, and never merge on a builder's word or a report alone. If the target head no longer equals `target_revision`, report `stale_target`. If the repository's rules forbid the merge (for example a behind branch that needs a fresh signed review, a failing required check or a missing approval), do not merge: report `rejected` with the reason. Then publish one LANDING_RESULT (step 5 above), citing the PR or merge evidence.

**Deploy.** After `landed`, ORCH+ issues one `deploy_grant` (`{deploy_id,attempt_id,landing_id,revision,target_ref}`). It authorizes exactly one deploy attempt for exactly that revision; consume/claim it once. Deploy only where the repository's rules define a deploy and every precondition they state holds (for example a backup and restore proof before an automatic migration, or a required bootstrap already verified). A deploy is its own narrow step: it does not widen merge rights, skip the review rule or override any recorded operational hold. Anything the rules mark as a hold — for example a change carrying a migration, a service unit or drop-in, or a privilege file such as a sudoers or policy rule — is **held** before it runs: report `held` with the reason and wait for the owner's decision, which arrives as an `owner_decision`. Verify a deploy the way the repository prescribes and cite that evidence. Publish one DEPLOY_RESULT correlated to the grant's `action_id`/`action_revision`:

```json
{"kind":"DEPLOY_RESULT","action_id":"reply-action-12","action_revision":1,"payload":{"deploy_id":"deploy-1","attempt_id":"attempt-1","landing_id":"landing-5","outcome":"deployed","revision":"7a8b9c","evidence":["health:service-ok"]}}
```

`outcome` is `deployed`, `held`, `not_applicable` (the repository defines no deploy for this change) or `failed`; give a `reason` for `held` and `failed`. Every DEPLOY_RESULT correlates to a `deploy_grant` reply's `action_id`/`action_revision` and echoes that grant's `deploy_id`, `attempt_id`, `landing_id` and `revision`; never correlate it to a `deploy_hold` or other `owner_decision`, and never deploy without a current `deploy_grant` or report a revision other than the granted one. Both `held` and `failed` open a `deploy_hold` gate, and the owner's answer is relayed to you as an informational `owner_decision`: consume/claim it once.

- After `held`: if the answer is to deploy, continue the **same** attempt (no new grant) and publish the final DEPLOY_RESULT (`deployed`, `not_applicable`, `failed`, or `held` again) against the **original** `deploy_grant`, echoing the same `attempt_id`. If the answer is to stop, do not deploy; the deploy ends.
- After `failed`: if the owner allows a retry, ORCH+ issues a **new** `deploy_grant` for a new attempt (new `attempt_id` and action, same `deploy_id`, `landing_id`, `revision` and `target_ref`). Deploy again only on that grant and report one DEPLOY_RESULT correlated to it with the new `attempt_id`; the old attempt is closed and anything reported for it is late evidence only. If the answer is to stop, no grant follows and the deploy ends. Attempts are capped.

Send one DEPLOY_RESULT per outcome. Never re-deploy on your own, and never retry because a grant, reply or result seemed lost: a lost result is reconciled read-only by the owner.

An unissued pending deployment may wait through a safe rollover. After the predecessor's exact exit and handover settlement, the accepted same-work successor may receive the deployment for the already-landed revision; this does not transfer or replay the predecessor's merge grant. With no eligible current session, deployment stays held without a new manager launch. The owner's Stop pending deployment ends only a zero-attempt pending deploy and does not undo the completed merge. Issued or uncertain attempts remain bound to their original holder and require exact outcome reconciliation.

## Retained legacy classification

No new classifier-only worker or static task route is created. A pre-cutover classifier may finish only its already-issued LABEL request and drain its existing receipts; it cannot widen work or trigger another classifier. Retained unknown-class decisions are revised to Use preferred worker or Cancel, invalidating older captured answers. Task-type metadata remains informational; preferred worker/orchestrator and explicit scope permissions choose agents.

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

Fresh defaults: poll300,000ms, automatic report request900,000ms, stale1,800,000ms; automatic_reports=false, auto_start_projects=false, auto_rollover=true, paused=false, concurrency4, loop/review rounds5. Glitch integration is Off. Existing explicit choices remain. Pause never abandons intake or settlement. Automatic progress requests require safe observed idle input, not a busy model. Host epoch-bound timing preserves restart uncertainty.

Native permission/authentication gates require the owner to open the exact relevant pane and act there. **I resolved this — recheck** only asks for a new native lifecycle observation. It never logs in, answers a prompt or retries an uncertain operation. Health keeps separate native and reported facts; READY cannot override native waiting-input or exit.
An exact native exit is retained as a separate terminal lifecycle fact even when later observations are unknown or progress reports say READY. Missing/moved panes never establish exit. Restart makes freshness unconfirmed without erasing a previously confirmed exit.

Known durable ACK/reply publication is separate from a native notification that has not begun. ORCH+ retains at most 32 pending notification obligations per generation; idle-only `native_wake` grants use the ordinary one-generation/four-host execution limits. Busy workers can still exchange mailbox reads/receipts while notification waits. A started or uncertain notification keeps its execution slot; it is never repeated because a status record is missing. For native workers, return idle after draining each turn so pending ACKs and decisions can trigger their safe notification.

A fully assembled rejected report is retained with its exact bytes and a visible diagnostic. Its completed read releases the execution slot, but its acceptance cursor and receipt stay unchanged: there is no rejection ACK, silent skip, sequence reset or permission to overwrite the immutable producer event. Receipt-watermark settlement remains available while the owner inspects the hold.

Compatible reload/reconnection is automatic only for the same verified native controller/conversation and exact retained identity, with no outstanding session effects for automatic worker attachment. No old-executors-stopped attestation is fabricated. Original grants, mailboxes, tokens, pause and decisions survive; held/uncertain actions are never replayed or replaced. Actual unresolved effects and terminal continuation without retained executable/argv/process-start proof remain explicit recovery decisions. A route fence alone does not reactivate an uncertain coordinator.

Finished-project history is presentation, not executable authority. Finish project never kills an associated conversation and refuses unresolved managed obligations. Opening a finished row is read-only; Reopen creates a new unstarted project referencing its source, without old workers or approvals. Original immutable requests and uncertain effects remain fenced through schema conversion and recovery; neither START nor a history link can replay an issued effect.

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
