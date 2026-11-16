import json
import os
import shutil
import signal
import subprocess
import sys
import time
from testslot import config
from testslot import procs
from testslot import util


def resume_orphan(h):
    """A wrapper killed while the throttle had its run stopped: CONT the group and its scope, so the run never sits
    frozen without a slot. Safe to repeat (a running group ignores it), so every read that finds the orphan sends it."""
    try:
        os.killpg(h["pgid"], signal.SIGCONT)
    except OSError:
        pass  # gone, or another account's (its own status resumes it)
    signal_scope(holder_scope(h, False), signal.SIGCONT)


def group_cpu_seconds(pgid, seen):
    """Cpu seconds used so far by the processes that have been in a process group (user + system), or None if
    the processes can't be listed. `seen` maps pid to the most cpu time that pid has shown, and is kept by the
    caller between calls: a process that has exited drops out of the listing, but its cpu stays in the total.
    (Counting reaped children through their parent would count that cpu twice.) Limit: a process that starts and
    exits between two samples is never seen, so its cpu is never counted; the sampler is after what holds a slot
    (long-lived processes such as a python at 400%), and a run of many short-lived children reads low.
    This is the fallback and the macOS path; a Linux run in a cgroup is read by cgroup_cpu_seconds, which has
    neither gap and is not escaped by a descendant that calls setsid.
    debt: the dict holds a float per process it observes, and a pid reused inside the group keeps the larger
    of the two readings. Upgrade: none planned, since Linux has the cgroup.
    Linux: /proc stat fields. macOS: ps's cumulative time, not %cpu, which there is a lifetime average.
    Never raises, and a ps that hangs is killed after 2 s."""
    if config.LINUX:
        try:
            names = os.listdir("/proc")
        except OSError:
            return None
        ticks = os.sysconf("SC_CLK_TCK")
        for n in names:
            if not n.isdigit():
                continue
            try:
                with open(f"/proc/{n}/stat", encoding="utf-8", errors="replace") as f:
                    fields = f.read().rsplit(")", 1)[1].split()
                if int(fields[2]) == pgid:
                    seen[int(n)] = max(seen.get(int(n), 0.0), (int(fields[11]) + int(fields[12])) / ticks)  # utime stime
            except (OSError, IndexError, ValueError):
                continue  # gone since the listing
    else:
        try:
            r = subprocess.run(["ps", "-Ao", "pid=,pgid=,time="], capture_output=True, text=True, errors="replace", timeout=2,
                               env=dict(os.environ, LC_ALL="C"))
        except (OSError, subprocess.TimeoutExpired):
            return None
        if r.returncode != 0:
            return None
        for line in r.stdout.splitlines():
            f = line.split()
            if len(f) == 3 and f[0].isdigit() and f[1] == str(pgid) and util.clock_seconds(f[2]) is not None:
                seen[int(f[0])] = max(seen.get(int(f[0]), 0.0), util.clock_seconds(f[2]))
    return sum(seen.values()) if seen else None


def scope_dir(path, pid):
    """The cgroup directory a holder record names, or None unless it is this wrapper's own testslot scope under the
    cgroup root: its name is testslot-<wrapper pid>-<time>.scope. A record is group-writable, so what it names is
    checked before anything is read or signalled, and one forged to name another run's scope is not followed."""
    if not isinstance(path, str) or not path.startswith(config.CGROUP_ROOT + "/") or isinstance(pid, bool) or not isinstance(pid, int):
        return None
    real = os.path.realpath(path)
    name = os.path.basename(real)
    ok = real == path and name.startswith(f"testslot-{pid}-") and name.endswith(".scope")
    return real if ok else None


