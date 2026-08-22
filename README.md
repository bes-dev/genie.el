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
async RPC agent edits your config files (Pi or elmee backend)
   │
   ▼
validation — a batch subprocess must load init.el cleanly
   │
   ▼
git diff review:  [a] apply   [r] reject   [q] quit
   │ a                                │ r
   ▼                                  ▼
commit "genie: <wish>"            worktree restored
+ hot-reload of changed files     to the pre-wish state
(offers restart when init.el changed)
```

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

The UI never blocks: the agent runs as an async subprocess, tokens and tool
activity stream live into the `*genie*` transcript (which doubles as a
multi-turn chat via `M-x genie-chat`).

## Install

Not on MELPA yet. With `straight.el`:

```elisp
(use-package genie
  :straight (genie :type git :host github :repo "bes-dev/genie.el")
  :custom (genie-config-root "~/.emacs.d/")   ; must be a git repository
  :bind (("C-c g g" . genie)
         ("C-c g c" . genie-chat)
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

You also need one of the agent backends on `PATH`:

- **[elmee](https://github.com/bes-dev/elmee)** (default) — a fast agent
  microkernel in Rust, driven over the standard
  [Agent Client Protocol](https://agentclientprotocol.com) (`elmee --acp`):
  one warm JSON-RPC server process holds the session. Pass a model via
  `genie-elmee-args`, e.g. `'("-m" "ollama/qwen3-coder:latest")`.
- **[Pi](https://github.com/badlogic/pi-mono)** — one persistent
  `pi --mode rpc` process speaking Pi's own line-delimited JSON. Select with
  `(setq genie-backend 'pi)`; pin a model with `genie-pi-model`.

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

;; The lamp's controls.
(global-set-key (kbd "C-c g g") #'genie)         ; state a wish
(global-set-key (kbd "C-c g c") #'genie-chat)    ; multi-turn chat
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
- **Nothing applies silently** — you read the diff (`diff-mode`, hunk
  navigation included) unless you opt into `genie-auto-apply`.
- **One wish, one commit** — and `genie-undo` deletes that commit outright
  (after confirmation) instead of leaving a commit/revert pair in the log;
  later edits of your own to the same files are named in the prompt first.
  A config with a remote needs a force-push after an undo.
- **Scoped agent** — the system prompt confines edits to `genie-config-root`;
  interactive approval requests from the agent are denied by policy.
- **Spells never touch disk** — a generated `defun` only defines a command;
  side effects happen when *you* cast it. If a spell turn did touch files,
  genie warns and routes the changes into the usual review.
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
| `genie-chat` | `C-c g c` | Transcript as a multi-turn chat (RET sends) |
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
| `genie-quit` | — | End the agent session (fresh charter on the next wish) |

Wishes stated while a diff is pending refine it: the review stays cumulative
against the same restore point.

## Customization

| Variable | Default | Meaning |
|---|---|---|
| `genie-backend` | `'pi` | Agent backend: `'pi` or `'elmee` |
| `genie-config-root` | `user-emacs-directory` | The git repo genie may edit |
| `genie-validate` | `'batch` | `'batch` / `'parens` / `nil` |
| `genie-auto-apply` | `nil` | Skip review when validation passes |
| `genie-manual-file` | `"GENIE.md"` | The agent-maintained user manual, relative to the root |
| `genie-validate-timeout` | `120` | Seconds before batch validation is killed (package installs are slow) |
| `genie-spell-risky-functions` | processes, network, deletion… | Calls a conjured spell must confirm |
| `genie-pi-program`, `genie-pi-args`, `genie-pi-model` | | Pi invocation |
| `genie-elmee-program`, `genie-elmee-args` | | elmee invocation |

## genie-rpc: the generic layer

All agent plumbing lives in **`genie-rpc.el`**, an application-agnostic
library you can reuse for any AI-based Emacs package: async stdio transport
with line framing, an [ACP](https://agentclientprotocol.com) client
(JSON-RPC 2.0 with request correlation, the initialize/session handshake and
a prompt queue until the session is open), agent stderr capture, and
normalization of each backend's wire protocol into plain callbacks:

```elisp
(setq rpc (genie-rpc-open 'elmee (list "elmee" "--acp")
                          :directory "~/project/"
                          :on-text  (lambda (delta)  …)
                          :on-tool  (lambda (label)  …)
                          :on-done  (lambda (answer) …)
                          :on-fail  (lambda (msg)    …)))
(genie-rpc-prompt rpc "Refactor foo.el")
```

Adding a backend is one entry in `genie-rpc-backends` — a prompt sender, a
dispatcher and optional handshake/abort hooks. Nothing in `genie.el` knows
any agent's JSON.

## Development

```
make            # compile (warnings are errors) + checkdoc + tests
make test       # ERT suite — no network, no real agent needed
make lint       # package-lint (installs it from MELPA)
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
