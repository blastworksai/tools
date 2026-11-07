# report-files-v1 wire contract

`codec.luau` is the maintained strict byte contract shared by ORCH+ and SPAWN. `sync.py` vendors it into exactly those two packages as `wire/codec.luau`; edit this source, not either copy. ORCH-only checkpoint, landing-proof, signer and scope policy lives in `plugins/tern/ORCH+/workflow_rules.luau`.

```sh
python3 shared/report-files-v1/sync.py
python3 shared/report-files-v1/sync.py --check
```

The codec owns strict JSON/UTF-8, closed schemas, hashes, canonical Base64, framing and capability validation. Native JSON parsing alone is not a substitute. Runtime origin, current authority and workflow authorization remain in their existing owners.

## Report assembly

ORCH+ owns persisted report assembly. `assembly_start(manifest_bytes, manifest_sha256, binding)` creates a bounded JSON-serializable prefix. `assembly_push(state, chunk_bytes, chunk_sha256, binding)` validates the arriving object and appends its Base64 slice without replaying prior chunks. Slices may split a UTF-8 character; only complete logical bytes are decoded as the report.

Final digest, schema and binding validation precede intake. ORCH+ commits its receipt cursor before publishing an ACK. A rejected complete message preserves its bytes for the rejection path. Restoring an assembly validates its prefix, hashes and size; the authority enforces four assemblies and the existing 64-KiB logical-message limit.

SPAWN reads only the requested validated mailbox object. It still assembles and validates an entire reply before publishing that reply's manifest. Staged authorization and durable active reads are unchanged.

## Verification

```sh
systemd-run --user --scope --collect --property=KillMode=control-group --property=RuntimeMaxSec=900s python3 shared/report-files-v1/tests/native_smoke.py --suites all --evidence /tmp/orchplus-suites.json
```

The runner executes ORCH+, SPAWN and shared-corpus cases in native Tern, with bounded cooperative callbacks and unchanged native callback budgets. `corpus.json` names valid/invalid byte cases and explicit helper-specific diagnostics. The POSIX and PowerShell helper suites consume the applicable corpus cases; framing/incremental assembly cases remain Luau-owned.

For actual report-path qualification, use `--scenarios reports` instead of `--suites all` and supply `--baseline-archive` with a verified archive of the pinned comparison source. It opens an ordinary isolated GUI, initializes actual authorities, launches a real managed deterministic report producer in a disposable repository, exercises staged authorization, rejects forged-origin/replayed authorization, checks cursor-before-ACK ordering and reloads with an outstanding immutable ACK. This is not provider-backed agent-workflow or final showcase proof.

Product measurements and component measurements are separate. Product counters include actual native helper launches, loaded-codec hash input bytes, incoming SPAWN bridge events and successful native KV writes during the same report-to-ACK interval. Shell-tool/native-internal hashes are excluded. Sequential samples and polling overhead do not establish a latency improvement.

The runtime isolates configuration, daemon/control endpoints, HOME and XDG state, and reaps its owned processes. Actual screenshot pixels must be inspected separately from configured theme slots. Ordinary native Appearance preferences can override simulated system appearance.
