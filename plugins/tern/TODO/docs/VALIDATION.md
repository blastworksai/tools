# TODO validation

## 0.8.0 native execute and setup

Blastworks.ai · 28 November 2026. Native Linux probes used Tern `0.9.22 (3fd4def)`, Claude Code `2.1.332` and Codex `0.172.0`. The checkpoint receipts below describe their tested sources and disposable environments. Rollout still requires the reviewed release head and target readback.

| Checkpoint source | Check | Observed result |
| --- | --- | --- |
| `e66f8acb37ef5d93e139ed2d6427266d2238ec13` | Focused Python source, process, publication and hook contracts | 40 passed, 2 platform skips. Tests covered exact inputs, repeated events, reset isolation and preservation of an existing binding on refusal. |
| `e66f8acb37ef5d93e139ed2d6427266d2238ec13` | Native Claude typed execute and `Skill` | Both published the same fixture through TODO discovery. Canonical bytes stayed unchanged. `/clear` removed the old session's binding in the same process. A shell wrapper left the native Claude parent verifiable. A `--print` run still had a terminal, so the adapter also checks launch mode. |
| `e66f8acb37ef5d93e139ed2d6427266d2238ec13` | Native Codex default launcher and `--no-daemon` | The exact `$glitch-execute` prompt published. Explicit read-only refused. Codex's TUI rejected `/glitch-execute`. `/new` left an idle gap and cleared the old binding at the first new input. `/quit` could then emit end events for both IDs. |
| `e66f8acb37ef5d93e139ed2d6427266d2238ec13` | Native Claude legacy plan | The hook returned a single scoped continuation with no plan edit and no active publication. The fixture added the agreed block. Claude's native Bash tool ran that exact continuation, and TODO discovery returned the active legacy plan. The provider exchange used a loopback mock. |
| `e66f8acb37ef5d93e139ed2d6427266d2238ec13` | Native Tern remote transport in a private loopback network | Codex published on the execution daemon. The connected client rendered the title and a checkpoint change through the explicit attach command. Canonical bytes stayed unchanged. This covers native transport and display through that command. |
| `45828491470117d915b71f86eba6dcc81159586f` | Python installer contracts | 10 passed. They covered install, upgrade, re-run, recovery, ownership, unrelated settings, unsafe targets and scoped rollback. |
| `45828491470117d915b71f86eba6dcc81159586f` | Native install, opt-in and forced update | Glitch off left setup inactive. An opted-in window installed the owned callbacks. The update preserved consent and verified a new staged generation. Fresh Claude panes published after install and update. Fresh Codex kept hooks inactive until native `/hooks` approval, then published through TODO discovery. Fixture bytes stayed unchanged. |
| `45828491470117d915b71f86eba6dcc81159586f` | Installed package on an isolated native remote host | The host set up the callback after opt-in. Native Codex published with unchanged plan bytes. The connected window showed the title and a checkpoint change through the existing attach command. Both ends ran in the same private loopback network. |
| One-pane candidate before the version bump | Native Luau contracts and SDK analysis | `todo_smoke.py --contracts-only` passed 120 checks on Tern `0.9.22` and reaped its owned processes. Luau-LSP `1.70.1` found no diagnostics in `host.luau`, `window.luau` or their imports using the generated Tern SDK. This covers controller contracts and static types. |
| One-pane candidate, `window.luau` SHA-256 beginning `535ab85925d6` | Real local status-bar click | The real **TODO** segment opened the local native board for one pane, opened the exact plan with a pane on another tab, and kept the selector for two panes on the same tab. **TODO: Open Settings** opened settings on a one-pane tab. The isolated daemon socket was gone at cleanup. |

The isolated ordinary Codex hook process stayed silent. The sample took a median of 41.5 ms and a maximum of 46.5 ms, including Python startup. The native packages ran in private configurations with owned process supervision. No production hooks, settings, credentials or provider work were used.

Automatic macOS and Windows setup, an independently deployed remote host, and a prestarted shared Codex app server remain separate qualification targets. A remote execution account owns its own setup and consent. The checked native remote transport used a disposable loopback host. The native remote status-click result belongs in the final plan receipt for the release candidate.

## Historical viewer and publication receipts (0.6.0–0.7.3)

Blastworks.ai · 9 November 2026. This receipt supersedes the older 0.5.x validation headings for the current TODO reliability lane. Earlier 0.5.0, 0.5.1 and 0.5.2 receipts are historical and are not carried forward as evidence for this source.

