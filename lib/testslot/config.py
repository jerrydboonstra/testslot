import math
import os
import pwd
import sys
import time


# Linux reads /proc; macOS (a Mac, for small runs while the Linux host is full) asks ps instead.
# TESTSLOT_PLATFORM=darwin makes Linux take the ps path too, so the tests on Linux reach it.
PLATFORM = os.environ.get("TESTSLOT_PLATFORM") or ("linux" if sys.platform.startswith("linux") else "darwin")
LINUX = PLATFORM == "linux"
if LINUX and not sys.platform.startswith("linux"):
    PLATFORM, LINUX = "darwin", False  # no /proc here: TESTSLOT_PLATFORM=linux can only mean the ps path
DIR = os.environ.get("TESTSLOT_DIR", "/var/lib/testslot" if sys.platform.startswith("linux") else "/Users/Shared/testslot")
HEAVY = os.path.join(DIR, "heavy")
TURNSTILE = os.path.join(DIR, "turnstile")
HOLDERS = os.path.join(DIR, "holders")
LOGS = os.path.join(DIR, "logs")
HISTORY = os.path.join(DIR, "history.jsonl")
LOADAVG = os.environ.get("TESTSLOT_LOADAVG", "/proc/loadavg" if LINUX else "")  # tests point it at a file of their own
CORES = os.cpu_count() or 2
# Observed cpu: each wrapper samples its run's cgroup, or its process group as a fallback, every SAMPLE_S seconds
# (3 unless set; tests set it small). TESTSLOT_OBSERVED names a file holding one number: tests use it as every run's reading instead.
try:
    SAMPLE_S = float(os.environ.get("TESTSLOT_SAMPLE_S") or 3)
    SAMPLE_S = min(3600.0, max(0.5, SAMPLE_S)) if math.isfinite(SAMPLE_S) else 3.0  # 0 would spin it, inf would kill it
except ValueError:
    SAMPLE_S = 3.0
OBSERVED_FILE = os.environ.get("TESTSLOT_OBSERVED", "")
# tests: a folder with one file per run, named by the run's process group id; a run reads its own file first and falls
# back to TESTSLOT_OBSERVED when it has none, so one run can be set apart from honest ones.
OBSERVED_DIR = os.environ.get("TESTSLOT_OBSERVED_DIR", "")
VIA_HOOK = os.environ.get("TESTSLOT_OBSERVED_VIA", "")  # tests: with TESTSLOT_OBSERVED, record these readings as a cgroup's
# The longest a run waits for systemd-run to start its command in a scope before it stops the launcher and runs the
# command without one (10 s unless set; tests set it small). Starting a scope takes some milliseconds.
try:
    LAUNCH_S = float(os.environ.get("TESTSLOT_LAUNCH_S") or 10)
    LAUNCH_S = min(300.0, max(1.0, LAUNCH_S)) if math.isfinite(LAUNCH_S) else 10.0
except ValueError:
    LAUNCH_S = 10.0
# Linux runs each command in its own systemd user scope (a cgroup), so the sampler counts every process the run
# ever started, short-lived and setsid ones included. TESTSLOT_NO_CGROUP=1 forces the process-group path (tests).
CGROUP_ROOT = os.environ.get("TESTSLOT_CGROUP_ROOT") or "/sys/fs/cgroup"  # a test hook (documented, like TESTSLOT_SAMPLE_S): the suite points it at a folder of its own
NO_CGROUP = os.environ.get("TESTSLOT_NO_CGROUP") == "1"


# debt: the last good values are kept per process, so a process that starts during the truncate window of
# `echo N > cap` has none. One read retries a few times (4 more, 30 ms apart) before taking the default, but only
# when the file is there and bad, and a result is reused for a quarter second (monotonic clock), so a check pays
# for one read of each file, not one per holder. Upgrade: write the cap files with a rename, so no reader ever sees them empty.
_LAST_CAP = None  # the last cap read cleanly by this process; a cap file empty for an instant keeps it
_LAST_LOAD_CAP = None
_CAP_CACHE = {}  # name -> (when, value)
CAP_TTL = 0.25


def _cached(name, read):
    hit = _CAP_CACHE.get(name)
    if hit and time.monotonic() - hit[0] < CAP_TTL:
        return hit[1]
    value = read()
    _CAP_CACHE[name] = (time.monotonic(), value)
    return value


def _read_cap():
    global _LAST_CAP
    path = os.path.join(DIR, "cap")
    for attempt in range(1 if _LAST_CAP else 5):
        if attempt:
            time.sleep(0.03)
        for src in (_read(path), os.environ.get("TESTSLOT_CAP")):
            try:
                if src and int(src.strip()) >= 1:  # int() refuses inf and nan
                    _LAST_CAP = int(src.strip())
                    return _LAST_CAP
            except ValueError:
                pass
        if not os.path.exists(path) and not os.environ.get("TESTSLOT_CAP"):
            break  # no file and no override: nothing is being written, so don't wait for it
    return _LAST_CAP or max(1, round(CORES * 0.8))


