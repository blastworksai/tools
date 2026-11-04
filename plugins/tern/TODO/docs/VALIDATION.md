# TODO 0.5.0 — validation

CodexBWAI · 4 November 2026. The owner chose explicit publication for existing interactive CLI sessions. This replaces the earlier agent-query/operator-path candidates. No agent input, managed skill edit, new dependency, Tern restart or FORGE operation is involved.

## Current source evidence

Ten executable helper tests pass: canonical parsing/immutability and LF/CRLF, usage errors returning1, bounded SSH error envelopes, strict host trust/forwarding/multiplexing, locale-independent payload and a legacy SSH option boundary. Synthetic option-resolution checks are distinguished from real connections.

Tern0.9.8 and0.9.10 each pass six native contracts and fourteen connected checks. The production show → window-scoped process → host discovery → published reader → native renderer path covers source edits, pinned identity/save/restore, stale-success removal, independent local and real key-authenticated loopback SSH sources/backoff, clear while alive and no-plan TODO exit leaving the selected program alive. The unlisted-launcher fixture ends its publishing child without clear, starts a replacement and proves the old publication is not inherited. Cleared/ended bindings stop polling. Receipts: todo-publication-v6-098.json and todo-publication-v6-0910.json.

The packaged tests/publication_probe.py passes nine Linux, four Windows and eight macOS native process/filesystem boundary checks. Windows Python3.14.7 and macOS Python3.9.6 execute as real new native Tern programs. It verifies canonical bytes, changed/failed publication refusal, clear while alive and a concurrent reader paused inside successful republish validation. POSIX also tests a readable unsafe matching store, an unrelated untraversable namespace, plain-file/cyclic-link entries and a forged owner using the exact session key. Linux exercises a real process-name change. Evidence: todo-publication-v6-linux-boundaries.json, todo-publication-odin-v6-result.json and claudebwai-todo-publication-thor-probe-v6/result.json.

All eight Linux runtime fingerprints equal current source. All three helper fingerprints match all portable receipts. The flat portable probe is byte-identical to the packaged script; only its filename differs. Primary comparison: todo-publication-v6-primary-readback.json. Fixtures contain no AI or deployed metadata; subprocesses and owned native sessions are reaped. Thor retained its existing desktop/daemons/sessions, and its owned stage was removed. Native catalogue readbacks separately confirm existing TODO0.3.0 ready on VM/Odin/Thor.

Initial local pending/done accessibility rows were observed. Later source/restore/lifecycle checks use actual host callbacks after the isolated client's closed-beta overlay hides the UI. They are not authenticated appearance passes. A real private Windows desktop client reported gate:true and hid Files; no gate screenshot is represented as TODO. No auth state was copied or bypassed.

## Review-driven repairs

The prior independent reviews at d7230de, edb246b and12baa7c returned REWORK NEEDED. Latest: https://github.com/blastworksai/tools/pull/2#issuecomment-6620750496. Those are historical verdicts; no new pass is claimed.

- Publisher identity is explicit --agent-pid, verified against owned native ancestry. The agent identifies its durable CLI from runtime facts or bounded ancestry output, never guesses a shell/launcher/helper. Ambiguity is unavailable. Identity checks use pid/birth/owner, not mutable process names; Windows ancestry also checks parent birth order.
- Namespace entries are untrusted candidates. Discovery lstats before key lookup and accepts only real non-link/non-reparse directories owned by their named UID (own native SID on Windows). Non-candidates and key-lookup OSError are ignored; readable matching legitimate unsafe stores still produce error. This fixes the global regular-file/loop/unsearchable cases and forged-owner interference.
- Successful republish retains the old record during validation and installs the new one atomically. Validation/write failure retracts this publisher's old record. Identity recheck during cleanup is best effort; it is not an atomic compare-and-delete claim.
- Ended/cleared/changed bindings report terminal failure and stop polling. Own valid-but-dead records are pruned with a bounded pass; another live publisher in the same native session is refused.
- Every instruction form includes verified --agent-pid. Examples explicitly use12345 as a placeholder supplied each time, without assuming a variable persists between tool shells. Both /glitch-plan and Codex $glitch-plan forms are named. Rollout requires all three installed companion/plugin helper hashes equal.

Actual red receipts reproduce the old failures: todo-publication-v5-red-namespace.json and -red-atomic.json use edb246b; todo-publication-v6-red-namespace.json and -red-forged.json use12baa7c. Each intentionally records probe.passed:false with expected_failure:true. Current source passes the same boundaries; old receipts are never relabelled with new hashes.

## Isolation and remaining gates

The connected smoke uses private config/plugin id, daemon, Xvfb window, disposable real loopback SSH and TODO_PUBLICATION_ROOT. The native publisher receives its fixture path explicitly because Tern drops arbitrary daemon environment variables from program launches. An earlier isolation mismatch wrote one dead own record to the normal root; it was removed by a deliberate real-session publish. Earlier production_touched:false receipts did not mean no pointer metadata was written to that root. Current fixtures stay private; the normal root contains only the real current CodexBWAI publication.

Windows UI probes used a kill-on-close Job Object assigned before worker execution. Initial invalid daemon filesystem endpoint was corrected to a native named pipe; launching through the existing desktop daemon reached the real beta gate. Owned descendants were reaped, the installed profile was untouched, and completed test stages were removed after saved results. No unchanged sign-in retry follows.

The current real canonical plan was deliberately published with its verified agent PID. The managed descriptor reader accepts the companion schema. Neither proves fresh planning-model adoption. The shared reflex proposal validates but is not installed, pending the owner's decision. An in-process conversation reset cannot be detected from kernel identity; clear on fresh startup and before reset/end is required. Skipping clear can leave the old publication visible. Owner acceptance of that residual is pending.

Outstanding: authenticated Files → picker → rendered checklist; actual native remote-host child-PID correspondence (loopback SSH file reading is not that path); companion installation/fresh planning adoption; owner reset/reflex decision; fresh exact-head cross-family pass and0.5.0 rollout. Raw SSH without native Tern ancestry remains unsupported and must not be presented as qualified. Existing0.3.0 installation is separate. The related catalogue PR755 passed independent source review at db606a8; its protected-platform commander/release check remains required. No check was spoofed, protection bypassed, live catalogue mirror written or whole-platform release run.

```sh
python3 -m unittest discover -s tests -p todo_test.py
python3 tests/todo_smoke.py --published --evidence /absolute/private/evidence.json
# Requires an available authenticated UI:
python3 tests/todo_smoke.py --published --files-button --evidence /absolute/private/ui-evidence.json
# Launch only as a new owned native Tern program, with a new private work folder:
python3 -I tests/publication_probe.py --work-dir /absolute/private/probe-work
```

Use the documented supervisor and record source hashes and cleanup. Evidence lives with the canonical interactive PLAN; no private plan prose or credentials are bundled in this package.
