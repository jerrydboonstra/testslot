import datetime
import getpass
import math
import os
import signal
import subprocess
import sys
import threading
import time
from testslot import admission
from testslot import cgroup
from testslot import config
from testslot import pacing
from testslot import procs
from testslot import sampling
from testslot import state
from testslot import util


def cmd_run(argv):
    heavy, track, log, cpus, key = False, False, None, None, None
    ci = False  # --ci: a CI run, for the users in ci-users
    requeued = None  # internal: (declared, peak) of the run this one replaces, set by the wrapper that requeued it
    limit_s = None  # --max-minutes, in seconds
    while argv and argv[0] != "--":
        a = argv.pop(0)
        if a == "--requeued" and argv:
            try:
                d, _, pk = argv.pop(0).partition(":")
                requeued = (float(d), float(pk))
            except ValueError:
                util.die("run: --requeued is for testslot's own restart (DECLARED:PEAK)")
        elif a == "--heavy":
            heavy = True
        elif a == "--track":
            track = True
        elif a == "--ci":
            ci = True
        elif a == "--log" and argv:
            log = argv.pop(0)
        elif a == "--key" and argv:
            key = argv.pop(0)
        elif a == "--max-minutes" and argv:
            n = argv.pop(0)
            try:
                limit_s = round(float(n) * 60, 3)
                if not math.isfinite(limit_s) or limit_s <= 0:
                    raise ValueError(n)
            except ValueError:
                util.die(f"run: --max-minutes wants a number of minutes above 0 (decimals are fine), not {n}")
        elif a == "--cpus" and argv:
            n = argv.pop(0)
            if not n.isdigit() or int(n) < 1:
                util.die(f"run: --cpus wants a whole number of 1 or more, not {n}")
            cpus = int(n)
        else:
            util.die(f"run: unknown option {a}")
    if not argv or argv[0] != "--" or len(argv) < 2:
        util.die("usage: testslot run [--cpus N | --heavy | --track] [--ci] [--max-minutes N] [--key KEY] [--log FILE] -- <command...>")
    if heavy + track + (cpus is not None) > 1:
        util.die("run: --cpus, --heavy and --track exclude each other")
    if ci:
        if track:
            util.die("run: --ci and --track exclude each other (a track run takes no slot, so there is nothing to put first)")
        who = config.real_user()
        if who not in config.read_ci_users():
            util.die(f"run: --ci is for the users listed in {config.CI_USERS} (one account name a line); {who} is not one"
                     + ("" if os.path.exists(config.CI_USERS) else " (the file does not exist)"))
    command = argv[1:]
    kind = "heavy" if heavy else "track" if track else "light"
    if cpus and cpus > config.read_cap():
        print(f"testslot: --cpus {cpus} is over the cap; this run gets all {config.read_cap()}", file=sys.stderr, flush=True)
    # stored as asked (heavy as none, which counts as the whole cap): the cap is applied at each check, so a
    # raise reaches a run that is already queued
    cpus = 0 if track else None if heavy else (cpus or 1)

    # Nested under a run that already holds a slot (testslot's or test-parallel's): waiting again
    # would wait on ourselves. An ancestor holding the gate in /proc/locks is the proof.
    outer = procs.held_by_ancestor()
    if outer == "heavy" or (outer == "light" and not heavy):
        try:
            os.execvp(command[0], command)
        except OSError as e:
            util.die(f"run: {command[0]}: {e.strerror}", 127)
    if outer == "light" and heavy:
        util.die("run: a heavy run can't start inside a light one (it would wait on its own parent); "
            "run the outer command with --heavy", 1)
    if not os.path.isdir(config.HOLDERS):
        util.die(f"{config.DIR} is not set up: make it with its holders/ and logs/ folders "
            f'(mkdir -p "{config.DIR}/holders" "{config.DIR}/logs"), or set TESTSLOT_DIR to a folder you own and make holders/ and logs/ inside it; '
            "to share one gate between accounts, see the README's sharing steps (group, chmod -R g+rws)")

    me = getpass.getuser()
    state.prune(me)
    pid = os.getpid()
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    log = os.path.abspath(log) if log else os.path.join(config.LOGS, f"{me}-{stamp}-{pid}.log")
    holder_path = os.path.join(config.HOLDERS, f"{pid}.json")
    state.MY_QUEUED = time.time()
    rec = {"pid": pid, "account": me, "repo": state.repo_dir(), "command": " ".join(command), "kind": kind, "limit_s": limit_s,
           "cpus": cpus, "key": admission.store_key(key) if key else admission.derive_key(command), "start": (procs.proc_stat(pid) or (None, None))[1], "state": "waiting", "queued": state.MY_QUEUED, "since": None, "pgid": None, "log": log}
    if ci:
        rec["ci"] = True  # set only here, after the ci-users check: the hold in admission.wait_check reads it
    if requeued:  # started again by its own wrapper: at the head of the queue, once, with its measured size
        rec.update(requeued_from={"declared": requeued[0], "peak": requeued[1], "cpus": cpus}, head=True)
    proc = None
    sampler = None  # (stop event, thread, lock) once the command runs

    cancelled = []
    ended = False
    result = None
    scope = None  # the run's cgroup directory once it is made, else None (the group path)

    def run_alive(pgid):
        """Whether anything of the run is left: its group, or its cgroup (which holds the setsid children too)."""
        return procs.group_alive(pgid) or bool(cgroup.scope_pids(scope))

    def end_group(pgid):
        """CONT then TERM the group and the cgroup, then KILL whatever is left after 5s. The CONT first: a group the
        throttle stopped would hold the TERM pending and be KILLed, recorded as a failure, not a cancel."""
        # OSError, not just ProcessLookupError: a setuid member makes killpg fail with EPERM
        for sig in (signal.SIGCONT, signal.SIGTERM):
            try:
                os.killpg(pgid, sig)
            except OSError:
                pass
            cgroup.signal_scope(scope, sig)
        if not run_alive(pgid):
            return
        for _ in range(10):
            time.sleep(0.5)
            if not run_alive(pgid):
                return
        kill_group(pgid)

    def kill_group(pgid):
        if procs.group_alive(pgid):  # re-checked, so a pgid already gone is never signalled
            try:
                os.killpg(pgid, signal.SIGKILL)
            except OSError:
                pass
        cgroup.kill_scope(scope)

    def escalate(_signum, _frame):
        # SIGALRM: forward()'s 5 s timer, or `testslot stop --kill`, which leaves the KILL to this handler so the cancel
        # is recorded before the leader dies. A KILL from outside first would leave a leader that has ended, unreaped,
        # and forward() would take that for the command ending by itself (exit 137, counted as failed).
        if proc is not None:
            if not cancelled and not leader_ended():
                cancelled.append(signal.SIGTERM)
            kill_group(proc.pid)

    def leader_ended():
        """True once the command's leader has exited, reaped or not. proc.returncode is set only by the
        wrapper's wait(), so a stop in the gap between the exit and the reap would count as a cancel.
        waitid with WNOWAIT looks without reaping, so wait() still gets the code (no Popen.poll here: the
        handler runs inside wait(), which holds Popen's lock). A reaped child (ECHILD) has ended too. Not on macOS: there only the reap tells."""
        if proc is None:
            return False
        if proc.returncode is not None:
            return True
        if not hasattr(os, "waitid"):
            return False
        try:
            r = os.waitid(os.P_PID, proc.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            # macOS answers for a child that is only stopped (si_code CLD_STOPPED), where Linux answers None until it
            # exits: so a load-paused or throttle-paused leader would count as ended and a stop would be ignored.
            return r is not None and r.si_code in (os.CLD_EXITED, os.CLD_KILLED, os.CLD_DUMPED)
        except ChildProcessError:
            return True  # our own child, already reaped (wait() reaps before it sets returncode): it ended
        except OSError:
            return False

    stopped = []  # signals that came from outside (a stop, a ^C): a requeue never overrides them
    requeue = []  # set by on_requeue: this wrapper is cancelling the run to start it again

    def forward(signum, _frame):
        stopped.append(signum)
        cancel_run(signum)

    def on_requeue(_signum, _frame):
        # SIGUSR1, sent by this wrapper's own throttle thread: cancel the run as a stop would
        if cancelled or stopped or proc is None or leader_ended():
            return
        requeue.append(True)
        cancel_run(signal.SIGTERM)

    def on_limit(_signum, _frame):
        # SIGUSR2, sent by this wrapper's own throttle thread: the run started past a
        # waiting run and its time limit has passed. Cancel it as a stop would, with the reason, and never requeue it
        if cancelled or stopped or proc is None or leader_ended():
            return
        cancel_run(signal.SIGTERM)
        if cancelled:  # cancel_run returns without cancelling when the command has just ended: then there is no stop to name
            rec["stop_reason"] = "time limit"

    def ask_requeue():
        signal.pthread_kill(threading.main_thread().ident, signal.SIGUSR1)

    def ask_stop():
        signal.pthread_kill(threading.main_thread().ident, signal.SIGUSR2)

    def cancel_run(signum):
        if leader_ended():
            return  # the command already ended (its leftovers are being cleared): its code stands
        if proc is not None:
            # a cancelled run never reports success, and a command that traps TERM still ends
            # Only plain os calls here: a handler that starts a thread can deadlock on threading's own lock.
            # SIGALRM does the KILL in 5s.
            if not cancelled:
                cancelled.append(signum)
                # no group_alive here (on macOS it runs ps): the leader isn't reaped yet, so the pgid is still ours.
                # CONT first, in case the throttle has the group stopped; from here on it stops nothing more.
                for sig in (signal.SIGCONT, signal.SIGTERM):
                    try:
                        os.killpg(proc.pid, sig)
                    except OSError:
                        pass
                    cgroup.signal_scope(scope, sig)  # plain file reads and os.kill: safe in a handler
                signal.alarm(5)
        else:
            cancelled.append(signum)  # the finally below removes the holder (and records it, if admitted)
            sys.exit(128 + signum)

    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, forward)
    signal.signal(signal.SIGALRM, escalate)
    signal.signal(signal.SIGUSR1, on_requeue)
    signal.signal(signal.SIGUSR2, on_limit)

    try:
        try:
            # before any slot: a bad --log path fails without holding anything. In the shared logs folder
            # the name is guessable, so a link planted there is refused, never followed.
            nofollow = os.O_NOFOLLOW if os.path.realpath(os.path.dirname(log)) == os.path.realpath(config.LOGS) else 0
            logf = os.fdopen(os.open(log, os.O_WRONLY | os.O_APPEND | os.O_CREAT | nofollow, 0o644), "ab")
            state.own_mode(logf.fileno(), 0o644)
        except OSError as e:
            util.die(f"run: log {log}: {e.strerror}", 1)
        try:
            if track:
                state.write_holder(holder_path, rec)
                held, waited = [], False
                rec.update(state="admitted", since=time.time(), load_at_start=config.loadavg()[0])
            else:
                held, waited = admission.take_slots(rec, holder_path, heavy)
        except OSError as e:
            if not isinstance(e, PermissionError):
                util.die(f"{e.filename or config.DIR}: {e.strerror}", 1)
            util.die(f"{e.filename or config.DIR}: permission denied. Is {me} in the testslot group in this shell? "
                f"(`id -nG`; a new group needs a fresh login)", 1)
        if waited:
            print("testslot: slot free, starting", file=sys.stderr, flush=True)
        if os.environ.get("TESTSLOT_TEST_CRASH") == "after-admit":  # tests only: an internal error after admission, before the command
            raise RuntimeError("after admission, before the command")
        env = dict(os.environ, TESTSLOT_LOG=log)
        if not track:
            # A light run marks the slot held too, so a test-parallel inside it runs rather than waiting
            # on its own parent forever: the caller chose light. Wrap full suites with --heavy.
            env.update(TESTSLOT_HELD=f"{kind}:{pid}:{rec['start']}")

        sigs = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}

        def child_setup():
            # a run started from a non-interactive `&` inherits an ignored SIGINT; give the tests the default back
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            signal.pthread_sigmask(signal.SIG_UNBLOCK, sigs)

        # Only this wrapper holds the lock (close_fds keeps it from the command), so the slot ends with
        # the wrapper, however it ends, and nothing the command starts (a daemon, a setsid child) can keep
        # it. A wrapper killed outright leaves its command running without a slot; status says so.
        unit = f"testslot-{pid}-{int(time.time())}"
        argv, why, extra = cgroup.scope_command(command, unit)
        mark_r = mark_w = None
        if argv is not command:
            mark_r, mark_w = os.pipe()
            os.set_blocking(mark_r, False)
            extra = dict(extra, TESTSLOT_MARKFD=str(mark_w))

        def spawn(a, more, keep=()):
            # signals wait while the child starts, so none lands between "slot taken" and "proc known"
            signal.pthread_sigmask(signal.SIG_BLOCK, sigs)
            try:
                return subprocess.Popen(a, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
                                        env=dict(env, **more), preexec_fn=child_setup, pass_fds=keep)
            except OSError as e:
                util.die(f"run: {command[0]}: {e.strerror}", 127)
            finally:
                signal.pthread_sigmask(signal.SIG_UNBLOCK, sigs)

        proc = spawn(argv, extra, (mark_w,) if mark_w is not None else ())
        if argv is not command:  # systemd-run execs the command itself, so proc.pid is the command and its group
            os.close(mark_w)
            # The launcher answers on the pipe: a byte (the command is about to run), or the end of the file with no
            # byte (it never ran). Only the second may be rerun, once, without a scope. If neither comes in
            # LAUNCH_S the launcher is stopped first, and what its pipe then holds decides: a byte means the command
            # may have started, so it is not run again.
            outcome = cgroup.read_marker(mark_r, config.LAUNCH_S)
            if outcome == "timeout":
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except OSError:
                    pass
                outcome = cgroup.read_marker(mark_r, 5)
                os.close(mark_r)
                if outcome == "timeout":
                    util.die(f"run: systemd-run did not start {command[0]} in {config.LAUNCH_S:g} s and could not be stopped", 1)
                if outcome == "byte":
                    util.die(f"run: systemd-run started {command[0]} just as it was stopped; not run again", 1)
                why = f"systemd-run did not start the command in {config.LAUNCH_S:g} s; it ran without a scope"
            else:
                os.close(mark_r)
                if outcome == "eof":
                    why = "systemd-run failed to start the command; it ran without a scope"
            if outcome == "byte":
                scope, why = cgroup.find_scope(proc, unit, pid)
            else:
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    kill_group(proc.pid)
                    proc.wait()
                proc.stdout.close()
                if cancelled:  # a signal came while the launcher ran: no second start
                    sys.exit(128 + cancelled[0])
                proc = spawn(command, {})
        rec.update(state="running", pgid=proc.pid, cgroup=scope, observed_via="cgroup" if scope or ((config.OBSERVED_FILE or config.OBSERVED_DIR) and config.VIA_HOOK == "cgroup") else "group",
                   cgroup_note=why if config.LINUX else None)
        state.write_holder(holder_path, rec)
        rec_lock = threading.Lock()
        stop_ev, sample_thread = sampling.start_sampler(rec, holder_path, proc.pid, rec_lock, scope)
        throttle = pacing.start_throttle(rec, holder_path, proc.pid, rec_lock, scope, lambda: bool(cancelled), stop_ev,
                                  ask_requeue if kind == "light" and not requeued else None,
                                  ask_stop if rec.get("limit_s") else None)
        sampler = (stop_ev, sample_thread, rec_lock, throttle)
        print(f"testslot: {kind} run, {state.cpus_of(rec)} cpus, pgid {proc.pid}, log {log}", file=sys.stderr, flush=True)

        def copy():
            logging = True
            for chunk in iter(lambda: proc.stdout.read1(65536), b""):
                if logging:
                    try:
                        logf.write(chunk)
                        logf.flush()
                    except ValueError:  # closed after the join timed out: a leftover still holds the pipe
                        return
                    except OSError as e:  # disk full: stop logging, keep draining, or the command blocks
                        logging = False
                        try:  # stderr may be on the same full disk
                            print(f"testslot: log write failed ({e.strerror}); output goes to the terminal only",
                                  file=sys.stderr)
                        except OSError:
                            pass
                try:
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                except (BrokenPipeError, OSError):
                    pass

        # The copy thread starts with TERM/INT/HUP, ALRM (the KILL escalation), and USR1/USR2 (requeue/time limit)
        # blocked (a new thread inherits the mask), so the kernel always hands them to the main thread. Otherwise one can land on
        # this thread while the main thread sits in wait(), and the cancel waits for the command to end
        # (seen after a Ctrl-Z).
        t = threading.Thread(target=copy, daemon=True)
        tsigs = sigs | {signal.SIGALRM, signal.SIGUSR1, signal.SIGUSR2}
        signal.pthread_sigmask(signal.SIG_BLOCK, tsigs)
        try:
            t.start()
        finally:
            signal.pthread_sigmask(signal.SIG_UNBLOCK, tsigs)
        code = proc.wait()
        util.RAN[0] = 128 + cancelled[0] if cancelled else code if code >= 0 else 128 - code  # main keeps it if cleanup fails
        sampling.stop_sampler(sampler)
        if os.environ.get("TESTSLOT_TEST_CRASH") == "after-wait":  # tests only
            raise RuntimeError("after the command ended")
        # Whatever the command left running in its group or cgroup would run on after the slot frees: end it.
        if run_alive(proc.pid):
            end_group(proc.pid)
        ended = True
        t.join(timeout=2)  # a child that left the group but kept the pipe must not hang us
        try:
            logf.close()
        except OSError:  # the full disk again, flushing the last of the buffer: the command's code stands
            pass
        # a command killed by a signal of its own (the OOM killer, say) failed; only a signal to this
        # wrapper, from the caller or from `testslot stop`, makes a cancel
        result = 128 + cancelled[0] if cancelled else code if code >= 0 else 128 - code
        return result
    except SystemExit as e:
        result = e.code if isinstance(e.code, int) else 1
        raise
    except Exception as e:
        # testslot's own failure past this point: keep its text for the history line the finally writes, and for the stderr line
        # the handler prints (the same text). Not PsFailed ("nothing was started": its calls come before admission) and not
        # BrokenPipeError (the reader left): the handler does not print either one as "testslot error".
        if not isinstance(e, (procs.PsFailed, BrokenPipeError)):
            util.ERROR[0] = util.error_text(e)
        raise
    finally:
        # however we leave (an exception included), end the sampler first (it must not write the record back
        # after we remove it), then the command's group before the slot frees
        cleanup_error = None
        outlived = True  # until it is known the group is gone: a run whose cleanup failed keeps its record, for prune to write
        try:
            sampling.stop_sampler(sampler)
            if proc is not None and (rec.get("paused_since") or rec.get("load_paused_since")):  # the throttle didn't end in time: never leave the group stopped
                try:
                    os.killpg(proc.pid, signal.SIGCONT)
                except OSError:
                    pass
                cgroup.signal_scope(scope, signal.SIGCONT)
            if proc is not None and run_alive(proc.pid):
                # once already tried (TERM, 5s, KILL) only a last KILL: a group stuck in the kernel costs no second wait
                kill_group(proc.pid) if ended else end_group(proc.pid)
            if rec.get("since") and os.environ.get("TESTSLOT_TEST_CRASH") == "in-cleanup":  # tests only: an internal error in the cleanup
                raise RuntimeError("in the cleanup")
            outlived = proc is not None and run_alive(proc.pid)
        except Exception as e:
            # a failure in the cleanup is recorded like any other (the handler prints it, too): the record is written or kept
            # below, and the error is raised again once that is done
            cleanup_error = e
            if not isinstance(e, (procs.PsFailed, BrokenPipeError)) and not util.ERROR[0]:
                util.ERROR[0] = util.error_text(e)
        # a group that outlives even SIGKILL (stuck in the kernel) keeps its record, so status lists it
        # as running without a slot; prune drops the record once the group is gone
        if rec.get("since"):  # admitted: what happened goes into history, now or when prune finds it
            # the command's code when testslot broke after the command ended (result is still None then; RAN[0] has it), else null
            # for a run that never reached the command; testslot's own error goes in the record, so a line prune writes later has it too
            rec.update(ended=time.time(), cancelled=bool(cancelled),
                       exit=result if result is not None else util.RAN[0] if util.RAN[0] is not None else 128 + cancelled[0] if cancelled else None)
            if util.ERROR[0]:
                rec["error"] = util.ERROR[0]
        if rec.get("since") and os.environ.get("TESTSLOT_TEST_KEEP_HOLDER"):  # tests only: take the group-outlived-SIGKILL path
            outlived = True
        if not outlived:
            try:
                os.unlink(holder_path)
                if rec.get("since"):
                    state.append_history(state.history_line(rec, rec["ended"], rec["exit"]))
            except OSError:
                pass
        elif rec.get("since"):
            try:  # the group outlived SIGKILL: keep the record, with the exit, for prune to write later
                state.write_holder(holder_path, rec)
            except OSError:
                pass
        if requeue and cancelled and not stopped and rec.get("since") and proc is not None and not run_alive(proc.pid):
            exec_requeue(rec, command, log)
        if cleanup_error is not None:
            raise cleanup_error


