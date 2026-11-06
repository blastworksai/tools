# SPAWN managed dispatch bridge reference

Full specification of the `spawn.dispatch` bridge that [ORCH+](../ORCH+/README.md) uses: managed launch, authority compatibility and retention, managed configuration, mailbox producer prerequisites, the public bridge protocol, owner-gated import and recovery, bounds and durability, and verification entrypoints. For ordinary SPAWN use see [README.md](README.md).

## Scope

SPAWN keeps one canonical host-owned configuration and ordinary launch ledger. The window half resolves that host configuration rather than choosing a client-local roster. Normal Config, Guided setup, Spawn all, duplicate policy and retained launch observations remain available.

This package also implements the non-palette `spawn.dispatch` bridge for ORCH+. Source and fixtures are not runtime certification: each configured host/OS/account/CLI still needs the checks below before its managed capability is enabled. No account inventory, credential collection, quota collector or model-policy enforcement is included; USAGE owns evidence collection and ORCH+ owns policy.

## Ordinary launch and managed execution

Use the SPAWN status/menu entry, command palette, or Files-pane SPAWN button beside WORK. Guided setup, Config, Spawn all, Spawn specific, Running agents and Review setup result share the canonical host roster. Linking or reloading the package never launches it. Guided setup requires a reviewed Native OMP executable; an empty roster uses Config's manual record or reviewed JSON import route. Imports do not launch accounts.

Ordinary launches, including Native OMP and setup, use released host-executor tickets. The window allocates only `exit 125 # SPAWN:<token>`; the host spawn hook consumes that ticket once, captures the actual pane shell/native identity and preserves Tern shell integration. Deferred host work claims the pane, rechecks membership and approved config revision, persists submission intent, then types the approved invocation once. Unknown submission effects never retry. Command completion, retained parent shells, provider icons, sequential, paced Spawn all, setup prompts and ordinary resume arguments retain their released behavior.

Managed `spawn.dispatch` launch is the deliberate exception: the host constructs an immutable **fresh** command projection, and the exact granted window invokes native `agents:start` or terminal layout APIs. Native wake separately claims `agents:ask`; native stop/terminal close require their own exact grants and observations. The ordinary spawn hook does not intercept ticketless managed panes. Native agent recognition, idle checks and window alias fences remain prerequisites; a terminal wrapper is not a substitute for native OMP.

`launch_resolution.luau` shares canonical record validation, ordinary/fresh argv selection, configured OS-user checking and SSH identity resolution. Rendering is executor-specific: ordinary rendering uses the captured host pane program and retained-shell semantics; managed rendering uses the host authority's `SHELL`/`ComSpec` observation and explicit target declarations. Managed shell evidence is not proof of an actual pane shell. Ordinary OMP startup prompts and managed terminal task-argument insertion intentionally differ. Existing `sudo` must select exactly the configured user; missing, conflicting or ambiguous selectors and malformed/conflicting SSH destinations are rejected for review, never silently rerouted.

## Authority compatibility and retention

Durable authority remains **version 3**, with `namespace`, `host_key`, `config_revision` and `config.hosts[host_key].agents`. Ordinary request/snapshot envelopes are version 2 (`SPAWN_STATE_V2`). Every ordinary attempt has exactly one ticketed job; every managed attempt has `purpose:"managed"` and **no** ordinary execution job. Managed observer, attempt, original launch and mailbox identities remain immutable.

Reply capacity still rotates `authority_id` and rejects old ordinary requests. A separately retained `managed_authority_id` is the initial scope identity; native effect callbacks bind the exact namespace/session, host and native session, not a reply-transport epoch. Rotation neither replays effects nor adopts a new controller/window. Explicit reset retains both guards: resolve active/unresolved attempts and reconcile managed owners, consumed authorizations, live mailbox generations and unresolved import gates.

An old detached version-1 authority migrates only when every attempt has exactly one immutable `dispatch-v1` launch reference matching scope, authority, native session, host, record, exact request-derived observer and attempt (or the exact interrupted reservation intent), with matching recorded pane evidence. The original is preserved as `managed-v1-original` before conversion. No record name or observer prefix is enough to classify an old ordinary attempt as managed. A never-created bridge registry is valid for an empty clean authority, but never evidence for a saved attempt; unreadable/corrupt storage and a missing previously initialized registry still refuse unchanged. Nonempty old request/reply transport and unmatched attempts require original-version review.

Old ordinary setup import receipts are shape-validated and preserved in the original backup, then discarded from the live ledger without replaying their settings. Managed `bridge-` receipts instead require an exact consumed gate, matching records and the stable session-key/host-key/native-session tuple; an intervening reply-transport rotation does not invalidate that receipt. Unmatched managed receipts refuse unchanged.

**Rollback is a state restore, not a package downgrade.** The released 0.1.0 writer cannot read the added managed scope fields or attempt purposes even though the authority envelope remains version 3. Before upgrading, preserve the matching package version and a consistent copy of all SPAWN plugin state (including `authority`, `dispatch-v1`, its initialization marker, gates/fences and mailbox journals). `managed-v1-original` preserves only the pre-conversion authority, not a complete rollback snapshot. Stop/quiesce all affected executors and reconcile every post-backup effect before restoring the matching complete state and old package; restoring an old ledger while newer effects remain can replay work. Never delete managed fields or reset a registry to make an older package load.

**Before downgrading SPAWN from 0.3.1,** settle every pending window request and acknowledge (or **Mark result reviewed**) every retained reply. An older host validates every retained request against its own closed operation list, so a retained `resolve_lost_attempts` request makes the whole authority unreadable to it; an older window likewise rejects a journalled pending `resolve_lost_attempts` request.

Managed imports atomically retain bounded exact request/payload receipts with configuration. Replaying a committed import returns its receipt before revision checks and never overwrites subsequent owner edits; changed payload reuse conflicts. Ordinary imports retain released identical-record idempotence.

