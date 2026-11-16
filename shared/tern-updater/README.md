# Tern plugin updater

Shared code that lets a Tern plugin from this repo update itself from GitHub. The window owns update decisions and its per-incarnation file journal; the host handles legacy host-owned state migration. Each plugin exposes these palette commands:

- **`<PREFIX>Check for updates`** fetches the published `plugins/tern/<DIR>/plugin.toml` from `main` and says whether a newer version exists. A background check also runs at most every 6 hours and only announces a new version once.
- **`<PREFIX>Update`** (shown only when an update is known) re-checks, checks the release's `requires.json`, asks in a picker (optionally "here and on `<host>`" for connected remote hosts), then runs `tern plugin install --force --json github.com/blastworksai/tools/plugins/tern/<DIR>` with the running Tern executable.
- **`<PREFIX>Resolve update outcome`** inspects retained outcomes without replaying an install. A live owner or positively running installer blocks takeover. Missing completion evidence stays unknown; explicit resolution is not an update-success claim.

## Rules

- **Never auto-installs.** Installing only happens after you choose an Update option in the picker. Background checks only notify.
- **Dev copies are never touched.** A linked checkout (`tern plugin link`, i.e. `<plugins>/<id>.path` exists) gets no background fetch and no Update command; `git pull` it yourself.
- **Reloads affect everything.** Any install reloads every plugin on that machine, linked ones included. ORCH+ reconnects automatically after reload; genuinely unresolved ownership or interrupted operations remain paused with recovery guidance. An install callback can disappear during reload: exit status, installed version, daemon/catalog health, current window registration and actual installed requirements are separate evidence.
- **Default-branch previews are not pins.** The confirmation previews a version; Git installs the default-branch tip at execution. A different installed version is not reported as that preview's success.
- **Uncertainty holds ownership.** Each window writes its own journal before external commands. Claims scan all retained records; advancement and removal require matching record bytes and native owner identity. Corrupt, replaced or ambiguous records remain visible. Legacy host state is removed only through the host migration acknowledgement, not by a window writing `tern.kv`.
- **No invented process completion.** Missing callbacks, incomplete process inventories and ambiguous remote completion do not prove the installer stopped. An explicitly attested stopped operation may be resolved as **unverified**; a positively live operation cannot be overridden.
- **Live callback proof stays in memory.** Only the current registration's exact completed-install object proves that its native callback completed. Persisted clock labels cannot establish VM identity after reload; a timeout never supplies this proof.
- **Interrupted resolver cleanup preserves the original attempt.** A retained resolver may name an intermediate resolver already removed by an earlier cleanup. Follow its captured bytes only after a complete inventory proves that file absent, and only when the reconstructed record and filename/owner identity validate. Unreadable present files, changed bytes, malformed records, cycles and unrelated claims still block cleanup. An explicitly unknown leaf contributes no invented upstream history. This cleanup neither recreates missing records nor authorizes another install.

## Non-goals

- Linked/dev checkouts are never modified (no `git pull`).
- The first update after this ships is manual for copies installed before the updater existed: run `tern plugin install --force …` once per plugin per machine; after that the palette does it.
- Remote hosts are updated only when connected and chosen in the picker, and only on hosts whose login shell has `tern` on `PATH` (the opened shell shows the result).
- No new-plugin discovery and no pinning to tags (Tern installs the default-branch tip).

## `requires.json`

Optional, next to the plugin's `plugin.toml`:

```json
{ "schema": 1, "tern": "0.9.8", "plugins": { "spawn": "0.3.1" } }
```

`tern` is the minimum Tern version; `plugins` maps plugin ids to minimum versions. Both are optional; versions are SemVer. If a requirement isn't met, Update stops with a message such as "Update spawn to 0.3.1 or later first (you have 0.3.0)" and shows no picker.

## Add to a plugin

1. In the plugin's `window.luau` add, on one line:

   ```lua
   require("./updater/window").register({ name = "SPAWN", dir = "SPAWN", title_prefix = "SPAWN " })
   ```

   `dir` must be the folder name under `plugins/tern/`. `title_prefix` is optional (default `name .. " "`). The line must contain `require("./updater/window").register(` verbatim: `sync.py` finds integrated plugins by it.
2. In `host.luau`, register `require("./updater/host").register()`. Add the hidden host recovery block to `plugin.toml`:

   ```toml
   [[blocks]]
   id = "updater-recovery"
   name = "Updater recovery"
   hidden = true
   ```

3. Run `python3 shared/tern-updater/sync.py <DIR>` to vendor the fourteen modules into `plugins/tern/<DIR>/updater/`. Never edit vendored copies; edit here and re-run `sync.py` (no DIR = every integrated plugin). The pure `discovery.luau` module is also used by SPAWN and TODO; their runners retain their own deadlines and environment routing. `shell.luau` is generated from SPAWN's reviewed shell serializers.

   The extraction runs from `local Backend = {}` to the mailbox-adapter boundary in `SPAWN/backend.luau`. Keep SPAWN-only setup helpers and their constants below that boundary: the generated updater module has no SPAWN `Config` dependency. Run `sync.py --check` after editing this region; unchanged serializers should leave the canonical module and all five vendored copies byte-identical.
4. Add the snippet below to the plugin's README with `<PREFIX>`/`<DIR>` filled in.
5. Bump `version` in the plugin's `plugin.toml` beyond the integrated published version.
6. Optionally add `requires.json`.