def exec_requeue(rec, command, log):
    """The run was cancelled by its own wrapper for using far more than it declared: start the same
    command again, once, in this process (so the caller keeps waiting on the same pid), at the head of the queue, declaring
    its measured peak. Returns only if the restart could not be made; the caller then ends as a cancel."""
    peak = rec.get("requeue_peak")
    declared = rec.get("requeue_declared")
    if not isinstance(peak, (int, float)) or isinstance(peak, bool) or not math.isfinite(peak) or peak <= 0:
        return
    new = sampling.requeue_size(peak)
    line = (f"requeued: this run used {peak:g} cpus against the {declared:g} it declared while the load was "
            f"{(rec.get('requeue_load') or 0):g} on {config.CORES} cores; stopped, and starting again at the head of the queue declaring {new}")
    print(f"testslot: {line}", file=sys.stderr, flush=True)
    try:  # and in the run's log, so whoever reads the log sees why its output starts over
        with open(log, "ab") as f:
            f.write(f"testslot: {line}\n".encode())
    except OSError:
        pass
    argv = [sys.executable, os.path.abspath(sys.argv[0]), "run", "--cpus", str(new), "--requeued", f"{declared:g}:{peak:g}",
            "--key", str(rec.get("key") or ""), "--log", log, "--"] + list(command)
    if rec.get("limit_s"):
        argv[argv.index("--key"):argv.index("--key")] = ["--max-minutes", f"{rec['limit_s'] / 60:.6g}"]
    try:
        sys.stdout.flush()
        signal.alarm(0)  # the cancel set a 5 s KILL timer; a pending alarm survives exec and would KILL the new run
        os.execv(sys.executable, argv)
    except OSError as e:
        print(f"testslot: could not start the run again ({e.strerror}); it ends as a cancel", file=sys.stderr, flush=True)
