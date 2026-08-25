#!/usr/bin/env bash
# Bootstrap an ~/.emacs.d that contains genie and nothing else.
#
#   curl -fsSL https://raw.githubusercontent.com/bes-dev/genie.el/main/bootstrap.sh | bash
#
# Creates the directory (refusing to touch an existing config), writes the
# minimal init.el from the README, and makes the directory a git repository —
# genie's wish pipeline commits every change, so the config root must be one.
# Override the target with EMACS_D=/path.

set -euo pipefail

EMACS_D="${EMACS_D:-$HOME/.emacs.d}"

if [ -e "$EMACS_D/init.el" ] || [ -e "$HOME/.emacs" ]; then
  echo "genie: $EMACS_D/init.el (or ~/.emacs) already exists — refusing to touch a living config." >&2
  echo "genie: to try the empty-lamp experiment anyway: EMACS_D=/tmp/lamp $0 && emacs --init-directory /tmp/lamp" >&2
  exit 1
fi

command -v git >/dev/null || { echo "genie: git is required." >&2; exit 1; }
command -v emacs >/dev/null || { echo "genie: emacs not found on PATH." >&2; exit 1; }
emacs --batch --eval '(kill-emacs (if (< emacs-major-version 29) 1 0))' ||
  echo "genie: warning — this init.el uses package-vc-install (Emacs 29+); on 28 clone the repo and use load-path instead." >&2
command -v elmee >/dev/null || command -v pi >/dev/null ||
  echo "genie: warning — no agent backend on PATH; install elmee (https://github.com/bes-dev/elmee) or Pi (https://github.com/badlogic/pi-mono)." >&2

mkdir -p "$EMACS_D"
cat > "$EMACS_D/init.el" <<'EOF'
;;; init.el --- All you need -*- lexical-binding: t; -*-

;;; Commentary:
;; An empty lamp: genie and nothing else.  Everything this config will
;; ever contain arrives as a wish (C-c g g), validated, reviewed and
;; committed — `git log' is its biography.

;;; Code:

(require 'package)
(unless (bound-and-true-p package--initialized) (package-initialize))

;; The genie itself, straight from the repository (Emacs 29+).
(unless (package-installed-p 'genie)
  (package-vc-install "https://github.com/bes-dev/genie.el"))
(require 'genie)

;; Wishes apply as soon as they validate — judge them in the editor,
;; take them back with C-c g u.  See `genie-confirm' for the ceremonies.
(setq genie-confirm '(risky-spell))

;; The lamp's controls.
(global-set-key (kbd "C-c g g") #'genie)         ; state a wish
(global-set-key (kbd "C-c g c") #'genie-chat)    ; multi-turn chat
(global-set-key (kbd "C-c g d") #'genie-diff)    ; review the pending diff
(global-set-key (kbd "C-c g u") #'genie-undo)    ; revert the last wish
(global-set-key (kbd "C-c g k") #'genie-abort)   ; abort the turn in flight
(global-set-key (kbd "C-c g s") #'genie-spell)   ; conjure an ephemeral command
(global-set-key (kbd "C-c g x") #'genie-cast)    ; cast the current spell
(global-set-key (kbd "C-c g !") #'genie-cantrip) ; one-shot: conjure and run here
(global-set-key (kbd "C-c g m") #'genie-manual)  ; the manual, grown wish by wish
(dotimes (i 10)                                  ; ten programmable spell registers
  (global-set-key (kbd (format "C-c g %d" i)) #'genie-cast-register))

;;; init.el ends here
EOF

# Wishes are commits: the config root must be a git repository.
git -C "$EMACS_D" init -q
git -C "$EMACS_D" add init.el
git -C "$EMACS_D" commit -qm "init: an empty lamp" ||
  git -C "$EMACS_D" -c user.name=genie -c user.email=genie@localhost \
      commit -qm "init: an empty lamp"

cat <<EOF
genie: lamp ready at $EMACS_D

Next:
  1. Make sure an agent backend is installed (elmee by default; for Pi:
     add (setq genie-backend 'pi) to init.el — or wish it in later).
  2. Launch Emacs. The first start installs genie from GitHub.
  3. Rub the lamp: C-c g g — and don't waste wishes on trifles.
EOF
