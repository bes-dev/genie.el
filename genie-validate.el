;;; genie-validate.el --- Whether a change to the configuration may be applied -*- lexical-binding: t; -*-

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

;; Two questions are put to a change before it is applied, in this order.
;;
;; Can it be taken back?  A wish file may define what it likes, but what
;; it changes it must change through the effects of genie-wish, inside a
;; `genie-wish' form.  `genie-validate-reversible' reads the file for what
;; does not: anything at the top level that is not a definition, a
;; definition over a function that already exists, and inside a wish any
;; `setq', `add-hook', `define-key' and their kin that leave no way back.  It reads code, so it is a strong hint rather than
;; a proof — but what it names is always worth naming.
;;
;; Does the configuration still start?  `genie-validate-starts' loads
;; init.el in another Emacs, made as much like this one as a batch Emacs
;; can be: the same `user-emacs-directory', the same early-init.el, the
;; packages activated if they are here.  Another process, so that
;; installing a package or a loop that never ends costs this one nothing.
;; With everything loaded — and the libraries the wish names — that Emacs
;; also compiles the wish files, for the one thing loading does not show:
;; a function called that does not exist.  A model writes those in
;; good faith, and they would only be found on the day the code runs.
;;
;; `genie-validate-heavy' answers a third question nobody is refused
;; over: what in the change could make Emacs's one thread wait.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'genie-wish)
(require 'genie-live)

(defcustom genie-validate 'batch
  "How a change is checked to still start: `batch', `parens', or nil.
`batch' loads init.el in another Emacs; `parens' only checks that the
changed files balance; nil checks nothing."
  :type '(choice (const batch) (const parens) (const nil))
  :group 'genie)

(defcustom genie-validate-timeout 120
  "Seconds before the batch validation subprocess is killed.
A wish that adds packages makes the validation install them, which can
be slow on the first run — raise this when that bites."
  :type 'integer :group 'genie)

;;;; Can it be taken back?

(defconst genie-validate--irreversible
  '((global-set-key . genie-key) (local-set-key . genie-key)
    (global-unset-key . genie-key) (define-key . genie-key)
    (keymap-set . genie-key) (keymap-global-set . genie-key)
    (keymap-unset . genie-key) (bind-key . genie-key)
    (add-hook . genie-hook) (remove-hook . genie-effect)
    (advice-add . genie-advice) (advice-remove . genie-effect)
    (set . genie-set) (set-default . genie-set)
    (customize-set-variable . genie-set) (custom-set-variables . genie-set)
    (add-to-list . genie-add) (push . genie-add) (setenv . genie-effect)
    (put . genie-effect) (fset . genie-effect) (defalias . genie-effect)
    (load . genie-effect) (load-theme . genie-effect)
    (set-face-attribute . genie-effect) (custom-set-faces . genie-effect)
    (run-at-time . genie-timer) (run-with-timer . genie-timer)
    (run-with-idle-timer . genie-timer))
  "Ways to change Emacs that leave no way back, and the effect to use instead.")

(defconst genie-validate--setters '(setq setq-default setq-local setopt setf)
  "Forms that give places values, pair by pair.")

(defconst genie-validate--binders
  '(let let* dolist dotimes when-let when-let* if-let if-let* and-let*)
  "Forms whose first argument names variables their body may freely set.")

(defconst genie-validate--inert-keywords
  '(:ensure :straight :elpaca :defer :demand :commands :vc :pin :load-path
    :after :if :when :unless :requires :no-require :autoload :functions
    :defines :disabled)
  "What a `use-package' form in a wish file may say: where a package is from.")

