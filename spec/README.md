# Testslot model

A TLA+ model of the testslot scheduler, `../testslot` (the script). It is a trial of the method on one small, concurrent piece of code: model it, let TLC explore every interleaving of a few runs, and turn each counterexample into a test. This directory holds the model only. "Results of the check" records the script fix and the model's TLC results.

## Files

- `Testslot.tla`: the model and its properties. Each simplification names the line of the script it simplifies, and each rule names the line it comes from (lines of main at 5e24784).
- `Testslot.cfg`: two runs, every property below, no symmetry, so the liveness property can be checked.
- `Testslot-3runs.cfg`: three runs with symmetry, safety properties only (TLC's symmetry reduction is unsound for temporal properties).

## Run it

TLC needs Java and `tla2tools.jar`. From this directory, through a test slot and in the background (a model check is a test run):

```bash
testslot run --cpus 2 -- java -XX:+UseParallelGC -cp /path/to/tla2tools.jar tlc2.TLC -workers 2 -config Testslot.cfg Testslot.tla
```

Swap in `-config Testslot-3runs.cfg` for the three-run safety check. To see the old setsid bug come back, set `Cgroup = FALSE` in a copy of the cfg: `SlotHeldWhileAlive` and `AfterStopNothingAlive` then fail on a process that called `setsid`.

## What is modelled

- **Admission** (`take_slots`, `why_wait`): a run starts when the charged cpus of the holders plus its own stay within the cpu cap, the outside load is under the load cap, and, while anything holds, load plus its cpus stays within the load cap. Check and admission are one step (the turnstile).
- **The caps are re-read** on every check, both of them, so a change reaches runs already waiting. A lowered cap evicts nobody. Both caps and the outside load change at any step.
- **Not modelled: the time limit**. The code lets a run start past a waiting head only with `--max-minutes` and stops it at its limit; this model still lets any strictly smaller run start, so it admits runs the code now holds as `no-limit`.
- **The queue and backfill**: turn order is the order of arrival. A later run may start past a waiting run only if it asks for strictly fewer cpus. After the reserve wait (`Reserve` ticks) the queue reserves for that run and nothing passes it. A head the load holds back while anything holds reserves only after `IdleX` times that wait (6 in the script, 2 here). A heavy run keeps the plain wait.
- **Kinds**: light (declares cpus), heavy (cpus = the cap), track (costs 0, is never ahead of anyone, and skips the queue, the load gate and the flock gate altogether: lines 1484-1487).
- **The flock gate** (lines 938-941, 952): every light and heavy run holds it while it runs, LOCK_EX for heavy and LOCK_SH for the rest. So a heavy run starts only when no other light or heavy run holds, and nothing starts while a heavy run holds. A test-parallel run outside testslot takes it too; that is outside load here.
- **The clamp**: a size is held to the cap as it stands now (lines 279 and 307), so a run asking for more than the cap is charged the cap.
- **Charge**: the larger of the declaration and the reading, held to the cap; idle shrink charges a light cgroup run that has sat under its declaration for `ShrinkAfter` ticks its reading plus `Margin`, never above the declaration and never under 1. A run that climbs back to its declaration is charged in full at once.
- **The reading** is a nondeterministic whole number that can change at any step. That stands in for the 3 to 6 s lag of the sampler: the checker reaches the state where a burst has not shown yet.
- **Outside load** is a variable that can hold the whole queue.
- **Exit, reap and stop**: the command's main process exits, and a step later the wrapper reaps it (`proc.wait()`, line 1609). `testslot stop` reaches the wrapper, which records a cancel, TERMs the group and the cgroup, and KILLs what is left. `--kill` kills at once. In the model, the wrapper ignores a stop only once it has reaped the command (the pre-fix script's line 1451 tests `proc.returncode`), so a stop in the window between the exit and the reap is still a cancel. The current Linux script uses `waitid(..., WNOWAIT)` to detect an exit before the reap; macOS retains the old check. A TERM sent to the group alone is a failure, not a cancel. A command that exits nonzero on its own is a failure. Some processes ignore TERM; a process may have left the group with `setsid` and sit only in the cgroup (`Cgroup = TRUE` reaches it, `FALSE` does not).
- **Runs come back** after they finish, so a stream of small runs can pass a big head. That is what makes the liveness check mean something.