## Source and helper receipt

The immutable handoff is commit `ca8bebb4553e1338c7bf49844494f9d665af33fc`, based on `9f761f031154bd57e20391755a5c9fb675be9963`; its author receipt records version `0.6.0`. Integration preserves the owned updater work and adds the scoped review corrections below. No git command or runtime check was used during integration.

The following SHA256 values are the source-byte identities of TODO 0.7.3 as released on tools main (after the credit edit), needed for a later coordinated companion/plugin rollout:

| Helper | SHA256 |
| --- | --- |
| `bin/todo.py` | `c66f06d070a687b88e18869388601ef2546be68f0fda3ace9479d58c2cdecdd3` |
| `bin/publication.py` | `616c36dfe93e2cdad931f54d3fb90bfa853677fab66b650aa72e8f864da6c844` |
| `bin/process_identity.py` | `d4369444f152d199826a905ca29f8d0ce4bbe16d0549c2fe8dd5e7c5027c874f` |

These are source hashes, not installed-companion or installed-plugin readbacks. A later authorized rollout must compare all three companion and plugin helpers at the same reviewed head and refuse schema/version skew. Task 2C performed no companion copy, plugin install/link/reload, deployment, publication or other rollout.

### Integration review corrections

All three handoff helper hashes were checked against immutable incoming inputs. The handoff's `publication.py` hash was `e6baf830ab59504a942b75692fb05f4beccadc71a0915412bdbeefa5aeeceef1`; the integrated hash above differs because writer locks now reject extra hard links before any mode/ownership change, and Windows record reads validate ownership/DACL through `GetSecurityInfo` on the open handle before reading bytes. This reuses the existing account allowlist and ACE policy without weakening it. The path-only Windows security gap predates this handoff.

The handoff's `todo.py` hash was `3b4cc607b390b50adae74df9857378a455048a715ef947b348195bfe15e03489`. Its semantic-maximal fixture did not bound the wire envelope: validation preserves leading/trailing whitespace while checking stripped lengths. The corrected ceiling is `6 * 1048576 + 20 = 6291476` bytes. The canonical file is still limited to 1 MiB; ASCII JSON encoding expands each input byte by at most six, and schema validation permits only existing plan fields and bounded numeric/enum values. The success wrapper (`ok`, `plan`, punctuation and newline) adds exactly 20 bytes; no caller-controlled wrapper field exists. All received envelope bytes, including error text and any extra fields, face the same cap before decoding. Accepted strings are neither trimmed nor truncated. The padded non-ASCII roundtrip and actual ceiling-plus-one rejection passed in the selected CP1T batch below.

New regressions cover unchanged canonical bytes/mode for a hardlinked lock, rejected open-handle security before reading, handle closure, and the existing owner/DACL policy. Interpreter fixtures drop incidental exact probe counts while retaining one-shot helper results and no replay of publication/clear. These corrections were not exercised during integration; the selected Python corrections are now covered by the CP1T result below, while native interpreter and Windows gates remain open.

### CP1T closeout — selected Python and private CLI/filesystem proof

The initial 9 November closeout retained the integrated helper implementations; its `todo.py` hash was `9298427e80a45ac75375b09c79928240beb42ccddabe7b85608b15bacdda0349`. Review covered open-handle Windows ACL validation before `ReadFile`, single-link lock refusal before metadata mutation, the raw SSH ceiling with padded strings, handle closure, replacement-failure preservation, process/source identity and one-shot interpreter selection. The later bytecode correction below supersedes that helper hash, not the historical test receipt.

Deleted `Windows shims share the probe order and do not use PATH presence` from `tests/host_interpreter.luau`: source substring/order/count checks do not prove shim execution. The interpreter behavior and no-replay negative controls remain; actual CMD/PowerShell forwarding and fallback require the real Windows gate below.

After all three CP1 writers stopped, the owner ran this selected batch from the TODO package: **35 tests passed in 1.153 seconds; OK**. No full discovery or native publication probe was run.

```sh
env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=tests python3 -m unittest todo_test.SourceContract todo_test.ProcessIdentityContract todo_test.WindowsReadContract todo_test.PublicationContract
```