def proc_cgroup(pid):
    """The cgroup path /proc says a process is in (as it appears after the root), or None."""
    try:
        with open(f"/proc/{pid}/cgroup", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("0::"):
                    return line.strip()[3:]
    except OSError:
        pass
    return None


def parent_of(pid):
    """The parent pid of a process, or None when it is gone."""
    try:
        if config.LINUX:
            with open(f"/proc/{pid}/stat", encoding="utf-8", errors="replace") as f:
                return int(f.read().rsplit(")", 1)[1].split()[1])
        p = procs.ps_table().get(pid)
        return p[1] if p else None
    except (OSError, IndexError, ValueError, procs.PsFailed):
        return None


def holder_scope(h, genuine):
    """The cgroup directory of a holder's run that may be followed (read or signalled), or None. A record is
    group-writable, so one forged to name another run's scope must not be followed. The scope must carry the
    holder's pid in its name; when the group's leader exists it must be in that very cgroup, and its record must be
    the genuine one (its wrapper the leader's parent) unless the wrapper is gone (an orphan). With the leader gone
    only an orphan's scope is followed (its name is all there is to check)."""
    d = scope_dir(h.get("cgroup"), h.get("pid"))
    if not d:
        return None
    pg = h.get("pgid")
    lead = proc_cgroup(pg) if pg else None
    if lead is not None:
        return d if lead == d[len(config.CGROUP_ROOT):] and (genuine or h.get("orphan")) else None
    return d if h.get("orphan") else None


def scope_pids(d):
    """The pids in a cgroup, [] when it is gone (a scope vanishes when its last process does) or unreadable."""
    if not d:
        return []
    try:
        with open(os.path.join(d, "cgroup.procs"), encoding="utf-8") as f:
            return [int(x) for x in f.read().split()]
    except (OSError, ValueError):
        return []


def signal_scope(d, sig):
    """Send sig to every process in the cgroup (a child that called setsid is in no group of the run's)."""
    for p in scope_pids(d):
        try:
            os.kill(p, sig)
        except OSError:
            pass


def kill_scope(d):
    """KILL everything in the cgroup: cgroup.kill (Linux 5.14+) in one go, else signal what cgroup.procs lists,
    again until it is empty (a process can fork while the list is read)."""
    if not d:
        return
    try:
        with open(os.path.join(d, "cgroup.kill"), "w", encoding="utf-8") as f:
            f.write("1")
        return
    except OSError:
        pass
    for _ in range(5):
        if not scope_pids(d):
            return
        signal_scope(d, signal.SIGKILL)
        time.sleep(0.05)


def cgroup_cpu_seconds(d):
    """Cpu seconds the cgroup has used (cpu.stat usage_usec: user + system, every process it ever held, exited
    ones included), or None when it can't be read."""
    try:
        with open(os.path.join(d, "cpu.stat"), encoding="utf-8") as f:
            for line in f:
                key, _, val = line.partition(" ")
                if key == "usage_usec":
                    return int(val) / 1e6
    except (OSError, ValueError):
        pass
    return None


def scope_command(command, unit):
    """(argv to run the command in a user scope named unit, None, extra env), or (command, why not, {}) when no scope can
    be made: forced off, no cgroup v2, or a command too long for the environment. A launch that then fails is caught
    by the caller (no marker byte), not probed for here: a probe would cost a second scope inside the slot on every
    run. A command that isn't found goes straight to Popen, which reports it as 127 as it always did. The command travels in the environment and a python one-liner execs it:
    systemd-run rewrites its arguments (a `$$` becomes `$`), and the command must run exactly as typed."""
    if config.NO_CGROUP:
        return command, "TESTSLOT_NO_CGROUP is set", {}
    if not config.LINUX:
        return command, None, {}
    if shutil.which(command[0], path=os.environ.get("PATH")) is None:
        return command, None, {}
    if not os.path.exists(os.path.join(config.CGROUP_ROOT, "cgroup.controllers")):
        return command, "no cgroup v2 here", {}
    packed = json.dumps(command)
    if len(packed) > 100_000:  # one environment string is capped at 128 KiB (MAX_ARG_STRLEN)
        return command, "the command is too long to pass through the environment", {}
    base = ["systemd-run", "--user", "--scope", "--quiet", "--collect"]
    # The byte on TESTSLOT_MARKFD tells the wrapper the scope started and the command is about to run. The write is
    # not guarded: if the byte can't be written the command must not run, and the wrapper, seeing the pipe end with no
    # byte, runs it once on the group path. Closing the pipe is guarded (it only matters after the byte is sent).
    prog = ("import os,json\nfd = int(os.environ.pop('TESTSLOT_MARKFD'))\nos.write(fd, b'1')\n"
            "try:\n os.close(fd)\nexcept OSError:\n pass\n"
            "a = json.loads(os.environ.pop('TESTSLOT_ARGV'))\nos.execvp(a[0], a)")
    return base + ["--unit", unit, "--", sys.executable, "-c", prog], None, {"TESTSLOT_ARGV": packed}


def find_scope(proc, unit, owner):
    """(the cgroup directory of the scope proc has moved into (named for wrapper `owner`), None), or (None, why not):
    it polls up to 3 s for a scope that exists with a cpu.stat that reads. A command that ends before the scope is
    seen ends the poll at once (it has exited); one that lives on without a scope costs the 3 s."""
    pid = proc.pid
    want = "/" + unit + ".scope"
    end = time.monotonic() + 3
    why = "its scope was not found (the command may have ended first)"
    while True:
        try:
            with open(f"/proc/{pid}/cgroup", encoding="utf-8", errors="replace") as f:
                for line in f:
                    path = line.strip().partition("::")[2]
                    if line.startswith("0::") and path.endswith(want):
                        d = scope_dir(config.CGROUP_ROOT + path, owner)
                        if d and os.path.isdir(d):
                            if cgroup_cpu_seconds(d) is not None:
                                return d, None  # a directory we can read cpu from; else keep polling, then fall back
                            why = "its cpu.stat is not readable"
        except OSError:
            return None, why
        if time.monotonic() > end or proc.poll() is not None:
            return None, why
        time.sleep(0.01)


def read_marker(fd, seconds):
    """What the launcher's pipe says within `seconds`: "byte" (the scope started and the command is about to run),
    "eof" (every writer is gone and no byte came, so the command never ran), or "timeout" (neither yet: unknown).
    The read end must stay open until a byte or the end of the file, or the one-liner's write would break."""
    end = time.monotonic() + seconds
    while True:
        try:
            return "byte" if os.read(fd, 1) == b"1" else "eof"
        except BlockingIOError:
            pass
        except OSError:
            return "eof"
        if time.monotonic() > end:
            return "timeout"
        time.sleep(0.01)
