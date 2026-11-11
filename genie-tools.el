;;; genie-tools.el --- Emacs, as tools for its own agent -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.16.0
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

;; Emacs documents itself: every function, option and key can be asked
;; what it is, and answers from the session that is actually running.
;; An agent that changes Emacs should ask it rather than guess, so these
;; are the questions, offered as tools (see `:tools' in genie-acp):
;;
;;   describe   what a function, a variable or a key is, here and now
;;   apropos    what there is whose name matches
;;   source     how something is written
;;   messages   what Emacs has been saying
;;   eval       run Lisp in this session
;;
;; Four ask and one acts.  The one that acts goes through genie-live: it
;; is screened, it waits until Emacs is free, it runs where the wish was
;; made, and what it does to a buffer `genie-undo' takes back.
;;
;; Every answer is bounded: what a tool says lands in a model's context.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'find-func)
(require 'genie-live)

(defconst genie-tools--limit 6000
  "The most characters one answer may be.")

(defun genie-tools--clip (text)
  "Return TEXT, cut to what an answer may be."
  (if (> (length text) genie-tools--limit)
      (concat (substring text 0 genie-tools--limit) "\n[cut]")
    text))

(defun genie-tools--first-line (doc)
  "Return the first line of DOC, or the empty string."
  (car (split-string (or doc "") "\n")))

(defun genie-tools--function (symbol)
  "Describe the function SYMBOL."
  (let ((keys (and (commandp symbol)
                   (mapcar #'key-description
                           (cl-subseq (where-is-internal symbol) 0
                                      (min 5 (length (where-is-internal symbol))))))))
    (format "%s is %s%s.\n%S\n%s%s"
            symbol
            (cond ((commandp symbol) "a command")
                  ((macrop symbol) "a macro")
                  (t "a function"))
            (if-let* ((file (symbol-file symbol 'defun)))
                (format " defined in %s" (abbreviate-file-name file))
              "")
            (cons symbol (help-function-arglist symbol t))
            (if keys (format "Keys: %s\n" (string-join keys ", ")) "")
            ;; The usage line some docstrings end in says the arguments again.
            (replace-regexp-in-string
             "\n\n(fn[^\n]*)\\'" ""
             (or (ignore-errors (documentation symbol)) "Not documented.")))))

(defun genie-tools--variable (symbol)
  "Describe the variable SYMBOL."
  (format "%s is %s%s.\nValue: %s\n%s"
          symbol
          (if (custom-variable-p symbol) "a user option" "a variable")
          (if-let* ((file (symbol-file symbol 'defvar)))
              (format " defined in %s" (abbreviate-file-name file))
            "")
          (truncate-string-to-width (format "%S" (symbol-value symbol)) 400
                                    nil nil "…")
          (or (documentation-property symbol 'variable-documentation)
              "Not documented.")))

(defun genie-tools--describe (args)
  "Say what the symbol or the key named in ARGS is in this session."
  (let* ((key (plist-get args :key))
         (bound (and key (genie-tools--in-place
                          (lambda () (key-binding (kbd key))))))
         (symbol (if key bound (intern-soft (or (plist-get args :symbol) ""))))
         (said (delq nil
                     (list (and key (format "%s runs %s." key (or bound "nothing")))
                           (and symbol (symbolp symbol) (fboundp symbol)
                                (genie-tools--function symbol))
                           (and symbol (symbolp symbol) (boundp symbol)
                                (genie-tools--variable symbol))))))
    (if said
        (string-join said "\n\n")
      (format "Nothing here is called %s.  `apropos' finds what there is."
              (plist-get args :symbol)))))

(defun genie-tools--apropos (args)
  "List what is defined whose name matches the pattern in ARGS."
  (let* ((pattern (plist-get args :pattern))
         (line (lambda (kind symbol doc)
                 (format "%s %s — %s" kind symbol (genie-tools--first-line doc))))
         (found
          (append
           (mapcar (lambda (symbol)
                     (funcall line "command" symbol
                              (ignore-errors (documentation symbol t))))
                   (apropos-internal pattern #'commandp))
           (mapcar (lambda (symbol)
                     (funcall line "option" symbol
                              (documentation-property
                               symbol 'variable-documentation t)))
                   (apropos-internal pattern #'custom-variable-p))
           (mapcar (lambda (symbol)
                     (funcall line "function" symbol
                              (ignore-errors (documentation symbol t))))
                   (apropos-internal
                    pattern (lambda (symbol)
                              (and (fboundp symbol) (not (commandp symbol)))))))))
    (if found
        (string-join (cl-subseq found 0 (min 40 (length found))) "\n")
      (format "Nothing matches %s." pattern))))

(defun genie-tools--source (args)
  "Return the definition of the symbol named in ARGS, as written."
  (let* ((symbol (or (intern-soft (plist-get args :symbol))
                     (error "Nothing here is called %s" (plist-get args :symbol))))
         (file (or (symbol-file symbol 'defun) (symbol-file symbol 'defvar)
                   (error "%s is built in, or was defined without a file"
                          symbol)))
         ;; What is recorded may be the compiled file, or a bare name.
         (source (if (and (string-suffix-p ".el" file) (file-readable-p file))
                     file
                   (find-library-name (file-name-base file)))))
    (with-temp-buffer
      (insert-file-contents source)
      (goto-char (point-min))
      (unless (re-search-forward
               (format "^(\\(?:cl-\\)?def[a-z-]* +%s\\_>"
                       (regexp-quote (symbol-name symbol)))
               nil t)
        (error "%s is defined in %s, but not by a form of its own"
               symbol (abbreviate-file-name source)))
      (goto-char (match-beginning 0))
      (format ";; %s\n%s" (abbreviate-file-name source)
              (buffer-substring (point) (progn (forward-sexp) (point)))))))

(defun genie-tools--messages (_args)
  "Return the last of what Emacs said, and of what it warned about."
  (cl-flet ((tail (name lines)
              (when-let* ((buffer (get-buffer name)))
                (with-current-buffer buffer
                  (save-excursion
                    (goto-char (point-max))
                    (forward-line (- lines))
                    (string-trim (buffer-substring-no-properties
                                  (point) (point-max))))))))
    (format "*Messages*\n%s%s"
            (or (tail "*Messages*" 40) "")
            (if-let* ((warnings (tail "*Warnings*" 20)))
                (format "\n\n*Warnings*\n%s" warnings)
              ""))))

(defun genie-tools--in-place (function)
  "Call FUNCTION where the last wish was made, or here if that is gone."
  (if (buffer-live-p (plist-get genie-live--place :buffer))
      (genie-live-at genie-live--place function)
    (funcall function)))

(defun genie-tools--eval (args)
  "Run the Lisp in ARGS where the last wish was made; return what it gave."
  (let ((code (plist-get args :code)))
    (genie-live-screen code)
    (genie-tools--in-place
     (lambda ()
       (let ((value (cdr (genie-live-call
                          "eval" (lambda () (genie-live-eval code))))))
         (format "=> %S\n(ran in buffer %s)" value (buffer-name)))))))

(defun genie-tools--tool (name description properties required function
                               &optional acting)
  "Return the tool NAME, which answers with the result of FUNCTION.
DESCRIPTION is for the model; PROPERTIES and REQUIRED are its JSON
schema.  No tool runs in the process filter that asked for it.  One
that is ACTING also waits until no minibuffer is in use."
  (list :name name :description description
        :schema (list :type "object" :properties properties
                      :required (vconcat required))
        :call
        (lambda (args say)
          (funcall
           (if acting #'genie-live-when-free
             (lambda (thunk) (run-at-time 0 nil thunk)))
           (lambda ()
             (condition-case err
                 (funcall say (genie-tools--clip (funcall function args)))
               (error (funcall say (error-message-string err) t))))))))

(defconst genie-tools
  (list
   (genie-tools--tool
    "describe"
    "What a function, variable or key is in the running Emacs: its \
documentation, value, keys and the file that defines it. Ask this instead \
of assuming a name or an option exists."
    '(:symbol (:type "string" :description "A function or variable name.")
      :key (:type "string" :description "A key instead, as in \"C-c d\"."))
    nil #'genie-tools--describe)
   (genie-tools--tool
    "apropos"
    "The commands, options and functions whose names match a regexp, each \
with the first line of its documentation."
    '(:pattern (:type "string" :description "A regexp, such as \"line-number\"."))
    '("pattern") #'genie-tools--apropos)
   (genie-tools--tool
    "source"
    "The definition of a function or variable as written in its file."
    '(:symbol (:type "string" :description "A function or variable name."))
    '("symbol") #'genie-tools--source)
   (genie-tools--tool
    "messages"
    "The latest lines of *Messages* and *Warnings*: what Emacs just said, \
and what went wrong."
    nil nil #'genie-tools--messages)
   (genie-tools--tool
    "eval"
    "Evaluate Emacs Lisp in the running session and return the value of the \
last form. It runs in the buffer the user asked from, at their point, with \
their region active. Use it to do something now, or to check that a change \
took effect — not to change the configuration, which is done in files."
    '(:code (:type "string" :description "One or more Lisp forms."))
    '("code") #'genie-tools--eval t))
  "What an agent may ask of, and do in, this Emacs.")

(provide 'genie-tools)
;;; genie-tools.el ends here
