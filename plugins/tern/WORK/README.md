# WORK for Tern

WORK is a native Tern pane for active Glitch workspaces. It reads the same generated workspace registry used by `/work-on`, so the list stays current without a second project catalog.

![WORK list beside a Claude Code pane already running /work-on](assets/screenshots/work-on-split.png)

*After **Work On**: the default agent opens to the right of WORK at the Glitch root, already running `/work-on <workspace-slug>`. Workspace names are blurred.*

## What it does

- Lists every registry entry whose `status` is `active`.
- Shows each workspace's kind and configured GitHub repository.
- Selects a row when you click it and remembers the selection locally in Tern KV.
- Opens the repository's GitHub URL through Tern's normal link handling.
- **Work On** starts an agent at the Glitch root, in a split to the right of the WORK pane in the same tab, with the prompt below. Without SPAWN it starts Tern's default agent; with SPAWN agents saved on the host it first asks which one (see [Choosing the agent](#choosing-the-agent)).

  ```text
  /work-on <workspace-slug>
  ```

The agent starts at the Glitch root because `/work-on` is a Glitch skill: an agent started inside a workspace cannot see it. It opens beside WORK whatever Tern's "Agent opens" setting says, and with several Tern windows showing the same session only the window you clicked in starts it.

Workspaces are discovered from `workspaces/registry.json`; names are never hardcoded into the plugin. Worktrees, mirrors and failed registry entries are omitted because `/work-on` does not treat them as independent workspaces.

## Choosing the agent

Work On runs whatever Preferences › Coding agents › **Agent** is set to (`agent_command` in Tern's `settings.json`). Pick **Custom** and enter a command, such as `claude --dangerously-skip-permissions`, to run that CLI in its own interface. **Claude Code** opens Claude in Tern's ACP chat instead.

![Tern's Coding agents settings beside the WORK list, with Agent set to Custom](assets/screenshots/work-agent-setting.png)

*Agent set to **Custom** with `claude --dangerously-skip-permissions`. Workspace names and local paths are blurred.*

A CLI agent (`claude`, `codex`, `omp`) receives the prompt as its launch argument, so it runs as soon as the CLI is up, including after Claude Code's first-run folder-trust question. Tern's own ACP chat (`tern acp …`) receives it through Tern.

### With SPAWN (optional)

WORK does not need [SPAWN](https://github.com/blastworksai/tools/blob/main/plugins/tern/SPAWN/README.md), and works the same without it. When the SPAWN plugin has saved agents on the same host, **Work On** becomes a dropdown: one row per saved SPAWN agent, labelled `Provider — suffix` with the provider's logo, then **Tern default agent** at the bottom. Agents that are disabled or still need review in SPAWN Config are listed greyed out, with the reason as a tooltip. The list is reread from SPAWN whenever you interact with WORK. If SPAWN has no saved agents on the host, Work On stays a plain button. If WORK can't read SPAWN's saved agents, it says so under the list and also stays a plain button.

WORK only reads SPAWN's roster (`authority` in SPAWN's host `kv.json`, next to WORK's own plugin data) and never writes it. A chosen agent runs the way SPAWN would launch it: its saved command and arguments, `sudo -u <user> -H --` for an OS-user record, `ssh` for an SSH record, and `SPAWN_PROVIDER=<provider>` in front so the tab gets SPAWN's provider icon. WORK starts it itself, in the split beside WORK. SPAWN's reservations, duplicate policy and Running agents list are not involved, so an account that is already running can be started again from WORK. Clicking also checks that SPAWN is loaded on the host.

The prompt reaches the agent in one of two ways:

- **As a launch argument** when the record runs a provider CLI directly that accepts a first prompt: `claude`, `codex`, `grok`, `muse` and `omp` take it as a positional argument, `agy` takes `-i <prompt>`. A native OMP record gets WORK's prompt, not its saved SPAWN startup prompt.
- **Typed into the pane** for everything else: launcher scripts that start a provider for an account and ignore extra arguments, Kimi (it has no interactive first-prompt option) and custom CLIs. WORK waits until the agent's screen has stopped changing for 1.5 s, then types the prompt and presses Enter separately. If the screen hasn't settled after 90 s, WORK copies the prompt to the clipboard and says so instead.

SPAWN agents are started from WORK on Linux and macOS hosts only; on a Windows host they are listed greyed out and **Tern default agent** still works.

## Install

Install WORK on the Tern host that owns the Glitch workspace registry:

```sh
tern plugin install github.com/blastworksai/tools/plugins/tern/WORK
tern plugin reload tern-work --json
```

Then run **WORK** from Tern's command palette. The plugin can run locally on the same machine as Glitch or with Tern connected to a remote Glitch host. In either case, the host half must be attached to the Glitch root containing `workspaces/registry.json`. Install or update WORK on every machine you use it from (the host and each desktop client): the host draws the list, the desktop runs the Work On launch.

SPAWN is optional. To get the agent dropdown, install SPAWN on the same host and save at least one agent in SPAWN Config; no WORK setting is involved.

For a local Glitch checkout, link the package from that checkout's `_local` directory if you want automatic root discovery:

```sh
tern plugin link <glitch-root>/_local/tern-projects
tern plugin reload tern-work --json
```

Windows paths are supported; the plugin normalizes path separators before locating the Glitch root.

## Registry contract

The registry is expected to have this shape:

```json
{
  "workspaces": {
    "example": {
      "status": "active",
      "kind": "coding",
      "path": "example",
      "remote": "https://github.com/example/example"
    }
  }
}
```

Only safe workspace slugs and paths are displayed. GitHub links are accepted only for `https://github.com/...` URLs.

## Files

- `plugin.toml` — Tern plugin and block declaration
- `host.luau` — host-side block registration
- `window.luau` — WORK command, files-pane button, native agent launch and SPAWN agent launch/prompt typing
- `projects.luau` — registry loading, validation and workspace view model
- `spawn.luau` — read-only SPAWN roster and the launch line for a chosen agent
- `blocks/panel.luau` — workspace list, row actions and the Work On dropdown
- `styles.css` — amber Work On button and dropdown trigger styling
- `tests/projects.luau` — registry/filtering/selection regression checks
- `tests/spawn.luau` — SPAWN roster decoding and launch-line checks
- `tests/run.txt` — runs both: `env WORK_PACKAGE_DIR=<package> tern shot <package>/tests/run.txt` (failures print `run(s) failed`)
- `assets/screenshots/` — README screenshots

## License

MIT. See the repository license.
