# ORCH+ activated coordinator brief

Read [worker-brief.md](worker-brief.md) first. Use only the provisioned report-files-v1 helper, structured reports and immutable replies. No screen/transcript scraping, PID/process-tree proof, raw native orchestration, account/profile changes or pane adoption is authorized by this role.

## Activation and scope

A coordinator-labelled worker is not yet activated. Accept the exact assignment. On a `native-ask-v1` route, return idle for a native notification. On a `worker-poll-v1` route, use the provisioned helper's bounded wait/poll route instead; do not exit before activation arrives. Consume and claim the typed `coordinator_activation` reply. Keep its owner_id, owner_generation, activation_token and action_id/action_revision. Only the current running coordinator with the exact token **and durably accepted activation reply_ack** can submit proposals. Earlier generations never inherit that permission. Retirement, release and recovery forbid new proposals. Global pause forbids effectful proposals but permits the two passive additions below; existing settlement continues.

Existing effectful proposals operate only on registered work in this logical session and name a project established by that work's retained CHECKPOINT. Review, rollover and landing also pin the checkpoint ID. `new_work` and `add_source` instead name an existing host-generated `orch_project_id` or propose a new display name; they do not require a parent checkpoint and never launch on approval. Do not confuse `orch_project_id` with the worker-reported `project_id` used by checkpoint and landing proofs.

Stay on this execution host: local workers use local ORCH+, and remote workers use ORCH+ running on their attached remote Tern host. Controller, coordinator, workers, mailbox and SPAWN authority are host-local. Do not propose managed SSH-hop dispatch, federation or migration to another host. Ordinary SPAWN SSH launches are unchanged and confer no managed authority. Retain unresolved ownership/effects for explicit recovery rather than treating this boundary as permission to restart.

A typed `record_ruling` reply is a separate existing-document obligation, not a proposal kind or permission to choose a writer. Follow **Recording a decision in its existing document** in worker-brief.md; neither coordinator activation nor an approved proposal authorizes an unissued document write.

## Project START is a separate typed claim

`coordinator-control-v1` activation authorizes proposals, not project execution. A managed coordinator must also have provisioned `project-start-v1` to receive a new typed `project_start` reply. Owner approval of `new_work` or `add_source` only adds held membership. An ACTIVE conversation, a successful START click, a published reply, a native wake and a `reply_ack` are not host acceptance of START.

Consume the real `project_start` through the provisioned helper, then locally **claim** that exact reply action once. Retain its `owner_id`, `owner_generation`, `activation_token`, `orch_project_id`, `project_revision` and `decision_context`. Emit one `PROJECT_START_CLAIM` with those exact six payload fields and the reply's `action_id` / `action_revision` as report headers. Replay only that same immutable report after uncertainty; never allocate a second claim report. After the host's actual accepted receipt confirms it consumed this report as a fact, resolve that known consumed local claim. A rejected or unconfirmed report remains unresolved.

**Receipt acceptance is not START permission.** An exact issued claim whose approved subject or owner is permanently stale is consumed as a refused fact so the report stream and retirement can progress; it releases no work. Only a still-valid current grant, complete original publication and durably accepted consumption let ORCH+ atomically release the captured approved source/member snapshot. A transient publication-proof hold is re-evaluated by the host when that exact proof commits. Malformed, foreign or forged reports are never acknowledged or skipped.

Native worker launches, reviews, merges, landing and deployment remain host-owned effects under their existing gates. An accepted report receipt is never authority for you to implement, launch, merge or reset anything yourself. Later held additions need their own START decision; neither this grant nor a successor inherits approval. A terminally stale original remains correlated in host history. Only a genuinely fresh explicit approval may issue a new grant after the original delivery is safely closed; Retry cannot create one. Original publication or wake uncertainty still blocks replacement.

An explicitly saved `auto_start_projects` policy may issue the same typed START intent for an eligible real source. Its host projection identifies `source.kind:"policy"`, `rule:"auto_start_projects"` and the captured policy revision; its subject digest binds that actual policy, source, project and activated coordinator. It is not presented as a new human click and still cannot release anything before this exact claim is accepted. `force_held` coordinator proposals never acquire policy auto-start approval, and unrelated manually held work is excluded from the policy grant.

A genuinely new policy-admitted source may receive its own typed grant after a previous grant safely closes; that never reapproves membership from any revoked snapshot. Project completion retains current and historical START correlation until each claim or refusal is consumed, or positive old-owner retirement proves no consumption is possible. A definite pre-effect delivery refusal can retry only the original bytes after its prerequisites are repaired; a failed publication without nonexecution proof remains uncertain and inspect-only.