(defun genie-validate--bound (form)
  "Return the variables local to the body of FORM, one of the binders."
  (let ((spec (cadr form)))
    (if (memq (car form) '(dolist dotimes))
        (list (car-safe spec))
      (delq nil (mapcar (lambda (binding)
                          (cond ((symbolp binding) binding)
                                ((cdr-safe binding) (car binding))))
                        (and (listp spec) spec))))))

(defun genie-validate--in-wish (form local statement)
  "Return what FORM, inside a wish, does that could not be taken back.
LOCAL are the variables bound around it, which it may change as it
likes.  STATEMENT is non-nil when FORM stands on its own in the wish's
body, rather than being an argument to something."
  (pcase form
    ;; Code that is only written here, to be run by something else: a
    ;; function is its own business, and an effect's arguments are data.
    (`(,(or 'quote 'function 'defun 'cl-defun 'genie-effect 'genie-timer
            'genie-set 'genie-key 'genie-hook 'genie-advice 'genie-add
            'genie-enable 'genie-disable)
       . ,_)
     nil)
    ;; A function written where it is called — for `mapc', say — runs here.
    (`(lambda ,args . ,body)
     (cl-loop for inner in body when (consp inner)
              append (genie-validate--in-wish
                      inner (append (and (listp args) args) local) nil)))
    (`(,(and head (guard (memq head genie-validate--setters))) . ,pairs)
     (cl-loop for (place value) on pairs by #'cddr
              unless (memq place local)
              collect (format "`%s' of `%s' cannot be taken back — use \
`genie-set'" head place)
              append (and (consp value)
                          (genie-validate--in-wish value local nil))))
    ;; What is done to something made here is nobody else's to take back.
    (`(,(or 'push 'define-key 'keymap-set 'add-to-list 'put) . ,args)
     (unless (or (memq (car args) local) (memq (cadr args) local))
       (list (format "`%s' cannot be taken back — use `%s'" (car form)
                     (cdr (assq (car form) genie-validate--irreversible))))))
    (`(,(or 'funcall 'apply) (function ,called) . ,args)
     (genie-validate--in-wish (cons called args) local nil))
    (`(,(and head (guard (assq head genie-validate--irreversible))) . ,_)
     (list (format "`%s' cannot be taken back — use `%s'"
                   head (cdr (assq head genie-validate--irreversible)))))
    (`(,(and head (pred symbolp)
             (guard (string-suffix-p "-mode" (symbol-name head))))
       . ,args)
     ;; Switching a mode, as against asking whether it is on.
     (when (or (numberp (car args)) (and statement (null (cdr args))))
       (list (format "`(%s …)' cannot be taken back — use `genie-enable' or \
`genie-disable'" head))))
    (`(,head . ,args)
     (let ((local (if (memq head genie-validate--binders)
                      (append (genie-validate--bound form) local)
                    local))
           ;; The body of a form that only groups or guards stands as the
           ;; form does; what comes before the body — a name, a condition,
           ;; the bindings — is an argument like any other.
           (before (and statement
                        (cdr (assq head '((genie-wish . 2) (progn . 0)
                                          (genie-after . 1) (when . 1)
                                          (unless . 1) (let . 1) (let* . 1)
                                          (dolist . 1) (dotimes . 1)))))))
       (cl-loop for arg in (and (proper-list-p args) args)
                for position from 0
                when (consp arg)
                append (genie-validate--in-wish
                        arg local (and before (>= position before))))))))

(defun genie-validate--defines-p (head)
  "Return non-nil when a form whose first symbol is HEAD is a definition.
By its name: `defun', `cl-defmethod', `define-minor-mode',
`defvar-keymap', `easy-menu-define' and `transient-define-prefix' all
say what they are."
  (and (symbolp head)
       (or (memq head '(require autoload declare-function provide put))
           (and (not (assq head genie-validate--irreversible)) ; `define-key'
                (string-match-p "\\`\\(?:cl-\\)?def\\|define"
                                (symbol-name head))))))

