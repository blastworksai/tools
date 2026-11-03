# Tern Plugin Development

A practical skill for creating, type-checking, testing, debugging, and packaging
[Tern](https://docs.stencil.so/tern/) plugins.

It emphasizes the boundaries that make Tern plugins reliable:

- host and window halves are designed separately;
- pure Luau modules are tested with standalone `luau`;
- `tern plugin types DIR` supplies the exact API declarations for the target
  binary;
- integration tests run in a disposable container/VM or descendant-owning
  supervisor with scratch `TERN_CONFIG_DIR`, `TERN_DAEMON_SOCKET`, and
  `STENCIL_LOG_DIR`, readiness checks, a distinct test plugin id, text-only
  qualified `tern ctl` assertions, and bounded cleanup; the real daemon is
  never reloaded;
- logs and the controlled window, not `tern plugin list` alone, prove loading;
- known action, row, pane-lifetime, file-write, spawn-environment, native-node,
  scoped-context, and reload pitfalls are called out explicitly.

Read [`SKILL.md`](SKILL.md) for the agent workflow and acceptance checklist.

## License
In collaboration with [felipevdc1](https://github.com/felipevdc1).
MIT. See the repository [LICENSE](../../LICENSE).
