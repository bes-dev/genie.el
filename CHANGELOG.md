# Changelog

All notable changes to this project are documented here. The project
follows [Semantic Versioning](https://semver.org).

## [0.5.0] — 2026-08-21

Hardening: an explicit state machine and honest guardrails everywhere.

- The turn lifecycle is now an explicit state machine (`idle → thinking
  → validating → reviewing`): entry points refuse cleanly before input
  is read, a stale diff cannot be applied while a refinement streams,
  a late validation callback cannot clobber a newer cycle, and a failed
  submit rolls the turn state back.
- Conjured code is screened before evaluation: calls to processes, the
  network, file deletion and friends (`genie-spell-risky-functions`)
  need explicit confirmation; a declined spell is never evaluated.
- `genie-undo` with an empty journal now *offers* the git revert instead
  of silently performing it; new `genie-journal` previews the stack;
  reverting a wish notes that loaded definitions survive until restart.
- Spells are stored as entries with captured function objects: a newer
  spell reusing a name no longer silently changes what old registers do,
  and duplicate names are labeled `name<2>` in pick lists.
- Agent stderr is captured separately (genie-rpc 0.2.0) and its tail is
  shown when the process dies, so a backend startup failure has a
  readable reason; a deliberate elmee respawn no longer risks a spurious
  "process exited" salvage.
- Activity is visible in every mode line via `global-mode-string`;
  killing the `*genie*` buffer no longer kills the agent session — new
  `genie-quit` does that deliberately; validation timeout is
  customizable (`genie-validate-timeout`) and reported as a timeout,
  not a config failure.

## [0.4.0] — 2026-08-21

Cantrips and one undo for everything.

- New: `genie-cantrip` — conjure a one-shot command and execute it
  immediately where it was asked from (active region respected, target
  captured at request time). The command stays armed afterwards, so a
  good cantrip can be re-cast, slotted into a register, or kept.
- `genie-undo` is now unified: a session journal records every
  genie-made change, and undo pops the newest one whatever it was — an
  applied wish (`git revert` + reload) or the buffer effect of a spell,
  register cast or cantrip (reverted precisely via the buffer's undo
  history, with a confirmation when later edits would revert too). With
  an empty journal it falls back to reverting a genie commit at HEAD.

## [0.3.0] — 2026-08-20

Spell registers, in the spirit of `C-x r`.

- `genie-spell` now asks for a register digit (RET skips): the conjured
  command lands both as the current spell and in that register.
- New: `genie-cast-register` — bind it to `C-c g 1`..`C-c g 0` for ten
  programmable keys whose meaning is rewritten in natural language;
  `genie-spell-bind` slots any session spell into a register later.
- `C-u genie-cast` now annotates each spell with its register.
- New: `bootstrap.sh` and a README recipe for the empty-lamp start — an
  `~/.emacs.d` containing genie and nothing else, git-initialized, with
  genie installed from the repository via `package-vc-install` on first
  launch (Emacs 29+).

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
