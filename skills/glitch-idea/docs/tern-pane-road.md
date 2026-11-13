# Tern pane road: how a pane asks Tern to open the idea page

Design note from the SKILLS-142 spike, 12 and 13 November 2026.
Tern 0.9.16 on a Linux host, window on Windows attached over the remote link.

## Road chosen

Road A, window half only.
The helper writes one terminal title escape to the terminal of the pane it runs in.
Tern raises a `title` event in the window half, and that event carries the pane id.
The title carries a one-time request id, never the pairing link.
The window half fetches the pairing link from the idea service with that id, then opens the page above that pane.
No daemon half, no request file, no ssh, nothing installed on the host's Tern.

## Why not a daemon half

A daemon-half `cx:open` reaches the window's `route.link` with `pane` set to the focused pane, not the pane that asked.
A daemon-half timer has no `cx`, `tern.pane.list()` gives no pid or tty, and `tern.kv` does not cross a remote link.
The daemon half hears the same `title` event but cannot hand the pane to the window, so it adds parts and no ability.

## Evidence

Local runs used an isolated Tern: own `TERN_CONFIG_DIR` and `TERN_DAEMON_SOCKET`, a real window under `xvfb-run`, inside a `systemd-run --user --scope`.
`tern serve` is no substitute: it starts an ephemeral session with no daemon and loads no plugin.
A probe plugin logged every event it heard.

| Question | Command | Result |
|---|---|---|
| Does a title escape raise `title` with the pane, on both halves? | `printf '\033]2;spike-title\007'` in pane 5 | `host title pane=5` and `window title pane=5` |
| OSC 0 with ST terminator? | `printf '\033]0;x\033\\'` | `window title pane=5` |
| Other escapes? | OSC 7, OSC 133;C;cmdline=, OSC 1337 SetUserVar | `cwd` and `command_started` raised with the pane; SetUserVar raises nothing |
| From a detached child with no terminal fds? | `setsid env -i python3 find_tty.py` (walks ancestors to the first pty it owns and may write) | `wrote 24 bytes to /dev/pts/28 found at pid … fd 0`; `title pane=5` |
| Payload length? | titles of 200, 1,000, 4,000, 20,000 characters | all arrive whole |
| Same title twice? | the same escape sent again, on the real estate | no second event: each request needs a new value |
| Is `tern.fetch` bounded? | `timeout_ms = 700` to a silent, a closed and a live port | `timeout: global`; `Connection refused`; 200 |
| Place above an asker that is not focused? | `cx:open(url, "beside", {focus = true})`, then `cx.layout:move(page, asker, "up")` | `move true`; asker rows 45 to 22 |
| `cx.browser:call{op="open", owner=asker}`? | local Tern, then the real estate | works locally; `not_found` for a remote-host pane: not used |
| Daemon-half open: which pane? | host `cx:open(url)` on a title from pane 5 | `route.link pane=10` (the focused pane) |
| Across the remote link, under `sudo -iu` and an agent screen? | window-only probe on the Windows window; escape written from the host pane | `step=page&pane=4521258704175191&known=true`, also with another pane focused |
| Is the page port reachable from the window's computer? | `tern.fetch("http://127.0.0.1:8845/")` in the window half | 200 with a listener up, status 0 with none |
| Does the page open above the asking pane there? | the open and move calls above | `opencdone ok=true move=true-true`; page requested; seen above the pane |
| Is the title shown? | screenshot of the pane header | yes, and it stays until something changes it |
| More than one window half? | two `loaded` answers 20 s apart | yes: a request must be claimable once |
| `tern.fs.remove` return value? | generated API | returns nothing; not needed on this road |

## Request grammar

Title text: `glitch-idea:1:<port>:<rid>`.
`<port>` is the idea service's port, 1024 to 65535, no leading zero.
`<rid>` is 32 lowercase hex characters from a secure random source, new for every request.
Anything else is ignored without an answer.
After its wait the helper sets the title to the fixed text `glitch-idea`.

## Where the link travels

1. The helper opens the session as link mode does and holds the pairing link in memory.
2. It offers the link to its own idea service over the existing authenticated control channel: `rid`, link, 30 s life. The service keeps the offer in memory only.
3. It writes the title.
4. The window half validates the title, then calls `GET http://127.0.0.1:<port>/api/v1/tern-claim?rid=<rid>` with a 3 s timeout.
5. The service answers once with the link and forgets the offer's link. A second claim, an unknown id and an expired id all answer 404.
6. The window half checks the link against the one pairing-link grammar and checks its port equals `<port>`, opens it beside, moves it above the asking pane, and reports `above`, `beside` or `open_failed` with one `GET /api/v1/tern-result?rid=<rid>&how=<value>`.
7. The helper reads the offer's state over the control channel until it is final or the wait ends.

The pairing code is never in a title, an argv, a log or a file.
The request id is displayed for a moment; it is worth one claim, for 30 s, only against the loopback service that minted it.
A remote host needs its page port reachable from the window's computer under the same port number, exactly as link mode already does.

## Who may ask

A request exists only as terminal output of a pane of that Tern, so it comes from inside a pane by construction, under any account and on any system.
The same event names the pane, so "who may ask" and "which pane asked" are one mechanism.
A window half acts only when `cx.session:pane(<pane>)` knows the pane.

Known limit: any program whose output reaches a pane can print a well-formed title.
The window then makes one fixed-path GET to a loopback port on its own machine and opens a page only when the answer is a valid pairing link for that same port.
That is the reach of a printed link without the click.
The window half takes at most one request per pane every 5 s.

## Claim rule and two windows

The service's single claim is the claim: the first window half to ask gets the link, every other gets 404 and does nothing.
A window that does not show the pane does not ask.

## Target pane

The page goes above the pane that wrote the title.
When that pane has closed, is parked or the move fails after the claim, the page stays where `beside` put it, next to the focused pane, and the result says `beside`.
A request never reaches the focused pane without a claim.

## Answers the helper can give

`opened` with `how` = `above` or `beside`.
Failures, fixed: `no_terminal` (no terminal this account may write was found among the ancestors), `plugin_no_answer` (no claim in time: plugin missing, window half not started, port unreachable from the window, or not a Tern), `open_failed` (claimed, the open failed), `no_result` (claimed, nothing reported).
The window cannot report an unreachable port, because the port is its only way back; that case reads `plugin_no_answer`.
On every failure the helper returns the live link, as link mode does, and never opens a second session.

## Default mode

Pane mode is the default only when the helper finds a terminal among its ancestors and either `TERN_PANE` is set or an ancestor process is named `tern`.
That test only picks a default; the plugin's claim is the proof.
An explicit `browser_mode` or `--browser` always wins.

## Not tested

- A macOS window, and a local Tern on Windows or macOS (the helper needs another way to reach the pane's terminal there).
- OSC 7 and OSC 133 across the remote link.
- Two windows showing the same pane at once.
- An agent screen that repaints at the instant of the write.