## Properties

All are defined in `Testslot.tla` and named in the cfg.

- `AdmitWithinCap` (safety): every light or heavy admission left the sum of charged cpus, the new run included, within the cap. It is not true of every state: a lowered cap, or a shrunk run climbing back, can push the sum over while runs go, and the script's docstring says so.
- `AfterStopNothingAlive` and `SlotHeldWhileAlive` (safety): after a stop completes no process of the run is alive, and while any process is alive the run still holds its slot.
- `CancelNotFailure` (safety): judged against what really ended the command (`endedBy`), not the wrapper's own flag. A cancel only for a command that a stop ended, a failure only for one that exited nonzero on its own or died to a signal that did not come from `stop`. **TLC reported it violated** (see "Results of the check"): a stop that lands after the command has exited on its own and before the reap is recorded as a cancel for a command that had already finished. That counterexample remains in this model. The Linux script now checks for an exited leader before recording a cancel, and case 99 covers that fix; the macOS path retains the old check.
- `TypeOK` and `RunningHasMain`: bookkeeping the others rely on.
- `Liveness`: if outside load drops below the load cap infinitely often, every waiting run eventually starts, under fairness (time passes, a running command ends, the wrapper's clean-up steps happen) and strong fairness on admission. Strong, not weak: with load that drops only now and then, admission is enabled now and then, not continuously, and weak fairness would not force it. Every declaration fits under the cap because of the clamp, so the item's "whose declaration fits" excludes no run.

## Left out, and why

- **Orphans** (a wrapper killed outright, whose command lives on): not in the item's list, and covered by their own tests. Adding them is a small extension: a state in which the wrapper is gone and the group still holds cpus.
- **A waiting run that is cancelled** (it has no pgid for `stop`, line 1888, so it is never stopped by it).
- **A group stuck in the kernel**, which survives KILL (lines 1642-1650): the model assumes KILL ends everything it reaches.
- **The sampler's staleness rule** (lines 323-334): a dead sampler's record is charged in full. The model has no dead sampler.
- **Process-group readings** and macOS: only the cgroup path shrinks, and `Cgroup = FALSE` stands for "no cgroup" for stop only. The ps path, `TESTSLOT_HELD` nesting and the exit codes 70 and 127 are not modelled.
- **History, status, summary, suggest, keys**: bookkeeping that does not change who runs.
- **Real time**: a tick is abstract. The 5 s between TERM and KILL is "any later step", forced by fairness. The 1-minute load average's lag (line 884 comment) is not modelled: load is the outside work alone.
- **A real command's process tree**: its processes are chosen at admission and may exit one at a time; it does not start new ones.
- **The watchdog in `test.sh`**: test-only, out of scope. testslot has none of its own; liveness assumes a running command ends.

## Results of the check (2026-10-24)

TLC 2.19 (tla2tools 1.7.4, Java 25) on a Linux host, through `testslot run --cpus 2 -- tlc -workers 2`, 2 workers, state on disk. Logs are on that host in `~/tla-check/` and `~/tla-check-b/` (named below). The method cost about 3 hours of wall clock after the model existed, most of it waiting on state spaces that did not finish.

**Two properties failed, both followed up.**

- **`CancelNotFailure`: a real finding, fixed on Linux and covered by a test.** 2 runs, `Testslot.cfg` (log `tla-check/tlc-2runs.log`): violated after 3 min 37 s at 937,573 distinct states, depth 7. The trace: a track run is admitted, its command dies of a signal that did not come from `stop` (`endedBy = raw`), `testslot stop` reaches the wrapper before it has reaped the command and sets `cancelled`, and the history line says `cancel`. In the checked script, `forward()` (line 1450) ignored a stop only when `proc.returncode` was set, and only the wrapper's `wait()` set it. Reproduced against the real script: the case "a stop after the command exited by itself leaves its code 0" in `test.sh` (section 99, originally gated by `TESTSLOT_KNOWN_BUGS=1`). With the gate on it failed (`changed its code to 143`), and with it off `test.sh` was green (0 failed). It stops the wrapper (SIGSTOP), lets the command exit 0 while a child keeps the group alive, and runs `testslot stop`. Bug (medium: a wrong record, nothing lost or stuck; the window is microseconds unless the wrapper is stopped or starved). **Fixed on Linux**: `leader_ended()` asks `os.waitid(..., WNOWAIT)` whether the leader has exited before a cancel is recorded, so the stop leaves the command's code alone. Case 99 now runs without the opt-in gate on Linux; macOS has no `waitid`, retains the old check, and skips this case.
- **`AdmitWithinCap`: model-only, the model was wrong.** 3 runs, no `CancelNotFailure`, `Testslot-3runs.cfg` (log `tla-check/tlc-3runs-nocancel.log`): violated after 6 min 32 s at 7,211,740 distinct states. Cap 2, two light runs asking 1 cpu each, both admitted; a running run's reading then rose to 2 (a burst), so the charged sum became 3; a track run was admitted after that, and the ghost variable read the sum at that admission. A track run is charged nothing and skips the cpu check (lines 1484-1487), so its admission asserts nothing about cpus; the over-cap sum came from the reading burst, which the property already says is allowed ("not true of every state"). The model now exempts track admissions from the check (`Testslot.tla`, `Admit`). Not a script bug, so no test.

**What did not finish.** Every exhaustive run past the first two went over an hour, so the constants were shrunk twice and the cap on each run was an hour (`timeout 3600`). None reached a full state space, so these are bounded results, not proofs:

| Run | Constants | Explored (distinct) | Result |
|---|---|---|---|
| 3 runs, symmetry, safety, model fixed (`tla-check-b/tlc-3runs-v2.log`) | cap {2,4}, load cap {3,5} | 56,431,931 in 1 h | no violation, not finished |
| 3 runs, symmetry, safety (`tla-check-b/tlc-3runs-tiny.log`) | cap {2}, load cap {3}, MaxCpus 2 | 65,095,524 in 1 h | no violation, not finished |
| 2 runs, liveness and safety (`tla-check-b/tlc-2runs-tiny.log`) | cap {2}, load cap {3}, MaxCpus 2 | 11,157,211 in 1 h | no violation, not finished |
| 2 runs, `CancelNotFailure` off, full constants (`tla-check/tlc-2runs-nocancel.log`) | as `Testslot.cfg` | 10.0 million when the disk filled at 32 min | no violation up to there; the run died on a full `/tmp` (tmpfs), not on a result |
| 2 and 3 runs, cap {4}, load cap {3} (`tla-check-b/tlc-2runs-small.log`, `tlc-3runs-small.log`) | smaller | 4.45 million and 24.8 million, stopped by hand at about 35 min | no violation |

So for `AfterStopNothingAlive`, `SlotHeldWhileAlive`, `TypeOK`, `RunningHasMain` and `Liveness` the result is "no counterexample in the explored prefix", which is weaker than "holds". Liveness in particular was checked only on the growing state graph TLC rechecks each minute, never on a finished one. To make an exhaustive run feasible, the model needs fewer per-run variables (the process-set and shrink counters are most of the state), or `Liveness` and the stop properties need separate, smaller models. Not done here.

**A warning for the next run.** Put TLC's `-metadir` on disk (`~/tla-states`), never `/tmp`: that host's `/tmp` is a 7.8 GB tmpfs, and two runs filled it to "Disk quota exceeded".

## Status

SANY parses `Testslot.tla`. TLC ran on 2026-10-24 (see "Results of the check" above): one script bug found, tested and fixed on Linux, one model error found and fixed, and no run finished its state space. This directory still holds only the model, which retains the pre-fix stop rule.
