;;; genie-packages.el --- Packages installed into a running Emacs -*- lexical-binding: t; -*-

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

;; A package installed into an Emacs that is already running takes the
;; place of nothing.  If the session has loaded the `compat' that Emacs
;; ships and is then given the one from ELPA, it still counts `compat' as
;; loaded.  Two things follow, and both happened: the first call into what
;; only the new library defines fails until Emacs is restarted, and a
;; package installed after it is compiled against the old macros and is
;; wrong on disk from then on.
;;
;; `genie-packages-reload-shadowed' loads again what a package now
;; provides in place of what was loaded.  The session calls it when a wish
;; has brought packages; the Emacs that validates a wish, where they are
;; installed, calls it after each one (`genie-packages-settle-installs').

;;; Code:

(require 'package)

(defun genie-packages-reload-shadowed (&rest _)
  "Load again each library an installed package now provides in its place."
  (dolist (entry load-history)
    (when-let* ((was (car entry))
                (feature (cdr (assq 'provide (cdr entry))))
                (now (locate-library (symbol-name feature)))
                ((file-in-directory-p now package-user-dir))
                ((not (file-in-directory-p was package-user-dir))))
      (with-demoted-errors "Genie: %S" (load now nil t)))))

(defun genie-packages-mend-broken (&rest _)
  "Install again each package that was left half unpacked.
One whose install was interrupted has its files and no autoloads: it
counts as installed, so nothing installs it again, and it cannot be
loaded, so everything that needs it fails from then on."
  (dolist (entry package-alist)
    (when-let* ((desc (cadr entry))
                (dir (package-desc-dir desc))
                ((stringp dir))
                ((file-in-directory-p dir package-user-dir))
                ((not (file-exists-p
                       (expand-file-name (format "%s-autoloads.el" (car entry))
                                         dir)))))
      (with-demoted-errors "Genie: %S" (package-reinstall (car entry))))))

(defun genie-packages-settle-installs ()
  "Have each package installed from now on replace at once what it shadows.
The ones installed after it are then compiled against what it defines.
What an earlier, interrupted install left broken is first installed
again."
  (advice-add 'package-initialize :after #'genie-packages-mend-broken)
  (advice-add 'package-unpack :after #'genie-packages-reload-shadowed))

(provide 'genie-packages)
;;; genie-packages.el ends here
