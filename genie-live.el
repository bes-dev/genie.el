;;; genie-live.el --- Running conjured code in the live session -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.17.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: lisp, tools
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

;; Code a model wrote, run in the Emacs a person is working in.  Four
;; things make that something one can live with, and they are all here:
;;
;; - It is screened first: code that reaches for processes, the network,
;;   file deletion or Emacs's own lifetime is named, and with `risky-code'
;;   in `genie-confirm' it runs only after a yes.
;;
;; - It runs when Emacs is free.  Lisp runs on one thread, the one that
;;   reads keys and draws the screen, so code run from a process filter
;;   freezes the editor and cannot even be interrupted there.
;;   `genie-live-when-free' runs it from the event loop instead, after
;;   any minibuffer in use is done, where C-g stops it like any command.
;;
;; - It runs where it was asked for: `genie-live-place' remembers the
;;   buffer, the point and the region, and `genie-live-at' goes back.
;;
;; - What it did to a buffer can be taken back: `genie-live-call' notes
;;   the edits in the journal `genie-undo' pops.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defcustom genie-confirm '(wish risky-code undo)
  "Which genie actions stop to ask you first.

  `wish'        review the diff before a change to the config is committed
  `risky-code'  approve conjured code that calls a risky function
                \(see `genie-risky-functions')
  `undo'        approve deleting a wish's commit from history

Drop `wish' for the frictionless flow the README recommends: a wish is
validated, committed and switched on on the spot, and you judge the
result in the running editor instead of in a diff.  Nothing is lost by
it — every wish is still one commit that `genie-undo' takes back, and a
change that fails validation is handed back to the agent to fix (see
`genie-repair-attempts'), then undone rather than applied, instead of
becoming a diff you did not ask to read.  Set to nil to never be asked
anything."
  :type '(set (const :tag "Review the diff of a wish" wish)
              (const :tag "Approve risky conjured code" risky-code)
              (const :tag "Approve dropping a commit" undo))
  :group 'genie)

(defcustom genie-risky-functions
  '(shell-command shell-command-to-string async-shell-command
    shell-command-on-region call-process call-process-region
    call-process-shell-command process-file process-file-shell-command
    process-lines start-process start-process-shell-command
    start-file-process start-file-process-shell-command make-process
    make-serial-process make-network-process open-network-stream
    eshell-command compile term-exec
    url-retrieve url-retrieve-synchronously url-copy-file
    url-insert-file-contents browse-url
    delete-file delete-directory move-file-to-trash rename-file copy-file
    write-region write-file with-temp-file append-to-file
    make-pipe-process set-file-modes dired-delete-file
    kill-emacs save-buffers-kill-emacs restart-emacs server-eval-at)
  "Functions conjured code may only call after explicit confirmation.
Code run in the live session is meant to act on buffers; anything
reaching processes, the network, the file system or Emacs's lifetime is
named before it is evaluated.

This is a courtesy, not a sandbox.  The code is read for these names,
and Lisp has more ways to reach a function than naming it; the agent
that wrote the code can also run a shell command without asking Emacs
at all.  What the list buys is that code which says what it does is
asked about when it does something you may not have meant."
  :type '(repeat symbol) :group 'genie)

(defun genie--confirm-p (what)
  "Return non-nil when `genie-confirm' lists WHAT as needing approval."
  (memq what genie-confirm))

;;;; Screening and evaluating

(defun genie--mentions (code symbols)
  "Return those of SYMBOLS that CODE, a string of Lisp, mentions."
  (let (found)
    (with-temp-buffer
      (insert code)
      (goto-char (point-min))
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (cl-labels ((walk (x)
                            (cond ((consp x) (walk (car x)) (walk (cdr x)))
                                  ((and (symbolp x) (memq x symbols))
                                   (cl-pushnew x found)))))
                (walk form))))
        (error nil)))
    (nreverse found)))

