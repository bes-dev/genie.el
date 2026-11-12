;;; genie-trail.el --- The steps the agent is taking, along the top -*- lexical-binding: t; -*-

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

;; The mode line says what the agent is doing this second.  The trail
;; says how it got there: every step of the turn in order, the finished
;; ones ticked, in the tab bar — one line across the top of the frame,
;; and no window of its own.  `genie-trail-mode' switches it on; a frame
;; with a single tab gives the trail the whole bar.

;;; Code:

(require 'tab-bar)

(defvar genie-trail--steps nil "The steps of the latest turn, newest first.")
(defvar genie-trail--over t "Non-nil once the latest step has ended too.")

(defvar genie-trail--format nil "What `tab-bar-format' was before the trail.")

(defun genie-trail-step (fresh what)
  "Add WHAT to the trail; with WHAT nil, the step under way has ended.
FRESH non-nil begins a new trail."
  (when fresh (setq genie-trail--steps nil))
  ;; Thinking is a step only until there is something done to show for it.
  (when (equal (car genie-trail--steps) "thinking") (pop genie-trail--steps))
  (when what (push what genie-trail--steps))
  (setq genie-trail--over (not what))
  (force-mode-line-update t))

(defun genie-trail ()
  "Return the trail as an item of `tab-bar-format'.
When it is longer than the frame is wide, its beginning gives way."
  (let* ((now (and (not genie-trail--over) (car genie-trail--steps)))
         (line (mapconcat
                (lambda (step)
                  ;; Faces of their own: a theme may paint the bar's text
                  ;; in the colour of the bar.
                  (if (eq step now)
                      (propertize (concat "◦ " step) 'face '(bold default))
                    (concat (propertize "✓ " 'face 'success)
                            (propertize step 'face 'shadow))))
                (reverse genie-trail--steps) "  ›  "))
         (room (- (frame-width) 5))
         (over (- (string-width line) room)))
    `((genie-trail menu-item
                   ,(concat " 🧞 " (if (> over 0)
                                      (concat "…" (substring line (1+ over)))
                                    line))
                   ignore))))

;;;###autoload
(define-minor-mode genie-trail-mode
  "Show the steps of the agent's turn in the tab bar."
  :global t :group 'genie
  (if genie-trail-mode
      (progn (setq genie-trail--format tab-bar-format
                   tab-bar-format (if (cdr (tab-bar-tabs))
                                      (append tab-bar-format '(genie-trail))
                                    '(genie-trail)))
             (tab-bar-mode 1))
    (setq tab-bar-format genie-trail--format)
    (force-mode-line-update t)))

(provide 'genie-trail)
;;; genie-trail.el ends here
