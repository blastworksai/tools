# Glitch Idea for Tern

A small Tern window plugin.
It opens the local idea page as a browser split above the pane that asked for it, instead of in a separate browser window.

## What it does

- Listens for a pane title of the form `glitch-idea:1:<port>:<request id>`.
- Fetches the pairing link once from `http://127.0.0.1:<port>/` on your computer, using that request id.
- Opens the link above the asking pane, then tells the idea service whether it went `above`, `beside` or `open_failed`.
- The pairing link never travels in a title.

## The rule

Anything inside a pane of this Tern may ask.
Nothing outside a pane can, because a request exists only as terminal output of a pane.
The plugin acts only when Tern knows the pane that wrote the title, and takes at most one request per pane every 5 seconds.

## What it can never do

- It only opens `http://127.0.0.1:<port>/` pairing links of the exact form the idea skill produces, and only when the link's port equals the port in the title.
- It never sends input to a pane, runs a program, reads or writes a file, or calls an agent.
- It makes no request except to the loopback idea service on your own computer.
- If the claim does not return a valid link, it does nothing and shows nothing.

## Install

```
tern plugin install <src>
```

where `<src>` is this folder or the published path in the repository.
After installing or updating it into a window that is already open, change focus once so the window loads it.

## Remote hosts

When the pane runs on another host, the idea page's port must be reachable from the window's computer under the same port number.
This is the same need as opening the link by hand.

## Known limit

Any program whose output reaches a pane can print a well-formed title.
The window then makes one fixed-path GET to a loopback port on its own machine.
It opens a page only when the answer is a valid pairing link for that same port.
That is the reach of a printed link without the click.

## Uninstall

```
tern plugin uninstall glitch-idea
```

## License

MIT, see `LICENSE`.
