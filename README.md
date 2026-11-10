# genie.el 🧞

*Rub the lamp, state a wish — an AI agent edits your Emacs config, you review the
diff, it hot-reloads.*

[![CI](https://github.com/bes-dev/genie.el/actions/workflows/ci.yml/badge.svg)](https://github.com/bes-dev/genie.el/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Emacs](https://img.shields.io/badge/Emacs-28.1+-7F5AB6?logo=gnu-emacs&logoColor=white)](https://www.gnu.org/software/emacs/)

`genie` is a self-modifying Emacs configuration driven by natural language.
Every **wish** goes through a full safety pipeline:

```
M-x genie "bind buffer formatting via black to C-c f"
   │
   ▼
the elmee agent edits your config files (async, over ACP)
   │
   ▼
validation — a batch subprocess must load init.el cleanly
   │
   ▼
commit "genie: <wish>" + hot-reload of the changed files
```

That last step is instant by default in the recommended config: you see the
change in the running editor rather than in a diff. Prefer to look first?
Keep `wish` in `genie-confirm` and every change stops at a review instead:

```
git diff review:  [a] apply   [r] reject   [q] quit
   │ a                                │ r
   ▼                                  ▼
commit + hot-reload               worktree restored to the pre-wish state
```

A change that **fails validation** is never applied and never dumped on you
as a diff to judge: the error goes back to the agent to fix (twice, by
default — see `genie-repair-attempts`). If the repairs do not take, the
change is undone and reported in plain words — *"couldn't do it, nothing
was changed"* — unless you are reviewing diffs, in which case you get one.

`M-x genie-undo` undoes the last applied wish — every wish is one git commit,
and undoing one deletes it from history rather than piling a revert on top.

**Spells** are the ephemeral counterpart: `M-x genie-spell` *"number the lines
of the selected region"* generates an interactive command, evaluates it
straight into the running session (nothing touches disk) and arms it on
`M-x genie-cast`. Liked it? `M-x genie-spell-keep` turns it into a permanent
wish through the same review pipeline.

Spells live in **registers**, in the spirit of Emacs's `C-x r`: when
conjuring, you pick a digit (or `RET` to skip) and the spell lands on
`C-c g <digit>` — ten programmable keys whose meaning you rewrite in natural
language as the day demands. `C-c g x` always casts the most recent spell;
`C-u C-c g x` lists every spell of the session with its register.

At the fully ephemeral end there are **cantrips** — minor magic, cast
instantly, no slot: `C-c g !` *"transpose these two columns"* generates the
command and executes it right where you asked, on the active region when
there is one. The command stays armed afterwards, so a cantrip that earned
its keep can be re-cast, slotted into a register, or promoted to the config.

**One undo for everything**: `genie-undo` pops the most recent genie-made
change from a session journal, whatever it was — an applied wish (confirmed,
then dropped from history and re-reloaded) or the buffer effect of a spell, register
cast or cantrip (undone precisely in the buffer it edited, even if you've
moved elsewhere since).

The UI never blocks: the agent runs as an async subprocess, and tokens and
tool activity stream live into the `*genie*` chat.

## The agent, anywhere

The lamp is one use of a general thing: a chat with the
[elmee](https://github.com/bes-dev/elmee) agent about a directory.
`M-x genie-ask` (`C-c g a`) opens the chat for the project you are in and
hands the agent what you are looking at — the active region, or with `C-u`
the whole file (in Dired, the directory). `*genie*` itself is such a chat,
about your config, with the wish pipeline wrapped around every turn.

In any chat:

- **Type ahead.** Answers stream in above the prompt, so the next message can
  be written while the agent works. `RET` sends, `C-c C-k` stops the turn.
- **Skills.** Whatever skills the agent has are commands here: `/pdf
  report.pdf`, `/kb что у меня про X`. `TAB` completes the name, `C-c C-/`
  picks one from a list. A skill is a `SKILL.md` — add a capability by
  dropping a file under `~/.agents/skills/`, no Emacs package needed.
- **Past conversations.** `C-c C-s` (or `M-x genie-sessions`) lists the
  conversations kept for the directory — when, how much was asked, what
  about. `RET` returns to one: the chat fills with what was said and goes on
  from there. `n` starts a new one, `d` deletes. They are elmee's files, so
  they survive restarts; `C-c C-n` starts afresh without the list.
- **The model.** `C-c C-m` switches it mid-conversation. The header line
  shows the model, how full its context is, and the step of the plan the
  agent is on.
- **Questions.** When the agent needs a decision it asks in the minibuffer,
  with its options as completions.
- **Links.** Paths in an answer open on `RET`/click; `[[wikilinks]]` open
  the page of that name under `genie-chat-wiki-roots`.
- **Signing in.** A model that needs an account says so; `M-x genie-login`
  runs elmee's browser sign-in.

## Install

Not on MELPA yet. With `straight.el`:

```elisp
(use-package genie
  :straight (genie :type git :host github :repo "bes-dev/genie.el")
  :custom (genie-config-root "~/.emacs.d/")   ; must be a git repository
          ;; Frictionless: a wish is validated, committed and hot-reloaded on
          ;; the spot; you judge it in the running editor and C-c g u takes it
          ;; back. Keep the one screen that guards generated code.
          (genie-confirm '(risky-spell))
  :bind (("C-c g g" . genie)
         ("C-c g c" . genie-chat)
         ("C-c g a" . genie-ask)
         ("C-c g d" . genie-diff)
         ("C-c g u" . genie-undo)
         ("C-c g k" . genie-abort)
         ("C-c g s" . genie-spell)
         ("C-c g x" . genie-cast)
         ("C-c g m" . genie-manual))
  :init (dotimes (i 10)                 ; ten programmable spell registers
          (global-set-key (kbd (format "C-c g %d" i)) #'genie-cast-register)))
```

Or clone and `(add-to-list 'load-path "…/genie.el") (require 'genie)`.

You also need **[elmee](https://github.com/bes-dev/elmee)** on `PATH` — a
fast agent microkernel in Rust, driven over the standard
[Agent Client Protocol](https://agentclientprotocol.com) (`elmee --acp`).
Pass a model via `genie-elmee-args`, e.g. `'("-m" "ollama/qwen3-coder:latest")`,
or switch it inside a chat with `C-c C-m`.

## Starting from nothing

The title is a claim, and here is the experiment: a config that contains genie
and nothing else. Everything it will ever have arrives as a wish.

```elisp
;;; init.el --- All you need -*- lexical-binding: t; -*-

(require 'package)
(unless (bound-and-true-p package--initialized) (package-initialize))

;; The genie itself, straight from the repository (Emacs 29+).
(unless (package-installed-p 'genie)
  (package-vc-install "https://github.com/bes-dev/genie.el"))
(require 'genie)

;; Wishes apply as soon as they validate — judge them in the editor,
;; take them back with C-c g u. See `genie-confirm' for the ceremonies.
(setq genie-confirm '(risky-spell))

;; The lamp's controls.
(global-set-key (kbd "C-c g g") #'genie)         ; state a wish
(global-set-key (kbd "C-c g c") #'genie-chat)    ; the chat about this config
(global-set-key (kbd "C-c g a") #'genie-ask)     ; the agent, about where you are
(global-set-key (kbd "C-c g d") #'genie-diff)    ; review the pending diff
(global-set-key (kbd "C-c g u") #'genie-undo)    ; undo the last wish
(global-set-key (kbd "C-c g k") #'genie-abort)   ; abort the turn in flight
(global-set-key (kbd "C-c g s") #'genie-spell)   ; conjure an ephemeral command
(global-set-key (kbd "C-c g x") #'genie-cast)    ; cast the current spell
(global-set-key (kbd "C-c g !") #'genie-cantrip) ; one-shot: conjure and run here
(global-set-key (kbd "C-c g m") #'genie-manual)  ; the manual, grown wish by wish
(dotimes (i 10)                                  ; ten programmable spell registers
  (global-set-key (kbd (format "C-c g %d" i)) #'genie-cast-register))
```

[`bootstrap.sh`](bootstrap.sh) sets this up for you — it writes the init.el
above into `~/.emacs.d` (refusing to touch an existing config) and makes the
directory a git repository, which the wish pipeline requires:

```sh
curl -fsSL https://raw.githubusercontent.com/bes-dev/genie.el/main/bootstrap.sh | bash
```

To try the empty lamp without risking anything, point it elsewhere:

```sh
EMACS_D=/tmp/lamp ./bootstrap.sh && emacs --init-directory /tmp/lamp
```

Then launch Emacs (the first start installs genie from GitHub), rub the lamp
with `C-c g g` — and don't waste wishes on trifles. On Emacs 28, where
`package-vc-install` is missing, clone the repo and use `load-path` as in
[Install](#install).

## A maintainer, not a generator

The agent operates under a *maintainer charter* (the system prompt), built to
keep a config coherent over hundreds of wishes — including a config grown from
an empty `init.el` with nothing but genie in it:

- **Architecture** — `init.el` stays a thin bootstrap; features live in
  one-responsibility modules; the structure is established on the first wish
  and refactored as it grows (extend and simplify instead of adding parallel
  copies; delete what a change obsoletes).
- **Research first** — for any non-trivial wish the agent checks how the
  ecosystem already solves it (built-in feature? established package?) using
  its web tools, and never hand-rolls what a maintained package does better.
  The report names what was considered and why.
- **Documentation** — every definition gets a real docstring, and the agent
  maintains `GENIE.md`: the config's user manual, updated with each
  user-facing change. After apply, genie shows the agent's report — what
  changed and exactly how to use it; `genie-manual` opens the accumulated
  reference.

## Safety model

- **Restore point per wish** — before the agent runs, the worktree is captured
  with `git stash create`; reject restores exactly that state (your own
  uncommitted edits survive, agent-created files are deleted).
- **Validation before review** — `genie-validate` is `'batch` by default: a
  throwaway `emacs --batch -l init.el` must exit cleanly, or apply demands
  explicit confirmation. `'parens` checks bracket balance only; `nil` skips.
- **A broken change never reaches you** — validation failure is the agent's
  problem first: the error is handed back for repair, and a change that
  still will not load is undone rather than applied or dropped in your lap.
- **Ceremony is yours to choose** (`genie-confirm`) — review every diff
  (`diff-mode`, hunk navigation included), or let validated wishes apply on
  the spot and judge them in the editor. Nothing is lost by the latter: a
  failed validation still stops for review, every wish is still one commit,
  and `genie-undo` still takes it back.
- **One wish, one commit** — and `genie-undo` deletes that commit outright
  (after confirmation) instead of leaving a commit/revert pair in the log;
  later edits of your own to the same files are named in the prompt first.
  A config with a remote needs a force-push after an undo.
- **Scoped agent** — the system prompt confines edits to `genie-config-root`;
  interactive approval requests from the agent are denied by policy.
- **Spells never touch disk** — a generated `defun` only defines a command;
  side effects happen when *you* cast it. The agent that writes it has no
  tools at all, so there is nothing it could touch.
- **A turn that did not finish is not applied** — stopped with
  `genie-abort`, cut off by the step limit, or lost with the agent process,
  whatever was half-edited is held for review (`genie-diff`,
  `genie-reject`) rather than validated and committed.
- **Risky code is screened** — conjured code that calls processes, the
  network, file deletion or anything else in `genie-spell-risky-functions`
  needs explicit confirmation *before it is evaluated*; everything else
  stays instant.
- **Undo never surprises** — `genie-undo` pops a session journal of
  genie-made changes; with an empty journal (a fresh Emacs) it *offers* to
  drop a genie commit at HEAD instead of silently doing so.
  `genie-journal` previews the stack.
- **An explicit turn state machine** (`idle → thinking → validating →
  reviewing`) guards every entry point: you cannot apply a stale diff while
  the agent is rewriting it, start a turn mid-validation, or lose typed
  input to a busy error after the fact. Activity is visible in every mode
  line, and if the agent process dies, its stderr tail lands in the
  transcript so the failure has a reason.

## Commands

| Command | Suggested key | Description |
|---|---|---|
| `genie` | `C-c g g` | State a wish from the minibuffer |
| `genie-chat` | `C-c g c` | The chat about this config (RET sends) |
| `genie-ask` | `C-c g a` | The chat for the current project, with the region or file attached |
| `genie-sessions` | `C-c C-s` in a chat | Past conversations of a directory: return, start, delete |
| `genie-login` | — | Sign the agent in (elmee's browser flow) |
| `genie-diff` | `C-c g d` | Review the pending diff (`a` apply, `r` reject) |
| `genie-undo` | `C-c g u` | Undo the last genie-made change, whatever its kind |
| `genie-abort` | `C-c g k` | Abort the turn in flight |
| `genie-spell` | `C-c g s` | Conjure an ephemeral command from a request |
| `genie-cast` | `C-c g x` | Invoke the current spell (`C-u` picks among all) |
| `genie-cast-register` | `C-c g 1`…`0` | Cast the spell stored in that register |
| `genie-cantrip` | `C-c g !` | Conjure a one-shot command and run it right here |
| `genie-spell-bind` | — | Put a conjured spell into a register |
| `genie-spell-keep` | — | Make the current spell permanent |
| `genie-manual` | `C-c g m` | Open the config's user manual, grown wish by wish |
| `genie-journal` | — | Preview what `genie-undo` would undo, newest first |
| `genie-quit` | — | End the agents and close the config chat (fresh charter on the next wish) |

Wishes stated while a diff is pending refine it: the review stays cumulative
against the same restore point.

## Customization

| Variable | Default | Meaning |
|---|---|---|
| `genie-config-root` | `user-emacs-directory` | The git repo genie may edit |
| `genie-validate` | `'batch` | `'batch` / `'parens` / `nil` |
| `genie-confirm` | `'(wish risky-spell undo)` | Which actions stop to ask; the README config drops `wish` |
| `genie-repair-attempts` | `2` | Times a failed change is handed back to the agent |
| `genie-manual-file` | `"GENIE.md"` | The agent-maintained user manual, relative to the root |
| `genie-validate-timeout` | `120` | Seconds before batch validation is killed (package installs are slow) |
| `genie-spell-risky-functions` | processes, network, deletion… | Calls a conjured spell must confirm |
| `genie-elmee-program`, `genie-elmee-args` | | elmee invocation |
| `genie-chat-show-thoughts` | `nil` | Write a model's reasoning into the chat |
| `genie-chat-wiki-roots` | `nil` | Where a `[[wikilink]]` in an answer is looked up |

## The layers

- **`genie-acp.el`** — an [ACP](https://agentclientprotocol.com) client for
  elmee: one warm process, any number of sessions, everything through
  callbacks. Reusable by any Emacs package:

  ```elisp
  (setq agent (genie-acp-agent '("elmee" "--acp")))
  (setq session (genie-acp-open agent "~/project/"
                                :on-text (lambda (delta) …)
                                :on-done (lambda (stop-reason) …)))
  (genie-acp-prompt session "Refactor foo.el")
  ```

- **`genie-chat.el`** — the chat buffer and the list of conversations,
  for any directory.
- **`genie.el`** — the lamp: the wish pipeline around the config's chat,
  spells, and the one undo.

Spells are conjured by a second elmee process that carries no tools, no
history and a one-line system prompt, each in a conversation of its own: a
cantrip sends the model about a kilobyte, not a session's worth — which is
what makes it quick on a local model.

## Development

```
make            # compile (warnings are errors) + checkdoc + tests
make test       # ERT suite — no network, no real agent needed
make lint       # package-lint (installs it from MELPA)
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