The actual `bin/todo.py template --title Qualification --step First` → `source --plan <owned-private-file>` roundtrip returned the identical generated plan ID, title and checkpoint. A real hardlinked lock was refused before entering the writer body; canonical bytes, mode, owner and group remained unchanged, and no publication was created. The owner holds the receipt privately. The owned throwaway fixture was removed after success. These checks made no network connection or publication into a real agent. The publication probe and `todo_smoke.py --contracts-only` remain separate supervised native operations; no install/link/reload or companion rollout occurred.

### Native Mac discovery and installed-helper immutability

Mac a12 exercised the actual Files-header hover, TODO button and picker, then failed discovery because the native publisher used the normal user cache while the host helper used the private test cache. Its exact verified pointer and newly-created empty lock were removed after the run; broader cache preservation was not established. No end-to-end Mac qualification is claimed.

That run also created two helper bytecode files inside the installed plugin. The shared CLI entrypoint now sets `sys.dont_write_bytecode` before importing its helpers. Actual Mac CLI-only discovery with Python `-I`, without `-B`, preserved exact writable-install membership and bytes. The full isolated Python suite passed **38 tests** after supplying a private OS identity fixture required by offline OpenSSH configuration expansion; the earlier runner failure remains retained, and the fixture was removed. Neither result qualifies native pane environment forwarding or the GUI.

The owner holds these receipts privately: `cp2m-adapter-a12-receipts-20261109.json`, `cp2m-a12-external-pointer-cleanup-20261109.json`, `cp2m-a12-installed-package-delta-20261109.json`, `cp1t-bytecode-actual-mac-cli-smoke-20261109.json`, and `cp1t-bytecode-isolated-regression-suite-with-identity-20261109.json`.

Mac a15 subsequently **passed the selected cold publication/discovery and native checkpoint-refresh case** against the corrected helpers. The actual durable publisher and host reader used the reviewed private roots, the real Files-header button/picker selected the plan, and the rendered rows changed to a completed first checkpoint and current second checkpoint. The retained 1280×800 native screenshot was viewed and matches the machine readback. Installed/source/input preservation, the specified production-preservation projection, original deadline, observed-owned-zero and endpoint cleanup passed. This is a selected real-GUI case, not a full Mac, connected, provider or estate qualification.

The owner explicitly allowed normal account login-shell/profile startup before private worker binding; that startup is outside the isolation/preservation claim. Mac process observations remain sampled, not Windows-style cumulative kernel containment. A12 remains failed. A14 reached the selected behavior but failed the driver's missing named-check result contract; the corrected driver supplies actual named witnesses rather than weakening the common acceptance gate.

Additional private evidence: `cp2m-adapter-a15-receipts-20261109.json`, `cp2m-a15-todo-visual-acceptance-20261109.json`, `cp2m-a15-todo-refreshed.png`, and `cp2m-normal-account-startup-consent-20261109.json`.

### Native Windows cold case and retained-exit correction — 11 November

Windows B243 passed the selected cold publication/discovery case: real Files selection, publisher/host private-root agreement and canonical checkpoint refresh without republishing. Its dark1920x1200 screenshot was hash-verified and visually inspected. Named-file preservation and all owned cleanup passed. The batch itself failed at the second case because the harness retained the first case's TODO panel; three later cases did not run. This is a scoped cold-case pass, not full Windows acceptance.

A separate headless native check reproduced a retained-exit defect in the previous process helper: an exited child with an open native handle was classified unknown when Toolhelp omitted its parent. The current helper checks handle-bound exit time first. The same actual-child smoke now raises terminal `ProcessEnded`; live handles with missing parent evidence still remain unknown. Native `ProcessIdentityContract` ran10 tests in0.043seconds:9 passed,1 Linux-only case skipped. Source hashes were verified on the Windows machine and the throwaway fixture was removed. The later B256 GUI process-replacement case passed at the scope recorded below.

Private evidence: `cp2w-b243-scoped-cold-pass-20261111.json`, `cp2w-todo-retained-exit-native-20261111.json`, `cp2w-todo-retained-exit-fixed-native-20261111.json`, `cp2w-todo-exit-fix-contract-tests-20261111.json` and `cp2w-todo-exit-fix-cleanup-20261111.json`. B243 used the preceding helper hash; its cold live-process path is unchanged by the added definitive-exit classification, but it does not qualify that new exit path.

### Native view rendering correction — 11 November

