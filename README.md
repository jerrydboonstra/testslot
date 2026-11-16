<img src="images/logo.png" alt="A wooden tray of four round slots, three holding balls, with a ramp feeding a red ball into the empty fourth." width="320">

# testslot

A test gate for one machine. Several people, agents or CI jobs can run test suites on the same host, and `testslot` makes each run wait its turn: a run starts only when its declared cpus are free under a cpu cap and the host's load is under a load cap.

## What it is

`testslot run --cpus 4 -- make test` waits until 4 cpus are free under the cap and the host's 1-minute load is under the load cap, then runs the command and prints its output as usual. It returns the command's exit code.

A run declares its cpus. testslot waits for them and checks the load before it starts, but it does not limit what the command then uses, and `--cpus` does not set the command's own parallelism (pass that to the command, for example `make -j4`).

Accounts share one gate only when they use the same state folder: the default (`/var/lib/testslot` on Linux, `/Users/Shared/testslot` on macOS) or one `TESTSLOT_DIR` that all of them set. The gate is cooperative: it queues programs that use `testslot run`, and counts other work only through the load.

## What you need

- Python 3.9 or newer and a Unix host (Linux or macOS). `testslot` is one file with no packages to install. The 3.9 minimum comes from a static check of the file with [vermin](https://github.com/netromdk/vermin), and `testslot run` and `testslot status` were run on Python 3.9.6.
- A folder for the gate's state that every account using it can write to.

## Install

Get the repository and enter it:

```sh
git clone https://github.com/jerrydboonstra/testslot
cd testslot
```

Then copy the `testslot` file onto your `PATH` and make a state folder. A copy, not a link into a checkout, keeps a running gate from changing when you switch branches.

```sh
mkdir -p ~/.local/bin && install -m 755 testslot ~/.local/bin/testslot   # any folder on your PATH works
export PATH="$HOME/.local/bin:$PATH"       # needed if that folder is not on your PATH yet (it is not, by default, on macOS)
export TESTSLOT_DIR=$HOME/.testslot        # the state folder; any folder you own works
mkdir -p "$TESTSLOT_DIR/holders" "$TESTSLOT_DIR/logs"
```

This is a gate for one account. `testslot` does not create the state folder, and exits with a "not set up" message when it is missing. `holders/` keeps one small file for each run that is going or waiting (what `status` reads), and `logs/` keeps each run's output. Put both `export` lines in your shell profile so every shell sees them. With `TESTSLOT_DIR` unset the default is `/var/lib/testslot` on Linux (making it needs root), and `/Users/Shared/testslot` on macOS.

To share one gate between accounts, make one shared folder, give it to a group they all belong to, and point every account at it (on Linux; on macOS use `/Users/Shared/testslot` and no `sudo`):

```sh
sudo mkdir -p /var/lib/testslot/holders /var/lib/testslot/logs
sudo chgrp -R <group> /var/lib/testslot
sudo chmod -R g+rws /var/lib/testslot
export TESTSLOT_DIR=/var/lib/testslot      # in each account's shell profile
```

Check the install with a smoke test of the installed command:

```sh
command -v testslot                  # prints where the installed copy is
testslot run --cpus 1 -- echo ok     # prints a "light run, 1 cpus" line, then: ok
```

The repository's own tests are separate: `bash test.sh ./testslot`, run from the repository folder, tests the checkout's copy of `testslot`, not the installed one. On a shared host, run them through the gate (`testslot run --cpus 2 -- bash test.sh ./testslot`).

## Usage

```sh
testslot run --cpus 4 -- make test      # wait for 4 cpus, then run
testslot run --track -- ./long-api-job  # listed, but reserves no cpus in the gate
testslot run --heavy -- ./big-build     # the whole cap to itself
testslot status                         # who holds cpus, who waits and why
testslot summary --since 12h            # recent runs from the history file
testslot stop <pgid>                    # stop a run by the group id status shows
testslot suggest --default 2 -- make test   # cpus the last run of this command peaked at
```

Declare the cpus your command really uses (for `make`, its `-j`). The default is 1. A run that asks for more cpus than the cap gets the cap, so it still starts on a small host. `status` and `summary` read the state folder: `history.jsonl` there holds one line per finished run, and `suggest` reads each run's peak cpu use from it.

### How runs are scheduled

- Smaller runs may start ahead of a bigger one that is waiting (backfill), but a long wait for the bigger one reserves cpus for it, so it cannot starve.
- A run that would start ahead of a waiting one needs a time limit (`--max-minutes N`), so it cannot hold the queue up for long. Without one it simply waits its turn. A normal run needs no limit.
- A run pauses itself for up to 3 seconds at a time if the host is starting processes faster than a start-rate cap.
- An internal failure prints `testslot error: ...` on stderr and exits `70` if the command has not already finished. The docstring lists the exit codes.

### Settings

Settings are read from files in the state folder; environment variables are used when those files are missing or invalid. A setting file holds one number, for example `echo 6 > "$TESTSLOT_DIR/cap"` caps the gate at 6 cpus.

| Setting | File | Variable | Default |
|---|---|---|---|
| cpu cap | `cap` | `TESTSLOT_CAP` | `max(1, round(cores * 0.8))` |
| load cap | `load-cap` | `TESTSLOT_LOAD_CAP` | the cpu cap |
| start-rate cap (process starts a second) | `start-rate-cap` | `TESTSLOT_START_RATE_CAP` | none |
| reservation wait, in seconds | `reserve` | `TESTSLOT_RESERVE` | 600 |
| longest backfill, in minutes | `backfill-limit` | `TESTSLOT_BACKFILL_LIMIT` | 30 |
| idle-shrink wait, in seconds | `shrink-after` | `TESTSLOT_SHRINK_AFTER` | 600 |
| idle-shrink margin, in cpus | `shrink-margin` | `TESTSLOT_SHRINK_MARGIN` | 1 |

- Reservation wait: how long the run at the head of the queue waits before the queue reserves cpus for it and nothing passes it.
- Longest backfill: the longest time limit a run may carry to start ahead of a waiting run.
- Idle shrink (Linux only, for light runs; a `--heavy` or `--track` run, and any run on macOS, never shrinks): a run whose real cpu use stays under what it declared for the wait is charged only what it uses plus the margin, so an idle 8-cpu run frees most of its cpus for waiting runs.

## Specification

The full interface, every setting and every exit code are in the docstring at the top of the [`testslot`](./testslot) file. [`spec/README.md`](./spec/README.md) describes a TLA+ model (a formal model checked by machine) of the admission rules and what checking it found.

## License

MIT. See [LICENSE](./LICENSE).
