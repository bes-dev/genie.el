;;; genie.el --- State a wish; Emacs grants it -*- lexical-binding: t; -*-

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

;; Rub the lamp — `M-x genie' — and state a wish.  The genie is an AI
;; agent (elmee) that lives in this Emacs, and it grants the wish in the
;; form that fits:
;;
;;   an answer   when you asked something: it asks the running Emacs
;;               what a key, a command or an option is, rather than guess
;;   an act      when you want something done now: it runs Lisp where you
;;               were, on your region, and `genie-undo' takes it back
;;   a wish      when you want Emacs to be different from now on: a file
;;               of its own that is validated, committed, switched on —
;;               and can be switched off again while Emacs runs
;;
;; A configuration grows this way one wish at a time.  `genie-lamp'
;; lists them: what was asked, whether it is on, what exactly it changed.
;; Every change to the configuration is one git commit, and `genie-undo'
;; takes back the latest thing genie did, whatever its kind.
;;
;; Beside the lamp there is quick magic that needs no agent with tools:
;; `genie-cantrip' conjures a one-off command and runs it on the spot,
;; `genie-spell' conjures one to cast again (see genie-spell.el).
;; `genie-ask' opens a chat about whatever project you are in.
;;
;; Setup, once:
;;
;;   M-x genie-setup
;;
;; makes the configuration a git repository, has init.el load its wishes,
;; and — as the first wish of all — puts genie on `C-c g':
;;
;;   C-c g g   a wish               C-c g l   the lamp
;;   C-c g c   the genie's chat     C-c g u   undo
;;   C-c g a   ask about a project  C-c g k   stop
;;   C-c g !   a cantrip            C-c g s   a spell, C-c g x casts it
;;
;; The pieces: genie-wish (wishes that can be taken back), genie-acp (the
;; protocol), genie-chat (conversations), genie-tools (Emacs as the
;; agent's tools), genie-live (running conjured code safely),
;; genie-pipeline (a change to the configuration, start to finish),
;; genie-spell and genie-lamp.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'genie-wish)
(require 'genie-live)
(require 'genie-chat)
(require 'genie-sessions)
(require 'genie-pipeline)
(require 'genie-spell)
(require 'genie-lamp)

(defvar genie--wish-history nil "Minibuffer history for wishes.")

;;;###autoload (autoload 'genie-command-map "genie" nil t 'keymap)
(defvar genie-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'genie)
    (define-key map "c" #'genie-chat)
    (define-key map "a" #'genie-ask)
    (define-key map "l" #'genie-lamp)
    (define-key map "d" #'genie-diff)
    (define-key map "u" #'genie-undo)
    (define-key map "k" #'genie-abort)
    (define-key map "s" #'genie-spell)
    (define-key map "x" #'genie-cast)
    (define-key map "!" #'genie-cantrip)
    (define-key map "m" #'genie-manual)
    (dotimes (digit 10)
      (define-key map (number-to-string digit) #'genie-cast-register))
    map)
  "Everything genie does, one key each; `genie-setup' puts it on \\`C-c g'.")
(fset 'genie-command-map genie-command-map)

(defun genie--cleanup ()
  "End both agents and forget the conversation (`genie-quit', Emacs exit)."
  (when genie--spell-agent
    (genie-acp-shutdown genie--spell-agent)
    (setq genie--spell-agent nil genie--spell-session nil))
  (when-let* ((chat (get-buffer genie-buffer)))
    (kill-buffer chat))
  (setq genie--cantrip-target nil genie--pending-register nil)
  (genie--busy 'spell nil)
  (genie--abandon))

(add-hook 'kill-emacs-hook #'genie--cleanup)

(defun genie--where ()
  "Say where the person is, for an agent that will act there."
  (format "[Asked from the buffer %s — %s%s, line %d%s.]"
          (buffer-name) major-mode
          (if buffer-file-name
              (format ", visiting %s" (abbreviate-file-name buffer-file-name))
            "")
          (line-number-at-pos)
          (if (use-region-p) ", with the attached region active" "")))

;;;###autoload
(defun genie (wish)
  "State a WISH, and have it granted in the form that fits.
A question is answered, something to do now is done right here, and
something Emacs should do from now on becomes a wish of its own in the
configuration — validated, committed and switched on, and listed in
`genie-lamp' to be switched off again.  An active region goes with the
wish.  `genie-undo' takes back whatever was done."
  (interactive
   (progn
     (genie--require-ready)
     (list (string-trim (read-string "🧞 I wish: " nil 'genie--wish-history)))))
  (when (string-empty-p wish) (user-error "Empty wish"))
  (genie-live-remember-place)
  (let ((where (genie--where))
        (region (and (use-region-p) (genie-chat-context))))
    (when region
      (genie-chat-attach (genie--buffer) (car region) (cdr region))
      (deactivate-mark))
    (genie--submit (concat wish "\n\n" where) wish)))

;;;###autoload
(defun genie-manual ()
  "Open the config's user manual, grown by the agent wish by wish."
  (interactive)
  (let ((file (expand-file-name genie-manual-file (genie--root))))
    (unless (file-exists-p file)
      (user-error "Genie: no manual yet — it grows as you make wishes"))
    (find-file file)))

;;;###autoload
(defun genie-chat ()
  "Open the chat with the genie of this configuration.
It is a `genie-chat' like any other — skills, past conversations
\(\\<genie-chat-mode-map>\\[genie-sessions]), the model \
\(\\[genie-chat-model]) — except that whatever a turn
changes in the config goes through the wish pipeline."
  (interactive)
  (genie-live-remember-place)
  (pop-to-buffer (genie--buffer))
  (goto-char (point-max)))

;;;###autoload
(defun genie-abort ()
  "Stop the turn in flight — a wish, or a spell being conjured."
  (interactive)
  (cond
   (genie--spell-session
    (genie-acp-cancel genie--spell-session)
    (message "🧞 stopping…"))
   ((and (eq genie--state 'thinking) (get-buffer genie-buffer))
    (with-current-buffer genie-buffer (genie-chat-abort)))
   (t (message "🧞 nothing to abort"))))

;;;###autoload
(defun genie-quit ()
  "End the agents and close the genie's chat (the config is untouched).
The next wish starts a new conversation — also the way to make the
agent re-read its charter after changing `genie-config-root'.  The old
conversation is not lost: `genie-sessions' in the chat returns to it."
  (interactive)
  (genie--cleanup)
  (message "🧞 session ended — the next wish starts fresh"))

;;;###autoload
(defun genie-panic ()
  "Stop the agents and switch every wish off, for this session only.
For when Emacs misbehaves and a wish may be why: what the wishes
changed is put back as it was, nothing on disk is touched, and
`genie-lamp' switches them back on one at a time."
  (interactive)
  (genie--cleanup)
  (dolist (wish (genie-wish-list))
    (genie-wish-off (plist-get wish :name)))
  (message "🧞 every wish is off for this session and the agents are stopped \
— M-x genie-lamp switches them back on"))

;;;; Setup

(defconst genie--bootstrap
  "(require 'genie-wish)
\(genie-wish-load)
"
  "What init.el needs in order to start a configuration made of wishes.")

(defconst genie--gitignore
  "# What Emacs and its packages write for themselves; not configuration.
/elpa/
/eln-cache/
/straight/
/elpaca/
/auto-save-list/
/transient/
/url/
/.cache/
/tramp
/recentf
/places
/history
/savehist
/bookmarks
/projects
/network-security.data
*.elc
*~
\\#*#
"
  "What `genie-setup' has git leave alone in a configuration with no rules yet.")

(defconst genie--keys-wish
  ";;; genie-keys.el --- the first wish -*- lexical-binding: t; -*-

\(autoload 'genie-command-map \"genie\" nil t 'keymap)

\(genie-wish genie-keys
  \"Genie on C-c g: g a wish, c its chat, l the lamp, u undo.\"
  (genie-key global-map \"C-c g\" 'genie-command-map))
"
  "The wish `genie-setup' grants unasked: a key to make the others with.")

;;;###autoload
(defun genie-setup ()
  "Make this Emacs ready for wishes.
The configuration in `genie-config-root' becomes a git repository if it
is not kept by git already, the init file is made to load the wishes
kept in its `wishes' directory, git is told what Emacs writes for itself
there, and the first wish puts genie on \\`C-c g'.  Safe to run again:
it only adds what is missing."
  (interactive)
  (let* ((root (genie--root))
         (home (file-equal-p root user-emacs-directory))
         (init (or (genie--init-file)
                   (and home (expand-file-name "init.el" root))
                   (user-error "Genie: no init.el under %s — set \
`genie-config-root' to the directory your init file is in"
                               (abbreviate-file-name root))))
         (ignore (expand-file-name ".gitignore" root))
         keys done touched)
    ;; An init file elsewhere means Emacs would never read the one written
    ;; here: better said now than found out at the next start.
    (when (and user-init-file (not (genie--init-file))
               (not (file-in-directory-p user-init-file root)))
      (user-error "Genie: Emacs starts from %s, which is not under %s — move \
it there as init.el, or set `genie-config-root' to where it is"
                  (abbreviate-file-name user-init-file)
                  (abbreviate-file-name root)))
    ;; The wishes are part of the configuration, wherever that is kept.
    (unless home
      (setq genie-wish-directory (expand-file-name "wishes" root)))
    (setq keys (expand-file-name "genie-keys.el" genie-wish-directory))
    (make-directory genie-wish-directory t)
    ;; A directory of a larger repository is already kept by git.
    (unless (genie--git-p "rev-parse" "--is-inside-work-tree")
      (genie--git "init" "-q")
      (push "a git repository" done))
    (unless (file-exists-p ignore)
      (write-region genie--gitignore nil ignore nil 'silent)
      (push ignore touched)
      (push "a .gitignore for what Emacs writes itself" done))
    (unless (and (file-exists-p init)
                 (with-temp-buffer
                   (insert-file-contents init)
                   (search-forward "(genie-wish-load)" nil t)))
      (with-temp-buffer
        (if (file-exists-p init)
            (insert-file-contents init)
          (insert ";;; init.el --- grown by genie -*- lexical-binding: t; -*-\n"))
        (goto-char (point-max))
        (insert (if (bolp) "\n" "\n\n")
                ";; Wishes granted by genie: each a file of its own that can \
be taken back.\n"
                (if home ""
                  "(setq genie-wish-directory\n      (expand-file-name \
\"wishes\" (file-name-directory load-file-name)))\n")
                genie--bootstrap)
        (write-region nil nil init nil 'silent))
      (push init touched)
      (push (format "%s loads the wishes" (file-name-nondirectory init)) done))
    (unless (file-exists-p keys)
      (write-region genie--keys-wish nil keys nil 'silent)
      (push keys touched)
      (push "genie on C-c g" done))
    ;; Only what setup wrote: the rest of the worktree is not its to commit.
    (when touched
      (genie--commit "setup" touched)
      (genie-wish-load-file keys))
    (message "🧞 %s%s"
             (if done
                 (format "ready: %s" (string-join (nreverse done) ", "))
               "already set up")
             (if (executable-find genie-elmee-program)
                 " — C-c g g makes a wish"
               (format " — but `%s' is not on the path: install elmee, or set \
`genie-elmee-program'" genie-elmee-program)))))

(provide 'genie)
;;; genie.el ends here
