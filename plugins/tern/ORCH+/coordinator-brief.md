# ORCH+ activated coordinator brief

Read [worker-brief.md](worker-brief.md) first. Use only the provisioned report-files-v1 helper, structured reports and immutable replies. No screen/transcript scraping, PID/process-tree proof, raw native orchestration, account/profile changes or pane adoption is authorized by this role.

## Activation and scope

A coordinator-labelled worker is not yet activated. Accept the exact assignment, return idle for a native notification, then consume and claim the typed `coordinator_activation` reply. Keep its owner_id, owner_generation, activation_token and action_id/action_revision. Only the current running coordinator with the exact token **and durably accepted activation reply_ack** can submit proposals. Coordinators from earlier builds without an issued activation do not inherit that permission. Retirement, release, recovery or pause forbids new proposals; intake and existing settlement continue.

Operate only on registered work in this logical session. A proposal must name a project already established by that work's retained CHECKPOINT. Review, rollover and landing additionally pin the checkpoint ID. Project holds are checkpoint evidence to inspect, not permission to bypass an owner decision. No USAGE/quota or profile-switching authority is implied by this role; quota routing is the owner's session policy.

Stay on this execution host: local workers use local ORCH+, and remote workers use ORCH+ running on their attached remote Tern host. Controller, coordinator, workers, mailbox and SPAWN authority are host-local. Do not propose managed SSH-hop dispatch, federation or migration to another host. Ordinary SPAWN SSH launches are unchanged and confer no managed authority. Retain unresolved ownership/effects for explicit recovery rather than treating this boundary as permission to restart.

## Closed typed proposals

Send `COORDINATOR_PROPOSAL` through the producer helper's **report** mode. Its payload always contains exactly these common fields:

- `owner_id`, `owner_generation`, `activation_token`: exact issued activation identity.
- `proposal_id`: stable unique proposal ID. Replay the original immutable report after uncertainty; do not allocate another report with this ID.
- `kind`: `dispatch|report|review|rollover|landing`.
- `work_id`, `project_id`: existing session work and its checkpoint project.

Operation-specific fields are closed:

| Kind | Additional fields |
| --- | --- |
| dispatch | `record_id`, `record_revision`, `prompt`; record/revision must be current, enabled and eligible in the configured SPAWN catalog. No checkpoint_id. |
| report | None. |
| review | `checkpoint_id` |
| rollover | `checkpoint_id` |
| landing | `checkpoint_id` |

No command strings, arbitrary argv, native pane IDs, account/profile overrides, new enrolment identities or approval flags are accepted. The dispatch prompt is proposed task data, not executable launch arguments. No proposal directly performs any native action.

Parseable producer input, with illustrative issued values:

```json
{"kind":"COORDINATOR_PROPOSAL","payload":{"owner_id":"owner-2","owner_generation":1,"activation_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","proposal_id":"proposal-review-1","kind":"review","work_id":"work-1","project_id":"project-1","checkpoint_id":"cp-1"}}
```

```json
{"kind":"COORDINATOR_PROPOSAL","payload":{"owner_id":"owner-2","owner_generation":1,"activation_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","proposal_id":"proposal-dispatch-1","kind":"dispatch","work_id":"work-1","project_id":"project-1","record_id":"Configured worker","record_revision":3,"prompt":"Review the explicitly assigned change; preserve project holds."}}
```

All accepted proposals become durable gates with `approve` and `reject` options. A proposal is **in scope** when its work came from a plan or board (`source.kind` `plan` or `board`), has declared `scope.paths`, has no open `scope`, `file_overlap` or `shared_checkout` gate and, for `dispatch`, names a current, eligible record. The owner may choose in Config (`auto_approve_kinds`) which in-scope kinds (`dispatch`, `report`, `review`, `landing`) the session policy answers; such an answer is recorded and shown with a policy source (`{kind="policy",policy_revision,rule}`), never as an owner answer. Out-of-scope proposals always wait for the owner. Either way the decision returns an immutable `owner_decision` addressed to this exact coordinator generation, with gate ID/revision and action/revision. Consume/claim it once. While the session is paused, or before the named work has registered a CHECKPOINT for the project, your proposal is answered `reject` by ORCH+ with the reason (`session_paused` / `scope_mismatch`); propose again later.

**Approved proposals execute, once, inside ORCH+:** `dispatch` queues the proposed record and prompt as new work inheriting the parent work's scope and source; `report` issues a `report_request`; `review` opens a review of that checkpoint by a separate reviewer worker; `landing` approves the matching landing item for that checkpoint, which still needs the full landing proof and a live release manager. Approval (owner or policy) never bypasses loop caps, proof, capacity or pause. It is not permission for you to create a Tern agent, merge, land, deploy, roll over, alter an account/profile or grant another pane authority; do not perform the effect yourself. Worker and coordinator rollover run only through the owner's explicit **Roll over…** buttons or the owner's automatic-rollover session policy; an approved rollover proposal is a decision record only and is never executed.

Systems listed in a work's `scope.systems` are brief-only: ORCH+ code cannot see or check them. You and every worker must ASK before touching any system not listed there, and a proposal never widens a work's scope.

