;;; genie.el --- Self-modifying config driven by natural-language wishes -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.4.0
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
;; turns the current spell into a permanent wish.
;;
;; `genie-undo' undoes the most recent genie-made change, whatever its
;; kind: an applied wish (git revert + reload) or the buffer effect of a
;; spell, register cast or cantrip.
;;
;; Everything is async, built on the genie-rpc library, with two agent
;; backends (`genie-backend'): the Pi coding agent and the elmee agent
;; microkernel.
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

(defcustom genie-backend 'pi
  "Agent backend: the Pi coding agent or the elmee microkernel agent."
  :type '(choice (const pi) (const elmee))
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

(defcustom genie-auto-apply nil
  "When non-nil, commit and reload without the diff review if validation passes."
  :type 'boolean :group 'genie)

(defcustom genie-manual-file "GENIE.md"
  "The config's user manual, relative to `genie-config-root'.
The agent keeps it updated as the config grows: a concise reference of
the features and keybindings each wish added.  Open it with `genie-manual'."
  :type 'string :group 'genie)

(defconst genie-buffer "*genie*"
  "Name of the transcript/chat buffer.")

(defconst genie-diff-buffer "*genie-diff*"
  "Name of the pending-wish review buffer.")

(defvar genie--rpc nil "The `genie-rpc-session' to the agent, or nil.")
(defvar genie--busy nil "Non-nil while a turn is streaming.")
(defvar genie--tool nil "Name of the tool currently running.")
(defvar genie--seen-text nil "Non-nil once the current turn emitted real text.")
(defvar genie--ctxfile nil "Temp file holding Pi's system-prompt addendum.")
(defvar genie--elmee-session nil "Elmee session file, carrying context across respawns.")
(defvar genie--input-start nil "Marker where the chat input begins.")
(defvar genie--wish nil "Wish text of the pending turn(s), used as commit message.")
(defvar genie--pre nil "Commit capturing the pre-wish worktree (restore point).")
(defvar genie--pre-dirty nil "Files already dirty before the wish.")
(defvar genie--pre-untracked nil "Files already untracked before the wish.")
(defvar genie--changed nil "Files changed by the pending wish.")
(defvar genie--created nil "Files newly created by the pending wish.")
(defvar genie--verdict nil "Validation result (OK . DETAIL) for the pending wish.")
(defvar genie--turn 'wish "Kind of the turn in flight: `wish' or `spell'.")
(defvar genie--answer "" "Accumulated answer text of the turn in flight.")
(defvar genie--spell nil "Symbol of the current conjured command.")
(defvar genie--spells nil "Alist of (COMMAND . CODE) conjured this session, newest first.")
(defvar genie--registers nil "Alist of (DIGIT-CHAR . COMMAND) spell registers.")
(defvar genie--pending-register nil "Register chosen for the spell being conjured.")
(defvar genie--cantrip-target nil "Plist locating where the pending cantrip lands.")
(defvar genie--journal nil
  "Stack of genie-made changes, newest first, popped by `genie-undo'.
An entry is (wish . COMMIT-SUBJECT) for an applied config wish, or
\(cast BUFFER PRE POST FN) for a spell invocation that edited BUFFER,
where PRE and POST are its `buffer-undo-list' before and after.")

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

(defun genie--elmee-session-file ()
  "Return (creating the name lazily) the shared elmee session file."
  (or genie--elmee-session
      (setq genie--elmee-session
            (expand-file-name (format "genie-%d.jsonl" (emacs-pid))
                              temporary-file-directory))))

(defun genie--command ()
  "Return the agent argv for the configured backend, system prompt included."
  (pcase genie-backend
    ('elmee (append (list genie-elmee-program "--rpc"
                          "--session" (genie--elmee-session-file)
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
                          :on-request #'genie--on-request
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

(defun genie--on-request (request)
  "Decline the agent's approval/question REQUEST — out of genie's mandate.
Config edits inside the root need no approval under elmee's default
workspace permission mode; anything that does is not genie's business."
  (message "🧞 %s request denied — out of genie's scope"
           (or (plist-get request :kind) "interaction"))
  (genie-rpc-respond genie--rpc (plist-get request :id)
                     (if (equal (plist-get request :kind) "approval")
                         '(:outcome "deny"
                           :value "genie may only edit files inside the config root")
                       '(:outcome "cancel"))))

(defun genie--on-exit ()
  "Handle the agent process dying; salvage a turn that was in flight."
  (when genie--busy
    (genie--emit "\n[genie: agent process exited]\n" 'error)
    (genie--finish-turn))
  (force-mode-line-update t))

(defun genie--cleanup ()
  "Close the RPC session and delete temp files (buffer kill / Emacs exit)."
  (when genie--rpc
    (genie-rpc-close genie--rpc)
    (setq genie--rpc nil))
  (dolist (file (list genie--ctxfile genie--elmee-session))
    (when (and file (file-exists-p file))
      (ignore-errors (delete-file file))))
  (setq genie--elmee-session nil genie--busy nil))

(add-hook 'kill-emacs-hook #'genie--cleanup)

;;;; Transcript buffer / turns

(defvar genie-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'genie-send)
    (define-key map (kbd "C-j") #'newline)
    (define-key map (kbd "C-c C-k") #'genie-abort)
    map)
  "Keymap for `genie-mode'.")

(define-derived-mode genie-mode fundamental-mode "genie"
  "Chat with the config genie; RET sends, \\[genie-abort] aborts."
  (setq-local mode-line-format
              '(" " (:propertize "%b" face mode-line-buffer-id)
                (:eval (cond (genie--tool (format "  ⏳ %s" genie--tool))
                             (genie--busy "  🧞 thinking… (C-c C-k abort)")
                             (t "")))))
  (visual-line-mode 1)
  (add-hook 'kill-buffer-hook #'genie--cleanup nil t))

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

(defun genie--submit (wish &optional label)
  "Send WISH to the agent; the transcript and commit message use LABEL."
  (genie--ensure-session)
  (unless genie--changed           ; refining a pending wish keeps its baseline
    (genie--snapshot)
    (setq genie--wish nil))
  (let ((label (or label wish)))
    (setq genie--wish (if genie--wish (concat genie--wish "; " label) label))
    (with-current-buffer (genie--buffer)
      (when (markerp genie--input-start)
        (goto-char genie--input-start)
        (forward-line 0)
        (delete-region (point) (point-max)))
      (goto-char (point-max))
      (insert (propertize "You: " 'face 'font-lock-keyword-face) label "\n\n")))
  (setq genie--busy t genie--seen-text nil genie--tool nil genie--answer "")
  (force-mode-line-update t)
  (message "🧞 genie is working… (M-x genie-abort interrupts)")
  (genie-rpc-prompt genie--rpc wish))

(defun genie--finish-turn ()
  "End the turn: arm a spell, or detect, validate and review the config change set."
  (setq genie--busy nil genie--tool nil)
  (with-current-buffer (genie--buffer) (genie--insert-prompt))
  (force-mode-line-update t)
  (genie--detect-changes)
  (cond
   ((memq genie--turn '(spell cantrip))
    (let ((cast-now (eq genie--turn 'cantrip)))
      (setq genie--turn 'wish)
      (when genie--changed           ; a spell must not touch disk — surface it
        (message "⚠ the spell also touched files — review with M-x genie-diff"))
      (genie--learn-spell genie--answer cast-now)))
   ((null genie--changed)
    (setq genie--verdict nil)
    (display-buffer (genie--buffer))
    (message "🧞 done — no config changes"))
   (t
    (message "🧞 validating %d file(s)…" (length genie--changed))
    (genie--validate
     (lambda (verdict)
       (setq genie--verdict verdict)
       (if (and genie-auto-apply (car verdict))
           (genie-apply)
         (genie--show-diff)))))))

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
The config must still boot cleanly with the pending edits in place."
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
                      (funcall callback
                               (cons ok
                                     (if ok "init.el loads cleanly"
                                       (truncate-string-to-width
                                        (or (car (last (split-string out "\n" t)))
                                            "batch load failed")
                                        200))))))))))
    (run-at-time 120 nil (lambda ()
                           (when (process-live-p proc)
                             (kill-process proc))))))

