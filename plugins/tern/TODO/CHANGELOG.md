# Changelog

## 0.7.3

- Fix: a plan with several `active` entities (parallel builders) is no longer refused with "at most one active entity, named by current". Every active entity shows as active. `current` may be null or name one active or blocked entity; naming a pending, done or unknown entity, and every other shape rule (states, ids, duplicates, bounds, reasons), still refuses.

- Fix: turning **Sync Glitch Plan to Tern Board?** On no longer empties **Attach to**. Sessions on other hosts were dropped for sync as well as for the native board, so with every session remote the list vanished and the attach was cleared.
- Fix: sync is never silent. The pane names the board once it is synced (with an **Open board** control) or says what is missing: no session picked, the session closed, no plan view yet, no plan published, or a session on another host whose plan this window cannot read.
- Fix: with Glitch Off, when only sessions on other hosts are open, the list says that the board needs a session on this computer and how many were left out, instead of "No eligible session is open for this mode."
- The Glitch Off control reads "Show the session's folder as a Tern Board?" instead of a bare "Board", so it is not mistaken for the Glitch sync setting.
- Turning sync on while a plan view is attached starts syncing on the next tick; the status is cleared whenever sync turns off or the attached session changes.

## 0.7.2

Earlier releases: see the git history.
