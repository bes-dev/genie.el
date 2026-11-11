#!/usr/bin/env bash
# Bootstrap an ~/.emacs.d that contains genie and nothing else.
#
#   curl -fsSL https://raw.githubusercontent.com/bes-dev/genie.el/main/bootstrap.sh | bash
#
# Creates the directory (refusing to touch an existing config), writes a
# minimal init.el and the first wish — genie on C-c g — and makes the
# directory a git repository: every wish is a commit, so the root must be one.
# Override the target with EMACS_D=/path.

set -euo pipefail

EMACS_D="${EMACS_D:-$HOME/.emacs.d}"

# Emacs reads the first of these it finds, so a config in any of them is a
# living one — and a new ~/.emacs.d would be read instead of ~/.config/emacs.
if [ -e "$EMACS_D/init.el" ] || [ -e "$HOME/.emacs" ] || [ -e "$HOME/.emacs.el" ] ||
   { [ "$EMACS_D" = "$HOME/.emacs.d" ] && [ -e "${XDG_CONFIG_HOME:-$HOME/.config}/emacs" ]; }; then
  echo "genie: an Emacs configuration already exists here — refusing to touch a living config." >&2
  echo "genie: to try the empty-lamp experiment anyway: EMACS_D=/tmp/lamp $0 && emacs --init-directory /tmp/lamp" >&2
  exit 1
fi

command -v git >/dev/null || { echo "genie: git is required." >&2; exit 1; }
command -v emacs >/dev/null || { echo "genie: emacs not found on PATH." >&2; exit 1; }
emacs --batch --eval '(kill-emacs (if (< emacs-major-version 29) 1 0))' ||
  echo "genie: warning — this init.el uses package-vc-install (Emacs 29+); on 28 clone the repo and use load-path instead." >&2
command -v elmee >/dev/null ||
  echo "genie: warning — elmee is not on PATH; install it from https://github.com/bes-dev/elmee." >&2

mkdir -p "$EMACS_D/wishes"
cat > "$EMACS_D/init.el" <<'EOF'
;;; init.el --- An empty lamp -*- lexical-binding: t; -*-

;;; Commentary:
;; Genie and nothing else.  Everything this Emacs will ever do arrives as
;; a wish (C-c g g): a file under wishes/ that is validated, committed and
;; can be switched off again in `genie-lamp'.  `git log' is its biography.

;;; Code:

(require 'package)
(unless (bound-and-true-p package--initialized) (package-initialize))

;; The genie itself, straight from the repository (Emacs 29+).
(unless (package-installed-p 'genie)
  (package-vc-install "https://github.com/bes-dev/genie.el"))

;; Wishes apply as soon as they validate — judge them in the editor, take
;; them back with C-c g u.  See `genie-confirm' for the ceremonies.
(setq genie-confirm '(risky-code))

;; Wishes granted by genie: each a file of its own that can be taken back.
(require 'genie-wish)
(genie-wish-load)

;;; init.el ends here
EOF

cat > "$EMACS_D/wishes/genie-keys.el" <<'EOF'
;;; genie-keys.el --- the first wish -*- lexical-binding: t; -*-

(autoload 'genie-command-map "genie" nil t 'keymap)

(genie-wish genie-keys
  "Genie on C-c g: g a wish, c its chat, l the lamp, u undo."
  (genie-key global-map "C-c g" 'genie-command-map))
EOF

# What Emacs writes for itself is not configuration, and not git's to keep.
cat > "$EMACS_D/.gitignore" <<'EOF'
# What Emacs and its packages write for themselves; not configuration.
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
\#*#
EOF

# Wishes are commits: the config root must be a git repository.
git -C "$EMACS_D" init -q
git -C "$EMACS_D" add .gitignore init.el wishes/genie-keys.el
git -C "$EMACS_D" commit -qm "genie: an empty lamp" ||
  git -C "$EMACS_D" -c user.name=genie -c user.email=genie@localhost \
      commit -qm "genie: an empty lamp"

cat <<EOF
genie: lamp ready at $EMACS_D

Next:
  1. Make sure elmee is installed: https://github.com/bes-dev/elmee
  2. Launch Emacs. The first start installs genie from GitHub.
  3. Rub the lamp: C-c g g — and C-c g l shows what you have wished for.
EOF