def read_cap():
    """The cpu cap: the number in $DIR/cap (shared, so every account admits against the same one), else
    TESTSLOT_CAP (for tests, in a scratch folder with no cap file), else the last good value read by this
    process, else max(1, round(CORES * 0.8)). Read afresh each check, so a change reaches runs already waiting."""
    return _cached("cap", _read_cap)


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None



def _read_load_cap():
    global _LAST_LOAD_CAP
    path = os.path.join(DIR, "load-cap")
    for attempt in range(1 if _LAST_LOAD_CAP else 3):
        if attempt:
            time.sleep(0.03)
        for src in (_read(path), os.environ.get("TESTSLOT_LOAD_CAP")):
            try:
                if src and math.isfinite(float(src.strip())) and float(src.strip()) > 0:
                    _LAST_LOAD_CAP = float(src.strip())
                    return _LAST_LOAD_CAP
            except ValueError:
                pass
        if not os.path.exists(path) and not os.environ.get("TESTSLOT_LOAD_CAP"):
            break  # no file and no override: the cpu cap is the answer, no need to wait for a write
    return _LAST_LOAD_CAP or float(read_cap())


def read_load_cap():
    """The load the gate holds at: $DIR/load-cap, else TESTSLOT_LOAD_CAP, else the last good value read by this
    process, else the cpu cap. The files hold the live numbers: /Users/Shared/testslot/cap and load-cap on the
    Mac, /var/lib/testslot on Linux (provisioning writes 20 and 10 if missing). As of 2026-10-20: a Mac 6/10,
    a Linux host 20/10. Herd runs declare more cpus than they use, so the load cap does the guarding."""
    return _cached("load-cap", _read_load_cap)


CI_USERS = os.path.join(DIR, "ci-users")


def real_user():
    """The account this process runs as, by its uid: never getpass.getuser(), which reads LOGNAME and USER first, so a caller could name
    itself. A uid with no passwd entry gives its number."""
    try:
        return pwd.getpwuid(os.geteuid()).pw_name
    except KeyError:
        return str(os.geteuid())


def read_ci_users():
    """The accounts allowed to start a CI run (`run --ci`): one name a line in $DIR/ci-users, blank lines and # lines ignored. The file
    only: no environment variable stands in for it, since the caller sets its own environment. No file means nobody."""
    # debt: a cooperative gate, not a security boundary: the shared folder is group-writable (install-shared, no sticky bit), so a group
    # member can replace ci-users, as it can a holder record. Upgrade: a root-owned ci-users outside the group-writable folder.
    return {ln.strip() for ln in (_read(CI_USERS) or "").splitlines() if ln.strip() and not ln.strip().startswith("#")}


def read_reserve():
    """Seconds the run at the head of the queue may be passed by smaller runs: $DIR/reserve, else
    TESTSLOT_RESERVE, else 600. Past it, the queue reserves cpus for that run."""
    for src in (_read(os.path.join(DIR, "reserve")), os.environ.get("TESTSLOT_RESERVE")):
        try:
            if src and math.isfinite(float(src.strip())) and float(src.strip()) >= 0:
                return float(src.strip())
        except ValueError:
            pass
    return 600.0


RESERVE = read_reserve()


def read_backfill_limit():
    """Minutes a run that starts past a waiting head may be given: $DIR/backfill-limit, else TESTSLOT_BACKFILL_LIMIT, else 30."""
    for src in (_read(os.path.join(DIR, "backfill-limit")), os.environ.get("TESTSLOT_BACKFILL_LIMIT")):
        try:
            if src and math.isfinite(float(src.strip())) and float(src.strip()) > 0:
                return float(src.strip())
        except ValueError:
            pass
    return 30.0


def _read_number(name, env, default, lo, hi):
    """A number from $DIR/<name>, else $<env>, else default, clamped to [lo, hi]; anything that isn't a finite number
    (text, nan, inf, an empty file) falls through to the next source, and in the end to the default."""
    for src in (_read(os.path.join(DIR, name)), os.environ.get(env)):
        try:
            if src and math.isfinite(float(src.strip())):
                return min(hi, max(lo, float(src.strip())))
        except ValueError:
            pass
    return default


# Idle shrink: a run counted by cgroup whose observed cpu has stayed under what it declared for SHRINK_AFTER_S seconds
# is charged its observed cpu plus SHRINK_MARGIN, never above its declaration and never below 1. Read once at start,
# like RESERVE. As of 2026-10-21 the defaults are 600 s and 1 cpu.
SHRINK_AFTER_S = _read_number("shrink-after", "TESTSLOT_SHRINK_AFTER", 600.0, 1.0, 86400.0)
SHRINK_MARGIN = _read_number("shrink-margin", "TESTSLOT_SHRINK_MARGIN", 1.0, 0.0, 64.0)

