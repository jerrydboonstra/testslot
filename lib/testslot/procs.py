import json
import math
import os
import pwd
import re
import subprocess
import time
from testslot import config


_PS = (-math.inf, {})  # not 0.0: a clock near 0 (a fresh boot, a sandbox) would take this empty table for a fresh listing
_PS_FAILED = -1e9  # when ps last failed three times: for 2s after, callers hear so at once, not after 30s more


class PsFailed(Exception):
    """ps gave no usable listing, three times. Callers fail closed: a process counts as alive (its slot
    stays taken, its group is still signalled), and a run that can't tell, before it holds a slot, stops."""


def ps_table():
    """pid -> (state, ppid, pgid, start) for every process, from one ps call, reused for 0.2s: the
    macOS stand-in for /proc. start is ps's lstart text, which is all a reused pid check needs."""
    # debt: a ps that hangs (not fails) still costs about 16s per check once the 2s failure cache runs
    # out, so teardown under a hung ps can take a minute or two. Upgrade: sysctl(KERN_PROC) through ctypes.
    global _PS, _PS_FAILED
    now = time.monotonic()
    if now - _PS[0] < 0.2:
        return _PS[1]
    if now - _PS_FAILED < 2:
        raise PsFailed()
    # A failed ps (fork EAGAIN, a timeout) must never read as "no processes": every holder would look
    # dead, so runs would be admitted over the cap and live holders pruned. An older table won't do either
    # (anything newer is missing from it). So: retry, then raise PsFailed, and each caller fails closed.
    for attempt in range(3):
        table = {}
        try:
            r = subprocess.run(["ps", "-Ao", "pid=,ppid=,pgid=,stat=,lstart="], capture_output=True,
                               text=True, errors="replace", timeout=5, env=dict(os.environ, LC_ALL="C"))
            out = r.stdout if r.returncode == 0 else ""
        except (OSError, subprocess.TimeoutExpired):
            out = ""
        for line in out.splitlines():
            f = line.split(None, 4)
            if len(f) == 5 and f[0].isdigit():
                table[int(f[0])] = (f[3][0], int(f[1]), int(f[2]), " ".join(f[4].split()))
        if os.getpid() in table:  # a real listing always has this process in it
            _PS = (now, table)
            return table
        time.sleep(0.2 * (attempt + 1))
    _PS_FAILED = time.monotonic()
    raise PsFailed()


def proc_stat(pid):
    """(state, start time) of a pid, or None if it is gone: from /proc on Linux (start in clock ticks),
    from ps elsewhere (start as ps prints it)."""
    if not config.LINUX:
        p = ps_table().get(pid)
        return (p[0], p[3]) if p else None
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8", errors="replace") as f:
            fields = f.read().rsplit(")", 1)[1].split()
        return fields[0], int(fields[19])
    except (OSError, IndexError, ValueError):
        return None


def signal_reaches(probe):
    """Without ps, the kernel still says whether a pid or group exists: signal 0 checks, sends nothing.
    A zombie counts as present here, so this errs toward alive."""
    try:
        probe()
        return True
    except ProcessLookupError:
        return False
    except OSError:
        return True  # exists, but another account's


def alive(pid, start=None):
    """A live process: present in /proc and not a zombie (a killed wrapper nobody has reaped yet).
    Given the start time a holder recorded, a reused pid (another process since) counts as gone."""
    try:
        st = proc_stat(pid)
    except PsFailed:
        return signal_reaches(lambda: os.kill(pid, 0))  # can't check its start: a live pid counts
    return bool(st) and st[0] != "Z" and (start is None or st[1] == start)


def stopped(pid):
    """Stopped (Ctrl-Z, SIGSTOP): a waiting run in this state gives up its place rather than block the queue."""
    try:
        st = proc_stat(pid)
    except PsFailed:
        return False  # not known to be stopped: it keeps its place
    return bool(st) and st[0] in ("T", "t")