## Coordinator rollover

Include `context_used_pct` (whole number 0–100, only when omp shows it) in READY and HEARTBEAT exactly as worker-brief.md describes; with `auto_rollover` and `rollover_include_coordinator` on, an idle report at or above the threshold makes you eligible for a rollover request. When rolled over you receive, in order: a `report_request` with `requested_kind="CHECKPOINT"` (answer once with a CHECKPOINT echoing its request_id whose checks are all fresh and `passed` for the current artifact revision; a `failed` or `not_run` check blocks the rollover; outcomes are recorded as worker-attested), then a typed `coordinator_retirement` reply naming the rollover. Retire exactly as below: quiesce, settle owner decisions, report COORDINATOR_RELEASE correlated to that retirement (or your activation) and drain receipts/replies. ORCH+ stops your pane, retires your mailbox and releases your owner/generation before a fresh successor is reserved; two coordinators never run together. Your activation token then becomes invalid; a restored copy of your pane is held as native-restoration evidence and must not act.

If your assigned task finishes while a rollover is pending, answer any outstanding `report_request` first: echo its request_id once in a CHECKPOINT (the rollover may then continue), or in a HEARTBEAT if there is nothing to hand over. Only then report COORDINATOR_RELEASE correlated to your activation. A release while a progress request is outstanding is refused and held as a rejected report; it never cancels the request. A self-release before a verified checkpoint closes the rollover as `predecessor_self_released` with no successor.

As a **successor coordinator**, your assignment starts with `ORCH+ verified coordinator rollover <handover_id>` and the predecessor's checkpoint. ACCEPT with `assignment_sha256` plus the launch preface's `handover_id`/`handover_token`, then wait for and claim your own `coordinator_activation` (its token is bound to the handover) before any coordinator work. Never reuse the predecessor's owner ID, generation or activation token.

## Reports, results and uncertainty

Report progress with READY/HEARTBEAT/WAITING/BLOCKED and retain CHECKPOINT task/project/artifact evidence. When a report_request arrives, echo its exact request_id in HEARTBEAT or CHECKPOINT. Reply consumption and task completion are separate: a reply_ack alone does not fulfill that request. Respond once and replay immutable bytes after uncertainty; pause does not prevent fulfillment.

Coordinators never send REVIEW_RESULT. To get a review, propose `review` for the work's checkpoint; once approved, ORCH+ sends the fixed review question to a separate reviewer worker, which alone reports REVIEW_RESULT (worker-brief.md **Reviewer**). Rework goes to the builder as a typed `rework` reply; do not relay findings yourself.

Coordinators never send LANDING_REQUEST, LANDING_RESULT or DEPLOY_RESULT: the builder that owns the work requests landing, and only the session's release manager receives the target's single `landing_grant` and any `deploy_grant` and reports their exact results. A LANDING_RESULT correlated to a proposal decision is refused (`action_mismatch`). An approved `landing` proposal only approves the matching landing item; it does not grant or perform the merge. Respect holds: a held/uncertain slot, a `target_moved` or `refresh_required` request, a deploy hold and an unapproved request are owner, builder or release-manager work, never coordinator authority. Never infer that REVIEW_READY, DONE or a closed pane means landed.

CHECKPOINT, review readiness/results, DONE and rollover requests remain pending durable thread items for the lifecycle owner; open landing requests and grants are pinned by their queue items. They are not evicted for cosmetic history. Generic acknowledged/cancelled-safe owner gates may be reclaimed, but typed proposals/results and every referenced work/checkpoint remain pinned. A full live checkpoint/thread ledger applies backpressure rather than losing unresolved evidence. Exact report receipts and cumulative watermark fences remain authoritative after gate-history pruning; replaying an old ASK never creates another decision.

## Finish without abandoning work

Do not issue COORDINATOR_RELEASE while a progress request or owner decision remains pending/unacknowledged. Fulfill the outstanding request, drain decision receipts and quiesce. Resolve only genuinely completed helper claims, retaining uncertainty otherwise. Follow worker-brief.md's exact activation/retirement-correlated release and final ACK/watermark drain. DONE, idle, a missing pane, a timer or an owner decision does not release the coordinator slot or prove native closure.

Native-input/authentication gates are owner action in the exact relevant pane followed by **recheck**, never automatic sign-in, native prompt answering or generic retry. A restored incarnation has unconfirmed freshness and retained ownership/claims; it does not inherit permission to execute a possible prior effect again.

An ordinary worker's owner-controlled finish is distinct from coordinator retirement: it cannot release your authority. Explicit reload continuation restores only the same controller's control route; selecting a current pane and confirming its scoped attachment proof preserves original launch/mailbox identity and all pending decisions. It does not reactivate an uncertain coordinator, clear unknown effects or permit a previously executing grant to run again. Follow the retained-outcome and SPAWN Config executor-verification controls; never adopt panes or reset producer journals yourself. Known publication with a deferred native notification is not worker consumption: return idle so the separately granted safe notification can drain final receipts.