Automatic trimming keeps the newest 26 reclaimable finished attempts across ordinary and settled managed work. A managed attempt is reclaimable only when it is `Exited`, not unresolved, and no interrupted `retirement_result`, unsettled linked request/wake or unretired mailbox generation still needs its ledger. Unknown, failed or active managed evidence remains protected; operator resolution alone is not successful retirement. Explicit history clearing uses the same eligibility. Unreadable bridge evidence prevents managed reclamation, and missing/corrupt storage blocks explicit history clearing and session forgetting.

Wholly settled absent session scopes may be forgotten once active owners and unsettled references are gone. Retained successful receipts or tombstones alone do not pin the scope; bridge request/identity fences are never erased by authority cleanup. Exact interrupted retirement reconciliation remains available while its pending settlement evidence exists. After successful settlement and eventual reclamation, callers read the retained bridge result rather than re-settling a removed authority attempt. History cleanup never removes native sessions or panes.

Catalog payloads add `namespace`, `host_key` and `config_revision` while retaining `revision == config_revision` and each record's `id`/`revision`. The exact USAGE join is `(namespace, host_key, config_revision, record.id)` from one complete catalog revision. USAGE's definition SHA256 is independent definition evidence, not the numeric configuration revision. Configured model/profile/capacity labels do not establish a verified account or model binding.


## Managed configuration

To update an existing record, open **Config → Configured agents → Full record JSON** on that record. Activation loads only the focused record's current JSON; paste/edit one complete record object, not the schema/agents import wrapper, and keep its stable `id`. Saving changed JSON validates the normal schema, replaces only that record through the existing revision-fenced authority, and sets **Needs settings review**. Inspect the complete settings, then use **Approve reviewed command and settings** before launching. This is the operator route for mailbox verification/evidence, fresh argv and model/profile metadata; setting `review_required:false` in JSON cannot bypass approval. Stale edits refuse rather than overwrite another record's changes. Ordinary Paste JSON import remains add-only and still refuses a conflicting existing ID.

Existing records retain their normal `command`, `arguments`, `cwd`, `prompt`, backend, placement, enabled/include-all and duplicate policy fields. Managed launch additionally requires one of:

- Native OMP: `fresh_native_default: true`, explicitly selecting a new default OMP context without inheriting resume arguments. Model/profile metadata cannot silently override this default.
- Structured CLI: `fresh_executable` and `fresh_arguments`, plus `task_argument_index` for terminal backends. This is the one-based insertion slot for **one literal task argument**, including any quotes/newlines/Unicode. The configured CLI must document this as fresh input. No command stripping, predecessor command reuse or task text appended as shell code occurs.

Managed Windows targets additionally require `argv_contract: "windows-crt"` and an explicit native `.exe`. Batch/script targets, extensionless PATHEXT resolution, and direct `cmd.exe`/PowerShell command-code input are not managed argv-v1 routes. Ordinary existing Windows batch/script behavior remains separate.

`cwd` and `placement` are explicit managed allowances: requests must match the selected record. Native placements are `tab`, `split`, `replace_if_alone`; managed terminals support `tab` and `split`, not a silently substituted replacement. `target_os` and `target_shell` are mandatory for managed SSH. `host_shell`, when configured, must agree with the host authority's shell observation; this is distinct from the actual pane-program observation used for ordinary tickets. The client machine's OS never chooses the target serializer.

Optional `model`, `profile`, `variant_id`, `selector_evidence`, `capacity_binding`, and positive `capacity_limit` remain configured metadata for subsequent policy work. They are not verified effective identity or available quota.

A mailbox record contains:

```json
{
  "permitted_root": "/absolute/reviewed/mailbox-root",
  "helper_path": "/absolute/reviewed/mailbox_target.sh",
  "producer_helper_path": "/absolute/reviewed/mailbox_worker.sh",
  "worker_identity": "expected-os-account",
  "producer": {"read": true, "write": true, "hash": true, "journal": true, "poll": true},
  "capabilities": ["report-files-v1", "worker-poll-v1", "argv-v1"],
  "wake": "worker-poll-v1",
  "verified": true,
  "evidence_ref": "owner-reviewed-existing-tool-and-actual-cli-evidence"
}
```

This illustrates the **mailbox object**, not a ready-to-use account. `verified` is an explicit operator-attestation gate, never a probe result fabricated by the normalizer. Only set it after establishing the configured producer/target/CLI evidence. Native-recognized OMP may instead use `native-ask-v1`; it must really be recognized by the attached window's native agent API. A terminal with argv input alone is not eligible for managed duplex work.

The complete capability set is validated once by the shared backend/mailbox contract, persisted and digest-bound at provisioning, and returned unchanged. Terminals require `report-files-v1`, `worker-poll-v1`, and `argv-v1`; native agents omit `argv-v1` and declare exactly their configured wake route. Missing producer/capability metadata or mismatched backend/wake declarations make the catalog row ineligible rather than throwing.

Existing host Config imports accept the extended record schema. Private wrappers, credentials and rosters are deliberately not part of this package. Unix user routing is explicit; unsupported Windows user selection rejects rather than emitting `sudo` or using the current user. Ordinary matching prewrapped sudo selectors are checked, not doubled. SSH retains normal host-key verification and configured user/key references; no automatic trust or authentication changes occur.

## Existing-tool target and producer prerequisites

No daemon, new language runtime, or automatic installation is provided. Review and deliberately place the applicable short-lived helper assets on the **execution target**, with owner-controlled regular files and non-symlink/non-reparse ancestors. Config points to their exact absolute paths:

| Target | Host transport helper | Producer/consumer helper | Existing tools required |
| --- | --- | --- | --- |
| POSIX local or SSH | `mailbox_target.sh` | `mailbox_worker.sh`, with sibling `mailbox_json.awk` and `mailbox_reply.jq` | POSIX shell/core tools; `base64`; `sha256sum` or `shasum`; producer additionally `jq`, `awk`, `iconv` |
| Windows local or SSH | `mailbox_target.ps1` | `mailbox_worker.ps1` | Existing Windows PowerShell/.NET |

