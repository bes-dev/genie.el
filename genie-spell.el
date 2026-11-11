;;; genie-spell.el --- Commands conjured for the session -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.17.0
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

;; The quick magic: a command written on request and evaluated straight
;; into the running session.  Nothing touches disk and nothing is
;; committed, so a spell costs one short answer from a model that is
;; given no tools and no history — which is what keeps it quick on a
;; local one.
;;
;;   `genie-cantrip'  conjure a command and run it at once, right where
;;                    it was asked for
;;   `genie-spell'    conjure one to cast later: on `genie-cast', or on
;;                    one of ten digit registers (`genie-cast-register')
;;   `genie-spell-keep'  make the current spell a wish, so it stays
;;
;; What a spell does to a buffer `genie-undo' takes back, and code that
;; reaches outside buffers is screened first (see genie-live).  A spell
;; cast for the third time says how to keep it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'genie-live)
(require 'genie-pipeline)

(declare-function genie "genie" (wish))

(defvar genie--spell-agent nil "The bare agent that conjures spells, or nil.")
(defvar genie--spell-session nil "The conjuring in flight, or nil.")
(defvar genie--spell-history nil "Minibuffer history for spells and cantrips.")
(defvar genie--spell nil "The current conjured spell entry, or nil.")
(defvar genie--spells nil
  "Spell entries (NAME FUNCTION CODE) conjured this session, newest first.
FUNCTION is the captured function object, immune to later redefinitions
of NAME by a newer spell.")
(defvar genie--registers nil "Alist of (DIGIT-CHAR . SPELL-ENTRY) registers.")
(defvar genie--pending-register nil "Register chosen for the spell being conjured.")
(defvar genie--cantrip-target nil "Where the pending cantrip lands.")
(defvar genie--casts (make-hash-table :test #'eq)
  "How many times each spell entry has been cast.")

;;;; Spells

(defun genie--spell-name (entry) "NAME of spell ENTRY." (nth 0 entry))
(defun genie--spell-fn (entry) "Function object of spell ENTRY." (nth 1 entry))
(defun genie--spell-code (entry) "Source code of spell ENTRY." (nth 2 entry))

(defun genie--extract-elisp (text)
  "Return the first fenced code block in TEXT, or TEXT itself."
  (if (string-match "```[a-z-]*\n\\(\\(?:.\\|\n\\)*?\\)```" text)
      (match-string 1 text)
    text))

(defun genie--eval-spell (code)
  "Evaluate CODE and return its interactive command."
  (or (cadr (cl-find-if (lambda (form)
                          (and (eq (car-safe form) 'defun)
                               (commandp (cadr form))))
                        (car (genie-live-eval code)) :from-end t))
      (error "The reply defines no interactive command")))

(defun genie--cast (entry)
  "Cast spell ENTRY here, journaling its edits for `genie-undo'.
A spell cast for the third time is worth more than a session: say how
to keep it."
  (let ((name (genie--spell-name entry)))
    (prog1 (genie-live-call
            name (lambda () (call-interactively (genie--spell-fn entry))))
      (when (= (cl-incf (gethash entry genie--casts 0)) 3)
        (message "🧞 %s, a third time — M-x genie-spell-keep makes it stay"
                 name)))))

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
Risky calls (see `genie-risky-functions') need confirmation before
anything is evaluated.  With CAST-NOW (a cantrip), immediately invoke
the command where it was asked from."
  (condition-case err
      (let ((code (string-trim (genie--extract-elisp answer))))
        (genie-live-screen code)
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
    (error (message "🧞 spell failed: %s" (error-message-string err))))
  (setq genie--pending-register nil genie--cantrip-target nil))

(defun genie--spell-command ()
  "Return the argv of the agent that conjures spells.
A spell is one function written from one request, so its agent carries
no tools, no history and a one-line prompt: what reaches the model is
the request and little else, which is what makes a cantrip quick on a
local model."
  (append (list genie-elmee-program "--acp" "--no-session" "--tools" ""
                "--system-prompt"
                (format "You write Emacs Lisp for Emacs %s. Reply with code \
only." emacs-version))
          genie-elmee-args))

(defun genie--spell-require-ready ()
  "Signal unless a spell may be conjured now: one at a time."
  (when genie--spell-session
    (user-error "Genie is conjuring a spell — a moment, or M-x genie-abort")))

(defun genie--spell-log (label answer)
  "Note the spell asked for as LABEL, and ANSWER, in the genie's chat.
Only if that chat is open: a spell is not a reason to start its agent."
  (when (get-buffer genie-buffer)
    (genie--emit (format "%s\n%s\n" label (string-trim answer)))))

(defun genie--conjure (prompt label &optional cast-now)
  "Ask the spell agent for the command PROMPT describes.
LABEL names the request in the transcript.  The answer is learnt as a
spell and, with CAST-NOW, invoked where it was asked from.  Each
conjuring is a conversation of its own, closed when it answers."
  (genie--spell-require-ready)
  (unless genie--spell-agent
    (setq genie--spell-agent (genie-acp-agent (genie--spell-command))))
  (let* ((answer "")
         (finish
          (lambda (failure)
            (when genie--spell-session
              (genie-acp-close genie--spell-session)
              (setq genie--spell-session nil)
              (genie--busy 'spell nil)
              (if failure
                  (progn
                    (setq genie--pending-register nil genie--cantrip-target nil)
                    (message "🧞 spell failed: %s" failure))
                ;; This is the agent's process filter.  What was conjured is
                ;; evaluated, and a cantrip cast, from the event loop, where
                ;; it can be asked about and can be interrupted.
                (genie-live-when-free
                 (lambda ()
                   (genie--spell-log label answer)
                   (genie--learn-spell answer cast-now))))))))
    (setq genie--spell-session
          (genie-acp-open
           genie--spell-agent (genie--root)
           :on-text (lambda (delta) (setq answer (concat answer delta)))
           :on-done (lambda (stop)
                      (funcall finish (and (not (equal stop "end_turn")) stop)))
           :on-fail (lambda (reason _code) (funcall finish reason))
           :on-exit (lambda ()
                      (funcall finish
                               (or (genie-acp-stderr genie--spell-agent 3)
                                   "the agent process exited")))))
    (genie--busy 'spell "conjuring")
    (condition-case err
        (genie-acp-prompt genie--spell-session prompt)
      (error (funcall finish (error-message-string err))))))

(defun genie--spell-prompt (request &optional context)
  "Return the prompt asking the agent to conjure a command for REQUEST.
CONTEXT, when given, is a sentence about where the command will run."
  (format "Reply with ONLY one Emacs Lisp code block containing a single \
interactive `defun' (a command) implementing: %s

This is pure code generation — do NOT edit, create or run anything.%s

The command must be self-contained (built-ins and already-loaded \
libraries only), safe under lexical binding, named \
`genie-spell/<short-name>' and carry a docstring in the user's language. \
No commentary outside the code block."
          request (if context (concat "  " context) "")))

;;;###autoload
(defun genie-spell (request &optional register)
  "Conjure an ephemeral interactive command implementing REQUEST.
The generated function is evaluated into the running session (no files
are touched) and armed on `genie-cast'; with REGISTER (a digit
character) it also lands in that spell register, castable via
`genie-cast-register'.  `genie-spell-keep' makes a spell permanent."
  (interactive
   (progn
     (genie--spell-require-ready)
     (list (string-trim (read-string "🧞 Spell (command to conjure): "
                                     nil 'genie--spell-history))
           (genie--read-register "🧞 Register for it (0-9, RET to skip): " t))))
  (when (string-empty-p request) (user-error "Empty spell"))
  (setq genie--pending-register register)
  (genie--conjure (genie--spell-prompt
                   request "Operate on the active region when that is the \
natural reading of the request.")
                  (format "spell: %s" request)))

(defun genie--cast-at-target (entry)
  "Cast cantrip ENTRY in the buffer (and on the region) it was asked from."
  (let ((target genie--cantrip-target)
        (name (genie--spell-name entry)))
    (setq genie--cantrip-target nil)
    (if (not (buffer-live-p (plist-get target :buffer)))
        (message "🧞 %s armed, but its buffer is gone — cast it manually" name)
      (genie-live-at
       target
       (lambda ()
         (let ((journal genie--journal) (said (current-message)))
           (genie--cast entry)
           ;; Whatever the cantrip itself said keeps the echo area; genie
           ;; only adds the undo hint, and only when there is an effect.
           (message "%s%s"
                    (if (equal (current-message) said)
                        (format "🧞 %s" name) ; it said nothing of its own
                      (current-message))
                    (if (eq genie--journal journal)
                        ""              ; nothing to undo
                      " — M-x genie-undo reverts it"))))))))

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
     (genie--spell-require-ready)
     (list (string-trim (read-string "🧞 Cantrip (do right now): "
                                     nil 'genie--spell-history)))))
  (when (string-empty-p request) (user-error "Empty cantrip"))
  (setq genie--cantrip-target (genie-live-place))
  (genie--conjure
   (genie--spell-prompt
    request
    (format "It runs IMMEDIATELY in the buffer it was asked from — major \
mode `%s', %s."
            major-mode
            (if (use-region-p)
                (format "an active region of %d characters (take its bounds \
with (interactive \"r\"))"
                        (- (region-end) (region-beginning)))
              "no active region — act at point or on the whole buffer, \
whichever the request implies")))
   (format "cantrip: %s" request)
   t))

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
  (genie--cast genie--spell))

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
    (genie--cast entry)))

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
  "Turn the current spell into a wish, so that it stays."
  (interactive)
  (unless genie--spell (user-error "Genie: no spell to keep"))
  (genie (format "Keep this command for good, as a wish of its own, on a \
sensible key:\n\n```elisp\n%s\n```" (genie--spell-code genie--spell))))

(provide 'genie-spell)
;;; genie-spell.el ends here
