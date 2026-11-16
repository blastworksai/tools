# ORCH+ — two clients, one execution host

This is the three-device equivalent of the four separate code-linked walks. **Client A and Client B connect to the same Execution Host.** They are not two execution hosts. The Mermaid diagrams are in [architecture.md](architecture.md).

The intended example is a Windows client and a Mac client sharing one Linux Execution Host. This deployment trace is based on current source and that topology. It is **not** a recorded three-device test. The four HTML pages expose the same code paths; this document maps each step onto the three devices rather than duplicating the source snapshots.

## What must be shared

Both clients must reach the same Tern host daemon under the same host OS account for the shared plugin-data model below. A different SSH login account has a different plugin-data home; using the same machine name does not merge those stores.

The execution-host login owns the host plugin state. An explicitly selected per-agent Unix account owns that agent's process and prepared helper resources. Those are separate choices. With no per-agent Unix user, the ordinary route runs as the execution-host login account.

| Component | Client A | Client B | Execution Host |
|---|---|---|---|
| Tern window and native SDK actions | Its own window and route | Its own window and route | Host daemon executes the attached session's processes |
| ORCH+ ownership, projects, approvals and START grants | Rendered observations and captured intent | Rendered observations and independently fenced intent | `authority_state`; ORCH+ is the owning writer |
| SPAWN saved agents and launch facts | Configuration UI | Configuration UI | `authority` and `dispatch-v1`; SPAWN is the owning writer |
| ORCH+ ↔ SPAWN plugin channel | No direct mailbox-file transport | No direct mailbox-file transport | Host-local files, bounded requests/results/ACKs |
| Agent helpers, communication mailboxes and journals | No automatic copy | No automatic copy | Prepared for the selected runtime account |
| Native ORCH+ Board file | Client-side file if created here | Client-side file if created here | Plan/source state can remain here; this is not automatic board-file replication |

The existing Tern connection carries window/host traffic. ORCH+ does not add a second SSH connection from the execution host back to itself, a parked transport terminal or a new background daemon.

## 1. Set up agents in SPAWN

[Open the separate setup walk](walks/orchplus-single-device.html).

1. **Client A:** open SPAWN on the attached Execution Host. The setup source captures that host/session/window identity.
2. **Client A:** choose the intended machine from Tern-known connected machines. Discovery does not create a connection, SSH key or OS account. Selecting Multi device is not a substitute for an existing Tern connection.
3. **Execution Host:** retain the run ID, working folder, result path and submitted approved records. Glitch detection searches observed candidate ancestors; it is not a hardcoded install location or a full-disk search.
4. **Client A:** the configured helper pane performs its discovery and questions in the selected context. Its native submission is bound to the original setup run. Submission delivery is not a saved configuration.
5. **Execution Host:** SPAWN validates and saves the exact records. Preparation uses execution-host executables, folders and selected runtime accounts. Terminal preparation is offline; the native OMP readiness message is a separately disclosed route.
6. **Client B:** sharing the same host account means the same saved host-side roster can be read. It does not mean importing a second roster or copying the first client's local board file.

**Current product limit:** approved Guided setup still presents a separate native review picker before saving/preparing. The requested automatic-save/no-second-popup repair remains deferred. The retained 12-agent receipt was assisted; it is not proof of a complete unattended Guided setup.

## 2. Start an orchestrator pane

[Open the separate orchestrator-start walk](walks/orchplus-orchestrator-start.html).

1. **Client A:** the admitted controller chooses a project and a ready saved orchestrator. Its intent carries a window key/epoch, source pane, logical session, owner/generation, record revision and expected authority revision.
2. **Execution Host / ORCH+:** validate the choice, reserve the coordinator owner/generation and save the mailbox-provision action in `authority_state`.
3. **Execution Host / SPAWN:** prepare the exact mailbox and command through the host-local plugin channel. Helpers must be accessible to the selected agent account, not merely the account running the host plugin.
4. **Client A's window route:** claim the exact native action and invoke the matching Tern agent or terminal API once. The process runs **on the Execution Host**, not on Client A merely because the UI is there.
5. **Execution Host:** the agent reports ACCEPTED. SPAWN accepts the exact launch binding; ORCH+ issues coordinator activation. Acknowledging that activation enables coordinator proposals, not project implementation.
6. **Client B:** opening another window does not acquire Client A's controller authority. It may control its own separately admitted orchestration; it does not inherit permission to launch or replace this coordinator.

The native launch route checks host and selected native session. When the SDK cannot target the authorized nonselected session, it holds the original grant rather than changing the user's selection or launching elsewhere. That limitation is not removed by adding another client.

## 3. Start approved project work

[Open the separate typed START walk](walks/orchplus-project-start.html).

1. **Client A:** click START for the exact reviewed project revision. Conversational “start” is not the transport grant.
2. **Execution Host / ORCH+:** durably save one immutable START naming the coordinator owner/generation and captured approved membership. Later additions are not silently included.
3. **Execution Host / SPAWN and helper:** publish the complete reply through the existing mailbox. The complete manifest is made consumable before its notification. Client B does not forward this message.
4. **Execution Host / coordinator:** consume the exact reply into the durable journal, acknowledge it, claim it and publish the matching `PROJECT_START_CLAIM`.
5. **Execution Host / ORCH+:** accept the exact claim and release only the captured approved work. The normal launch machinery creates the child process through the authorized window route.
6. **Both clients:** any displayed progress must come from saved state. An ACTIVE label, another client's click or a toast cannot replace durable publication and claim. A failed or unknown publication remains held; retry retains the original grant identity.

This is why the authority and agent journals belong beside execution: delivery does not depend on copying a request file between the two desktops.

## 4. Reload or reconnect

[Open the separate reload walk](walks/orchplus-reload.html).

1. **Client A:** a plugin/window reload creates a new ephemeral window incarnation. It does not erase the host's owner/generation, outstanding START, launch facts or journals.
2. **Execution Host:** retained outcomes are reconciled before another effect is permitted. A timeout or absent pane does not prove that an earlier action never ran.
3. **Client A:** the current verified continuation replaces the window route, not the agent process. Positively never-consumed old authorizations can be fenced; consumed and uncertain outcomes remain retained.
4. **Execution Host:** the same coordinator/child binding and journal continue. Busy work elsewhere in the same orchestration prevents a false “settled” proof. Changing the selected native session must not stall already owned work, and an old completed control's acknowledgment must not hold the new lane forever.
5. **Client B:** it is not an automatic failover controller. A second desktop being connected is not permission to take over an occupied owner slot. Native pane/process reachability and explicit owner reconciliation still apply.

The retained two-reload journey used the public **Continue controller** confirmation after each reload. It proves same-process continuation in an isolated Linux terminal scenario, not entirely click-free recovery or seamless cross-client takeover.

Closing Client A does not establish that Client B has acquired its route. Agent processes may remain on the host, but this is not a promise that window-driven scheduling, native actions and board synchronization continue unattended.

## Source and evidence boundaries

The code-linked HTML pages contain the exact snippets and recorded receipts for the four flows. Additional client-boundary source files are [ORCH+ window.luau](https://github.com/blastworksai/tools/blob/main/plugins/tern/ORCH+/window.luau) and [SPAWN dispatch_window.luau](https://github.com/blastworksai/tools/blob/main/plugins/tern/SPAWN/dispatch_window.luau).

The passed physical-helper journey is retained deterministic evidence that is not published here. It covers one deterministic Linux execution host, both reloads and one physical child. It does **not** qualify real providers, native OMP, the normal polling defaults, multiple clients or automatic client failover. No product was installed, reset or launched for this review.