Both the actual transport identity and worker identity must have the required access. Provisioning probes the resolved target, validates the expected worker account, creates a unique handle directory and proves immutable write/readback before returning a provisioned handle. A helper missing on the target is a prerequisite failure, not permission to install a runtime or run a client-side substitute.

SPAWN's private adapter passes nine literal data arguments to the target helper: `root, handle, mode, selector-or-"-", operation_id, worker_identity, report_floor, reply_floor, producer_helper`. Writes additionally send one Base64 object line on stdin. The adapter supplies these values; ORCH+ never resolves paths or builds this command. POSIX producer validator assets must remain adjacent to its helper.

Private selectors map the `report` stream to `reports/` and `reply` to `replies/`. Slot and watermark sequence filenames use exact decimal integers through 9,007,199,254,740,991; exponent notation or rounded counters are not valid selectors.

The producer owns a cooperative single-writer journal. It atomically saves the entire logical report and next sequence together before publication, writes chunks before the manifest, and retains exact bytes until the exact ACK and cumulative receipt chain are durably consumed. Locks left by an interrupted producer require operator recovery after establishing that the prior producer is stopped; no PID inspection or timeout stealing is used.

The private launch preface contains the target root, handle, producer helper and enrolment binding. The exact original ORCH+ assignment follows it unchanged; `assignment_sha256` hashes only that assignment's bytes, not the transport preface. Producer `report` input is a closed JSON object `{kind,payload,action_id?,action_revision?,handover_id?,handover_token?}` on stdin. The helper supplies immutable BE, sequence and deterministic event ID itself. Initial ACCEPTED has no handover pair; rollover supplies both, and the preface tells the successor to copy them verbatim from its JSON.

A rollover successor's `mailbox_provision` carries the issued `handover_id` and `handover_sha256` = SHA-256 of the UTF-8 bytes `handover_id:handover_token`. The raw token is never provisioned. Both fields are required together. They are part of the binding digest and are written to `provision.json` as `handover:{handover_id,handover_sha256}`. Ordinary generations carry neither, so their `provision.json` and digest are unchanged. SPAWN refuses a launch whose enrolment pair does not hash to the provisioned digest. Before allocating a sequence, both producer helpers check every ACCEPTED against `provision.json`. A missing pair, a pair on an ordinary generation, a different `handover_id` or a token whose pair digest differs is refused with exit 1 and a stderr line that names the field and never echoes either value, for example `binding_mismatch: handover_token differs from the provisioned handover digest; copy it verbatim from the launch preface and report ACCEPTED again`. Nothing is published or journaled, so the worker retries with the exact values at the same sequence. Only ACCEPTED reads the provisioned handover. A malformed one refuses ACCEPTED with a plain `binding_mismatch`, while every other report and mode, including `retire-authorized`, behaves identically in both helpers.

Every `mailbox_read` of a report is still validated against the issued launch (assignment digest, handover pair, capabilities). A mismatch is refused with the codec code and message, for example `binding_mismatch` "Acceptance differs from the issued assignment or handover.". An already published report keeps its sequence and is never replaced.

Coordinator use additionally requires explicitly reviewed/configured `coordinator-control-v1` in the provisioned capability set. It is not implied by `report-files-v1`, and existing ordinary records remain usable without it. The five recognized capability names are `report-files-v1`, `native-ask-v1`, `worker-poll-v1`, `argv-v1`, and `coordinator-control-v1`; backend/wake-route compatibility still applies. An actual coordinator launch carries paired enrolment `coordinator_owner_id`/`coordinator_generation`. Only that explicit role adds the transport instruction to emit ACCEPTED, then wait for and claim typed activation before coordinator work. A capable record used for ordinary work does not wait. Original assignment bytes and digest remain unchanged; no activation token is sent through the preface.

The closed version-1 replies add `coordinator_activation` payload `{owner_id,owner_generation,activation_token,instructions}` and `coordinator_retirement` payload `{owner_id,owner_generation,activation_token,reason}`. The closed version-3 report adds `COORDINATOR_RELEASE` payload `{owner_id,owner_generation,activation_token,quiescent:true}` and requires `action_id`/`action_revision` referencing the issued activation or retirement. Tokens are exactly 64 lowercase hexadecimal bytes, instructions at most 32,768 UTF-8 bytes, reasons at most 1,024. Helper schema support is not authorization: configured/provisioned launch capabilities and ORCH+'s exact issued grant/receipt govern intake. Existing helper provision bindings gain no fields. A release report means cooperative quiescence, never native closure.

Concrete POSIX work-tool invocation, using the private values from the launched assignment:

```sh
sh "$producer_helper" "$root" "$handle" "$enrolment_token" init
printf '%s' "$report_json" | sh "$producer_helper" "$root" "$handle" "$enrolment_token" report
sh "$producer_helper" "$root" "$handle" "$enrolment_token" receipts
sh "$producer_helper" "$root" "$handle" "$enrolment_token" consume
sh "$producer_helper" "$root" "$handle" "$enrolment_token" wait '' 5 30
```

Windows uses `powershell.exe -NoLogo -NoProfile -File <producer_helper> -Root: <root> -Handle: <handle> -Owner: <enrolment_token> -Mode: init|report|replay|receipts|consume|wait|claim|resolve|retire-local`; `report` takes the same JSON on stdin, `-PollMs: 5000 -WaitSeconds: 30` bounds wait, and `-MessageId:` addresses claim/resolve. Each colon-ended parameter name and its literal value are separate argv elements: this prevents `-File` from interpreting the `-` selector or a hyphen-prefixed identifier as a parameter name, without coercing boolean-looking strings. The target adapter uses the same explicit binding for all nine helper fields; POSIX keeps its positional protocol. Use structured work-tool argv/target quoting, not interpolation of untrusted report text as code.

Windows report stdin is UTF-8 bytes, read directly from the standard-input stream with a 65,536-byte ceiling and one overflow-detection byte. It does not use PowerShell's automatic input enumerator or locale-dependent console text reader. Send UTF-8 explicitly; an OEM-code-page process writer is not a valid substitute. Empty, malformed UTF-8 and oversized input are rejected before journal mutation. The Windows regressions exercise the documented `-File` entrypoint, including all five capability names, multibyte text boundaries and unchanged journals on rejection.

