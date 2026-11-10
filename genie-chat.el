;;; genie-chat.el --- Conversations with the elmee agent -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.13.0
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

;; A chat buffer is one conversation with the elmee agent about one
;; directory.  What the agent says streams in above the prompt, so the
;; next message can be typed while it works; RET sends.
;;
;; `genie-ask' opens the chat for wherever you are — the project of the
;; current buffer — and hands the agent the active region, or with a
;; prefix argument the whole file, to talk about.
;;
;; Inside a chat:
;;
;;   RET        send                   C-c C-k   stop the turn
;;   C-j        newline                C-c C-n   start a new conversation
;;   M-p / M-n  earlier messages       C-c C-s   past conversations
;;   C-c C-/    pick a skill           C-c C-m   switch the model
;;   TAB        complete a /skill name
;;
;; Skills are what the agent calls its `/name' commands: typing
;; `/review src/' sends the skill named review with those arguments.
;; The header line shows what the conversation is about, the model, how
;; full its context is and the step of the plan it is on.
;;
;; `genie-sessions' lists the conversations kept for a directory, newest
;; first, to return to one (RET), start another (n) or delete one (d).
;; A conversation is a file elmee keeps; nothing about it lives in Emacs,
;; so it is there again after a restart.
;;
;; A question the agent asks arrives in the minibuffer, with the options
;; it offered as completions.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'tabulated-list)
(require 'project)
(require 'genie-acp)

(defgroup genie nil
  "The elmee agent in Emacs: conversations, and a self-modifying config."
  :group 'tools
  :prefix "genie-")

(defcustom genie-elmee-program "elmee"
  "Path to the elmee executable."
  :type 'string :group 'genie)

(defcustom genie-elmee-args nil
  "Extra elmee arguments, for example (\"-m\" \"ollama/qwen3-coder:latest\").
Nil uses elmee's own model resolution; the model can also be switched
inside a chat with \\[genie-chat-model]."
  :type '(repeat string) :group 'genie)

(defcustom genie-chat-show-thoughts nil
  "Whether a model's reasoning is written into the chat as it arrives.
Off, the header line only says that it is thinking."
  :type 'boolean :group 'genie)

(defcustom genie-chat-wiki-roots nil
  "Directories searched for the page a [[wikilink]] in an answer names.
A link opens the first NAME.md found under any of them."
  :type '(repeat directory) :group 'genie)

(defface genie-chat-code '((t :inherit (font-lock-constant-face fixed-pitch)))
  "Face for code in an answer: inline, and in fenced blocks."
  :group 'genie)

(defface genie-chat-said '((t :inherit bold))
  "Face for what the person said, in the transcript."
  :group 'genie)

(defvar-local genie-chat--agent nil "The agent process of this chat.")
(defvar-local genie-chat--session nil "The conversation this chat shows.")
(defvar-local genie-chat--directory nil "The directory this chat is about.")
(defvar-local genie-chat--busy nil
  "The time the turn in flight started, or nil when there is none.")
(defvar-local genie-chat--clock nil "Timer redrawing the header while busy.")
(defvar-local genie-chat--said nil "What was sent from here, newest first.")
(defvar-local genie-chat--recall nil
  "How far back `genie-chat-earlier' has gone, or nil.")
(defvar-local genie-chat--thinking nil "Non-nil while the model reasons.")
(defvar-local genie-chat--answer "" "The answer text of the turn in flight.")
(defvar-local genie-chat--answer-start nil "Marker where that answer begins.")
(defvar-local genie-chat--tail nil "Marker where the transcript grows.")
(defvar-local genie-chat--input nil "Marker where the typed message begins.")
(defvar-local genie-chat--calls nil "Tool call id → marker at its line.")
(defvar-local genie-chat--commands nil "Skills: (NAME . DESCRIPTION).")
(defvar-local genie-chat--options nil "What the session lets one choose.")
(defvar-local genie-chat--usage nil "Context in use, as (USED . SIZE).")
(defvar-local genie-chat--plan nil "The agent's plan entries.")
(defvar-local genie-chat--title nil "What the conversation is about.")
(defvar-local genie-chat--attached nil
  "Context for the next message, as (LABEL . CONTENT-BLOCK).")
(defvar-local genie-chat--start nil
  "Function called with what was asked before a turn is sent.
It may signal an error to refuse the turn.")
(defvar-local genie-chat--finish nil
  "Function called with (STOP-REASON ANSWER) when a turn ends.")

(defvar genie-chat--history nil "Minibuffer history of answers to the agent.")

;;;; The buffer

(defvar genie-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'genie-chat-send)
    (define-key map (kbd "C-j") #'newline)
    (define-key map (kbd "TAB") #'completion-at-point)
    (define-key map (kbd "M-p") #'genie-chat-earlier)
    (define-key map (kbd "M-n") #'genie-chat-later)
    (define-key map (kbd "C-c C-k") #'genie-chat-abort)
    (define-key map (kbd "C-c C-n") #'genie-chat-new)
    (define-key map (kbd "C-c C-s") #'genie-sessions)
    (define-key map (kbd "C-c C-m") #'genie-chat-model)
    (define-key map (kbd "C-c C-/") #'genie-chat-skill)
    map)
  "Keymap for `genie-chat-mode'.")

(define-derived-mode genie-chat-mode fundamental-mode "genie"
  "A conversation with the elmee agent.
\\<genie-chat-mode-map>\\[genie-chat-send] sends what is typed after the \
prompt, \\[genie-chat-abort] stops the turn,
\\[genie-sessions] lists past conversations and \\[genie-chat-new] starts \
a new one.

Killing the buffer ends its agent process; what was said stays in the
conversation elmee keeps, and `genie-sessions' returns to it."
  (visual-line-mode 1)
  (setq-local header-line-format '(:eval (genie-chat--header)))
  (add-hook 'completion-at-point-functions #'genie-chat--complete-skill nil t)
  (add-hook 'kill-buffer-hook #'genie-chat--shutdown nil t))

(defun genie-chat-command ()
  "Return the argv that serves conversations: elmee in ACP mode."
  (append (list genie-elmee-program "--acp") genie-elmee-args))

(defun genie-chat-open (directory &rest options)
  "Return the chat buffer for DIRECTORY, creating it when needed.
OPTIONS is a plist: `:name' is the buffer's name, `:command' the agent's
argv (default `genie-chat-command'), `:start' a function called before
every turn with what was asked (or the symbol `note'), free to refuse it
by signalling, and `:finish' one called with (STOP-REASON ANSWER)
whenever a turn ends."
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (name (or (plist-get options :name)
                   (format "*genie: %s*"
                           (file-name-nondirectory
                            (directory-file-name directory)))))
         (buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'genie-chat-mode)
        (genie-chat-mode)
        (setq genie-chat--directory directory
              default-directory directory
              genie-chat--start (plist-get options :start)
              genie-chat--finish (plist-get options :finish)
              genie-chat--agent (genie-acp-agent
                                 (or (plist-get options :command)
                                     (genie-chat-command))))
        (genie-chat--converse nil)))
    buffer))

(defun genie-chat--converse (resume)
  "Point this chat at a conversation: a new one, or the one RESUME names.
The buffer is emptied; a resumed conversation is played back into it."
  (when genie-chat--session
    (genie-acp-close genie-chat--session))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq genie-chat--tail (point-marker)
          genie-chat--calls (make-hash-table :test #'equal)
          genie-chat--busy nil genie-chat--thinking nil
          genie-chat--answer "" genie-chat--answer-start nil
          genie-chat--usage nil genie-chat--plan nil
          genie-chat--title nil genie-chat--attached nil
          genie-chat--said nil genie-chat--recall nil)
    (genie-chat--stop-clock)
    (unless resume
      (genie-chat--insert
       ;; Spelled out rather than looked up: `C-c C-m' would be shown as
       ;; `C-c RET', which is the same key and reads like a different one.
       "RET sends · C-j newline · M-p earlier messages · C-c C-/ skills · \
C-c C-s past conversations · C-c C-m model\n"
       'shadow))
    (goto-char (point-max))
    (insert (propertize "\n❯ " 'face 'minibuffer-prompt
                        'read-only t 'rear-nonsticky t 'front-sticky t))
    (setq genie-chat--input (point-marker)))
  (let ((buffer (current-buffer)))
    (cl-flet ((in-chat (function)
                (lambda (&rest args)
                  (when (buffer-live-p buffer)
                    (with-current-buffer buffer (apply function args))))))
      (setq genie-chat--session
            (genie-acp-open
             genie-chat--agent genie-chat--directory
             :resume resume
             :on-text (in-chat #'genie-chat--on-text)
             :on-thought (in-chat #'genie-chat--on-thought)
             :on-user (in-chat #'genie-chat--on-user)
             :on-tool (in-chat #'genie-chat--on-tool)
             :on-tool-update (in-chat #'genie-chat--on-tool-update)
             :on-plan (in-chat (lambda (plan) (setq genie-chat--plan plan)))
             :on-usage (in-chat (lambda (used size)
                                  (setq genie-chat--usage (cons used size))))
             :on-commands (in-chat (lambda (commands)
                                     (setq genie-chat--commands commands)))
             :on-options (in-chat (lambda (options)
                                    (setq genie-chat--options options)))
             :on-title (in-chat (lambda (title) (setq genie-chat--title title)))
             :on-ask (in-chat #'genie-chat--on-ask)
             :on-done (in-chat #'genie-chat--finish-turn)
             :on-fail (in-chat #'genie-chat--on-fail)
             :on-exit (in-chat #'genie-chat--on-exit)))))
  ;; Opened now rather than with the first message: the skills to complete
  ;; and the models to choose from are things the session says when it
  ;; opens, and a conversation nothing was said in leaves nothing behind.
  (condition-case nil
      (genie-acp-ensure genie-chat--session #'ignore)
    (error nil))
  (when resume
    ;; Playing back ends when the session has opened; what it wrote is
    ;; then an ordinary transcript, to be dressed like one.
    (genie-acp-ensure genie-chat--session
                       (let ((buffer (current-buffer)))
                         (lambda ()
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (genie-chat--dress (point-min) genie-chat--tail)
                               (genie-chat-note "— earlier conversation, resumed —\n")
                               (goto-char (point-max)))))))))

(defun genie-chat--shutdown ()
  "End the agent process of the chat being killed."
  (genie-chat--stop-clock)
  (when genie-chat--agent
    (genie-acp-shutdown genie-chat--agent)))

(defun genie-chat--header ()
  "Return the header line: the subject, the model, and the state of things."
  (let* ((model (plist-get (genie-chat--option "model") :currentValue))
         (plan genie-chat--plan)
         (step (cl-find "in_progress" plan :test #'equal
                        :key (lambda (entry) (plist-get entry :status))))
         (done (cl-count "completed" plan :test #'equal
                         :key (lambda (entry) (plist-get entry :status)))))
    (concat
     " 🧞 "
     (propertize (truncate-string-to-width
                  (car (split-string
                        (or genie-chat--title
                            (file-name-nondirectory
                             (directory-file-name genie-chat--directory)))
                        "\n"))
                  48 nil nil "…")
                 'face 'bold)
     ;; What is happening now comes first: it is what a glance is for, and
     ;; a long plan step must not push it off the edge.
     (when genie-chat--busy
       (format "  ·  %s %ds (C-c C-k stops)"
               (if genie-chat--thinking "thinking" "working")
               (floor (float-time (time-since genie-chat--busy)))))
     (and model (format "  ·  %s" model))
     (pcase genie-chat--usage
       (`(,(and used (pred numberp)) . ,(and size (pred numberp) (pred (< 0))))
        (format "  ·  %d%% of context" (/ (* 100 used) size))))
     (and genie-chat--attached
          (format "  ·  📎 %s" (mapconcat #'car genie-chat--attached ", ")))
     (and plan (format "  ·  plan %d/%d%s" done (length plan)
                       (if step (concat ": " (plist-get step :content)) ""))))))

(defun genie-chat--start-clock ()
  "Redraw the header every second for the length of a turn."
  (genie-chat--stop-clock)
  (let ((buffer (current-buffer)))
    (setq genie-chat--clock
          (run-at-time 1 1 (lambda ()
                             (when (get-buffer-window buffer t)
                               (force-mode-line-update t)))))))

(defun genie-chat--stop-clock ()
  "Stop redrawing the header of this chat."
  (when genie-chat--clock
    (cancel-timer genie-chat--clock)
    (setq genie-chat--clock nil)))

(defun genie-chat--option (id)
  "Return the session option called ID, a plist, or nil."
  (cl-find id genie-chat--options :test #'equal
           :key (lambda (option) (plist-get option :id))))

;;;; Writing into the transcript

(defun genie-chat--insert (text &optional face)
  "Add TEXT (in FACE) to the transcript, above the prompt.
The window keeps following the conversation unless it was scrolled away."
  (let* ((inhibit-read-only t)
         (window (get-buffer-window (current-buffer) t))
         (follow (and window (>= (window-point window) genie-chat--tail))))
    (save-excursion
      (goto-char genie-chat--tail)
      (insert (apply #'propertize text 'read-only t 'front-sticky t
                     (and face (list 'face face))))
      (set-marker genie-chat--tail (point)))
    (when (and follow (< (window-point window) genie-chat--input))
      (set-window-point window genie-chat--tail))))

(defun genie-chat--fresh-line ()
  "Make sure the transcript ends at the start of a line."
  (unless (or (= genie-chat--tail (point-min))
              (eq (char-before genie-chat--tail) ?\n))
    (genie-chat--insert "\n")))

(defun genie-chat-note (text &optional face buffer)
  "Write TEXT into the transcript of BUFFER (default: this chat) as an aside.
It is shown in FACE, by default the one for things that are not the
conversation itself."
  (with-current-buffer (or buffer (current-buffer))
    (genie-chat--fresh-line)
    (genie-chat--insert text (or face 'shadow))))

(defun genie-chat--on-user (text)
  "Show TEXT as something the person said."
  (push text genie-chat--said)
  (genie-chat--fresh-line)
  (genie-chat--insert "\n❯ " 'minibuffer-prompt)
  (genie-chat--insert text 'genie-chat-said)
  (genie-chat--insert "\n\n"))

(defun genie-chat--on-text (delta)
  "Stream answer DELTA, swallowing the blank chunks around tool activity."
  (let ((leading (string-empty-p (string-trim genie-chat--answer))))
    (setq genie-chat--thinking nil
          genie-chat--answer (concat genie-chat--answer delta))
    (when (and leading (not (string-empty-p (string-trim delta))))
      (genie-chat--fresh-line)
      (setq genie-chat--answer-start (copy-marker genie-chat--tail)))
    (genie-chat--insert (if leading (string-trim-left delta) delta))))

(defun genie-chat--on-thought (delta)
  "Note that the model is reasoning; show DELTA when that is asked for."
  (setq genie-chat--thinking t)
  (when genie-chat-show-thoughts
    (genie-chat--insert delta 'shadow)))

(defun genie-chat--on-tool (call)
  "Log tool CALL as a line that its ending will finish."
  (setq genie-chat--thinking nil)
  (genie-chat--fresh-line)
  (puthash (plist-get call :toolCallId) (copy-marker genie-chat--tail)
           genie-chat--calls)
  (genie-chat--insert
   (format "⏳ %s\n" (or (plist-get call :title) (plist-get call :kind) "tool"))
   'shadow))

(defun genie-chat--on-tool-update (call)
  "Mark the line of tool CALL with how it ended.
A call that failed says why in a line of its own: what went wrong is the
part of a tool's output worth reading without being asked."
  (when-let* ((at (gethash (plist-get call :toolCallId) genie-chat--calls)))
    (let ((failed (equal (plist-get call :status) "failed"))
          (inhibit-read-only t))
      (save-excursion
        (goto-char at)
        (when (looking-at "⏳")
          (replace-match (propertize (if failed "✗" "✓")
                                     'face (if failed 'error 'shadow)
                                     'read-only t 'front-sticky t)
                         t t))
        (when failed
          (when-let* ((said (genie-chat--call-output call)))
            (forward-line 1)
            (let ((at-tail (= (point) genie-chat--tail)))
              (insert (propertize (format "  %s\n" said)
                                  'face 'error 'read-only t 'front-sticky t))
              ;; Written at the very end, it is part of the transcript the
              ;; next output must follow rather than precede.
              (when at-tail (set-marker genie-chat--tail (point))))))))))

(defun genie-chat--call-output (call)
  "Return the last line of the output of tool CALL, or nil."
  (let* ((content (append (plist-get call :content) nil))
         (text (plist-get (plist-get (car content) :content) :text)))
    (car (last (cl-remove-if (lambda (line) (string-prefix-p "[exit status" line))
                             (split-string (or text "") "\n" t))))))

(defun genie-chat--on-fail (message code)
  "Report that a request failed with MESSAGE and CODE, and end the turn."
  (genie-chat-note (format "[%s]\n" message) 'error)
  (when (eql code genie-acp-auth-required)
    (genie-chat-note "Sign in with M-x genie-login, then send it again.\n"))
  (genie-chat--finish-turn 'failed))

(defun genie-chat--on-exit ()
  "Report that the agent process died, with whatever it said last."
  (when genie-chat--busy
    (genie-chat-note "[the agent process exited]\n" 'error)
    (when-let* ((said (genie-acp-stderr genie-chat--agent)))
      (genie-chat-note (concat said "\n") 'error))
    (genie-chat--finish-turn 'exited)))

(defun genie-chat--finish-turn (stop)
  "End the turn in flight, which stopped because of STOP.
STOP is the agent's stop reason, or `failed' or `exited'."
  (when genie-chat--busy
    (setq genie-chat--busy nil genie-chat--thinking nil)
    (genie-chat--stop-clock)
    (when (and genie-chat--answer-start
               (< genie-chat--answer-start genie-chat--tail))
      (genie-chat--dress genie-chat--answer-start genie-chat--tail))
    (genie-chat--fresh-line)
    (pcase stop
      ("cancelled" (genie-chat-note "— stopped —\n"))
      ("max_turn_requests"
       (genie-chat-note "— stopped at the step limit; say “continue” to go on —\n")))
    (force-mode-line-update)
    (if genie-chat--finish
        (funcall genie-chat--finish stop genie-chat--answer)
      ;; Someone who went elsewhere while it worked is told it is done.
      (unless (eq (window-buffer) (current-buffer))
        (message "🧞 %s: %s" (buffer-name)
                 (if (equal stop "end_turn") "answered" "stopped"))))))

;;;; Dressing an answer: light markdown, and things to click

(define-button-type 'genie-chat-file
  'follow-link t 'help-echo "Open this file"
  'action (lambda (button)
            (find-file-other-window (button-get button 'file))
            (when-let* ((line (button-get button 'line)))
              (goto-char (point-min))
              (forward-line (1- line)))))

(define-button-type 'genie-chat-url
  'follow-link t 'help-echo "Open this in a browser"
  'action (lambda (button) (browse-url (button-get button 'url))))

(define-button-type 'genie-chat-wikilink
  'follow-link t 'help-echo "Open this page"
  'action (lambda (button) (genie-chat--open-page (button-get button 'page))))

(defun genie-chat--open-page (name)
  "Open the wiki page NAME, found under `genie-chat-wiki-roots'."
  (let* ((leaf (concat (file-name-nondirectory name) ".md"))
         (found (cl-some
                 (lambda (root)
                   (and (file-directory-p root)
                        (car (directory-files-recursively
                              root (concat "\\`" (regexp-quote leaf) "\\'")))))
                 genie-chat-wiki-roots)))
    (if found
        (find-file-other-window found)
      (user-error "No page %s under `genie-chat-wiki-roots'" name))))

(defun genie-chat--dress (beg end)
  "Render the markdown between BEG and END lightly, and make links of it.
Headings, **bold**, `code` and fenced blocks get faces; a path to a
file that exists, a URL and a [[wikilink]] become buttons.  The text
itself is left as written."
  (let ((inhibit-read-only t) (end (copy-marker end)))
    (save-excursion
      (cl-flet ((each (regexp function)
                  (goto-char beg)
                  (while (re-search-forward regexp end t)
                    (save-match-data (funcall function)))))
        (each "^#+ .*$"
              (lambda () (add-face-text-property
                          (match-beginning 0) (match-end 0) 'bold)))
        (each "\\*\\*\\([^*\n]+\\)\\*\\*"
              (lambda () (add-face-text-property
                          (match-beginning 1) (match-end 1) 'bold)))
        (each "`\\([^`\n]+\\)`"
              (lambda () (add-face-text-property
                          (match-beginning 1) (match-end 1) 'genie-chat-code)))
        (each "^```.*\n\\(\\(?:.*\n\\)*?\\)```"
              (lambda () (add-face-text-property
                          (match-beginning 1) (match-end 1) 'genie-chat-code)))
        (each "https?://[^ \t\n<>\"')]+[^ \t\n<>\"').,;:!?]"
              (lambda () (make-text-button
                          (match-beginning 0) (match-end 0)
                          'type 'genie-chat-url
                          'url (match-string-no-properties 0))))
        (each "\\[\\[\\([^]|\n]+\\)\\(?:|[^]\n]*\\)?\\]\\]"
              (lambda () (make-text-button
                          (match-beginning 0) (match-end 0)
                          'type 'genie-chat-wikilink
                          'page (match-string-no-properties 1))))
        (each "\\(?:^\\|[ \t(`\"']\\)\\(\\(?:~\\|\\.\\{0,2\\}\\)?/[^ \t\n`\"'()<>:,;]+\\)\\(?::\\([0-9]+\\)\\)?"
              (lambda ()
                (let ((file (expand-file-name (match-string-no-properties 1)
                                              genie-chat--directory)))
                  (when (file-exists-p file)
                    (make-text-button
                     (match-beginning 1) (or (match-end 2) (match-end 1))
                     'type 'genie-chat-file 'file file
                     'line (and (match-string 2)
                                (string-to-number (match-string 2))))))))))
    (set-marker end nil)))

;;;; Turns

(defun genie-chat-busy-p (&optional buffer)
  "Return non-nil while a turn is in flight in BUFFER (default: this chat)."
  (buffer-local-value 'genie-chat--busy (or buffer (current-buffer))))

(defun genie-chat-submit (buffer text &optional shown)
  "Send TEXT as the next turn of the chat in BUFFER.
The transcript shows SHOWN instead of TEXT when given — a short name
for a long prompt — and nothing of the person's when SHOWN is `note'.
Whatever was attached with `genie-ask' goes with it."
  (with-current-buffer buffer
    (when genie-chat--busy
      (user-error "Genie is busy here — wait, or C-c C-k stops it"))
    (when genie-chat--start
      (funcall genie-chat--start (or shown text)))
    (let ((attached (reverse genie-chat--attached)))
      (unless (eq shown 'note)
        (genie-chat--on-user (or shown text))
        (dolist (item attached)
          (genie-chat-note (format "📎 %s\n" (car item)))))
      (setq genie-chat--busy (current-time) genie-chat--thinking nil
            genie-chat--recall nil
            genie-chat--answer "" genie-chat--answer-start nil
            genie-chat--attached nil)
      (genie-chat--start-clock)
      (force-mode-line-update)
      ;; A process that cannot even start — elmee not on the path — fails
      ;; here, synchronously, and must end the turn like any other failure.
      (condition-case err
          (genie-acp-prompt genie-chat--session
                            (append (mapcar #'cdr attached)
                                    (list (list :type "text" :text text))))
        (error (genie-chat--on-fail (error-message-string err) nil))))))

(defun genie-chat-send ()
  "Send what is typed after the prompt."
  (interactive)
  (let ((text (string-trim (buffer-substring-no-properties
                            genie-chat--input (point-max)))))
    (when (string-empty-p text) (user-error "Type a message first"))
    (when genie-chat--busy
      (user-error "Genie is busy here — wait, or C-c C-k stops it"))
    (delete-region genie-chat--input (point-max))
    (genie-chat-submit (current-buffer) text)))

(defun genie-chat-abort ()
  "Stop the turn in flight, keeping the conversation."
  (interactive)
  (if genie-chat--busy
      (progn (genie-acp-cancel genie-chat--session)
             (message "🧞 stopping…"))
    (message "🧞 nothing to stop")))

(defun genie-chat-new ()
  "Start a new conversation in this chat.
The one being left stays in the list `genie-sessions' shows."
  (interactive)
  (when genie-chat--busy (user-error "Genie is busy here — stop it first"))
  (genie-chat--converse nil)
  (goto-char (point-max))
  (message "🧞 a new conversation — C-c C-s returns to earlier ones"))

(defun genie-chat--recall (step)
  "Replace what is typed with the message STEP places further back."
  (let ((at (+ (or genie-chat--recall -1) step)))
    (cond ((< at 0)
           (setq genie-chat--recall nil)
           (delete-region genie-chat--input (point-max)))
          ((nth at genie-chat--said)
           (setq genie-chat--recall at)
           (delete-region genie-chat--input (point-max))
           (goto-char (point-max))
           (insert (nth at genie-chat--said)))
          (t (user-error "Nothing earlier was said here")))))

(defun genie-chat-earlier ()
  "Bring back the message sent before the one shown, to send it again."
  (interactive)
  (genie-chat--recall 1))

(defun genie-chat-later ()
  "Step forward again through the messages `genie-chat-earlier' brought back."
  (interactive)
  (genie-chat--recall -1))

(defun genie-chat-attach (buffer label block)
  "Attach content BLOCK, shown as LABEL, to the next message of chat BUFFER."
  (with-current-buffer buffer
    (push (cons label block) genie-chat--attached)
    (force-mode-line-update)))

(defun genie-chat-draft (buffer text)
  "Put TEXT after the prompt of chat BUFFER, unless something is typed there."
  (with-current-buffer buffer
    (when (= genie-chat--input (point-max))
      (goto-char (point-max))
      (insert text))))

(defun genie-chat-context (&optional whole)
  "Return what the person is looking at, as (LABEL . CONTENT-BLOCK), or nil.
That is the active region; or, with WHOLE, the visited file or the
directory of a Dired buffer, named for the agent to read itself."
  (let ((file (buffer-file-name)))
    (cond
     ((use-region-p)
      (let ((from (line-number-at-pos (region-beginning)))
            (to (line-number-at-pos (region-end))))
        (cons (format "%s:%d-%d" (buffer-name) from to)
              (list :type "resource"
                    :resource
                    (list :uri (format "file://%s#L%d-%d"
                                       (or file (buffer-name)) from to)
                          :text (buffer-substring-no-properties
                                 (region-beginning) (region-end)))))))
     ((and whole (or file (derived-mode-p 'dired-mode)))
      (let ((path (expand-file-name (or file default-directory))))
        (cons (abbreviate-file-name path)
              (list :type "resource_link" :uri (concat "file://" path)
                    :name (file-name-nondirectory
                           (directory-file-name path)))))))))

;;;; Skills, the model, questions, signing in

(defun genie-chat--complete-skill ()
  "Complete a `/skill' name at the start of the message being typed."
  (when (and genie-chat--input (>= (point) genie-chat--input))
    (save-excursion
      (let ((end (point)))
        (goto-char genie-chat--input)
        (when (and (looking-at "/\\([^ \t\n]*\\)") (<= end (match-end 0)))
          (list (1+ genie-chat--input) (match-end 0)
                genie-chat--commands
                :annotation-function
                (lambda (name)
                  (concat "  " (cdr (assoc name genie-chat--commands))))
                :exit-function
                (lambda (_name status)
                  (when (eq status 'finished) (insert " ")))))))))

(defun genie-chat-skill ()
  "Pick one of the agent's skills and start a message with it."
  (interactive)
  (unless genie-chat--commands
    (user-error "No skills yet — they arrive once the conversation opens"))
  (let* ((completion-extra-properties
          (list :annotation-function
                (lambda (name)
                  (concat "  " (cdr (assoc name genie-chat--commands))))))
         (name (completing-read "🧞 Skill: " genie-chat--commands nil t)))
    (goto-char genie-chat--input)
    (delete-region genie-chat--input (point-max))
    (insert "/" name " ")))

(defun genie-chat-model ()
  "Switch the model of this conversation."
  (interactive)
  (let* ((option (or (genie-chat--option "model")
                     (user-error "No models yet — send a message first")))
         (models (mapcar (lambda (choice) (plist-get choice :value))
                         (plist-get option :options)))
         (model (completing-read
                 (format "🧞 Model (now %s): " (plist-get option :currentValue))
                 models nil t))
         (buffer (current-buffer)))
    (genie-acp-set
     genie-chat--session "model" model
     (lambda (refused)
       (if refused
           (message "🧞 model not switched: %s" refused)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (plist-put option :currentValue model)
             (force-mode-line-update)))
         (message "🧞 now on %s" model))))))

(defun genie-chat--on-ask (params reply)
  "Put the agent's question in PARAMS to the person; answer through REPLY.
Each field of the form is asked in the minibuffer, with the options the
agent offered as completions and anything else accepted as typed.
Quitting declines the whole question."
  (let ((fields (plist-get (plist-get (plist-get (plist-get params :mode) :form)
                                      :requestedSchema)
                           :properties)))
    ;; Asked from the event loop rather than from the process filter that
    ;; delivered it, where a minibuffer would hold up everything else.
    (run-at-time
     0 nil
     (lambda ()
       (funcall
        reply
        (condition-case nil
            (cl-loop
             for (key field) on fields by #'cddr
             nconc (list key
                         (completing-read
                          (format "🧞 %s " (or (plist-get field :description)
                                               (plist-get field :title)
                                               "Answer:"))
                          (append (plist-get field :enum) nil)
                          nil nil nil 'genie-chat--history)))
          (quit nil)))))))

;;;###autoload
(defun genie-login ()
  "Sign the agent in — for elmee, a browser opens for a Codex account."
  (interactive)
  (let ((agent (or genie-chat--agent
                   (user-error "Run this from a genie chat buffer"))))
    (message "🧞 signing in — look at your browser…")
    (genie-acp-sign-in
     agent
     (lambda (refused)
       (message (if refused "🧞 not signed in: %s" "🧞 signed in%s")
                (or refused ""))))))

;;;; Talking about where you are

(defun genie-chat--here ()
  "Return the directory a chat started from this buffer is about."
  (if (derived-mode-p 'genie-chat-mode)
      genie-chat--directory
    (if-let* ((project (project-current)))
        (project-root project)
      default-directory)))

;;;###autoload
(defun genie-ask (&optional whole)
  "Open the chat for this project, with what you are looking at attached.
An active region is attached as it is; with prefix argument WHOLE the
visited file — or in Dired the directory — is named for the agent to
read.  What is attached goes with the next message."
  (interactive "P")
  (let* ((item (genie-chat-context whole))
         (chat (genie-chat-open (genie-chat--here))))
    (deactivate-mark)
    (when item (genie-chat-attach chat (car item) (cdr item)))
    (pop-to-buffer chat)
    (goto-char (point-max))))

;;;; The list of conversations

(defvar-local genie-sessions--chat nil "The chat this list belongs to.")

(defvar genie-sessions-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'genie-sessions-open)
    (define-key map "n" #'genie-sessions-new)
    (define-key map "d" #'genie-sessions-delete)
    map)
  "Keymap for `genie-sessions-mode'.")

(define-derived-mode genie-sessions-mode tabulated-list-mode "genie-sessions"
  "The conversations kept for one directory, newest first.
\\<genie-sessions-mode-map>\\[genie-sessions-open] returns to the one at \
point, \\[genie-sessions-new] starts a new one,
\\[genie-sessions-delete] deletes one, \\[revert-buffer] reads the list again."
  (setq tabulated-list-format [("When" 12 nil) ("Asked" 6 nil :right-align t)
                               ("About" 0 nil)]
        tabulated-list-padding 2)
  (add-hook 'tabulated-list-revert-hook #'genie-sessions--fetch nil t)
  (tabulated-list-init-header))

(defun genie-sessions--ago (stamp)
  "Say how long ago STAMP, an RFC 3339 time, was."
  (let ((seconds (and stamp
                      (ignore-errors
                        (float-time (time-subtract nil (date-to-time stamp)))))))
    (cond ((null seconds) "")
          ((< seconds 90) "just now")
          ((< seconds 5400) (format "%d min ago" (round seconds 60)))
          ((< seconds 129600) (format "%d h ago" (round seconds 3600)))
          (t (format "%d d ago" (round seconds 86400))))))

(defun genie-sessions--fetch ()
  "Ask the agent for this list's conversations and show them."
  (let ((buffer (current-buffer))
        (chat genie-sessions--chat))
    (unless (buffer-live-p chat) (user-error "Its chat is gone"))
    (let ((current (genie-acp-session-id
                    (buffer-local-value 'genie-chat--session chat))))
      (genie-acp-list
       (buffer-local-value 'genie-chat--agent chat)
       (buffer-local-value 'genie-chat--directory chat)
       (lambda (sessions reason)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when reason (message "🧞 %s" reason))
             (setq tabulated-list-entries
                   (mapcar
                    (lambda (session)
                      (let ((id (plist-get session :sessionId)))
                        (list id
                              (vector
                               (genie-sessions--ago (plist-get session :updatedAt))
                               (format "%s" (or (plist-get session :prompts) ""))
                               (concat (if (equal id current) "▸ " "")
                                       (or (plist-get session :title)
                                           "(nothing asked yet)"))))))
                    sessions))
             (tabulated-list-print t))))))))

;;;###autoload
(defun genie-sessions ()
  "List the conversations kept for this directory, to return to one.
From a chat it is that chat's list; from anywhere else, the list of the
project you are in."
  (interactive)
  (let* ((chat (if (derived-mode-p 'genie-chat-mode)
                   (current-buffer)
                 (genie-chat-open (genie-chat--here))))
         (list (get-buffer-create
                (format "*genie sessions: %s*"
                        (file-name-nondirectory
                         (directory-file-name
                          (buffer-local-value 'genie-chat--directory chat)))))))
    (with-current-buffer list
      (genie-sessions-mode)
      (setq genie-sessions--chat chat)
      (genie-sessions--fetch))
    (pop-to-buffer list)
    (message "RET returns to one · n starts a new one · d deletes · g refreshes · q closes")))

(defun genie-sessions--idle-chat ()
  "Return this list's chat, which must not be in the middle of a turn."
  (let ((chat genie-sessions--chat))
    (unless (buffer-live-p chat) (user-error "Its chat is gone"))
    (when (genie-chat-busy-p chat)
      (user-error "Genie is busy in that chat — stop it first"))
    chat))

(defun genie-sessions-open ()
  "Return to the conversation at point.
Its chat is filled with what was said and continues from there."
  (interactive)
  (let ((id (or (tabulated-list-get-id) (user-error "No conversation here")))
        (chat (genie-sessions--idle-chat)))
    (quit-window)
    (pop-to-buffer chat)
    (unless (equal id (genie-acp-session-id genie-chat--session))
      (genie-chat--converse id))
    (goto-char (point-max))))

(defun genie-sessions-new ()
  "Start a new conversation in this list's chat."
  (interactive)
  (let ((chat (genie-sessions--idle-chat)))
    (quit-window)
    (pop-to-buffer chat)
    (genie-chat-new)))

(defun genie-sessions-delete ()
  "Delete the conversation at point, for good."
  (interactive)
  (let* ((id (or (tabulated-list-get-id) (user-error "No conversation here")))
         (chat (genie-sessions--idle-chat))
         (buffer (current-buffer)))
    (when (equal id (genie-acp-session-id
                     (buffer-local-value 'genie-chat--session chat)))
      (user-error "That is the open conversation — start a new one first (n)"))
    (when (yes-or-no-p "Delete this conversation for good? ")
      (genie-acp-delete
       (buffer-local-value 'genie-chat--agent chat) id
       (lambda (refused)
         (if refused
             (message "🧞 not deleted: %s" refused)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer (genie-sessions--fetch)))))))))

(provide 'genie-chat)
;;; genie-chat.el ends here
