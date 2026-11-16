#!/usr/bin/env bash
# guard.sh: refuse a tracked testslot file that names one of the owner's private words (a host, a path, a network name). The
# words live in a file outside the repo, one per line (blank lines and lines starting with # are skipped), named by
# GUARD_WORDS (an absolute path: the script changes folder before it reads it); agent-tools' `make guard` passes local.mk's
# PRIVATE_WORDS. A word matches as a whole word, exactly as written (case counts), in every tracked text file under
# testslot/ as it is in the working tree. The words are not kept here: a word that is private cannot sit in a public file.
# It sits in testslot/tools so it travels with testslot's export, and it searches the folder above it (testslot/).
# Without a list it says so on stderr and passes, unless GUARD_REQUIRE_WORDS is set (make release sets it), when a missing
# list is an error: a release has to check. A GUARD_WORDS that names no readable file is an error either way.
# Exit 0 clean, 1 a hit (or a required list missing), 2 a list it cannot read or a search that failed. It reads the tree as it
# is now, not the history.
# Written for bash 3.2 and up.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
list=${GUARD_WORDS:-}
if [ -z "$list" ]; then
  if [ -n "${GUARD_REQUIRE_WORDS:-}" ]; then echo "guard: no private-word list; set PRIVATE_WORDS in local.mk, a release has to check one" >&2; exit 1; fi
  echo "guard: no private-word list, so no word was checked (PRIVATE_WORDS in local.mk names one)" >&2; exit 0
fi
[ -r "$list" ] && [ -f "$list" ] || { echo "guard: can't read the private-word list $list" >&2; exit 2; }
pat=$(mktemp) || exit 2; trap 'rm -f "$pat"' EXIT
# a list edited elsewhere may have CRs or padding; either would make a word that matches nothing
tr -d '\r' < "$list" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -vE '^(#|$)' > "$pat"
[ -s "$pat" ] || { echo "guard: $list holds no words" >&2; exit 2; }
hits=$(git grep -n -I -w -F -f "$pat" 2>&1); st=$?
case $st in
  0) echo "guard: a tracked file names a private word:" >&2
     printf '%s\n' "$hits" | cut -c1-200 | sed 's/^/  /' >&2; exit 1 ;;
  1) echo "guard: clean" ;;
  *) echo "guard: git grep failed (status $st), so nothing was checked: $(printf '%s' "$hits" | head -c 200)" >&2; exit 2 ;;
esac
