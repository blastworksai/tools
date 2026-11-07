# Changelog

## 0.5.0

Requires Tern 0.9.10 (now declared in `requires.json`).

### Added

- Self-updater: **SPAWN: Check for updates** reports whether a newer SPAWN is on GitHub (a background check runs at most every 6 hours), and **SPAWN: Update** checks the release's `requires.json`, asks first, optionally updates connected remote hosts, then reinstalls with `tern plugin install --force`. Linked development checkouts are never updated. Copies installed before 0.5.0 need one manual `tern plugin install --force github.com/blastworksai/tools/plugins/tern/SPAWN`.
- Config has a **Spawn agents** page: one **Spawn all** button and one button per saved record with its provider logo, `Provider — Suffix` and its command, arguments and working directory. Disabled records and records needing review are greyed with the reason.
- Automatic settlement: the host checks its panes on load, every 15 seconds and after each observation, and moves ordinary launches to history by itself: `Exited` "Pane closed", `Failed` "Never started (ticket not claimed)" after 30 seconds, `Exited` "Host restarted" 20 seconds after a host restart. Agents Tern reruns in their pane within those 20 seconds are re-adopted as `Running`. On non-Linux hosts the restart epoch is unverifiable, so only the pane rule applies. Managed (ORCH+) launches are unchanged.

### Changed

- One record can run any number of copies: every Spawn starts a new launch. Only disabled records are skipped.
- The SPAWN menu is **Guided setup** (only until the first record is saved), **Config**, **Spawn all** and **Spawn specific**. **Running agents** and **Review setup result** left the menu; the `SPAWN: Running agents` and `SPAWN: Guided setup` palette commands stay, and **Review setup result** moved to Config › Setup while a setup run is active.
- The host-restart notice is one informational line, "Host restarted: N SPAWN agents ended (cleared automatically)", with no action.
- When a batch finishes, SPAWN closes the Config view it opened for that batch instead of hiding it, so no idle SPAWN block is left behind. A Config you opened, or are looking at, stays.
- Reset transport now waits only for live or managed attempts.

### Removed

- The `duplicate_policy` record field and the `skip`/`allow` duplicate choice.
- **Mark no longer running** and **Mark all N lost agents no longer running**, with the `resolve_attempt` and `resolve_lost_attempts` operations and the `Unknown` blocking state for ordinary launches.

### Fixed

- The Config › Setup **Guided setup** row raised an error; it now starts Guided setup.

### Upgrade notes

- Saved records, Paste JSON imports, setup results and managed imports that still carry `duplicate_policy` have it stripped on restore or import, never rejected.
- A retained or journalled old Mark request is cleared automatically ("An old Mark-no-longer-running request was cleared; SPAWN now does this automatically") and never replayed.
- Leftover parked SPAWN Config blocks from older versions are closed when the window loads, unless one still has a pending request.
- Launches left `Unknown` by an older version settle on the host's first check.

## 0.4.0

For ORCH+ 0.4.0. The mailbox helpers changed: reinstall `mailbox_target.*`, `mailbox_worker.*`, `mailbox_json.awk` and `mailbox_reply.jq` on each execution target. Ordinary SPAWN launches are unchanged.

Includes all 0.3.1 fixes (SPAWN 0.3.1 had no changelog of its own; its entries are the `SPAWN:` items under ORCH+ 0.3.1): a short focus guard keeps managed launches from taking focus; a pending request the host already refused is acknowledged automatically; attempts lost to a daemon restart are recognised and can be released together with **Mark all N lost agents no longer running** (`resolve_lost_attempts`); **Spawn all** waits 5 seconds between launches; unused-mailbox retirement accepts a launch whose window challenge expired unconsumed.

### Changed (breaking)

- Managed records may declare up to seven mailbox capabilities (was five): `check-runner-v1` and `release-manager-v1` are new. Config, the codec and both helpers accept the same set.
- REVIEW_RESULT is now `{review_id, round, artifact_revision, outcome, findings, summary?}`, with findings tied to file and line, instead of `evidence`. Coordinators no longer send it; ORCH+ reviewer workers do.
- `landing_grant` and `deploy_grant` replies need `release-manager-v1` in the provisioned capability set; the helpers refuse them otherwise (`capability_missing`).

### Added

- Assignment manifest: `mailbox_provision` accepts optional `manifest` bytes (declared checks, files, scope and base ref; at most 4,096 bytes). Its digest joins the provision binding digest and `provision.json`, and the target helper writes the bytes as `manifest.json`. Provisions without a manifest keep their 0.3.0 digest and descriptor.
- Helper mode `checkout` (POSIX and Windows) publishes CHECKOUT from git: worktree, common dir, branch, head, merge base, changed files (committed, staged, unstaged and untracked; at most 512) and a dirty flag. Without a manifest `base_ref`, the first `checkout` pins the launch HEAD in `<mailbox>/checkout-base`, so later checkouts report committed (including out-of-scope) files instead of only uncommitted ones; a tampered pin is refused `storage_error`.
- Helper mode `run-checks <check_id>` (Windows: `-Mode: run-checks -CheckId: <check_id>`) runs one declared check's exact argv from the authenticated manifest without a shell and publishes CHECK_RESULT with its argv digest, exit code, output digest and head.
- CHECK_RESULT and CHECKOUT are helper-only: publishing them through `report` is refused `helper_only_kind`. Refusals `capability_missing`, `manifest_missing`, `manifest_mismatch`, `check_undeclared` and `git_unavailable` are definite and publish nothing.
- New report kinds LABEL and DEPLOY_RESULT (the latter needs `release-manager-v1`); new reply kinds `review_request`, `rework`, `deploy_grant` and `label_request`; DONE may carry `output_ref`.
- The helper JSON validator accepts arrays of up to 512 entries (was 256), for CHECKOUT's changed-file list.

### Fixed

- POSIX `wait` no longer leaves `producer/lock` behind with no running helper, which refused every later call `producer_locked`. A later poll or an interrupted wait now waits up to 10 seconds for a capacity gate held by a target commit; if the gate stays busy, the helper leaves it untouched and still removes its own empty workspace and producer lock. A helper killed without cleanup still needs explicit stopped-producer recovery (see BRIDGE.md). The PowerShell helper's lock already ended with its process; its `wait` polls and post-retirement lock-file removal now wait out a busy gate the same way instead of failing `capacity_locked`.