# Start-rate throttle: the Mac hung when test runs started 200 to 340 processes a second,
# with the cpu and load caps holding the whole time. Each run's wrapper reads the host's process starts every
# START_RATE_S; when the 3-second average is over the cap it stops its own group for up to PAUSE_MAX_S, and keeps it
# stopped only while the rate falls (the burst was its own). A rate that doesn't fall is outside work: the run
# resumes and isn't paused again for HOLD_OFF_S.
START_RATE_S = 1.0
START_RATE_WINDOW = 3     # readings averaged for the cap check
PAUSE_MAX_S = 3.0
HOLD_OFF_S = 60.0
PAUSE_REPORT_S = 30.0     # at most one stderr line per this while a run keeps being paused
FAKE_START_RATE = os.environ.get("TESTSLOT_FAKE_START_RATE", "")  # tests: a file holding the host rate, as TESTSLOT_OBSERVED is for cpu
# debt: logs are pruned by age only (14 days, own files, at each run); a burst of huge logs could
# still fill the disk. Upgrade: a size cap in prune_logs.
LOG_DAYS = 14
# history.jsonl rolls over to history.jsonl.1 past this size (one old generation is kept): as of 2026-10-20 a line
# is about 500 bytes on average (a Linux host 497, a Mac 546), up to some 750 with a long key and a long command, so
# 7,000 to 10,000 runs each, and summary sees a few weeks back.
HISTORY_MAX = int(os.environ.get("TESTSLOT_HISTORY_MAX", 5 * 1024 * 1024))  # tests set it small


# Tests only: TESTSLOT_TEST_CLOCK names a file holding the time (seconds, a number) that the load pause's reads use instead of the
# wall clock: the pause and resume stamps, pausing(), and the settle window's state. A missing or bad file means the wall clock.
TEST_CLOCK = os.environ.get("TESTSLOT_TEST_CLOCK", "")


def now():
    """The time the load pause reads: the wall clock, or in tests the number in the TESTSLOT_TEST_CLOCK file."""
    if TEST_CLOCK:
        try:
            t = float((_read(TEST_CLOCK) or "").strip())
            if math.isfinite(t):
                return t
        except ValueError:
            pass
    return time.time()


# The settle window: the least time between two load pauses, and between two load resumes, across every run on the host.
# 1-minute load lags a pause by tens of seconds, so about half of that: 30 s unless set, 5 to 300.
PAUSE_WINDOW_DEFAULT, PAUSE_WINDOW_MIN, PAUSE_WINDOW_MAX = 30.0, 5.0, 300.0


def read_pause_window():
    """Seconds of the settle window: TESTSLOT_PAUSE_WINDOW, else $DIR/pause-window, else 30; a value is held to 5..300 and a
    bad one falls through to the next source. Read live, so a change reaches every wrapper at its next tick."""
    for src in (os.environ.get("TESTSLOT_PAUSE_WINDOW"), _read(os.path.join(DIR, "pause-window"))):
        try:
            if src and src.strip() and math.isfinite(float(src.strip())):
                return min(PAUSE_WINDOW_MAX, max(PAUSE_WINDOW_MIN, float(src.strip())))
        except ValueError:
            pass
    return PAUSE_WINDOW_DEFAULT


def loadavg():
    """The 1, 5 and 15-minute load averages."""
    if not LOADAVG:
        return list(os.getloadavg())
    try:
        return [float(x) for x in (_read(LOADAVG) or "").split()[:3]] or [0.0, 0.0, 0.0]
    except ValueError:
        return [0.0, 0.0, 0.0]


# A head that over_load_cap holds back can't start while anything holds (why_wait checks the same thing), so
# reserving for it at once would idle the box for nothing: smaller runs keep backfilling past it. To keep it from
# starving behind a stream of them, it reserves after this many times RESERVE, and then blocks every later run,
# fitting ones too, until the holders drain and it starts on the idle slot: that is the intended trade against
# starvation, not a bug. A --heavy run is the exception: it always takes the whole cap, so the plain RESERVE is
# how it drains the slot. Default 600 s x 6 = one hour (as of 2026-10-21).
IDLE_ONLY_RESERVE_X = 6


# Load pause: while the 1-minute load is over LOAD_TRIGGER_X times the cores, the one run
# using the most above what it declared pauses (SIGSTOP), and resumes once the load is under the load cap.
LOAD_TRIGGER_X = 1.5


# Requeue, the last resort after the load pause: a light run whose unpaused reading is over REQUEUE_X
# times what it declared, and has been paused by the load pause for REQUEUE_AFTER_S (counted from its first load pause since it
# went over), with the load still over the load trigger and another run going, is stopped as a cancel and started again once,
# at the head of the queue, declaring its measured peak. The clock starts at the pause, never earlier: the pause must have had its turn.
REQUEUE_X = 2.0
try:
    REQUEUE_AFTER_S = float(os.environ.get("TESTSLOT_REQUEUE_AFTER_S") or 300)
    REQUEUE_AFTER_S = min(86400.0, max(1.0, REQUEUE_AFTER_S)) if math.isfinite(REQUEUE_AFTER_S) else 300.0  # tests set it small
except ValueError:
    REQUEUE_AFTER_S = 300.0
