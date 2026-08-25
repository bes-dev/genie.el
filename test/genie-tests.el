;;; genie-tests.el --- Tests for genie and genie-rpc -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; ERT suite: genie-rpc line framing and event normalization, genie's git
;; pipeline (snapshot / detect / reject / commit / undo), validation, the
;; turn state machine, and the spell/cantrip pipeline with the unified
;; undo journal.  No network and no real agent needed.

;;; Code:

(require 'ert)
(require 'genie)

;;;; Helpers

(defmacro genie-tests--with-repo (&rest body)
  "Run BODY with `genie-config-root' bound to a fresh throwaway git repo."
  (declare (indent 0))
  `(let* ((genie-config-root (make-temp-file "genie-tests-repo" t))
          (genie--changed nil) (genie--created nil) (genie--verdict nil)
          (genie--pre nil) (genie--pre-dirty nil) (genie--pre-untracked nil)
          (genie--wish nil) (genie--journal nil) (genie--state 'idle)
          (genie--turn 'wish) (genie--turn-baseline nil))
     (unwind-protect
         (progn
           (genie--git "init" "-q")
           (genie--git "config" "user.email" "test@test")
           (genie--git "config" "user.name" "test")
           ,@body)
       (delete-directory genie-config-root t))))

(defun genie-tests--write (name content)
  "Write CONTENT to file NAME under the test repo."
  (with-temp-file (expand-file-name name (genie--root)) (insert content)))

(defun genie-tests--read (name)
  "Return the content of file NAME under the test repo."
  (with-temp-buffer
    (insert-file-contents (expand-file-name name (genie--root)))
    (buffer-string)))

(defun genie-tests--rpc (backend &rest handlers)
  "Return a fake `genie-rpc-session' for BACKEND with HANDLERS attached."
  (apply #'genie-rpc-open backend '("true") handlers))

;;;; genie-rpc: framing and event normalization

(ert-deftest genie-rpc-line-framing ()
  "JSON lines split across arbitrary chunks are reassembled."
  (let* ((texts nil)
         (rpc (genie-tests--rpc 'pi :on-text (lambda (s) (push s texts))))
         (line (concat "{\"type\":\"message_update\",\"assistantMessageEvent\":"
                       "{\"type\":\"text_delta\",\"delta\":\"hello\"}}\n")))
    (genie-rpc--filter rpc (substring line 0 40))
    (genie-rpc--filter rpc (substring line 40 55))
    (genie-rpc--filter rpc (substring line 55))
    (genie-rpc--filter rpc line)
    (should (equal (nreverse texts) '("hello" "hello")))))

(ert-deftest genie-rpc-pi-events ()
  "Pi events normalize to on-text / on-tool / on-done."
  (let* ((log nil)
         (rpc (genie-tests--rpc
               'pi
               :on-text (lambda (s) (push (cons 'text s) log))
               :on-tool (lambda (s) (push (cons 'tool s) log))
               :on-done (lambda (a) (push (cons 'done a) log)))))
    (genie-rpc--filter
     rpc (concat "{\"type\":\"tool_execution_start\",\"toolName\":\"edit\"}\n"
                 "{\"type\":\"message_update\",\"assistantMessageEvent\":"
                 "{\"type\":\"text_delta\",\"delta\":\"ok\"}}\n"
                 "{\"type\":\"agent_end\"}\n"))
    (should (equal (nreverse log)
                   '((tool . "edit") (text . "ok") (done . nil))))))

(ert-deftest genie-rpc-acp-handshake-and-turn ()
  "The full ACP cycle: handshake, queued prompt, streaming, stop reason."
  (let* ((log nil) (sent nil)
         (rpc (genie-tests--rpc
               'elmee
               :on-text (lambda (s) (push (cons 'text s) log))
               :on-tool (lambda (s) (push (cons 'tool s) log))
               :on-done (lambda (a) (push (cons 'done a) log))
               :on-fail (lambda (m) (push (cons 'fail m) log)))))
    (cl-letf (((symbol-function 'genie-rpc--send)
               (lambda (_rpc msg) (push msg sent))))
      ;; a prompt before the session is open waits in the queue
      (genie-rpc--acp-prompt rpc "make it so")
      (should (equal (genie-rpc-session-queue rpc) '("make it so")))
      (genie-rpc--acp-hello rpc)
      (let ((init (car (last sent))))
        (should (equal (plist-get init :method) "initialize")))
      ;; initialize answered → session/new goes out
      (genie-rpc--filter rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1}}\n")
      (let ((new (car (last sent 1))))
        (should (equal (plist-get (car sent) :method) "session/new"))
        (should (stringp (plist-get (plist-get (car sent) :params) :cwd)))
        (ignore new))
      ;; session opened → the queued prompt is flushed with the sessionId
      (genie-rpc--filter rpc "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"/tmp/s.jsonl\"}}\n")
      (let ((prompt (car sent)))
        (should (equal (plist-get prompt :method) "session/prompt"))
        (should (equal (plist-get (plist-get prompt :params) :sessionId)
                       "/tmp/s.jsonl"))
        (should (equal (plist-get (aref (plist-get (plist-get prompt :params)
                                                   :prompt)
                                        0)
                        :text)
                       "make it so")))
      ;; the turn streams as session/update notifications
      (genie-rpc--filter
       rpc (concat "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":"
                   "{\"sessionId\":\"/tmp/s.jsonl\",\"update\":"
                   "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"1\",\"title\":\"apply_patch init.el\"}}}\n"
                   "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":"
                   "{\"sessionId\":\"/tmp/s.jsonl\",\"update\":"
                   "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"done\"}}}}\n"
                   "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":"
                   "{\"sessionId\":\"/tmp/s.jsonl\",\"update\":"
                   "{\"sessionUpdate\":\"available_commands_update\",\"availableCommands\":[]}}}\n"))
      ;; the response to session/prompt ends the turn
      (genie-rpc--filter rpc "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}\n")
      (should (equal (nreverse log)
                     '((tool . "apply_patch init.el") (text . "done")
                       (done . nil))))
      ;; a request from the agent is declined without stalling the turn
      (genie-rpc--filter rpc "{\"jsonrpc\":\"2.0\",\"id\":\"srv-1\",\"method\":\"elicitation/create\",\"params\":{}}\n")
      (let ((reply (car sent)))
        (should (equal (plist-get reply :id) "srv-1"))
        (should (equal (plist-get (plist-get reply :result) :action)
                       "cancel"))))))

(ert-deftest genie-rpc-acp-prompt-refused ()
  "A JSON-RPC error answering session/prompt fires on-fail."
  (let* ((log nil)
         (rpc (genie-tests--rpc
               'elmee :on-fail (lambda (m) (push m log)))))
    (cl-letf (((symbol-function 'genie-rpc--send) #'ignore))
      (setf (genie-rpc-session-session-id rpc) "/tmp/s.jsonl")
      (genie-rpc--acp-send-prompt rpc "hi"))
    (genie-rpc--filter
     rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600,\"message\":\"this session is already prompting\"}}\n")
    (should (equal log '("this session is already prompting")))))

(ert-deftest genie-rpc-unknown-backend ()
  "Opening an unregistered backend signals an error."
  (should-error (genie-rpc-open 'nope '("true"))))

;;;; genie: git pipeline

(ert-deftest genie-git-snapshot-and-detect ()
  "Snapshot baselines and change detection, including created files."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie-tests--write "b.el" "(setq b 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (genie-tests--write "b.el" "(setq b 2)\n") ; user WIP before the wish
    (genie--snapshot)
    (should (equal genie--pre-dirty '("b.el")))
    (genie-tests--write "a.el" "(setq a 2)\n")
    (genie-tests--write "b.el" "(setq b 3)\n")
    (genie-tests--write "c.el" "(setq c 1)\n")
    (genie--detect-changes)
    (should (equal (sort (copy-sequence genie--changed) #'string<)
                   '("a.el" "b.el" "c.el")))
    (should (equal genie--created '("c.el")))))

(ert-deftest genie-snapshot-heals-stale-intent-to-add ()
  "A leftover `git add -N' entry (interrupted review) must not break stash.
The healed file survives in the worktree as a plain untracked file."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (genie-tests--write "GENIE.md" "# leftover manual\n")
    (genie--git "add" "-N" "--" "GENIE.md")   ; what a lost review leaves
    (genie--snapshot)                          ; must not signal
    (should (member "GENIE.md" genie--pre-untracked))
    (should (equal (genie-tests--read "GENIE.md") "# leftover manual\n"))))

(ert-deftest genie-git-reject-restores ()
  "Reject restores the pre-wish worktree but keeps the user's own WIP."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie-tests--write "b.el" "(setq b 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (genie-tests--write "b.el" "(setq b 2)\n") ; user WIP
    (genie--snapshot)
    (genie-tests--write "a.el" "(setq a 2)\n")
    (genie-tests--write "b.el" "(setq b 3)\n")
    (genie-tests--write "c.el" "(setq c 1)\n")
    (genie--detect-changes)
    (setq genie--state 'reviewing)
    (genie-reject)
    (should (equal (genie-tests--read "a.el") "(setq a 1)\n"))
    (should (equal (genie-tests--read "b.el") "(setq b 2)\n"))
    (should-not (file-exists-p (expand-file-name "c.el" (genie--root))))
    (should-not genie--changed)
    (should (eq genie--state 'idle))))

(ert-deftest genie-git-commit-and-undo ()
  "Apply commits only touched files; undo confirms, then drops the commit.
The commit leaves history entirely, its created files leave the
worktree, and unrelated uncommitted work survives untouched."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie-tests--write "b.el" "(setq b 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (genie-tests--write "b.el" "(setq b 2)\n") ; user WIP, must survive
    (genie--snapshot)
    (genie-tests--write "a.el" "(setq a 5)\n")
    (genie-tests--write "d.el" "(setq d 1)\n")
    (genie--detect-changes)
    (setq genie--wish "make a five")
    (apply #'genie--git "commit" "-m" (format "genie: %s" genie--wish)
           "--" genie--changed)
    (genie--reset)
    (should (string-prefix-p "genie: make a five"
                             (genie--git "log" "-1" "--format=%s")))
    (should (member "b.el" (split-string
                            (genie--git "diff" "--name-only" "HEAD") "\n" t)))
    ;; undo asks first; declining leaves the commit alone
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
      (should-error (genie-undo) :type 'user-error))
    (should (string-prefix-p "genie: " (genie--git "log" "-1" "--format=%s")))
    (cl-letf (((symbol-function 'genie--reload) #'ignore)
              ((symbol-function 'y-or-n-p) (lambda (_) t)))
      (genie-undo))
    (should (equal (genie-tests--read "a.el") "(setq a 1)\n"))
    (should-not (file-exists-p (expand-file-name "d.el" (genie--root))))
    (should (equal (genie-tests--read "b.el") "(setq b 2)\n"))
    ;; the commit is gone from history, not reverted on top of it
    (should (equal (genie--git "log" "--format=%s") "base"))))

(ert-deftest genie-reload-covers-init-el ()
  "Reload evaluates changed modules first, then init.el itself."
  (genie-tests--with-repo
    (genie-tests--write "mod.el" "(setq genie-tests--mod-loaded t)\n")
    (genie-tests--write
     "init.el"
     "(setq genie-tests--init-saw-mod (bound-and-true-p genie-tests--mod-loaded))\n")
    (setq genie-tests--mod-loaded nil genie-tests--init-saw-mod nil)
    (genie--reload '("mod.el" "init.el" "GENIE.md"))
    (should (bound-and-true-p genie-tests--mod-loaded))
    (should (bound-and-true-p genie-tests--init-saw-mod)))) ; init ran last

(ert-deftest genie-reload-failure-offers-restart ()
  "A file that fails to load falls back to the restart offer, not a crash."
  (genie-tests--with-repo
    (genie-tests--write "boom.el" "(error \"broken module\")\n")
    (let (asked)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt) (setq asked prompt) nil)))
        (genie--reload '("boom.el")))
      (should (string-match-p "boom\\.el" asked)))))

(ert-deftest genie-undo-warns-only-about-overlapping-edits ()
  "The drop prompt names later edits to the wish's files, and only those."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie-tests--write "b.el" "(setq b 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (genie-tests--write "a.el" "(setq a 5)\n")
    (genie--git "commit" "-qm" "genie: five" "--" "a.el")
    ;; unrelated WIP must not be mentioned…
    (genie-tests--write "b.el" "(setq b 99)\n")
    (let (prompt)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (p) (setq prompt p) nil)))
        (should-error (genie--undo-wish nil) :type 'user-error))
      (should-not (string-match-p "b\\.el" prompt))
      ;; …but a later edit to the wish's own file must be
      (genie-tests--write "a.el" "(setq a 7)\n")
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (p) (setq prompt p) nil)))
        (should-error (genie--undo-wish nil) :type 'user-error))
      (should (string-match-p "a\\.el" prompt)))
    ;; declining changed nothing
    (should (equal (genie-tests--read "b.el") "(setq b 99)\n"))
    (should (string-prefix-p "genie: " (genie--git "log" "-1" "--format=%s")))))

(ert-deftest genie-undo-refuses-foreign-head ()
  "Undo refuses when HEAD is not a genie commit."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (should-error (genie-undo) :type 'user-error)))

;;;; genie: validation and state machine

(ert-deftest genie-parens-check ()
  "The parens validator accepts balanced files and pinpoints broken ones."
  (genie-tests--with-repo
    (genie-tests--write "ok.el" "(defun f () 1)\n")
    (genie-tests--write "bad.el" "(defun f ( () 1)\n")
    (let ((genie--changed '("ok.el")))
      (should (car (genie--parens-check))))
    (let ((genie--changed '("ok.el" "bad.el")))
      (let ((verdict (genie--parens-check)))
        (should-not (car verdict))
        (should (string-match-p "bad\\.el" (cdr verdict)))))))

(ert-deftest genie-state-blocks-new-turns ()
  "Turns cannot start while one is thinking or validating."
  (dolist (state '(thinking validating))
    (let ((genie--state state))
      (should-error (genie--submit "x") :type 'user-error)))
  (let ((genie--state 'thinking))
    (should-error (genie--require-ready) :type 'user-error)))

(ert-deftest genie-state-guards-review-commands ()
  "Apply and reject demand the reviewing state; undo demands idle."
  (let ((genie--state 'thinking) (genie--changed '("a.el")))
    (should-error (genie-apply) :type 'user-error)
    (should-error (genie-reject) :type 'user-error)
    (should-error (genie-undo) :type 'user-error)))

(ert-deftest genie-indicator-heals-stale-values ()
  "Install repairs a `genie--mode-line' left bound by an older genie."
  (let ((genie--mode-line '(:eval "stale 0.6.1 construct"))
        (global-mode-string nil))
    (genie--install-indicator)
    (should (eq genie--mode-line genie--mode-line-construct))
    (should (memq 'genie--mode-line global-mode-string))
    (genie--install-indicator)                  ; idempotent
    (should (= 1 (cl-count 'genie--mode-line global-mode-string)))))

(ert-deftest genie-spinner-follows-state ()
  "The spinner timer runs while genie works and stops when it is quiet."
  (let ((genie--state 'idle) (genie--spinner-timer nil)
        (genie--spinner-index 0) (genie--tool nil))
    (unwind-protect
        (progn
          (genie--set-state 'thinking)
          (should (timerp genie--spinner-timer))
          (should (string-match-p "thinking\\." (genie--activity)))
          ;; the dots breathe: one, two, three, then one again
          (should (equal (mapcar (lambda (i)
                                   (let ((genie--spinner-index i))
                                     (genie--activity)))
                                 '(0 1 2 3))
                         '("🧞 thinking.  " "🧞 thinking.. "
                           "🧞 thinking..." "🧞 thinking.  ")))
          (genie--set-state 'validating)
          (should (timerp genie--spinner-timer))
          (should (string-match-p "validating\\." (genie--activity)))
          (genie--set-state 'idle)
          (should-not genie--spinner-timer)
          (should-not (genie--activity)))
      (when (timerp genie--spinner-timer)
        (cancel-timer genie--spinner-timer)))))

(ert-deftest genie-finish-turn-ignores-late-events ()
  "A finish outside the thinking state must not re-run the pipeline."
  (let ((genie--state 'idle))
    (cl-letf (((symbol-function 'genie--detect-changes)
               (lambda () (error "Pipeline ran twice"))))
      (genie--finish-turn))))                   ; no error means it was ignored

;;;; genie: the confirmation dial

(ert-deftest genie-confirm-dial ()
  "`genie--confirm-p' reads the dial, and honors the obsolete flag."
  (let ((genie-confirm '(wish risky-spell undo)) (genie-auto-apply nil))
    (should (genie--confirm-p 'wish))
    (should (genie--confirm-p 'undo)))
  (let ((genie-confirm '(risky-spell)) (genie-auto-apply nil))
    (should-not (genie--confirm-p 'wish))
    (should (genie--confirm-p 'risky-spell)))
  (let ((genie-confirm nil) (genie-auto-apply nil))
    (should-not (genie--confirm-p 'risky-spell)))
  ;; the obsolete boolean still switches the wish review off
  (let ((genie-confirm '(wish)) (genie-auto-apply t))
    (should-not (genie--confirm-p 'wish))))

(ert-deftest genie-instant-wish-skips-the-review ()
  "Without `wish' confirmation a validated change applies straight away."
  (let ((genie-confirm nil) (genie--state 'thinking) (genie--turn 'wish)
        (genie--changed '("a.el")) (genie--turn-baseline nil)
        applied shown)
    (cl-letf (((symbol-function 'genie--detect-changes) #'ignore)
              ((symbol-function 'genie--insert-prompt) #'ignore)
              ((symbol-function 'genie--validate)
               (lambda (cb) (funcall cb '(t . "ok"))))
              ((symbol-function 'genie-apply) (lambda () (setq applied t)))
              ((symbol-function 'genie--show-diff) (lambda () (setq shown t))))
      (genie--finish-turn))
    (should applied)
    (should-not shown)))

(ert-deftest genie-instant-wish-still-reviews-a-failure ()
  "A change that fails validation is reviewed however frictionless the flow."
  (let ((genie-confirm nil) (genie--state 'thinking) (genie--turn 'wish)
        (genie--changed '("a.el")) (genie--turn-baseline nil)
        applied shown)
    (cl-letf (((symbol-function 'genie--detect-changes) #'ignore)
              ((symbol-function 'genie--insert-prompt) #'ignore)
              ((symbol-function 'genie--validate)
               (lambda (cb) (funcall cb '(nil . "init.el broke"))))
              ((symbol-function 'genie-apply) (lambda () (setq applied t)))
              ((symbol-function 'genie--show-diff) (lambda () (setq shown t))))
      (genie--finish-turn))
    (should shown)
    (should-not applied)))

(ert-deftest genie-instant-undo-skips-the-prompt ()
  "Without `undo' confirmation the commit is dropped without asking…"
  (genie-tests--with-repo
    (let ((genie-confirm nil) asked)
      (genie-tests--write "a.el" "(setq a 1)\n")
      (genie--git "add" "-A")
      (genie--git "commit" "-qm" "base")
      (genie-tests--write "a.el" "(setq a 5)\n")
      (genie--git "commit" "-qm" "genie: five" "--" "a.el")
      (cl-letf (((symbol-function 'genie--reload) #'ignore)
                ((symbol-function 'y-or-n-p) (lambda (_) (setq asked t) t)))
        (genie--undo-wish nil))
      (should-not asked)
      (should (equal (genie--git "log" "--format=%s") "base"))
      ;; …unless the user's own later edits would go with it
      (genie-tests--write "a.el" "(setq a 9)\n")
      (genie--git "commit" "-qm" "genie: nine" "--" "a.el")
      (genie-tests--write "a.el" "(setq a 10)\n")   ; later edit of your own
      (cl-letf (((symbol-function 'genie--reload) #'ignore)
                ((symbol-function 'y-or-n-p) (lambda (_) (setq asked t) nil)))
        (should-error (genie--undo-wish nil) :type 'user-error))
      (should asked))))

(ert-deftest genie-instant-risky-spell-reports-instead-of-asking ()
  "Without the gate risky code is evaluated, but the call is still named."
  (let ((genie-confirm nil) (genie--spell nil) (genie--spells nil)
        (genie--pending-register nil) (genie--cantrip-target nil)
        said)
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (_) (error "Must not ask")))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
      (genie--learn-spell
       "(defun genie-spell/risky () (interactive) (shell-command \"ls\"))"))
    (should (eq (genie--spell-name genie--spell) 'genie-spell/risky))
    (should (cl-some (lambda (s) (string-match-p "shell-command" s)) said))))

;;;; genie: maintainer charter

(ert-deftest genie-charter-covers-maintainer-duties ()
  "The system prompt carries the anti-slop charter, not just edit permissions."
  (genie-tests--with-repo
    (let ((prompt (genie--context-prompt)))
      (dolist (duty '("thin bootstrap" "one-responsibility"
                      "web search" "Never hand-roll"
                      "docstring" "Refactor as you go"))
        (should (string-match-p duty prompt)))
      (should (string-match-p (regexp-quote genie-manual-file) prompt)))))

(ert-deftest genie-manual-requires-existing-file ()
  "`genie-manual' refuses politely when no manual has grown yet."
  (genie-tests--with-repo
    (should-error (genie-manual) :type 'user-error)))

;;;; genie: spells

(ert-deftest genie-extract-elisp ()
  "Code extraction handles fenced blocks and bare code."
  (should (equal (genie--extract-elisp "text\n```elisp\n(+ 1 2)\n```\ntail")
                 "(+ 1 2)\n"))
  (should (equal (genie--extract-elisp "(+ 1 2)") "(+ 1 2)")))

(ert-deftest genie-eval-spell ()
  "Spell evaluation returns the interactive command, or errors clearly."
  (should (eq (genie--eval-spell
               "(defun genie-spell/test-noop () (interactive) 42)")
              'genie-spell/test-noop))
  (should-error (genie--eval-spell "(setq genie-tests--nothing 1)")))

(ert-deftest genie-risky-spell-gate ()
  "Conjured code calling risky functions is screened; declining discards it."
  (should (equal (genie--risky-calls
                  "(defun f () (interactive) (shell-command \"ls\"))")
                 '(shell-command)))
  (should-not (genie--risky-calls "(defun f () (interactive) (upcase 1))"))
  (let ((genie--spell 'sentinel) (genie--spells nil)
        (genie--pending-register nil))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil))
              ((symbol-function 'display-buffer) #'ignore))
      (genie--learn-spell
       "(defun genie-spell/evil () (interactive) (delete-file \"x\"))"))
    (should (eq genie--spell 'sentinel))        ; nothing armed
    (should-not (fboundp 'genie-spell/evil))))  ; nothing evaluated

(ert-deftest genie-spell-pipeline ()
  "A full spell turn arms a working region command; a bad reply keeps it."
  (let ((genie--turn 'spell) (genie--turn-baseline nil)
        (genie--spell nil) (genie--spells nil)
        (genie--state 'thinking) (genie--changed nil)
        (genie--pending-register nil) (genie--journal nil))
    (cl-letf (((symbol-function 'genie--detect-changes) #'ignore)
              ((symbol-function 'genie--insert-prompt) #'ignore))
      (setq genie--answer
            (concat "```elisp\n"
                    "(defun genie-spell/number-lines (beg end)\n"
                    "  \"Number the lines of the region.\"\n"
                    "  (interactive \"r\")\n"
                    "  (save-excursion\n"
                    "    (goto-char beg)\n"
                    "    (let ((n 0) (endm (copy-marker end)))\n"
                    "      (while (< (point) endm)\n"
                    "        (insert (format \"%d. \" (setq n (1+ n))))\n"
                    "        (forward-line 1)))))\n"
                    "```"))
      (genie--finish-turn))
    (should (eq (genie--spell-name genie--spell) 'genie-spell/number-lines))
    (should (eq genie--state 'idle))
    (with-temp-buffer
      (insert "alpha\nbeta\ngamma\n")
      (funcall (genie--spell-fn genie--spell) (point-min) (point-max))
      (should (equal (buffer-string) "1. alpha\n2. beta\n3. gamma\n")))
    ;; a reply without an interactive defun keeps the previous spell armed
    (let ((previous genie--spell))
      (cl-letf (((symbol-function 'display-buffer) #'ignore))
        (genie--learn-spell "```elisp\n(setq genie-tests--var 1)\n```"))
      (should (eq genie--spell previous)))))

(ert-deftest genie-spell-registers ()
  "Registers store spell entries; casting an empty register errors clearly."
  (let ((genie--registers nil) (genie--spells nil) (genie--spell nil)
        (genie--journal nil) (genie--pending-register ?3)
        (genie--cantrip-target nil))
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (genie--learn-spell
       "(defun genie-spell/test-reg () (interactive) 'cast)"))
    (let ((entry (alist-get ?3 genie--registers)))
      (should (eq (genie--spell-name entry) 'genie-spell/test-reg))
      (should-not genie--pending-register)
      (should (eq (genie-cast-register ?3) 'cast))
      (should-error (genie-cast-register ?7) :type 'user-error)
      ;; rebinding a register evicts the old entry in place
      (genie--bind-register ?3 (list 'other #'ignore ""))
      (should (eq (genie--spell-name (alist-get ?3 genie--registers))
                  'other)))))

(ert-deftest genie-spell-labels-uniquify ()
  "Reused spell names get distinct labels, and old entries keep old code."
  (let ((genie--spells nil) (genie--spell nil) (genie--registers nil)
        (genie--pending-register nil) (genie--cantrip-target nil))
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (genie--learn-spell
       "(defun genie-spell/twice () (interactive) 'first)")
      (let ((old (genie--spell-fn genie--spell)))
        (genie--learn-spell
         "(defun genie-spell/twice () (interactive) 'second)")
        ;; the captured function object of the old entry is unaffected
        (should (eq (funcall old) 'first))
        (should (eq (funcall (genie--spell-fn genie--spell)) 'second))
        (should (equal (mapcar #'car (genie--spell-labels))
                       '("genie-spell/twice" "genie-spell/twice<2>")))))))

;;;; genie: unified undo journal

(ert-deftest genie-undo-cast-effect ()
  "A journaled cast is undone by `genie-undo' in the buffer it edited."
  (let ((genie--journal nil) (genie--state 'idle))
    (with-temp-buffer
      (buffer-enable-undo)
      (insert "hello\nworld\n")
      (undo-boundary)
      (genie--call-spell
       'test (lambda () (interactive) (upcase-region (point-min) (point-max))))
      (should (equal (buffer-string) "HELLO\nWORLD\n"))
      (should (eq (caar genie--journal) 'cast))
      (genie-undo)
      (should (equal (buffer-string) "hello\nworld\n"))
      (should-not genie--journal))))

(ert-deftest genie-undo-cast-survives-truncated-history ()
  "GC dropping the pre-cast tail must not strand the journal entry.
When nothing changed since the cast, its groups are the list head and
are undone whole even though the recorded tail is gone."
  (let ((genie--journal nil) (genie--state 'idle))
    (with-temp-buffer
      (buffer-enable-undo)
      (insert "aged history\n")
      (undo-boundary)
      (genie--call-spell
       'test (lambda () (interactive) (upcase-region (point-min) (point-max))))
      (should (equal (buffer-string) "AGED HISTORY\n"))
      ;; emulate truncate_undo_list: cut the tail in place, head cons intact
      (pcase-let ((`(cast ,_ ,pre ,_ ,_) (car genie--journal)))
        (let ((cons buffer-undo-list))
          (while (not (eq (cdr cons) pre)) (setq cons (cdr cons)))
          (setcdr cons nil)))
      (genie-undo)
      (should (equal (buffer-string) "aged history\n"))
      (should-not genie--journal))))

(ert-deftest genie-undo-cast-tolerates-rebuilt-history ()
  "A rebuilt undo list (buffer revert) drops the entry with a message.
The effect is gone with the revert; undo must not error or strand it."
  (let ((genie--journal nil) (genie--state 'idle))
    (with-temp-buffer
      (buffer-enable-undo)
      (insert "x\n")
      (undo-boundary)
      (genie--call-spell
       'test (lambda () (interactive) (upcase-region (point-min) (point-max))))
      (setq buffer-undo-list '(nil))    ; what a revert leaves behind
      (genie-undo)                      ; no error, entry consumed
      (should-not genie--journal))))

(ert-deftest genie-undo-empty-journal-message ()
  "With an empty journal and a foreign HEAD, undo explains itself."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (let ((err (should-error (genie-undo) :type 'user-error)))
      (should (string-match-p "journal is empty" (cadr err))))))

(ert-deftest genie-journal-skips-effectless-casts ()
  "A cast that edits nothing leaves no journal entry."
  (let ((genie--journal nil))
    (with-temp-buffer
      (buffer-enable-undo)
      (genie--call-spell 'noop (lambda () (interactive) 'noop))
      (should-not genie--journal))))

(ert-deftest genie-cantrip-pipeline ()
  "A cantrip turn executes immediately on the captured region and is undoable."
  (let ((genie--turn 'cantrip) (genie--turn-baseline nil)
        (genie--spell nil) (genie--spells nil)
        (genie--state 'thinking) (genie--changed nil) (genie--journal nil)
        (genie--pending-register nil))
    (with-temp-buffer
      (buffer-enable-undo)
      (insert "alpha\nbeta\n")
      (undo-boundary)
      (setq genie--cantrip-target
            (list :buffer (current-buffer) :point (point-marker)
                  :region (cons (copy-marker (point-min))
                                (copy-marker (point-max)))))
      (cl-letf (((symbol-function 'genie--detect-changes) #'ignore)
                ((symbol-function 'genie--insert-prompt) #'ignore))
        (setq genie--answer
              (concat "```elisp\n"
                      "(defun genie-spell/upcase-it (beg end)\n"
                      "  \"Upcase the region.\"\n"
                      "  (interactive \"r\")\n"
                      "  (upcase-region beg end))\n"
                      "```"))
        (genie--finish-turn))
      (should (equal (buffer-string) "ALPHA\nBETA\n"))
      (should (eq (genie--spell-name genie--spell) 'genie-spell/upcase-it))
      (should (eq (caar genie--journal) 'cast))
      (should (eq genie--state 'idle))
      (genie-undo)
      (should (equal (buffer-string) "alpha\nbeta\n")))))

(provide 'genie-tests)
;;; genie-tests.el ends here
