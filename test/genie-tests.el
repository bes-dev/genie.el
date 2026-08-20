;;; genie-tests.el --- Tests for genie and genie-rpc -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; ERT suite: genie-rpc line framing and event normalization, genie's git
;; pipeline (snapshot / detect / reject / commit / undo), validation, and
;; the spell conjure/cast pipeline.  No network and no real agent needed.

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
          (genie--wish nil))
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
    (genie-reject)
    (should (equal (genie-tests--read "a.el") "(setq a 1)\n"))
    (should (equal (genie-tests--read "b.el") "(setq b 2)\n"))
    (should-not (file-exists-p (expand-file-name "c.el" (genie--root))))
    (should-not genie--changed)))

(ert-deftest genie-git-commit-and-undo ()
  "Apply commits only touched files; undo reverts cleanly despite user WIP."
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
    (cl-letf (((symbol-function 'genie--reload) #'ignore))
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

;;;; genie: validation

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

(ert-deftest genie-spell-pipeline ()
  "A full spell turn arms a working region command; a bad reply keeps it."
  (let ((genie--turn 'spell)
        (genie--spell nil)
        (genie--spells nil)
        (genie--busy t)
        (genie--changed nil))
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
    (should (eq genie--spell 'genie-spell/number-lines))
    (should (commandp genie--spell))
    (with-temp-buffer
      (insert "alpha\nbeta\ngamma\n")
      (funcall genie--spell (point-min) (point-max))
      (should (equal (buffer-string) "1. alpha\n2. beta\n3. gamma\n")))
    ;; a reply without an interactive defun keeps the previous spell armed
    (genie--learn-spell "```elisp\n(setq genie-tests--var 1)\n```")
    (should (eq genie--spell 'genie-spell/number-lines))))

(ert-deftest genie-spell-registers ()
  "Registers store spells by digit; casting an empty register errors clearly."
  (let ((genie--registers nil)
        (genie--spells nil)
        (genie--spell nil)
        (genie--pending-register ?3))
    ;; conjuring with a pending register lands the spell there
    (genie--learn-spell
     "(defun genie-spell/test-reg () (interactive) 'cast)")
    (should (eq (alist-get ?3 genie--registers) 'genie-spell/test-reg))
    (should-not genie--pending-register)
    (should (eq (genie-cast-register ?3) 'cast))
    (should-error (genie-cast-register ?7) :type 'user-error)
    ;; rebinding a register evicts the old spell in place
    (genie--bind-register ?3 'ignore)
    (should (eq (alist-get ?3 genie--registers) 'ignore))))

(provide 'genie-tests)
;;; genie-tests.el ends here
