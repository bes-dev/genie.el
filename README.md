# genie.el 🧞

*Rub the lamp, state a wish. An AI agent that lives in your Emacs grants it —
and every wish can be taken back.*

[![CI](https://github.com/bes-dev/genie.el/actions/workflows/ci.yml/badge.svg)](https://github.com/bes-dev/genie.el/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Emacs](https://img.shields.io/badge/Emacs-28.1+-7F5AB6?logo=gnu-emacs&logoColor=white)](https://www.gnu.org/software/emacs/)

Install genie and nothing else; the rest of your Emacs arrives as wishes.
`M-x genie` takes one in plain words, and the genie grants it in the form
that fits:

| You wish | The genie | What is left |
|---|---|---|
| *"what does C-x 8 do?"* | asks the running Emacs, and answers | nothing |
| *"sort these lines by the second column"* | runs Lisp right where you are, on your region | an entry `genie-undo` takes back |
| *"duplicate the line on C-c d"* | writes a **wish**: a file of its own in your config | a commit, and a line in the lamp |
| *"show my agenda every morning at nine"* | a wish with a timer in it | the same |

You do not choose the form. A wish that could mean two things is asked about
first, in the minibuffer.

## Wishes can be taken back

Emacs lets any code change anything and remembers none of it: a key bound or
a hook added stays until restart, whatever becomes of the code that did it.
A configuration that rewrites itself while it runs cannot live with that. So
a wish makes its changes through effects that each remember the way back:

```elisp
;;; wishes/duplicate-line.el -*- lexical-binding: t; -*-

(defun my-duplicate-line () ...)

(genie-wish duplicate-line
  "Duplicate the current line with C-c d."
  (genie-key global-map "C-c d" #'my-duplicate-line)
  (genie-set 'scroll-margin 3)
  (genie-hook 'prog-mode-hook #'display-line-numbers-mode)
  (genie-enable 'global-auto-revert-mode)
  (genie-after 'org
    (genie-key org-mode-map "C-c d" #'my-duplicate-line)))
```

Switch it off and the key, the option, the hook and the mode are as they
were — now, without restarting. The effects are `genie-set`, `genie-key`,
`genie-hook`, `genie-advice`, `genie-enable`, `genie-disable`, `genie-add`,
`genie-timer`, and `genie-effect` for anything else that has a way back;
`genie-after` defers part of a wish until a library is loaded.

**The lamp** — `M-x genie-lamp` — lists the wishes your Emacs is made of, as
`list-packages` lists its packages: `t` switches one off or back on, `e`
shows exactly what it changed, `RET` opens its file, `d` forgets it.

A wish that signals is switched off and reported; it never takes the rest of
the configuration down with it. `M-x genie-panic` switches every wish off for
the session when something misbehaves and a wish may be why.

`genie-wish.el` needs nothing else of genie. A configuration made of wishes
starts without an agent anywhere near it:

```elisp
(require 'genie-wish)
(genie-wish-load)
```

## What happens to a wish

```
M-x genie "duplicate the line on C-c d"
   │
   ▼
the genie asks Emacs what is there, then writes wishes/duplicate-line.el
   │
   ▼
can it be taken back?      a bare add-hook or setq goes back to the genie
does the config start?     another Emacs loads init.el; a failure goes back too
   │
   ▼
commit "genie: <wish>"  →  switched on, live
```

A change that fails either check is the genie's problem before it is yours:
the reason goes back to it to fix (twice, by default). If that does not
take, the change is undone and reported in plain words — unless you review
diffs, in which case you get one. To look before anything is applied, keep
`wish` in `genie-confirm`:

```
git diff review:  [a] apply   [r] reject   [q] quit
```

**One undo for everything.** `M-x genie-undo` takes back the latest thing
genie did, whatever its form: a wish (its commit is deleted from history and
it is switched off), a switch in the lamp, or what code did to a buffer —
undone precisely there, even if you have moved on.

## Emacs is the genie's own eyes and hands

Emacs documents itself, so the genie asks it rather than guessing. Five
tools reach the running session, served over the connection that is already
there — no server, no port:

| | |
|---|---|
| `describe` | what a function, option or key is, here and now |
| `apropos` | what there is whose name matches |
| `source` | how something is written |
| `messages` | what Emacs has just said, and warned about |
| `eval` | run Lisp where you asked from, on your region |

## Emacs has one thread, and genie stays off it

Lisp runs on the thread that reads your keys and draws the screen. Nothing
here makes it wait:

- **The agent is another process**, and so is validation: installing a
  package or a loop that never ends costs the Emacs you are typing in
  nothing.
- **Code the genie runs is never run from a process filter**, where it would
  freeze the editor and could not be interrupted. It waits until no
  minibuffer is in use, and `C-g` stops it like any command.
- **Code that reaches outside buffers is screened first** — processes, the
  network, file deletion, Emacs's own lifetime (`genie-risky-functions`).
- **A wish that hooks every keystroke, or waits synchronously, is named**
  before it is applied.
- **What arrives is read in time proportional to its size**: a ten-megabyte
  tool result takes 40 ms to take in, and streaming twenty thousand tokens
  into a chat takes 45.

## Quick magic

For a one-off there is something faster than the genie: a model given no
tools and no history, asked for one command. About a kilobyte goes out, which
is what makes it quick on a local model.

- **Cantrip** — `C-c g !` *"transpose these two columns"*: the command is
  conjured and run right where you asked, on the active region.
- **Spell** — `C-c g s`: conjured to cast again, with `C-c g x` or on one of
  ten digit registers (`C-c g 1` … `C-c g 0`), in the spirit of `C-x r`.
- A spell cast for the third time says how to keep it: `M-x genie-spell-keep`
  makes it a wish.

## The agent, anywhere

The lamp is one use of a general thing: a chat with the
[elmee](https://github.com/bes-dev/elmee) agent about a directory.
`M-x genie-ask` (`C-c g a`) opens the chat for the project you are in and
hands the agent what you are looking at — the active region, or with `C-u`
the whole file (in Dired, the directory). `*genie*` itself is such a chat,
about your config, with the wish pipeline wrapped around every turn. Every
chat's agent can ask the running Emacs what something is and act in it, as
the genie can.

In any chat:

- **Type ahead, and steer.** Answers stream in above the prompt, so the next
  message can be written while the agent works. `RET` sends — and while a
  turn is in flight it does not wait: what you typed reaches that turn as a
  correction, taken up at its next step. `C-c C-k` stops the turn.
- **Go back.** `C-c C-r` rewinds to before any earlier message: the
  conversation, the files as they were before that message's turn changed
  them, or both. The message returns after the prompt to be edited and sent
  again. What followed it is kept as a line of its own, and `C-c C-b`
  returns to it.
- **Skills.** Whatever skills the agent has are commands here: `/pdf
  report.pdf`, `/kb что у меня про X`. `TAB` completes the name, `C-c C-/`
  picks one from a list. A skill is a `SKILL.md` — add a capability by
  dropping a file under `~/.agents/skills/`, no Emacs package needed.
- **Past conversations.** `C-c C-s` (or `M-x genie-sessions`) lists the
  conversations kept for the directory — when, how much was asked, what
  about. `RET` returns to one: the chat fills with what was said and goes on
  from there. `n` starts a new one, `r` gives one a name of its own, `d`
  deletes. They are elmee's files, so they survive restarts; `C-c C-n`
  starts afresh without the list.
- **The model.** `C-c C-m` switches it mid-conversation. The header line
  shows the model, how full its context is, and the step of the plan the
  agent is on.
- **Questions.** When the agent needs a decision it asks in the minibuffer,
  with its options as completions.
- **What happens beside the conversation.** An agent the conversation
  delegated to shows when it starts, what it runs and when it is done, and
  the header counts the ones still working. A context being summarized to
  make room says so, and so does anything that went wrong outside the
  conversation, such as an MCP server that would not start.
- **Links.** Paths in an answer open on `RET`/click; `[[wikilinks]]` open
  the page of that name under `genie-chat-wiki-roots`.
- **Signing in.** A model that needs an account says so; `M-x genie-login`
  runs elmee's browser sign-in.

## Install

You need Emacs 28.1 or later, git, and **[elmee](https://github.com/bes-dev/elmee)**
on `PATH` — a fast agent in Rust that genie drives over the
[Agent Client Protocol](https://agentclientprotocol.com). Pass it a model with
`genie-elmee-args`, e.g. `'("-m" "ollama/qwen3-coder:latest")`, or switch
inside a chat with `C-c C-m`.

**Starting from nothing** — a configuration that contains genie and nothing
else:

```sh
curl -fsSL https://raw.githubusercontent.com/bes-dev/genie.el/main/bootstrap.sh | bash
```

[`bootstrap.sh`](bootstrap.sh) writes a ten-line `init.el` into `~/.emacs.d`
(refusing to touch an existing config), grants the first wish — genie on
`C-c g` — and makes the directory a git repository. To try it without risking
anything:

```sh
EMACS_D=/tmp/lamp ./bootstrap.sh && emacs --init-directory /tmp/lamp
```

**Into a configuration you already have** (Emacs 29+):

```elisp
(package-vc-install "https://github.com/bes-dev/genie.el")
```

then `M-x genie-setup`. It makes the config a git repository if it is not
one, adds the two lines that load wishes to `init.el`, and grants the keys
wish. It only adds what is missing, and what your config already has stays
where it is: the genie edits it in place when a wish is about it.

On `C-c g`, once set up:

| Key | Command | |
|---|---|---|
| `g` | `genie` | state a wish |
| `l` | `genie-lamp` | the wishes, to switch off or look into |
| `u` | `genie-undo` | take back the latest thing genie did |
| `c` | `genie-chat` | the genie's chat |
| `a` | `genie-ask` | a chat about the project you are in |
| `k` | `genie-abort` | stop the turn in flight |
| `d` | `genie-diff` | review the pending diff (`a` apply, `r` reject) |
| `!` | `genie-cantrip` | conjure a command and run it here |
| `s` `x` | `genie-spell`, `genie-cast` | conjure a command; cast it (`C-u` picks) |
| `1`…`0` | `genie-cast-register` | cast the spell in that register |
| `m` | `genie-manual` | the config's manual, grown wish by wish |

Also: `genie-panic`, `genie-journal` (what undo would take back),
`genie-spell-bind`, `genie-spell-keep`, `genie-login`, `genie-quit`.

## Customization

| Variable | Default | Meaning |
|---|---|---|
| `genie-config-root` | `user-emacs-directory` | The git repository genie may edit |
| `genie-wish-directory` | `wishes/` under `user-emacs-directory` | Where wishes are kept |
| `genie-confirm` | `'(wish risky-code undo)` | Which actions stop to ask; drop `wish` to judge changes in the editor instead of in a diff |
| `genie-validate` | `'batch` | `'batch` / `'parens` / `nil` |
| `genie-validate-timeout` | `120` | Seconds before validation is killed (package installs are slow) |
| `genie-repair-attempts` | `2` | Times a refused change goes back to the genie |
| `genie-risky-functions` | processes, network, deletion… | What conjured code must ask before calling |
| `genie-manual-file` | `"GENIE.md"` | The manual the genie keeps, relative to the root |
| `genie-elmee-program`, `genie-elmee-args` | | elmee invocation |
| `genie-chat-show-thoughts` | `nil` | Write a model's reasoning into the chat |
| `genie-chat-wiki-roots` | `nil` | Where a `[[wikilink]]` in an answer is looked up |

## The pieces

One file, one job; each usable without the ones below it.

| File | |
|---|---|
| `genie-wish.el` | Wishes that can be taken back: the effects, switching, loading. Depends on nothing. |
| `genie-acp.el` | An [ACP](https://agentclientprotocol.com) client: one warm process, any number of sessions, tools served back to the agent. |
| `genie-live.el` | Running conjured code in the live session: screened, off the filter, in place, undoable. |
| `genie-tools.el` | Emacs as tools for its agent. |
| `genie-chat.el` | The chat buffer and the list of conversations, for any directory. |
| `genie-pipeline.el` | A change to the configuration, start to finish: check, review, commit, make live, undo. |
| `genie-spell.el` | Cantrips, spells and registers. |
| `genie-lamp.el` | The list of wishes. |
| `genie.el` | The way in: `genie`, the keys, setup. |

`genie-acp.el` is reusable by any Emacs package:

```elisp
(setq agent (genie-acp-agent '("elmee" "--acp")))
(setq session (genie-acp-open agent "~/project/"
                              :on-text (lambda (delta) …)
                              :on-done (lambda (stop-reason) …)
                              :tools genie-tools))
(genie-acp-prompt session "Refactor foo.el")
```

## Development

```
make            # compile (warnings are errors) + checkdoc + tests
make test       # ERT suite — no network, no real agent needed
make lint       # package-lint (installs it from MELPA)
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
