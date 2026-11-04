# TODO 0.5.0 publication rework — validation

CodexBWAI · 4 November 2026. This explicit-publication design supersedes 0.4's agent-query/operator-path candidates. No agent input, managed skill edit, new dependency, Tern restart or FORGE operation is involved. The owner chose existing CLI sessions and canonical plan publication.

## Current frozen-source evidence

Ten executable helper tests pass. They cover canonical block parsing/immutability, LF/CRLF, invalid usage returning 1, bounded SSH error envelopes, trusted-host/forwarding/multiplexing options, locale-independent payload and a legacy SSH option boundary. Synthetic option-resolution checks are distinguished from actual connections.

Tern 0.9.8 and 0.9.10 each pass six native view/controller contracts and fourteen connected checks. The production show → native window-scoped process → host discovery → published reader → renderer path covers canonical edits, pinned identity/save/restore, failure invalidation, independent local and real key-authenticated loopback SSH sources/backoff, clear while alive and no-plan TODO exit without ending the selected program. The additional real native regression keeps an unlisted launcher alive, ends its publishing child without clearing, starts a replacement without publishing and proves that replacement cannot inherit the old plan. The cleared binding is also observed to stop polling. Receipts: `todo-publication-v5-098.json` and `todo-publication-v5-0910.json`.

Actual Odin Windows Python 3.14.7 and Thor macOS Python 3.9.6 native Tern programs pass publication/discovery/read preserving canonical bytes, changed/failed publication refusal, and clear while alive. macOS additionally proves that a matching unsafe store produces an error and an unrelated untraversable namespace cannot block valid discovery. Windows passes four native boundary checks, macOS six, and Linux seven, including the reader/writer interleaving; Linux also exercises a native process-name change. Windows receipt: `todo-publication-odin-v5.out`; macOS receipt: `claudebwai-todo-publication-thor-probe-v5/result.json`. The eight Linux runtime hashes match current source; all three helper hashes match both portable probes. Primary comparison: `todo-publication-v5-primary-readback.json`.

The current CodexBWAI interactive canonical plan was deliberately published using its explicitly identified actual agent PID and kernel-verified ancestry. The managed descriptor reader accepts the companion schema. Neither observation proves that a fresh planning model adopts the workflow.

## Review repairs and limits

ClaudeBWAI returned REWORK NEEDED at https://github.com/blastworksai/tools/pull/2#issuecomment-6619964813 for head d7230de. That verdict remains historical evidence; no new review pass is claimed.

The rework removes shell-name inference: publish/clear require --agent-pid, verified against the caller's owned native ancestry. The planning agent identifies its durable CLI process from runtime facts or bounded helper ancestry; ambiguous identity is unavailable, never guessed. Matching unsafe metadata is an error. Ended/cleared/changed bindings carry a terminal failure marker and stop polling. Publish prunes only a bounded number of this account's own valid-but-dead records and refuses to replace a different live publisher in the same native session. Windows ancestry checks parent birth ordering. Both /glitch-plan and Codex $glitch-plan names are documented. Rollout must compare all three installed companion/plugin helper hashes. The unused window alias is removed.

An in-process conversation reset cannot be detected from kernel process identity. The companion instructs clearing on fresh startup and before reset/end. If skipped, the old publication can remain visible. Owner acceptance of this residual and addition of the proposed shared planning reflex remain pending. The reflex proposal validates, but has not been installed. The descriptor alone does not make every planning invocation read the companion.

Initial local pending/done accessibility rows were observed. Later remote/restore/lifecycle checks use actual host callback state after the isolated client's closed-beta overlay hides the UI. The full Files button → session picker → rendered checklist remains unqualified. A real private Windows desktop client reached `gate:true`; the Files button was hidden. No gate screenshot is represented as TODO. Native remote-host attachment (VM daemon viewed from Windows/macOS) is also unqualified: loopback SSH file reading does not prove window-side process metadata routes to the selected remote host. No auth was copied or bypassed.

## Harness isolation and corrected failures

