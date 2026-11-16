# Install testslot.
#   make install                                  one account: a copy in ~/.local/bin and the state folder ~/.testslot
#   sudo make install-shared GROUP=<group>        one gate for many accounts: the shared state folder, given to a group
# PREFIX, STATE and SHARED can be changed (the tests install into a scratch folder this way).
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
STATE  ?= $(HOME)/.testslot
# the folder testslot itself uses when TESTSLOT_DIR is unset
SHARED ?= $(shell if [ "$$(uname -s)" = Darwin ]; then echo /Users/Shared/testslot; else echo /var/lib/testslot; fi)
HERE   := $(dir $(lastword $(MAKEFILE_LIST)))

.PHONY: install install-shared

# Safe to run twice: the copy is overwritten, mkdir -p keeps the folders, and the output is the same.
install:
	@mkdir -p "$(BINDIR)" "$(STATE)/holders" "$(STATE)/logs"
	@install -m 755 "$(HERE)testslot" "$(BINDIR)/testslot"
	@echo "Installed testslot in $(BINDIR) and made the state folder $(STATE)."
	@echo "Add this line to your shell profile (and run it now to use testslot in this shell):"
	@echo 'export PATH="$(BINDIR):$$PATH" TESTSLOT_DIR="$(STATE)"'

install-shared:
ifndef GROUP
	$(error usage: sudo make install-shared GROUP=<group> [SHARED=<folder>])
endif
	@mkdir -p "$(SHARED)/holders" "$(SHARED)/logs"
	@chgrp -R "$(GROUP)" "$(SHARED)"
	@chmod -R g+rws "$(SHARED)"
	@echo "Made the shared state folder $(SHARED) for the group $(GROUP)."
	@echo "Each account adds this line to its shell profile:"
	@echo 'export TESTSLOT_DIR="$(SHARED)"'
