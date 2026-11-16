import os
import signal
import subprocess
import time
from testslot import cgroup
from testslot import procs
from testslot import state
from testslot import util


def group_pids(pgid):
    r = subprocess.run(["pgrep", "-g", str(pgid)], capture_output=True, text=True, errors="replace")
    return r.stdout.split()


def cmd_stop(argv):
    sig = signal.SIGTERM
    if argv and argv[0] == "--kill":
        sig = signal.SIGKILL
        argv = argv[1:]
    if len(argv) != 1 or not argv[0].isdigit():
        util.die("usage: testslot stop [--kill] <pgid>")
    pgid = int(argv[0])
    # The holder is the one whose wrapper is the parent of the group's leader: a record is group-writable, and one
    # forged to carry another live run's pid must not make stop signal that run or its scope. With the leader gone
    # there is no parent to check, so no wrapper is signalled (the group and an orphan's scope still are).
    cands = [h for h in state.read_holders() if h.get("pgid") == pgid]
    parent = cgroup.parent_of(pgid)
    genuine = [h for h in cands if not h.get("orphan") and parent == h["pid"]]
    holder = next(iter(genuine), None) or next((h for h in cands if h.get("orphan")), None)
    scope = cgroup.holder_scope(holder, bool(genuine)) if holder else None
    if not group_pids(pgid) and not cgroup.scope_pids(scope):
        print(f"testslot: nothing runs in process group {pgid}")
        return 0
    # A run under testslot is stopped through its wrapper, so the wrapper records a cancel (a signal to
    # the group alone looks like the command dying by itself, which is a failure). The wrapper TERMs the
    # group and KILLs it after 5s; --kill asks the wrapper to KILL it now (SIGALRM), and KILLs it here only
    # if the wrapper hasn't within a second: a KILL sent here first can beat the wrapper's handler, which
    # then sees a leader that ended and records a failure.
    wrapper = next((h["pid"] for h in genuine if procs.alive(h["pid"], h.get("start"))), None)
    # debt: a run stopped in the moment between its start and its holder naming the pgid is signalled
    # as a plain group, so it counts as failed; and a waiting run has no pgid for stop to name.
    # debt: with ps failing (macOS), alive() can't check the start time, so a wrapper pid reused since
    # would get the TERM and CONT. Needs a pid wrap during a ps outage. Upgrade: skip the wrapper then.
    try:
        if wrapper:
            try:
                os.kill(wrapper, signal.SIGTERM)
                if sig == signal.SIGKILL:
                    os.kill(wrapper, signal.SIGALRM)  # its handler records the cancel, then KILLs the group
                os.kill(wrapper, signal.SIGCONT)  # a Ctrl-Z'd wrapper would hold the TERM, and the slot
            except ProcessLookupError:
                wrapper = None  # it ended just now: signal the group itself
        if not wrapper:
            cgroup.signal_scope(scope, sig)  # children that called setsid are in the cgroup, not the group
            os.killpg(pgid, sig)
            if not wrapper:  # no wrapper to resume it: a group the throttle stopped would hold the TERM pending
                cgroup.signal_scope(scope, signal.SIGCONT)
                os.killpg(pgid, signal.SIGCONT)
    except ProcessLookupError:
        pass
    except PermissionError:
        acct = procs.proc_info(pgid)[0]
        util.die(f"process group {pgid} belongs to {acct}; stop it as {acct}, or: sudo testslot stop {pgid}", 1)
    for i in range(20):
        time.sleep(0.5)
        left = group_pids(pgid) + [str(p) for p in cgroup.scope_pids(scope)]
        if left and i == 1 and sig == signal.SIGKILL and wrapper:
            # the wrapper didn't KILL it within a second (hung, or stopped again): do it here, as before
            cgroup.signal_scope(scope, sig)
            try:
                os.killpg(pgid, sig)
            except OSError:
                pass
        if not left:
            if wrapper and procs.alive(wrapper):
                continue  # the slot frees when the wrapper ends, not the group
            print(f"testslot: stopped process group {pgid}; nothing left")
            return 0
    if not left:
        print(f"testslot: group {pgid} is gone, but its run (pid {wrapper}) hasn't ended; the slot is still held")
        return 1
    print(f"testslot: still running in group {pgid}: {' '.join(left)}; try: testslot stop --kill {pgid}")
    return 1
