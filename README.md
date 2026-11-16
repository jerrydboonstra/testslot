<img src="images/logo.png" alt="A wooden tray of four round slots, three holding balls, with a ramp feeding a red ball into the empty fourth." width="320">

# testslot

A test gate for one machine. Several people, agents or CI jobs can run test suites on the same host, and `testslot` makes each run wait its turn so together they stay inside a cpu budget and a load limit.

## What it is

`testslot run --cpus 4 -- make test` waits until 4 cpus are free under the cap and the host's 1-minute load is under the load cap, then runs the command and prints its output as usual. A run returns the command's exit code. An internal failure prints `testslot error: ...` on stderr and exits `70` if the command has not already finished; the docstring lists the exit codes. Smaller runs may start ahead of a bigger one that is waiting, but a long wait for the bigger one reserves cpus for it, so it cannot starve. A run that would start ahead of a waiting one needs a time limit (`--max-minutes N`), so it cannot hold the queue up for long; without one it simply waits its turn. A normal run needs no limit. A run also pauses itself for up to 3 seconds at a time if the host is starting processes faster than a start-rate cap.

Every account on the host shares one gate. The gate is cooperative: it queues programs that use `testslot run`, and counts other work only through the load.

## What you need

- A recent Python 3 and a Unix host (Linux or macOS). `testslot` is one file with no packages to install.
- A folder for the gate's state that every account using it can write to.

## Install

From this folder, copy the `testslot` file onto your `PATH` and make a state folder. A copy, not a link into a checkout, keeps a running gate from changing when you switch branches.

```sh
mkdir -p ~/.local/bin && install -m 755 testslot ~/.local/bin/testslot   # any folder on your PATH works
export PATH="$HOME/.local/bin:$PATH"       # needed if that folder is not on your PATH yet (it is not, by default, on macOS)
export TESTSLOT_DIR=$HOME/.testslot        # the state folder; any folder you own works
mkdir -p "$TESTSLOT_DIR/holders" "$TESTSLOT_DIR/logs"
```

`testslot` does not create the state folder, and exits with a "not set up" message when it is missing. Put both `export` lines in your shell profile so every shell sees them. With `TESTSLOT_DIR` unset the default is `/var/lib/testslot` on Linux (making it needs root), and a shared folder on macOS.

To share one gate between accounts, use a shared folder (for example `/var/lib/testslot`), give it to a group they all belong to (`chgrp -R <group>` and `chmod -R g+rws`), and set the same `TESTSLOT_DIR` for each account.

Settings are read from files in the state folder; environment variables are used when those files are missing or invalid:

| Setting | File | Variable | Default |
|---|---|---|---|
| cpu cap | `cap` | `TESTSLOT_CAP` | `max(1, round(cores * 0.8))` |
| load cap | `load-cap` | `TESTSLOT_LOAD_CAP` | the cpu cap |
| start-rate cap (process starts a second) | `start-rate-cap` | `TESTSLOT_START_RATE_CAP` | none |
| reservation wait, in seconds | `reserve` | `TESTSLOT_RESERVE` | 600 |
| longest backfill, in minutes | `backfill-limit` | `TESTSLOT_BACKFILL_LIMIT` | 30 |
| idle-shrink wait, in seconds | `shrink-after` | `TESTSLOT_SHRINK_AFTER` | 600 |
| idle-shrink margin, in cpus | `shrink-margin` | `TESTSLOT_SHRINK_MARGIN` | 1 |

To check the install, run the tests from this folder: `bash test.sh ./testslot`. Run them through the gate itself (`testslot run --cpus 2 -- bash test.sh ./testslot`) on a shared host.

## Usage

```sh
testslot run --cpus 4 -- make test      # wait for 4 cpus, then run
testslot run --track -- ./long-api-job  # listed, but takes no cpus
testslot run --heavy -- ./big-build     # the whole cap to itself
testslot status                         # who holds cpus, who waits and why
testslot summary --since 12h            # recent runs from the history file
testslot stop <pgid>                    # stop a run by the group id status shows
testslot suggest --default 2 -- make test   # cpus the last run of this command peaked at
```

Declare the cpus your command really uses (for `make`, its `-j`). The default is 1. A run that asks for more cpus than the cap gets the cap, so it still starts on a small host. `status` and `summary` read the state folder: `history.jsonl` there holds one line per finished run, and `suggest` reads each run's peak cpu use from it.

## Specification

The full interface, every setting and every exit code are in the docstring at the top of the `testslot` file. `spec/README.md` describes a TLA+ model (a formal model checked by machine) of the admission rules and what checking it found.

## License

MIT. See [LICENSE](./LICENSE).
