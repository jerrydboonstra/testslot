"""testslot: one machine-wide test gate on a Linux host (and on a Mac), shared by every account and repo.

  testslot run [--cpus N | --heavy | --track] [--max-minutes N] [--key KEY] [--log FILE] -- <command...>
  testslot suggest [--default N] (--key KEY | -- <command...>)
  testslot status [--json]
  testslot summary [--since 12h] [--json]
  testslot stop [--kill] <pgid>

Admission is by CPU. Each run declares the cpus it uses (--cpus N, its -j; default 1). Runs start
first come, first served while the charged cpus of everything running, plus the new run's, stay
within the cap (the number in $DIR/cap, or TESTSLOT_CAP; with neither, max(1, round(cores * 0.8)); as of 2026-10-20 a Linux host 20, a Mac 6), and while the
1-minute load is under the load cap ($DIR/load-cap, or TESTSLOT_LOAD_CAP, else the cap; as of 2026-10-20 a Linux host 10, a Mac 10), so outside work (builds, sessions) counts too; and while another
run is going, that load plus the new run's cpus also stays within the load cap.
--heavy means cpus = the cap: the box to itself. --track takes no cpus at all: it is only listed, for
long jobs that are API calls rather than CPU (its load, like any outside work's, still counts in the
load gate). A run asking for more than the cap gets the cap.

Runs start first come, first served among runs of a size, but a run may be backfilled: a run that fits in the free
cpus (and the load) starts ahead of a bigger run waiting before it, so a 10-cpu run at the head doesn't idle the box
while it waits for a 4-cpu run to end. A run is never passed by one asking for as many cpus or more. Once the run at
the head has waited past the reserve time ($DIR/reserve or TESTSLOT_RESERVE, seconds; default 600), the queue reserves
cpus for it: nothing passes it, and it starts as soon as enough cpus free. A head that the load holds back while anything
holds (its cpus on top of the load go over the load cap) can start only on an idle slot, so it reserves after six times
that wait (a --heavy run keeps the plain one): smaller runs backfill past it until then, and after it they wait for the
head too, so it can't starve. status and summary name the run cpus are reserved for, and mark a run that started by
backfill.
A run that would start while another waits ahead of it (a head: waiting for cpus or for the load, reserved or not) needs
a time limit, --max-minutes N (decimal minutes, above 0). A run with no limit, or one over the backfill limit
($DIR/backfill-limit or TESTSLOT_BACKFILL_LIMIT, minutes; default 30), waits for the head (wait reason no-limit). A
limited run starts if it fits; against a reserved head its limit must end within the backfill limit of the moment the
head began to reserve. A run that started that way is stopped, as a cancel with stop_reason "time limit" in its
history line, once its limit passes while a run it started past still waits. That stop is final: unlike the load requeue
below, the run is not started again. A run that starts with nothing waiting
ahead is never stopped for its limit.
Outside load that stays at or over the cap holds the whole queue until it falls; status says so. The
turnstile ($DIR/turnstile) is held only for the moment of each admission check. Runs also hold the old
flock gate, $DIR/heavy (LOCK_EX for --heavy, LOCK_SH otherwise), so Cat Herder's tools/test-parallel,
which takes LOCK_EX on $CAT_HERDER_TEST_SLOT (both accounts point it at $DIR/heavy), still queues
against them. A command run under testslot gets TESTSLOT_HELD (kind, wrapper pid and start), which Cat Herder's
test-parallel reads since 0.53.3, so a nested test-parallel doesn't wait on its own parent; a nested testslot
sees its ancestor's lock in /proc/locks and runs inside the parent's admission. When the command's main process ends, the rest of its process group is
ended too; on Linux that includes anything in the command's cgroup, a child that called setsid among it. A run whose
wrapper was killed outright (an orphan) holds its cpus against the cap while its process group lives, and on Linux,
where the command ran in a cgroup, while anything lives in that cgroup: a setsid child that left the group used to free
the slot while it ran on. Stop a run with `testslot stop <pgid>`, which goes through its wrapper and counts as a
cancel; a signal sent to the group alone (kill -TERM -- -<pgid>) looks like the command dying, a failure.

Start-rate throttle: with a cap on process starts ($DIR/start-rate-cap, else TESTSLOT_START_RATE_CAP, else none: no
throttle; the Mac's setup writes 120), each run's wrapper reads the host's starts a second, every second (Linux: the
processes counter in /proc/stat; macOS: the pid of a child it starts, since pids are handed out in order). Over the cap,
averaged over 3 s, it stops its own group (and cgroup) for up to 3 s. If the rate falls by half the cap meanwhile, the
burst was its own: it resumes once under 80% of the cap and may pause again; if not, the starts are outside work, and
the run resumes and isn't paused again for 60 s. A paused run keeps its full cpus, prints a line on its first pause and
at most every 30 s after, and its history line counts pauses, paused_s and max_pause_s. Every end path (stop, a cancel,
a killed wrapper's orphan) resumes the group before it signals it. TESTSLOT_FAKE_START_RATE names a file holding the
host rate, for tests.

Wait reason: a waiting run records why it waits as one code, in its holder, in status (--json and the "(waiting: <code>)" on its
row) and, once admitted, on its history line as wait_reason: reserved (cpus are reserved for the head), queued-ahead (runs
queued ahead of it), cpus (the cap is in use), load (the load cap), gate (the test gate is held outside testslot or by a
heavy run) or no-limit (a run is waiting ahead and this one has no --max-minutes, or one over the backfill limit). It is
empty on a run that never waited, and status shows it only while the run waits. A run with a limit shows it on its status
row as "(limit 2m, 95s left)", and in --json as limit_s and limit_left_s.

Load pause: while the 1-minute load is over 1.5 times the cores, the one light run using the most cpus above what it
declared pauses itself (SIGSTOP to its group and cgroup), and resumes once the load is under the load cap. A heavy or
tracked run, a run with no reading, and the last run going are never paused. If the load stays over the trigger, the
next worst over-user pauses at the next second. It prints a line when it pauses and when it resumes, and status shows
it as "paused: load". It is kept apart from the start-rate pause: a run under both is resumed only when both have
cleared. TESTSLOT_OBSERVED_DIR names a folder with one file per run, named by its process group id, holding that run's
cpu reading (TESTSLOT_OBSERVED is the fallback), for tests.

Requeue, the last resort after the load pause: a light run whose last unpaused reading is over twice what it declared,
and that the load pause first paused 5 minutes ago (TESTSLOT_REQUEUE_AFTER_S, for tests; the 5 minutes count from that
first pause since it went over, never from when it went over, so the pause always has its turn first; time spent paused counts toward them), while the load is
still over 1.5 times the cores and another run is going, is stopped by its own wrapper as a cancel (the history line says cancel) and started again in the same process, so the caller keeps waiting
on the same command and sees only the final run's exit code. The new run goes to the head of the queue, declaring its
measured peak rounded up (held to the cap), prints why on stderr and in the log, and shows "requeued once" in status. A
run is requeued once; a second overrun is left to the load pause. A heavy or tracked run, one with no reading, and the
last run going are never requeued. The output of the first run stays in the log and on the caller's stdout. The
internal option --requeued DECLARED:PEAK is how the wrapper restarts itself; it is not for callers.

A run's peak observed cpu (see the sampler) is recorded in its history line under a key: --key KEY, else the
command with its paths, hex and number tokens and --log argument dropped. `testslot suggest` prints the last
peak for a key as a whole number of cpus, for the next run's --cpus, or nothing (or --default N) when no run with
that key has a reading; it always exits 0 unless its own arguments are wrong. A key past 200 characters is stored
as a hash, so a caller can pass any length.

Idle shrink (as of 2026-10-21: N = 600 s, margin = 1 cpu; $DIR/shrink-after and $DIR/shrink-margin, else TESTSLOT_SHRINK_AFTER
and TESTSLOT_SHRINK_MARGIN, validated and clamped, garbage falling back to the default): a run counted by cgroup whose
observed cpu has stayed under its declared cpus for N seconds is charged observed + margin, never above its declaration
and never under 1, so an idle 8-cpu run frees most of its cpus for waiting runs. The charge follows the reading while it
stays under the declaration (0.1 -> 1.1, 2.0 -> 3) and is the full declaration again once the reading climbs back to
the declaration, at the next check. Only light runs counted by cgroup shrink: a process-group reading undercounts, and
heavy and --track runs never shrink. THE WORST CASE, plainly: a shrunk run is charged seen + margin while it may hold
its whole declaration, and the cpus it frees can be filled. If it then climbs to its declaration, real use is above
the cap until the admitted runs end: nothing enforces the cap on running runs, only the load gate stops new starts.
Shrunk runs add up: each can free declared - margin - seen cpus, so a 4-cpu run at 0.1 frees 2.9, and five of them on
the 20-cpu host free 14.5; if those five climb to 4 each while the 14.5 is filled, demand is 34.5 cpus on a 20-cpu
box, 1.7 times the cap, until the admitted runs end. The reading lags by one averaged sample interval plus the write, about 3 to 6 s at the
defaults, so a burst takes up to two samples to show. The wrapper rewrites a shrunk record every sample; one not
rewritten for 4 sample intervals + 1 s (a dead sampler) is charged in full.

Each run writes a holder file ($DIR/holders/<pid>.json) that status reads. A dead wrapper's record still counts
while its command's group or cgroup lives; otherwise it is ignored there and deleted by the next run. When a run ends, one line goes into
$DIR/history.jsonl (queued, started, ended, exit, cpus and more), which summary reads. The command
runs in its own process group, and its output goes to the terminal and to a log ($DIR/logs/ unless
--log).

On macOS (a Mac takes small runs while the Linux host is full) the same commands work against
/Users/Shared/testslot, set up by testslot/setup-mac.sh (the live cap and load-cap are the numbers in $DIR/cap and $DIR/load-cap; as of 2026-10-20 a Mac 6/10): $DIR/load-cap (or
TESTSLOT_LOAD_CAP) is the load the gate holds at, the cap when unset. ps stands in for /proc; a nested
run knows its parent by TESTSLOT_HELD (kind, wrapper pid and start), since there is no /proc/locks; and
on macOS status lists a test-parallel run outside testslot by its command line (as Linux does), but no other
holder outside testslot.

Exit codes: run returns its command's code (128+n if it was killed by signal n, or cancelled with n);
2 for a usage error, 1 for a setup or permission error, 127 when the command can't start, and 70
(INTERNAL_ERROR, sysexits' EX_SOFTWARE) when testslot itself fails on something it didn't expect: it prints
"testslot error: ..." on stderr and exits 70, so a wrapper that reads only the code can tell a broken gate from
a failed suite. A command may itself exit 70, so the stderr line is the only reliable marker of testslot's own
failure. Once the command has finished, an internal error after that (in the cleanup) keeps the command's exit code
and still prints the line. A closed stdout (testslot status | head) ends quietly with 141, not as an error. Everything
printed is written with errors="replace", so a path or command line that isn't UTF-8 shows as "?" and cannot crash a
listing. Test hooks: TESTSLOT_TEST_CRASH=<text> raises an internal error at start, except after-wait raises it just after
the command ends, and pipe raises BrokenPipeError (quiet exit 141). TESTSLOT_DEBUG=1 adds the traceback after the
"testslot error" line. status, summary and stop return 0 (stop: 1 if the group survives).
"""
import os
import sys
import traceback
from testslot import procs
from testslot import runcmd
from testslot import statuscmd
from testslot import stopcmd
from testslot import suggestcmd
from testslot import summarycmd
from testslot import util


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0
    cmds = {"run": runcmd.cmd_run, "suggest": suggestcmd.cmd_suggest, "status": statuscmd.cmd_status, "summary": summarycmd.cmd_summary, "stop": stopcmd.cmd_stop}
    if argv[0] not in cmds:
        util.die(f"unknown command {argv[0]}; see testslot --help")
    for out in (sys.stdout, sys.stderr):  # a path or command line that isn't UTF-8 must print as "?", not crash the listing
        try:
            out.reconfigure(errors="replace")
        except (AttributeError, ValueError):
            pass
    try:
        crash = os.environ.get("TESTSLOT_TEST_CRASH")  # tests only: an internal error, to see the exit code and the stderr line
        if crash == "pipe":
            raise BrokenPipeError()
        if crash and crash != "after-wait":
            raise RuntimeError(crash)
        return cmds[argv[0]](argv[1:])
    except procs.PsFailed:
        util.die("ps failed three times, so which runs are alive can't be told; nothing was started", 1)
    except BrokenPipeError:  # `testslot status | head`: the reader left, which is not testslot's failure
        try:
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())  # so the flush at exit stays quiet
        except (OSError, ValueError):
            pass
        return 141
    except Exception as e:  # SystemExit and KeyboardInterrupt are not Exceptions, so exits and ^C pass through
        frames = traceback.extract_tb(e.__traceback__)
        pkg = os.path.dirname(os.path.abspath(__file__)) + os.sep
        ours = [f for f in frames if os.path.abspath(f.filename).startswith(pkg)] or frames
        where = f" (line {ours[-1].lineno})" if ours else ""
        print(f"testslot error: {type(e).__name__}: {e}{where}", file=sys.stderr)
        if os.environ.get("TESTSLOT_DEBUG"):
            traceback.print_exc()
        return util.INTERNAL_ERROR if util.RAN[0] is None else util.RAN[0]