`init` takes no input: non-empty stdin is refused with a nonzero exit before any journal is created, and success prints `journal initialized; next: publish ACCEPTED with mode report` on stderr (stdout stays empty). Publish every report, including ACCEPTED, with `report`.

`init` is only for a genuinely new journal. Restoration uses `replay`, never a reset of sequence. `consume` durably records a validated reply and emits its correlated `reply_ack` before returning the reply. `claim`/`resolve` record the recipient's execution uncertainty separately from receipt. At work checkpoints call `receipts` and `consume`; while awaiting a reply use bounded `wait` calls through the actual configured CLI's existing execution loop. A shell helper existing on disk does **not** prove a CLI polls it during work or while waiting. Demonstrate that route before marking a terminal record eligible.

Receipt and application delivery are separate. `consume`/`wait` re-deliver retained **unclaimed** exact reply bytes after a crash between durable receipt and stdout, even if the receipt cursor advanced or transport files were compacted. Claimed/uncertain effects are never presented as new execution permission. At most eight consumed facts and 524,288 raw reply bytes are retained; unresolved facts count toward this limit and cause visible backpressure.

For eligible recognized native agents, durable ACK/reply publication records a bounded notification obligation, not a native execution claim. ACK wake requires the exact launched `awaiting_acceptance` or `accepted` worker; reply-manifest wake requires `accepted`. A separate ORCH+-granted `native_wake` references that exact publication. Its fresh window checks the current execution origin/controller alias, exact grant, pane association and safe idle state before `cx.agents:ask` with the bound numeric pane ID. The ask drains receipts first, then consumes a complete reply if present; ACK-only notifications require no synthetic report. Working, waiting-input, exited, unknown and permission-held agents are not interrupted. Queued input is not receipt or execution success.

Publication exposes canonical `wake_target_request_id` / `wake_target_action_id`, `wake_status` and `wake_effect_started`. Only `awaiting_window` with `wake_effect_started=false` proves an unstarted obligation: ORCH+ can settle publication without occupying an execution slot. Separate wake reservations/claims share the normal four-host/one-generation limits with transport. A proven pre-effect idle race defers under a fresh exact grant; possible asks stay uncertain and never repeat. Polling routes need no native wake. Duplicate publication and compaction preserve the canonical notification and cannot reset a submitted/uncertain wake.

## Public bridge

Open the native block and read its current response node before sending an action:

```lua
local pane = cx:new_block("spawn.dispatch", { creator_json }, "beside", { focus = false, target = controller })
local surface = cx.session:surface(pane, {
  as = "table", root = "main.spawn-dispatch-response", nodes = 4, depth = 2, max_chars = 8192,
})
-- Validate complete surface role plugin.spawn.dispatch, exact keyed text node,
-- role spawn.dispatch.response, and all native clipping indicators first.
cx.session:event(pane, { ev = "action", id = surface.main.id,
  act = request.op, value = tern.json.encode(request) })
```

The prefix is `SPAWN_DISPATCH v1 ` and the closed outer frame is:

```text
{schema:1,op,request_id,complete:true,body_bytes,body_sha256,body_json}
```

`body_json` is the exact UTF-8 JSON string hashed and counted, not parsed/re-encoded data or another Base64 layer. The entire prefix plus escaped outer JSON must fit 8,192 bytes. The body is `{schema,op,request_id,action_id,origin_binding,controller_generation,status,payload?,error?}`. Reject clipped, oversized, mismatched or partial surfaces; never mine generic pane text for results. Only SPAWN consumes its separate private execution projection.

Runtime common fields: `schema:1`, `origin:"orchplus"`, `op`, host-issued `request_id`/`action_id`, decimal-string window-local `controller_pane`, positive `controller_generation`, and exact `origin_binding`:

```text
{logical_session_id,owner_id,owner_generation,host_pane_id,alias_nonce,
 window_key,window_epoch,native_session_id,window_host_id}
```

These correlate/fence the admitted controller; they do not authenticate OS principals or establish canonical cross-window identity. After asynchronous membership verification, public mutations persist `pending` with `authorization_required:true`. SPAWN privately issues a boot-, bridge-, request- and time-bound nonce. Its window checks the exact live ORCH+ owner, immutable request and `{executor,epoch,grant_id}`, plus the projected current execution origin/controller alias and durable control cursor. Read-only reconciliation projections cannot authorize execution. The host rechecks its independent owner fence and consumes the nonce before intent/effect; a public request alone never authorizes mutation. No suitable window leaves authorization pending. A newer same-origin intent sequence does not invalidate a retained effect claim, but continuation fences old-window callbacks. No `WindowCx` is retained.

Bridge membership scans the host daemon's `window` clients and `remote` clients (window halves attached through `tern remote serve`), at most 16, and requires exactly one session across them to hold the bridge pane, re-inspected once before use; CLI/script clients are ignored. Regression: `dispatch/remote_membership`.

Authorization deadlines preserve the native clock's fractional monotonic milliseconds; integer-only validation applies to revisions, generations and sequence counters, not clock values.

A requested nonce is projected only on its originating host bridge while still live. Other request/status panels may inspect public outcomes but cannot solicit that nonce's one-shot window response, and duplicate submissions cannot rotate an unexpired challenge onto another bridge. Authorization refusals distinguish request, nonce, VM, bridge, phase and deadline mismatches without exposing nonce or filesystem material publicly; none grants retry permission.

A `status` read of a staged request whose challenge is still `requested` but expired or issued by an earlier host VM reports definitive pre-effect evidence instead of `pending`: the retained pre-challenge outcome when one exists, otherwise `full` with `{resource="window_authorization",current=1,limit=1,retryable=true,effect_started=false}`. Such a challenge can never be consumed, so nothing started. The projection is read-only; re-staging the identical request still issues a fresh nonce. The window executor rearms its 250 ms observation timer before each tick, so a tick that trips the window budget cannot end later authorization observations.

