# ORCH+ documentation

How ORCH+ and its companion SPAWN plugin work, read from the current source.
The intended model is one Linux execution host and two clients (for example Windows and Mac) that share it.

## Code-linked walks

Each walk is one self-contained HTML page.
It follows one action step by step, shows the real source lines behind each step and labels what was and was not observed.
Open a page in any browser; the walks use recorded source and retained deterministic evidence, not screenshots.

1. [Set up agents in SPAWN](walks/orchplus-single-device.html): Guided setup, the helper conversation, the separate native review and the verified save.
2. [Start an orchestrator pane](walks/orchplus-orchestrator-start.html): choosing a project, reserving the coordinator, launching its pane and activation.
3. [Click START on an approved project](walks/orchplus-project-start.html): the immutable START grant, publication, the coordinator's claim and release of the captured work.
4. [Reload ORCH+ and continue](walks/orchplus-reload.html): what the host keeps across window reloads and how the same work continues.

## Architecture and the two-client mapping

- [Architecture](architecture.md): runtime and state boundaries, with Mermaid diagrams for one device and for two clients with one execution host.
- [Two clients, one execution host](three-device.md): maps each of the four walks onto Client A, Client B and the Execution Host.

## Open work

- [Backlog](backlog.md): the wished-for changes that are not built yet.