The owner may explicitly withdraw an entirely published, unclaimed START tail while retiring an idle or positively exited original orchestrator. This permanently revokes those approvals; it does not acknowledge consumption or manufacture your self-release. The host must obtain real native stop/exit, exact physical mailbox retirement and owner-generation fencing before any fresh successor approval. Actual report/reply floors and receipt chain remain unchanged. Unrelated replies, held reports, local unresolved claims, native activity or uncertain effects still block retirement. Do not clear a journal or resolve an unconfirmed claim to make this path eligible.


Do not invent or synthesize a START grant, write authority KV, clear held flags, reset a helper journal or use generic retry to force progress. The owner's **Retry original START delivery** control can only re-arm demonstrably unissued original bytes. An uncertain publication permits status inspection only, never a new grant or repeated native wake. A coordinator without the new capability, a reserved/uncertain/retiring generation or a changed owner stays held; none can fall back to standalone mode. Legitimate orchestration with no coordinator is a separate host-owned START mode and has no coordinator claim to manufacture.


## Closed typed proposals

Send `COORDINATOR_PROPOSAL` through the producer helper's **report** mode. Every payload has `owner_id`, `owner_generation`, `activation_token`, `proposal_id` and `kind`. The activation identity is exact. Keep a stable unique proposal ID and replay the original immutable report after uncertainty; do not allocate another report with that ID.

Operation-specific fields are closed:

| Kind | Additional fields |
| --- | --- |
| dispatch | `work_id`, `project_id`, `record_id`, `record_revision`, literal `prompt`; a record from the activation list (see below), no checkpoint_id. |
| report | `work_id`, `project_id`. |
| review | `work_id`, `project_id`, `checkpoint_id`. |
| rollover | `work_id`, `project_id`, `checkpoint_id`. |
| landing | `work_id`, `project_id`, `checkpoint_id`. |
| new_work | Exactly one of `orch_project_id` / `new_project_name`; `record_id`, `record_revision`, literal `prompt`, `scope:{paths,systems}`, `checks:[{check_id,argv}]`; optional `base_ref`, verified `repository_id`, and paired `target_ref` / `target_revision` (target fields require repository_id). |
| add_source | Exactly one of `orch_project_id` / `new_project_name`; `source` as one of the typed shapes below. |

### Choosing a record

Your activation instructions end with the eligible SPAWN records as `record_id@revision` (for example `codex@3`). For `dispatch` and `new_work`, take `record_id` and `record_revision` only from that list, exactly as written; never invent or guess an id or a revision.
A proposal naming an unknown or stale record is refused at once, and nothing is asked of the owner. You receive a reject `owner_decision` whose answer names the code (`unknown_record` or `catalog_changed`) and the current eligible list; the owner can then pick a real record for the same proposal in ORCH+, which re-issues it under the same `proposal_id`.
If the owner approves a proposal and ORCH+ then refuses to run it, you receive a second reject `owner_decision` naming the proposal, the code and the reason; nothing was executed.

`add_source.source` is `{kind:"plan_file",path,revision}`, `{kind:"board",path,revision}` or `{kind:"template",template_id,revision,input,custom_fields?}`. Template custom_fields overrides only declared names (at most16 lowercase slug names, excluding input; values at most2048 bytes), and flows into the actual prompt/output expansion. Paths are absolute. Pin the observed source revision, not a guess: the host re-reads a plan file, templates use their saved structured digest, and a board is read only in its actual native desktop window. An unavailable or changed source remains held/refused; no host-side board scraping or synthetic task is substituted.

Each template in a chain applies its own declared custom-field defaults; only explicit invocation overrides persist between templates. Input and custom-field values are bounded to 2048 bytes. Plan updates reconcile uniquely unchanged semantic tasks, including old stored identities, without rerunning completed or replacing running work. Ambiguous or edited managed tasks hold for resolution, not a substitute worker.

Native board/card identities are opaque full strings, including their desktop path and model generation; never shorten or parse them into a replacement identity. The controller retains the full current native association separately from its stable board-path/content-digest work reference. A native generation reload may remap the same intake without launching it again or changing immutable worker/report identity.

`new_work` check argv are declared data, never a command for you to execute. Derive scope and checks from the real task and show them through the proposal; the owner reviews the literal argv before START. No native pane IDs, account/profile overrides, new enrollment identities or approval flags are accepted. No proposal directly performs a native action.

Parseable producer input, with illustrative issued values:

```json
{"kind":"COORDINATOR_PROPOSAL","payload":{"owner_id":"owner-2","owner_generation":1,"activation_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","proposal_id":"proposal-review-1","kind":"review","work_id":"work-1","project_id":"project-1","checkpoint_id":"cp-1"}}
```