The bridge view shows one compact human line (`SPAWN bridge - <op> <status> - <note>`). Its machine nodes stay in the native surface, keyed and bounded as before, and `dispatch.css` (manifest `styles`) only stops drawing them. A third keyed node, `main.spawn-dispatch-lease` (role `spawn.dispatch.lease`), carries `SPAWN_BRIDGE v1 {schema:1,held,live,busy,owner?}` (at most 2,048 bytes) for the ORCH+ window's bridge lifecycle; it is never authority. `held` means the registry still names this pane as the bridge of a `requested` window authorization that can still be consumed (issued by this host VM and not past its deadline), or the registry is unreadable. An expired or earlier-VM challenge can never be consumed, so it stops holding its bridge once the deadline passes, whether or not the window that requested it still exists; a granted launch, adoption, stop or wake keeps the bridge `live` through its execution projection until its native outcome is recorded. `live` means an execution projection is current, and `busy` means a membership verification is in flight. `owner` is `{controller_pane,alias_nonce,window_key,window_epoch}` of the current request. A request-less bridge reports instead the creator JSON `{schema:1,...same fields}` that ORCH+ passes as `new_block` argument 1, kept in saved state. ORCH+ reuses a bridge only when its lease is idle and its owner is the same controller and window, and it closes only an idle bridge of an earlier incarnation of its own window. Regression: `dispatch/bridge_view`.

Never move a bridge pane between tabs after it opens. In the live window a pane moved with `move_to_tab`/`move_to_new_tab` answers `cx.session:surface` with nil, so neither ORCH+ nor this package's window executor can read its response, lease or execution nodes any more. Open it where it stays: a `"tab"` placement, or `"beside"` with `target` set to a pane in the destination tab. Never park it either, since a parked pane has no tab and fails the session-membership check.

The window marks a nonce sent only after both exact-origin observations and final payload checks succeed, immediately before enqueueing the private authorization event. A rejected pre-send observation leaves the unsent challenge available for a later valid observation. Once enqueueing begins, exceptions or missing acknowledgements do not permit another send; the host still enforces nonce freshness and one-shot consumption.

The window VM's sent/effect markers and stop observations are grouped per ORCH+ request. A group is dropped only once that ORCH+ action reads back `complete` or `resolved` from its own controller pane (same alias nonce and session), when no marker can authorize anything; a claimed, uncertain, missing or unreadable action keeps every marker. One group is checked per tick, so the tables stay bounded by unsettled work instead of growing for the VM's lifetime.

| Operation | Additional request fields | Result |
| --- | --- | --- |
| `catalog` | optional `cursor:{revision,index}` | `catalog` with `{revision,records,next_cursor?}`; record revisions equal canonical nonnegative config revision |
| `launch` | `record_id,record_revision,work_id,prompt,cwd,placement,fresh:true,mailbox_handle,enrolment` | Durable resolved/claimed/launching/awaiting_acceptance/accepted/rejected/uncertain phase |
| `adopt` | `record_id,record_revision,work_id,prompt,mailbox_handle,enrolment,pane_binding,attestation:"operator_verified_exact_agent_pane"` (ordinary enrolment only: no handover or coordinator pair) | ORCH+ explicit verified attach of an existing native agent pane. Same staging, window authorization and exact claim/begin/result as `launch`, but no managed reservation and no new agent: the window delivers the shared transport preface plus the unchanged assignment once via `agents:ask` to the exact pane, after confirming it is an idle recognized native agent in the controller's window/session/host. `refused` (pre-effect: busy, non-agent, out of scope) → `rejected`; `submitted` → `awaiting_acceptance` with that pane as the launch pane binding; anything ambiguous → `uncertain`, never repeated. A pane already bound to an unstopped launch/adoption is refused. Accept, stop, wake, attach and retirement then treat it as a launch. |
| `status` | `target_request_id` | `found` payload `{outcome:<retained original body>}` or `missing` |
| `owner_status` | none | `owner_status` payload `{owner}`, one of `current`, `none`, `previous_incarnation`, `other_owner`, `fenced`, `retired`, `other_authority`. Read-only: it reserves no owner, fences nothing, records nothing and exposes no binding; ORCH+'s guided reload recovery uses it to show whether SPAWN's own Config owner recovery (fence, verify, confirm) is still required |
| `accept` | `target_request_id,target_action_id,pane_binding,worker_id,worker_generation,enrolment_token,work_id,event_id,seq,event_sha256`; rollover-only handover pair | Exact semantic-acceptance replay or binding/content refusal |
| `stop` | `target_request_id,target_action_id,pane_binding,worker_id,worker_generation,enrolment_token,work_id` | Exclusive resolved/claimed/launching intent, then `stopped` with exactly `{pane_binding,observation:"absent"|"exited"}`, or retained uncertainty/refusal |
| `native_wake` | `target_request_id,target_action_id` identifying the canonical published ACK/reply manifest | Separate bounded notification reservation/claim, then `submitted`, proven pre-effect deferral or retained uncertainty |
| `attach_worker` | `target_request_id,target_action_id,previous_origin_binding,previous_pane_binding,pane_binding,worker_id,worker_generation,enrolment_token,work_id,attestation:"old_executors_stopped_or_retired"` | Explicit current route attachment; original launch/mailbox/request identities remain immutable |
| `mailbox_provision` | top-level BE, `record_id,record_revision,capability:"report-files-v1"`; rollover successors add paired `handover_id,handover_sha256` | Opaque handle, binding digest, limits, capability/identity facts; never paths or the raw handover token |
| `mailbox_read` | BE, `handle,expected_generation,selector` | One complete codec page or typed absence/compaction |
| `mailbox_publish_ack` | BE, `handle,expected_generation,receipt_revision,ack_b64,ack_sha256` | Immutable publication/readback outcome |
| `mailbox_publish_reply` | BE, `handle,expected_generation,message_id,reply_seq,action_revision,reply_sha256,part,index?,object_b64,object_sha256` | Part publication only; manifest verified last |
| `mailbox_retire` | BE, `handle,expected_generation,mode,settlement_revision,report_floor,report_chain_sha256,reply_floor,grant_id` | Authorized prefix compaction or settled retirement |