(defun genie-live-screen (code)
  "Signal unless CODE may run, after naming whatever risky it reaches for.
With `risky-code' in `genie-confirm' a person says yes first; without,
the calls are still named in the echo area."
  (when-let* ((risky (genie--mentions code genie-risky-functions))
              (named (mapconcat #'symbol-name risky ", ")))
    (if (genie--confirm-p 'risky-code)
        (unless (yes-or-no-p (format "⚠ The conjured code calls %s — allow? "
                                     named))
          (error "Declined by the user: the code calls %s" named))
      (message "⚠ conjured code calls %s" named))))

(defun genie-live-eval (code)
  "Evaluate every form in CODE; return the forms and the last value.
The answer is (FORMS . VALUE).  Quitting is an error like any other
here, so that code a person interrupted is reported rather than lost."
  (let (forms value)
    (with-temp-buffer
      (insert code)
      (goto-char (point-min))
      (condition-case nil
          (while t (push (read (current-buffer)) forms))
        (end-of-file nil)))
    (setq forms (nreverse forms))
    (condition-case nil
        ;; A timer runs with quitting held off; here it must not be.
        (let ((inhibit-quit nil))
          (dolist (form forms)
            (setq value (eval form t))))
      (quit (error "Interrupted with C-g")))
    (cons forms value)))

(defvar genie-live--waiting nil
  "What is waiting for Emacs to be free, oldest first.")

(defvar genie-live--timer nil
  "The timer that will look again, while anything is waiting.")

(defun genie-live--busy-p ()
  "Return non-nil while a person is in the middle of something."
  (or (active-minibuffer-window) executing-kbd-macro))

(defun genie-live--drain ()
  "Run what is waiting, in the order it came, for as long as Emacs is free."
  (setq genie-live--timer nil)
  (while (and genie-live--waiting (not (genie-live--busy-p)))
    ;; A timer runs with quitting held off.  Nothing run from here may be
    ;; something a person cannot stop.
    (condition-case err
        (let ((inhibit-quit nil))
          (funcall (pop genie-live--waiting)))
      (quit (message "🧞 interrupted"))
      (error (message "🧞 %s" (error-message-string err)))))
  (when genie-live--waiting
    (setq genie-live--timer (run-at-time 0.5 nil #'genie-live--drain))))

(defun genie-live-when-free (function)
  "Call FUNCTION from the event loop, once no minibuffer is in use.
Never from the caller's own stack: what asks for code to be run is a
process filter, where it would hold up the whole editor and could not
be interrupted.  What is asked for first runs first, and a person can
interrupt it like any command."
  (setq genie-live--waiting (append genie-live--waiting (list function)))
  (unless genie-live--timer
    (setq genie-live--timer (run-at-time 0 nil #'genie-live--drain))))

;;;; Where it was asked for

(defvar genie-live--place nil
  "Where the last wish was made, as `genie-live-place' returned it.")

(defun genie-live-place ()
  "Return where the person is: the buffer, the point, and the region if active."
  (list :buffer (current-buffer)
        :point (point-marker)
        :region (when (use-region-p)
                  (cons (copy-marker (region-beginning))
                        (copy-marker (region-end))))))

(defun genie-live-remember-place ()
  "Note where the person is, for code they are about to ask for.
A chat is where one asks, not what one asks about, so it is not noted."
  (unless (or (minibufferp) (derived-mode-p 'genie-chat-mode))
    (setq genie-live--place (genie-live-place))))

(defun genie-live-at (place function)
  "Call FUNCTION in the buffer of PLACE, at its point, its region active.
Signal when that buffer is gone."
  (let ((buffer (plist-get place :buffer))
        (region (plist-get place :region)))
    (unless (buffer-live-p buffer)
      (error "The buffer it was asked in is gone"))
    (with-current-buffer buffer
      (if region
          (progn (goto-char (cdr region))
                 (push-mark (car region) t t))
        (goto-char (plist-get place :point)))
      (funcall function))))

;;;; The journal of what was done to buffers

(defvar genie--journal nil
  "Stack of genie-made changes, newest first, popped by `genie-undo'.
An entry is (wish . COMMIT-SUBJECT) for an applied change to the config,
or (cast BUFFER PRE POST NAME) for code that edited BUFFER, where PRE
and POST are its `buffer-undo-list' before and after.")

(defun genie-live-call (name function)
  "Call FUNCTION, journaling as NAME what it does to the current buffer."
  (let ((buf (current-buffer)) pre)
    (undo-boundary)
    (setq pre buffer-undo-list)
    (unwind-protect (funcall function)
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

(defun genie-live-undo (entry)
  "Undo the buffer effect recorded in the journal's cast ENTRY.
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

(provide 'genie-live)
;;; genie-live.el ends here
