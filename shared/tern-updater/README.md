# Tern plugin updater

Shared code that lets a Tern plugin from this repo update itself from GitHub. Each plugin gets two palette commands (window half only; no `host.luau` changes):

- **`<PREFIX>Check for updates`** fetches the published `plugins/tern/<DIR>/plugin.toml` from `main` and says whether a newer version exists. A background check also runs at most every 6 hours and only announces a new version once.
- **`<PREFIX>Update`** (shown only when an update is known) re-checks, checks the release's `requires.json`, asks in a picker (optionally "here and on `<host>`" for connected remote hosts), then runs `tern plugin install --force --json github.com/blastworksai/tools/plugins/tern/<DIR>` with the running Tern executable.

## Rules

- **Never auto-installs.** Installing only happens after you choose an Update option in the picker. Background checks only notify.
- **Dev copies are never touched.** A linked checkout (`tern plugin link`, i.e. `<plugins>/<id>.path` exists) gets no background fetch and no Update command; `git pull` it yourself.
- **Reloads affect everything.** Any install reloads every plugin on that machine, linked ones included. When ORCH+ is loaded the confirm text and success notice say: "Running ORCH+ controllers pause until you run ORCH+ Reload recovery guide". A pending journal in `tern.kv` lets the reloaded plugin report the result.

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

   `dir` must be the folder name under `plugins/tern/`. `title_prefix` is optional (default `name .. " "`). The line must contain `require("./updater/window").register(` verbatim: `sync.py` and `tests/test_vendored.py` find integrated plugins by it.
2. Run `python3 shared/tern-updater/sync.py <DIR>` to vendor the eight modules into `plugins/tern/<DIR>/updater/`. Never edit vendored copies; edit here and re-run `sync.py` (no DIR = every integrated plugin).
3. Add the snippet below to the plugin's README with `<PREFIX>`/`<DIR>` filled in.
4. Bump `version` in the plugin's `plugin.toml`.
5. Optionally add `requires.json`.

## Release

Bump `version` in the plugin's `plugin.toml` on `main`: that is the signal every installed copy checks. `requires.json` must change in the same commit as any CHANGELOG "Requires X" line, so a release never ships without the requirement it announces.

## README snippet

```markdown
### Update

Run **<PREFIX>Check for updates** from the command palette. When a newer version is on GitHub, **<PREFIX>Update** installs it in place: it checks the release's requirements and asks first, and can also update connected remote hosts. Tern then reloads all its plugins, and your settings carry over. If ORCH+ is running a controller, run **ORCH+ Reload recovery guide** afterwards.

A copy installed before the updater existed needs one manual update:

    tern plugin install --force github.com/blastworksai/tools/plugins/tern/<DIR>

A linked development checkout (`tern plugin link`) is never updated by the plugin; `git pull` it yourself.
```

## Tests

```sh
# vendored copies, register lines, manifests, requires.json
python3 -m unittest discover -s shared/tern-updater/tests -p 'test_*.py' -v
python3 shared/tern-updater/sync.py --check

# pure-module suite and end-to-end run in an isolated Tern
systemd-run --user --scope --collect --property=KillMode=control-group --property=RuntimeMaxSec=120s python3 shared/tern-updater/tests/updater_smoke.py --suite-only --evidence /tmp/updater-suite.json
systemd-run --user --scope --collect --property=KillMode=control-group --property=RuntimeMaxSec=900s python3 shared/tern-updater/tests/updater_smoke.py --evidence /tmp/updater-e2e.json
# add --plugin plugins/tern/<DIR> (RuntimeMaxSec=180s) to smoke one integrated plugin
```
