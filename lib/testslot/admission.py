import fcntl
import hashlib
import os
import re
import signal
import sys
import time
from testslot import config
from testslot import procs
from testslot import state
from testslot import util


def waiters_ahead(hs, me, mine):
    """The waiting runs queued before the one at `mine`, in turn order."""
    return [h for h in hs if h.get("state") == "waiting" and h.get("kind") != "track" and h["pid"] != me
            and (h.get("queued", 0), h["pid"]) < (mine, me) and not procs.stopped(h["pid"])]


def over_load_cap(cpus, load, load_cap):
    """Whether a run of `cpus` is held back by the load while anything holds: its cpus on top of the load go over the cap."""
    return load + cpus > load_cap


def reserve_moment(h, load, load_cap):
    """When the queue starts reserving cpus for the waiting run `h`: it queued + RESERVE (times IDLE_ONLY_RESERVE_X when the
    load holds it back while anything holds), or None for a run with no queue time."""
    if not h.get("queued"):
        return None
    idle_only = h.get("kind") != "heavy" and over_load_cap(state.cpus_of(h), load, load_cap)
    return h["queued"] + config.RESERVE * (config.IDLE_ONLY_RESERVE_X if idle_only else 1)


def reserving(waiting, now=None):
    """The waiting run the queue reserves cpus for: the first in turn order that has waited past RESERVE (past
    IDLE_ONLY_RESERVE_X times RESERVE when the load holds it back while anything holds), else None.
    `waiting` is in turn order (read_holders sorts by queue time)."""
    now = time.time() if now is None else now
    load_cap, load = config.read_load_cap(), config.loadavg()[0]
    for h in waiting:
        at = reserve_moment(h, load, load_cap)
        if at is not None and now > at:
            return h
    return None


# The stable code of each reason a waiting run can be held for, recorded as its wait_reason. The text of a reason
# carries live numbers (elapsed time, load); the code never does, so it changes only when the reason does. Every
# reason goes through wait_why, which refuses a code not listed here.
WAIT_CODES = ("reserved", "queued-ahead", "cpus", "load", "gate", "no-limit", "ci-first", "ci-priority")


def wait_why(code, text):
    """(code, text) for one reason; a code not in WAIT_CODES is a bug."""
    if code not in WAIT_CODES:
        raise ValueError(f"unlisted wait code {code!r}")
    return code, text


def why_wait(hs, me, mine, cpus, limit_s=None):
    """Why a run queued at `mine` asking for `cpus` (with a time limit of `limit_s` seconds, or none) can't start now, or None if it can."""
    held = wait_check(hs, me, mine, cpus, limit_s)
    return held[1] if held else None


