# Install testslot.
#   make install                                  one account: the code in ~/.local/lib, a link in ~/.local/bin, and the state folder ~/.testslot
#   sudo make install-shared GROUP=<group>        one gate for many accounts: the shared state folder, given to a group
# PREFIX, STATE and SHARED can be changed (the tests install into a scratch folder this way).
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
STATE  ?= $(HOME)/.testslot
# the code goes into a folder here, testslot-<hash of the code>, and BINDIR/testslot is a link to its entry script
LIBROOT ?= $(PREFIX)/lib
# the folder testslot itself uses when TESTSLOT_DIR is unset
SHARED ?= $(shell if [ "$$(uname -s)" = Darwin ]; then echo /Users/Shared/testslot; else echo /var/lib/testslot; fi)
HERE   := $(dir $(lastword $(MAKEFILE_LIST)))

.PHONY: install install-shared

# The code is copied into a new folder, LIBROOT/testslot-<hash of the code>, built under a temporary name and renamed into
# place, so no run ever sees a half-copied folder and a folder a run may be using is never written to. Then BINDIR/testslot
# (a link to that folder's entry script) is replaced by one rename, which also replaces an old single-file install in the
# same step. Folders older than the one before the current one are removed; that one stays for a run that read the old
# link a moment before the swap and has not imported yet. Safe to run twice: a second run finds the folder and the link
# already there, changes nothing, and prints the same lines.
install:
	@mkdir -p "$(BINDIR)" "$(LIBROOT)" "$(STATE)/holders" "$(STATE)/logs"
	@set -e; \
	h=$$(cat "$(HERE)testslot" "$(HERE)"lib/testslot/*.py | python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])'); \
	dest="$(LIBROOT)/testslot-$$h"; link="$(BINDIR)/testslot"; \
	old=$$(readlink "$$link" 2>/dev/null || true); \
	if [ ! -d "$$dest" ]; then \
	  tmp="$(LIBROOT)/.testslot-tmp-$$$$"; mkdir -p "$$tmp/lib/testslot"; \
	  install -m 755 "$(HERE)testslot" "$$tmp/testslot"; cp "$(HERE)"lib/testslot/*.py "$$tmp/lib/testslot/"; \
	  mv "$$tmp" "$$dest"; \
	fi; \
	if [ "$$old" != "$$dest/testslot" ]; then \
	  ln -s "$$dest/testslot" "$(BINDIR)/.testslot-link-$$$$"; mv -f "$(BINDIR)/.testslot-link-$$$$" "$$link"; \
	  olddir=$$(dirname "$$old"); \
	  for d in "$(LIBROOT)"/testslot-????????????; do \
	    [ -f "$$d/testslot" ] || continue; [ "$$d" = "$$dest" ] && continue; [ "$$d" = "$$olddir" ] && continue; rm -rf "$$d"; \
	  done; \
	fi
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
