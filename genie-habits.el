;;; genie-habits.el --- What the session says of how one works -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.18.0
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

;; Emacs already keeps what a person did: the commands they called by name,
;; the files they opened, what they compiled and ran, what they asked the
;; genie for.  Nothing is recorded here — `genie-habits' reads those
;; histories and says what recurs, with the evidence.
;;
;; `genie-reflect' hands that to the genie and asks what this Emacs should
;; change because of it.  What it proposes is offered in the minibuffer;
;; the one chosen becomes a wish like any other.

;;; Code:

(require 'cl-lib)
(require 'genie-pipeline)

(defvar genie--wish-history)
(defvar genie--task-history)
(defvar genie--spell-history)
(declare-function genie "genie" (wish))

(defun genie-habits--often (history least)
  "Return what occurs LEAST times or more in HISTORY, most first.
Each as (ITEM . COUNT)."
  (let (counts)
    (dolist (item history)
      (cl-incf (alist-get item counts 0 nil #'equal)))
    (sort (cl-remove-if (lambda (count) (< (cdr count) least)) counts)
          (lambda (a b) (> (cdr a) (cdr b))))))

(defun genie-habits--lines (title history least &optional describe)
  "Return TITLE, then what recurs LEAST times in HISTORY, a line each.
Nil when nothing does.  DESCRIBE, when given, turns an item into what
is said of it."
  (when-let* ((often (genie-habits--often history least)))
    (concat title "\n"
            (mapconcat (lambda (count)
                         (format "  %d× %s" (cdr count)
                                 (funcall (or describe #'identity) (car count))))
                       (seq-take often 8) "\n"))))

(defun genie-habits--command (name)
  "Return command NAME with the key it is on, or that it has none."
  (let ((key (where-is-internal (intern-soft name) nil t)))
    (format "M-x %s (%s)" name
            (if key (concat "on " (key-description key)) "no key"))))

(defun genie-habits ()
  "Return what recurs in this session's histories, or nil when nothing does."
  (when-let* ((said (delq nil
                          (list
                           (genie-habits--lines "Commands called by name:"
                                                extended-command-history 2
                                                #'genie-habits--command)
                           (genie-habits--lines "Files opened again and again:"
                                                file-name-history 3
                                                #'abbreviate-file-name)
                           (genie-habits--lines "Compiled:"
                                                (bound-and-true-p compile-history) 2)
                           (genie-habits--lines "Shell commands:"
                                                shell-command-history 2)
                           (genie-habits--lines "Asked of the genie:"
                                                (append genie--wish-history
                                                        genie--task-history
                                                        (bound-and-true-p
                                                         genie--spell-history))
                                                2)))))
    (string-join said "\n")))

;;;###autoload
(defun genie-reflect ()
  "Ask the genie what this Emacs should change, given how you have worked.
It finds three changes, with the evidence for each; you choose one in
the minibuffer, and that one becomes a wish."
  (interactive)
  (setq genie--answered #'genie-habits--choose)
  (genie--submit
   (concat "Here is what recurred in how I worked in this Emacs:\n\n"
           (or (genie-habits) (user-error "Genie: nothing has recurred yet"))
           "\n\nFind the three changes to this Emacs that would save me the most, \
each from a different line of evidence. A change is whatever removes the \
repetition: a file one key away, a thing done by itself on save or on opening, \
what I keep asking you for kept as a command of its own — a key for a command \
only when nothing better fits, and never for one that has a key. Ask this \
Emacs first: is the key free, is there already a command for it. Change nothing.

Answer with exactly three lines and nothing else, each starting with `- ': the \
change first, in plain words I can act on, then a dash and my own numbers — \
`- F2 opens todo.org — you opened it 5 times'.")
   "What have you noticed about how I work?"))

(defun genie-habits--choose (answer)
  "Offer what the genie proposed in ANSWER; make the one chosen a wish.
The choice is one key, asked for in the minibuffer and nowhere else."
  (let* ((offered (cl-loop for line in (split-string (or answer "") "\n" t)
                           when (string-match "\\`[-•] +\\(.+\\)" line)
                           collect (match-string 1 line)))
         (keys (number-sequence ?1 (+ ?0 (length offered))))
         (key (and offered
                   (read-char-choice
                    (concat
                     "🧞 I noticed. Which shall I grant?\n"
                     (cl-loop
                      for text in offered and key in keys
                      for (change why) = (split-string text " — ")
                      concat (format "  %s  %s%s\n"
                                     (propertize (string key) 'face 'bold) change
                                     (if why
                                         (propertize (concat " — " why)
                                                     'face 'shadow)
                                       "")))
                     "Its number, or RET for none: ")
                    (cons ?\r keys)))))
    (if (memq key keys)
        (genie (car (split-string (nth (- key ?1) offered) " — ")))
      (message "🧞 nothing granted"))))

(provide 'genie-habits)
;;; genie-habits.el ends here