def wait_check(hs, me, mine, cpus, limit_s=None, ci=False):
    """(code, reason text) for why a run queued at `mine` asking for `cpus` can't start now, or None if it can.
    A run that would start past a waiting run (a head) needs a time limit within the backfill limit, and against a reserved head
    that limit must end within the backfill limit of the moment the head began to reserve.
    The CI hold: a non-CI run waits (ci-first) while any other CI run on the host is waiting or holding a slot; a CI run (`ci`) goes ahead of
    every queued non-CI run, and anything that holds it back comes with the code ci-priority and the usual reason after it."""
    if not ci:
        for h in hs:
            if h.get("ci") and h["pid"] != me and h.get("state") in ("waiting", "admitted", "running") and not h.get("orphan"):
                return wait_why("ci-first", f"ci first: a CI run (pid {h['pid']}) is queued or running on this host, and no new run starts until it has ended")

    def check():
        # both caps are read on every check, not once at start: a cap raised or lowered while runs wait reaches them
        cap, load_cap = config.read_cap(), config.read_load_cap()
        ahead = waiters_ahead(hs, me, mine)
        if ci:  # a CI run goes ahead of every queued non-CI run: only CI runs queued before it are ahead of it
            ahead = [h for h in ahead if h.get("ci")]
        backfill_s = config.read_backfill_limit() * 60
        head = reserving(ahead)
        if head:
            held = wait_why("reserved", f"cpus are reserved for the run at the head (pgid {head.get('pgid') or '-'}, {state.cpus_of(head)} cpus, "
                            f"waiting {util.fmt_elapsed(head['queued'])}); nothing passes it")
            if limit_s is None:
                return held
            # the earliest moment a head began to reserve: the run's limit must end by then plus the backfill limit
            now, load = time.time(), config.loadavg()[0]
            moments = [m for m in (reserve_moment(h, load, load_cap) for h in ahead) if m is not None and m < now]
            if not moments or now + limit_s > min(moments) + backfill_s:
                return held
        # backfill: only a run asking for more cpus than this one is passed over; a run of this size or smaller goes first
        first = [h for h in ahead if state.cpus_of(h) <= cpus]
        if first:
            return wait_why("queued-ahead", f"{len(first)} run(s) queued ahead of this one")
        if ahead and (limit_s is None or limit_s > backfill_s):
            h = ahead[0]
            why = "no time limit (--max-minutes)" if limit_s is None else f"a time limit over the backfill limit of {backfill_s / 60:g} minutes"
            return wait_why("no-limit", f"{why}: the run ahead (pid {h.get('pid')}, {state.cpus_of(h)} cpus) is still waiting")
        used = sum(state.charged_cpus(h) for h in hs if state.holds_cpus(h) and h["pid"] != me)
        if used + cpus > cap:
            return wait_why("cpus", f"cpus: {used:g} of {cap} in use, this run needs {cpus}")
        # debt: the 1-minute load lags. Just after a run ends it still counts that run for some seconds,
        # so the next start can wait until it falls under the cap; just after a start it doesn't count it
        # yet, which the charge check above covers. Upgrade: subtract the running runs' share, or
        # read /proc/stat. Ceiling: outside work that keeps the load at the cap holds every run, by design
        # (the agreed gate); the first run is checked against the load alone, not load plus its cpus, or a
        # --heavy run could start only on an idle box.
        load = config.loadavg()[0]
        if load >= load_cap:  # always, so outside work holds back even the first run
            return wait_why("load", f"load: {load:.1f} now, at or over the load cap {load_cap:g}")
        if used and over_load_cap(cpus, load, load_cap):
            return wait_why("load", f"load: {load:.1f} now, this run needs {cpus}, load cap {load_cap:g}")
        return None

    held = check()
    if ci and held:  # the code says a CI run is held; its text says what by (cpus, load, a CI run ahead of it, the reservation)
        return wait_why("ci-priority", f"ci priority: {held[1]}")
    return held


TTY_STOPS = {signal.SIGTSTP, signal.SIGTTIN, signal.SIGTTOU}


def turnstile_held(turn):
    """Hold the turnstile for a moment, with Ctrl-Z held off, so a stopped run can't freeze every admission."""
    class Held:
        def __enter__(self):
            signal.pthread_sigmask(signal.SIG_BLOCK, TTY_STOPS)
            fcntl.flock(turn, fcntl.LOCK_EX)

        def __exit__(self, *_):
            fcntl.flock(turn, fcntl.LOCK_UN)
            signal.pthread_sigmask(signal.SIG_UNBLOCK, TTY_STOPS)
    return Held()