## Release

Bump `version` in the plugin's `plugin.toml` on `main`: that is the signal every installed copy checks. `requires.json` must change in the same commit as any CHANGELOG "Requires X" line, so a release never ships without the requirement it announces.

## README snippet

```markdown
### Update

Run **<PREFIX>Check for updates** from the command palette. When a newer version is on GitHub, **<PREFIX>Update** installs it in place: it checks the release's requirements and asks first, and can also update connected remote hosts. Tern then reloads all its plugins, and your settings carry over. ORCH+ reconnects automatically; unresolved ownership or interrupted operations remain paused with a specific recovery action.

The preview is not a pinned commit. After installation the updater checks the actual package, requirements and load evidence. If reload or missing process evidence leaves the outcome uncertain, use **<PREFIX>Resolve update outcome**: it never repeats the install. Explicitly resolving an uncertain outcome does not certify success; a running installer cannot be overridden.

A copy installed before the updater existed needs one manual update:

    tern plugin install --force github.com/blastworksai/tools/plugins/tern/<DIR>

A linked development checkout (`tern plugin link`) is never updated by the plugin; `git pull` it yourself.
```

## Tests

```sh
# behavioral manifest/requirements checks; sync owns vendored-byte verification
python3 -m unittest discover -s shared/tern-updater/tests -p 'test_*.py' -v
python3 shared/tern-updater/sync.py --check

# Native contracts: select only affected groups when preserving earlier passes.
systemd-run --user --scope --collect --property=KillMode=control-group --property=RuntimeMaxSec=120s python3 shared/tern-updater/tests/updater_smoke.py --suite-only --suite-groups observe,remote --evidence /tmp/updater-contracts.json

# One selected real-Git GUI scenario, with private HOME/config/socket and owned descendants.
systemd-run --user --scope --collect --property=KillMode=control-group --property=RuntimeMaxSec=900s python3 shared/tern-updater/tests/updater_smoke.py --case git --evidence /tmp/updater-git.json

# One actual integrated consumer, never the production installation.
systemd-run --user --scope --collect --property=KillMode=control-group --property=RuntimeMaxSec=900s python3 shared/tern-updater/tests/updater_smoke.py --case consumer --plugin plugins/tern/WORK --evidence /tmp/updater-work.json
```

The runner requires an explicit case or `--suite-only`; it does not implicitly run every scenario. Cases include default-branch tip movement to newer or older versions, pre/post-install requirements, callback loss, native timeout before and after actual replacement, corrupt/legacy records, development links, competing windows, owner loss, interrupted resolver cleanup, missing daemon/Git, clone failure and host/window load failures. Interrupted recovery selects the visibly labelled `resolving` record, not the original `pending` attempt when their positional window names match. GUI cases need an exclusive native GUI slot. The private Git fixture uses a bare default-branch origin through loopback `git daemon`, with no production Git configuration changes.

The competing-window case waits for both real confirmation surfaces before the first claim, then proves that the second acceptance and live-owner resolution cannot take over the admitted install. Consumer cases exercise ORCH+, SPAWN, USAGE, TODO and WORK independently; their private preview-version increments are not release bumps. Palette availability checks preserve punctuation across native highlighted spans, including `SPAWN:` and `TODO:`.

Receipts retain source, journals and failure captures and report descendant cleanup and production-state checks. An incomplete native process inventory may leave a real, correctly installed package unverified. The Git scenario then proves its own installer process incarnations ended before exercising explicit unverified resolution; it does not relabel missing native evidence as verified success.

### Evidence boundaries

Local native Git, reload and competing-window receipts qualify their exercised routes only. An installed version, a healthy host catalog and this window's fresh registration are separate observations; none proves every window, remote host or ORCH workflow healthy. Retained passes remain tied to their source hashes. Unchanged updater modules can retain that evidence without repeating unrelated scenarios; changed consumers still need their affected integration checks.

The `resolution` component group exercises interrupted nested cleanup through the real state/journal functions, including absence-versus-unreadability and exact-byte claim guards. It does not exercise the native resolution picker or an interrupted installation; those affected window paths still require coordinated native acceptance.

The November 2026 type-contract repairs preserve valid hexadecimal owner-name decoding and pass only the UTF-16 payload, not its optional error return, to native `base64.encode`. The owner-name round-trip/refusal smoke passed in Luau 0.746; the selected SPAWN backend suite passed 1,979 checks in the native Tern host. These are serializer/component results, not Windows process forwarding, an installer run or an integrated consumer acceptance. The generated copies still require `sync.py --check`.

Remote acceptance requires an independently observed target: current host identity, the exact terminal pane and submitted command, reliable completion, bounded installed metadata, and that target's requirements/load evidence. A missing or reassigned pane is not process completion. Unsupported or ambiguous preflight refuses before mutation; losing evidence after an install starts retains uncertainty and never retypes the install. Local fixtures, serializer/argv checks and historical deployments are not substitutes for this per-host proof.

Native hook-budget or filesystem stalls do not authorize larger budgets, a second install or a success claim. Preserve the pending record and failed receipt. A later successful scenario or RAM-backed functional check does not establish that an ordinary-disk persistence failure was fixed. Final release verification must keep those limits, unknown-pane coverage and unavailable independent-host qualification explicit.
