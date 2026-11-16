# Changelog

What changed in each release, newest first.

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
