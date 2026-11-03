---
name: tern-plugin-development
description: Create, test, debug, and package Tern plugins. Use for requests to build a Tern plugin, add a block/lens/window command, type-check Luau against Tern, isolate a plugin test daemon, or diagnose plugin reload and UI failures.
license: MIT
---

# Tern plugin development

Build against the official Tern Plugin SDK documentation first. Tern is a Luau
plugin runtime with two separate halves, not one script with optional callbacks.
Keep the package boring, the pure logic testable, and integration tests isolated
from the user's real daemon.

## Non-negotiable workflow

1. **Choose the half before choosing the API.**
   - `host.luau` runs in the session daemon (or the process that owns panes). It
     owns blocks, command lenses, host hooks, the spawn filter, and pane writes.
   - `window.luau` runs once per Tern window on the UI thread. It owns commands,
     binds, overrides, routes, chrome, Files-pane buttons, CSS, layout, and
     window events.
   - The halves have separate Luau VMs and do not share Lua state. Communicate
     through Tern's persisted state, files, panes, or the catalog only when that
     is actually part of the design.

2. **Start from a valid package.** Put `plugin.toml` at the package root:

   ```toml
   schema = 1
   id = "example"
   name = "Example"
   version = "0.1.0"
   description = "Short, one-line description."
   host = "host.luau"       # omit when window-only
   window = "window.luau"   # omit when host-only
   ```

   Use a lowercase id beginning with a letter, containing only lowercase
   letters, digits, and `-`, at most 32 characters. Keep ids unique on the
   test machine. Declare every `[[blocks]]` and `[[lenses]]` in the manifest;
   define each one in the host entry. Order lens match patterns from most to
   least specific. Keep runtime state and build output out of the package root:
   Tern watches linked packages and reloads when anything in them changes.
   Store mutable data under `tern.plugin.data` or in `tern.kv`. A generated
   `tern.d.luau` is a development artifact, not runtime state; prefer writing
   it to a sibling directory such as `../tern-api` and point the editor there.
   If you intentionally keep it in the package, expect every regeneration to
   trigger a reload and do not treat it as a shipped runtime dependency.
   Do not put generated files or build output in a released package unless the
   package's distribution policy explicitly requires them.

3. **Generate the shipped API definitions before coding.** Run:

   ```sh
   tern plugin types ../tern-api
   ```

   This writes `../tern-api/tern.d.luau`, the complete API declaration file
   for the installed Tern. Read `tern.d.luau` before coding; the current file
   is roughly 2,000 lines and is the most concrete contract for the binary you
   are targeting. Regenerate it after upgrading Tern. Put `--!strict` on the
   line of each checked Luau entry/module, then configure luau-lsp with the
   standard platform and the definition file:

   ```json
   {
     "luau-lsp.platform.type": "standard",
     "luau-lsp.sourcemap.enabled": false,
     "luau-lsp.types.definitionFiles": { "@tern": "../tern-api/tern.d.luau" }
   }
   ```

   The same check can run headlessly from the package directory. Pass only
   entry files that exist; this host-only example checks `host.luau`:

   ```sh
   luau-lsp analyze --platform=standard \
     --definitions=@tern=../tern-api/tern.d.luau host.luau
   ```

   Add `window.luau` to that command for a package with a window entry.

   Use the global `tern` in source. `require("tern")` works at runtime but
   luau-lsp reports it as an unknown require. Treat the generated definitions
   as versioned API evidence, not as a license to call members from the wrong
   half: the definition file declares both contexts, while wrong-context
   members are absent at runtime.

4. **Link for development, install for release.**

   ```sh
   tern plugin link /path/to/plugin
   tern plugin reload example --json
   tern plugin list --json
   ```

   `link` watches the source directory and reloads on save. This command is
   for interactive development against the selected daemon; automated tests
   must use the isolated environment in the next section. `reload` is the
   meaningful load check when a daemon is running; it exits nonzero for a
   failed host plugin or folder problem. `plugin list` is a catalog view, not
   proof that the window half loaded. Release packages have `plugin.toml` at
   their install root and are installed with `tern plugin install SRC`.

## Keep logic pure


