;;; genie-follow.el --- See what the agent changes, as it changes it -*- lexical-binding: t; -*-

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

;; An agent edits files on disk, where nobody is looking.  This brings
;; each edit to the screen: the file is shown in a window that is not the
;; one being worked in, at the place that changed, with the new lines
;; lit.  After `genie-follow-seconds' the light goes out, and a window
;; that was opened only to show the change goes with it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defcustom genie-follow-seconds 12
  "For how long a change the agent made stays lit, or nil not to show any."
  :type '(choice (const :tag "Do not follow" nil) number) :group 'genie)

(defface genie-follow '((t :inherit diff-added :extend t))
  "Lines the agent has just written."
  :group 'genie)

(defun genie-follow--changed (old new)
  "Return (SKIP . COUNT): where in the text NEW the lines not in OLD are.
A hunk carries context around what it changes; the context is what OLD
and NEW share at both ends."
  (let* ((old (split-string (or old "") "\n"))
         (new (split-string new "\n"))
         (most (min (length old) (length new)))
         (head 0) (tail 0))
    (while (and (< head most) (equal (nth head old) (nth head new)))
      (cl-incf head))
    (while (and (< (+ head tail) most)
                (equal (nth (- (length old) tail 1) old)
                       (nth (- (length new) tail 1) new)))
      (cl-incf tail))
    (cons head (- (length new) head tail))))

(defun genie-follow--dim (overlay window)
  "Put out OVERLAY, and close WINDOW if it was opened to show it."
  (let ((buffer (overlay-buffer overlay)))
    (delete-overlay overlay)
    (when (and (window-live-p window) (eq (window-buffer window) buffer)
               (not (eq window (selected-window))))
      ;; Quitting a window selects the one that was selected when it was
      ;; opened — out from under someone typing in the minibuffer by now.
      (save-selected-window (quit-restore-window window)))))

(defun genie-follow-light (beg end &optional window)
  "Light what the agent wrote between BEG and END in this buffer.
WINDOW, when it was opened to show it, closes when the light goes out."
  (when genie-follow-seconds
    (let ((overlay (make-overlay beg end)))
      (overlay-put overlay 'face 'genie-follow)
      (run-at-time genie-follow-seconds nil #'genie-follow--dim
                   overlay window))))

(defvar genie-follow--queue nil "Hunks waiting to be shown, oldest first.")
(defvar genie-follow--timer nil "The timer that shows the next hunk.")

(defun genie-follow (call)
  "Show what the finished edit CALL changed: each file, its new lines lit.
One hunk at a time, so that a change to several files is seen in each."
  (when genie-follow-seconds
    (setq genie-follow--queue
          (append genie-follow--queue
                  (seq-filter (lambda (part) (equal (plist-get part :type) "diff"))
                              (plist-get call :content))))
    (unless genie-follow--timer (genie-follow--next))))

(defun genie-follow--next ()
  "Show the hunk that has waited longest; come back for the one after it."
  (setq genie-follow--timer nil)
  (when-let* ((diff (pop genie-follow--queue)))
    (genie-follow--show diff)
    (setq genie-follow--timer (run-at-time 1.5 nil #'genie-follow--next))))

(defun genie-follow--show (diff)
  "Bring the hunk DIFF to the screen.
The window the person is in is never taken, and their point never moved."
  (when-let* ((path (plist-get diff :path))
              ((file-exists-p path))
              (buffer (or (find-buffer-visiting path)
                          (find-file-noselect path t))))
    (with-current-buffer buffer
      (unless (or (buffer-modified-p) (verify-visited-file-modtime))
        (revert-buffer t t t))
      (save-excursion
        (goto-char (point-min))
        (when (search-forward (plist-get diff :newText) nil t)
          (pcase-let* ((start (match-beginning 0)) ; showing it loses the match
                       (`(,skip . ,count)
                        (genie-follow--changed (plist-get diff :oldText)
                                               (plist-get diff :newText)))
                       (opened (not (get-buffer-window buffer)))
                       (window (display-buffer buffer)))
            (goto-char start)
            (forward-line skip)
            (unless (eq window (selected-window))
              (set-window-point window (point)))
            (genie-follow-light (point) (line-beginning-position (1+ count))
                                (and opened window))))))))

(provide 'genie-follow)
;;; genie-follow.el ends here
