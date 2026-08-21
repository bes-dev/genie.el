;;; genie.el --- Self-modifying config driven by natural-language wishes -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.7.3
;; Package-Requires: ((emacs "28.1"))
;; Keywords: convenience, tools
;; URL: https://github.com/bes-dev/genie.el

;; This file is not part of GNU Emacs.

;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
;; implied.  See the License for the specific language governing
;; permissions and limitations under the License.

;;; Commentary:

;; Rub the lamp (`M-x genie'), state a wish, and an AI agent edits your
;; Emacs configuration.  The change is validated (a batch subprocess must
;; load init.el cleanly), reviewed as a git diff, committed as
;; "genie: <wish>" and hot-reloaded on accept — or restored on reject.
;;
;; Spells are the ephemeral counterpart: `genie-spell' conjures an
;; interactive command from a request, evaluates it straight into the
;; running session (nothing touches disk) and arms it on `genie-cast' and
;; a chosen digit register; `genie-cantrip' conjures a one-shot command
;; and executes it immediately where it was asked from; `genie-spell-keep'
;; turns the current spell into a permanent wish.  Conjured code that
;; calls anything risky (processes, network, file deletion — see
;; `genie-spell-risky-functions') needs explicit confirmation first.
;;
;; `genie-undo' undoes the most recent genie-made change, whatever its
;; kind: an applied wish (git revert + reload) or the buffer effect of a
;; spell, register cast or cantrip.  `genie-journal' previews the stack.
;;
;; Everything is async, built on the genie-rpc library, with two agent
;; backends (`genie-backend'): the elmee agent microkernel by default,
;; driven over the standard Agent Client Protocol (`elmee --acp'), and
;; the Pi coding agent.  A turn's progress is visible in every mode line.
;;
;; Setup:
;;
;;   (require 'genie)
;;   (setq genie-config-root "~/.emacs.d/")   ; must be a git repository
;;   ;; recommended bindings:
;;   (global-set-key (kbd "C-c g g") #'genie)
;;   (global-set-key (kbd "C-c g c") #'genie-chat)
;;   (global-set-key (kbd "C-c g d") #'genie-diff)
;;   (global-set-key (kbd "C-c g u") #'genie-undo)
;;   (global-set-key (kbd "C-c g k") #'genie-abort)
;;   (global-set-key (kbd "C-c g s") #'genie-spell)
;;   (global-set-key (kbd "C-c g x") #'genie-cast)
;;   (global-set-key (kbd "C-c g !") #'genie-cantrip)
;;   (global-set-key (kbd "C-c g m") #'genie-manual)
;;   (dotimes (i 10)                       ; ten programmable spell registers
;;     (global-set-key (kbd (format "C-c g %d" i)) #'genie-cast-register))

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'diff-mode)
(require 'genie-rpc)

(defgroup genie nil
  "Wish-driven, self-modifying Emacs configuration."
  :group 'tools
  :prefix "genie-")

(defcustom genie-backend 'elmee
  "Agent backend: the elmee microkernel agent (default) or the Pi agent.
Elmee is driven over the standard Agent Client Protocol (`elmee --acp');
Pi over its own line-delimited JSON RPC (`pi --mode rpc')."
  :type '(choice (const elmee) (const pi))
  :group 'genie)

(defcustom genie-pi-program "pi"
  "Path to the Pi executable."
  :type 'string :group 'genie)

(defcustom genie-pi-args '("--mode" "rpc" "--no-session")
  "Base arguments for Pi's RPC mode."
  :type '(repeat string) :group 'genie)

(defcustom genie-pi-model nil
  "Extra Pi arguments to pin a provider/model.
For example (\"--model\" \"qwen/qwen3.6-27b\"); nil uses Pi's default."
  :type '(repeat string) :group 'genie)

(defcustom genie-elmee-program "elmee"
  "Path to the elmee executable."
  :type 'string :group 'genie)

(defcustom genie-elmee-args nil
  "Extra elmee arguments, for example (\"-m\" \"ollama/qwen3-coder:latest\").
Nil uses elmee's own model resolution."
  :type '(repeat string) :group 'genie)

(defcustom genie-config-root user-emacs-directory
  "Root of the configuration the genie may edit.
Must be a git repository."
  :type 'directory :group 'genie)

(defcustom genie-validate 'batch
  "Pre-review validation: batch-load init.el, parens-check, or nothing."
  :type '(choice (const batch) (const parens) (const nil))
  :group 'genie)

(defcustom genie-validate-timeout 120
  "Seconds before the batch validation subprocess is killed.
A wish that adds packages makes the validation install them, which can
be slow on the first run — raise this when that bites."
  :type 'integer :group 'genie)

(defcustom genie-auto-apply nil
  "When non-nil, commit and reload without the diff review if validation passes."
  :type 'boolean :group 'genie)

(defcustom genie-manual-file "GENIE.md"
  "The config's user manual, relative to `genie-config-root'.
The agent keeps it updated as the config grows: a concise reference of
the features and keybindings each wish added.  Open it with `genie-manual'."
  :type 'string :group 'genie)

(defcustom genie-spell-risky-functions
  '(shell-command shell-command-to-string async-shell-command
    call-process call-process-region process-file start-process
    start-process-shell-command make-process make-serial-process
    make-network-process open-network-stream url-retrieve
    url-retrieve-synchronously url-copy-file browse-url
    delete-file delete-directory move-file-to-trash write-region
    kill-emacs restart-emacs server-eval-at)
  "Functions a conjured spell may only call after explicit confirmation.
Spells and cantrips are meant to be self-contained buffer commands;
anything reaching processes, the network, file deletion or Emacs's
lifetime is screened before the code is evaluated."
  :type '(repeat symbol) :group 'genie)

(defconst genie-buffer "*genie*"
  "Name of the transcript/chat buffer.")

(defconst genie-diff-buffer "*genie-diff*"
  "Name of the pending-wish review buffer.")

(defvar genie--rpc nil "The `genie-rpc-session' to the agent, or nil.")
(defvar genie--state 'idle
  "The turn state machine: `idle', `thinking', `validating' or `reviewing'.
New turns start from `idle' or `reviewing' (a refinement); `thinking'
covers an agent turn in flight; `validating' the async batch check.")
(defvar genie--tool nil "Name of the tool currently running.")
(defvar genie--seen-text nil "Non-nil once the current turn emitted real text.")
(defvar genie--ctxfile nil "Temp file holding Pi's system-prompt addendum.")
(defvar genie--input-start nil "Marker where the chat input begins.")
(defvar genie--wish nil "Wish text of the pending turn(s), used as commit message.")
(defvar genie--wish-history nil "Minibuffer history for wishes.")
(defvar genie--spell-history nil "Minibuffer history for spells and cantrips.")
(defvar genie--pre nil "Commit capturing the pre-wish worktree (restore point).")
(defvar genie--pre-dirty nil "Files already dirty before the wish.")
(defvar genie--pre-untracked nil "Files already untracked before the wish.")
(defvar genie--changed nil "Files changed by the pending wish.")
(defvar genie--created nil "Files newly created by the pending wish.")
(defvar genie--verdict nil "Validation result (OK . DETAIL), or nil when unknown.")
(defvar genie--turn 'wish "Kind of the turn in flight: `wish', `spell' or `cantrip'.")
(defvar genie--turn-baseline nil "Value of `genie--changed' when the turn started.")
(defvar genie--answer "" "Accumulated answer text of the turn in flight.")
(defvar genie--spell nil "The current conjured spell entry, or nil.")
(defvar genie--spells nil
  "Spell entries (NAME FUNCTION CODE) conjured this session, newest first.
FUNCTION is the captured function object, immune to later redefinitions
of NAME by a newer spell.")
(defvar genie--registers nil "Alist of (DIGIT-CHAR . SPELL-ENTRY) registers.")
(defvar genie--pending-register nil "Register chosen for the spell being conjured.")
(defvar genie--cantrip-target nil "Plist locating where the pending cantrip lands.")
(defvar genie--journal nil
  "Stack of genie-made changes, newest first, popped by `genie-undo'.
An entry is (wish . COMMIT-SUBJECT) for an applied config wish, or
\(cast BUFFER PRE POST NAME) for a spell invocation that edited BUFFER,
where PRE and POST are its `buffer-undo-list' before and after.")

;;;; The state machine

(defconst genie--spinner-frames ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames of the activity spinner.")
(defvar genie--spinner-index 0 "Current frame of the activity spinner.")
(defvar genie--spinner-timer nil "Timer animating the spinner while genie works.")

(defun genie--activity (&optional verbose)
  "Return the spinning activity string for mode lines, or nil when quiet.
With VERBOSE, thinking also names the abort key of the chat buffer."
  (let ((spin (aref genie--spinner-frames
                    (mod genie--spinner-index
                         (length genie--spinner-frames)))))
    (pcase genie--state
      ('thinking
       (format "🧞%s %s" spin
               (cond (genie--tool (concat (truncate-string-to-width
                                           genie--tool 40 nil nil "…")
                                          "…"))
                     (verbose "thinking… (C-c C-k abort)")
                     (t "thinking…"))))
      ('validating (format "🧞%s validating…" spin))
      (_ nil))))

(defun genie--mode-line-string ()
  "Return the global mode-line segment for genie activity."
  (let ((activity (genie--activity)))
    (if activity (concat " " activity) "")))

(defconst genie--mode-line-construct '(:eval (genie--mode-line-string))
  "The canonical global-indicator construct, a trampoline into a function.")

(defvar genie--mode-line genie--mode-line-construct
  "Mode-line construct showing genie activity in every buffer.
`genie--install-indicator' re-canonicalizes this on every turn, healing
values left bound by an older genie in a hot-reloaded session.")
(put 'genie--mode-line 'risky-local-variable t)

(defun genie--spinner-tick ()
  "Advance the activity spinner and repaint, stopping when genie is quiet."
  (if (memq genie--state '(thinking validating))
      (progn (setq genie--spinner-index (1+ genie--spinner-index))
             (force-mode-line-update t))
    (when genie--spinner-timer
      (cancel-timer genie--spinner-timer)
      (setq genie--spinner-timer nil))))

(defun genie--set-state (state)
  "Move the turn machine to STATE, drive the spinner, refresh mode lines."
  (setq genie--state state)
  (cond ((memq state '(thinking validating))
         (unless genie--spinner-timer
           (setq genie--spinner-index 0
                 genie--spinner-timer
                 (run-at-time 0 0.12 #'genie--spinner-tick))))
        (genie--spinner-timer
         (cancel-timer genie--spinner-timer)
         (setq genie--spinner-timer nil)))
  (force-mode-line-update t))

(defun genie--require-ready ()
  "Signal a friendly error unless a new turn may start now."
  (pcase genie--state
    ('thinking (user-error "Genie is busy — wait, or M-x genie-abort"))
    ('validating (user-error "Genie is validating the last change — a moment"))
    (_ nil)))

(defun genie--install-indicator ()
  "Add the genie activity element to `global-mode-string' once.
Also heal a `genie--mode-line' value left bound by an older genie:
`defvar' keeps old values across a hot reload, and a stale static
construct is what a frozen spinner looks like."
  (setq genie--mode-line genie--mode-line-construct)
  (cond ((not (listp global-mode-string))
         (setq global-mode-string (list "" global-mode-string 'genie--mode-line)))
        ((not (memq 'genie--mode-line global-mode-string))
         (setq global-mode-string
               (append global-mode-string '(genie--mode-line))))))

;;;; Git plumbing

(defun genie--root ()
  "Return `genie-config-root' as an expanded directory name."
  (file-name-as-directory (expand-file-name genie-config-root)))

(defun genie--git (&rest args)
  "Run git ARGS in the config root; return trimmed output, signal on failure."
  (with-temp-buffer
    (let ((default-directory (genie--root)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "Genie: git %s failed — %s"
               (car args) (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun genie--untracked ()
  "Return the list of untracked files in the config root."
  (split-string (genie--git "ls-files" "--others" "--exclude-standard") "\n" t))

(defun genie--snapshot ()
  "Capture the pre-wish worktree: a restore point plus dirty baselines."
  (let ((stash (genie--git "stash" "create" "genie pre-wish")))
    (setq genie--pre (if (string-empty-p stash) "HEAD" stash)))
  (setq genie--pre-dirty (split-string (genie--git "diff" "--name-only" "HEAD")
                                       "\n" t)
        genie--pre-untracked (genie--untracked)
        genie--created nil))

(defun genie--detect-changes ()
  "Record in `genie--changed' and `genie--created' what changed since the snapshot."
  (let ((new (cl-set-difference (genie--untracked) genie--pre-untracked
                                :test #'equal)))
    (when new                      ; intent-to-add: show up in git diff/commit
      (apply #'genie--git "add" "-N" "--" new)
      (setq genie--created (cl-union genie--created new :test #'equal)))
    (setq genie--changed
          (cl-union (split-string (genie--git "diff" "--name-only" genie--pre)
                                  "\n" t)
                    new :test #'equal))))

;;;; The agent session

(defun genie--context-prompt ()
  "Return the system-prompt addendum: the maintainer charter for the agent."
  (let ((root (genie--root)))
    (format "You are the resident genie of the Emacs configuration at `%s`, \
currently running live in Emacs %s. The user states wishes in natural \
language; fulfill them by editing the config files with your edit tools. \
You are not a code generator — you are this configuration's long-term \
maintainer, and every wish must leave it better engineered than you found it.

Architecture:
- `init.el' is a thin bootstrap: package-manager setup and module wiring \
only. Feature code lives in one-responsibility module files — in the \
config's existing module directory if it has one, otherwise create \
`modules/' and wire it from `init.el'.
- Starting from an empty or single-package config is normal: establish \
this structure with the first wish and grow it incrementally.
- Prefer, in order: built-in Emacs features; established, maintained \
packages (installed through the config's package manager, wired with \
`use-package'); custom code last, and only as much as the wish needs.
- Refactor as you go: when a wish overlaps existing code, extend or \
simplify it instead of adding a parallel copy; delete code your change \
obsoletes. No dead code, no duplication, minimal diffs, style matching \
the surrounding file, lexical-binding everywhere.

Research:
- For any wish that is not trivially obvious, first check how the Emacs \
ecosystem already solves it — a built-in feature, a well-known package, an \
established idiom — using your web search/fetch tools when available. \
Never hand-roll what a maintained package does better. Name in the report \
what you considered and why you chose what you chose.

Documentation:
- Every defun, defvar and defcustom you write gets a proper docstring: \
first line a complete sentence, arguments documented.
- Maintain `%s' (relative to the config root) as the config's user \
manual: a concise, well-organized reference of the features and \
keybindings this config provides. Update the relevant section with every \
wish that adds or changes something user-facing; create the file on first \
need.
- Finish every wish with a short report in the user's language: what \
changed, how to use it (exact keys and commands), what you researched and \
rejected, and whether a full Emacs restart is needed.

Hard rules:
- Edit ONLY files under the config root, using ABSOLUTE paths; never cd; \
never touch `.git/'.
- Do NOT run git and do NOT reload or restart Emacs — the Emacs side \
validates, commits and hot-reloads your edits itself."
            root emacs-version genie-manual-file)))

(defun genie--command ()
  "Return the agent argv for the configured backend, system prompt included."
  (pcase genie-backend
    ('elmee (append (list genie-elmee-program "--acp"
                          "--append-system-prompt" (genie--context-prompt))
                    genie-elmee-args))
    (_ (setq genie--ctxfile
             (make-temp-file "genie-ctx" nil ".md" (genie--context-prompt)))
       (append (list genie-pi-program) genie-pi-args genie-pi-model
               (list "--append-system-prompt" genie--ctxfile)))))

(defun genie--ensure-session ()
  "Create (or recreate after a backend switch) the agent RPC session."
  (when (and genie--rpc
             (not (eq (genie-rpc-session-backend genie--rpc) genie-backend)))
    (genie-rpc-close genie--rpc)
    (setq genie--rpc nil))
  (unless genie--rpc
    (setq genie--rpc
          (genie-rpc-open genie-backend (genie--command)
                          :directory (genie--root)
                          :on-text #'genie--on-text
                          :on-tool #'genie--on-tool
                          :on-done #'genie--on-done
                          :on-fail #'genie--on-fail
                          :on-exit #'genie--on-exit))))

(defun genie--on-text (delta)
  "Stream answer DELTA; swallow the blank chunks around tool activity."
  (setq genie--tool nil
        genie--answer (concat genie--answer delta))
  (if genie--seen-text
      (genie--emit delta)
    (let ((trimmed (string-trim-left delta)))
      (unless (string-empty-p trimmed)
        (setq genie--seen-text t)
        (genie--emit trimmed)))))

(defun genie--on-tool (name)
  "Show tool NAME as the current activity."
  (setq genie--tool name)
  (message "🧞 %s…" name)
  (force-mode-line-update t))

(defun genie--on-done (answer)
  "End the turn; emit ANSWER when nothing was streamed."
  (when (and answer (not genie--seen-text))
    (genie--on-text answer))
  (genie--finish-turn))

(defun genie--on-fail (msg)
  "Report agent failure MSG and end the turn (partial edits still reviewed)."
  (genie--emit (format "\n[%s]\n" msg) 'error)
  (genie--finish-turn))

(defun genie--on-exit ()
  "Handle the agent process dying; salvage a turn that was in flight.
The agent's stderr tail is surfaced so a startup failure has a reason."
  (when (eq genie--state 'thinking)
    (genie--emit "\n[genie: agent process exited]\n" 'error)
    (when-let* ((err (genie-rpc-stderr genie--rpc)))
      (genie--emit (concat err "\n") 'error))
    (display-buffer (genie--buffer))
    (genie--finish-turn))
  (force-mode-line-update t))

(defun genie--cleanup ()
  "Close the RPC session and delete temp files (Emacs exit / `genie-quit')."
  (when genie--rpc
    (genie-rpc-close genie--rpc)
    (setq genie--rpc nil))
  (when (and genie--ctxfile (file-exists-p genie--ctxfile))
    (ignore-errors (delete-file genie--ctxfile)))
  (setq genie--turn 'wish
        genie--cantrip-target nil genie--pending-register nil)
  (genie--set-state 'idle))

(add-hook 'kill-emacs-hook #'genie--cleanup)

;;;; Transcript buffer / turns

(defconst genie--chat-mode-line
  '(" " (:propertize "%b" face mode-line-buffer-id)
    (:eval (let ((activity (genie--activity t)))
             (if activity (concat "  " activity) ""))))
  "Mode-line format of the chat buffer, shared so it can be healed.")

(defvar genie-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'genie-send)
    (define-key map (kbd "C-j") #'newline)
    (define-key map (kbd "C-c C-k") #'genie-abort)
    map)
  "Keymap for `genie-mode'.")

(define-derived-mode genie-mode fundamental-mode "genie"
  "Chat with the config genie; RET sends, \\[genie-abort] aborts.
Killing this buffer only discards the transcript view — the agent
session lives on; `genie-quit' ends it."
  (setq-local mode-line-format genie--chat-mode-line)
  (visual-line-mode 1))

(defun genie--insert-prompt ()
  "Append a fresh input prompt to the transcript."
  (goto-char (point-max))
  (insert "\n\n" (propertize "❯ " 'face 'minibuffer-prompt))
  (setq genie--input-start (point-marker)))

(defun genie--buffer ()
  "Return the transcript buffer, creating and priming it when needed."
  (let ((buf (get-buffer-create genie-buffer)))
    (with-current-buffer buf
      (unless (derived-mode-p 'genie-mode) (genie-mode))
      (setq-local mode-line-format genie--chat-mode-line) ; heal after reload
      (when (= (point-min) (point-max))
        (insert (propertize "🧞 genie — wishes edit this very Emacs config"
                            'face 'shadow))
        (genie--insert-prompt)))
    buf))

(defun genie--emit (text &optional face)
  "Append TEXT (optionally with FACE) to the transcript and follow the tail."
  (with-current-buffer (genie--buffer)
    (save-excursion
      (goto-char (point-max))
      (insert (if face (propertize text 'face face) text)))
    (when-let* ((window (get-buffer-window (current-buffer))))
      (set-window-point window (point-max)))))

(defun genie--submit (wish &optional label turn)
  "Send WISH to the agent as a TURN (default a config wish).
The transcript and commit message use LABEL.  On any error the turn
state — including a pending register or cantrip target — is rolled back."
  (genie--require-ready)
  (condition-case err
      (progn
        (genie--ensure-session)
        (unless genie--changed       ; refining a pending wish keeps its baseline
          (genie--snapshot)
          (setq genie--wish nil))
        (setq genie--turn-baseline genie--changed)
        (let ((label (or label wish)))
          (setq genie--wish (if genie--wish (concat genie--wish "; " label) label))
          (with-current-buffer (genie--buffer)
            (when (markerp genie--input-start)
              (goto-char genie--input-start)
              (forward-line 0)
              (delete-region (point) (point-max)))
            (goto-char (point-max))
            (insert (propertize "You: " 'face 'font-lock-keyword-face)
                    label "\n\n")))
        (setq genie--turn (or turn 'wish)
              genie--seen-text nil genie--tool nil genie--answer "")
        (genie--install-indicator)
        (genie--set-state 'thinking)
        (message "🧞 genie is working… (M-x genie-abort interrupts)")
        (genie-rpc-prompt genie--rpc wish))
    (error
     (setq genie--turn 'wish
           genie--pending-register nil genie--cantrip-target nil)
     (genie--set-state (if genie--changed 'reviewing 'idle))
     (signal (car err) (cdr err)))))

(defun genie--finish-turn ()
  "End the turn in flight: arm a spell, or detect, validate and review edits.
A no-op unless a turn is actually in flight, so late or duplicate agent
events cannot re-run the pipeline."
  (when (eq genie--state 'thinking)
    (setq genie--tool nil)
    (with-current-buffer (genie--buffer) (genie--insert-prompt))
    (genie--detect-changes)
    (cond
     ((memq genie--turn '(spell cantrip))
      (let ((cast-now (eq genie--turn 'cantrip)))
        (setq genie--turn 'wish)
        (when (cl-set-difference genie--changed genie--turn-baseline
                                 :test #'equal)
          (message "⚠ the spell also touched files — review with M-x genie-diff"))
        (genie--learn-spell genie--answer cast-now)
        (genie--set-state 'idle)))
     ((null genie--changed)
      (setq genie--verdict nil)
      (genie--set-state 'idle)
      (display-buffer (genie--buffer))
      (message "🧞 done — no config changes"))
     (t
      (genie--set-state 'validating)
      (message "🧞 validating %d file(s)…" (length genie--changed))
      (genie--validate
       (lambda (verdict)
         (when (eq genie--state 'validating) ; ignore a stale callback
           (setq genie--verdict verdict)
           (genie--set-state 'reviewing)
           (if (and genie-auto-apply (car verdict))
               (genie-apply)
             (genie--show-diff)))))))))

;;;; Validation

(defun genie--validate (callback)
  "Validate the changed config per `genie-validate'; CALLBACK gets (OK . DETAIL)."
  (pcase genie-validate
    ('batch (genie--batch-check callback))
    ('parens (funcall callback (genie--parens-check)))
    (_ (funcall callback '(t . "validation skipped")))))

(defun genie--parens-check ()
  "Check every changed Elisp file for balanced brackets; return (OK . DETAIL)."
  (catch 'bad
    (dolist (file genie--changed '(t . "parens OK"))
      (when (string-suffix-p ".el" file)
        (with-temp-buffer
          (insert-file-contents (expand-file-name file (genie--root)))
          (delay-mode-hooks (emacs-lisp-mode))
          (condition-case err (check-parens)
            (error (throw 'bad
                          (cons nil (format "%s:%d: %s"
                                            file (line-number-at-pos)
                                            (error-message-string err)))))))))))

(defun genie--batch-check (callback)
  "Load init.el in a batch subprocess; CALLBACK gets (OK . DETAIL).
The config must still boot cleanly with the pending edits in place.
A run over `genie-validate-timeout' seconds is killed and reported as a
timeout rather than as a config failure."
  (let* ((buf (generate-new-buffer " *genie-validate*"))
         (proc (make-process
                :name "genie-validate" :buffer buf :noquery t
                :command (list (expand-file-name invocation-name
                                                 invocation-directory)
                               "--batch" "-l"
                               (expand-file-name "init.el" (genie--root)))
                :sentinel
                (lambda (proc _event)
                  (unless (process-live-p proc)
                    (let ((ok (zerop (process-exit-status proc)))
                          (out (with-current-buffer buf
                                 (string-trim (buffer-string)))))
                      (kill-buffer buf)
                      (funcall
                       callback
                       (cons ok
                             (cond
                              (ok "init.el loads cleanly")
                              ((process-get proc 'genie--timeout)
                               (format "validation timed out after %ss — raise `genie-validate-timeout'"
                                       genie-validate-timeout))
                              (t (truncate-string-to-width
                                  (or (car (last (split-string out "\n" t)))
                                      "batch load failed")
                                  200)))))))))))
    (run-at-time genie-validate-timeout nil
                 (lambda ()
                   (when (process-live-p proc)
                     (process-put proc 'genie--timeout t)
                     (kill-process proc))))))

;;;; Review: diff buffer, apply / reject

(defvar genie-diff--override-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map diff-mode-shared-map)
    (define-key map "a" #'genie-apply)
    (define-key map "r" #'genie-reject)
    (define-key map "q" #'quit-window)
    map)
  "Review keys; wins over `diff-mode-shared-map' in the read-only buffer.")

(define-derived-mode genie-diff-mode diff-mode "genie-diff"
  "Review a pending wish: \\`a' applies, \\`r' rejects."
  (setq buffer-read-only t)
  (push (cons 'buffer-read-only genie-diff--override-map)
        minor-mode-overriding-map-alist))

(defun genie--show-diff ()
  "Pop the review buffer for the pending wish."
  (let ((diff (apply #'genie--git "diff" genie--pre "--" genie--changed))
        (mixed (cl-intersection genie--changed genie--pre-dirty :test #'equal))
        (buf (get-buffer-create genie-diff-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert
         (propertize (format "🧞 wish: %s\n" genie--wish) 'face 'bold)
         (pcase genie--verdict
           (`(t . ,detail) (propertize (format "✓ %s\n" detail) 'face 'success))
           (`(nil . ,detail)
            (propertize (format "✗ validation FAILED: %s\n" detail)
                        'face 'error))
           (_ (propertize "· not validated\n" 'face 'shadow)))
         (format "files: %s\n" (string-join genie--changed " · "))
         (if mixed
             (propertize (format "⚠ includes your earlier uncommitted edits: %s\n"
                                 (string-join mixed " · "))
                         'face 'warning)
           "")
         (propertize
          "[a] apply · commit · reload    [r] reject (restore)    [q] quit\n\n"
          'face 'shadow)
         diff "\n"))
      (genie-diff-mode)
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defun genie--reset ()
  "Forget the pending wish's change set."
  (setq genie--changed nil genie--created nil genie--verdict nil))

(defun genie--quit-diff ()
  "Dismiss the review window when it is showing."
  (when-let* ((window (get-buffer-window genie-diff-buffer)))
    (quit-window nil window)))

(defun genie--reload (files)
  "Hot-reload changed Elisp FILES — init.el included, not just modules.
Modules load first so init.el's wiring (use-package declarations,
keybindings) picks up their fresh definitions; a file that fails to
load falls back to offering a full restart."
  (let* ((root (genie--root))
         (els (cl-remove-if-not (lambda (f) (string-suffix-p ".el" f)) files))
         (init (member "init.el" els))
         (ordered (append (cl-remove "init.el" els :test #'equal)
                          (and init '("init.el"))))
         failed)
    (when ordered
      (message "🧞 reloading… (a first-time package install may take a while)")
      (dolist (file ordered)
        (condition-case err
            (load (expand-file-name file root) nil t)
          (error (push (format "%s: %s" file (error-message-string err))
                       failed))))
      (if failed
          (when (y-or-n-p (format "Reload failed (%s) — restart Emacs? "
                                  (string-join (nreverse failed) "; ")))
            (if (fboundp 'restart-emacs) (restart-emacs)
              (message "🧞 restart-emacs unavailable — please restart manually")))
        (message "🧞 reloaded: %s%s" (string-join ordered " · ")
                 (if init " — restart if anything misbehaves" ""))))))

;;;###autoload
(defun genie-diff ()
  "Show (or re-show) the diff of the pending change set."
  (interactive)
  (unless genie--changed (user-error "Genie: no pending changes"))
  (unless (memq genie--state '(idle reviewing))
    (genie--require-ready))
  (genie--set-state 'reviewing)
  (genie--show-diff))

(defun genie-apply ()
  "Commit the pending wish and hot-reload the changed files."
  (interactive)
  (unless (eq genie--state 'reviewing)
    (user-error "Genie: nothing under review (state: %s)" genie--state))
  (let ((ok (car-safe genie--verdict)))
    (unless ok
      (let ((why (if genie--verdict
                     (format "Validation failed (%s)" (cdr genie--verdict))
                   "The change set was not validated")))
        (unless (yes-or-no-p (format "%s — apply anyway? " why))
          (user-error "Genie: not applied")))))
  (apply #'genie--git "commit" "-m" (format "genie: %s" genie--wish)
         "--" genie--changed)
  (push (cons 'wish (car (split-string (format "genie: %s" genie--wish) "\n")))
        genie--journal)
  (let ((files genie--changed))
    (genie--reset)
    (genie--quit-diff)
    (genie--set-state 'idle)
    (message "🧞 wish applied and committed")
    (genie--reload files)
    ;; The agent's report documents what was added and how to use it.
    (display-buffer (genie--buffer))))

(defun genie-reject ()
  "Discard the pending wish: restore every touched file to its pre-wish state."
  (interactive)
  (unless (eq genie--state 'reviewing)
    (user-error "Genie: nothing under review (state: %s)" genie--state))
  (when-let* ((tracked (cl-set-difference genie--changed genie--created
                                          :test #'equal)))
    ;; --worktree only: restoring via checkout would stage the files, and a
    ;; non-clean index later blocks `git revert' in `genie-undo'.
    (apply #'genie--git "restore" "--source" genie--pre "--worktree"
           "--" tracked))
  (dolist (file genie--created)
    (genie--git "restore" "--staged" "--" file)
    (ignore-errors (delete-file (expand-file-name file (genie--root)))))
  (genie--reset)
  (genie--quit-diff)
  (genie--set-state 'idle)
  (message "🧞 wish rejected — config restored"))

;;;; The undo journal — one `genie-undo' for every kind of change

(defun genie--call-spell (name fn)
  "Invoke spell FN (shown as NAME), journaling its edits for `genie-undo'."
  (let ((buf (current-buffer)) pre)
    (undo-boundary)
    (setq pre buffer-undo-list)
    (unwind-protect (call-interactively fn)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (undo-boundary)
          (unless (or (eq buffer-undo-list t) (eq buffer-undo-list pre))
            (push (list 'cast buf pre buffer-undo-list name)
                  genie--journal)))))))

(defun genie--undo-prefix (list tail)
  "Return the entries of undo LIST that precede TAIL, or nil if TAIL is gone."
  (let (acc)
    (while (and list (not (eq list tail)))
      (push (car list) acc)
      (setq list (cdr list)))
    (and list (nreverse acc))))

(defun genie--undo-cast (entry)
  "Undo the buffer effect recorded in cast ENTRY.
Robust against an undo history that has aged: when garbage collection
has truncated the recorded tail away but the buffer is untouched since
the cast, the cast's changes are still the head of the list and are
undone whole; a history rebuilt from scratch (a buffer revert) means
the effect is already gone, which is reported instead of erroring."
  (pcase-let ((`(cast ,buf ,pre ,post ,name) entry))
    (if (not (buffer-live-p buf))
        (message "🧞 %s's buffer is gone — nothing left to undo there" name)
      (with-current-buffer buf
        (let ((entries (genie--undo-prefix buffer-undo-list pre)))
          (cond
           (entries                     ; the recorded tail is still in place
            (when (and (not (eq buffer-undo-list post))
                       (not (y-or-n-p
                             (format "Edits made after %s revert too — continue? "
                                     name))))
              (user-error "Genie: not undone"))
            (primitive-undo (1+ (cl-count nil entries)) entries)
            (message "🧞 undone: %s in %s" name (buffer-name)))
           ((eq buffer-undo-list post)  ; untouched since; older history GC'd
            (primitive-undo (1+ (cl-count nil buffer-undo-list))
                            buffer-undo-list)
            (message "🧞 undone: %s in %s" name (buffer-name)))
           (t                           ; rebuilt from scratch — revert did it
            (message "🧞 %s: %s's undo history was rebuilt (reverted?) — the \
effect is already gone; C-/ if not" name (buffer-name)))))))))

(defun genie--undo-wish (subject)
  "Revert the newest genie commit; SUBJECT, when given, must match HEAD.
Without SUBJECT (the empty-journal fallback) the revert is confirmed
first — undoing \"the last thing\" must never surprise-revert a commit."
  (let ((head (genie--git "log" "-1" "--format=%s")))
    (unless (string-prefix-p "genie: " head)
      (if subject
          (user-error "Genie: HEAD is not a genie commit (%s)" head)
        (user-error "Genie: nothing to undo — the session journal is empty \
and HEAD is not a genie commit")))
    (when (and subject (not (equal subject head)))
      (user-error "Genie: HEAD moved since that wish (now at: %s)" head))
    (unless (or subject
                (y-or-n-p (format "No genie change journaled this session — revert \"%s\"? "
                                  head)))
      (user-error "Genie: not reverted"))
    (let ((files (split-string (genie--git "diff" "--name-only" "HEAD~" "HEAD")
                               "\n" t)))
      (genie--git "revert" "--no-edit" "HEAD")
      (message "🧞 reverted: %s (definitions it added stay loaded until restart)"
               head)
      (genie--reload
       (cl-remove-if-not
        (lambda (f) (file-exists-p (expand-file-name f (genie--root))))
        files)))))

;;;###autoload
(defun genie-undo ()
  "Undo the most recent genie-made change, whatever its kind.
An applied wish is reverted with `git revert' and its files re-reloaded;
the buffer effect of a spell, register cast or cantrip is undone in the
buffer it edited.  When the session journal is empty (a fresh Emacs),
offers to revert HEAD if it is a genie commit.  `genie-journal' previews
the stack."
  (interactive)
  (unless (eq genie--state 'idle)
    (user-error "Genie: finish the current cycle first (state: %s)"
                genie--state))
  (let ((entry (car genie--journal)))
    (pcase entry
      (`(cast . ,_) (genie--undo-cast entry))
      (`(wish . ,subject) (genie--undo-wish subject))
      (_ (genie--undo-wish nil)))
    (when entry (pop genie--journal))))

;;;###autoload
(defun genie-journal ()
  "Show what `genie-undo' would undo, newest first."
  (interactive)
  (if (null genie--journal)
      (message "🧞 journal empty — undo would offer the last genie commit")
    (message "%s"
             (mapconcat
              (lambda (entry)
                (pcase entry
                  (`(wish . ,subject) (format "wish  %s" subject))
                  (`(cast ,buf ,_ ,_ ,name)
                   (format "cast  %s in %s" name
                           (if (buffer-live-p buf) (buffer-name buf)
                             "a dead buffer")))))
              genie--journal "\n"))))

;;;; Spells — ephemeral conjured commands, nothing on disk

(defun genie--spell-name (entry) "NAME of spell ENTRY." (nth 0 entry))
(defun genie--spell-fn (entry) "Function object of spell ENTRY." (nth 1 entry))
(defun genie--spell-code (entry) "Source code of spell ENTRY." (nth 2 entry))

(defun genie--extract-elisp (text)
  "Return the first fenced code block in TEXT, or TEXT itself."
  (if (string-match "```[a-z-]*\n\\(\\(?:.\\|\n\\)*?\\)```" text)
      (match-string 1 text)
    text))

(defun genie--risky-calls (code)
  "Return the `genie-spell-risky-functions' that CODE mentions."
  (let (found)
    (with-temp-buffer
      (insert code)
      (goto-char (point-min))
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (cl-labels ((walk (x)
                            (cond ((consp x) (walk (car x)) (walk (cdr x)))
                                  ((and (symbolp x)
                                        (memq x genie-spell-risky-functions))
                                   (cl-pushnew x found)))))
                (walk form))))
        (error nil)))
    (nreverse found)))

(defun genie--eval-spell (code)
  "Eval CODE and return the freshly defined interactive command."
  (let (fn)
    (with-temp-buffer
      (insert code)
      (goto-char (point-min))
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (eval form t)
              (when (and (eq (car-safe form) 'defun) (commandp (cadr form)))
                (setq fn (cadr form)))))
        (end-of-file nil)))
    (unless fn (error "The reply defines no interactive command"))
    fn))

(defun genie--read-register (prompt &optional allow-skip)
  "Read a spell register digit with PROMPT; RET skips when ALLOW-SKIP."
  (let ((char (read-char prompt)))
    (cond ((and allow-skip (memq char '(?\r ?\n))) nil)
          ((<= ?0 char ?9) char)
          (t (user-error "Genie: a register is a digit 0-9")))))

(defun genie--bind-register (digit entry)
  "Store spell ENTRY in register DIGIT (a character), reporting evictions."
  (when-let* ((old (alist-get digit genie--registers)))
    (unless (eq old entry)
      (message "🧞 register %c: %s evicted" digit (genie--spell-name old))))
  (setf (alist-get digit genie--registers) entry))

(defun genie--spell-labels ()
  "Return an alist of unique display label to spell entry, newest first.
An older spell whose name a newer one reused is labeled NAME<2>, NAME<3>…"
  (let ((seen (make-hash-table :test 'eq)) acc)
    (dolist (entry genie--spells (nreverse acc))
      (let* ((name (genie--spell-name entry))
             (n (cl-incf (gethash name seen 0)))
             (label (if (= n 1) (symbol-name name) (format "%s<%d>" name n))))
        (push (cons label entry) acc)))))

(defun genie--learn-spell (answer &optional cast-now)
  "Extract the conjured command from ANSWER, screen it, eval it, arm it.
Risky calls (see `genie-spell-risky-functions') need confirmation before
anything is evaluated.  With CAST-NOW (a cantrip), immediately invoke
the command where it was asked from."
  (condition-case err
      (let* ((code (string-trim (genie--extract-elisp answer)))
             (risky (genie--risky-calls code)))
        (when risky
          (display-buffer (genie--buffer))
          (unless (yes-or-no-p (format "⚠ The conjured code calls %s — allow? "
                                       (mapconcat #'symbol-name risky ", ")))
            (error "Spell discarded — its code is in the %s buffer"
                   genie-buffer)))
        (let* ((fn (genie--eval-spell code))
               (entry (list fn (symbol-function fn) code)))
          (push entry genie--spells)
          (setq genie--spell entry)
          (when genie--pending-register
            (genie--bind-register genie--pending-register entry))
          (if cast-now
              (genie--cast-at-target entry)
            (message "🧞 spell armed: %s — cast with M-x genie-cast%s" fn
                     (if genie--pending-register
                         (format " or register %c" genie--pending-register)
                       "")))))
    (error (display-buffer (genie--buffer))
           (message "🧞 spell failed: %s" (error-message-string err))))
  (setq genie--pending-register nil genie--cantrip-target nil))

;;;###autoload
(defun genie-spell (request &optional register)
  "Conjure an ephemeral interactive command implementing REQUEST.
The generated function is evaluated into the running session (no files
are touched) and armed on `genie-cast'; with REGISTER (a digit
character) it also lands in that spell register, castable via
`genie-cast-register'.  `genie-spell-keep' makes a spell permanent."
  (interactive
   (progn
     (genie--require-ready)
     (list (string-trim (read-string "🧞 Spell (command to conjure): "
                                     nil 'genie--spell-history))
           (genie--read-register "🧞 Register for it (0-9, RET to skip): " t))))
  (when (string-empty-p request) (user-error "Empty spell"))
  (setq genie--pending-register register)
  (genie--submit
   (format "SPELL MODE — do NOT edit, create or run anything; this is pure \
code generation. Reply with ONLY one Emacs Lisp code block containing a \
single interactive `defun' (a command) implementing: %s. Requirements: \
self-contained (built-ins and already-loaded libraries only), safe under \
lexical binding, operate on the active region when that is the natural \
reading, docstring in the user's language, name it \
`genie-spell/<short-name>'. No commentary outside the code block." request)
   (format "spell: %s" request)
   'spell))

(defun genie--cast-at-target (entry)
  "Invoke cantrip ENTRY in the buffer (and on the region) it was asked from."
  (let* ((target genie--cantrip-target)
         (buf (plist-get target :buffer))
         (region (plist-get target :region))
         (name (genie--spell-name entry)))
    (setq genie--cantrip-target nil)
    (if (not (buffer-live-p buf))
        (message "🧞 %s armed, but its buffer is gone — cast it manually" name)
      (with-current-buffer buf
        (if region
            (progn (goto-char (cdr region))
                   (push-mark (car region) t t))
          (goto-char (plist-get target :point)))
        (let ((before-journal genie--journal)
              (before-message (current-message)))
          (genie--call-spell name (genie--spell-fn entry))
          ;; The cantrip's own words own the echo area; genie only adds the
          ;; undo hint when there is an effect to undo, and speaks for
          ;; itself only when the cantrip said nothing.
          (let ((journaled (not (eq genie--journal before-journal)))
                (spoke (let ((now (current-message)))
                         (and now (not (equal now before-message)) now))))
            (cond
             ((and spoke journaled)
              (message "%s — 🧞 genie-undo reverts it" spoke))
             (spoke)
             (journaled (message "🧞 %s — M-x genie-undo reverts it" name))
             (t (message "🧞 %s" name)))))))))

;;;###autoload
(defun genie-cantrip (request)
  "Conjure and IMMEDIATELY execute a one-shot command implementing REQUEST.
The generated command runs right where it was asked from — this buffer,
on the active region when there is one.  Its effect is reverted by
`genie-undo'; the command also stays armed as the current spell, so a
cantrip worth repeating can be re-cast (`genie-cast'), slotted into a
register (`genie-spell-bind') or made permanent (`genie-spell-keep')."
  (interactive
   (progn
     (genie--require-ready)
     (list (string-trim (read-string "🧞 Cantrip (do right now): "
                                     nil 'genie--spell-history)))))
  (when (string-empty-p request) (user-error "Empty cantrip"))
  (setq genie--cantrip-target
        (list :buffer (current-buffer)
              :point (point-marker)
              :region (when (use-region-p)
                        (cons (copy-marker (region-beginning))
                              (copy-marker (region-end))))))
  (genie--submit
   (format "CANTRIP MODE — a one-shot action; do NOT edit, create or run \
anything: this is pure code generation. Reply with ONLY one Emacs Lisp code \
block containing a single interactive `defun' (a command) implementing: %s. \
The command will be executed IMMEDIATELY in the buffer it was requested \
from — major mode `%s', %s. Requirements: self-contained (built-ins and \
already-loaded libraries only), safe under lexical binding, a proper \
docstring in the user's language, name it `genie-spell/<short-name>'. No \
commentary outside the code block."
           request major-mode
           (if (use-region-p)
               (format "an active region of %d characters (take its bounds \
with (interactive \"r\"))"
                       (- (region-end) (region-beginning)))
             "no active region — act at point or on the whole buffer, \
whichever the request implies"))
   (format "cantrip: %s" request)
   'cantrip))

;;;###autoload
(defun genie-cast (&optional pick)
  "Invoke the current conjured command; with prefix arg PICK, choose among them."
  (interactive "P")
  (when pick
    (unless genie--spells (user-error "Genie: no spells conjured yet"))
    (let* ((cands (mapcar (lambda (labeled)
                            (let ((reg (car (rassq (cdr labeled)
                                                   genie--registers))))
                              (cons (if reg
                                        (format "%s  [%c]" (car labeled) reg)
                                      (car labeled))
                                    (cdr labeled))))
                          (genie--spell-labels)))
           (choice (completing-read "Cast: " (mapcar #'car cands) nil t)))
      (setq genie--spell (cdr (assoc choice cands)))))
  (unless genie--spell
    (user-error "Genie: no spell armed — conjure one with M-x genie-spell"))
  (genie--call-spell (genie--spell-name genie--spell)
                     (genie--spell-fn genie--spell)))

;;;###autoload
(defun genie-cast-register (&optional digit)
  "Cast the spell stored in register DIGIT.
Interactively the register is the digit key that invoked the command, so
binding this to \\`C-c g 1' .. \\`C-c g 0' gives ten programmable keys."
  (interactive)
  (let* ((digit (or digit last-command-event))
         (entry (and (characterp digit) (alist-get digit genie--registers))))
    (unless (characterp digit)
      (user-error "Genie: bind this command to keys ending in a digit"))
    (unless entry
      (user-error "Genie: register %c is empty — fill it with M-x genie-spell"
                  digit))
    (genie--call-spell (genie--spell-name entry) (genie--spell-fn entry))))

;;;###autoload
(defun genie-spell-bind ()
  "Put one of this session's spells (default the current one) into a register."
  (interactive)
  (unless genie--spells (user-error "Genie: no spells conjured yet"))
  (let* ((labels (genie--spell-labels))
         (default (car (rassq genie--spell labels)))
         (choice (completing-read (format-prompt "Spell to bind" default)
                                  (mapcar #'car labels) nil t nil nil default))
         (entry (cdr (assoc choice labels)))
         (digit (genie--read-register "🧞 Register (0-9): ")))
    (genie--bind-register digit entry)
    (message "🧞 register %c ← %s" digit (genie--spell-name entry))))

;;;###autoload
(defun genie-spell-keep ()
  "Turn the current spell into a permanent config change (full wish pipeline)."
  (interactive)
  (unless genie--spell (user-error "Genie: no spell to keep"))
  (genie (format "Add this function permanently to the config, in the \
module where it belongs, wire a sensible keybinding for it and document \
it:\n\n```elisp\n%s\n```" (genie--spell-code genie--spell))))

;;;; Entry points

;;;###autoload
(defun genie (wish)
  "State a WISH; the agent edits the config, you review, it reloads."
  (interactive
   (progn
     (genie--require-ready)
     (list (string-trim (read-string "🧞 Wish: " nil 'genie--wish-history)))))
  (when (string-empty-p wish) (user-error "Empty wish"))
  (genie--submit wish))

;;;###autoload
(defun genie-manual ()
  "Open the config's user manual, grown by the agent wish by wish."
  (interactive)
  (let ((file (expand-file-name genie-manual-file (genie--root))))
    (unless (file-exists-p file)
      (user-error "Genie: no manual yet — it grows as you make wishes"))
    (find-file file)))

;;;###autoload
(defun genie-chat ()
  "Open the genie transcript as a multi-turn chat (RET sends)."
  (interactive)
  (genie--ensure-session)
  (pop-to-buffer (genie--buffer))
  (goto-char (point-max)))

(defun genie-send ()
  "Send the text typed after the chat prompt as the next wish."
  (interactive)
  (genie--require-ready)
  (let ((wish (string-trim (buffer-substring-no-properties
                            (or genie--input-start (point-min)) (point-max)))))
    (when (string-empty-p wish) (user-error "Type a wish first"))
    (genie--submit wish)))

;;;###autoload
(defun genie-abort ()
  "Abort the turn in flight (the session survives when the backend can)."
  (interactive)
  (if (and (eq genie--state 'thinking) (genie-rpc-live-p genie--rpc))
      (progn (genie-rpc-abort genie--rpc)
             (message "🧞 aborting…"))
    (message "🧞 nothing to abort")))

;;;###autoload
(defun genie-quit ()
  "End the agent session and forget its conversation (config is untouched).
The next wish starts fresh — also the way to make the agent re-read its
charter after changing `genie-config-root' or the backend."
  (interactive)
  (genie--cleanup)
  (message "🧞 session ended — the next wish starts fresh"))

(provide 'genie)
;;; genie.el ends here
