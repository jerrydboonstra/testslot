<img src="images/logo.png" alt="A wooden tray of four round slots, three holding balls, with a ramp feeding a red ball into the empty fourth." width="320">

# testslot

[![CI](https://github.com/jerrydboonstra/testslot/actions/workflows/ci.yml/badge.svg)](https://github.com/jerrydboonstra/testslot/actions/workflows/ci.yml) [![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) [![release](https://img.shields.io/github/v/release/jerrydboonstra/testslot)](https://github.com/jerrydboonstra/testslot/releases/latest)

A test gate for a shared machine: many people, agents and CI jobs run their test suites on one host, and each run waits its turn for free cpus. It scales down to one account on one laptop. It is for one host only: testslot does not coordinate several machines.

[Changelog](./CHANGELOG.md) · [Contributing](./CONTRIBUTING.md) · [Security](./SECURITY.md)

## Quick start

```sh
git clone https://github.com/jerrydboonstra/testslot
cd testslot
make install
```

`make install` puts a copy of the code in `~/.local/lib` and a link to it in `~/.local/bin` (a copy, not a link into the checkout, so a running gate does not change when you switch branches or install again) and makes a state folder for your account, `~/.testslot`, with its `holders/` and `logs/`. Then it prints the line to add to your shell profile (shown here for a user named alice):

```
Installed testslot in /home/alice/.local/bin and made the state folder /home/alice/.testslot.
Add this line to your shell profile (and run it now to use testslot in this shell):
export PATH="/home/alice/.local/bin:$PATH" TESTSLOT_DIR="/home/alice/.testslot"
```

Add the line `make install` printed to your shell profile, and run it in this shell. Then check the install:

```sh
testslot run --cpus 1 -- echo ok         # prints a "light run, 1 cpus" line, then: ok
```

Running `make install` again changes nothing and prints the same lines. macOS does not have `~/.local/bin` on `PATH` by default, so the line matters there. A shell profile reaches interactive shells only: in CI or any other non-interactive job, set both variables in the job itself.

This is a gate for one account. `holders/` keeps one small file for each run that is going or waiting (what `status` reads), and `logs/` keeps each run's output. `testslot` does not create the state folder itself and exits with a "not set up" message when it is missing. With `TESTSLOT_DIR` unset the default is `/var/lib/testslot` on Linux (making it needs root), and `/Users/Shared/testslot` on macOS.

## Usage

```sh
testslot run --cpus 4 -- make -j4 test  # wait for 4 cpus, then run
testslot status                         # who holds cpus, who waits and why
testslot stop <pgid>                    # stop a run by the group id status shows
testslot run --track -- ./long-api-job  # listed, but reserves no cpus in the gate
testslot run --heavy -- ./big-build     # the whole cap to itself
testslot summary --since 12h            # recent runs from the history file
testslot suggest --default 2 -- make test   # cpus the last run of this command peaked at
```

Declare the cpus your command really uses (for `make`, its `-j`). The default is 1. A run that asks for more cpus than the cap gets the cap, so it still starts on a small host. `status` and `summary` read the state folder: `history.jsonl` there holds one line per finished run, and `suggest` reads each run's peak cpu use from it. If testslot itself fails after a run was admitted, that run's line also has an `error` field with the text of the `testslot error` line on stderr (without its `(line N)`, cut to 500 characters), and its `exit` is the command's own code when the command had finished (null when testslot failed before the command started). A line with no `error` field is a run that hit no internal error of testslot's; a command that cannot start (exit 127) is not one.

## Sharing across accounts

Accounts share one gate only when they use the same state folder: the default (`/var/lib/testslot` on Linux, `/Users/Shared/testslot` on macOS) or one `TESTSLOT_DIR` that all of them set. To set one up, run this once as a user who can use `sudo`, with the name of a group all the accounts belong to:

```sh
sudo make install-shared GROUP=testers     # replace testers with your group
```

It makes the shared state folder with its `holders/` and `logs/` and gives it to the group. Then it prints the line each account adds to its shell profile (shown here for the group testers on Linux):

```
Made the shared state folder /var/lib/testslot for the group testers.
Each account adds this line to its shell profile:
export TESTSLOT_DIR="/var/lib/testslot"
```

On macOS the shared folder is `/Users/Shared/testslot`, and no `sudo` is needed for it. A per-account folder such as `$HOME/.testslot` gates only that account, and must be made first.

A CI job usually runs as its own account, and `~/.local/bin` is per account, so `testslot` must be installed for that account. Either run `make install` as the CI account (the code goes into that account's own `~/.local`), or put one copy where every account's `PATH` reaches, for example `sudo make install PREFIX=/usr/local` (it also makes a state folder in the home of the account that ran it, which the job does not use; the `PATH` line below is then not needed). In the job itself, set the state folder and call `testslot`. To gate against other accounts on the host, point the job at the shared folder (the CI account must be in its group):

```sh
export PATH="$HOME/.local/bin:$PATH"       # only when testslot is in the CI account's own ~/.local/bin
export TESTSLOT_DIR=/var/lib/testslot
testslot run --cpus 2 -- make -j2 test
```

## How it works

`testslot run --cpus 4 -- make -j4 test` waits until 4 cpus are free under the cpu cap and the host's 1-minute load is under the load cap, then runs the command and prints its output as usual. It returns the command's exit code.

A run declares its cpus. testslot waits for them and checks the load before it starts, but it does not limit what the command then uses, and `--cpus` does not set the command's own parallelism (pass that to the command, as `-j4` does above). The gate is cooperative: it queues programs that use `testslot run`, and counts other work only through the load.

- Smaller runs may start ahead of a bigger one that is waiting (backfill), but a long wait for the bigger one reserves cpus for it, so it cannot starve.
- A run that would start ahead of a waiting one needs a time limit (`--max-minutes N`, in minutes, above 0), so it cannot hold the queue up for long. Without one it simply waits its turn. A normal run needs no limit. The limit counts from when the run starts. If it passes while the run it started ahead of is still waiting, testslot stops the run with `TERM`; the run does not start again, its history line says `time limit`, and its exit code is 143 (128 plus the signal). A run that started with nothing waiting is never stopped for its limit.
- A run pauses itself for up to 3 seconds at a time if the host is starting processes faster than a start-rate cap.
- When the host's load runs high, the run using the most above what it declared pauses itself and resumes when the load is back under the load cap. The 1-minute load lags a pause by tens of seconds, so at most one run is paused, and one resumed (the newest pause first), per settle window: 30 seconds, or the number of seconds in `TESTSLOT_PAUSE_WINDOW`, else in `pause-window` in the state folder, from 5 to 300.
- A CI run goes first. `testslot run --ci -- <command>` is for the accounts listed in the file `ci-users` in the state folder (one account name a line, `#` lines and blank lines ignored; no file means nobody, and no environment variable stands in for it). While a CI run is waiting or running, no new run that is not a CI run starts on the host; runs already going are never stopped, and a queued CI run goes ahead of every queued run that is not one. CI runs among themselves keep the turn order and share the cap, so several run together while cpus are free. `status` marks a CI run `(ci, priority)` and a held run `(waiting: ci first)`. The file is a plain convention, not a lock: the shared state folder is writable by its group, so a group member can replace `ci-users`; for a hard boundary keep the file root-owned outside that folder.
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

## Requirements

- Python 3.9 or newer and a Unix host (Linux or macOS). `testslot` is a small package of standard-library modules, with nothing to install but itself (`make install` does that). The 3.9 minimum comes from a static check of the code with [vermin](https://github.com/netromdk/vermin), and `testslot run` and `testslot status` were run on Python 3.9.6.
- A state folder that every account using the gate can write to (`make install` and `make install-shared` make it).

## Running the tests

`bash test.sh ./testslot`, run from the repository folder, tests the checkout's copy of `testslot`, not the installed one. On a shared host, run it through the gate (`testslot run --cpus 2 -- bash test.sh ./testslot`).

The full suite passed on macOS (Darwin 25.6.0) with Python 3.15.2 and on Ubuntu 26.04 (Linux 7.3.1) with Python 3.14.4; it has not been run on other systems or on Python 3.9.

On macOS the tests need GNU `timeout`, which macOS does not have. `brew install coreutils` installs it as `gtimeout`, so link it into a folder on your `PATH` (`make install` makes `~/.local/bin`, and the line it prints puts it on your `PATH`): `mkdir -p ~/.local/bin && ln -s "$(brew --prefix coreutils)/bin/gtimeout" ~/.local/bin/timeout`. Nothing else is needed: with only that link, the suite passed in a clean macOS shell (the system `/bin/bash` 3.2.57 and system Python 3.9.6) with no failures. `setsid` is not needed: macOS lacks it too, and of the two cases that use it, one skips itself and the other (a `setsid` daemon that must not keep the slot) passes without testing `setsid`. Linux already has `timeout`.

## Specification

The full interface, every setting and every exit code are in the docstring at the top of [`lib/testslot/cli.py`](./lib/testslot/cli.py), the package's command module (`testslot` itself is a short entry script). [`spec/README.md`](./spec/README.md) describes a TLA+ model (a formal model checked by machine) of the admission rules and what checking it found.

## License

MIT. See [LICENSE](./LICENSE). What changed in each release: [CHANGELOG.md](./CHANGELOG.md), newest first.