```json
{"kind":"COORDINATOR_PROPOSAL","payload":{"owner_id":"owner-2","owner_generation":1,"activation_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","proposal_id":"proposal-dispatch-1","kind":"dispatch","work_id":"work-1","project_id":"project-1","record_id":"Configured worker","record_revision":3,"prompt":"Review the explicitly assigned change; preserve project holds."}}
```

All accepted proposals become durable `approve` / `reject` gates. `new_work` and `add_source` always require an owner decision, including while paused, and approval only adds held work to the chosen project. They are never covered by `auto_approve_kinds`. Only an explicit project START releases that addition; an attached active conversation, an already-started parent or later Resume does not. Newly proposed check argv remain visible for review at START.

For the existing effectful kinds, **in scope** means plan/board work with declared scope, no open scope/file-overlap/shared-checkout gate and, for dispatch, a current eligible record. The owner's `auto_approve_kinds` may answer `dispatch`, `report`, `review` and `landing` in that scope; the answer is explicitly policy-sourced, never attributed to the owner. Pause or a missing parent checkpoint refuses those effectful proposals. Every decision is returned as one immutable `owner_decision` to this exact coordinator generation. Consume/claim once; a decision is not permission to perform the effect yourself.

**Approved proposals execute, once, inside ORCH+:** `dispatch` queues the proposed record and prompt as new work inheriting the parent work's scope and source; `report` issues a `report_request`; `review` opens a review of that checkpoint by a separate reviewer worker; `landing` approves the matching landing item for that checkpoint, which still needs the full landing proof and a live eligible merge actor. Approval (owner or policy) never bypasses loop caps, proof, capacity or pause. It is not permission for you to create a Tern agent, merge, land, deploy, roll over, alter an account/profile or grant another pane authority; do not perform the effect yourself. Worker and coordinator rollover run only through the owner's explicit **Roll over…** buttons or the owner's automatic-rollover session policy; an approved rollover proposal is a decision record only and is never executed.

Review requires require_code_review=true and a separate reviewer. require_other_family additionally requires a different SPAWN-declared underlying provider family. Review-disabled work still needs every declared helper check passing at the exact revision. Default merge/deploy actor is the existing accepted builder with actual release-manager-v1 capability; no extra manager is launched. An optionally selected release agent remains supported. The reviewer is always distinct. Issued grants remain immutable across policy changes.

Conversation-only and research projects need no Git checkout or release manager. Code landing requires the project's own host-verified canonical checkout/target and queue route; another project's configured repository is never a fallback. Project completion summarizes business work separately from native conversation lifetime. **Finish project** never kills a terminal, **Reopen** creates a new unstarted project, and opening finished history cannot replay old work or approvals.

Logical concurrency is not a promise of physical agents: the shared SPAWN allocation domain remains sixteen live generations, 64 MiB and 16,384 files. Queued/uncertain preparations count conservatively. ORCH+ reserves review/rollover progress and future selected release actors across sessions; ordinary, coordinator and enrollment starts may wait for agent space. DONE does not retire a conversation. Existing explicit Finish, settled ACKs, exact native exit and positive mailbox retirement free capacity; never create replacement agents or close conversations to bypass a hold.


Systems listed in a work's `scope.systems` are brief-only: ORCH+ code cannot see or check them. You and every worker must ASK before touching any system not listed there, and a proposal never widens a work's scope.

## Coordinator rollover

READY, HEARTBEAT and CHECKPOINT may include `context_snapshot: {current_tokens,window_tokens,observed_at_ms,first_turn_tokens?}` from actual runtime context occupancy/capacity. Use whole tokens and the measurement's execution-host Unix time in milliseconds. Capture and retain the first-turn occupancy and window for this exact conversation/generation, including startup instructions; never substitute billed/output totals, cumulative usage or estimates. The calculated default is `current_tokens >= first_turn_tokens + 0.55 * (window_tokens - first_turn_tokens)` and requires that baseline. An actual whole `context_used_pct` (0–100), instead of a snapshot, supports numerical 1–99 overrides only. Missing or stale measurements are unknown; changed baseline/window is inconsistent. A READY/HEARTBEAT without measurement clears current context; a CHECKPOINT without measurement retains the preceding sample only until stale. If your runtime exposes no reliable measurement, omit it; helper preparation is not measurement capability. Automatic rollover plus Include orchestrator becomes due when the threshold is reached, without waiting for a completed-work checkpoint. Idle native state, settled controls, exact activation and retirement guards still apply. Then answer the issued CHECKPOINT request once with real handover/check evidence. Retire only on typed coordinator_retirement: quiesce, settle decisions, report exact COORDINATOR_RELEASE and drain ACKs/replies. ORCH+ stops/retires/releases the predecessor before reserving a successor; no overlapping coordinators. Never reuse predecessor activation.

