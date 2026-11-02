# WORK for Tern

WORK is a native Tern pane for active Glitch workspaces. It reads the same generated workspace registry used by `/work-on`, so the list stays current without a second project catalog.

## What it does

- Lists every registry entry whose `status` is `active`.
- Shows each workspace's kind and configured GitHub repository.
- Selects a row when you click it and remembers the selection locally in Tern KV.
- Opens the repository's GitHub URL through Tern's normal link handling.
- Starts the configured default Tern agent in a right-side split with:

  ```text
  Work on <workspace-slug>
  ```

Workspaces are discovered from `workspaces/registry.json`; names are never hardcoded into the plugin. Worktrees, mirrors and failed registry entries are omitted because `/work-on` does not treat them as independent workspaces.

## Install

Install WORK on the Tern host that owns the Glitch workspace registry:

```sh
tern plugin link /path/to/WORK
tern plugin reload tern-work --json
```

Then run **WORK** from Tern's command palette. The plugin can run locally on the same machine as Glitch or with Tern connected to a remote Glitch host. In either case, the host half must be attached to the Glitch root containing `workspaces/registry.json`.

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
- `window.luau` — WORK command, files-pane button and native agent launch
- `projects.luau` — registry loading, validation and workspace view model
- `blocks/panel.luau` — workspace list and row actions
- `styles.css` — amber Work On button styling
- `tests/projects.luau` — registry/filtering/selection regression checks

## License

MIT. See the repository license.