The native smoke uses a private config/plugin id, daemon, Xvfb window, real disposable loopback SSH and private TODO_PUBLICATION_ROOT. The publisher receives that path explicitly because native Tern program launches do not inherit arbitrary daemon variables. Initial root isolation failed at that fixture mismatch; it was corrected before the v4 receipts. Earlier receipts claiming production_touched:false predate that correction and did write pointer metadata into the normal root. Dead own fixture records were pruned by a deliberate real-session publish; the normal root now contains only the current session record. Current v5 fixtures use their own root throughout.

Portable v3 macOS passed; v3 Windows correctly refused its new test root's inherited foreign write access before publication. V4 applies an owner DACL to a newly created Windows fixture root before validating it; an already-existing unsafe root is still refused. V4 qualified that repair; final v5 receipts below qualify the subsequent discovery/republish rework. Historical hashes are not relabelled.

The Windows UI fixture first used an invalid daemon filesystem endpoint, then corrected it to a native named pipe. A window launched from SSH did not publish its endpoint; launching the private worker through the existing desktop daemon reached the real beta gate. All owned descendants were reaped through a kill-on-close Job Object assigned before worker execution; the installed profile was untouched. Thor probes kept the desktop closed. Only owned retained native sessions/stages were removed after saved proof; normal sessions/processes were preserved.

```sh
python3 -m unittest discover -s tests -p todo_test.py
python3 tests/todo_smoke.py --published --evidence /absolute/private/evidence.json
# Requires an available authenticated UI:
python3 tests/todo_smoke.py --published --files-button --evidence /absolute/private/ui-evidence.json
```

Run under the documented supervisor. Source fingerprints and owned-process cleanup are part of each receipt. Outstanding: fresh exact-head cross-family pass, owner reset-residual decision, supported companion installation/fresh planning adoption, native remote-host end-to-end, authenticated appearance and final 0.5.0 rollout. Existing 0.3.0 installation is separate from this candidate.

## Rework after edb246b review

ClaudeBWAI’s second exact-head review remains REWORK NEEDED (https://github.com/blastworksai/tools/pull/2#issuecomment-6620326650); the external UI/remote/adoption/owner-decision gates were not waived. Its new findings were repaired together:

- N1: skip an unrelated namespace when its key cannot be searched (PermissionError); a readable matching unsafe store still produces a detection error.
- N2: the publisher ownership gate compares pid/birth/owner, never the mutable kernel display name.
- N3: retain the old record during successful validation, then atomically replace it. Validation/write failure retracts this publisher’s old record; cleanup checks the live identity again so it does not erase a different live publisher arriving meanwhile.
- N4: both inline instruction forms require --agent-pid; examples say the numeric12345 is only a placeholder, and identity must be supplied for every call rather than relying on a variable surviving a tool shell.

The packaged tests/publication_probe.py exercises actual native process/filesystem boundaries without an AI or UI. On the old edb246b helper, its isolated namespace case fails with PermissionError and its deterministic paused-reader case fails with a missing terminal binding. Those intended red receipts are todo-publication-v5-red-namespace.json and todo-publication-v5-red-atomic.json. Current source passes all seven Linux cases, four Windows cases and six macOS cases, at matching helper hashes. A private reader barrier exposes the real publish callback’s validation window; it does not substitute a second publication implementation. Name-change coverage uses Linux’s native process-name interface. All barrier subprocesses are reaped in finally.

Run the probe as a new owned native Tern program with a new private --work-dir; it never writes into the source package. Its flat immutable portable bundle is the exact packaged probe plus the three current helpers. It runs no model, installs nothing and touches no deployed publication cache. Native catalogue readback separately confirms the existing TODO0.3.0 remains ready on VM/Odin/Thor. All completed owned delegate panes were closed after saved result/hash verification.

The related platform catalogue PR755 now records the existing0.3.0 tool as active, and points to tools PR2 for the pending0.5.0 redesign and its acceptance gates. Its current head still requires independent review; no live store or whole-platform release is implied.