def group_alive(pgid):
    """Whether any process is still in process group pgid (its leader may have exited)."""
    if not config.LINUX:
        try:
            return any(p[2] == pgid and p[0] != "Z" for p in ps_table().values())
        except PsFailed:
            return signal_reaches(lambda: os.killpg(pgid, 0))
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                with open(f"/proc/{d}/stat", encoding="utf-8", errors="replace") as f:
                    st = f.read()
            except OSError:
                continue
            try:
                f = st.rsplit(")", 1)[1].split()
                if int(f[2]) == pgid and f[0] != "Z":
                    return True
            except (IndexError, ValueError):
                continue
    return False


def ancestors():
    """Pids of this process's ancestors, nearest first."""
    out, pid = [], os.getpid()
    if not config.LINUX:
        table = ps_table()
        while pid > 1 and pid in table and len(out) < 200:
            pid = table[pid][1]
            out.append(pid)
        return out
    while pid > 1:
        try:
            with open(f"/proc/{pid}/stat", encoding="utf-8", errors="replace") as f:
                pid = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, IndexError, ValueError):
            break
        out.append(pid)
    return out


def holds_running(pid, kind, start):
    """Whether pid's holder record says it is an admitted or running testslot wrapper of this kind, started then."""
    try:
        with open(os.path.join(config.HOLDERS, f"{pid}.json"), encoding="utf-8") as f:
            h = json.load(f)
        # "admitted" too: the command (and so a nested run) can start before the wrapper writes "running"
        return h.get("state") in ("admitted", "running") and h.get("kind") == kind and str(h.get("start")) == start
    except (OSError, ValueError, AttributeError):
        return False


def held_by_ancestor():
    """'heavy' or 'light' if one of our ancestors holds the gate (WRITE or READ in /proc/locks), else ''.
    The lock table is the proof, not an inherited variable: a daemon started under a run keeps the
    variables for life, long after the run's slot is gone.
    Without /proc/locks (macOS) the proof is TESTSLOT_HELD="<kind>:<wrapper pid>:<its start>", checked
    against our live ancestors and the wrapper's own holder record: a daemon that outlived its run, or
    was reparented, no longer counts, and neither does an ancestor that isn't a running wrapper (pid 1).
    Like the gate itself, this is cooperative: an account that forges a holder record skips the queue."""
    if not config.LINUX:
        kind, _, rest = os.environ.get("TESTSLOT_HELD", "").partition(":")
        wpid, _, start = rest.partition(":")
        if (kind in ("heavy", "light") and wpid.isdigit() and int(wpid) > 1 and int(wpid) in ancestors()
                and alive(int(wpid), start) and holds_running(int(wpid), kind, start)):
            return kind
        # debt: no lock table here, so a run nested under test-parallel's own LOCK_EX (not under testslot)
        # would wait on its parent. On the Mac nothing points CAT_HERDER_TEST_SLOT at this gate's heavy
        # file, so test-parallel never takes it. Since 0.53.3 test-parallel sets TESTSLOT_HELD="local:<pid>:<t>",
        # which the kind check above rejects. Upgrade: accept kind "local" once a run can prove it.
        return ""
    locks = heavy_lockers()
    real = os.path.realpath(config.HEAVY)
    for pid in ancestors():
        if pid in locks and has_open(pid, real):
            return "heavy" if locks[pid] == "WRITE" else "light"
    return ""


def has_open(pid, path):
    """Whether pid has path open: rules out a same-inode flock on another filesystem. An ancestor of
    another account can't be read; trust the lock table then."""
    try:
        fds = os.listdir(f"/proc/{pid}/fd")
    except OSError:
        return True
    for fd in fds:
        try:
            if os.readlink(f"/proc/{pid}/fd/{fd}") == path:
                return True
        except OSError:
            pass
    return False