Put parsing, normalization, sorting, view-model construction, and state
transitions in Luau modules that do **not** read the `tern` global. Give those
modules plain inputs and return plain values. Keep the thin entry files
responsible for Tern registration, effects, timers, process calls, and I/O.
This makes the core runnable with the standalone `luau` CLI and keeps tests
fast; a useful target is hundreds of deterministic checks in milliseconds.

Use a small fake JSON implementation in pure-module tests when the module
serializes or decodes Tern data. It must reproduce Tern's real edge cases:
`tern.json.decode` drops object members whose value is JSON `null`, preserves
`null` inside arrays as `tern.json.null`, and tags decoded arrays so empty
arrays remain arrays when re-encoded. An ordinary JSON library can therefore
hide a Tern bug. Test empty arrays, missing fields, explicit nulls, and false
values separately.

Do not make pure modules discover Tern through globals, hidden `require`
side effects, or test-only fallbacks. Inject clocks, filesystem readers,
process results, and JSON functions at the boundary. Keep handlers within
Tern's budgets: host calls have a 2 s budget; most window calls have 50 ms and
chrome formatters have 4 ms.

## Isolated integration testing

Never reload the user's real Tern just to test a plugin. A disposable
container/VM or a descendant-owning process supervisor is **REQUIRED** for the
whole sequence: `tern plugin dir`, `tern plugin link`, the controlled window,
every `tern ctl`, and `tern plugin reload`. `TERN_CONFIG_DIR` and
`TERN_DAEMON_SOCKET` isolate files and sockets; the supervisor prevents the
test daemon from becoming an unmanaged process.

On Linux, one option is `systemd-run --user --scope --wait --collect`; use the
equivalent container or supervisor on another platform. If no such boundary is
available, stop rather than backgrounding Tern and killing only `$!`.

Run a test script like this as one supervised unit:

