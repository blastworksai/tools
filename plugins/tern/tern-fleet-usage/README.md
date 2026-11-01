# Agent Usage Block for Tern

`tern-fleet-usage` is a read-only Tern block that asks the active Tern agents for their native `/usage` view and turns the reported weekly limits into compact account cards.

## What it does

- Uses Tern's native `cx.agents:list()`, `cx.agents:ask()`, `cx.agents:transcript()`, and `cx.session:read()` APIs.
- Sends `/usage` only to idle agents that are ready for input.
- Reads the agent's own rendered usage response; it does not contact Commander or provider APIs.
- Groups agents by provider and orders Claude, Codex, Kimi, Muse, then Google.
- Renders weekly usage as rings with `x% used` labels.
- Renders reset day, time, and countdown.
- Keeps separate weekly entries when an agent reports multiple pools.
- Stores only the normalized in-memory-style snapshot in Tern's plug-in KV store.

## Install

```sh
tern plugin link /path/to/tern-fleet-usage
tern reload
tern plugin list --json
```

Open **Agent Usage Block: open account usage** from Tern's command palette. The plug-in collects immediately for ready agents and refreshes every five minutes. Agent completion events update the snapshot as usage requests finish.

## Tern-native data path

The window half discovers agents with:

```lua
local agents = cx.agents:list()
```

It requests usage with:

```lua
cx.agents:ask(agent.pane, "/usage")
```

Then it reads the current agent surface and structured transcript using:

```lua
cx.session:read(agent.pane, { as = "text" })
cx.agents:transcript(agent.pane, { last = 20 })
```

The window half writes a small normalized snapshot to `tern.kv`. The host block reads that snapshot and renders it. No external service or account database is involved.

## Limitations

- An agent must be idle/ready before the plug-in asks it for `/usage`; working agents are collected after their current turn finishes.
- The exact usage text is agent-specific. The current parser requires a weekly line shaped like `Weekly limit <n>% used resets in <duration>`.
- Agents that do not expose a parseable weekly line are omitted until their native output matches the contract.
- Tern's native agent metadata does not guarantee a billing account name; the plug-in uses the pane title as the account label.

## Files

- `plugin.toml` — plug-in and block declaration
- `host.luau` — snapshot validation and rendering
- `window.luau` — native agent discovery, `/usage` collection, and command registration
- `fleet-usage.css` — surface-scoped styles

## Safety properties

- No provider credentials or provider API calls.
- No Commander endpoint or Commander database access.
- No shell injection; usage is requested through Tern's agent API.
- Only idle agents are prompted automatically.
- No persistent account history; only the latest normalized snapshot is kept in plug-in KV.
- All UI styles are scoped to the plug-in surface.

## Attribution

The card-and-ring presentation is visually inspired by `pfTheTrial/tern-ai-limits`. No code or assets were copied. This implementation is original.

## License

MIT. See the repository license.
