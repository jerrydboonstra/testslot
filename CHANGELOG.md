# Changelog

What changed in each release, newest first.

## 1.2.0 (2026-11-22)

### The gate

- `testslot run --ci` marks a CI run, for the accounts listed in the `ci-users` file in the state folder. While a CI run waits or runs, no new run that is not one starts on the host, and a queued CI run goes ahead of every queued run that is not one; runs already going are never stopped. `status` shows `(ci, priority)` and `(waiting: ci first)`, and `--json` has a `ci` field.

### The history line

- When testslot itself fails after a run was admitted, that run's `history.jsonl` line now has an `error` field with the text of the `testslot error` line, and its `exit` is the command's own code when the command had finished (null when testslot failed before the command started). A line with no `error` field is a run that hit no internal error of testslot's; a command that cannot start (exit 127) is not one.

### The load pause

- When the host's load runs high, testslot now pauses at most one run and resumes at most one run per settle window, the newest pause first, so the lagging 1-minute load can settle between steps. The window is 30 seconds by default, set by `TESTSLOT_PAUSE_WINDOW` or the `pause-window` file in the state folder (5 to 300). A pause that finds `pause.lock` unusable no longer leaves a stale paused record.

### README

- The README badge row reads CI (the first badge, now labelled CI instead of tests), the MIT license, and the latest release.

## 1.1.0 (2026-11-16)

### Install

- testslot is now a small package: an entry script and the modules under `lib/testslot/`. Nothing changes for users: the command, its options and its output are the same.
- `make install` puts each version in its own folder under `~/.local/lib` and swaps the link in `~/.local/bin` in one step, so a run that is already going is never touched, and running it twice changes nothing. An old one-file install is replaced by the same step.

### README

- The README shows a tests badge and an MIT license badge under its title.

## 1.0.0 (2026-11-16)

### The gate

- `testslot run --cpus N -- <command>` waits until N cpus are free under the cpu cap and the host's 1-minute load is under the load cap, then runs the command and returns its exit code. It does not limit what the command then uses.
- Smaller runs may start ahead of a bigger one that is waiting (backfill). A run that does so needs a time limit (`--max-minutes`), and the run at the head of the queue gets cpus reserved for it after a wait, so it cannot starve.
- `--heavy` takes the whole cap, `--track` lists a run without reserving cpus, and idle runs on Linux are charged only what they use plus a margin.
- `testslot status`, `summary`, `stop` and `suggest` show who holds cpus, recent runs, and a run's usual peak.
- Settings come from files in the state folder, or from environment variables when a file is missing or invalid.

### Install

- `make install` copies `testslot` into `~/.local/bin`, makes the state folder `~/.testslot`, and prints the line to add to your shell profile.
- `sudo make install-shared GROUP=<group>` makes one shared state folder for many accounts and gives it to a group.

### Tests

- `bash test.sh ./testslot` runs the suite. On macOS it needs GNU `timeout` (`brew install coreutils`).
- `spec/` holds a TLA+ model of the admission rules.