Windows B251 exposed a blank error region despite a successful component-state check. Tern renders only a block-region root's children; the previous error checklist and loading text were childless roots. Both now use the same container convention as the normal plan. The native refusal driver additionally requires the expected diagnostic in the unique TODO panel's rendered tree; B256 subsequently exercised the corrected Windows process-replacement and owned-panel cleanup paths.

The actual current view module was exercised in a private Linux daemon and Xvfb-backed Tern window. Three native-host contract tests passed. Hash-verified, visually inspected screenshots show the error and its reason without stale checkpoints, the loading message, and the unchanged current blocked checkpoint with its reason. Actual native state and all three screenshots verified Dark/Obsidian/Solid. Owned processes reached zero, private and tracked X11 endpoints were removed, and the passive production projection was unchanged.

Private acceptance: `todo-view-native-window-visual-acceptance-20261111.json`, backed by `todo-view-native-window-smoke-v3-20261111.json`. This qualifies the view renderer only, not Windows/macOS lifecycle behavior, deployment or full ORCH+. Earlier smoke attempts remain failed/unaccepted: shot-only mode did not load the host plugin; the first native-window attempt hit an exit-during-cleanup race; another captured a late welcome dialog rather than unobscured product pixels. The final run waited for and dismissed the actual welcome dialog before selecting native Dark and capturing the view.

### Native Windows process-replacement pass and sharing failure — 11 November

B256 passed `todo/process-identity`: the old publisher binding became terminal, replacement did not inherit the stale publication, the native error was readable, and owned-panel cleanup completed before the next case began. The dark1920x1200 screenshot was hash-verified and visually inspected. Private receipt: `cp2w-b256-scoped-process-pass-20261111.json`.

The batch failed in `todo/windows-sharing` when a real second publish returned WinError5 Access denied from `os.replace` while the actual product reader was held open after native ACL validation. This is unresolved native replacement behavior, not a sharing pass. Clear-while-alive and restored-source-ID cases were not-run. All three native Owners reached zero remaining processes, counts matched, endpoints and the exact temporary task were removed, and the ordinary outer task's final named-file preservation check passed. The aggregate batch remains failed; the selected process case is not full Windows or TODO qualification.


## Current 2A/2B source review

The repaired source establishes these contracts:

- Linux publication metadata uses `0751` directories and `0640` records/locks with the existing `agents` group where available. macOS publication metadata is owner-only `0700`/`0600`, including an explicit inventory/migration of legacy metadata. Windows uses protected per-user ACLs. Canonical-plan modes are never changed by these paths.
- Linux multi-account viewing still requires native process inspection plus host access to the canonical plan and every ancestor. Readable pointer metadata alone cannot make a plan viewable. macOS/Windows discovery is restricted to the current owner's store; solo-Mac/solo-Windows and the existing Linux estate are the current targets unless later evidence expands them.
- Metadata reads and mode changes use no-follow opens plus checks on the actual open descriptor/handle. Ownership, object type, link count and object identity are revalidated where needed. A pre-created namespace symlink cannot redirect permission changes to its target or alter canonical-plan modes.
- Pruning a different record takes that candidate's own writer lock and then reads and validates the record again. A cooperating writer that updates the different record before revalidation is not deleted using the earlier observation.
- TODO's Windows metadata reader requests read/write/delete sharing so its own open read does not prevent replacement, inspects the open handle and closes it on success and failure. This currently has mocked unit coverage; real Windows qualification remains open.
- If the final replacement operation fails, including a simulated sharing violation, the previous valid publication remains in place and temporary files/handles are cleaned up. A failed replacement is not treated as a successful new publication that should be retracted.
- Initial discovery treats process-access/unknown failures as nonterminal: the error remains visible, polling continues and a later successful discovery recovers the selected plan. A real initial `ProcessEnded` instead emits `terminal=true` and exits rather than retrying. The Luau fixture covers both paths and uses captured real helper output for the terminal case, but remains unrun until ORCH+ coordination.
- Process identity is tri-state: live, definitively ended/changed, or inaccessible/unknown. Only ended/changed is terminal. Permission, enumeration and other access errors remain visible and nonterminal; real PID, parent, owner or birth mismatches are not retried as transient.
- The direct-SSH response ceiling is derived from the existing raw canonical byte limit, worst-case JSON expansion and fixed envelope overhead, not stripped semantic field lengths or a 64 KiB assumption. It preserves accepted padded/non-ASCII strings without increasing the canonical file limit.
- The host and Windows shims probe `py -3`, then `python`, then `python3`. A successful Python 3 probe selects one interpreter; helper errors and mutating commands are not retried through another interpreter. Store alias output is not a valid version probe.
- In-process conversation reset remains invisible to the process binding and requires explicit clear. Multiple native windows claiming the same TODO panel produce an ambiguity error and fail closed. Harnesses without the Claude-specific entry wiring require explicit companion publication.

