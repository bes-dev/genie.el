;;; genie-wish.el --- Wishes that can be taken back -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.15.0
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

(defcustom genie-wish-directory
  (expand-file-name "wishes" user-emacs-directory)
  "Where wishes are kept, one file each."
  :type 'directory :group 'genie)

(cl-defstruct (genie-wish--record (:constructor genie-wish--make) (:copier nil))
  "One wish: what was asked, how it is done, and the way back."
  name doc file body
  ;; `on', `off', or `broken' with `error' saying why.
  (state 'off) error
  ;; Ways back, newest first, and what each undoes, for a person to read.
  undo effects
  ;; Counts switchings-on, so a part deferred by an earlier one stays out.
  (generation 0))

(defvar genie-wish--all nil
  "Every wish defined so far, as (NAME . RECORD), in the order defined.")

(defvar genie-wish--current nil
  "The wish being switched on, while its body runs.")

(defun genie-wish--off-file ()
  "Return the file listing the wishes that are kept switched off."
  (expand-file-name ".off" genie-wish-directory))

(defun genie-wish-disabled ()
  "Return the names of the wishes that are kept switched off."
  (let ((file (genie-wish--off-file)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (ignore-errors (read (current-buffer)))))))

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
        (new (genie-wish--make :name name :doc doc :body body
                               :file (or load-file-name buffer-file-name))))
    (if (not old)
        (setq genie-wish--all (append genie-wish--all (list (cons name new))))
      (genie-wish--revert old)
      (setf (genie-wish--record-generation new)
            (genie-wish--record-generation old)
            (cdr (assq name genie-wish--all)) new))
    (unless (memq name (genie-wish-disabled))
      (genie-wish-on name))
    name))

(defun genie-wish--run (wish body)
  "Run BODY as part of WISH.
Return non-nil unless it signals, which leaves WISH off and marked broken."
  (let ((genie-wish--current wish))
    (condition-case err
        (progn (funcall body) t)
      (error
       (genie-wish--revert wish)
       (setf (genie-wish--record-state wish) 'broken
             (genie-wish--record-error wish) (error-message-string err))
       (display-warning
        'genie (format "The wish `%s' was switched off: %s"
                       (genie-wish--record-name wish)
                       (error-message-string err)))
       nil))))

(defun genie-wish-on (name)
  "Switch the wish NAME on for this session."
  (let ((wish (genie-wish--get name)))
    (unless (eq (genie-wish--record-state wish) 'on)
      (cl-incf (genie-wish--record-generation wish))
      (setf (genie-wish--record-error wish) nil)
      (when (genie-wish--run wish (genie-wish--record-body wish))
        (setf (genie-wish--record-state wish) 'on)))))

(defun genie-wish--revert (wish)
  "Undo everything WISH did, newest first."
  (dolist (undo (genie-wish--record-undo wish))
    (ignore-errors (funcall undo)))
  (setf (genie-wish--record-undo wish) nil
        (genie-wish--record-effects wish) nil))

(defun genie-wish-off (name)
  "Switch the wish NAME off for this session, undoing what it did."
  (let ((wish (genie-wish--get name)))
    (genie-wish--revert wish)
    (setf (genie-wish--record-state wish) 'off)))

(defun genie-wish-keep (name on)
  "Switch the wish NAME on when ON is non-nil, off otherwise, and keep it so.
The choice is written beside the wishes and holds in later sessions."
  (let ((disabled (remq name (genie-wish-disabled))))
    (unless on (push name disabled))
    (make-directory genie-wish-directory t)
    (with-temp-file (genie-wish--off-file)
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
  (let ((file (expand-file-name file)))
    (setq genie-wish--all
          (cl-remove-if
           (lambda (cell)
             (when (equal (genie-wish--record-file (cdr cell)) file)
               (genie-wish--revert (cdr cell))
               t))
           genie-wish--all))))

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

(defun genie-effect (what do undo)
  "Make a change by calling DO, to be taken back by calling UNDO.
WHAT is the change in a few words, for a person to read.  This is what every
other effect is made of, and the one to use for a change none of them
covers.  It can only be called while a wish is being switched on."
  (unless genie-wish--current
    (error "An effect belongs in a `genie-wish': %s" what))
  (funcall do)
  (push undo (genie-wish--record-undo genie-wish--current))
  (push what (genie-wish--record-effects genie-wish--current)))

(defun genie-wish--assign (symbol value)
  "Give the option SYMBOL the VALUE, the way Customize would."
  (funcall (or (get symbol 'custom-set) #'set-default) symbol value))

(defun genie-set (symbol value)
  "Set the option or variable SYMBOL to VALUE.
Taken back, it has the value it had; one that had none gets its
standard value, or none again."
  (let ((old (and (default-boundp symbol) (list (default-value symbol)))))
    (genie-effect
     (format "set %s to %S" symbol value)
     (lambda () (genie-wish--assign symbol value))
     (lambda ()
       (cond (old (genie-wish--assign symbol (car old)))
             ((get symbol 'standard-value)
              (genie-wish--assign
               symbol (eval (car (get symbol 'standard-value)) t)))
             (t (makunbound symbol)))))))

(defun genie-key (keymap key command)
  "Bind KEY, in the syntax of `kbd', to COMMAND in KEYMAP.
Taken back, KEY is bound to what it was bound to in KEYMAP."
  (let* ((keys (kbd key))
         (old (lookup-key keymap keys)))
    (genie-effect
     (format "key %s runs %s" key (if (symbolp command) command "a command"))
     (lambda () (define-key keymap keys command))
     (lambda () (define-key keymap keys (and (not (numberp old)) old))))))

(defun genie-hook (hook function &optional depth)
  "Add FUNCTION to HOOK, at DEPTH as for `add-hook'.
Taken back, it is removed, unless it was there before."
  (let ((was (and (default-boundp hook) (memq function (default-value hook)))))
    (genie-effect
     (format "%s on %s" function hook)
     (lambda () (add-hook hook function depth))
     (lambda () (unless was (remove-hook hook function))))))

(defun genie-advice (symbol how function)
  "Advise SYMBOL with FUNCTION, HOW as for `advice-add'.
Taken back, the advice is removed, unless it was there before."
  (let ((was (advice-member-p function symbol)))
    (genie-effect
     (format "%s advised %s by %s" symbol how function)
     (lambda () (advice-add symbol how function))
     (lambda () (unless was (advice-remove symbol function))))))

(defun genie-wish--switch (mode on)
  "Switch the minor mode MODE on when ON is non-nil, off otherwise."
  (let ((was (and (boundp mode) (symbol-value mode))))
    (genie-effect
     (format "%s %s" mode (if on "on" "off"))
     (lambda () (funcall mode (if on 1 -1)))
     (lambda () (funcall mode (if was 1 -1))))))

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
         (set list-variable (delete element (symbol-value list-variable))))))))

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
       ;; Loaded later: only if the wish was not taken back meanwhile.
       ((and (eq (genie-wish--record-state wish) 'on)
             (= generation (genie-wish--record-generation wish)))
        (genie-wish--run wish body))))))

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
