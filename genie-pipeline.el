;;; genie-pipeline.el --- A wish about the configuration, start to finish -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.15.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience
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

;; The configuration has an agent of its own: an ordinary genie chat
;; about the directory the config lives in, carrying a charter that says
;; how this configuration is built.  This file is what brackets each of
;; its turns:
;;
;;   before   the worktree is noted, to measure the turn against
;;   after    what changed is checked — a wish that cannot be taken back
;;            and a config that no longer loads both go back to the agent
;;            to fix — then reviewed as a diff when that is asked for,
;;            committed as "genie: <wish>" and made live
;;
;; Made live means the session is brought to what the files now say:
;; a wish file is switched off and loaded again, one that is gone is
;; switched off, anything else is loaded.  `genie-undo' is the same
;; walk backwards: the commit is dropped and the session follows.
;;
;; A turn that changes nothing is simply an answer, or something done on
;; the spot through the agent's tools; the pipeline has nothing to add.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'diff-mode)
(require 'genie-wish)
(require 'genie-live)
(require 'genie-chat)

(defcustom genie-config-root user-emacs-directory
  "Root of the configuration the genie may edit.
Must be a git repository; `genie-setup' makes it one."
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

(defcustom genie-repair-attempts 2
  "How many times a change that fails validation is handed back to the agent.
The error goes back to the agent to fix, which is where a broken change
belongs before it reaches a person.  When the attempts run out, someone
reviewing diffs is shown one; for everyone else the change is undone and
reported in plain words.  Zero disables repair."
  :type 'integer :group 'genie)

(defcustom genie-manual-file "GENIE.md"
  "The config's user manual, relative to `genie-config-root'.
The agent keeps it updated as the config grows: a concise reference of
the features and keybindings each wish added.  Open it with `genie-manual'."
  :type 'string :group 'genie)

(defconst genie-buffer "*genie*"
  "Name of the chat about the configuration.")

(defconst genie-diff-buffer "*genie-diff*"
  "Name of the pending-wish review buffer.")

(defvar genie--state 'idle
  "The turn state machine: `idle', `thinking', `validating' or `reviewing'.
New turns start from `idle' or `reviewing' (a refinement); `thinking'
covers an agent turn in flight; `validating' the async batch check.")
(defvar genie--wish nil "Wish text of the pending turn(s), used as commit message.")
(defvar genie--pre nil "Commit capturing the pre-wish worktree (restore point).")
(defvar genie--pre-untracked nil "Files already untracked before the wish.")
(defvar genie--changed nil "Files changed by the pending wish.")
(defvar genie--created nil "Files newly created by the pending wish.")
(defvar genie--verdict nil "Validation result (OK . DETAIL), or nil when unknown.")
(defvar genie--cautions nil
  "What the pending change does that could slow Emacs down, for a person to weigh.")
(defvar genie--repairs 0 "Repair turns spent on the change under validation.")

;;;; The state machine

(defvar genie--spinner-index 0 "Current frame of the activity animation.")
(defvar genie--spinner-timer nil "Timer animating the mode line while genie works.")

(defun genie--activity ()
  "Return the animated activity string for the mode line, \"\" when quiet.
The animation is one to three trailing dots after the word, kept
deliberately ASCII: fancier spinner glyphs render as identical boxes
under fonts that lack them, which looks frozen.  The dots are padded so
the mode line does not jitter."
  (let ((dots (format "%-3s" (make-string (1+ (mod genie--spinner-index 3)) ?.))))
    (pcase genie--state
      ('thinking (format " 🧞 thinking%s" dots))
      ('validating (format " 🧞 validating%s" dots))
      (_ ""))))

;; Put straight into `global-mode-string' rather than through a variable:
;; the form calls whatever `genie--activity' is defined right now, so a
;; hot-reloaded genie animates without anything having to be healed.
(defconst genie--indicator '(:eval (genie--activity))
  "The mode-line element showing genie activity in every buffer.")

(defun genie--install-indicator ()
  "Put the activity indicator in `global-mode-string', once."
  (unless (listp global-mode-string)
    (setq global-mode-string (list "" global-mode-string)))
  (unless (member genie--indicator global-mode-string)
    (setq global-mode-string (append global-mode-string (list genie--indicator)))))

