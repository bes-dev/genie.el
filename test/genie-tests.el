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
         (rpc (genie-tests--rpc 'elmee :on-text (lambda (s) (push s texts)))))
    (genie-rpc--filter rpc "{\"type\":\"text\",\"te")
    (genie-rpc--filter rpc "xt\":\"hel")
    (genie-rpc--filter rpc "lo\"}\n{\"type\":\"text\",\"text\":\" world\"}\n")
    (should (equal (nreverse texts) '("hello" " world")))))

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

(ert-deftest genie-rpc-elmee-events ()
  "Elmee events normalize, including result answers and failures."
  (let* ((log nil)
         (rpc (genie-tests--rpc
               'elmee
               :on-text (lambda (s) (push (cons 'text s) log))
               :on-tool (lambda (s) (push (cons 'tool s) log))
               :on-done (lambda (a) (push (cons 'done a) log))
               :on-fail (lambda (m) (push (cons 'fail m) log)))))
    (genie-rpc--filter
     rpc (concat "{\"type\":\"protocol\",\"version\":1}\n"
                 "{\"type\":\"tool_start\",\"id\":\"1\",\"name\":\"write\"}\n"
                 "{\"type\":\"result\",\"answer\":\"done\"}\n"
                 "{\"type\":\"error\",\"message\":\"boom\"}\n"))
    (should (equal (nreverse log)
                   '((tool . "write") (done . "done") (fail . "boom"))))))

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
  "Apply commits only touched files; fallback undo confirms, then reverts."
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
    ;; the empty-journal fallback asks first; declining leaves HEAD alone
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
      (should-error (genie-undo) :type 'user-error))
    (cl-letf (((symbol-function 'genie--reload) #'ignore)
              ((symbol-function 'y-or-n-p) (lambda (_) t)))
      (genie-undo))
    (should (equal (genie-tests--read "a.el") "(setq a 1)\n"))
    (should-not (file-exists-p (expand-file-name "d.el" (genie--root))))
    (should (equal (genie-tests--read "b.el") "(setq b 2)\n"))))

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

(ert-deftest genie-finish-turn-ignores-late-events ()
  "A finish outside the thinking state must not re-run the pipeline."
  (let ((genie--state 'idle))
    (cl-letf (((symbol-function 'genie--detect-changes)
               (lambda () (error "Pipeline ran twice"))))
      (genie--finish-turn))))                   ; no error means it was ignored

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
