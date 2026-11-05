# ORCH+ mockups

These static SVGs sketch the ORCH+ controller. They use theme colour variables (`--surface`, `--border`, `--muted`, `--accent`, `--success`, `--warning`, `--error`) and `currentColor` text, so they follow the viewer's light or dark theme.

- [`orchestration-session.svg`](./orchestration-session.svg): controller for one logical session, with worker health, reports, pending effects and per-worker buttons.
- [`dispatch-worker.svg`](./dispatch-worker.svg): assigning a task through the configured SPAWN catalog. There is no raw command input, and the account is chosen by the SPAWN record.
- [`fresh-context-rollover.svg`](./fresh-context-rollover.svg): verified rollover, from checkpoint to fresh successor, accepted handover and exact predecessor stop. No transcript is transferred.
- [`operator-queue.svg`](./operator-queue.svg): a landing-approval owner gate beside the per-target landing queue.

The mockups are conceptual and simplified. For the real UI, see the screenshots in the [ORCH+ README](../README.md).