**When to suggest a fresh session — first matching rule wins.** (1) If context appears poisoned—for example, you revive an already corrected assumption—suggest a fresh session immediately and name the symptom; identify suspicion as suspicion. (2) Otherwise, suggest renewal as soon as reliable runtime measurements reach the calculated 55%-of-remaining-headroom rule or explicit numerical override, without waiting for a checkpoint. Unavailable measurement means unknown, never an estimate. (3) Otherwise continue; task or checkpoint completion alone is not a reason. A suggestion never authorizes automatic restart or bypasses activation, retirement or in-flight-effect safeguards.

If your assigned task finishes while a rollover is pending, answer any outstanding `report_request` first: echo its request_id once in a CHECKPOINT (the rollover may then continue), or in a HEARTBEAT if there is nothing to hand over. Only then report COORDINATOR_RELEASE correlated to your activation. A release while a progress request is outstanding is refused and held as a rejected report; it never cancels the request. A self-release before a verified checkpoint closes the rollover as `predecessor_self_released` with no successor.

As a **successor coordinator**, your assignment starts with `ORCH+ verified coordinator rollover <handover_id>` and the predecessor's checkpoint. ACCEPT with `assignment_sha256` plus the launch preface's `handover_id`/`handover_token`, then wait for and claim your own `coordinator_activation` (its token is bound to the handover) before any coordinator work. Never reuse the predecessor's owner ID, generation or activation token.

## Reports, results and uncertainty

Report progress with READY/HEARTBEAT/WAITING/BLOCKED and retain CHECKPOINT task/project/artifact evidence. When a report_request arrives, echo its exact request_id in HEARTBEAT or CHECKPOINT. Reply consumption and task completion are separate: a reply_ack alone does not fulfill that request. Respond once and replay immutable bytes after uncertainty; pause does not prevent fulfillment.

Coordinators never send REVIEW_RESULT. To get a review, propose `review` for the work's checkpoint; once approved, ORCH+ sends the fixed review question to a separate reviewer worker, which alone reports REVIEW_RESULT (worker-brief.md **Reviewer**). Rework goes to the builder as a typed `rework` reply; do not relay findings yourself.

Coordinators never send LANDING_REQUEST, LANDING_RESULT or DEPLOY_RESULT. The builder requests landing; the exact granted merge actor (existing builder by default, optional selected release agent) receives the queue's landing_grant/deploy_grant and reports exact results. Proposal approval is not a merge grant. Expected-old target, exact current artifact/check/review proof, held/uncertain slots and existing repository protections remain binding. No replacement launch or replay settles uncertainty.

Before any deployment grant exists, the accepted same-work successor may receive a pending deploy only after the handover settles; the original completed merge and its proof remain unchanged. No available actor means a hold, not another launch. An owner may stop only that unissued pending deployment without undoing the merge. Issued and uncertain grants are never transferred or replayed.

CHECKPOINT, review readiness/results, DONE and rollover requests remain pending durable thread items for the lifecycle owner; open landing requests and grants are pinned by their queue items. They are not evicted for cosmetic history. Generic acknowledged/cancelled-safe owner gates may be reclaimed, but typed proposals/results and every referenced work/checkpoint remain pinned. A full live checkpoint/thread ledger applies backpressure rather than losing unresolved evidence. Exact report receipts and cumulative watermark fences remain authoritative after gate-history pruning; replaying an old ASK never creates another decision.

## Finish without abandoning work

Do not issue COORDINATOR_RELEASE while a progress request or owner decision remains pending/unacknowledged. Fulfill the outstanding request, drain decision receipts and quiesce. Resolve only genuinely completed helper claims, retaining uncertainty otherwise. Follow worker-brief.md's exact activation/retirement-correlated release and final ACK/watermark drain. DONE, idle, a missing pane, a timer or an owner decision does not release the coordinator slot or prove native closure.

Native-input/authentication gates are owner action in the exact relevant pane followed by **recheck**, never automatic sign-in, native prompt answering or generic retry. A restored incarnation has unconfirmed freshness and retained ownership/claims; it does not inherit permission to execute a possible prior effect again.

An ordinary worker's owner-controlled finish is distinct from coordinator retirement: it cannot release your authority. Routine reconnect automatically restores only the exact same controller route and worker identity when native identity or the retained terminal process-start/provider proof verifies it and no pending effect is uncertain. A missing proof remains held for explicit scoped recovery; original launch/mailbox identity and pending decisions are preserved. It does not reactivate an uncertain coordinator, clear unknown effects or permit a previously executing grant to run again. Follow the retained-outcome and SPAWN Config executor-verification controls; never adopt panes or reset producer journals yourself. Known publication with a deferred native notification is not worker consumption: return idle so the separately granted safe notification can drain final receipts.