def take_slots(rec, holder_path, heavy):
    """Wait our turn and admit this run within the cpu cap and the load: first come among runs of a size, a run that
    fits may be backfilled ahead of a bigger waiter, and nothing passes a head that has waited past the reserve time.
    Each check holds the turnstile for a moment, so two runs can't both see the same free cpus.
    Returns (gate descriptors held by the wrapper, whether we waited)."""
    # debt: with ps down for good (macOS), every holder counts as alive, so a waiter waits on silently
    # and never gives up: fail closed, but quiet. Upgrade: say "can't tell, ps is failing" after a minute.
    # debt: on macOS a nested run is seen only through its parent chain, so one started by a
    # double-forked child (reparented to launchd) isn't nested and waits on its own outer run.
    turn = util.open_lock(config.TURNSTILE)
    gate = util.open_lock(config.HEAVY)
    me = rec["pid"]
    said = None
    code = None
    try:
        # our place in line: stamped and made visible under the turnstile, so no later run is seen first
        with turnstile_held(turn):
            state.MY_QUEUED = rec["queued"] = time.time()
            if rec.get("head"):  # a requeued run goes ahead of everything waiting
                ahead = [h["queued"] for h in state.read_holders() if h.get("state") == "waiting" and h["pid"] != me
                         and isinstance(h.get("queued"), (int, float))]
                if ahead:
                    state.MY_QUEUED = rec["queued"] = min(state.MY_QUEUED, min(ahead) - 0.001)
            state.write_holder(holder_path, rec)
        while True:
            with turnstile_held(turn):
                held = wait_check(state.read_holders(), me, rec["queued"], state.cpus_of(rec), rec.get("limit_s"), bool(rec.get("ci")))
                reason = held[1] if held else None
                if held is None:
                    try:  # the old gate: a run outside testslot (test-parallel's LOCK_EX) holds it
                        fcntl.flock(gate, (fcntl.LOCK_EX if heavy else fcntl.LOCK_SH) | fcntl.LOCK_NB)
                    except BlockingIOError:
                        held = wait_why("gate", "the test gate, held outside testslot or by a heavy run")
                        reason = held[1]
                if held is None:
                    # counted from here on, before the turnstile frees, so the next check sees our cpus
                    # rec only says admitted once the holder does: a cancel or a failed write before that
                    # leaves no history line for a run that never started
                    passed = waiters_ahead(state.read_holders(), me, rec["queued"])
                    # the holder file keeps the size the run declared; every view clamps it with cpus_of, by design
                    admitted = dict(rec, state="admitted", since=time.time(), load_at_start=config.loadavg()[0],
                                    backfill=bool(passed))
                    state.write_holder(holder_path, admitted)
                    rec.update(admitted)
                    return [gate], said is not None
                kind = re.sub(r"\([^)]*\)|[\d.:]+", "", held[1]) if rec.get("ci") else ""  # what a CI run waits on (cpus, load, queued ahead): the text without its numbers
                if held[0] != code or (rec.get("ci") and kind != rec.get("wait_kind")):  # codes, not text: the text carries live numbers and changes every second
                    code = rec["wait_reason"] = held[0]
                    if rec.get("ci"):  # a CI run's code is ci-priority (gate aside): status shows what it waits on, rewritten when that changes
                        rec["wait_text"], rec["wait_kind"] = held[1], kind
                    state.write_holder(holder_path, rec)
            if reason != said:
                head = "waiting" if said is None else "still waiting"
                print(f"testslot: {head}: {reason}; held by:", file=sys.stderr, flush=True)
                for line in state.describe_holders(state.MY_QUEUED):
                    print(f"  {line}", file=sys.stderr, flush=True)
                said = reason
            time.sleep(1)
    finally:
        os.close(turn)


KEY_MAX = 200   # a longer key is stored as a hash: a caller naming 100 modules needn't care


def store_key(key):
    """The key as stored and compared: as given, or a hash of it past KEY_MAX characters."""
    key = " ".join(str(key).split())
    return key if len(key) <= KEY_MAX else "sha256:" + hashlib.sha256(key.encode()).hexdigest()


def derive_key(command):
    """A key for a command with no --key: the program by its base name and the arguments with some of what changes
    from run to run taken out: a bare path argument to its base name, hex runs of 8 or more and numbers of 5 or more
    digits to a mark, --log and its value dropped. So two runs of one command from two temp trees agree when the trees
    differ only in those. Not covered: a path inside a dash token (--junit=/tmp/x/out.xml, -o/tmp/x/out keep the
    whole path), a random temp name (mktemp's tmp.Ab12Cd), and two scripts with the same base name in different
    folders (python3 a/run.py and python3 b/run.py are one key). debt: a heuristic; a caller that knows what its
    command is (Cat Herder's remote-test) passes --key instead, which is the way."""
    out, skip = [], False
    for tok in command:
        if skip:
            skip = False
            continue
        if tok == "--log":
            skip = True
            continue
        if tok.startswith("--log="):
            continue
        if "/" in tok and not tok.startswith("-"):
            tok = os.path.basename(tok.rstrip("/")) or tok
        tok = re.sub(r"[0-9a-f]{8,}", "<h>", tok)
        tok = re.sub(r"\d{5,}", "<n>", tok)
        out.append(tok)
    return store_key(" ".join(out))
