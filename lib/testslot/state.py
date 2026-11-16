import fcntl
import json
import math
import os
import subprocess
import time
from testslot import cgroup
from testslot import config
from testslot import procs


MY_QUEUED = None  # when this run queued, so waiters name only runs queued ahead of it


def cpus_of(h):
    """The cpus a holder record counts for: the size it asked for, held to the cap as it is now, so a cap that
    moves while it waits or runs moves its size too; a record from before --cpus counts by its kind.
    A run still going when the cap is lowered counts at the lowered size, so the box can hold more than the
    cap until it ends: running runs are left alone."""
    if h.get("kind") == "track":
        return 0
    if h.get("kind") == "heavy":
        return config.read_cap()  # the box to itself, whatever the cap is now
    if isinstance(h.get("cpus"), int):
        return min(h["cpus"], config.read_cap())  # the size asked for, held to the cap as it stands now
    return 1


def valid_observed(h):
    """The reading a holder's wrapper last recorded, in cores, or None when there is no usable one: none yet
    (an old record, or a run not yet sampled), not a finite number in range (hand-edited, or a failed read),
    or an orphan's (its wrapper is gone, so the reading is stale)."""
    seen = h.get("observed")
    if isinstance(seen, bool) or not isinstance(seen, (int, float)) or h.get("orphan"):
        return None
    if not math.isfinite(seen) or seen < 0 or seen > 4 * max(config.CORES, config.read_cap()):
        return None
    return float(seen)


def charged_cpus(h):
    """What a holder costs the cap: the larger of what it declared and what its wrapper last saw it use, in
    cores, held to the cap as it is now (a heavy run is the whole cap). With no usable reading, what it declared."""
    declared = cpus_of(h)
    if pausing(h):
        return declared  # a paused run takes its cpus back on resume: nothing may be admitted into them
    seen = valid_observed(h)
    if seen is None:
        return declared
    if shrunk(h, declared, seen):
        margin = h.get("shrink_margin")  # the margin as the run's wrapper read it, so every reader charges the same
        if isinstance(margin, bool) or not isinstance(margin, (int, float)) or not 0 <= margin <= 64:
            margin = config.SHRINK_MARGIN
        return min(declared, max(1.0, seen + margin))
    return min(max(declared, seen), config.read_cap())


def pausing(h):
    """Whether a holder's run is paused by the start-rate throttle or by the load pause, or resumed within
    max(SAMPLE_S, 0.5) + START_RATE_S seconds (its cpu sample may still include paused time, so its low reading
    says nothing about what the run uses)."""
    for k in ("paused_since", "load_paused_since"):
        if isinstance(h.get(k), (int, float)) and not isinstance(h.get(k), bool):
            return True
    back = h.get("resumed_at")
    return (isinstance(back, (int, float)) and not isinstance(back, bool)
            and 0 <= time.time() - back <= max(config.SAMPLE_S, 0.5) + config.START_RATE_S)


def record_shrink_after(h):
    """N as a holder's wrapper recorded it, for status: a finite number of seconds in the clamp range, else this process's."""
    n = h.get("shrink_after")
    if isinstance(n, bool) or not isinstance(n, (int, float)) or not math.isfinite(n) or not 1 <= n <= 86400:
        return config.SHRINK_AFTER_S
    return float(n)


def shrunk(h, declared, seen):
    """Whether a holder is charged its observed cpu plus the margin, not its declaration: its wrapper has seen it under
    its declaration for SHRINK_AFTER_S (`shrunk` in the record, rewritten every sample), the reading is a cgroup's (a
    process-group reading undercounts, so it never shrinks), and the latest reading is still under the declaration, so
    one that climbs back to its declaration is charged in full at once, without waiting for the wrapper's next write.
    A record whose wrapper has not rewritten it for 4 sample intervals + 1 s (its sampler died) is charged in full."""
    if not (h.get("shrunk") is True and h.get("observed_via") == "cgroup" and h.get("kind") == "light" and seen < declared):
        return False
    stamp, every = h.get("sampled_at"), h.get("sample_s")
    if isinstance(stamp, bool) or not isinstance(stamp, (int, float)) or not math.isfinite(stamp):
        return False
    if isinstance(every, bool) or not isinstance(every, (int, float)) or not math.isfinite(every):
        every = config.SAMPLE_S
    # a record's own interval counts for at most 4 times this process's, so a forged one can't keep a charge shrunk for hours
    # debt: wall clock, since the stamp crosses processes; a clock that jumps only ever makes the charge full again
    return abs(time.time() - stamp) <= 4 * min(max(every, 0.5), 4 * config.SAMPLE_S) + 1