;;;; Review: diff buffer, apply / reject / undo

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
        (ok (car genie--verdict))
        (mixed (cl-intersection genie--changed genie--pre-dirty :test #'equal))
        (buf (get-buffer-create genie-diff-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert
         (propertize (format "🧞 wish: %s\n" genie--wish) 'face 'bold)
         (if ok
             (propertize (format "✓ %s\n" (cdr genie--verdict)) 'face 'success)
           (propertize (format "✗ validation FAILED: %s\n" (cdr genie--verdict))
                       'face 'error))
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
  "Hot-reload changed Elisp FILES; offer a restart when init.el changed."
  (let* ((els (cl-remove-if-not (lambda (f) (string-suffix-p ".el" f)) files))
         (modules (cl-remove "init.el" els :test #'equal)))
    (dolist (file modules) (load (expand-file-name file (genie--root)) nil t))
    (when modules
      (message "🧞 reloaded: %s" (string-join modules " · ")))
    (when (and (member "init.el" els)
               (y-or-n-p "The init.el changed — restart Emacs to fully apply? "))
      (if (fboundp 'restart-emacs) (restart-emacs)
        (message "🧞 restart-emacs unavailable — please restart manually")))))

;;;###autoload
(defun genie-diff ()
  "Show the diff of the pending wish."
  (interactive)
  (unless genie--changed (user-error "Genie: no pending wish"))
  (genie--show-diff))

(defun genie-apply ()
  "Commit the pending wish and hot-reload the changed files."
  (interactive)
  (unless genie--changed (user-error "Genie: nothing to apply"))
  (when (and genie--verdict (not (car genie--verdict))
             (not (yes-or-no-p (format "Validation failed (%s) — apply anyway? "
                                       (cdr genie--verdict)))))
    (user-error "Genie: not applied"))
  (apply #'genie--git "commit" "-m" (format "genie: %s" genie--wish)
         "--" genie--changed)
  (push (cons 'wish (car (split-string (format "genie: %s" genie--wish) "\n")))
        genie--journal)
  (let ((files genie--changed))
    (genie--reset)
    (genie--quit-diff)
    (message "🧞 wish applied and committed")
    (genie--reload files)
    ;; The agent's report documents what was added and how to use it.
    (display-buffer (genie--buffer))))

(defun genie-reject ()
  "Discard the pending wish: restore every touched file to its pre-wish state."
  (interactive)
  (unless genie--changed (user-error "Genie: nothing to reject"))
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
  (message "🧞 wish rejected — config restored"))

(defun genie--undo-wish (subject)
  "Revert the newest genie commit; SUBJECT, when given, must match HEAD."
  (let ((head (genie--git "log" "-1" "--format=%s")))
    (unless (string-prefix-p "genie: " head)
      (user-error "Genie: HEAD is not a genie commit (%s)" head))
    (when (and subject (not (equal subject head)))
      (user-error "Genie: HEAD moved since that wish (now at: %s)" head))
    (let ((files (split-string (genie--git "diff" "--name-only" "HEAD~" "HEAD")
                               "\n" t)))
      (genie--git "revert" "--no-edit" "HEAD")
      (message "🧞 reverted: %s" head)
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
falls back to reverting HEAD if it is a genie commit."
  (interactive)
  (let ((entry (car genie--journal)))
    (pcase entry
      (`(cast . ,_) (genie--undo-cast entry))
      (`(wish . ,subject) (genie--undo-wish subject))
      (_ (genie--undo-wish nil)))
    (when entry (pop genie--journal))))

;;;; The undo journal — one `genie-undo' for every kind of change

(defun genie--call-spell (fn)
  "Invoke spell FN interactively, journaling its buffer edits for `genie-undo'."
  (let ((buf (current-buffer)) pre)
    (undo-boundary)
    (setq pre buffer-undo-list)
    (unwind-protect (call-interactively fn)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (undo-boundary)
          (unless (or (eq buffer-undo-list t) (eq buffer-undo-list pre))
            (push (list 'cast buf pre buffer-undo-list fn) genie--journal)))))))

(defun genie--undo-prefix (list tail)
  "Return the entries of undo LIST that precede TAIL, or nil if TAIL is gone."
  (let (acc)
    (while (and list (not (eq list tail)))
      (push (car list) acc)
      (setq list (cdr list)))
    (and list (nreverse acc))))

(defun genie--undo-cast (entry)
  "Undo the buffer effect recorded in cast ENTRY."
  (pcase-let ((`(cast ,buf ,pre ,post ,fn) entry))
    (if (not (buffer-live-p buf))
        (message "🧞 %s's buffer is gone — nothing left to undo there" fn)
      (with-current-buffer buf
        (when (and (not (eq buffer-undo-list post))
                   (not (y-or-n-p
                         (format "Edits made after %s revert too — continue? "
                                 fn))))
          (user-error "Genie: not undone"))
        (let ((entries (genie--undo-prefix buffer-undo-list pre)))
          (unless entries
            (user-error "Genie: undo history for %s was truncated" fn))
          (primitive-undo (1+ (cl-count nil entries)) entries)
          (message "🧞 undone: %s in %s" fn (buffer-name)))))))

;;;; Spells — ephemeral conjured commands, nothing on disk

(defun genie--extract-elisp (text)
  "Return the first fenced code block in TEXT, or TEXT itself."
  (if (string-match "```[a-z-]*\n\\(\\(?:.\\|\n\\)*?\\)```" text)
      (match-string 1 text)
    text))

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

(defun genie--bind-register (digit fn)
  "Store spell command FN in register DIGIT (a character), reporting evictions."
  (when-let* ((old (alist-get digit genie--registers)))
    (unless (eq old fn) (message "🧞 register %c: %s evicted" digit old)))
  (setf (alist-get digit genie--registers) fn))

(defun genie--learn-spell (answer &optional cast-now)
  "Extract the conjured command from ANSWER, eval it and make it current.
With CAST-NOW (a cantrip), immediately invoke it where it was asked from."
  (condition-case err
      (let* ((code (string-trim (genie--extract-elisp answer)))
             (fn (genie--eval-spell code)))
        (push (cons fn code) genie--spells)
        (setq genie--spell fn)
        (when genie--pending-register
          (genie--bind-register genie--pending-register fn))
        (if cast-now
            (genie--cast-at-target fn)
          (message "🧞 spell armed: %s — cast with M-x genie-cast%s" fn
                   (if genie--pending-register
                       (format " or register %c" genie--pending-register)
                     ""))))
    (error (display-buffer (genie--buffer))
           (message "🧞 spell failed: %s" (error-message-string err))))
  (setq genie--pending-register nil))

;;;###autoload
(defun genie-spell (request &optional register)
  "Conjure an ephemeral interactive command implementing REQUEST.
The generated function is evaluated into the running session (no files
are touched) and armed on `genie-cast'; with REGISTER (a digit
character) it also lands in that spell register, castable via
`genie-cast-register'.  `genie-spell-keep' makes a spell permanent."
  (interactive
   (list (string-trim (read-string "🧞 Spell (command to conjure): "))
         (genie--read-register "🧞 Register for it (0-9, RET to skip): " t)))
  (when genie--busy (user-error "Genie is busy (M-x genie-abort interrupts)"))
  (when (string-empty-p request) (user-error "Empty spell"))
  (setq genie--turn 'spell genie--pending-register register)
  (genie--submit
   (format "SPELL MODE — do NOT edit, create or run anything; this is pure \
code generation. Reply with ONLY one Emacs Lisp code block containing a \
single interactive `defun' (a command) implementing: %s. Requirements: \
self-contained (built-ins and already-loaded libraries only), safe under \
lexical binding, operate on the active region when that is the natural \
reading, docstring in the user's language, name it \
`genie-spell/<short-name>'. No commentary outside the code block." request)
   (format "spell: %s" request)))

(defun genie--cast-at-target (fn)
  "Invoke cantrip FN in the buffer (and on the region) it was asked from."
  (let* ((target genie--cantrip-target)
         (buf (plist-get target :buffer))
         (region (plist-get target :region)))
    (setq genie--cantrip-target nil)
    (if (not (buffer-live-p buf))
        (message "🧞 %s armed, but its buffer is gone — cast it manually" fn)
      (with-current-buffer buf
        (if region
            (progn (goto-char (cdr region))
                   (push-mark (car region) t t))
          (goto-char (plist-get target :point)))
        (genie--call-spell fn)
        (message "🧞 %s — M-x genie-undo reverts it" fn)))))

;;;###autoload
(defun genie-cantrip (request)
  "Conjure and IMMEDIATELY execute a one-shot command implementing REQUEST.
The generated command runs right where it was asked from — this buffer,
on the active region when there is one.  Its effect is reverted by
`genie-undo'; the command also stays armed as the current spell, so a
cantrip worth repeating can be re-cast (`genie-cast'), slotted into a
register (`genie-spell-bind') or made permanent (`genie-spell-keep')."
  (interactive (list (string-trim (read-string "🧞 Cantrip (do right now): "))))
  (when genie--busy (user-error "Genie is busy (M-x genie-abort interrupts)"))
  (when (string-empty-p request) (user-error "Empty cantrip"))
  (setq genie--turn 'cantrip
        genie--cantrip-target
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
   (format "cantrip: %s" request)))

;;;###autoload
(defun genie-cast (&optional pick)
  "Invoke the current conjured command; with prefix arg PICK, choose among them."
  (interactive "P")
  (when pick
    (unless genie--spells (user-error "Genie: no spells conjured yet"))
    (let* ((cands (mapcar (lambda (spell)
                            (let* ((fn (car spell))
                                   (reg (car (rassq fn genie--registers))))
                              (cons (if reg (format "%s  [%c]" fn reg)
                                      (symbol-name fn))
                                    fn)))
                          genie--spells))
           (choice (completing-read "Cast: " (mapcar #'car cands) nil t)))
      (setq genie--spell (cdr (assoc choice cands)))))
  (unless (commandp genie--spell)
    (user-error "Genie: no spell armed — conjure one with M-x genie-spell"))
  (genie--call-spell genie--spell))

;;;###autoload
(defun genie-cast-register (&optional digit)
  "Cast the spell stored in register DIGIT.
Interactively the register is the digit key that invoked the command, so
binding this to \\`C-c g 1' .. \\`C-c g 0' gives ten programmable keys."
  (interactive)
  (let* ((digit (or digit last-command-event))
         (fn (alist-get digit genie--registers)))
    (unless (characterp digit)
      (user-error "Genie: bind this command to keys ending in a digit"))
    (unless fn
      (user-error "Genie: register %c is empty — fill it with M-x genie-spell"
                  digit))
    (genie--call-spell fn)))

;;;###autoload
(defun genie-spell-bind ()
  "Put one of this session's spells (default the current one) into a register."
  (interactive)
  (unless genie--spells (user-error "Genie: no spells conjured yet"))
  (let* ((names (mapcar (lambda (s) (symbol-name (car s))) genie--spells))
         (default (and genie--spell (symbol-name genie--spell)))
         (name (completing-read
                (format-prompt "Spell to bind" default) names nil t nil nil
                default))
         (digit (genie--read-register "🧞 Register (0-9): ")))
    (genie--bind-register digit (intern name))
    (message "🧞 register %c ← %s" digit name)))

;;;###autoload
(defun genie-spell-keep ()
  "Turn the current spell into a permanent config change (full wish pipeline)."
  (interactive)
  (let ((code (alist-get genie--spell genie--spells)))
    (unless code (user-error "Genie: no spell to keep"))
    (genie (format "Add this function permanently to the config, in the \
module where it belongs, wire a sensible keybinding for it and document \
it:\n\n```elisp\n%s\n```" code))))

;;;; Entry points

;;;###autoload
(defun genie (wish)
  "State a WISH; the agent edits the config, you review, it reloads."
  (interactive (list (string-trim (read-string "🧞 Wish: "))))
  (when genie--busy (user-error "Genie is busy (M-x genie-abort interrupts)"))
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
  (when genie--busy (user-error "Genie is busy (C-c C-k aborts)"))
  (let ((wish (string-trim (buffer-substring-no-properties
                            (or genie--input-start (point-min)) (point-max)))))
    (when (string-empty-p wish) (user-error "Type a wish first"))
    (genie--submit wish)))

;;;###autoload
(defun genie-abort ()
  "Abort the turn in flight (the session survives when the backend can)."
  (interactive)
  (if (and genie--busy (genie-rpc-live-p genie--rpc))
      (progn (genie-rpc-abort genie--rpc)
             (message "🧞 aborting…"))
    (message "🧞 nothing to abort")))

(provide 'genie)
;;; genie.el ends here
