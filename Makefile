EMACS ?= emacs
FILES  = genie-wish.el genie-acp.el genie-follow.el genie-live.el genie-tools.el \
         genie-markdown.el genie-chat.el genie-sessions.el \
         genie-validate.el genie-packages.el genie-trail.el genie-pipeline.el genie-spell.el genie-habits.el genie-lamp.el genie.el

.PHONY: all compile checkdoc test lint clean

all: compile checkdoc test

compile: clean
	$(EMACS) -Q --batch -L . \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(FILES)

checkdoc:
	$(EMACS) -Q --batch -l scripts/checkdoc.el $(FILES)

test:
	$(EMACS) -Q --batch -L . -l test/genie-tests.el \
	  -f ert-run-tests-batch-and-exit

# Needs network access: installs package-lint from MELPA into a temp dir.
lint:
	$(EMACS) -Q --batch \
	  --eval "(progn \
	    (require 'package) \
	    (setq package-user-dir (make-temp-file \"genie-lint\" t)) \
	    (push '(\"melpa\" . \"https://melpa.org/packages/\") package-archives) \
	    (package-initialize) \
	    (package-refresh-contents) \
	    (package-install 'package-lint))" \
	  -L . -f package-lint-batch-and-exit $(FILES)

clean:
	rm -f *.elc test/*.elc
