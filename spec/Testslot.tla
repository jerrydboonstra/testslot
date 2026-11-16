------------------------------ MODULE Testslot ------------------------------
(***************************************************************************)
(* A model of testslot's scheduler: admission, the queue and its backfill  *)
(* rule, the reserve waits, the cpu and load caps, what each running run   *)
(* is charged, idle shrink, outside load, and stop.                        *)
(*                                                                         *)
(* Source: testslot/testslot (the script). Its docstring at the top says   *)
(* each rule; the comments below name the line a rule comes from, and      *)
(* every simplification names the line it simplifies. Line numbers are     *)
(* those of main at 5e24784 (2026-10-23).                                  *)
(*                                                                         *)
(* Time is abstract: Tick is one unit, the waits are constants counted in  *)
(* ticks. CPUs are whole numbers.                                          *)
(***************************************************************************)
EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Runs,           \* the runs that may be submitted, again and again
    CapLevels,      \* values the cpu cap can take (read again on every check, line 872)
    LoadCapLevels,  \* values the load cap can take (same)
    LoadLevels,     \* values outside load can take (a CPU count, standing in for the 1-minute load)
    MaxCpus,        \* the most cpus a light run asks for (it may ask for more than the cap: clamped, line 279)
    Reserve,        \* RESERVE (line 229), in ticks: how long the head waits before the queue reserves for it
    IdleX,          \* IDLE_ONLY_RESERVE_X (line 853): 6 in the script, small here
    ShrinkAfter,    \* SHRINK_AFTER_S, in ticks: how long a run must sit under its declaration before it shrinks
    Margin,         \* SHRINK_MARGIN: a shrunk run is charged observed + Margin
    Cgroup          \* TRUE on Linux: the run's cgroup is searched and signalled as well as its process group

ASSUME /\ Runs # {}
       /\ CapLevels \subseteq 1..MaxCpus
       /\ LoadCapLevels \subseteq Nat
       /\ LoadLevels \subseteq Nat
       /\ MaxCpus \in Nat \ {0}
       /\ Reserve \in Nat \ {0} /\ IdleX \in Nat \ {0} /\ ShrinkAfter \in Nat \ {0} /\ Margin \in Nat
       /\ Cgroup \in BOOLEAN

VARIABLES
    state,      \* per run: "idle", "waiting", "running" (the command is going), "exited" (its main process has ended
                \* but the wrapper has not reaped it: proc.wait() at line 1609 has not returned), "cleanup" (reaped; the
                \* wrapper clears leftovers), "done"
    kind,       \* per run: "light", "heavy" (cpus = the cap), "track" (listed only, no cpus), or "none" before the first submit
    ask,        \* per run: the cpus a light run declared with --cpus
    q,          \* the waiting runs in turn order (queued time, then pid: line 838)
    waited,     \* per waiting run: ticks waited, saturating at WaitMax
    obs,        \* per running run: its wrapper's last reading, or -1 for none yet
    calm,       \* per running run: ticks its reading has sat under its declaration, saturating at ShrinkAfter
    alive,      \* per run: which of its processes are alive: "main", "child" (same group), "setsid" (left the group, in the cgroup)
    stub,       \* per run: the processes that ignore TERM and die only to KILL
    termed,     \* per run: TERM has been sent to the group (by stop, or by the wrapper's clean-up)
    cancelled,  \* per run: the wrapper's `cancelled` list is non-empty (line 1457)
    nz,         \* per run: the command ended nonzero or by a signal of its own
    endedBy,    \* per run, ground truth about the command: "none" (still going), "self" (it exited on its own),
                \* "stop" (a signal from `testslot stop` or the wrapper's own KILL after it), "raw" (a signal sent to the group alone)
    rec,        \* per run: what history records: "none", "ok", "failure" or "cancel" (lines 1610, 1625)
    cap, loadCap, load,   \* the cpu cap, the load cap and the outside load, as they stand now
    admitOk     \* ghost: every light/heavy admission so far left the charged sum within the cap

vars == <<state, kind, ask, q, waited, obs, calm, alive, stub, termed, cancelled, nz, endedBy, rec,
          cap, loadCap, load, admitOk>>

Procs == {"main", "child", "setsid"}
WaitMax == Reserve * IdleX + 1

Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b

(***************************************************************************)
(* What a signal reaches. TERM and KILL go to the process group             *)
(* (os.killpg, lines 1457-1464) and, on Linux, to the cgroup               *)
(* (signal_scope, lines 1429, 1464). Without a cgroup a process that        *)
(* called setsid is out of reach: that is the case the cgroup was added    *)
(* for, and Cgroup = FALSE shows it.                                       *)
(***************************************************************************)
Reach == IF Cgroup THEN Procs ELSE {"main", "child"}

\* run_alive (line 1418): anything of the run left, in its group or its cgroup.
RunAlive(r) == (alive[r] \cap Reach) # {}

(***************************************************************************)
(* Charge. cpus_of (lines 269-281): the size asked for, held to the cap as *)
(* it stands now; a heavy run is the whole cap; a track run costs 0.       *)
(* The clamp is the cap as read now (line 279), so a lowered cap lowers    *)
(* the charge of a run already going, and running runs are not evicted.    *)
(***************************************************************************)
CpusOf(r) == IF kind[r] = "track" THEN 0
             ELSE IF kind[r] = "heavy" THEN cap
             ELSE Min(ask[r], cap)

\* shrunk (line 318). Simplified: a reading is whole cpus, and the wrapper's staleness check (a dead sampler
\* is charged in full, line 323) is left out.
Shrunk(r) == /\ Cgroup
             /\ kind[r] = "light"
             /\ obs[r] >= 0
             /\ obs[r] < CpusOf(r)
             /\ calm[r] >= ShrinkAfter

\* charged_cpus (lines 295-307): the larger of the declaration and the reading, held to the cap; a shrunk run
\* is charged reading + margin, never above its declaration and never under 1. No reading yet: the declaration.
Charged(r) ==
    LET d == CpusOf(r)
    IN IF obs[r] < 0 THEN d
       ELSE IF Shrunk(r) THEN Min(d, Max(1, obs[r] + Margin))
       ELSE Min(Max(d, obs[r]), cap)

\* holds_cpus (line 336): admitted and not finished. A run whose command ended still holds its cpus until its
\* wrapper has cleared the group, because the holder record goes only then (lines 1634-1645).
Holds(r) == state[r] \in {"running", "exited", "cleanup"} /\ kind[r] # "track"

\* Any holder at all, track included, for the flock gate below.
Live(r) == state[r] \in {"running", "exited", "cleanup"}

RECURSIVE SumCharged(_)
SumCharged(S) == IF S = {} THEN 0
                 ELSE LET x == CHOOSE y \in S : TRUE IN Charged(x) + SumCharged(S \ {x})

Used(r) == SumCharged({x \in Runs \ {r} : Holds(x)})   \* `used` in why_wait (line 881)
UsedAll == SumCharged({x \in Runs : Holds(x)})

(***************************************************************************)
(* The queue. waiters_ahead (line 836): the waiting runs before this one,  *)
(* track runs left out. A track run takes no cpus, so it is never ahead of *)
(* anyone. CanStart below also skips the load gate for track runs.        *)
(***************************************************************************)
InQ(r) == \E i \in 1..Len(q) : q[i] = r
Pos(r) == CHOOSE i \in 1..Len(q) : q[i] = r
Ahead(r) == {q[i] : i \in 1..(Pos(r) - 1)} \ {x \in Runs : kind[x] = "track"}

\* over_load_cap (line 842).
Over(c) == load + c > loadCap

\* reserving (line 856): a waiting run that has waited past RESERVE; past IDLE_ONLY_RESERVE_X times RESERVE
\* when the load holds it back while anything holds (a heavy run keeps the plain wait). Only whether such a
\* run exists ahead matters to why_wait, so this is a set, not "the first in turn order".
IdleOnly(x) == kind[x] # "heavy" /\ Over(CpusOf(x))
PastReserve(x) == waited[x] > Reserve * (IF IdleOnly(x) THEN IdleX ELSE 1)
Reserved(r) == {x \in Ahead(r) : PastReserve(x)}

(***************************************************************************)
(* why_wait (line 869) is None and the flock gate is taken: the run may    *)
(* start. A test-parallel run outside testslot also takes the gate; it is  *)
(* outside load here.                                                      *)
(***************************************************************************)
CanStart(r) ==
  \/ kind[r] = "track"    \* lines 1484-1487: a track run skips take_slots: no queue, no cpus, no load gate, no flock gate
  \/ /\ Reserved(r) = {}                                      \* line 876: nothing passes a reserving head
     /\ \A x \in Ahead(r) : CpusOf(x) > CpusOf(r)            \* line 879: backfill past strictly bigger runs only
     /\ Used(r) + CpusOf(r) <= cap                           \* line 883
     /\ load < loadCap                                       \* line 892: outside load can hold even the first run
     /\ (Used(r) > 0 => ~Over(CpusOf(r)))                    \* line 894
     \* The old flock gate (lines 938-941). Every light and heavy run holds it while it runs: LOCK_EX for heavy,
     \* LOCK_SH for the rest, and the wrapper keeps the descriptor (line 952). So a heavy run starts only when
     \* no other light or heavy run holds, and nothing starts while a heavy run holds. A track run never takes it.
     /\ (kind[r] = "heavy" => \A x \in Runs \ {r} : ~(Live(x) /\ kind[x] # "track"))
     /\ \A x \in Runs \ {r} : ~(Live(x) /\ kind[x] = "heavy")

(***************************************************************************)
(* Actions                                                                 *)
(***************************************************************************)
Init ==
    /\ state = [r \in Runs |-> "idle"]
    /\ kind = [r \in Runs |-> "none"]
    /\ ask = [r \in Runs |-> 0]
    /\ q = <<>>
    /\ waited = [r \in Runs |-> 0]
    /\ obs = [r \in Runs |-> -1]
    /\ calm = [r \in Runs |-> 0]
    /\ alive = [r \in Runs |-> {}]
    /\ stub = [r \in Runs |-> {}]
    /\ termed = [r \in Runs |-> FALSE]
    /\ cancelled = [r \in Runs |-> FALSE]
    /\ nz = [r \in Runs |-> FALSE]
    /\ endedBy = [r \in Runs |-> "none"]
    /\ rec = [r \in Runs |-> "none"]
    /\ cap \in CapLevels
    /\ loadCap \in LoadCapLevels
    /\ load \in LoadLevels
    /\ admitOk = TRUE

\* A run joins the queue. Runs come back after they finish, so a stream of small runs can pass a big head.
\* A run that is stopped while waiting (it has no pgid for `stop` to name, cmd_stop, line 1888) is left out.
Submit(r) ==
    /\ state[r] \in {"idle", "done"}
    /\ \E k \in {"light", "heavy", "track"}, c \in 1..MaxCpus :
         /\ kind' = [kind EXCEPT ![r] = k]
         /\ ask' = [ask EXCEPT ![r] = IF k = "light" THEN c ELSE 1]
    /\ state' = [state EXCEPT ![r] = "waiting"]
    /\ q' = Append(q, r)
    /\ waited' = [waited EXCEPT ![r] = 0]
    /\ rec' = [rec EXCEPT ![r] = "none"]
    /\ UNCHANGED <<obs, calm, alive, stub, termed, cancelled, nz, endedBy, cap, loadCap, load, admitOk>>

\* take_slots admits a run (line 915). Under the turnstile the check and the admission are one step, so two
\* runs never see the same free cpus (line 918, docstring).
\* The command's processes are fixed at admission: which of them exist, and which ignore TERM. A real command
\* starts and ends children as it goes; ProcExit lets them end, and the set is a superset of what a run has.
Admit(r) ==
    /\ state[r] = "waiting"
    /\ CanStart(r)
    /\ \E al \in SUBSET Procs : "main" \in al /\ \E st \in SUBSET al :
         /\ alive' = [alive EXCEPT ![r] = al]
         /\ stub' = [stub EXCEPT ![r] = st]
    /\ state' = [state EXCEPT ![r] = "running"]
    /\ q' = [i \in 1..(Len(q) - 1) |-> IF i < Pos(r) THEN q[i] ELSE q[i + 1]]
    /\ waited' = [waited EXCEPT ![r] = 0]
    /\ obs' = [obs EXCEPT ![r] = -1]
    /\ calm' = [calm EXCEPT ![r] = 0]
    /\ termed' = [termed EXCEPT ![r] = FALSE]
    /\ cancelled' = [cancelled EXCEPT ![r] = FALSE]
    /\ nz' = [nz EXCEPT ![r] = FALSE]
    /\ endedBy' = [endedBy EXCEPT ![r] = "none"]
    /\ UNCHANGED <<kind, ask, rec, cap, loadCap, load>>
    \* A track run is charged nothing and skips the gate (lines 1484-1487), so its admission checks no cpus: the sum can
    \* already be over the cap when a running run's reading rose after its own admission (TLC, 3 runs, 2026-10-24).
    /\ admitOk' = (admitOk /\ (kind[r] = "track" \/ UsedAll' <= cap'))   \* the safety property: read in the state after the admission

\* The sampler's reading, 3 to 6 s stale in the script (docstring, "The reading lags"). Abstracted here as a
\* nondeterministic value that may change at any step: the model does not say how stale it is, only that it can
\* be anything, so a burst the sampler has not seen yet is a state the checker reaches. Line 1281 (start_sampler).
SetObs(r, v) ==
    /\ state[r] \in {"running", "exited"}   \* the sampler stops after the reap (line 1611)
    /\ kind[r] # "track"
    /\ v \in 0..MaxCpus
    /\ obs' = [obs EXCEPT ![r] = v]
    /\ calm' = [calm EXCEPT ![r] = IF v >= CpusOf(r) THEN 0 ELSE calm[r]]
    /\ UNCHANGED <<state, kind, ask, q, waited, alive, stub, termed, cancelled, nz, endedBy, rec,
                   cap, loadCap, load, admitOk>>

\* One unit of time: waiting runs age toward the reserve, running runs sit longer under their declaration.
Tick ==
    /\ waited' = [r \in Runs |-> IF state[r] = "waiting" THEN Min(waited[r] + 1, WaitMax) ELSE waited[r]]
    /\ calm' = [r \in Runs |->
                  IF state[r] \in {"running", "exited"} /\ obs[r] >= 0 /\ obs[r] < CpusOf(r)
                  THEN Min(calm[r] + 1, ShrinkAfter) ELSE calm[r]]
    /\ UNCHANGED <<state, kind, ask, q, obs, alive, stub, termed, cancelled, nz, endedBy, rec,
                   cap, loadCap, load, admitOk>>

\* Outside load and the two caps change at any time. A lowered cap evicts nobody (cpus_of, lines 272-273).
SetCap == /\ cap' \in CapLevels \ {cap}
          /\ UNCHANGED <<state, kind, ask, q, waited, obs, calm, alive, stub, termed, cancelled, nz, endedBy,
                         rec, loadCap, load, admitOk>>
SetLoadCap == /\ loadCap' \in LoadCapLevels \ {loadCap}
              /\ UNCHANGED <<state, kind, ask, q, waited, obs, calm, alive, stub, termed, cancelled, nz, endedBy,
                             rec, cap, load, admitOk>>
SetLoad == /\ load' \in LoadLevels \ {load}
           /\ UNCHANGED <<state, kind, ask, q, waited, obs, calm, alive, stub, termed, cancelled, nz, endedBy,
                          rec, cap, loadCap, admitOk>>

\* The command's main process ends on its own. The wrapper has not reaped it yet: proc.wait() (line 1609) returns
\* a moment later, and Reap is that step. Between the two the wrapper still sees `proc.returncode` as None.
MainExit(r, code) ==
    /\ state[r] = "running"
    /\ alive' = [alive EXCEPT ![r] = alive[r] \ {"main"}]
    /\ nz' = [nz EXCEPT ![r] = code]
    /\ endedBy' = [endedBy EXCEPT ![r] = IF cancelled[r] THEN "stop" ELSE "self"]   \* a stop that came first ended it
    /\ state' = [state EXCEPT ![r] = "exited"]
    /\ UNCHANGED <<kind, ask, q, waited, obs, calm, stub, termed, cancelled, rec, cap, loadCap, load, admitOk>>

\* proc.wait() returns and sets proc.returncode (line 1609). From here `forward` (line 1451) ignores a signal.
Reap(r) ==
    /\ state[r] = "exited"
    /\ state' = [state EXCEPT ![r] = "cleanup"]
    /\ UNCHANGED <<kind, ask, q, waited, obs, calm, alive, stub, termed, cancelled, nz, endedBy, rec,
                   cap, loadCap, load, admitOk>>

\* A child (not the main process) ends by itself, in any state: a run that left a process behind still has it.
ProcExit(r, p) ==
    /\ p \in alive[r] /\ p # "main"
    /\ alive' = [alive EXCEPT ![r] = alive[r] \ {p}]
    /\ UNCHANGED <<state, kind, ask, q, waited, obs, calm, stub, termed, cancelled, nz, endedBy, rec,
                   cap, loadCap, load, admitOk>>

\* `testslot stop [--kill] <pgid>` (line 1888) reaches the wrapper, whose handler (forward, line 1450) records
\* the cancel, TERMs the group and the cgroup, and arms the 5 s KILL. The handler ignores a signal only once
\* proc.returncode is set, which the reap (line 1609) does, not the command's exit (line 1451). So a stop that
\* comes after the command's main process has exited and before the reap still counts as a cancel: state
\* "exited" is stoppable, and endedBy keeps what really ended the command. A second stop adds nothing.
\* `hard` is --kill, which also KILLs the group and the cgroup at once (lines 1923-1925).
Stop(r, hard) ==
    /\ state[r] \in {"running", "exited"}
    /\ hard \/ ~cancelled[r]
    /\ LET gone == IF hard THEN Reach ELSE Reach \ stub[r]
           al == alive[r] \ gone
           dies == state[r] = "running" /\ "main" \notin al   \* the signal ends the command here
       IN /\ alive' = [alive EXCEPT ![r] = al]
          /\ state' = [state EXCEPT ![r] = IF dies THEN "exited" ELSE state[r]]
          /\ nz' = [nz EXCEPT ![r] = nz[r] \/ dies]
          /\ endedBy' = [endedBy EXCEPT ![r] = IF dies THEN "stop" ELSE endedBy[r]]
    /\ cancelled' = [cancelled EXCEPT ![r] = TRUE]
    /\ termed' = [termed EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<kind, ask, q, waited, obs, calm, stub, rec, cap, loadCap, load, admitOk>>

\* `kill -TERM -- -<pgid>` aimed at the group alone: the wrapper is not told, so the command dies by a signal
\* and that is a failure (docstring, last lines of the stop paragraph; line 1625 comment). It reaches the
\* group, not the cgroup, and it sets no `cancelled`.
RawKill(r) ==
    /\ state[r] = "running"
    /\ LET al == alive[r] \ ({"main", "child"} \ stub[r])
           dies == "main" \notin al
       IN /\ alive' = [alive EXCEPT ![r] = al]
          /\ state' = [state EXCEPT ![r] = IF dies THEN "exited" ELSE "running"]
          /\ nz' = [nz EXCEPT ![r] = nz[r] \/ dies]
          /\ endedBy' = [endedBy EXCEPT ![r] = IF dies THEN "raw" ELSE endedBy[r]]
    /\ UNCHANGED <<kind, ask, q, waited, obs, calm, stub, termed, cancelled, rec, cap, loadCap, load, admitOk>>

\* end_group (line 1422), called when the command has ended and the run is not clear: TERM the group and the
\* cgroup.
Term(r) ==
    /\ state[r] = "cleanup"
    /\ ~termed[r]
    /\ RunAlive(r)
    /\ alive' = [alive EXCEPT ![r] = alive[r] \ (Reach \ stub[r])]
    /\ termed' = [termed EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<state, kind, ask, q, waited, obs, calm, stub, cancelled, nz, endedBy, rec,
                   cap, loadCap, load, admitOk>>

\* kill_group (line 1438): KILL whatever is left, 5 s after the TERM (the SIGALRM escalation of line 1446, or
\* end_group's own loop). The 5 s is abstracted: the KILL can come at any step after the TERM, and fairness
\* below makes it come. The escalation does not check the reap, so it can land in "exited" too. A command that
\* has not ended is killed by it: a signal, so nz, and it follows a stop, so endedBy says "stop".
Kill(r) ==
    /\ state[r] \in {"running", "exited", "cleanup"}
    /\ termed[r]
    /\ RunAlive(r)
    /\ LET dies == state[r] = "running"
       IN /\ alive' = [alive EXCEPT ![r] = alive[r] \ Reach]
          /\ nz' = [nz EXCEPT ![r] = nz[r] \/ dies]
          /\ endedBy' = [endedBy EXCEPT ![r] = IF dies THEN "stop" ELSE endedBy[r]]
          /\ state' = [state EXCEPT ![r] = IF dies THEN "exited" ELSE state[r]]
    /\ UNCHANGED <<kind, ask, q, waited, obs, calm, stub, termed, cancelled, rec, cap, loadCap, load, admitOk>>

\* The wrapper ends: history gets its line (lines 1625, 1642-1645) and the slot frees. A cancelled run is a
\* cancel, whatever the command's own code; otherwise nonzero is a failure.
Finish(r) ==
    /\ state[r] = "cleanup"
    /\ ~RunAlive(r)
    /\ state' = [state EXCEPT ![r] = "done"]
    /\ rec' = [rec EXCEPT ![r] = IF cancelled[r] THEN "cancel" ELSE IF nz[r] THEN "failure" ELSE "ok"]
    /\ UNCHANGED <<kind, ask, q, waited, obs, calm, alive, stub, termed, cancelled, nz, endedBy,
                   cap, loadCap, load, admitOk>>

Next ==
    \/ \E r \in Runs :
         \/ Submit(r) \/ Admit(r) \/ RawKill(r) \/ Reap(r) \/ Term(r) \/ Kill(r) \/ Finish(r)
         \/ \E hard \in BOOLEAN : Stop(r, hard)
         \/ \E code \in BOOLEAN : MainExit(r, code)
         \/ \E p \in Procs : ProcExit(r, p)
         \/ \E v \in 0..MaxCpus : SetObs(r, v)
    \/ Tick \/ SetCap \/ SetLoadCap \/ SetLoad

(***************************************************************************)
(* Fairness. Time passes. A command that is running eventually ends. The   *)
(* wrapper's clean-up steps eventually happen. A run that can start        *)
(* infinitely often starts: strong fairness, not weak, because outside     *)
(* load that drops only now and then makes admission enabled now and then, *)
(* not continuously. testslot has no watchdog of its own for a hung        *)
(* command; this assumes none is needed (the one in test.sh is test-only). *)
(***************************************************************************)
Fairness ==
    /\ WF_vars(Tick)
    /\ \A r \in Runs :
         /\ SF_vars(Admit(r))
         /\ WF_vars(\E code \in BOOLEAN : MainExit(r, code))
         /\ WF_vars(Reap(r))
         /\ WF_vars(Term(r))
         /\ WF_vars(Kill(r))
         /\ WF_vars(Finish(r))

Spec == Init /\ [][Next]_vars /\ Fairness

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
TypeOK ==
    /\ state \in [Runs -> {"idle", "waiting", "running", "exited", "cleanup", "done"}]
    /\ endedBy \in [Runs -> {"none", "self", "stop", "raw"}]
    /\ kind \in [Runs -> {"none", "light", "heavy", "track"}]
    /\ ask \in [Runs -> 0..MaxCpus]
    /\ waited \in [Runs -> 0..WaitMax]
    /\ obs \in [Runs -> -1..MaxCpus]
    /\ calm \in [Runs -> 0..ShrinkAfter]
    /\ alive \in [Runs -> SUBSET Procs]
    /\ stub \in [Runs -> SUBSET Procs]
    /\ rec \in [Runs -> {"none", "ok", "failure", "cancel"}]
    /\ cap \in CapLevels /\ loadCap \in LoadCapLevels /\ load \in LoadLevels
    /\ \A r \in Runs : (state[r] = "waiting") <=> InQ(r)

\* Safety 1: at the moment a light or heavy run is admitted, what the holders are charged, the new run
\* included, stays within the cap. (Not an invariant of every state: a lowered cap, or a shrunk run climbing back to its
\* declaration, can push the sum over the cap while runs are going. The docstring says so, lines 53-60.)
AdmitWithinCap == admitOk

\* Safety 2: after a stop completes, no process of that run is alive. The stronger form: while any process of
\* a run is alive, the run still holds its slot. With Cgroup = FALSE this fails on a "setsid" process.
AfterStopNothingAlive == \A r \in Runs : (state[r] = "done" /\ cancelled[r]) => alive[r] = {}
SlotHeldWhileAlive == \A r \in Runs : alive[r] # {} => state[r] \in {"running", "exited", "cleanup"}

\* Safety 3: a cancel is never recorded as a failure, nor the reverse. Judged against what really ended the
\* command (`endedBy`, set by the event that ended it), not against the wrapper's own flag: a cancel is
\* recorded only for a command that a stop ended; a failure only for one that exited nonzero on its own or
\* died to a signal that did not come from `stop`; ok only for a clean exit. A stop that lands after the
\* command has exited on its own and before the reap makes the wrapper record a cancel for a command that was
\* already finished (Stop, line 1451), so TLC is expected to report this property violated by that window.
CancelNotFailure ==
    \A r \in Runs : state[r] = "done" =>
        /\ rec[r] = "cancel" => endedBy[r] = "stop"
        /\ rec[r] = "failure" => (endedBy[r] \in {"self", "raw"} /\ nz[r] /\ ~cancelled[r])
        /\ rec[r] = "ok" => (endedBy[r] = "self" /\ ~nz[r] /\ ~cancelled[r])

\* Consistency the rest relies on: a run marked "running" has a live main process.
RunningHasMain == \A r \in Runs : (state[r] = "running") => "main" \in alive[r]

\* Liveness. Assuming outside load drops below the load cap infinitely often, every run that is waiting
\* eventually starts. Every declaration fits under the cap, since cpus_of clamps a size to the cap (line 279),
\* so no run is excluded by size.
LoadDrops == []<>(load < loadCap)
EveryQueuedRunStarts == \A r \in Runs : (state[r] = "waiting") ~> (state[r] = "running")
Liveness == LoadDrops => EveryQueuedRunStarts

\* For the three-run configuration, which uses symmetry and so cannot check a temporal property.
Sym == Permutations(Runs)

=============================================================================
