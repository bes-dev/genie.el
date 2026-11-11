;;; genie-sessions.el --- The conversations kept for a directory -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.17.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience
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

;; `genie-sessions' lists the conversations the agent keeps for a
;; directory, newest first: when each was last spoken in, how much was
;; asked, and what about.
;;
;;   RET  return to it      n  start a new one
;;   r    give it a name    d  delete it, for good
;;
;; A conversation is a file elmee keeps; nothing about it lives in Emacs,
;; so the list is the same after a restart.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'genie-chat)

(defvar-local genie-sessions--chat nil "The chat this list belongs to.")

(defvar genie-sessions-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'genie-sessions-open)
    (define-key map "n" #'genie-sessions-new)
    (define-key map "r" #'genie-sessions-rename)
    (define-key map "d" #'genie-sessions-delete)
    map)
  "Keymap for `genie-sessions-mode'.")

(define-derived-mode genie-sessions-mode tabulated-list-mode "genie-sessions"
  "The conversations kept for one directory, newest first.
\\<genie-sessions-mode-map>\\[genie-sessions-open] returns to the one at \
point, \\[genie-sessions-new] starts a new one,
\\[genie-sessions-rename] renames one, \\[genie-sessions-delete] deletes \
one, \\[revert-buffer] reads the list again."
  (setq tabulated-list-format [("When" 12 nil) ("Asked" 6 nil :right-align t)
                               ("About" 0 nil)]
        tabulated-list-padding 2)
  (add-hook 'tabulated-list-revert-hook #'genie-sessions--fetch nil t)
  (tabulated-list-init-header))

(defun genie-sessions--ago (stamp)
  "Say how long ago STAMP, an RFC 3339 time, was."
  (let ((seconds (and stamp
                      (ignore-errors
                        (float-time (time-subtract nil (date-to-time stamp)))))))
    (cond ((null seconds) "")
          ((< seconds 90) "just now")
          ((< seconds 5400) (format "%d min ago" (round seconds 60)))
          ((< seconds 129600) (format "%d h ago" (round seconds 3600)))
          (t (format "%d d ago" (round seconds 86400))))))

(defun genie-sessions--fetch ()
  "Ask the agent for this list's conversations and show them."
  (let ((buffer (current-buffer))
        (chat genie-sessions--chat))
    (unless (buffer-live-p chat) (user-error "Its chat is gone"))
    (let ((current (genie-acp-session-id
                    (buffer-local-value 'genie-chat--session chat))))
      (genie-acp-list
       (buffer-local-value 'genie-chat--agent chat)
       (buffer-local-value 'genie-chat--directory chat)
       (lambda (sessions reason)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when reason (message "🧞 %s" reason))
             (setq tabulated-list-entries
                   (mapcar
                    (lambda (session)
                      (let ((id (plist-get session :sessionId)))
                        (list id
                              (vector
                               (genie-sessions--ago (plist-get session :updatedAt))
                               (format "%s" (or (plist-get session :prompts) ""))
                               (concat (if (equal id current) "▸ " "")
                                       (or (plist-get session :title)
                                           "(nothing asked yet)"))))))
                    sessions))
             (tabulated-list-print t))))))))

;;;###autoload
(defun genie-sessions ()
  "List the conversations kept for this directory, to return to one.
From a chat it is that chat's list; from anywhere else, the list of the
project you are in."
  (interactive)
  (let* ((chat (if (derived-mode-p 'genie-chat-mode)
                   (current-buffer)
                 (genie-chat-open (genie-chat--here))))
         (list (get-buffer-create
                (format "*genie sessions: %s*"
                        (file-name-nondirectory
                         (directory-file-name
                          (buffer-local-value 'genie-chat--directory chat)))))))
    (with-current-buffer list
      (genie-sessions-mode)
      (setq genie-sessions--chat chat)
      (genie-sessions--fetch))
    (pop-to-buffer list)
    (message "RET returns to one · n starts a new one · r renames · d deletes · g refreshes · q closes")))

(defun genie-sessions--idle-chat ()
  "Return this list's chat, which must not be in the middle of a turn."
  (let ((chat genie-sessions--chat))
    (unless (buffer-live-p chat) (user-error "Its chat is gone"))
    (when (genie-chat-busy-p chat)
      (user-error "Genie is busy in that chat — stop it first"))
    chat))

(defun genie-sessions-open ()
  "Return to the conversation at point.
Its chat is filled with what was said and continues from there."
  (interactive)
  (let ((id (or (tabulated-list-get-id) (user-error "No conversation here")))
        (chat (genie-sessions--idle-chat)))
    (quit-window)
    (pop-to-buffer chat)
    (unless (equal id (genie-acp-session-id genie-chat--session))
      (genie-chat--converse id))
    (goto-char (point-max))))

(defun genie-sessions-new ()
  "Start a new conversation in this list's chat."
  (interactive)
  (let ((chat (genie-sessions--idle-chat)))
    (quit-window)
    (pop-to-buffer chat)
    (genie-chat-new)))

(defun genie-sessions-rename (title)
  "Call the conversation at point TITLE instead of what was first asked."
  (interactive
   (list (read-string "🧞 Call this conversation: "
                      (string-remove-prefix
                       "▸ " (aref (or (tabulated-list-get-entry)
                                      (user-error "No conversation here"))
                                  2)))))
  (let ((chat genie-sessions--chat)
        (buffer (current-buffer)))
    (unless (buffer-live-p chat) (user-error "Its chat is gone"))
    (genie-acp-rename
     (buffer-local-value 'genie-chat--agent chat) (tabulated-list-get-id) title
     (lambda (refused)
       (if refused
           (message "🧞 not renamed: %s" refused)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (genie-sessions--fetch))))))))

(defun genie-sessions-delete ()
  "Delete the conversation at point, for good."
  (interactive)
  (let* ((id (or (tabulated-list-get-id) (user-error "No conversation here")))
         (chat (genie-sessions--idle-chat))
         (buffer (current-buffer)))
    (when (equal id (genie-acp-session-id
                     (buffer-local-value 'genie-chat--session chat)))
      (user-error "That is the open conversation — start a new one first (n)"))
    (when (yes-or-no-p "Delete this conversation for good? ")
      (genie-acp-delete
       (buffer-local-value 'genie-chat--agent chat) id
       (lambda (refused)
         (if refused
             (message "🧞 not deleted: %s" refused)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer (genie-sessions--fetch)))))))))

(provide 'genie-sessions)
;;; genie-sessions.el ends here
