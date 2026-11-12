;;; genie-wish.el --- Wishes that can be taken back -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.18.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: convenience, lisp
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

;; A wish is a piece of configuration that knows how to undo itself.
;;
;; Emacs lets any code change anything, and remembers none of it: a key
;; bound, a hook added, an option set or a function advised stays that
;; way until Emacs restarts, whatever happens to the code that did it.
;; A configuration that an agent rewrites while it runs cannot live with
;; that — taking a change back has to take it back now.
;;
;; So a wish makes its changes through a handful of functions that each
;; remember the way back:
;;
;;   (defun my-duplicate-line () ...)
;;
;;   (genie-wish duplicate-line
;;     "Duplicate the current line with C-c d."
;;     (genie-key global-map "C-c d" #'my-duplicate-line)
;;     (genie-set 'scroll-margin 3)
;;     (genie-hook 'prog-mode-hook #'display-line-numbers-mode)
;;     (genie-enable 'global-auto-revert-mode)
;;     (genie-after 'org
;;       (genie-key org-mode-map "C-c d" #'my-duplicate-line)))
;;
;; Switching the wish off (`genie-wish-off', or \\`t' in `genie-lamp') puts
;; every one of those back as it was; switching it on runs the body
;; again.  A wish whose body signals is switched off and reported: it
;; never takes the rest of the configuration down with it.
;;
;; What a wish puts back is what was there when it was switched on.  So
;; when two wishes change the same thing — the same key, the same option
;; — they are taken back in reverse order, whichever is switched off: the
;; later one first, and switched on again once the earlier is gone.  The
;; body of a wish may therefore run more than once in a session, and
;; should do the same thing each time it does.
;;
;; The effects: `genie-set', `genie-key', `genie-hook', `genie-advice',
;; `genie-enable', `genie-disable', `genie-add', `genie-timer', and
;; `genie-effect' for anything else that has a way back.  `genie-after' defers part of a
;; wish until a library is loaded.
;;
;; Wishes live one to a file in `genie-wish-directory', and one line in
;; init.el loads them all:
;;
;;   (require 'genie-wish)
;;   (genie-wish-load)
;;
;; This file needs nothing else of genie: a configuration made of wishes
;; starts without an agent anywhere near it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defcustom genie-wish-directory
  (expand-file-name "wishes" user-emacs-directory)
  "Where wishes are kept, one file each."
  :type 'directory :group 'genie)

(cl-defstruct (genie-wish--record (:constructor genie-wish--make) (:copier nil))
  "One wish: what was asked, how it is done, and the way back."
  name doc file body
  ;; `on', `off', or `broken' with `error' saying why.
  (state 'off) error
  ;; Ways back, newest first; what each undoes, for a person to read; and
  ;; what each one changed, to tell when two wishes change the same thing.
  undo effects targets
  ;; Counts every switching on and off, so that a part deferred by one
  ;; switching-on does not run for another, or after the wish is gone.
  (generation 0))

(defvar genie-wish--all nil
  "Every wish defined so far, as (NAME . RECORD), in the order defined.")

(defvar genie-wish--on nil
  "The wishes that are switched on, in the order they were switched on.
What a wish puts back when it is switched off is what was there when it
was switched on, so wishes are taken back in the reverse of this order.")

(defvar genie-wish--current nil
  "The wish being switched on, while its body runs.")

(defun genie-wish-off-file ()
  "Return the file listing the wishes that are kept switched off."
  (expand-file-name ".off" genie-wish-directory))

(defun genie-wish-disabled ()
  "Return the names of the wishes that are kept switched off.
A file that does not hold a list of names — one a merge left its marks
in — keeps nothing off, rather than everything."
  (let ((file (genie-wish-off-file)))
    (when (file-readable-p file)
      (let ((kept (with-temp-buffer
                    (insert-file-contents file)
                    (ignore-errors (read (current-buffer))))))
        (and (listp kept) (cl-every #'symbolp kept) kept)))))

(defun genie-wish--get (name)
  "Return the record of the wish called NAME, or signal."
  (or (cdr (assq name genie-wish--all))
      (user-error "No wish called %s" name)))

;;;; Defining, and switching on and off

(defmacro genie-wish (name doc &rest body)
  "Define the wish NAME, with DOC for what was asked and BODY to make it so.
BODY changes Emacs only through the effects of this library —
`genie-set', `genie-key', `genie-hook', `genie-advice', `genie-enable',
`genie-disable', `genie-add', `genie-timer', `genie-effect' — so that
switching the wish off can undo each one.  The wish is switched on at
once unless it is listed as kept off."
  (declare (indent 1) (doc-string 2))
  `(genie-wish--define ',name ,doc (lambda () ,@body)))

(defun genie-wish--define (name doc body)
  "Record the wish NAME with DOC and BODY, replacing an earlier definition."
  (let ((old (cdr (assq name genie-wish--all)))
        (new (genie-wish--make
              :name name :doc doc :body body
              :file (when-let* ((file (or load-file-name buffer-file-name)))
                      (file-truename file)))))
    (genie-wish--without
     old
     (lambda ()
       (if old
           (setf (cdr (assq name genie-wish--all)) new)
         (setq genie-wish--all (append genie-wish--all (list (cons name new)))))
       (unless (memq name (genie-wish-disabled))
         (genie-wish--switch-on new))))
    name))

(defun genie-wish--revert (wish)
  "Undo everything WISH did, newest first, and leave it off.
Anything it deferred stays out from here on."
  (dolist (undo (genie-wish--record-undo wish))
    (ignore-errors (funcall undo)))
  (cl-incf (genie-wish--record-generation wish))
  (setq genie-wish--on (delq wish genie-wish--on))
  (setf (genie-wish--record-undo wish) nil
        (genie-wish--record-effects wish) nil
        (genie-wish--record-targets wish) nil
        (genie-wish--record-state wish) 'off))

(defun genie-wish--entangled (wish)
  "Return the wishes switched on after WISH that changed what it changed.
In the order they were switched on, and with those that changed what
they changed in turn: each of them took as \"what was there\" something
WISH, or one of the others, had put there."
  (let ((targets (genie-wish--record-targets wish))
        entangled)
    (dolist (later (cdr (memq wish genie-wish--on)) (nreverse entangled))
      (when (cl-intersection targets (genie-wish--record-targets later)
                             :test #'equal)
        (push later entangled)
        (setq targets (append (genie-wish--record-targets later) targets))))))

(defun genie-wish--without (wish function)
  "Take WISH back, call FUNCTION, and leave everything else as it was.
Wishes that changed the same things after WISH are taken back before it
and switched on again after FUNCTION: only so does each put back what
was really there.  WISH may be nil, when there is nothing to take back."
  (let ((entangled (and wish (genie-wish--entangled wish))))
    (mapc #'genie-wish--revert (reverse entangled))
    (when wish (genie-wish--revert wish))
    (funcall function)
    (mapc #'genie-wish--switch-on entangled)))

(defun genie-wish--run (wish body)
  "Run BODY as part of WISH.
Return non-nil unless it signals, which leaves WISH off and marked broken."
  (let ((genie-wish--current wish))
    (condition-case err
        (progn (funcall body) t)
      (error
       (genie-wish--without wish #'ignore)
       (setf (genie-wish--record-state wish) 'broken
             (genie-wish--record-error wish) (error-message-string err))
       (display-warning
        'genie (format "The wish `%s' was switched off: %s"
                       (genie-wish--record-name wish)
                       (error-message-string err)))
       nil))))

(defun genie-wish--switch-on (wish)
  "Switch WISH on, unless it is."
  (unless (eq (genie-wish--record-state wish) 'on)
    (cl-incf (genie-wish--record-generation wish))
    (setf (genie-wish--record-error wish) nil)
    (when (genie-wish--run wish (genie-wish--record-body wish))
      (setq genie-wish--on (append genie-wish--on (list wish)))
      (setf (genie-wish--record-state wish) 'on))))

(defun genie-wish-on (name)
  "Switch the wish NAME on for this session."
  (genie-wish--switch-on (genie-wish--get name)))

(defun genie-wish-off (name)
  "Switch the wish NAME off for this session, undoing what it did."
  (genie-wish--without (genie-wish--get name) #'ignore))

(defun genie-wish-keep (name on)
  "Switch the wish NAME on when ON is non-nil, off otherwise, and keep it so.
The choice is written beside the wishes and holds in later sessions."
  (let ((disabled (remq name (genie-wish-disabled))))
    (unless on (push name disabled))
    (make-directory genie-wish-directory t)
    (with-temp-file (genie-wish-off-file)
      (prin1 (sort disabled #'string<) (current-buffer))
      (insert "\n")))
  (if on (genie-wish-on name) (genie-wish-off name)))

(defun genie-wish-sync ()
  "Switch every wish on or off, to match the list of those kept off."
  (let ((disabled (genie-wish-disabled)))
    (dolist (cell genie-wish--all)
      (if (memq (car cell) disabled)
          (genie-wish-off (car cell))
        (genie-wish-on (car cell))))))

(defun genie-wish-forget-file (file)
  "Switch off and forget every wish that FILE defined."
  (let ((file (file-truename file)))
    (dolist (cell (copy-sequence genie-wish--all))
      (when (equal (genie-wish--record-file (cdr cell)) file)
        (genie-wish--without (cdr cell) #'ignore)
        (setq genie-wish--all (delq cell genie-wish--all))))))

(defun genie-wish-load-file (file)
  "Load the wishes in FILE, replacing the ones it defined before.
A file that does not load is reported and leaves the rest alone."
  (genie-wish-forget-file file)
  (condition-case err
      (load (expand-file-name file) nil t t)
    (error
     (display-warning
      'genie (format "%s did not load: %s"
                     (file-name-nondirectory file) (error-message-string err))))))

;;;###autoload
(defun genie-wish-load ()
  "Load every wish in `genie-wish-directory', in name order.
Call this from init.el.  Each file is on its own: one that does not
load, or a wish that cannot be switched on, is reported as a warning
and the rest of the configuration starts regardless."
  (when (file-directory-p genie-wish-directory)
    (mapc #'genie-wish-load-file
          (directory-files genie-wish-directory t "\\`[^.].*\\.el\\'"))))

;;;; Effects: each change, with the way back

(defun genie-effect (what do undo &optional target)
  "Make a change by calling DO, to be taken back by calling UNDO.
WHAT is the change in a few words, for a person to read.  This is what every
other effect is made of, and the one to use for a change none of them
covers.  TARGET names the thing changed, when another wish could change
it too: any value, compared with `equal'.  Wishes that share a target
are taken back in the reverse of the order they were switched on in,
whichever of them is switched off.

It can only be called while a wish is being switched on."
  (let ((wish (or genie-wish--current
                  (error "An effect belongs in a `genie-wish': %s" what))))
    ;; The way back is noted first: a change that signals halfway is still
    ;; taken back, as far as it got.
    (push undo (genie-wish--record-undo wish))
    (push what (genie-wish--record-effects wish))
    (when target (push target (genie-wish--record-targets wish)))
    (funcall do)))

(defun genie-wish--assign (symbol value)
  "Give the option SYMBOL the VALUE, the way Customize would."
  (funcall (or (get symbol 'custom-set) #'set-default) symbol value))

(defun genie-set (symbol value)
  "Set the option or variable SYMBOL to VALUE.
Taken back, it has the value it had.  One that had none yet gets its
standard value if it is an option.  A plain variable a library has
defined in the meantime keeps VALUE, since what the library would have
given it is not known; one nothing defined is unbound again."
  (let ((old (and (default-boundp symbol) (list (default-value symbol)))))
    (genie-effect
     (format "set %s to %S" symbol value)
     (lambda () (genie-wish--assign symbol value))
     (lambda ()
       (cond (old (genie-wish--assign symbol (car old)))
             ((get symbol 'standard-value)
              (genie-wish--assign
               symbol (eval (car (get symbol 'standard-value)) t)))
             ((not (special-variable-p symbol)) (makunbound symbol))))
     (list 'variable symbol))))

(defun genie-key (keymap key command)
  "Bind KEY, in the syntax of `kbd', to COMMAND in KEYMAP.
Taken back, KEY is bound to what it was bound to in KEYMAP."
  (let* ((keys (kbd key))
         (old (lookup-key keymap keys)))
    (genie-effect
     (format "key %s runs %s" key (if (symbolp command) command "a command"))
     (lambda () (define-key keymap keys command))
     (lambda () (define-key keymap keys (and (not (numberp old)) old)))
     (list 'key keymap keys))))

(defun genie-wish--buffers-in (hook)
  "Return the buffers already in the mode whose hook HOOK is, if it is one."
  (let* ((name (symbol-name hook))
         (mode (and (string-suffix-p "-mode-hook" name)
                    (intern-soft (substring name 0 -5)))))
    (when (and mode (fboundp mode))
      (cl-remove-if-not
       (lambda (buffer)
         (and (not (string-prefix-p " " (buffer-name buffer)))
              (with-current-buffer buffer
                (or (derived-mode-p mode)
                    (and (boundp mode) (symbol-value mode))))))
       (buffer-list)))))

(defun genie-hook (hook function &optional depth)
  "Add FUNCTION to HOOK, at DEPTH as for `add-hook'.
A mode's hook only runs when a buffer enters the mode, so FUNCTION is
also called now in the buffers that are already in it: the wish holds
for what is open, not only for what is opened next.  Taken back, the
function is removed unless it was there before, and where it is a
minor mode it is switched off again in exactly the buffers this wish
switched it on in — those open then and those opened since, but not
one where it was on already, or where you switched it on yourself."
  (let* ((was (and (default-boundp hook) (memq function (default-value hook))))
         (depth (pcase depth ('nil 0) ('t 90) (_ depth)))
         (on-p (lambda () (and (symbolp function) (boundp function)
                               (symbol-value function))))
         reached
         ;; Runs just before FUNCTION wherever the hook runs, to note the
         ;; buffers in which this wish is what switches the mode on.
         (note (lambda ()
                 (unless (funcall on-p) (push (current-buffer) reached)))))
    (genie-effect
     (format "%s on %s" function hook)
     (lambda ()
       (add-hook hook function depth)
       (add-hook hook note (1- depth))
       (dolist (buffer (genie-wish--buffers-in hook))
         (with-current-buffer buffer
           (funcall note)
           (ignore-errors (funcall function)))))
     (lambda ()
       (remove-hook hook note)
       (unless was
         (remove-hook hook function)
         ;; Asked now rather than when the wish was switched on: a mode
         ;; that was only an autoload then is known to be one by now.
         (when (and (symbolp function) (memq function minor-mode-list))
           (dolist (buffer reached)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (funcall on-p)
                   (ignore-errors (funcall function -1)))))))))
     (list 'hook hook function))))

(defun genie-advice (symbol how function)
  "Advise SYMBOL with FUNCTION, HOW as for `advice-add'.
Taken back, the advice is removed, unless it was there before."
  (let ((was (advice-member-p function symbol)))
    (genie-effect
     (format "%s advised %s by %s" symbol how function)
     (lambda () (advice-add symbol how function))
     (lambda () (unless was (advice-remove symbol function)))
     (list 'advice symbol function))))

(defun genie-wish--switch (mode on)
  "Switch the minor mode MODE on when ON is non-nil, off otherwise."
  ;; Said in full: whoever wrote the wish reads this to put it right.
  (unless (fboundp mode)
    (error "No mode is called `%s'%s" mode
           (if (fboundp (intern-soft (format "%s-mode" mode)))
               (format " — did you mean `%s-mode'?" mode)
             "")))
  (let ((was (and (boundp mode) (symbol-value mode))))
    (genie-effect
     (format "%s %s" mode (if on "on" "off"))
     (lambda () (funcall mode (if on 1 -1)))
     (lambda () (funcall mode (if was 1 -1)))
     (list 'variable mode))))

(defun genie-enable (mode)
  "Switch the minor mode MODE on.  Taken back, the mode is as it was."
  (genie-wish--switch mode t))

(defun genie-disable (mode)
  "Switch the minor mode MODE off.  Taken back, the mode is as it was."
  (genie-wish--switch mode nil))

(defun genie-add (list-variable element &optional append)
  "Add ELEMENT to the list in LIST-VARIABLE, at the end when APPEND.
Taken back, it is removed, unless it was there before."
  (let ((was (and (boundp list-variable)
                  (member element (symbol-value list-variable)))))
    (genie-effect
     (format "%S in %s" element list-variable)
     (lambda () (add-to-list list-variable element append))
     (lambda ()
       (unless was
         (set list-variable (delete element (symbol-value list-variable)))))
     (list 'element list-variable element))))

(defun genie-timer (timer)
  "Keep TIMER, as `run-at-time' or `run-with-idle-timer' returned it.
Taken back, the timer is cancelled."
  (genie-effect "a timer" #'ignore (lambda () (cancel-timer timer)))
  timer)

(defmacro genie-after (feature &rest body)
  "Run BODY, more of the wish being switched on, once FEATURE is loaded.
For effects on what a library defines — its keymaps, its options'
setters — that must wait for it.  BODY is skipped if the wish has been
switched off by then."
  (declare (indent 1))
  `(genie-wish--after ,feature (lambda () ,@body)))

(defun genie-wish--after (feature body)
  "Run BODY as part of the wish being switched on once FEATURE is loaded."
  (let* ((wish (or genie-wish--current
                   (error "`genie-after' belongs in a `genie-wish'")))
         (generation (genie-wish--record-generation wish)))
    (with-eval-after-load feature
      (cond
       ;; Loaded already: this is simply the next part of the body.
       ((eq wish genie-wish--current) (funcall body))
       ;; Loaded later: only if this switching-on still stands.  What it
       ;; changes it changes now, after whatever was switched on since, so
       ;; from here on this wish is the latest one.
       ((and (eq (genie-wish--record-state wish) 'on)
             (= generation (genie-wish--record-generation wish)))
        (when (genie-wish--run wish body)
          (setq genie-wish--on
                (append (delq wish genie-wish--on) (list wish)))))))))

;;;; Asking about wishes

(defun genie-wish-list ()
  "Return every wish, as a plist, in the order they were defined.
The properties are `:name', `:doc', `:file', `:state' (`on', `off' or
`broken'), `:error' and `:effects', the changes it has in place now."
  (mapcar (lambda (cell)
            (let ((wish (cdr cell)))
              (list :name (car cell)
                    :doc (genie-wish--record-doc wish)
                    :file (genie-wish--record-file wish)
                    :state (genie-wish--record-state wish)
                    :error (genie-wish--record-error wish)
                    :effects (reverse (genie-wish--record-effects wish)))))
          genie-wish--all))

(provide 'genie-wish)
;;; genie-wish.el ends here
