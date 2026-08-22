# Changelog

All notable changes to this project are documented here. The project
follows [Semantic Versioning](https://semver.org).

## [0.8.1] — 2026-08-22

- The activity animation is now breathing dots — thinking. thinking..
  thinking... — instead of braille spinner glyphs, which render as
  identical boxes under fonts that lack them and therefore look frozen.
  Dots are padded so the mode line does not jitter; the tick slows to a
  calmer 0.4s. Mechanics double-checked against spinner.el — the timer
  discipline was already equivalent; the glyphs were the problem.

## [0.8.0] — 2026-08-22

- Tool activity moved out of the echo area: each tool call is now a
  quiet `⏳ name` line in the `*genie*` transcript, and the mode line
  shows only the spinner with `thinking…` / `validating…`. The echo
  area belongs to the user (and to cantrip output) again.

## [0.7.4] — 2026-08-22

- A review lost to an Emacs restart no longer wedges the next wish:
  the intent-to-add index entries genie marks on created files broke
  `git stash create` ("Entry not uptodate. Cannot merge") forever after.
  The snapshot now heals such leftovers first — the files stay in the
  worktree as plain untracked files.

## [0.7.3] — 2026-08-22

- Hot-reload now actually covers `init.el`: an applied wish reloads the
  changed modules first and then init.el itself, so use-package wiring
  and keybindings living there take effect immediately instead of only
  after a restart. Every file loads under a condition-case; a failure
  falls back to offering the restart, and a clean init reload notes
  "restart if anything misbehaves".

## [0.7.2] — 2026-08-22

- The activity indicator now heals itself: on every turn, genie
  re-canonicalizes the global mode-line construct and the chat buffer's
  local format, so a session that hot-reloaded genie across versions
  (where `defvar' keeps the old bound value — a frozen spinner) fixes
  itself on the next wish, no restart needed.

## [0.7.1] — 2026-08-22

- The global mode-line indicator is now a stable trampoline into a
  function, so reloading genie in a running session actually updates it
  (`defvar` keeps old values on reload — the 0.7.0 spinner looked static
  to anyone who hot-reloaded instead of restarting).
- A cantrip's own echo-area output is no longer clobbered by genie's
  message: the cantrip's words stay on screen, with the undo hint
  appended only when there is an effect to undo.

## [0.7.0] — 2026-08-22

- The mode-line activity indicator now spins: an animated braille
  spinner runs in every mode line while the agent thinks or the config
  validates (`🧞⠹ thinking…`, `🧞⠹ apply_patch init.el…`,
  `🧞⠹ validating…`), driven by a timer that exists only while genie
  works. Long ACP tool titles are truncated to keep the line tidy.

## [0.6.1] — 2026-08-21

Field fixes for the unified undo, from a first day of real use.

- `genie-undo` of a cast no longer strands the journal entry when the
  buffer's undo history has aged: a tail truncated by GC (buffer
  untouched since the cast) is undone whole from the list head, and a
  history rebuilt by a buffer revert is reported as "the effect is
  already gone" and consumed instead of erroring forever.
- A cantrip that merely reports something (or runs in an undo-disabled
  buffer, like dired) no longer promises "genie-undo reverts it" — the
  promise appears only when a journal entry actually exists.
- Undo with an empty journal and a foreign HEAD now says plainly that
  there is nothing to undo, instead of "HEAD is not a genie commit".

## [0.6.0] — 2026-08-21

Elmee speaks the Agent Client Protocol and becomes the default backend.

- The elmee backend now drives `elmee --acp` — a warm JSON-RPC 2.0
  server following the standard [ACP](https://agentclientprotocol.com):
  `initialize` → `session/new` → `session/prompt`, turns streamed as
  `session/update` notifications, aborts via `session/cancel`. The old
  line-delimited elmee protocol (process-per-task, `--session` temp
  file) is removed.
- genie-rpc 0.3.0: a generic ACP client (request/response correlation,
  handshake with a prompt queue until the session is open, agent
  requests declined minimally), backends as function hooks
  (`:hello`/`:prompt`/`:abort`/`:dispatch`), simplified close.
- `genie-backend' defaults to `elmee'.

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
