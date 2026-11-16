<img src="images/logo.png" alt="A wooden tray of four round slots, three holding balls, with a ramp feeding a red ball into the empty fourth." width="320">

# testslot

A test gate for one machine. Several people, agents or CI jobs can run test suites on the same host, and `testslot` makes each run wait its turn: a run waits until the cpus it declares are free under a cpu cap (a request larger than the cap is cut to the cap) and the host's load is under a load cap.

## What it is

`testslot run --cpus 4 -- make -j4 test` waits until 4 cpus are free under the cap and the host's 1-minute load is under the load cap, then runs the command and prints its output as usual. It returns the command's exit code.

A run declares its cpus. testslot waits for them and checks the load before it starts, but it does not limit what the command then uses, and `--cpus` does not set the command's own parallelism (pass that to the command, as `-j4` does above).

Accounts share one gate only when they use the same state folder: the default (`/var/lib/testslot` on Linux, `/Users/Shared/testslot` on macOS) or one `TESTSLOT_DIR` that all of them set. The gate is cooperative: it queues programs that use `testslot run`, and counts other work only through the load.

## What you need

- Python 3.9 or newer and a Unix host (Linux or macOS). `testslot` is one file with no packages to install. The 3.9 minimum comes from a static check of the file with [vermin](https://github.com/netromdk/vermin), and `testslot run` and `testslot status` were run on Python 3.9.6. The full test suite (`bash test.sh ./testslot`) passed on macOS (Darwin 25.6.0) with Python 3.15.2 and on Ubuntu 26.04 (Linux 7.3.1) with Python 3.14.4; it has not been run on other systems or on Python 3.9.
- A folder for the gate's state that every account using it can write to.
- To run the repository's own tests on macOS: GNU `timeout`, which macOS does not have. `brew install coreutils` installs it as `gtimeout`, so link it into a folder on your `PATH` (the Install section below makes `~/.local/bin` and puts it there): `mkdir -p ~/.local/bin && ln -s "$(brew --prefix coreutils)/bin/gtimeout" ~/.local/bin/timeout`. Nothing else is needed: with only that link, the suite passed in a clean macOS shell (the system `/bin/bash` 3.2.57 and system Python 3.9.6) with no failures; `setsid` is not needed: macOS lacks it too, and of the two cases that use it, one skips itself and the other (a `setsid` daemon that must not keep the slot) passes without testing `setsid`. Linux already has `timeout`.

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

This is a gate for one account. `testslot` does not create the state folder, and exits with a "not set up" message when it is missing. `holders/` keeps one small file for each run that is going or waiting (what `status` reads), and `logs/` keeps each run's output. Put both `export` lines in your shell profile so every interactive shell sees them. A shell profile does not reach CI or other non-interactive jobs: set `PATH` and `TESTSLOT_DIR` in the job's own environment, for example at the top of the job script (see below). With `TESTSLOT_DIR` unset the default is `/var/lib/testslot` on Linux (making it needs root), and `/Users/Shared/testslot` on macOS.

To share one gate between accounts, make one shared folder, give it to a group they all belong to, and point every account at it (on Linux; on macOS use `/Users/Shared/testslot` and no `sudo`):

```sh
group=testers                              # replace with your group
sudo mkdir -p /var/lib/testslot/holders /var/lib/testslot/logs
sudo chgrp -R "$group" /var/lib/testslot
sudo chmod -R g+rws /var/lib/testslot
export TESTSLOT_DIR=/var/lib/testslot      # in each account's shell profile
```

A CI job usually runs as its own account, and `~/.local/bin` is per account, so `testslot` must be installed for that account. Either run the install lines above as the CI account (the file goes into that account's own `~/.local/bin`), or put one copy where every account's `PATH` reaches, for example `sudo install -m 755 testslot /usr/local/bin/testslot` (then the `PATH` line below is not needed). In the job itself, set the state folder and call `testslot`. To gate against other accounts on the host, point the job at the shared folder from the recipe above (the CI account must be in its group):

```sh
export PATH="$HOME/.local/bin:$PATH"       # only when testslot is in the CI account's own ~/.local/bin
export TESTSLOT_DIR=/var/lib/testslot
testslot run --cpus 2 -- make -j2 test
```

A per-account folder such as `$HOME/.testslot` gates only that account, and must be made first.

Check the install with a smoke test of the installed command:

```sh
command -v testslot                  # prints where the installed copy is
testslot run --cpus 1 -- echo ok     # prints a "light run, 1 cpus" line, then: ok
```

The repository's own tests are separate (on macOS, link `timeout` first, as under "What you need"): `bash test.sh ./testslot`, run from the repository folder, tests the checkout's copy of `testslot`, not the installed one. On a shared host, run them through the gate (`testslot run --cpus 2 -- bash test.sh ./testslot`).

## Usage

```sh
testslot run --cpus 4 -- make -j4 test  # wait for 4 cpus, then run
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
- A run that would start ahead of a waiting one needs a time limit (`--max-minutes N`, in minutes, above 0), so it cannot hold the queue up for long. Without one it simply waits its turn. A normal run needs no limit. The limit counts from when the run starts. If it passes while the run it started ahead of is still waiting, testslot stops the run with `TERM`; the run does not start again, its history line says `time limit`, and its exit code is 143 (128 plus the signal). A run that started with nothing waiting is never stopped for its limit.
- A run pauses itself for up to 3 seconds at a time if the host is starting processes faster than a start-rate cap.
- An internal failure prints `testslot error: ...` on stderr and exits `70` if the command has not already finished. The docstring lists the exit codes.

### Two runs competing

Try it on a scratch gate, so your real gate's settings stay as they are. Set both the cpu cap and the load cap there: the load cap defaults to the cpu cap, so on a host whose load is already near 3 a cap of 3 alone would close the gate.

```sh
export TESTSLOT_DIR=$(mktemp -d)           # a scratch gate, only for this shell
mkdir "$TESTSLOT_DIR/holders" "$TESTSLOT_DIR/logs"
echo 3 > "$TESTSLOT_DIR/cap"               # a cpu cap of 3
echo 100 > "$TESTSLOT_DIR/load-cap"        # and a load cap that stays out of the way
testslot run --cpus 2 -- sleep 25 &        # holds 2 of the 3 cpus
sleep 1                                    # let it start first
testslot run --cpus 3 -- sleep 1 &         # needs all 3, so it waits
sleep 1
testslot status
```

When you are done, run `unset TESTSLOT_DIR` (or open a new shell) to go back to your own gate.

`status` prints (host name, user, folders and log lines trimmed):

```
test slots: load 2.93 3.02 3.20 on 12 cores; cap 3 cpus, 2 in use, 1 free
holding:
  light  alice  pgid   92346  02:58   0m05s  2 cpus (using 0)  ~/work
         sleep 25
waiting:
  light  alice  pgid       -  02:58   0m04s  3 cpus  #1  (waiting: cpus)  ~/work
         sleep 1
```

`(using 0)` is how many cpus the run was measured using at its last sample (here 0: `sleep` is idle). The waiting run starts when the first one ends.

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