```sh
#!/usr/bin/env bash
set -euo pipefail

scratch="${1:?pass a scratch directory}"
TEST_PLUGIN_ID=session-list-test
TEST_PLUGIN_DIR="${TEST_PLUGIN_DIR:?set the distinct test-package path}"
TEST_EXPECTED_TEXT="${TEST_EXPECTED_TEXT:?set expected plugin tree text}"
TEST_EXPECTED_WINDOW_LOG="${TEST_EXPECTED_WINDOW_LOG:?set expected window log text}"
TEST_EXPECTED_DAEMON_LOG="${TEST_EXPECTED_DAEMON_LOG:?set expected daemon log text}"
window_pid=
window_pgid=
export TERN_CONFIG_DIR="$scratch/config"
export TERN_DAEMON_SOCKET="$scratch/daemon.sock"
export STENCIL_LOG_DIR="$scratch/logs"
export STENCIL_LOG=warn,stencil=info,tern::plugin=debug
mkdir -p "$TERN_CONFIG_DIR" "$STENCIL_LOG_DIR"

cleanup() {
  if [ -S "$scratch/window.sock" ]; then
    timeout -k 1s 5s tern ctl \
      --control "$scratch/window.sock" quit >/dev/null 2>&1 || true
  fi
  if [ -n "$window_pgid" ]; then
    for _ in $(seq 1 50); do
      kill -0 -- "-$window_pgid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 -- "-$window_pgid" 2>/dev/null; then
      kill -TERM -- "-$window_pgid" 2>/dev/null || true
      sleep 1
    fi
    if kill -0 -- "-$window_pgid" 2>/dev/null; then
      kill -KILL -- "-$window_pgid" 2>/dev/null || true
    fi
  fi
  [ -z "$window_pid" ] || wait "$window_pid" 2>/dev/null || true
}
trap cleanup EXIT

# These guards run before the link can write anything.
plugin_dir="$(tern plugin dir)"
case "$plugin_dir" in
  "$TERN_CONFIG_DIR"/*) ;;
  *) echo "refusing to link; wrong plugin directory: $plugin_dir" >&2; exit 1 ;;
esac
test ! -e "$TERN_DAEMON_SOCKET" || {
  echo "refusing to start; stale daemon socket: $TERN_DAEMON_SOCKET" >&2
  exit 1
}
tern plugin link "$TEST_PLUGIN_DIR"

# The supervisor owns this window and the daemon it starts. Create a separate
# process group so cleanup can stop both.
setsid tern --control "$scratch/window.sock" \
  >"$scratch/window.log" 2>&1 &
window_pid=$!
window_pgid="$window_pid"

ready=0
for _ in $(seq 1 100); do
  if tern ctl --control "$scratch/window.sock" tree \
      >"$scratch/tree.json" 2>"$scratch/tree.err"; then
    ready=1
    break
  fi
  sleep 0.1
done
test "$ready" -eq 1 || {
  cat "$scratch/tree.err" >&2
  exit 1
}
test -e "$TERN_DAEMON_SOCKET" || {
  echo "isolated daemon socket was not created" >&2
  exit 1
}

# Replies are JSON envelopes; tree contains visible UI text. Read text, never
# screenshots. Capture log offsets before reload so old evidence cannot pass.
window_log="$STENCIL_LOG_DIR/tern.log"
daemon_log="$STENCIL_LOG_DIR/tern-daemon.log"
if [ -f "$window_log" ]; then
  window_before="$(wc -c <"$window_log")"
else
  window_before=0
fi
if [ -f "$daemon_log" ]; then
  daemon_before="$(wc -c <"$daemon_log")"
else
  daemon_before=0
fi
tern plugin reload "$TEST_PLUGIN_ID" --json
tern ctl --control "$scratch/window.sock" tree >"$scratch/tree.json"
tree_text="$(cat "$scratch/tree.json")"
window_suffix="$(dd if="$window_log" bs=1 skip="$window_before" 2>/dev/null || true)"
daemon_suffix="$(dd if="$daemon_log" bs=1 skip="$daemon_before" 2>/dev/null || true)"
case "$tree_text" in
  *"$TEST_EXPECTED_TEXT"*) ;;
  *) echo "plugin tree evidence was not observed after reload" >&2; exit 1 ;;
esac
case "$window_suffix" in
  *"$TEST_EXPECTED_WINDOW_LOG"*) ;;
  *) echo "new window-log evidence was not observed after reload" >&2; exit 1 ;;
esac
case "$daemon_suffix" in
  *"$TEST_EXPECTED_DAEMON_LOG"*) ;;
  *) echo "new daemon-log evidence was not observed after reload" >&2; exit 1 ;;
esac
printf '%s\n' "$tree_text"
tern ctl --control "$scratch/window.sock" state
tern ctl --control "$scratch/window.sock" click "<selector from tree output>"
tern ctl --control "$scratch/window.sock" tree
```

Start that script under the supervisor, for example:

set -euo pipefail
scratch="$(mktemp -d "${TMPDIR:-/tmp}/tern-plugin.XXXXXX")"
systemd-run --user --scope --wait --collect \
  --working-directory="$PWD" \
  --property=KillMode=control-group \
  --property=RuntimeMaxSec=60s \
  --property=TimeoutStopSec=5s \
  --unit="tern-plugin-test-$RANDOM" \
  env TEST_PLUGIN_DIR=/path/to/session-list-test \
      TEST_EXPECTED_TEXT="expected plugin text" \
      TEST_EXPECTED_WINDOW_LOG="window plugin loaded" \
      TEST_EXPECTED_DAEMON_LOG="host plugin loaded" \
  bash ./test-isolated.sh "$scratch"
if [ -e "$scratch/daemon.sock" ]; then
  echo "supervised Tern left its daemon socket behind: $scratch/daemon.sock" >&2
  exit 1