BE is `{logical_session_id,worker_id,worker_generation,launch_request_id,work_id,enrolment_token}`. Launch enrolment is `{worker_id,worker_generation,enrolment_token,assignment_sha256,handover_id?,handover_token?,coordinator_owner_id?,coordinator_generation?}`; handover and coordinator fields are independently both-or-neither pairs. Pane binding is `{pane_id,window_epoch,window_key,native_session_id,window_host_id}`; pane_id is a window-scoped decimal alias, never a packed host-ID comparison.

Selectors are closed: report/reply `{stream,slot,part:"manifest"|"chunk",index?}`; ACK `{stream:"ack",slot}`; watermark `{stream:"watermark",through_seq?}`. A positive watermark selector is independent of data intake. No bridge operation accepts arbitrary filesystem paths, commands, credentials or raw model/account overrides.

Request IDs retain immutable outcomes across duplicate blocks. Status nesting can exceed the outer bound for a large page; within its original execution context, exact original-request replay returns the direct retained body. A replacement window's read-only status admission is not permission to replay that effect. An uncertain mailbox operation's authorized reconciliation (exact replay, or a new request carrying the same publication bytes) performs bounded readback first, never blind publication. For an ACK or reply object only, readback that proves the final object absent republishes the exact same immutable bytes in the same operation: the no-replace link returns `already_published` for equal bytes, and a late earlier child can only publish those bytes. Legacy SSH generations, provisioning, compaction and retirement stay readback-only; possible native launch/wake effects never retry. Confirmed compaction keeps request/handle/generation/floor fences and unresolved notification evidence. Unresolved outcomes never age out; capacity exhaustion refuses new work.

Managed launches run in the background and never keep focus: terminal `split`/`new_tab` open with `focus=false`, and because native `agents:start` has no focus option, the pane focused just before it (normally the ORCH+ controller) is refocused if the new agent pane took focus. Refocusing is presentation only and never changes the launch result.

Ordinary worker finish and coordinator retirement both retain the accepted launch and one exclusive stop request. Ordinary stop does not require `coordinator-control-v1`; coordinator authority/release remains separately fenced. Fresh exact ORCH+ authorization and durable window claim/begin precede `cx.agents:stop` for a recognized native agent, or `cx.layout:close` for an enrolled terminal. There is no shell/PID fallback, focus stealing or session switching. Fresh exact-window absence/exit must be observed after the effect; pre-existing absence and successful return alone are not completion. Observation is bounded to twenty executor turns; ambiguous native effects never repeat under another stop request or after reload. This is native pane evidence, not proof that every remote descendant exited.

The managed launch reservation remains occupied until both exact durable stopped evidence and successful `mailbox_retire` (`mode=retire`) are retained. Settlement checks the issued attempt, observer, record, authority and pane, and cannot clear an unrelated/newer/uncertain reservation. A failed cross-store reservation commit preserves mailbox retirement evidence for exact reconciliation without repeating native stop or helper retirement. Only after settlement does the bridge expose `retired`, permitting ORCH+ to release its matching owner. No successor starts implicitly.

For that exact stopped launch only, the same bounded retirement operation first invokes the reviewed producer helper's private `retire-authorized` mode, then the existing target `retire`. Cleanup compares the exact seven-field issued binding against both provision and journal, matches the enrolled owner token, report/reply floors and receipt chain, requires empty pending reports and acknowledged/resolved consumed executions, and removes only the settled journal under existing producer/capacity locks. Workers must resolve genuinely completed control messages and drain their final receipts first. Missing, claimed, uncertain or mismatched journals remain occupied; locks are never stolen.

The private helper arguments extend neither the public bridge nor ordinary retirement permissions. POSIX slots 8–11 are report floor, reply floor, receipt-chain digest and bounded Base64 expected-binding JSON (slots 5–7 remain message/poll/wait). PowerShell uses literal `-ReportFloor:`, `-ReplyFloor:`, `-ReceiptChain:` and `-ExpectedBinding:`. Success is exactly `producer_retired\n` after lock cleanup. Existing worker-owned `retire-local` and ordinary empty-producer retirement/compaction are unchanged. Any lost callback between journal removal and target retirement stays uncertain: reconciliation only checks target absence, never replays cleanup or native stop. Capacity refusal after producer cleanup cannot claim the whole operation performed no effect.

A journal that is not settled at the authorized floors (pending reports, a cursor or receipt chain off the floors, or a consumed message not acknowledged and `resolved`) is refused before anything is removed: the helper releases its gates and exits 0 with exactly `producer_unsettled\n`. As the first child it proves no effect, so the adapter returns a definite `rejected` (`producer_unsettled`), never uncertainty, and the target is not invoked; the mailbox stays provisioned and a later retirement needs a fresh grant. Any other output, a non-zero exit, a timeout or that line from the target child remains uncertain. Older installed helpers report the same refusal as uncertain; reinstall the reviewed helpers to get the definite outcome.

A launch or adoption SPAWN rejected never reached native execution: every stored launch-family rejection precedes the native call, and an adoption `refused` result precedes its ask. When that entry is `rejected` with no pane, attachment, acceptance or stop intent, `mailbox_retire` (`mode=retire`) of its never-used mailbox is accepted without native stop evidence or explicit attachment, as if no launch had been issued. It runs the ordinary empty-producer retirement, never the private producer cleanup, and settles no launch reservation. ORCH+ uses this when the owner cancels such never-launched work. Any executed launch still requires its exact stop. Regression: `dispatch/unused_retirement`.

A proven pre-effect capacity refusal includes `payload.retryable:true,effect_started:false`. Only this result authorizes rechecking the same exact request after pressure clears; its identity and immutable contents must not change. An ordinary `full` after a possible effect, a pending child/claim, or prior uncertainty carries no such permission. Capacity handling must retain the preceding worker state rather than inventing failed launch or acceptance.

