EMACS ?= emacs
# Spacemacs keeps packages under elpa/<emacs-version>/<branch>/; prefer the
# directory of the Emacs that runs the tests.
EMACS_VERSION := $(shell $(EMACS) -Q --batch --eval \
  '(princ (format "%d.%d" emacs-major-version emacs-minor-version))')
PERSP ?= $(lastword $(sort \
  $(or $(wildcard $(HOME)/.emacs.d/elpa/$(EMACS_VERSION)/*/persp-mode-*/), \
       $(wildcard $(HOME)/.emacs.d/elpa/*/*/persp-mode-*/))))
# Optional: evil (and its goto-chg dependency) enables the evil key tests.
ELPA_DIR := $(patsubst %/,%,$(dir $(patsubst %/,%,$(PERSP))))
EVIL_PATHS := $(foreach p,$(lastword $(sort $(wildcard $(ELPA_DIR)/evil-[0-9]*/))) \
  $(lastword $(sort $(wildcard $(ELPA_DIR)/goto-chg-*/))),-L $(p))

.PHONY: install test test-el test-ts test-install

install:
	./install.sh

test: test-el test-ts test-install

test-el:
	@test -n "$(PERSP)" || { echo "persp-mode not found; pass PERSP=dir" >&2; exit 1; }
	$(EMACS) -Q --batch -L . -L $(PERSP) $(EVIL_PATHS) -l test/agent-tasks-test.el \
	  -f ert-run-tests-batch-and-exit < /dev/null

test-ts:
	node --test pi/spawn-task/

test-install:
	sh test/install-test.sh