## Author handoff evidence — before integration corrections

### Python unit suite

From `plugins/tern/TODO`, with bytecode writing disabled:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p todo_test.py
```

Author-recorded handoff result: **34 tests passed; OK** on Linux. That historical full-suite result precedes the integration corrections; the current selected 35-test result is recorded separately above.

The suite covers canonical parsing and byte immutability, CLI errors, synthetic SSH argv/trust/forwarding boundaries, a bounded non-ASCII SSH envelope and overflow refusal, tri-state process identity, Windows snapshot error handling and shared-read/handle mocks, POSIX metadata modes/macOS migration fixtures, symlink mode preservation, replace-failure preservation and handle closure, different-record writer lock/revalidation, same-record observed-revision cleanup, nonterminal access failure, terminal identity changes and workflow-entry payload boundaries. The OpenSSH-specific check uses `ssh -G` with a synthetic configuration; it makes no remote connection. Windows API behavior exercised through mocks is not real Windows evidence. The corrected padded-string roundtrip and raw-ceiling-plus-one cases passed in the current selected CP1T batch, not the author's historical 34-test result.

### Linux native publication probe

The author recorded a fresh run as an owned native Tern program with private fixture metadata completing **13 checks, all passed** on Linux, before the integration corrections:

1. Native publication, discovery and read preserve canonical bytes.
2. Linux `agents` metadata modes are applied.
3. A readable but unsafe matching store is an error.
4. An untraversable unrelated namespace cannot disable valid discovery.
5. Plain-file and cyclic-link entries are not accepted as namespaces.
6. A pre-created namespace symlink cannot change its target directory or canonical-plan modes.
7. A forged-owner namespace cannot interfere with the exact session key.
8. Republish and clear survive a native process-name change.
9. Competing writers on the same record serialize, and a failed old writer cannot retract the later success.
10. Same-plan republish has no missing-record window during validation.
11. A reader-open replace failure preserves the previous valid publication, and a `finally` assertion on the exception path proves `reader.closed`.
12. Changed and failed publications cannot retain stale success.
13. Clear removes the binding while the selected program stays alive.

The separate 34-test unit suite, not this 13-check probe, contains the deterministic different-record competing-writer lock/revalidation case. The probe supplies native Linux process/filesystem evidence only. It is not a Luau contract run, native connected daemon/window run, real remote-client result, real macOS result or real Windows result.

## Integrated-source component checks

On 9 November 2026, luau-lsp 1.70.1 analysis of `host.luau` and `window.luau`, including their imported modules, passed against the generated target Tern definitions. `host_selection.RunOptions` now reflects native optional process fields; discovery outcomes require a source only for `active`, and an error only for `retry`/`terminal`. This is static contract evidence, not native interpreter, process, GUI or platform acceptance.

The selected `host_interpreter` and `host_selection_test` fixtures passed all 11 named cases in a private native Tern host, with unchanged source snapshots, owned processes/endpoints removed and production unchanged. They exercise interpreter choice, one-shot helper results, discovery recovery and stale callback/process binding using the fixtures' existing mocked external effects. The first fixture attempt was rejected before loading because its generated plugin ID exceeded Tern's 32-character bound; that failed receipt is retained. This selected pass does not close the full native suite, real Python discovery, local/SSH UI or Windows gates below.

## Open gates at this head

The selected Mac cold-publication, Files/picker and checkpoint-refresh case passed as recorded above. The broader gates below remain open for the integrated source. The author-recorded Linux publication probe must also be repeated against the corrected helper under separately authorized native-slot coordination; no earlier failed result is relabelled.

| Gate | Required evidence still outstanding |
| --- | --- |
| Native Luau contracts | Run `python3 tests/todo_smoke.py --contracts-only --evidence <new-private-evidence.json>` after ORCH+ native-slot coordination. This includes `tests/native_suite.luau` and `host_interpreter.luau`: interpreter fallback, Store stubs, one-shot helper results, initial nonterminal discovery remaining visible and recovering, and initial `ProcessEnded` producing `terminal=true` and exiting. The fixture's terminal case uses captured real `todo.py discover --parent-pid 999999999` output with an isolated absent publication root; captured output does not make the unrun Luau fixture a pass. Shim source inspection has been removed; actual shim behavior belongs to the real Windows gate. |
| Native local/SSH connected suite | Run `python3 tests/todo_smoke.py --published --evidence <new-private-evidence.json>` in the coordinated private runtime. Mac a15 covers one real local cold-publication/refresh route; the full suite, SSH views, source-id change refusal, restored identity, clear while alive, no-plan behavior and process replacement remain outstanding. |
| Native Files/picker UI | Mac a15 passed the actual Files-header hover, TODO button, picker, publication, rendered checkpoint refresh and specified preservation checks. Other required platform/client routes remain outstanding; a12's earlier discovery failure remains retained. |
| Multi-window behavior | Exercise two real native windows and prove ambiguous panel membership refuses attachment without choosing a source. The source fails closed, but current-head native acceptance is outstanding. |
| Linux estate multi-account viewing | On the existing estate, prove process inspection, `agents` metadata readability, canonical-plan readability and every ancestor's traversal together. Include inaccessible-process nonterminal behavior. The private 13-check Linux probe is not estate acceptance. |
| Real macOS | Mac a15 passed the selected private cold-publication/refresh route with viewed native visuals. Owner-only metadata migration, descriptor-based no-follow protections, native process identity/access failures, restored viewing and clear/source-id refusal still need their selected native cases. Normal account startup is explicitly outside isolation/preservation; downstream worker roots remain private. Cross-account stores remain out of scope unless new evidence and a later decision expand the target. |
| Real Windows | Run the native publication probe and qualify sharing reads, replace failures and handle closure on real Windows, plus `py`/`python`/`python3` fallback, Store aliases, CMD/PowerShell shims, protected ACLs, process identity/access failures, solo-account local and attached remote-Linux viewing, clear/source-id refusal, restored views and actual client visuals. Cross-account stores remain out of scope unless new evidence and a later decision expand the target. No real Windows ran. |
| Conversation and harness acceptance | Prove explicit clear around a real in-process conversation reset and fresh startup. Prove explicit companion publication on each non-Claude harness; no automatic adoption is claimed for unwired harnesses. |
| Coordinated companion/plugin rollout | Compare installed companion and plugin helper hashes, qualify companion adoption and repeat the required native/real-client checks after an authorized rollout. This task recorded source hashes only and did not roll out anything. |

## Preserved limitations and disqualifying workarounds

### Non-atomic same-record cleanup race

`publication._retract_observed` reads and compares the current record identity/revision and then calls `unlink`. The native writer lock excludes cooperating writers, and different-record pruning now locks and revalidates each candidate. Neither repair makes the final same-record check-to-unlink sequence an **atomic compare-delete** against outside or non-cooperating writers. Such a writer can replace the target after the check and before the unlink, causing that newer replacement to be removed. This narrowed race is intentionally preserved and disclosed; no atomicity or total outside-writer safety is claimed.

### Account, path and transport boundaries

Linux group-readable metadata does not grant process inspection or canonical-plan access. Both are independently required. Never make viewing work by copying plans, automatically changing plan/ancestor permissions or forwarding Tern/agent sockets. Raw SSH without native Tern ancestry remains unsupported, and no secondary SSH login, copied credential or socket-forwarding workaround is allowed.

macOS and Windows publication stores are owner-only and cross-account viewing is not claimed. Inaccessible process inspection is a visible nonterminal unknown, not proof of process exit; initial discovery can recover after that unknown clears. An in-process conversation reset without explicit clear can leave the old publication visible until clear or process exit. Multi-window ambiguity fails closed. These limitations require honest UI/rollout evidence and must not be converted into silent fallback behavior.

## Historical status bar, schema 2 and board sync

`python3 -m unittest discover -s tests -p todo_test.py` covers schema 1 and 2, every entity kind and state, rename and reorder, duplicates, bounds, malformed nesting, maximal Unicode and the static window contract. `python3 tests/todo_smoke.py --contracts-only` runs the Luau suites (plan view, board projection, settings, attach, host selection) inside a real Tern host. The full `todo_smoke.py` run also opens the TODO Settings pane through its command and asserts that no Files-pane button exists. Not yet exercised against the real engine: clicking the status segment itself, the Markdown board file format Tern's board accepts for the managed board, and two windows syncing the same plan at once.
