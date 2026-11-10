;;; genie-lamp.el --- The wishes this Emacs was granted -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.15.0
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

;; `genie-lamp' lists the wishes this Emacs is made of, as `list-packages'
;; lists its packages: what was asked, whether it is on, and — one key
;; away — exactly what it changed.
;;
;;   RET  the wish's file          t  switch it off, or back on
;;   e    what it has changed      d  forget it for good
;;   w    make a new wish          g  read the list again
;;
;; Switching a wish off takes back every change it made, now, and keeps
;; it off in later sessions.  Like everything else genie does to the
;; configuration it is one commit, and `genie-undo' takes it back.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'genie-wish)
(require 'genie-pipeline)

(declare-function genie "genie" (wish))

(defvar genie-lamp-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'genie-lamp-visit)
    (define-key map "t" #'genie-lamp-toggle)
    (define-key map "e" #'genie-lamp-effects)
    (define-key map "d" #'genie-lamp-forget)
    (define-key map "w" #'genie)
    map)
  "Keymap for `genie-lamp-mode'.")

(define-derived-mode genie-lamp-mode tabulated-list-mode "genie-lamp"
  "The wishes this Emacs was granted.
\\<genie-lamp-mode-map>\\[genie-lamp-toggle] switches the wish at point off \
or back on, \\[genie-lamp-effects] shows what it changed,
\\[genie-lamp-visit] opens its file, \\[genie-lamp-forget] forgets it for \
good, \\[genie] makes a new one."
  (setq tabulated-list-format [("" 1 nil) ("Wish" 24 t) ("What was asked" 0 nil)]
        tabulated-list-padding 2)
  (add-hook 'tabulated-list-revert-hook #'genie-lamp--fill nil t)
  (tabulated-list-init-header))

(defun genie-lamp--fill ()
  "Read the wishes into the list."
  (setq tabulated-list-entries
        (mapcar
         (lambda (wish)
           (list (plist-get wish :name)
                 (vector
                  (pcase (plist-get wish :state)
                    ('on (propertize "●" 'face 'success))
                    ('broken (propertize "✗" 'face 'error))
                    (_ (propertize "○" 'face 'shadow)))
                  (symbol-name (plist-get wish :name))
                  (concat (car (split-string (plist-get wish :doc) "\n"))
                          (if-let* ((why (plist-get wish :error)))
                              (propertize (format "  — %s" why) 'face 'error)
                            "")))))
         (genie-wish-list))))

;;;###autoload
(defun genie-lamp ()
  "List the wishes this Emacs was granted, to look into one or take it back."
  (interactive)
  (with-current-buffer (get-buffer-create "*genie lamp*")
    (genie-lamp-mode)
    (genie-lamp--fill)
    (tabulated-list-print t)
    (pop-to-buffer (current-buffer)))
  (message "t switches off or on · e what it changed · RET its file · d forgets · w a new wish"))

(defun genie-lamp--wish ()
  "Return the wish at point, as `genie-wish-list' gives it."
  (let ((name (or (tabulated-list-get-id) (user-error "No wish here"))))
    (cl-find name (genie-wish-list) :key (lambda (wish) (plist-get wish :name)))))

(defun genie-lamp--commit (subject &rest files)
  "Commit FILES of the configuration as SUBJECT, for `genie-undo' to take back."
  (let ((subject (format "genie: %s" subject)))
    (apply #'genie--git "add" "-A" "--" files)
    (apply #'genie--git "commit" "-q" "-m" subject "--" files)
    (push (cons 'wish subject) genie--journal)))

(defun genie-lamp-visit ()
  "Open the file of the wish at point."
  (interactive)
  (find-file (plist-get (genie-lamp--wish) :file)))

(defun genie-lamp-toggle ()
  "Switch the wish at point off, or back on, and keep it so."
  (interactive)
  (let* ((wish (genie-lamp--wish))
         (name (plist-get wish :name))
         (on (not (eq (plist-get wish :state) 'on))))
    (genie-wish-keep name on)
    (genie-lamp--commit (format "switch %s %s" name (if on "on" "off"))
                        (genie-wish--off-file))
    (revert-buffer)
    (message "🧞 %s is %s" name (if on "on" "off — what it changed is as it was"))))

(defun genie-lamp-effects ()
  "Show what the wish at point has changed in this Emacs."
  (interactive)
  (let ((wish (genie-lamp--wish)))
    (with-help-window "*genie wish*"
      (princ (format "%s is %s.\n\n%s\n\n"
                     (plist-get wish :name)
                     (pcase (plist-get wish :state)
                       ('broken (format "switched off, because it signalled: %s"
                                        (plist-get wish :error)))
                       (state state))
                     (plist-get wish :doc)))
      (princ (if-let* ((effects (plist-get wish :effects)))
                 (format "What it has in place:\n%s\n"
                         (mapconcat (lambda (effect) (concat "  " effect))
                                    effects "\n"))
               "It has nothing in place.\n"))
      (princ (format "\nIt is written in %s"
                     (abbreviate-file-name (plist-get wish :file)))))))

(defun genie-lamp-forget ()
  "Forget the wish at point for good: switch it off and delete its file."
  (interactive)
  (let* ((wish (genie-lamp--wish))
         (file (plist-get wish :file)))
    (when (yes-or-no-p (format "Forget the wish %s for good? "
                               (plist-get wish :name)))
      (genie-wish-forget-file file)
      (delete-file file)
      (genie-lamp--commit (format "forget %s" (plist-get wish :name)) file)
      (revert-buffer))))

(provide 'genie-lamp)
;;; genie-lamp.el ends here