def holds_cpus(h):
    """Admitted and not finished: its cpus count against the cap (an orphaned command still burns them)."""
    return h.get("state") in ("admitted", "running") and h.get("kind") != "track"


def read_holders():
    """Live wrapper records and orphans with a live process group or cgroup, oldest first."""
    # debt: records are read through links (only writes refuse them); a planted record's fields reach
    # status and a waiter's stderr. Upgrade: O_NOFOLLOW reads, and skip a record not owned by its account.
    out = []
    try:
        names = os.listdir(config.HOLDERS)
    except FileNotFoundError:
        return out
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            with open(os.path.join(config.HOLDERS, n), encoding="utf-8") as f:
                h = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(h, dict) or not isinstance(h.get("pid"), int):
            continue
        # another account wrote it, maybe by hand or half-way: fill what status and the waiters print
        for k, v in (("account", "?"), ("kind", "?"), ("repo", "?"), ("command", ""), ("state", "?")):
            if not isinstance(h.get(k), str):
                h[k] = v
        for k in ("queued", "since", "cpus", "pgid", "observed"):  # sorted and subtracted: a string here crashed every run
            if k in h and (isinstance(h[k], bool) or not isinstance(h[k], (int, float))):
                h[k] = None if k != "queued" else 0
        if procs.alive(h.get("pid", -1), h.get("start")):
            h["orphan"] = False  # from liveness only: a record can't claim it (an orphan's scope is followed on that word)
            out.append(h)
        elif h.get("pgid") and (procs.group_alive(h["pgid"]) or cgroup.scope_pids(cgroup.scope_dir(h.get("cgroup"), h["pid"]))):
            # the wrapper was killed outright: its slot is gone, but its command still runs (maybe only a setsid
            # child in its scope, once the leader has exited)
            h["orphan"] = True
            if h.get("paused_since") or h.get("load_paused_since"):
                cgroup.resume_orphan(h)
            out.append(h)
    return sorted(out, key=lambda h: h.get("queued", 0))


def describe_holders(mine=None):
    """One line per current holder, for a waiting run to print."""
    hs = read_holders()
    lines = [f"{h.get('account')} {h.get('kind')} in {h.get('repo')}, {cpus_of(h)} cpus: {h.get('command')} (pgid {h.get('pgid')})"
             for h in hs if holds_cpus(h)]
    # a run queued earlier goes first, so it is what a later run waits behind too
    lines += [f"{h.get('account')} {h.get('kind')}, waiting ahead of you, in {h.get('repo')}, {cpus_of(h)} cpus: {h.get('command')}"
              for h in hs if h.get("state") == "waiting" and h["pid"] != os.getpid() and h.get("kind") != "track"
              and (mine is None or h.get("queued", 0) < mine) and not procs.stopped(h["pid"])]
    known = {h["pid"] for h in hs} | {h.get("pgid") for h in hs if h.get("pgid")}
    for pid, how in procs.outside_runs(known):
        acct, cwd, cmd = procs.proc_info(pid)
        note = procs.outside_note() if how == "flock" else ""
        lines.append(f"{acct} outside testslot in {cwd}: {cmd} (pid {pid})" + (f" [{note}]" if note else ""))
    return lines or ["another run"]


def repo_dir():
    try:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, errors="replace", timeout=5)
        if top.returncode == 0 and top.stdout.strip():
            return top.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    return os.getcwd()


def write_holder(path, rec):
    tmp = f"{path}.{os.getpid()}.{time.time_ns()}.tmp"  # never another account's leftover
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o664)
    os.fchmod(fd, 0o664)  # O_EXCL made it, so it is ours
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(rec, f)
    os.replace(tmp, path)


def own_mode(fd, mode):
    """chmod an open file only if this account owns it. Every account can replace files in the shared
    folder, so a name there may now be a link to someone's private file: never widen that file's mode."""
    try:
        if os.fstat(fd).st_uid == os.getuid():
            os.fchmod(fd, mode)
    except OSError:
        pass


