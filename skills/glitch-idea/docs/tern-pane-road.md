# Tern pane road: how a pane asks Tern to open the idea page

Design note from the SKILLS-142 spike, 12 and 13 November 2026.
Tern 0.9.16 on a Linux host, window on Windows attached over the remote link.

## Road chosen

Road A, window half only.
The helper writes one terminal title escape to the terminal of the pane it runs in.
Tern raises a `title` event in the window half, and that event carries the pane id.
The title carries a one-time request id, never the pairing link.
The window half fetches the pairing link from the idea service with that id, then opens the page above that pane.
No daemon half, no request file, nothing installed on the host's Tern.

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

Title text: `glitch-idea:<version>:<port>:<rid>`, version 1 or 2.
Version 1 (the ancestor road): claim at once, place above the asking pane.
Version 2 (the account lookup, SKILLS-160): focus-gated, see Focus rule.
`<port>` is the idea service's port, 1024 to 65535, no leading zero.
`<rid>` is 32 lowercase hex characters from a secure random source, new for every request.
Anything else is ignored without an answer.
After its wait the helper sets the title to the fixed text `glitch-idea`.

## Where the link travels

1. The helper opens the session as link mode does and holds the pairing link in memory.
2. It offers the link to its own idea service over the existing authenticated control channel: `rid`, link, 30 s life to be claimed. The service keeps the offer in memory only.
3. It writes the title.
4. The window half validates the title, then calls `GET http://127.0.0.1:<port>/api/v1/tern-claim?rid=<rid>` with a 3 s timeout.
5. The service answers once with the link and forgets the offer's link. The claimed offer then lives 60 s counted from the claim, so the result can arrive. A second claim, an unknown id and an expired id all answer 404.
A malformed query answers 400 `invalid_query`.
6. The window half checks the link against the one pairing-link grammar and checks its port equals `<port>`, opens it beside, moves it above the asking pane, and reports `above`, `beside` or `open_failed` with one `GET /api/v1/tern-result?rid=<rid>&how=<value>`.
7. The helper reads the offer's state over the control channel until it is final or the wait ends.

The pairing code is never in a title, an argv, a log or a file.
The request id is displayed for a moment; it is worth one claim, within 30 s of the offer, only against the loopback service that minted it.
A remote host needs its page port reachable from the window's computer under the same port number, exactly as link mode already does.

## Who may ask

A request exists only as terminal output of a pane of that Tern, so it comes from inside a pane by construction, under any account and on any system.
The same event names the pane, so "who may ask" and "which pane asked" are one mechanism.
A window half acts only when `cx.session:pane(<pane>)` knows the pane.

Known limit: any program whose output reaches a pane can print a well-formed title.
The window then makes one fixed-path GET to a loopback port on its own machine and opens a page only when the answer is a valid pairing link for that same port.
That is the reach of a printed link without the click.
The window half takes at most one request per pane every 5 s, counted on Tern's monotonic clock.
Only a direct claim stamps that limit; a deferred claim (Focus rule) neither checks nor stamps it, so one request written to several panes never locks the others out of their own next request.

## Claim rule and two windows

The service's single claim is the claim: the first window half to ask gets the link, every other gets 404 and does nothing.
A window that does not show the pane does not ask.

## Target pane

The page goes above the pane that wrote the title.
When that pane has closed, is parked or the move fails after the claim, the page stays where `beside` put it, next to the focused pane, and the result says `beside`.
A request never reaches the focused pane without a claim.

## Answers the helper can give

`opened` with `how` = `above` or `beside`.
Failures, fixed: `no_terminal` (no terminal this account may write was found among the ancestors), `plugin_no_answer` (no claim in time: plugin missing, window half not started, port unreachable from the window, or not a Tern), `open_failed` (claimed, the open failed), `no_result` (claimed, nothing reported), `offer_failed` (the helper could not hand the link to its own service).
A success result carries no link, no pairing code and no fallback line.
Waits: 4 s for a claim, then 6 s for the result.
The window cannot report an unreachable port, because the port is its only way back; that case reads `plugin_no_answer`.
On every failure the helper returns the live link, as link mode does, and never opens a second session.

## Default mode

Pane mode is the default when the helper finds a terminal among its ancestors and either `TERN_PANE` is set or an ancestor process is named `tern`.
With no terminal among its ancestors, it is also the default when the account lookup below finds at least one candidate in Tern.
That test only picks a default; the plugin's claim is the proof.
An explicit `browser_mode` or `--browser` always wins.