(defun genie-validate--at-top (form &optional file)
  "Return what FORM, at the top level of the wish FILE, should not be doing."
  (pcase form
    (`(use-package ,name . ,rest)
     (when-let* ((acting (cl-set-difference (cl-remove-if-not #'keywordp rest)
                                            genie-validate--inert-keywords)))
       (list (format "`use-package %s' with %s: in a wish file it only installs \
— make the changes with effects" name (mapconcat #'symbol-name acting " ")))))
    (`(genie-wish . ,_) (genie-validate--in-wish form nil t))
    (`(,(or 'progn 'eval-when-compile 'eval-and-compile) . ,body)
     (mapcan (lambda (inner) (genie-validate--at-top inner file))
             (cl-remove-if-not #'consp body)))
    ;; Defining over what is already there is a change like any other,
    ;; and one that nothing remembers the way back from.
    (`(,(or 'defun 'defalias 'defmacro 'cl-defun 'fset)
       ,(or `(quote ,name) name) . ,_)
     (when (and (symbolp name) (fboundp name)
                (not (equal (symbol-file name 'defun) file)))
       (list (format "`%s' is already a function here: redefining it cannot \
be taken back — give yours another name, or use `genie-advice'" name))))
    (`(,(and head (guard (genie-validate--defines-p head))) . ,_) nil)
    (`(,head . ,_)
     (list (format "`%s' at the top level runs whenever the file loads and \
cannot be taken back — put it in the `genie-wish', through an effect"
                   head)))))

(defun genie-validate--forms (file)
  "Return the forms in FILE, as far as it can be read."
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms)
      (condition-case nil
          (while t (push (read (current-buffer)) forms))
        (error nil))
      (nreverse forms))))

(defun genie-validate-reversible (file)
  "Return why the wishes in FILE could not be taken back, a list of strings."
  (mapcan (lambda (form) (genie-validate--at-top form (file-truename file)))
          (cl-remove-if-not #'consp (genie-validate--forms file))))

;;;; What could make Emacs wait?

(defconst genie-validate--heavy
  '(post-command-hook pre-command-hook after-change-functions
    before-change-functions window-scroll-functions
    window-configuration-change-hook sleep-for sit-for
    url-retrieve-synchronously accept-process-output)
  "What makes the one thread Emacs has wait, or work on every keystroke.")

(defun genie-validate-heavy (files)
  "Return whatever in the Elisp of FILES could slow every keystroke."
  (cl-remove-duplicates
   (mapcan (lambda (file)
             (when (and (string-suffix-p ".el" file) (file-exists-p file))
               (genie--mentions (with-temp-buffer
                                  (insert-file-contents file)
                                  (buffer-string))
                                genie-validate--heavy)))
           files)))

;;;; Does it still start?

(defun genie-validate--parens (files)
  "Check each of FILES for balanced brackets; return (OK . DETAIL)."
  (catch 'bad
    (dolist (file files '(t . "parens OK"))
      (when (and (string-suffix-p ".el" file) (file-exists-p file))
        (with-temp-buffer
          (insert-file-contents file)
          (delay-mode-hooks (emacs-lisp-mode))
          (condition-case err (check-parens)
            (error (throw 'bad
                          (cons nil (format "%s:%d: %s"
                                            (file-name-nondirectory file)
                                            (line-number-at-pos)
                                            (error-message-string err)))))))))))

(defun genie-validate--like-here ()
  "Return a form to make a batch Emacs resemble this one before init.el.
A batch Emacs reads no init file, so nothing has told it where the
configuration lives, run early-init.el, or put the installed packages
on the load path — and a configuration is entitled to all three."
  (let ((early (locate-user-emacs-file "early-init.el")))
    `(progn
       (setq user-emacs-directory ,user-emacs-directory)
       ,@(when (file-readable-p early) `((load ,early nil t)))
       ;; Emacs activates packages at startup without calling them
       ;; initialized, so either is the sign that this session has them.
       ,@(when (or (bound-and-true-p package--initialized)
                   (bound-and-true-p package--activated))
           `((setq package-user-dir ,(bound-and-true-p package-user-dir))
             (package-activate-all))))))

(defun genie-validate--features (files)
  "Return the libraries the wishes in FILES say they use.
Named in a `require', wherever it stands, or waited for with
`genie-after': code that calls into a library has said so one way or
the other, and what it calls is only missing if it is missing then."
  (let (features)
    (cl-labels ((walk (form)
                  (pcase form
                    (`(,(or 'require 'genie-after) (quote ,feature) . ,rest)
                     (cl-pushnew feature features)
                     (mapc #'walk rest))
                    ((pred consp)
                     (when (proper-list-p form) (mapc #'walk form))))))
      (dolist (file files) (mapc #'walk (genie-validate--forms file))))
    features))

(defun genie-validate--compiled (files)
  "Return a form that compiles FILES for what they call that does not exist.
The libraries they name are loaded first.  What the compiler has to say
of each file is printed on a line of its own, marked, and nothing else
of the compiling is kept."
  `(progn
     (require 'bytecomp)
     (dolist (feature ',(genie-validate--features files))
       (require feature nil t))
     (dolist (file ',files)
       (let* ((output (make-temp-file "genie-validate" nil ".elc"))
              (byte-compile-dest-file-function (lambda (_) output))
              (byte-compile-warnings '(unresolved callargs))
              (byte-compile-log-warning-function
               (lambda (said &rest _)
                 (message "genie-undefined: %s: %s"
                          (file-name-nondirectory file) said))))
         (unwind-protect (byte-compile-file file)
           (delete-file output))))))

(defun genie-validate--refusal (output)
  "Return why the change that printed OUTPUT in the other Emacs is refused.
That is a wish switched off for signalling, or what a wish file calls
that does not exist; nil when there is neither."
  (let (said (start 0))
    (when (string-match "^Warning (genie): \\(.*\\)" output)
      (push (match-string 1 output) said))
    (while (string-match "^genie-undefined: \\(.*\\)" output start)
      (setq start (match-end 0))
      (cl-pushnew (match-string 1 output) said :test #'equal))
    (and said (string-join (nreverse said) "\n  "))))

(defun genie-validate-starts (init files callback &optional wishes)
  "Check the configuration for starting; CALLBACK gets (OK . DETAIL).
INIT is its init file and FILES are the ones that changed; WISHES are
the wish files among them, which are also compiled to find what they
name that does not exist.  How it is checked is `genie-validate'.

With `batch', a wish that was switched off for signalling counts as a
failure, since that is what would greet
the next start; a run over `genie-validate-timeout' seconds is killed
and reported as a timeout rather than as a failure of the change.
Return the process doing the checking, or nil when it is already done."
  (pcase genie-validate
    ('parens (funcall callback (genie-validate--parens files)) nil)
    ('batch
     (let* ((buf (generate-new-buffer " *genie-validate*"))
            (proc
             (make-process
              :name "genie-validate" :buffer buf :noquery t
              :command
              (list (expand-file-name invocation-name invocation-directory)
                    "--batch"
                    ;; Wherever this genie was loaded from, so a config that
                    ;; relies on a package manager to find it finds it here.
                    "-L" (file-name-directory (locate-library "genie-wish"))
                    "--eval" (prin1-to-string (genie-validate--like-here))
                    "-l" init
                    "--eval" (prin1-to-string
                              (genie-validate--compiled wishes)))
              :sentinel
              (lambda (proc _event)
                (unless (process-live-p proc)
                  (let* ((out (with-current-buffer buf
                                (string-trim (buffer-string))))
                         (refused (genie-validate--refusal out))
                         (ok (and (zerop (process-exit-status proc))
                                  (not refused))))
                    (kill-buffer buf)
                    (funcall
                     callback
                     (cons ok
                           (cond
                            (ok "the config starts cleanly")
                            ((process-get proc 'genie--timeout)
                             (format "validation timed out after %ss — raise \
`genie-validate-timeout'" genie-validate-timeout))
                            (t (truncate-string-to-width
                                (or refused
                                    (car (last (split-string out "\n" t)))
                                    "batch load failed")
                                600)))))))))))
       (run-at-time genie-validate-timeout nil
                    (lambda ()
                      (when (process-live-p proc)
                        (process-put proc 'genie--timeout t)
                        (kill-process proc))))
       proc))
    (_ (funcall callback '(t . "validation skipped")) nil)))

(provide 'genie-validate)
;;; genie-validate.el ends here
