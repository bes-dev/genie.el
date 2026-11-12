;;; genie-markdown.el --- Markdown, dressed a line at a time -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.18.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: text, convenience
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

;; What a model writes is markdown, and it arrives a few characters at a
;; time.  `genie-markdown-line' dresses one finished line of it where it
;; stands: the marks are hidden rather than removed, so the text is still
;; what was written — copy it and the markdown comes along — while what
;; is read is headings, emphasis, code and things to click.
;;
;; A line at a time is what makes this usable while text streams: nothing
;; is ever re-read, and the only thing carried from one line to the next
;; is whether a fenced block is open.
;;
;;   # heading          a heading, without the hashes
;;   **bold** `code`    emphasis and code, without the marks
;;   - item             a bullet
;;   > quoted           a quotation
;;   ```lang … ```      a block of code, set apart by a rule down its side
;;   [text](url)        a link, as its text
;;   https://… /a/file.el:12 [[page]]   things to click

;;; Code:

(require 'cl-lib)
(require 'button)

(defface genie-markdown-heading '((t :inherit bold :height 1.1))
  "Face for a heading."
  :group 'genie)

(defface genie-markdown-code '((t :inherit (font-lock-constant-face fixed-pitch)))
  "Face for code within a line."
  :group 'genie)

(defface genie-markdown-block '((t :inherit fixed-pitch))
  "Face for the lines of a fenced block of code."
  :group 'genie)

(defface genie-markdown-quote '((t :inherit (italic shadow)))
  "Face for a quotation."
  :group 'genie)

(defface genie-markdown-rule '((t :inherit shadow))
  "Face for what sets text apart: a block's side rule, a bullet, a divider."
  :group 'genie)

(defvar genie-markdown-page-function nil
  "Function called with the name of a [[page]] when its link is followed.
Nil leaves such links as plain text.")

(define-button-type 'genie-markdown-file
  'follow-link t 'help-echo "Open this file"
  'action (lambda (button)
            (find-file-other-window (button-get button 'file))
            (when-let* ((line (button-get button 'line)))
              (goto-char (point-min))
              (forward-line (1- line)))))

(define-button-type 'genie-markdown-url
  'follow-link t 'help-echo "Open this in a browser"
  'action (lambda (button) (browse-url (button-get button 'url))))

(define-button-type 'genie-markdown-page
  'follow-link t 'help-echo "Open this page"
  'action (lambda (button)
            (funcall genie-markdown-page-function (button-get button 'page))))

(defun genie-markdown--hide (beg end)
  "Hide the text between BEG and END without removing it."
  (put-text-property beg end 'invisible t))

(defun genie-markdown--each (beg end regexp function)
  "Call FUNCTION at each match of REGEXP between BEG and END."
  (goto-char beg)
  (while (re-search-forward regexp end t)
    (save-match-data (funcall function))))

(defun genie-markdown--inline (beg end directory)
  "Dress what stands within the line from BEG to END.
Paths are looked up against DIRECTORY."
  ;; Code first: what stands inside it is not markdown.
  (genie-markdown--each
   beg end "\\(`\\)\\([^`\n]+\\)\\(`\\)"
   (lambda ()
     (genie-markdown--hide (match-beginning 1) (match-end 1))
     (genie-markdown--hide (match-beginning 3) (match-end 3))
     (put-text-property (match-beginning 2) (match-end 2) 'genie-markdown-code t)
     (add-face-text-property (match-beginning 2) (match-end 2)
                             'genie-markdown-code)))
  ;; Emphasis opens after a space or at the start and closes before one or
  ;; at the end: `2**10' and `**kwargs' are not emphasis.
  (genie-markdown--each
   beg end "\\(?:^\\|[ \t(\"'>]\\)\\(\\*\\*\\)\\([^ *\n][^*\n]*\\)\\(\\*\\*\\)\\(?:$\\|[^[:alnum:]_*]\\)"
   (lambda ()
     (unless (text-property-any (match-beginning 1) (match-end 3)
                                'genie-markdown-code t)
       (genie-markdown--hide (match-beginning 1) (match-end 1))
       (genie-markdown--hide (match-beginning 3) (match-end 3))
       (add-face-text-property (match-beginning 2) (match-end 2) 'bold))
     ;; What closed this one may be what the next one opens after.
     (goto-char (match-end 3))))
  (genie-markdown--each
   beg end "\\(\\[\\)\\([^]\n[]+\\)\\(\\](\\(https?://[^)\n ]+\\))\\)"
   (lambda ()
     (genie-markdown--hide (match-beginning 1) (match-end 1))
     (genie-markdown--hide (match-beginning 3) (match-end 3))
     (make-text-button (match-beginning 2) (match-end 2)
                       'type 'genie-markdown-url
                       'url (match-string-no-properties 4))))
  (genie-markdown--each
   beg end "https?://[^ \t\n<>\"')]+[^ \t\n<>\"').,;:!?]"
   (lambda ()
     (unless (get-text-property (match-beginning 0) 'invisible)
       (make-text-button (match-beginning 0) (match-end 0)
                         'type 'genie-markdown-url
                         'url (match-string-no-properties 0)))))
  (when genie-markdown-page-function
    (genie-markdown--each
     beg end "\\[\\[\\([^]|\n]+\\)\\(?:|[^]\n]*\\)?\\]\\]"
     (lambda ()
       (make-text-button (match-beginning 0) (match-end 0)
                         'type 'genie-markdown-page
                         'page (match-string-no-properties 1)))))
  (genie-markdown--each
   beg end
   "\\(?:^\\|[ \t(`\"']\\)\\(\\(?:~\\|\\.\\{0,2\\}\\)?/[^ \t\n`\"'()<>:,;]+\\)\\(?::\\([0-9]+\\)\\)?"
   (lambda ()
     (let ((file (expand-file-name (match-string-no-properties 1) directory)))
       (when (file-exists-p file)
         (make-text-button (match-beginning 1) (or (match-end 2) (match-end 1))
                           'type 'genie-markdown-file 'file file
                           'line (and (match-string 2)
                                      (string-to-number (match-string 2)))))))))

(defun genie-markdown-line (beg end fence directory prefix)
  "Dress the line of markdown from BEG to END; return whether a fence is open.
FENCE says whether the line stands inside a fenced block, DIRECTORY is
what a path in it is relative to, and PREFIX is what the lines around
it are indented with, which a block's side rule is added to.  The text
is not changed: marks are hidden, and faces and buttons are laid over."
  (save-excursion
    (goto-char beg)
    (let ((ruled (concat prefix (propertize "│ " 'face 'genie-markdown-rule))))
      (cond
       ((looking-at "[ \t]*```\\(.*\\)$")
        ;; The fence itself is not for reading.  One that names a language
        ;; shows the name, small, above the block; any other is not shown.
        (if (or fence (string-empty-p (match-string 1)))
            (genie-markdown--hide beg (min (1+ end) (point-max)))
          (put-text-property beg end 'display
                             (propertize (match-string 1)
                                         'face 'genie-markdown-rule)))
        (not fence))
       (fence
        (add-text-properties
         beg (min (1+ end) (point-max))
         (list 'line-prefix ruled 'wrap-prefix ruled))
        (add-face-text-property beg end 'genie-markdown-block)
        t)
       (t
        (cond
         ((looking-at "\\(#+ +\\)\\(.*\\)$")
          (genie-markdown--hide (match-beginning 1) (match-end 1))
          (add-face-text-property (match-beginning 2) (match-end 2)
                                  'genie-markdown-heading))
         ((looking-at "[ \t]*\\([-*]\\) ")
          (put-text-property (match-beginning 1) (match-end 1) 'display
                             (propertize "•" 'face 'genie-markdown-rule)))
         ((looking-at "\\(> ?\\)\\(.*\\)$")
          (put-text-property (match-beginning 1) (match-end 1) 'display
                             (propertize "▎ " 'face 'genie-markdown-rule))
          (add-face-text-property (match-beginning 2) (match-end 2)
                                  'genie-markdown-quote))
         ((looking-at "\\(?:-\\{3,\\}\\|\\*\\{3,\\}\\|_\\{3,\\}\\)[ \t]*$")
          (put-text-property beg end 'display
                             (propertize (make-string 24 ?─)
                                         'face 'genie-markdown-rule))))
        (genie-markdown--inline beg end directory)
        nil)))))

(provide 'genie-markdown)
;;; genie-markdown.el ends here