## Focus rule

A version 2 request may reach several panes at once, one request id for all of them.
The pane that is focused claims it directly and the page goes above it, as in version 1.
Every other pane that sees it claims with `defer=1`.
The service holds a deferred claim for up to 1.5 s: a direct claim in that time wins and the deferred claimer gets 404; still pending after it, the first deferred claimer gets the link, and the window opens it beside the focused pane, reporting `beside`.
When that claimer was the only pane of the window that raised the request id, the window then moves the page beside the claimer with `focus = false`: the page lands in the claimer's own tab and the person's focus stays where it is (window plugin 0.3.1).
When several panes raised it (two sessions of one account), the first deferred claimer is simply the first terminal written, not necessarily the asker, so the page stays beside the focused pane (0.3.2; 0.3.1 moved it beside that first claimer, which put it in the wrong tab, measured 15 Nov 2026).
Nothing ties a Codex session to its front end: the front end holds no thread file and its log rows carry no thread id.
At most 2 deferred claims wait at once across the service (it has 8 ordinary handler slots); a third answers 404 at once, so waits never starve the helper's state poll.
The window's 3 s fetch timeout covers the 1.5 s wait.
An unknown focus never counts as the asker: such a pane defers.
Measured 15 Nov 2026 in an isolated Tern 0.9.21: with focus in tab 2 and the asker in tab 1, `move(page, asker, "right", {focus = false})` returned true, the page joined tab 1 beside the asker and focus stayed in tab 2; with `focus = true` the window switched to tab 1.
Known limit: with several candidates and none focused, the first deferred claimer wins, so in different tabs the page joins one of them, not necessarily the pane whose agent ran the command.
The "page beside" outcome lives in the service, not in a window timer, because no window timer was proven in the spike.

## Agents whose commands do not run under the pane

Measured 14 Nov 2026 on codexbwai (Codex 0.167.2): the TUI runs on the pane's terminal, but commands are children of the account's long-lived app-server daemon, which has no terminal.
The ancestor walk therefore finds nothing, and before SKILLS-160 the helper answered `browser_mode_required`.
Codex sets `CODEX_THREAD_ID` for its commands; nothing found ties that id to a TUI process.
`/proc/<pid>/stat` is world-readable and its `tty_nr` names the process's controlling terminal.

The ancestor road stays first and unchanged.
Only when it finds nothing and an agent marker variable is present does the helper look up the account's own agent front ends.
The marker table is closed: `CODEX_THREAD_ID` maps to the front-end process name `codex`; a new agent is one row, added after it is measured.
A candidate is a process of that name whose real uid is this account's and whose `tty_nr` decodes to a Unix98 pseudo-terminal (majors 136 to 143) this account owns and may write.
A candidate counts only when it is in Tern: `TERN_PANE` set in its own environ, or an ancestor named `tern`; a candidate outside Tern is never written to.
Candidates are deduplicated by terminal, sorted, and capped at 8 (the service's offer cap).
A process that vanishes or cannot be read mid-scan is skipped; the lookup is empty when `/proc` cannot be read at all.
Another account's environ is never read.

Every request found this way is title version 2, `glitch-idea:2:<port>:<rid>`, whatever the number of candidates, because a lone candidate may be another session's pane (the asker may be a headless `codex exec`).
One request id goes to every candidate terminal, the helper waits once, then writes the fixed title back to each.
Version 2 is focus-gated in the window plugin (0.3.0 and later; from 0.3.2 a deferred page joins the asker only when it is the lone pane that raised the request): see Focus rule below.
With plugin 0.2.0 a version 2 request is ignored and reads `plugin_no_answer`, so the helper falls back to the link as before.
A transient `busy` from the helper's own service during the state poll is asked again within the same deadlines.

Limits: same account only, the front-end name table, Linux `/proc` only (Windows and macOS hosts keep today's behaviour).

## Not tested

- A macOS window, and a local Tern on Windows or macOS (the helper needs another way to reach the pane's terminal there).
- OSC 7 and OSC 133 across the remote link.
- Two windows showing the same pane at once.
- The pure Luau module under a standalone `luau` binary (none on the build host); it ran inside an isolated Tern 0.9.16 with the real claim routes: a never-offered id opened nothing, an offered id went `pending` then `above`.
- An agent screen that repaints at the instant of the write.