def history_line(h, ended, code):
    """The history record for a finished run: plain fields, so another backend could write the same."""
    started = h.get("since")
    return {"pid": h.get("pid"), "pgid": h.get("pgid"), "account": h.get("account"), "repo": h.get("repo"),
            "command": (h.get("command") or "")[:500], "kind": h.get("kind"), "cpus": cpus_of(h),
            "queued": h.get("queued"), "started": started, "ended": ended, "exit": code,
            "wait_s": round(started - h["queued"], 3) if started and h.get("queued") else None,
            "run_s": round(ended - started, 3) if started and ended else None,
            "load_at_start": h.get("load_at_start"), "cancelled": bool(h.get("cancelled")), "log": h.get("log"),
            "backfill": bool(h.get("backfill")), "requeued": bool(h.get("requeued_from")),
            "stop_reason": h.get("stop_reason") if isinstance(h.get("stop_reason"), str) else None,
            "limit_s": h.get("limit_s") if isinstance(h.get("limit_s"), (int, float)) and not isinstance(h.get("limit_s"), bool) else None,
            "wait_reason": h.get("wait_reason") if isinstance(h.get("wait_reason"), str) else "",
            "requeue_peak": h.get("requeue_peak") if isinstance(h.get("requeue_peak"), (int, float)) and not isinstance(h.get("requeue_peak"), bool) else None,
            "pauses": h.get("pauses") or 0, "paused_s": round(h.get("paused_s") or 0, 2),
            "max_pause_s": round(h.get("max_pause_s") or 0, 2),
            "key": h.get("key"), "peak": h.get("peak") if isinstance(h.get("peak"), (int, float)) else None,
            "cpu_s": h.get("cpu_s") if isinstance(h.get("cpu_s"), (int, float)) and not isinstance(h.get("cpu_s"), bool) else None}


def append_history(rec):
    """Append one line to history.jsonl, rolling it to history.jsonl.1 past HISTORY_MAX.
    Never fails the run: history is a record, not a gate."""
    data = (json.dumps(rec) + "\n").encode()
    for _ in range(5):
        try:
            # O_NOFOLLOW: another account may have swapped the name for a link to a file of ours
            fd = os.open(config.HISTORY, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o664)
        except OSError:
            return
        own_mode(fd, 0o664)  # umask 022 would leave the creator's file shut to the other account
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            try:
                same = os.stat(config.HISTORY).st_ino == os.fstat(fd).st_ino
            except FileNotFoundError:
                same = False
            if not same:  # rolled over while we waited for the lock: open the new file
                continue
            if os.fstat(fd).st_size > config.HISTORY_MAX:
                os.replace(config.HISTORY, config.HISTORY + ".1")  # under the lock; the next pass opens a fresh file
                continue
            try:
                os.fchmod(fd, 0o664)  # the other account appends too; umask 022 drops the group bit
            except OSError:
                pass  # not ours to chmod: the creator already did
            os.write(fd, data)
            return
        except OSError:
            return
        finally:
            os.close(fd)


def prune(me):
    """Drop holder files of dead processes (an admitted one leaves a history line, marked lost unless
    it recorded its exit), and this account's logs older than LOG_DAYS."""
    try:
        for n in os.listdir(config.HOLDERS):
            p = os.path.join(config.HOLDERS, n)
            try:
                if n.endswith(".tmp") and time.time() - os.stat(p).st_mtime > 60:
                    os.unlink(p)
                elif n.endswith(".json") and n[:-5].isdigit():
                    with open(p, encoding="utf-8") as f:
                        h = json.load(f)
                    if procs.alive(int(n[:-5]), h.get("start")):
                        continue
                    pg = h.get("pgid")
                    if not (pg and (procs.group_alive(pg) or cgroup.scope_pids(cgroup.scope_dir(h.get("cgroup"), h.get("pid"))))):
                        os.unlink(p)  # whoever unlinks it writes its history, so it is written once
                        if h.get("since"):
                            line = history_line(h, h.get("ended") or time.time(), h.get("exit"))
                            line["lost"] = "exit" not in h
                            append_history(line)
            except (OSError, ValueError, AttributeError, TypeError):
                pass
        cutoff = time.time() - config.LOG_DAYS * 86400
        for n in os.listdir(config.LOGS):
            p = os.path.join(config.LOGS, n)
            if n.startswith(me + "-"):
                try:
                    if os.stat(p).st_mtime < cutoff:
                        os.unlink(p)
                except OSError:
                    pass
    except OSError:
        pass
