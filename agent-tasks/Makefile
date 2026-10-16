EMACS ?= emacs
# Spacemacs keeps packages under elpa/<emacs-version>/<branch>/; prefer the
# directory of the Emacs that runs the tests.
EMACS_VERSION := $(shell $(EMACS) -Q --batch --eval \
  '(princ (format "%d.%d" emacs-major-version emacs-minor-version))')
PERSP ?= $(lastword $(sort \
  $(or $(wildcard $(HOME)/.emacs.d/elpa/$(EMACS_VERSION)/*/persp-mode-*/), \
       $(wildcard $(HOME)/.emacs.d/elpa/*/*/persp-mode-*/))))

.PHONY: install test test-el test-ts test-install

install:
	./install.sh

test: test-el test-ts test-install

test-el:
	@test -n "$(PERSP)" || { echo "persp-mode not found; pass PERSP=dir" >&2; exit 1; }
	$(EMACS) -Q --batch -L . -L $(PERSP) -l test/agent-tasks-test.el \
	  -f ert-run-tests-batch-and-exit < /dev/null

test-ts:
	node --test pi/spawn-task/

test-install:
	sh test/install-test.sh