fi
rm -rf "$scratch"
```

The outer shell removes the scratch directory only after the supervisor
returns successfully and the daemon socket is gone. On failure, `set -e`
leaves the scratch logs for diagnosis. Keep all `tern ctl` calls qualified with
`--control "$scratch/window.sock"`; never use the implicit current-window
route. `state` is JSON, while `tree` exposes visible UI text. Use the window
log as evidence, not screenshots.

Exercise only the surfaces the plugin actually uses, but cover their failure
modes explicitly:

- For a button, click only a node whose tree output identifies the intended
  action, then assert the resulting tree/state or log evidence for the action
  name and value. A row is not a button: use a key command for checklist-row
  behavior, or add and test an explicit action node.
- For long-lived blocks, close or end the pane and verify the producer stops
  because a new `tern.pane.list()` check no longer reports it; do not make
  shutdown depend on `pane_exited`. Set the local stopped flag before queuing
  `cx:exit()`, and re-check pane presence immediately before applying every
  async result.
- If the plugin shares files with another reader, test malformed/partial-file
  handling. Do not turn the observed “12 torn reads in 335 reads” into a
  statistical pass criterion; use `tern.kv` when its temp-file-plus-rename
  store fits, otherwise write a temporary file and rename it over the
  destination when atomic hand-off is required.
- For a spawn hook, assert that returned `spec.env` preserves the Tern-provided
  entries and that no casual `PATH` assignment changes command lookup.
- After `tern plugin reload "$TEST_PLUGIN_ID" --json`, assert block state
  restored from the last `save` result and window commands/binds re-registered
  because `window.luau` ran again. Persisted state does not preserve old Lua
  closures. Also cover native nodes and fresh window `cx` usage when those APIs
  are present.

Generate the test copy with a tiny script that changes the manifest id from the
production id to a distinct value such as `session-list-test`, and audit source
strings for hard-coded production namespaces. Tern ids name blocks, actions,
styles, and plugin data; the production and test packages must never collide.
Run the pure-module suite first, then the isolated Tern scenario, then remove
the scratch directory.

Check both halves independently. A host `reload`/daemon log proves host
loading. A controlled window and its log prove window loading and UI behavior.
Do not treat a green pure suite as proof that manifest declarations, actions,
keys, reloads, or context placement work.

## Evidence and debugging

Trust the window log and the actual controlled UI more than `tern plugin list`.
With no daemon, `list` reads only the manifest and settings and may say
`ready`; with a daemon, it still does not report a window entry that failed in
a particular window. Inspect:

- `$STENCIL_LOG_DIR/tern-daemon.log` for host load and handler failures.
- `$STENCIL_LOG_DIR/tern.log` for window load and window handler failures.
- `tern plugin reload "$TEST_PLUGIN_ID" --json` from the supervised test
  shell, after its isolated plugin-directory and daemon-socket checks.
- `tern ctl --control "$SCRATCH/window.sock" tree`, `state`, `click`, and
  `quit` replies for the behavior the user sees; never use the implicit
  current-window route.

For plugin-owned diagnostics, default filtering keeps only warning/error plugin
records. Set `STENCIL_LOG=warn,stencil=info,tern::plugin=debug` before starting
the isolated daemon if `print`, `tern.log.info`, or debug lines matter. The
process inherits this environment at startup; changing it later is too late.

When a plugin fails, classify the failure before changing code:

- manifest/path/declaration problem: `plugin list` reports `problem` or reload
  fails;
- host entry or declared block/lens mismatch: host catalog is Failed and the
  daemon log has the traceback;
- window entry failure: the window toast/log reports it, while host `list` may
  still say `ready`;
- handler failure or budget trip: inspect the hook name and traceback in logs;
- UI mismatch: inspect the text tree and event path, not a screenshot.

## Gotchas to encode in reviews and tests

These are easy to miss even when the API shape looks plausible:

- **Interactive buttons:** set `actions = { click = "name=value" }` on the
  node. An `act` property is not a click binding and does not fire the handler.
  Assert the resulting action event (`ev.ev == "action"`, `ev.act`, and, when
  present, `ev.value`).
- **Checklist/table rows:** rows do not emit pointer clicks in the way a
  button does. Use keys for row interaction, or put an explicit button/action
  node in the row and test that node.
- **Pane lifetime:** `pane_exited` does not fire when Tern closes. For
  long-lived block work, poll `tern.pane.list()` and stop when the pane
  disappears. Cancel producers where possible and re-check before applying an
  async result. Also set a local stopped flag before queuing `cx:exit()`,
  because the pane list updates after the handler returns.
- **File writes:** `tern.fs.write` replaces a file but is not atomic. In one
  test, a reader saw half-written files 12 times in 335 reads. Do not use it
  as an atomic hand-off; validate reads and use `tern.kv` for small shared
  state when its temp-file-plus-rename semantics fit the data. Never write
  runtime state into the watched package.
- **Spawn environment:** the spawn hook's `spec.env` is the complete set of
  Tern-provided environment overrides. Return the received spec and preserve
  its entries. Setting `PATH` casually can replace the login PATH and break
  commands; do not manufacture a PATH in a hook unless the full intended
  value is explicit and tested.
- **Native nodes:** Tern's native checklist and tool nodes are available to
  plugins, including the same node family used by omp's todo surface. Prefer
  the documented `tern.ui` builders or `tern.ui.node` and inspect the Elements
  reference before recreating them with custom HTML/CSS.
- **Scoped window contexts:** do not retain a normal window `cx` for a later
  timer, process callback, or event. Those callbacks receive a fresh `cx`.
  Block `cx` has different lifetime guarantees; follow the generated type
  definitions and block guide for that context.
- **Reload state:** host reloads restart blocks from the last `save` result;
  window reloads discard Lua registrations. Put restart-required state in the
  block save value, `tern.kv`, or plugin data, and make rehydration safe.

## Minimum acceptance checklist

Before calling a plugin complete:

- [ ] `plugin.toml` validates; ids are unique; every declared block/lens is
      defined; no runtime state or unapproved generated/build output is in the
      package root.
- [ ] `tern plugin types ../tern-api` was run for the target Tern, the
      generated `tern.d.luau` was read, and `luau-lsp analyze` passes with
      `--definitions=@tern=../tern-api/tern.d.luau`; pass only the entry files
      that exist and enable `--!strict`.
- [ ] Pure modules run with standalone `luau` and cover Tern JSON null/array
      behavior, false values, empty collections, malformed input, and the
      important state transitions.
- [ ] A generated test copy uses a distinct id such as `session-list-test` and
      has no hard-coded production namespaces.
- [ ] Integration runs under a disposable container/VM or descendant-owning
      supervisor with isolated `TERN_CONFIG_DIR`, `TERN_DAEMON_SOCKET`, and
      `STENCIL_LOG_DIR`; readiness and bounded descendant cleanup were proven;
      the real daemon was not reloaded.
- [ ] The controlled window was exercised through qualified commands such as
      `tern ctl --control "$SCRATCH/window.sock" tree`, `state`, `click`, key
      input, and `quit`; UI assertions read `tree` text and `state` JSON, not
      screenshots.
- [ ] A button test uses `actions = { click = "name=value" }` and asserts
      `ev.ev == "action"`, `ev.act`, and `ev.value` where present; checklist
      rows use keys or explicit action nodes.
- [ ] Both daemon and window logs were checked; `ready` from `plugin list` was
      not accepted as window-load proof.
- [ ] Actions, pane disappearance, the stopped flag before `cx:exit()`, a new
      `tern.pane.list()` check before each async result, file-write behavior,
      spawn environment, and reload persistence have regression coverage where
      the plugin uses them.
- [ ] Native nodes use the documented `tern.ui` builders or `tern.ui.node`, and
      window `cx` values are not retained across callbacks.

## Official references

- [Tern Plugin SDK overview](https://docs.stencil.so/tern/)
- [Getting Started](https://docs.stencil.so/tern/guides/getting-started.html)
- [API Reference](https://docs.stencil.so/tern/reference/api.html)
- [Manifest Reference](https://docs.stencil.so/tern/reference/manifest.html)
- [Command Line](https://docs.stencil.so/tern/reference/cli.html)
- [Building Views](https://docs.stencil.so/tern/guides/views.html)
- [Elements and native node kinds](https://docs.stencil.so/tern/elements/index.html)
- [Blocks](https://docs.stencil.so/tern/guides/blocks.html)
- [Files, Processes, and Storage](https://docs.stencil.so/tern/guides/io.html)
- [Debugging](https://docs.stencil.so/tern/guides/debugging.html)
- [Control Commands](https://docs.stencil.so/tern/scripts/control.html)
- [Lifecycle and Reload](https://docs.stencil.so/tern/concepts/lifecycle.html)
- [Example Plugins](https://docs.stencil.so/tern/examples/index.html)
