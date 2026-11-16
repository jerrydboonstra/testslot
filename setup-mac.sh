#!/usr/bin/env bash
# Set testslot up on the Mac: small test runs here while
# the Linux host is full, never enough to pin the Mac. Run it only with the machine owner's go for the install.
#
#   bash setup-mac.sh   (from this folder)
#
# This script creates /Users/Shared/testslot for state (no sudo, any local
# account can share the gate). Cap 6 cpus; every run waits while the 1-minute load is 10 or more
# (12 cores, and the herd sessions alone keep the load high), and a run pauses itself while the
# host starts over 120 processes a second (the Mac hung at 200 to 340). The command is a copy of the package, not a
# link into this repo, so an edit here goes live only by running this again.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo "setup-mac.sh: this is for the Mac; a Linux host uses its own provisioning script" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
# TESTSLOT_MAC_DIR is for tests, which run this into a scratch state folder and a scratch HOME
dir="${TESTSLOT_MAC_DIR:-/Users/Shared/testslot}"
# /Users/Shared is world-writable: a folder or file someone else made first is refused, never adopted,
# and nothing here follows a planted symlink. The folder stays group-writable (every local account is
# in staff) because any account prunes another's dead holders; the gate is cooperative, as on a Linux host.
# cap, load-cap and start-rate-cap are 644, which stops edits but not replacement (the folder is shared): another
# account could still swap them. testslot never follows a link in this folder or widens a file it
# doesn't own.
for p in "$dir" "$dir/holders" "$dir/logs" "$dir/cap" "$dir/load-cap" "$dir/start-rate-cap" "$dir/history.jsonl"; do
    if [ -L "$p" ] || { [ -e "$p" ] && [ ! -O "$p" ]; }; then
        echo "setup-mac.sh: $p is a symlink or belongs to another account; move it aside and rerun" >&2
        exit 1
    fi
done
mkdir -p "$dir/holders" "$dir/logs"
# a new folder takes the group of the one that holds it, and /Users/Shared is root:wheel, so name staff
# (every local account is in it); files made inside later take the folder's group, staff
chgrp staff "$dir" "$dir/holders" "$dir/logs"
chmod 2775 "$dir" "$dir/holders" "$dir/logs"
# the defaults go in when a file is missing or empty; a number already there is kept
[ -s "$dir/cap" ] || echo 6 > "$dir/cap"
[ -s "$dir/load-cap" ] || echo 10 > "$dir/load-cap"
[ -s "$dir/start-rate-cap" ] || echo 120 > "$dir/start-rate-cap"
touch "$dir/history.jsonl"
chgrp staff "$dir/cap" "$dir/load-cap" "$dir/start-rate-cap" "$dir/history.jsonl"
chmod 644 "$dir/cap" "$dir/load-cap" "$dir/start-rate-cap"
chmod 664 "$dir/history.jsonl"
# the package (the entry script and lib/testslot) goes in by testslot's own make install: a testslot-<hash> folder under
# ~/.local/lib and a link in ~/.local/bin, swapped by one rename, so a run using the old copy is never written to
make -s -C "$here" install PREFIX="$HOME/.local" STATE="$dir" >/dev/null
echo "folder $(stat -f '%Su:%Sg %Lp' "$dir"), history $(stat -f '%Su:%Sg %Lp' "$dir/history.jsonl")"
echo "installed $HOME/.local/bin/testslot -> $(readlink "$HOME/.local/bin/testslot"); state in $dir, cap $(cat "$dir/cap"), load-cap $(cat "$dir/load-cap"), start-rate-cap $(cat "$dir/start-rate-cap")"
TESTSLOT_DIR="$dir" "$HOME/.local/bin/testslot" status | head -2