(defun genie--set-state (state)
  "Move the turn machine to STATE, and run the spinner exactly while it works."
  (setq genie--state state)
  (if (memq state '(thinking validating))
      (unless genie--spinner-timer
        (setq genie--spinner-index 0
              genie--spinner-timer
              (run-at-time 0 0.4 (lambda ()
                                   (cl-incf genie--spinner-index)
                                   (force-mode-line-update t)))))
    (when genie--spinner-timer
      (cancel-timer genie--spinner-timer)
      (setq genie--spinner-timer nil)))
  (force-mode-line-update t))

(defun genie--require-ready ()
  "Signal a friendly error unless a new turn may start now."
  (pcase genie--state
    ('thinking (user-error "Genie is busy — wait, or M-x genie-abort"))
    ('validating (user-error "Genie is validating the last change — a moment"))
    (_ nil)))

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
  "Capture the pre-wish worktree as the restore point everything measures from."
  (let ((stash (genie--git "stash" "create" "genie pre-wish")))
    (setq genie--pre (if (string-empty-p stash) "HEAD" stash)
          genie--pre-untracked (genie--untracked)
          genie--created nil)))

(defun genie--detect-changes ()
  "Record in `genie--changed' and `genie--created' what changed since the snapshot.
Files the agent created are staged, which is what puts them in the diff
and lets the commit name them."
  (let ((new (cl-set-difference (genie--untracked) genie--pre-untracked
                                :test #'equal)))
    (when new
      (apply #'genie--git "add" "--" new)
      (setq genie--created (cl-union genie--created new :test #'equal)))
    (setq genie--changed
          (cl-union (split-string (genie--git "diff" "--name-only" genie--pre)
                                  "\n" t)
                    new :test #'equal))))

(defun genie--pre-dirty ()
  "Return the files that were already uncommitted when the wish started."
  (split-string (genie--git "diff" "--name-only" "HEAD" genie--pre) "\n" t))

(defun genie--in-commit-p (file commit)
  "Return non-nil when FILE exists in COMMIT."
  (let ((default-directory (genie--root)))
    (zerop (call-process "git" nil nil nil "cat-file" "-e"
                         (concat commit ":" file)))))

;;;; The agent session

(defun genie--context-prompt ()
  "Return the system-prompt addendum: the charter of the config's agent."
  (let ((root (genie--root)))
    (format "You are the genie of the Emacs at `%s`, running live in Emacs \
%s. The user states a wish; you grant it in the form that fits, and say \
which form you chose:

- An answer, when they asked a question. Ask the running Emacs first \
(`describe`, `apropos`, `source`, `messages`) rather than recalling.
- An act, when they want something done now: `eval` runs Lisp in the buffer \
they asked from, at their point, with their region active. A buffer is \
not a file: act on it with `eval`, not with the shell. Nothing is written \
to disk.
- A wish file, when they want Emacs to be different from now on — \
including every time something happens, or every so often. This is the \
only form that changes the configuration.
If a wish could mean two different things, ask before granting it.

A wish file is `%s<name>.el`, one wish to a file, and it must be possible \
to take back while Emacs runs. Two unrelated things asked for at once are \
two files, so that each can be taken back alone. Definitions go at the top level; every \
change to Emacs goes inside one `genie-wish' form, through effects that \
remember the way back:

    ;;; -*- lexical-binding: t; -*-
    (defun my-duplicate-line () \"Duplicate the current line.\" ...)

    (genie-wish duplicate-line
      \"Duplicate the current line with C-c d.\"
      (genie-key global-map \"C-c d\" #'my-duplicate-line)
      (genie-set 'scroll-margin 3)
      (genie-hook 'prog-mode-hook #'display-line-numbers-mode)
      (genie-enable 'global-auto-revert-mode)
      (genie-after 'org
        (genie-key org-mode-map \"C-c d\" #'my-duplicate-line)))

The effects are `genie-set', `genie-key', `genie-hook', `genie-advice', \
`genie-enable', `genie-disable', `genie-add' (for `add-to-list'), \
`genie-timer' (wrapping `run-at-time' or `run-with-idle-timer') and \
`(genie-effect WHAT DO UNDO)' for anything else. `genie-after' defers \
effects until a library is loaded. Never use `setq', `global-set-key', \
`define-key', `add-hook', `advice-add' or a bare mode call at the top \
level of a wish file: they cannot be taken back, and the change will be \
returned to you. Install a package with a top-level `(use-package NAME \
:ensure t :defer t)' and nothing else in it. The docstring of the wish \
is what the user asked for, in their words.

Emacs runs Lisp on the one thread that reads keys and draws the screen. \
Nothing a wish adds may wait or work for long there: no `sleep-for', no \
synchronous processes or network calls, nothing heavy on \
`post-command-hook' or the change hooks. Start a process and take its \
answer in a sentinel instead.

Engineering:
- Prefer, in order: what Emacs already does; an established, maintained \
package; code of your own, and only as much as the wish needs. Before \
writing a function, `apropos` for it: Emacs often has the command already.
- When a wish overlaps an existing one, change that file instead of adding \
a parallel one; delete what your change makes obsolete.
- What the configuration already has outside `%s' stays where it is; edit \
it in place when a wish is about it. `init.el' stays a thin bootstrap.
- Every definition gets a docstring whose first line is a full sentence.
- Keep `%s' as the user's manual of this configuration: a concise \
reference of what it offers and on which keys. Update it with every wish \
that changes something they would look up.
- Check before you write, not after: is the key free, does the option \
exist, what is its value now. A wish file goes live only once your turn has \
ended, so the tools cannot show you its effect.
- Finish with a short report in the user's language: what changed, the \
exact keys and commands, and what you considered and rejected.

Hard rules:
- Edit only files under the config root, by absolute path; never touch \
`.git/'.
- Do not run git and do not load, reload or restart Emacs: the Emacs side \
validates your edits, commits them and switches them on itself."
            root emacs-version
            (file-relative-name (file-name-as-directory genie-wish-directory)
                                root)
            (file-relative-name (file-name-as-directory genie-wish-directory)
                                root)
            genie-manual-file)))

(defun genie--command ()
  "Return the argv of the config's agent: elmee, carrying the charter."
  (append (genie-chat-command)
          (list "--append-system-prompt" (genie--context-prompt))))

(defun genie--buffer ()
  "Return the chat about this configuration, creating it when needed.
It is an ordinary `genie-chat' whose turns are bracketed by the
pipeline: a snapshot before, change detection and validation after."
  (genie-chat-open (genie--root) :name genie-buffer
                   :command (genie--command)
                   :start #'genie--turn-starting
                   :finish #'genie--turn-ended))

(defun genie--emit (text &optional face)
  "Write TEXT (in FACE) into the config chat as an aside."
  (genie-chat-note text face (genie--buffer)))

;;;; Turns

(defun genie--turn-starting (label)
  "Open the pipeline for a turn of the config chat.
LABEL is what was asked — it becomes part of the commit message — or
the symbol `note' for a follow-up genie sent on its own.  Called for
every turn, typed into the chat or made as a wish, before it is sent;
an error here refuses it."
  (genie--require-ready)
  ;; A wish written where init.el does not look would be gone at restart.
  (unless (and (file-directory-p genie-wish-directory)
               (file-in-directory-p genie-wish-directory (genie--root)))
    (user-error "Genie: run M-x genie-setup first — this configuration has \
nowhere to keep wishes yet"))
  (unless genie--changed          ; refining a pending wish keeps its baseline
    (genie--snapshot)
    (setq genie--wish nil genie--repairs 0))
  (unless (eq label 'note)
    (setq genie--wish (if genie--wish (concat genie--wish "; " label) label)))
  (genie--install-indicator)
  (genie--set-state 'thinking))

(defun genie--submit (wish &optional label)
  "Send WISH to the config's agent.
The transcript and the commit message use LABEL instead when given; the
symbol `silent' marks a follow-up genie asked for on its own, which
stays out of the commit message and shows as a note."
  (genie--require-ready)
  (let ((silent (eq label 'silent)))
    (when silent (genie--emit "↻ fixing what was not accepted\n"))
    (genie-chat-submit (genie--buffer) wish (if silent 'note label))
    (message "🧞 genie is working… (M-x genie-abort interrupts)")))

(defun genie--turn-ended (stop)
  "Close the pipeline for a turn of the config chat that ended with STOP."
  (genie--finish-turn stop))

(defun genie--finish-turn (&optional stop)
  "End the turn in flight: detect what it changed, then validate and review.
STOP is why the turn ended; anything but a normal end means the agent
did not finish what it was doing, and what it left is held for review
rather than validated and applied.  A no-op unless a turn is actually
in flight, so late or duplicate agent events cannot re-run the pipeline."
  (when (eq genie--state 'thinking)
    (genie--detect-changes)
    (cond
     ((null genie--changed)
      (setq genie--verdict nil genie--repairs 0)
      (genie--set-state 'idle)
      ;; Nothing changed, so the wish was granted as an answer or an act,
      ;; and the agent's words are the whole of the result: show them.
      (display-buffer (genie--buffer))
      (message "🧞 done"))
     ((not (member stop '(nil "end_turn")))
      ;; Stopped, refused or dead in the middle of an edit.  Half a change
      ;; is nobody's wish: it is neither committed nor thrown away unasked.
      (setq genie--verdict nil genie--repairs 0)
      (genie--set-state 'reviewing)
      (message "🧞 the turn did not finish — %d file(s) left half-changed: \
M-x genie-diff shows them, M-x genie-reject restores them"
               (length genie--changed)))
     (t
      (genie--set-state 'validating)
      (message "🧞 validating %d file(s)…" (length genie--changed))
      (genie--validate
       (lambda (verdict)
         (when (eq genie--state 'validating) ; ignore a stale callback
           (setq genie--verdict verdict)
           (genie--set-state 'reviewing)
           (cond
            ((car verdict)
             (setq genie--repairs 0)
             (if (genie--confirm-p 'wish) (genie--show-diff) (genie-apply)))
            ;; A broken change is the agent's problem before it is the
            ;; user's: hand the error back and let it try again.
            ((< genie--repairs genie-repair-attempts) (genie--repair verdict))
            ;; Out of attempts.  Someone who asked to review diffs gets
            ;; one; someone who did not is not handed a diff and an elisp
            ;; error to judge — the change is undone and said so plainly.
            ((genie--confirm-p 'wish) (setq genie--repairs 0) (genie--show-diff))
            (t (genie--give-up verdict))))))))))

(defun genie--repair (verdict)
  "Ask the agent to fix the change that failed validation with VERDICT."
  (cl-incf genie--repairs)
  (message "🧞 that change cannot be applied — asking the agent to fix it (%d/%d)…"
           genie--repairs genie-repair-attempts)
  (genie--submit
   (format "Your change was not accepted:

  %s

Fix it: find the mistake in what you just edited and correct it, keeping \
the original request satisfied.  Do not start over and do not widen the \
change.  Reply with a one-line note of what was wrong." (cdr verdict))
   'silent))

(defun genie--give-up (verdict)
  "Undo the change that kept failing validation with VERDICT, and say so."
  (let ((wish genie--wish))
    (setq genie--repairs 0)
    (genie--restore-worktree)
    (genie--reset)
    (genie--set-state 'idle)
    (display-buffer (genie--buffer))
    (message "🧞 couldn't do it — \"%s\" could not be applied (%s), so \
nothing was changed"
             (truncate-string-to-width wish 40 nil nil "…")
             (truncate-string-to-width (cdr verdict) 60 nil nil "…"))))

;;;; Validation

(defconst genie--irreversible
  '((global-set-key . genie-key) (local-set-key . genie-key)
    (define-key . genie-key) (keymap-set . genie-key)
    (keymap-global-set . genie-key) (add-hook . genie-hook)
    (advice-add . genie-advice) (setq . genie-set) (setq-default . genie-set)
    (setopt . genie-set) (customize-set-variable . genie-set)
    (add-to-list . genie-add) (run-at-time . genie-timer)
    (run-with-timer . genie-timer) (run-with-idle-timer . genie-timer))
  "Ways to change Emacs that leave no way back, and the effect to use instead.")

(defconst genie--transparent
  '(genie-wish genie-after progn when unless if let let* with-eval-after-load
    eval-after-load eval-when-compile eval-and-compile)
  "Forms whose bodies run where they stand, and so are checked like them.")

(defconst genie--inert-keywords
  '(:ensure :defer :demand :commands :vc :pin :load-path :after :if :when
    :unless :requires :no-require :autoload :functions :defines :disabled)
  "What a `use-package' form in a wish file may say: where a package is from.")

(defconst genie--heavy
  '(post-command-hook pre-command-hook after-change-functions
    before-change-functions window-scroll-functions
    window-configuration-change-hook sleep-for sit-for
    url-retrieve-synchronously accept-process-output)
  "What makes the one thread Emacs has wait or work on every keystroke.")

(defun genie--irreversible-in (form)
  "Return what FORM does where it stands that could not be taken back."
  (pcase form
    (`(use-package ,name . ,rest)
     (when-let* ((said (cl-remove-if-not #'keywordp rest))
                 (acting (cl-set-difference said genie--inert-keywords)))
       (list (format "`use-package %s' with %s: in a wish file it only installs \
— make the changes with effects" name (mapconcat #'symbol-name acting " ")))))
    (`(,(and head (guard (assq head genie--irreversible))) . ,_)
     (list (format "`%s' cannot be taken back — use `%s'"
                   head (cdr (assq head genie--irreversible)))))
    (`(,(and head (pred symbolp)
             (guard (string-suffix-p "-mode" (symbol-name head))))
       . ,_)
     (list (format "`(%s …)' cannot be taken back — use `genie-enable' or \
`genie-disable'" head)))
    (`(,(and head (guard (memq head genie--transparent))) . ,body)
     (mapcan #'genie--irreversible-in (cl-remove-if-not #'consp body)))))

(defun genie--wish-file-p (file)
  "Return non-nil when FILE, relative to the root, is a wish file."
  (and (string-suffix-p ".el" file)
       (file-in-directory-p (expand-file-name file (genie--root))
                            genie-wish-directory)))

(defun genie--lint ()
  "Return why the changed wish files could not be taken back, or nil."
  (let (found)
    (dolist (file (cl-remove-if-not #'genie--wish-file-p genie--changed))
      (let ((path (expand-file-name file (genie--root))))
        (when (file-exists-p path)
          (with-temp-buffer
            (insert-file-contents path)
            (condition-case nil
                (while t
                  (dolist (problem (genie--irreversible-in
                                    (read (current-buffer))))
                    (push (format "%s: %s" file problem) found)))
              (error nil))))))
    (and found (string-join (nreverse found) "\n  "))))

(defun genie--heavy-in-changes ()
  "Return what the changed files use that could slow every keystroke."
  (cl-remove-duplicates
   (mapcan (lambda (file)
             (let ((path (expand-file-name file (genie--root))))
               (when (and (string-suffix-p ".el" file) (file-exists-p path))
                 (genie--mentions (with-temp-buffer
                                    (insert-file-contents path)
                                    (buffer-string))
                                  genie--heavy))))
           genie--changed)))

(defun genie--validate (callback)
  "Validate the pending change; CALLBACK gets (OK . DETAIL).
A wish that could not be taken back fails before anything is loaded."
  (setq genie--cautions (genie--heavy-in-changes))
  (if-let* ((problem (genie--lint)))
      (funcall callback (cons nil problem))
    (pcase genie-validate
      ('batch (genie--batch-check callback))
      ('parens (funcall callback (genie--parens-check)))
      (_ (funcall callback '(t . "validation skipped"))))))

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
The config must still start cleanly with the pending edits in place: a
wish that was switched off for signalling counts as a failure, since
that is what would greet the next start.  It runs in another Emacs so
that installing a package, or a loop that never ends, costs this one
nothing; a run over `genie-validate-timeout' seconds is killed and
reported as a timeout rather than as a config failure."
  (let* ((buf (generate-new-buffer " *genie-validate*"))
         (proc (make-process
                :name "genie-validate" :buffer buf :noquery t
                :command
                (list (expand-file-name invocation-name invocation-directory)
                      "--batch"
                      ;; Wherever this genie was loaded from, so a config
                      ;; that relies on a package manager to find it still
                      ;; finds it here.
                      "-L" (file-name-directory (locate-library "genie-wish"))
                      "-l" (expand-file-name "init.el" (genie--root)))
                :sentinel
                (lambda (proc _event)
                  (unless (process-live-p proc)
                    (let* ((out (with-current-buffer buf
                                  (string-trim (buffer-string))))
                           (refused (and (string-match
                                          "^Warning (genie): \\(.*\\)" out)
                                         (match-string 1 out)))
                           (ok (and (zerop (process-exit-status proc))
                                    (not refused))))
                      (kill-buffer buf)
                      (funcall
                       callback
                       (cons ok
                             (cond
                              (ok "the config starts cleanly")
                              ((process-get proc 'genie--timeout)
                               (format "validation timed out after %ss — raise `genie-validate-timeout'"
                                       genie-validate-timeout))
                              (t (truncate-string-to-width
                                  (or refused
                                      (car (last (split-string out "\n" t)))
                                      "batch load failed")
                                  300)))))))))))
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
        (mixed (cl-intersection genie--changed (genie--pre-dirty) :test #'equal))
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
         (if genie--cautions
             (propertize (format "⚠ could slow Emacs down: uses %s\n"
                                 (mapconcat #'symbol-name genie--cautions ", "))
                         'face 'warning)
           "")
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
  (setq genie--changed nil genie--created nil genie--verdict nil
        genie--cautions nil genie--repairs 0))

(defun genie--quit-diff ()
  "Dismiss the review window when it is showing."
  (when-let* ((window (get-buffer-window genie-diff-buffer)))
    (quit-window nil window)))

(defun genie--refresh (files)
  "Bring the session to what FILES, relative to the root, now say.
A wish file is switched off and loaded again, and one that is gone is
switched off; that is exact, and needs no restart.  Any other Elisp
file is loaded — init.el last, so that what it wires up finds the fresh
definitions — and one that fails to load offers a restart."
  (let* ((root (genie--root))
         (els (cl-remove-if-not (lambda (f) (string-suffix-p ".el" f)) files))
         (wishes (cl-remove-if-not #'genie--wish-file-p els))
         (rest (cl-set-difference els wishes :test #'equal))
         (init (member "init.el" rest))
         (ordered (append (remove "init.el" rest) (and init '("init.el"))))
         failed)
    (dolist (file wishes)
      (let ((path (expand-file-name file root)))
        (if (file-exists-p path)
            (genie-wish-load-file path)
          (genie-wish-forget-file path))))
    ;; Which wishes are kept off is a file like any other.
    (when (cl-some (lambda (file) (equal (file-name-nondirectory file) ".off"))
                   files)
      (genie-wish-sync))
    (dolist (file ordered)
      (when (file-exists-p (expand-file-name file root))
        (condition-case err
            (load (expand-file-name file root) nil t)
          (error (push (format "%s: %s" file (error-message-string err))
                       failed)))))
    (when (and failed
               (y-or-n-p (format "Reload failed (%s) — restart Emacs? "
                                 (string-join (nreverse failed) "; "))))
      (if (fboundp 'restart-emacs) (restart-emacs)
        (message "🧞 restart-emacs unavailable — please restart manually")))))

;;;###autoload
(defun genie-diff ()
  "Show (or re-show) the diff of the pending change set."
  (interactive)
  (unless genie--changed (user-error "Genie: no pending changes"))
  (genie--require-ready)               ; errors only while a turn is in flight
  (genie--set-state 'reviewing)
  (genie--show-diff))

(defun genie-apply ()
  "Commit the pending wish and make it live."
  (interactive)
  (unless (eq genie--state 'reviewing)
    (user-error "Genie: nothing under review (state: %s)" genie--state))
  (unless (car-safe genie--verdict)
    (unless (yes-or-no-p
             (format "%s — apply anyway? "
                     (if genie--verdict
                         (format "Validation failed (%s)" (cdr genie--verdict))
                       "The change set was not validated")))
      (user-error "Genie: not applied")))
  (apply #'genie--git "commit" "-m" (format "genie: %s" genie--wish)
         "--" genie--changed)
  (push (cons 'wish (car (split-string (format "genie: %s" genie--wish) "\n")))
        genie--journal)
  (let ((files genie--changed)
        (wish genie--wish)
        (caution (if genie--cautions
                     (format " · ⚠ uses %s, which can slow Emacs down"
                             (mapconcat #'symbol-name genie--cautions ", "))
                   "")))
    (genie--reset)
    (genie--quit-diff)
    (genie--set-state 'idle)
    (genie--refresh files)
    (if (genie--confirm-p 'wish)
        ;; The agent's report documents what was added and how to use it.
        (display-buffer (genie--buffer))
      ;; In the frictionless flow the change is already live and the user is
      ;; looking at the editor, not at us: one line saying what happened and
      ;; how to take it back beats a window they did not ask for.
      (message "🧞 %s · %s · M-x genie-undo takes it back%s"
               (truncate-string-to-width wish 60 nil nil "…")
               (string-join files " · ") caution))))

(defun genie--restore-worktree ()
  "Put every file the pending change touched back as it was before it."
  (when-let* ((tracked (cl-set-difference genie--changed genie--created
                                          :test #'equal)))
    ;; --worktree only: restoring via checkout would stage the files, and a
    ;; non-clean index later blocks the drop in `genie-undo'.
    (apply #'genie--git "restore" "--source" genie--pre "--worktree"
           "--" tracked))
  (dolist (file genie--created)
    (genie--git "restore" "--staged" "--" file)
    (ignore-errors (delete-file (expand-file-name file (genie--root))))))

(defun genie-reject ()
  "Discard the pending wish: restore every touched file to its pre-wish state."
  (interactive)
  (unless (eq genie--state 'reviewing)
    (user-error "Genie: nothing under review (state: %s)" genie--state))
  (genie--restore-worktree)
  (genie--reset)
  (genie--quit-diff)
  (genie--set-state 'idle)
  (message "🧞 wish rejected — config restored"))

;;;; Undo — one `genie-undo' for every kind of change

(defun genie--undo-wish (subject)
  "Drop the newest genie commit entirely; SUBJECT, when given, must match HEAD.
Always confirmed first: the commit is deleted from history (a clean log
beats a commit/revert pair), its changes leave the worktree, and
unrelated uncommitted work is untouched.  Note that a config pushed to
a remote would need a force-push afterwards."
  (let ((head (genie--git "log" "-1" "--format=%s")))
    (unless (string-prefix-p "genie: " head)
      (if subject
          (user-error "Genie: HEAD is not a genie commit (%s)" head)
        (user-error "Genie: nothing to undo — the session journal is empty \
and HEAD is not a genie commit")))
    (when (and subject (not (equal subject head)))
      (user-error "Genie: HEAD moved since that wish (now at: %s)" head))
    ;; Every path the commit touched, classified by one question: did it
    ;; exist before?  Renames are listed as their two plain paths rather
    ;; than as a rename, so old and new fall out on the right sides.
    (let (added kept)
      (dolist (file (split-string (genie--git "diff" "--no-renames"
                                              "--name-only" "HEAD~" "HEAD")
                                  "\n" t))
        (if (genie--in-commit-p file "HEAD~") (push file kept) (push file added)))
      ;; Edits made to the wish's OWN files after it was applied would be
      ;; discarded along with it; say so before touching anything.  Work on
      ;; other files is never in the way and is not worth mentioning.
      (let ((overlap (cl-intersection
                      (split-string (genie--git "diff" "--name-only" "HEAD")
                                    "\n" t)
                      (append added kept) :test #'equal)))
        ;; Asked when `genie-confirm' says so — and always when work of the
        ;; user's own would go with the commit, whatever the setting.
        (when (or overlap (genie--confirm-p 'undo))
          (unless (y-or-n-p
                   (format "%s%sUndo \"%s\" — delete the commit entirely? "
                           (if subject ""
                             "No genie change journaled this session.  ")
                           (if overlap
                               (format "Your later edits to %s go too.  "
                                       (string-join overlap ", "))
                             "")
                           head))
            (user-error "Genie: not undone"))))
      (genie--git "reset" "-q" "--mixed" "HEAD~")
      (when kept (apply #'genie--git "checkout" "HEAD" "--" kept))
      (dolist (file added)
        (ignore-errors (delete-file (expand-file-name file (genie--root)))))
      (message "🧞 dropped: %s" head)
      (genie--refresh (append added kept)))))

;;;###autoload
(defun genie-undo ()
  "Undo the most recent genie-made change, whatever its kind.
An applied wish is, after confirmation, deleted from history entirely
\(no commit/revert pairs in the log) and switched off in this session;
what a spell, a cantrip or the agent's own code did to a buffer is
undone in that buffer.  When the session journal is empty (a fresh Emacs),
offers to drop HEAD if it is a genie commit.  `genie-journal' previews
the stack."
  (interactive)
  (unless (eq genie--state 'idle)
    (user-error "Genie: finish the current cycle first (state: %s)"
                genie--state))
  (let ((entry (car genie--journal)))
    (pcase entry
      (`(cast . ,_) (genie-live-undo entry))
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

(provide 'genie-pipeline)
;;; genie-pipeline.el ends here