Every `full` includes truthful `resource,current,limit`: resource is a nonempty ID of at most 96 characters, current is a nonnegative safe integer, and limit is a positive safe integer. Admission may report a projected count below a ceiling; this is not itself retry permission. Helper stdout for `full` is exactly four newline-terminated lines: status, resource, current, limit. Missing/malformed accounting remains uncertain.

The explicitly amended retry-proof contract has only two cases: host admission refused before launching a child; or a fresh, non-reconciliation operation on an existing mailbox whose reviewed target helper terminates successfully with exactly `admission_full\ncapacity_admission\n1\n1\n`, before acquiring the shared commit lock or beginning any effect. The adapter validates complete output and exit status, settlement releases the child/generation claim, and exact replay requires a new live ORCH+ authorization. Provisioning is excluded because it may already have created directories. Timeout, cancellation, failure, a matching prefix, other `full` results, or earlier uncertainty never grant this proof.

## Owner-gated import and recovery

Migration is a separate schema, not an ORCH+ runtime exception:

```text
{schema:1,origin:"spawn-migration",op:"import_config",request_id,
 migration_gate_id,source_client,target_host,source_revision,source_sha256,records_json}
```

`records_json` is the exact bounded record-array JSON string; its original bytes determine `source_sha256`. Paste the same preview **without migration_gate_id** into Config → Setup, inspect the source/target/revision/hash and records, then click **Allow roster import**. That owner action returns a one-use gate; it imports and launches nothing. Cancel explicitly or let a host runtime restart invalidate an unused gate. Consumed gates retain their result, and divergent existing record IDs are never silently overwritten. Keep source snapshots until canonical readback and a configured launch succeed. Never place literal credentials in a migration snapshot.

A consumed gate with an uncertain cross-store result is reconciled on exact replay through the retained authority binding and immutable snapshot. The authority checks its existing import receipt before revision checks; an already committed import is recovered without importing twice, and an unattempted idempotent import can complete. Changed tuple bytes cannot use that gate.

An occupied controller binding refuses ordinary mutations from another origin. A replacement window of the same stable owner/generation/controller host pane may inspect retained outcomes read-only after matching SPAWN authority and host-session checks; inspection changes no owner and exposes no effect grant. Explicit `attach_worker` verifies the immutable original launch plus the selected current pane and operator attestation, stores a separate control route, and fences earlier authorization callbacks. A staged request whose authorization challenge was never consumed when owner recovery or attachment fences its old controller becomes `rejected` with the pre-effect code `authorization_revoked`. Nothing executed. An `accept` revoked this way may be re-sent as a new request on the attached route, and `accept` validates that route against the attachment record and the original immutable launch, enrolment and acceptance event.

Config → Running agents shows retained bindings, pane aliases, claims and outcomes. Where active/uncertain executors block attachment, first **Fence managed controller for recovery**, then independently verify the previous controller and every executor stopped or retired. Exact-revision confirmation records authority/host-session-scoped operator attestation, preserves unknown outcomes and worker reservations, and starts no replacement. Retired executor occupancy cannot block unrelated safe workers forever, but the affected generation remains held if an ask/publication outcome is still unknown. Config read failures/corruption are recovery errors, not empty state.

Tombstone checks also apply when no current owner slot exists: a retired binding cannot request a new catalog or stage an authorization. Read-only status may inspect that binding's retained outcome without allocating or recreating ownership.

Recovery includes native wake and authorization records. A resolved wake without an execution claim can be conclusively fenced as pre-effect while retaining its notification. Possible effects remain uncertain; unused nonces are revoked. Stopped-executor attestation never claims those unknown effects succeeded or permits retry. Normal transport identity reset refuses while that authority owns managed controllers, consumed authorizations or unresolved import gates. Authorization preflights canonical configuration; only retained proven pre-effect prerequisite failures can obtain a fresh challenge after repair.

## Bounds and durability

Logical reports/replies: 65,536 UTF-8 bytes; 1–32 chunks of at most 2,048 raw bytes; chunk wire JSON <=4,096; control/manifest <=2,048; bridge <=8,192. Outstanding data reports and replies each have eight slots; reply ACK reports have eight reserved control slots. Each generation is limited to 4 MiB/1,024 files. Host allocation is 64 MiB/16,384 files; every unretired generation reserves its full 4 MiB/1,024-file allowance, so at most 16 unretired generations exist (`LIMITS.generations`, also reported in the provisioned `limits`). The 17th provision is refused `full` (`resource=mailbox_allocation`), and a stored registry with more live generations fails validation. One operation/generation, four/host, 30-second process deadline measured in awake time. Transport registry <=4 MiB with 256 KiB reserved for settlement/control.

The mailbox adapter's whole-operation deadline counts awake progress. A 1 s watchdog adds the elapsed time between observations, but a gap of more than 5 s (host sleep, App Nap throttling or a paused hook) counts as one nominal second. Each helper child receives the remaining awake budget as its `process.run` timeout, so a child spanning a suspension is not declared uncertain because wall time passed, and a later child keeps its unspent budget. Awake waiting still ends as `uncertain`; a child that `process.run` itself timed out (for example, if the runtime counts the suspension) stays `uncertain` and needs the existing readback reconciliation. The deadline is never shortened. The bridge's authorization-challenge freshness window (30 s, host clock) is a separate security fence and is unchanged.

Within each physical mailbox, ordinary durable allocation is capped at 2,097,152 bytes/896 files and settlement allocation at 2,359,296 bytes/1,008 files, leaving room for a 1,572,864-byte journal replacement and 262,144 bytes/16 files of workspace. Target and worker use a separate short-lived shared capacity admission/commit lock; the producer's invocation lock is not reused. The capacity lock is released before stdin/stdout or polling sleep, so an awaiting worker cannot block incoming replies. Abandoned locks require explicit operator recovery, never PID/time-based stealing. Failed reconciliation (`full`, incomplete or missing) cannot clear an earlier uncertain-child fence.

