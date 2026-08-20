# Changelog

All notable changes to this project are documented here. The project
follows [Semantic Versioning](https://semver.org).

## [0.1.0] — 2026-08-20

Initial release.

- **Wishes**: natural-language edits to the Emacs config through an async
  RPC agent, with a per-wish git restore point, batch-load validation,
  diff review, one-commit-per-wish apply, hot-reload and `genie-undo`.
- **Spells**: ephemeral interactive commands conjured from a request,
  evaluated into the running session and armed on `genie-cast`;
  `genie-spell-keep` promotes one into a permanent wish.
- **genie-rpc**: application-agnostic library for driving JSONL-over-stdio
  coding agents, with two bundled backends — Pi (persistent process) and
  elmee (one process per task, session continuity via `--session`).