def heavy_lockers():
    """pid -> 'WRITE'|'READ' for every process holding a flock on the heavy file, from /proc/locks.
    This sees runs that never went through testslot (test-parallel on its own). Linux only: macOS
    has no lock table to read, so this finds nothing there; test_parallel_runs() still finds a test-parallel by ps."""
    # debt: on macOS status says "free" while another flock holder outside testslot (not a test-parallel,
    # which test_parallel_runs lists by name) holds the gate; admission still waits on it. Upgrade: lsof on
    # the heavy file, which is slow, so only when a run is waiting.
    if not config.LINUX:
        return {}
    try:
        st = os.stat(config.HEAVY)
        with open("/proc/locks", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return {}
    # debt: matches on the inode number alone, since on btrfs stat's st_dev (the subvolume's anonymous
    # device) differs from the superblock device /proc/locks prints. Another filesystem's file with the
    # same inode number would be miscounted; upgrade: resolve the subvolume's device via its mount.
    ino = f":{st.st_ino}"
    found = {}
    for line in lines:
        parts = line.split()
        if "->" in parts:  # a blocked waiter, not a holder
            continue
        if len(parts) >= 6 and parts[1] == "FLOCK" and parts[5].endswith(ino):
            found[int(parts[4])] = parts[3]
    return found


WRAPPERS = {"env", "timeout", "nice", "nohup", "setsid", "caffeinate", "ionice", "taskset", "stdbuf", "time"}


def test_parallel_runs():
    """pid -> pgid of every running `tools/test-parallel` (Cat Herder's suite runner), whoever started it.
    Cat Herder starts it by itself (remote-test, a hand run), outside testslot, and it takes the heavy flock
    only when CAT_HERDER_TEST_SLOT points there, so heavy_lockers() may not see it. A
    worker that test-parallel forks is another program. Only the first test-parallel seen in each process
    group is kept, which is its parent while ps lists by ascending pid."""
    # debt: matches Cat Herder's runner by name; another suite runner outside testslot still goes unseen.
    # Upgrade: count CPU by process group against the holders' groups.
    try:
        out = subprocess.run(["ps", "-Ao", "pid=,pgid=,args="], capture_output=True, text=True, errors="replace", timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    found = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3 or not parts[0].isdigit() or not parts[1].lstrip("-").isdigit():
            continue
        # the runner itself, perhaps behind interpreters, wrappers and their flags (`python3 -u tools/test-parallel`,
        # `timeout 600 env X=1 tools/test-parallel`), but never as another program's argument (`pgrep -f test-parallel`)
        hit = False
        for a in parts[2].split()[:8]:
            if a == "test-parallel" or a.endswith("/test-parallel"):
                hit = True
                break
            if not (re.fullmatch(r"python[0-9.]*|bash|sh|zsh", os.path.basename(a), re.I) or os.path.basename(a) in WRAPPERS
                    or a.startswith("-") or re.fullmatch(r"[0-9]+(\.[0-9]+)?[smhd]?", a) or "=" in a):
                break
        if hit:
            pid, pgid = int(parts[0]), int(parts[1])
            if pgid not in found.values():
                found[pid] = pgid
    return found


def outside_runs(known):
    """(pid, how) for each run outside testslot: a flock on the heavy file, or a test-parallel whose
    group is not a holder's. known is the holders' pids and pgids."""
    seen, runs = set(), []
    for p in heavy_lockers():
        if p not in known:
            seen.add(p)
            runs.append((p, "flock"))
    for p, pg in test_parallel_runs().items():
        if p in known or pg in known or p in seen:
            continue
        runs.append((p, "test-parallel"))
    return runs


def proc_info(pid):
    """(account, cwd, command) for a pid, as far as this account may read it."""
    if not config.LINUX:
        def out(cmd):
            try:
                return subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=5).stdout.strip()
            except (OSError, subprocess.TimeoutExpired):
                return ""
        cwd = next((l[1:] for l in out(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"]).splitlines()
                    if l.startswith("n")), "?")
        return (out(["ps", "-o", "user=", "-p", str(pid)]) or "?", cwd,
                out(["ps", "-o", "command=", "-p", str(pid)]) or "?")
    try:
        uid = os.stat(f"/proc/{pid}").st_uid
        acct = pwd.getpwuid(uid).pw_name
    except (OSError, KeyError):
        acct = "?"
    try:
        cwd = os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        cwd = "?"
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            cmd = " ".join(a.decode(errors="replace") for a in f.read().split(b"\0") if a)
    except OSError:
        cmd = "?"
    return acct, cwd, cmd


def outside_note():
    """What test-parallel wrote into the heavy file ("<cwd>, pid N, since T"), readable by both accounts,
    where /proc/<pid>/cwd of the other account is not."""
    try:
        with open(config.HEAVY, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""