The POSIX producer also creates and removes its invocation lock and workspace under shared capacity admission. Releasing admission before deleting those directories let a concurrent target scan enumerate disappearing entries and incorrectly reject valid reads as `binding_mismatch`. Normal cleanup now finishes before releasing the gate. An interrupted wait that cannot reacquire admission preserves its recovery lock instead of deleting inventory beneath another helper's scan; explicit stopped-producer recovery remains required.

Publication uses exclusive same-filesystem staging and atomic no-replace final names. Existing identical bytes are success; different bytes conflict. Regular-file and ancestor checks reject symlink/reparse redirection; this is not a malicious-same-user sandbox. Host KV commit, OS files and native panes are separate stores: intent/claim, effect, readback and retained uncertainty replace any claim of a cross-store transaction. Reload/process-failure recovery is covered by the design; no power-loss/fsync guarantee is asserted.

Windows uses a fixed UTF16LE-encoded PowerShell wrapper with a separate UTF8 JSON payload and Windows CRT argv escaping; SSH nests the remote serializer inside the pane-host serializer. Commands are bounded before pane creation (Windows 7,000 encoded characters; POSIX 32 KiB). Native OMP on an unverified Windows launch shell remains explicitly unavailable rather than falling back to another identity.

## Verification entrypoints

No checks are run by the implementation builders. Integration owns all executions and actual-worker evidence. Native Luau runner:

```lua
return assert(loadstring(tern.fs.read(root .. "/tests/run.luau")))(root,
  "behavior,authority,backend,dispatch,window_dispatch,mailbox,host_editor,retirement_adapter")
```

Existing behavior/authority groups remain intact. New groups cover strict framing, immutable requests, initial acceptance, exact action/claim/nonce fencing, delayed wake authorization, reloads/failed commits, receipt-first migration reconciliation, coherent capabilities, fresh serialization and mailbox planning. Run groups separately if native callback budgets require it; do not infer stress coverage from fixture counts.

The runner includes every released authority section plus managed coexistence, ordinary/managed job isolation, exact old-store migration, transport rotation, import replay, missing-store/reset guards, forgetting protection and delayed observations. `lost_release` covers host-restart bulk release: only Unknown attempts recorded under a different, known daemon epoch are listed and released, all-or-nothing on both the request and Config edit paths, with an unknown epoch, a stale revision or any non-lost attempt refused unchanged. `managed_retention` covers 140 sequential retired workers alongside unknown evidence and subsequent ordinary admission; `managed_settlement_replay` retains interrupted retirement across trimming/clearing and permits settled-scope reclamation without deleting bridge fences. `managed_migration` includes obsolete ordinary receipts, a consumed bridge import after transport rotation, clean never-created storage and missing/corrupt/read-failed evidence. The dispatch `authority_rotation` section additionally checks stable controller/recovery identity and unchanged execution-origin fences. None of these source changes asserts a passed runtime matrix.

Dispatch sections are `launch`, `migration`, `publication`, `ack_lifecycle`, `wake_binding`, `authorization`, `recovery`, `duplex`, `retirement_binding`, `retirement_settlement`, `retirement_producer`, `unused_retirement`, `coordinator_launch`, `wake_capacity`, `wake_retention`, `attachment`, `attachment_recovery` and `bridge_view`. Invoke `run.luau(root, "dispatch", section)` or `tests/dispatch.luau(root, section)`; omitting the section runs all cases. The optional third argument also selects an `authority` section or `window_dispatch` section (`wake`, `retirement`). Long traces require cooperative host-callback slicing without dropping assertions; do not raise or disable production budgets. The integrated suite exercises actual reducers/host/window code with controlled boundaries, including four executing wakes versus independent transport, once-only publication notification, explicit attachment and delayed old-window callbacks. Actual workers/platforms remain separate acceptance gates.

The `host_editor` group exercises the actual host callbacks and canonical authority behind mocked membership/KV boundaries: lazy JSON draft loading, schema/ID refusal, review-before-launch, explicit approval, concurrent stale edits, unchanged import collision refusal and the two-click host-restart bulk release.

Disposable helper regressions are provided separately: `python3 tests/mailbox_posix.py` on POSIX and `powershell -NoProfile -File tests/mailbox_helpers.ps1` on Windows. These exercise crash-boundary redelivery, report rejection before sequence allocation, saturation/drain and shared-lock behavior. Python is a test-harness prerequisite only, not a deployed producer dependency. Builders have not run these scripts.

The POSIX scans deliberately use balanced `(pattern)` case arms inside command substitutions. This avoids Bash 3.2's [documented premature `)` termination](https://lists.gnu.org/archive/html/bug-bash/2006-10/msg00009.html) without changing containment, depth or capacity checks. The real-helper suite runs `/bin/sh` directly, including on macOS, and covers literal parentheses in mailbox roots plus link/depth rejection with unchanged journals.

Windows helper regressions additionally exercise nested `DirectoryInfo.Parent` ancestry, file rejection and junction rejection at both the leaf and an ancestor. Production directory guards use the .NET directory type rather than provider-only `PSIsContainer` metadata while retaining every reparse-point rejection. Compaction and retirement preflight every cleanup lane before their first deletion; actual helper subprocess regressions redirect each lane through a disposable junction and require both external numeric sentinels and earlier valid mailbox data to remain unchanged. Actual `consume` and `wait` entrypoints are checked through raw stdout bytes, including retained replay after transport compaction: output is the exact immutable reply, without an appended newline.

Journal updates retain atomic `File.Replace` on Windows. Its optional backup path uses PowerShell's explicit null-string value so Windows PowerShell 5.1 cannot coerce it to an invalid empty path; there is no delete-then-move replacement fallback.

Required runtime evidence before publication: unchanged ordinary configured launch; exact task/cwd/identity through native/local-terminal/SSH; Windows/macOS/Linux adapters as applicable; duplicate claims/lost callbacks/reload; actual full ACCEPTED → ORCH+ commit → SPAWN ACK → producer watermark; actual reply → safe native wake or terminal polling → durable reply_ack; partial ACK retention, immutable conflict, missing chunk, size/backpressure boundaries, failed commit/no ACK, and authorized compaction/retirement. A fixture producer or queued ask is not proof of a real configured worker's polling or consumption.
