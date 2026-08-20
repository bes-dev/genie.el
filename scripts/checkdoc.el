;;; checkdoc.el --- Fail on checkdoc warnings -*- lexical-binding: t; -*-
;;; Commentary:
;; Batch driver: `make checkdoc' runs checkdoc-file over the given files
;; and exits non-zero when any warning was emitted.
;;; Code:
(require 'checkdoc)
(let ((sentence-end-double-space t))
  (dolist (file command-line-args-left)
    (checkdoc-file file)))
(when-let* ((buf (get-buffer "*Warnings*")))
  (with-current-buffer buf (princ (buffer-string)))
  (kill-emacs 1))
;;; checkdoc.el ends here
