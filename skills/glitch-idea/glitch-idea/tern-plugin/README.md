# Glitch Idea for Tern

A small Tern window plugin.
It opens the local idea page as a browser split above the focused pane (the pane with focus in your Tern window, normally the one you just ran the idea skill in), instead of in a separate browser window.

## What it does

- Watches one folder on your computer, `%LOCALAPPDATA%\glitch-idea\open`, twice a second.
- When the idea skill drops a short request file there, it checks the link and opens it above the focused pane.
- It writes a one-line answer file back (opened, or the kind of failure), with no link and no secret in it.

## What it can do, and nothing else

- It only opens `http://127.0.0.1:<port>/` pairing links, the exact form the idea skill produces, and only next to the focused pane.
- It refuses anything else, and anything older than 30 seconds.
- It never switches host, moves focus, sends input, runs a program or calls an agent.
- It reads at most 1 KB per request and deletes request and answer files within a minute.

## Install

This is the published path in the repository:

```
tern plugin install github.com/blastworksai/tools/skills/glitch-idea/glitch-idea/tern-plugin
```

## Uninstall

```
tern plugin uninstall glitch-idea
```

## License

MIT, see `LICENSE`.

After installing or updating it into a window that is already open, switch to another pane and back once: the plugin starts listening on the first focus change (a running window does not start an updated plugin by itself).
