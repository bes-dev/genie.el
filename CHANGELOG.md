# Changelog

All notable changes to this project are documented here. The project
follows [Semantic Versioning](https://semver.org).

## [0.3.0] — 2026-08-20

Spell registers, in the spirit of `C-x r`.

- `genie-spell` now asks for a register digit (RET skips): the conjured
  command lands both as the current spell and in that register.
- New: `genie-cast-register` — bind it to `C-c g 1`..`C-c g 0` for ten
  programmable keys whose meaning is rewritten in natural language;
  `genie-spell-bind` slots any session spell into a register later.
- `C-u genie-cast` now annotates each spell with its register.

## [0.2.0] — 2026-08-20

The maintainer charter: genie is a config maintainer, not a code generator.

- The system prompt now carries architectural duties (thin `init.el`,
  one-responsibility modules established even from an empty config,
  refactor-as-you-go, built-ins and maintained packages before custom
  code), a research duty (check how the ecosystem solves it, via web
  tools, before writing code), and documentation duties (docstrings
  everywhere; a living user manual).
- New: `genie-manual-file` (default `GENIE.md`) — the agent-maintained
  manual of everything the config provides; `genie-manual` opens it.
- `genie-apply` now shows the agent's report after reloading, so every
  applied wish ends with usage documentation on screen.

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
