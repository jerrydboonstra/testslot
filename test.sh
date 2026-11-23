#!/usr/bin/env bash
# Check testslot on one account, in a scratch slot folder: run on a Linux host as
#   bash test.sh [path/to/testslot]
# A cap of 2 cpus here (TESTSLOT_CAP), whatever the core count, and a load average read from a file
# the tests write (TESTSLOT_LOADAVG). The two-account check (two accounts at once, on the real
# /var/lib/testslot) needs both logins and is not run here.
set -uo pipefail
T=${1:-testslot}
export TS_SHIM_DIR=$(cd "$(dirname "$0")" && pwd)  # test_shim.py sits beside this file: it loads the package for the inline checks
# an absolute path: the odd-folder case cds away, and a relative ./testslot would no longer resolve there
case $T in */*) T=$(cd "$(dirname "$T")" && pwd)/$(basename "$T") ;; *) T=$(command -v "$T") || { echo "no $1 on PATH"; exit 1; } ;; esac
export TESTSLOT_DIR=$(mktemp -d /tmp/testslot-test.XXXXXX)
mkdir -p "$TESTSLOT_DIR/holders" "$TESTSLOT_DIR/logs"
export TESTSLOT_CAP=2 TESTSLOT_LOADAVG=$TESTSLOT_DIR/loadavg
echo "0.00 0.00 0.00 1/100 1" > "$TESTSLOT_LOADAVG"
unset TESTSLOT_HELD
# TESTSLOT_PLATFORM=darwin runs the suite through the macOS code (ps, no /proc/locks) on Linux; the
# checks that need a lock table are Linux-only and say so.
PLAT=${TESTSLOT_PLATFORM:-$(uname -s | tr 'A-Z' 'a-z')}
linux() { [ "$PLAT" = linux ]; }
# hold the heavy gate from outside testslot until $1 seconds pass; returns once the lock is taken
outside_hold() { rm -f "$O/held.ready"; python3 -c "import fcntl,time; f=open('$TESTSLOT_DIR/heavy','a+'); fcntl.flock(f, fcntl.LOCK_EX); open('$O/held.ready','w').close(); time.sleep($1)" &
  for _ in $(seq 50); do [ -e "$O/held.ready" ] && return; sleep 0.1; done; }
lstart() { LC_ALL=C ps -o lstart= -p "$1" | tr -s ' ' | sed 's/^ //; s/ $//'; }
skip() { echo "skip $1 (Linux only)"; }
mir=
# the cgroup cases (20) start sleeps named 600-619 plus $$, and one helper loop; a failing case must not leave them behind.
# The busy loops that trap TERM (7f, 18) carry "tsorph.$$" in their command line, so this trap can KILL them: killing
# the testslot wrapper alone (kill -9 $w) leaves its bash child behind with ppid 1.
trap '[ -n "$mir" ] && kill $mir 2>/dev/null; pkill -f "$TESTSLOT_DIR" 2>/dev/null; pkill -f "sleep 6[01][0-9]\\.$$" 2>/dev/null; pkill -9 -f "tsorph\\.$$" 2>/dev/null; pkill -9 -f "settle[A-D]\\.$$" 2>/dev/null; rm -rf "$TESTSLOT_DIR"' EXIT
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
stamp() { date +%s.%N; }
need() { for f; do [ -s "$O/$f" ] || { echo "     (missing $f)"; return 1; }; done; }   # no vacuous compare
O=$TESTSLOT_DIR/out; mkdir -p "$O"

# 1. Two heavy runs go one after the other.
"$T" run --heavy -- bash -c "stamp(){ date +%s.%N; }; stamp > $O/a1; sleep 2; stamp > $O/a2" >/dev/null 2>&1 &
sleep 0.4
"$T" run --heavy -- bash -c "date +%s.%N > $O/b1" >/dev/null 2>"$O/b.err" &
sleep 0.6
"$T" status | grep -q '^waiting:' && ok "status shows a waiting heavy run" || fail "status shows a waiting heavy run"
wait
need a2 b1 && awk -v a="$(cat $O/a2)" -v b="$(cat $O/b1)" 'BEGIN{exit !(b >= a)}' && ok "second heavy run started after the first ended" || fail "heavy runs overlapped"
grep -q "held by:" "$O/b.err" && ok "the waiting run named the holder" || fail "the waiting run named the holder"

# 2. Two 1-cpu runs share the cap of 2; a third waits and names the holders.
holding() { "$T" status | sed -n '/^holding:/,/^[a-z]/p' | grep -c "^  $1"; }
# the pgid of the first run of a kind, once it has one (status shows "-" until the command starts)
pgid_of() { local p; for _ in $(seq 50); do p=$("$T" status | awk -v k="  $1" 'index($0, k) == 1 {print $4; exit}')
  case $p in ''|*[!0-9]*) sleep 0.1 ;; *) echo "$p"; return ;; esac; done; }
# up to 5s, for a loaded box; a timeout says what never happened, so a later failure isn't a silent mystery
# wait for one background pid, but never for ever: after 30s say so and stop it. The exit code is left in $bwc.
bwaitp() { for _ in $(seq 300); do kill -0 "$1" 2>/dev/null || { wait "$1" 2>/dev/null; bwc=$?; return 0; }; sleep 0.1; done
  echo "     (pid $1 still running after 30s)"; kill -CONT "$1" 2>/dev/null; kill "$1" 2>/dev/null
  for _ in $(seq 50); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done; kill -KILL "$1" 2>/dev/null; wait "$1" 2>/dev/null; bwc=$?; return 1; }
until_true() { for _ in $(seq 50); do eval "$1" && return 0; sleep 0.1; done; echo "     (timed out after 5s waiting for: $1)"; return 1; }
# the two light runs hold for HOLD seconds: long enough for a slow probe on a loaded box to see both
HOLD=3
for i in 1 2; do "$T" run -- bash -c "date +%s.%N > $O/l$i; sleep $HOLD" >/dev/null 2>&1 & done
until_true '[ "$(holding light)" = 2 ]' || fail "2: the two light runs never showed as holding"
"$T" run -- bash -c "date +%s.%N > $O/l3" >/dev/null 2>"$O/l3.err" &
until_true 'grep -q "cpus: 2 of 2 in use" "$O/l3.err"' || fail "2: the third run never said it waits on 2 of 2"
n=$(holding light)
[ "$n" = 2 ] && ok "two light runs hold slots together" || fail "two light runs hold slots together (saw $n)"
grep -q "cpus: 2 of 2 in use" "$O/l3.err" && grep -q "light in" "$O/l3.err" && ok "a third light run waits and names the holders" || fail "a third light run waits and names the holders"
# 3. A heavy run waits for light runs; a light run queued behind it waits too (turnstile).
"$T" run --heavy -- bash -c "date +%s.%N > $O/h1" >/dev/null 2>"$O/h1.err" &
until_true 'grep -q "waiting" "$O/h1.err"' || fail "3: the heavy run never showed as waiting"   # a fixed 0.3s head start let a slow start queue the light run first
"$T" run -- bash -c "date +%s.%N > $O/l4" >/dev/null 2>&1 &
wait
need l1 h1 && awk -v l="$(cat $O/l1)" -v h="$(cat $O/h1)" 'BEGIN{exit !(h >= l + 2.9)}' && ok "heavy waited for the light runs" || fail "heavy waited for the light runs"
need l1 l2 l3 && awk -v a="$(cat $O/l1)" -v c="$(cat $O/l2)" -v b="$(cat $O/l3)" 'BEGIN{m = a < c ? a : c; exit !(b >= m + 2.9)}' && ok "the third light run started when a slot freed" || fail "the third light run overlapped"
need h1 l4 && awk -v h="$(cat $O/h1)" -v l="$(cat $O/l4)" 'BEGIN{exit !(l >= h)}' && ok "a light run queued behind a heavy one waited for it" || fail "light run jumped the waiting heavy run"

# 4. stop ends the whole group and the slot frees.
"$T" run --heavy -- bash -c "sleep 60 & sleep 60; wait" >/dev/null 2>&1 &
sleep 0.6
pg=$(pgid_of heavy)
"$T" stop "$pg" | grep -q "nothing left" && ok "stop ended group $pg" || fail "stop ended group $pg"
wait
[ -z "$(ls "$TESTSLOT_DIR/holders")" ] && ok "holder file removed after stop" || fail "holder file left after stop"

# 5. A wrapper killed with -9: status shows the command still running without a wrapper, and its cpus
# still count (it still burns them), so the next run starts only when that command ends.
"$T" run --heavy -- bash -c "sleep 2" >/dev/null 2>&1 &
w=$!; sleep 0.5; kill -9 $w; sleep 0.2
"$T" status | grep -q "WITHOUT a slot" && ok "status names the orphaned command, with its pgid" || fail "status lost the orphaned command"
timeout 0.8 "$T" run --heavy -- true >/dev/null 2>&1; c=$?
[ $c = 124 ] && ok "the orphaned command's cpus still count" || fail "a run started beside the orphaned command (exit $c)"
timeout 3 "$T" run --heavy -- true >/dev/null 2>&1 && ok "the next run starts once the orphaned command ends" || fail "the orphan's cpus stayed counted"
# not "free:": a real suite running outside testslot on this box is listed too, and that is right
! "$T" status | grep -qE "^(holding|tracked)|WITHOUT a slot" && ok "status forgets the run once its command ends" || fail "status still lists the dead run"

# 5a. A killed wrapper its parent hasn't reaped yet (a zombie) holds nothing: status says so.
python3 - "$T" "$O/zombie.out" <<'PY'
import os, signal, subprocess, sys, time
w = subprocess.Popen([sys.argv[1], "run", "--heavy", "--", "sleep", "2"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.6)
os.kill(w.pid, signal.SIGKILL)
time.sleep(0.2)  # not reaped: w stays a zombie while status runs
with open(sys.argv[2], "w") as f:
    f.write(subprocess.run([sys.argv[1], "status"], capture_output=True, text=True).stdout)
w.wait()
PY
grep -q "WITHOUT a slot" "$O/zombie.out" && ok "an unreaped (zombie) wrapper counts as gone" || fail "a zombie wrapper still shows as holding"
sleep 2

# 5b. A setsid daemon the command starts never holds the slot.
"$T" run --heavy -- setsid sleep 3.137 >/dev/null 2>&1
timeout 1 "$T" run --heavy -- true >/dev/null 2>&1 && ok "a setsid daemon doesn't keep the slot" || fail "a setsid daemon kept the slot"
pkill -x -f "sleep 3.137"   # an odd length, so no one else's sleep matches

# 6. An flock taken outside testslot (test-parallel's way) is shown and waited for.
python3 -c "import fcntl,time,sys; f=open('$TESTSLOT_DIR/heavy','a+'); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(2)" &
sleep 0.4
if linux; then "$T" status | grep -q "outside testslot" && ok "status shows an outside flock" || fail "status shows an outside flock"
else skip "status shows an outside flock"; fi
s=$(stamp); "$T" run -- true >/dev/null 2>&1; e=$(stamp)
awk -v s="$s" -v e="$e" 'BEGIN{exit !(e - s >= 1.2)}' && ok "a light run waited for the outside flock" || fail "a light run ignored the outside flock"
wait

# 6b. Cat Herder's own suite runner, tools/test-parallel, takes no flock testslot can count on (by default): status counts it
# by name as outside, and doesn't when it runs under testslot.
mkdir -p "$O/tools"; printf '#!/usr/bin/env python3\nimport os,sys,time\nopen(sys.argv[1],"w").write(str(os.getpid()))\ntime.sleep(2)\n' > "$O/tools/test-parallel"
chmod +x "$O/tools/test-parallel"
"$O/tools/test-parallel" "$O/tp-out.pid" & sleep 0.6
tp=$(cat "$O/tp-out.pid" 2>/dev/null)
"$T" status --json | python3 -c "import json,sys; o=json.load(sys.stdin)['outside']; sys.exit(not any(x['pid']==int('$tp' or 0) and x['how']=='test-parallel' for x in o))" \
  && ok "status counts a test-parallel outside testslot" || fail "status missed a test-parallel outside testslot (pid $tp)"
"$T" summary 2>&1 | grep -qE '[1-9][0-9]* outside testslot' && ok "summary counts it too" || fail "summary: $("$T" summary 2>&1 | head -1)"
wait
timeout 5 python3 -u "$O/tools/test-parallel" "$O/tp-wrap.pid" & sleep 0.6
tp=$(cat "$O/tp-wrap.pid" 2>/dev/null); tg=$(ps -o pgid= -p "${tp:-0}" | tr -d ' ')
# timeout leads the group, so the run is reported by its group, as timeout's pid
"$T" status --json | python3 -c "import json,sys; o=json.load(sys.stdin)['outside']; sys.exit(not any(x['pgid']==int('$tg' or 0) for x in o))" \
  && ok "found behind timeout and python3 -u" || fail "missed behind a wrapper (pid $tp)"
# the Mac's Homebrew Python is a framework build: ps shows .../Python.app/Contents/MacOS/Python (capital P), and a
# duration after timeout ("10m") is not a number of seconds
# (own session, so the group is its own: one group is reported once)
timeout 10m python3 "$O/tools/test-parallel" "$O/tp-dur.pid" & tpid=$!; sleep 0.6
dp=$(cat "$O/tp-dur.pid" 2>/dev/null)
"$T" status --json | python3 -c "import json,sys; o=json.load(sys.stdin)['outside']; sys.exit(not any(x['pid']==$tpid for x in o))" \
  && ok "found behind timeout 10m, reported as timeout's pid (the scan got past 10m)" || fail "missed behind timeout with a duration (pid $dp)"
wait
if command -v setsid >/dev/null; then   # a Mac has no setsid
setsid bash -c 'exec -a /opt/x/Python.app/Contents/MacOS/Python python3 "$0" "$1"' "$O/tools/test-parallel" "$O/tp-cap.pid" & sleep 0.8
cp=$(cat "$O/tp-cap.pid" 2>/dev/null); cg=$(ps -o pgid= -p "${cp:-0}" | tr -d ' ')
"$T" status --json | python3 -c "import json,sys; o=json.load(sys.stdin)['outside']; sys.exit(not any(x['pgid']==int('$cg' or 0) for x in o))" \
  && ok "found behind a capital-P Python (Homebrew framework build)" || fail "missed behind Python.app (pid $cp)"
else echo "skip found behind a capital-P Python (no setsid here)"; fi
wait
(exec -a "grep -f test-parallel" sleep 3) & gp=$!; (exec -a shellcheck python3 -c "import time; time.sleep(3)" tools/test-parallel) & sp=$!; sleep 0.3
ps -p $gp >/dev/null && ps -p $sp >/dev/null && ok "the decoys are alive when status runs" || fail "a decoy exited before status ran"
"$T" status --json | python3 -c "import json,sys; o=json.load(sys.stdin)['outside']; sys.exit(any(x['pid'] in ($gp, $sp) for x in o))" \
  && ok "another program naming test-parallel is not counted" || fail "counted a program that only names test-parallel"
kill $sp $gp 2>/dev/null; wait
"$T" run -- "$O/tools/test-parallel" "$O/tp-in.pid" >/dev/null 2>&1 & sleep 0.8
tp=$(cat "$O/tp-in.pid" 2>/dev/null)
"$T" status --json | python3 -c "import json,sys; o=json.load(sys.stdin)['outside']; sys.exit(any(x['pid']==int('$tp' or 0) for x in o) or not '$tp')" \
  && ok "a test-parallel under testslot is not outside" || fail "a test-parallel under testslot counted as outside (pid $tp)"
wait

# 7. Nested: a run inside a run doesn't wait on itself; the env tells test-parallel the slot is held.
timeout 5 "$T" run --heavy -- bash -c "\"$T\" run --heavy -- true && case \"\$TESTSLOT_HELD\" in heavy:*) ;; *) false;; esac" >/dev/null 2>&1 \
  && ok "nested run goes straight through" || fail "nested run deadlocked or lost the env"

# 7b. A heavy run inside a light one is refused, not waved through; test-parallel's own marker counts as held.
timeout 5 "$T" run -- "$T" run --heavy -- true >"$O/nest.err" 2>&1; c=$?
[ $c = 1 ] && grep -q "inside a light one" "$O/nest.err" && ok "heavy inside light refused" || fail "heavy inside light: exit $c"
# under a process that holds the gate itself (test-parallel's way), a nested run goes through
if linux; then timeout 5 python3 -c "import fcntl,subprocess,sys; f=open('$TESTSLOT_DIR/heavy','a+'); fcntl.flock(f, fcntl.LOCK_EX); sys.exit(subprocess.call(['$T','run','--heavy','--','true']))" >/dev/null 2>&1 \
  && ok "a run under test-parallel's own lock goes through" || fail "nested under test-parallel deadlocked"
else skip "a run under test-parallel's own lock goes through"; fi
# a leaked "held" variable, with no ancestor holding anything, does not open the gate
outside_hold 2
TESTSLOT_HELD=heavy timeout 1 "$T" run --heavy -- true >/dev/null 2>&1; c=$?
[ $c = 124 ] && ok "a leaked held variable still waits for the gate" || fail "a leaked held variable skipped the gate (exit $c)"
wait
# The macOS proof: a marker naming a live ancestor that is not a running wrapper (a shell, pid 1), or a
# wrapper that has exited, doesn't open the gate.
if ! linux; then
  outside_hold 3
  bash -c 'TESTSLOT_HELD="heavy:$$:$(LC_ALL=C ps -o lstart= -p $$ | tr -s " " | sed "s/^ //; s/ $//")" timeout 1 "$0" run --heavy -- true; c=$?; exit $c' "$T" >/dev/null 2>&1; c=$?
  [ $c = 124 ] && ok "a marker naming an ancestor that isn't a wrapper still waits" || fail "a shell ancestor opened the gate (exit $c)"
  TESTSLOT_HELD="heavy:1:$(lstart 1)" timeout 1 "$T" run --heavy -- true >/dev/null 2>&1; c=$?
  [ $c = 124 ] && ok "a marker naming pid 1 still waits" || fail "pid 1 opened the gate (exit $c)"
  sleep 31.3 & d=$!; ds=$(lstart $d); kill $d; wait $d 2>/dev/null
  TESTSLOT_HELD="heavy:$d:$ds" timeout 1 "$T" run --heavy -- true >/dev/null 2>&1; c=$?
  [ $c = 124 ] && ok "a marker naming an exited wrapper still waits" || fail "a dead marker opened the gate (exit $c)"
  wait
  # the holder record decides: an ancestor whose record says light doesn't prove a heavy run, one that says heavy does
  hold_rec='st=$(LC_ALL=C ps -o lstart= -p $$ | tr -s " " | sed "s/^ //; s/ $//"); printf "{\"pid\": %s, \"state\": \"running\", \"kind\": \"%s\", \"cpus\": 1, \"start\": \"%s\"}" $$ "$2" "$st" > "$1/holders/$$.json"; TESTSLOT_HELD="heavy:$$:$st" timeout 1 "$0" run --heavy -- true; c=$?; rm -f "$1/holders/$$.json"; exit $c'
  outside_hold 3
  bash -c "$hold_rec" "$T" "$TESTSLOT_DIR" light >/dev/null 2>&1; c=$?
  [ $c = 124 ] && ok "an ancestor whose record says light doesn't open a heavy gate" || fail "a light record opened the heavy gate (exit $c)"
  bash -c "$hold_rec" "$T" "$TESTSLOT_DIR" heavy >/dev/null 2>&1; c=$?
  [ $c = 0 ] && ok "an ancestor whose record says heavy is a nested run" || fail "a heavy record didn't count (exit $c)"
  wait
  # a ps that fails never reads as "nothing running": the run stops before taking a slot
  mkdir -p "$O/badps"; printf '#!/bin/sh\nexit 1\n' > "$O/badps/ps"; chmod +x "$O/badps/ps"
  PATH="$O/badps:$PATH" timeout 10 "$T" run -- true >/dev/null 2>"$O/badps.err"; c=$?
  [ $c = 1 ] && grep -q "ps failed" "$O/badps.err" && ok "a failing ps stops the run, closed" || fail "a failing ps: exit $c"
  # ps that starts failing after admission: the run still ends with its command's code, frees its slot and records it
  realps=$(command -v ps); rm -f "$O/psbroken"
  printf '#!/bin/sh\n[ -e "%s" ] && exit 1\nexec %s "$@"\n' "$O/psbroken" "$realps" > "$O/badps/ps"
  : > "$TESTSLOT_DIR/history.jsonl"
  PATH="$O/badps:$PATH" timeout 90 "$T" run -- bash -c "touch $O/psbroken; sleep 1; exit 3" >/dev/null 2>"$O/late.err"; c=$?
  rm -f "$O/psbroken"
  [ $c = 3 ] && [ -z "$(ls "$TESTSLOT_DIR/holders")" ] && grep -q '"exit": 3' "$TESTSLOT_DIR/history.jsonl" \
    && ok "ps failing mid-run: the run ends with its code, frees its slot, records it" || { fail "ps failing mid-run: exit $c"; sed 's/^/     /' "$O/late.err"; }
else echo "skip the macOS-only ancestor-marker and failing-ps block (not for Linux; this run is $PLAT)"; fi

# 7d. A command that leaves a background child: the slot frees when the command ends, nothing is left.
"$T" run --heavy -- bash -c "sleep 600.$$ & echo started" >/dev/null 2>&1   # $$ in the name: another session's "sleep 600" doesn't count
sleep 0.3
pgrep -f "sleep 600\\.$$" >/dev/null && fail "a background child outlived its run" || ok "the run's leftover child was ended"
timeout 2 "$T" run --heavy -- true >/dev/null 2>&1 && ok "the slot is free after a run with a leftover child" || fail "a leftover child kept the slot"

# 7c. A tracked run takes no slot: a heavy run starts beside it, and status lists it apart.
"$T" run --track -- sleep 2 >/dev/null 2>&1 &
sleep 0.4
"$T" status | grep -q "^tracked (no slot):" && ok "status lists the tracked run" || fail "status lists the tracked run"
timeout 1.5 "$T" run --heavy -- true >/dev/null 2>&1 && ok "a heavy run starts beside a tracked one" || fail "a tracked run blocked a heavy one"
wait

# 7e. A leftover that ignores TERM is killed after the grace period, and the slot frees.
s=$(stamp)
"$T" run --heavy -- bash -c "(trap '' TERM; exec sleep 30.$$) & sleep 0.2; exit 0" >/dev/null 2>&1   # $$ in the name: another suite's leftover doesn't count
e=$(stamp)
pgrep -f "sleep 30\\.$$" >/dev/null && fail "a TERM-ignoring leftover survived" || ok "a TERM-ignoring leftover was killed"
awk -v s="$s" -v e="$e" 'BEGIN{exit !(e - s >= 4.5 && e - s < 12)}' && ok "it got the 5s grace, then SIGKILL" || fail "grace period was $(awk -v s=$s -v e=$e 'BEGIN{print e-s}')s"

# 7f. Cancelling a run whose command traps TERM: it still ends (KILL after 5s), the run reports the
# signal rather than success, and the slot frees.
# The run must have started before the TERM, or the wrapper's pre-start path answers and proves nothing;
# a watchdog turns a hang (the old code) into a failure.
started() { until_true '[ "$(holding heavy)" = 1 ]' || { fail "$1: the run never took the slot"; kill -9 $w; pkill -9 -f "tsorph\\.$$" 2>/dev/null; return 1; }; }
watch() { ( sleep 15; kill -9 $w 2>/dev/null; pkill -9 -f "tsorph\\.$$" 2>/dev/null ) & dog=$!; wait $w; c=$?; kill $dog 2>/dev/null; }
"$T" run --heavy -- bash -c ": tsorph.$$; trap 'exit 0' TERM; trap '' INT; while :; do sleep 0.1; done" >/dev/null 2>&1 &
w=$!
if started "cancel"; then kill -TERM $w; watch
  [ $c = 143 ] && ok "a cancelled run reports 143, not its command's 0" || fail "a cancelled run exited $c"; fi
"$T" run --heavy -- bash -c ": tsorph.$$; trap '' TERM; while :; do sleep 0.1; done" >/dev/null 2>&1 &
w=$!
if started "TERM-proof"; then s=$(stamp); kill -TERM $w; watch; e=$(stamp)
  [ $c = 143 ] && awk -v s="$s" -v e="$e" 'BEGIN{exit !(e - s >= 4.5 && e - s < 9)}' && ok "a TERM-proof command is killed after the grace" || fail "a TERM-proof command held on (exit $c)"; fi
timeout 2 "$T" run --heavy -- true >/dev/null 2>&1 && ok "the slot is free after the cancel" || fail "the slot stayed held after the cancel"

# 8. Exit code and log; a command killed by a signal exits 128+n.
"$T" run -- bash -c 'kill -TERM $$' >/dev/null 2>&1; c=$?
[ $c = 143 ] && ok "a command killed by TERM exits 143" || fail "a command killed by TERM exited $c"
"$T" run --log "$O/x.log" -- bash -c "echo hello; exit 3" >/dev/null 2>&1; c=$?
[ $c = 3 ] && grep -q hello "$O/x.log" && ok "exit code and log kept" || fail "exit code ($c) or log lost"

# 8b. A log that can't be written (disk full; here a 100 KB file size limit) doesn't stall the run: 1 MB of output still drains.
(ulimit -f 100; timeout 10 "$T" run --log "$O/full.log" -- bash -c 'head -c 1000000 /dev/zero; exit 4') >/dev/null 2>"$O/full.err"; c=$?
[ $c = 4 ] && grep -q "log write failed" "$O/full.err" && ok "a full disk doesn't stall the run" || fail "a full disk: exit $c"

# 10. Admission by cpus (cap 4 here): a 3-cpu run holds; a 2-cpu run waits for cpus; a 1-cpu run queued
# behind it is backfilled: it fits in the 1 free cpu, so it starts ahead of the 2-cpu run (reserve time is long).
export TESTSLOT_RESERVE=600
before=$(stamp)
TESTSLOT_CAP=4 "$T" run --cpus 3 -- bash -c "date +%s.%N > $O/c3; sleep 2.5; date +%s.%N > $O/c3e" >/dev/null 2>&1 &
until_true '[ -s "$O/c3" ]'
TESTSLOT_CAP=4 "$T" run --cpus 2 -- bash -c "date +%s.%N > $O/c2" >/dev/null 2>"$O/c2.err" &
until_true 'grep -q "waiting" "$O/c2.err"'
TESTSLOT_CAP=4 "$T" run --cpus 1 --max-minutes 5 -- bash -c "date +%s.%N > $O/c1; sleep 1" >/dev/null 2>"$O/c1.err" &
until_true '[ -s "$O/c1" ]'
TESTSLOT_CAP=4 "$T" status --json > "$O/snap.json"
TESTSLOT_CAP=4 "$T" status > "$O/snap.txt"
wait
grep -q "cpus: 3 of 4 in use, this run needs 2" "$O/c2.err" && ok "a run that doesn't fit waits, and says why" || fail "the 2-cpu run's wait: $(head -1 $O/c2.err)"
need c3 c3e c2 c1 && awk -v s="$(cat $O/c3)" -v e="$(cat $O/c3e)" -v b="$(cat $O/c2)" -v c="$(cat $O/c1)" 'BEGIN{exit !(c < e && c > s && b >= e)}' \
  && ok "a small run that fits starts ahead of a bigger waiting one (backfill)" || fail "the 1-cpu run did not backfill ahead of the waiting 2-cpu run"
python3 - "$O/snap.json" <<'PY' && ok "status --json: running cpus, backfill flag, waiting in order, reserve fields" || fail "status --json content"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["cap"] == 4 and s["cpus_in_use"] == 4 and s["cpus_free"] == 0, s
assert sorted(j["cpus"] for j in s["running"]) == [1, 3], s["running"]
assert [j["backfill"] for j in sorted(s["running"], key=lambda j: j["cpus"])] == [True, False], s["running"]
assert [(j["position"], j["cpus"]) for j in s["waiting"]] == [(1, 2)], s["waiting"]
assert s["reserve_s"] == 600 and s["reserved_by"] is None, (s["reserve_s"], s["reserved_by"])
for k in ("host", "generated_at", "cores", "load", "tracked", "outside"):
    assert k in s, k
for k in ("pid", "pgid", "account", "repo", "command", "kind", "state", "queued", "started", "wait_s", "run_s", "log", "backfill"):
    assert k in s["running"][0], k
PY
grep -q "started by backfill" "$O/snap.txt" && ok "status prints a run started by backfill" || fail "status text: $(cat $O/snap.txt)"

# 10a. Same size keeps first-come order (reserve long): cap 4, a 4-cpu run holds, two 3-cpu runs queue A then B;
# only one 3-cpu run fits at a time, and when the 4-cpu run ends A must start before B.
export TESTSLOT_RESERVE=600
TESTSLOT_CAP=4 "$T" run --cpus 4 -- bash -c "date +%s.%N > $O/s4; sleep 2.6" >/dev/null 2>&1 &
until_true '[ -s "$O/s4" ]'
TESTSLOT_CAP=4 "$T" run --cpus 3 -- bash -c "date +%s.%N > $O/sA; sleep 1" >/dev/null 2>"$O/sA.err" &
until_true 'grep -q "waiting" "$O/sA.err"'
sleep 0.8   # B polls out of step with A, so a mutant that lets B pass A shows up as B starting first
TESTSLOT_CAP=4 "$T" run --cpus 3 -- bash -c "date +%s.%N > $O/sB; sleep 1" >/dev/null 2>"$O/sB.err" &
until_true 'grep -q "queued ahead" "$O/sB.err"'
wait
need sA sB && awk -v a="$(cat $O/sA)" -v b="$(cat $O/sB)" 'BEGIN{exit !(a < b)}' \
  && ok "runs of one size start in the order they queued" || fail "a later same-size run started before an earlier one"

# 10b. Reserve: a head run that has waited past the reserve time is not passed by a later run that would fit;
# status and summary name it, and it starts once the cpus free.
export TESTSLOT_RESERVE=1
TESTSLOT_CAP=4 "$T" run --cpus 3 -- bash -c "date +%s.%N > $O/r3; sleep 4; date +%s.%N > $O/r3e" >/dev/null 2>&1 &
until_true '[ -s "$O/r3" ]'
TESTSLOT_CAP=4 "$T" run --cpus 2 -- bash -c "date +%s.%N > $O/r2" >/dev/null 2>"$O/r2.err" &
until_true 'grep -q "waiting" "$O/r2.err"'
sleep 1.5
TESTSLOT_CAP=4 "$T" run --cpus 1 -- bash -c "date +%s.%N > $O/r1" >/dev/null 2>"$O/r1.err" &
until_true 'grep -q "reserved" "$O/r1.err"'
TESTSLOT_CAP=4 "$T" status --json > "$O/rsnap.json"
TESTSLOT_CAP=4 "$T" status > "$O/rsnap.txt"
TESTSLOT_CAP=4 "$T" summary > "$O/rsum.txt"
wait
grep -q "cpus are reserved for the run at the head" "$O/r1.err" && ok "a later run says cpus are reserved for the head" || fail "the 1-cpu run's wait: $(head -1 $O/r1.err)"
need r3e r2 r1 && awk -v e="$(cat $O/r3e)" -v b="$(cat $O/r2)" -v c="$(cat $O/r1)" 'BEGIN{exit !(b >= e && c >= b)}' \
  && ok "past the reserve time nothing passes the head, and it starts once cpus free" || fail "a later run passed the reserved head"
python3 - "$O/rsnap.json" <<'PY' && ok "status --json names the run cpus are reserved for" || fail "status --json reserved_by"
import json, sys
s = json.load(open(sys.argv[1]))
r = s["reserved_by"]
assert r and r["cpus"] == 2 and r["position"] == 1 and s["reserve_s"] == 1, s["reserved_by"]
PY
grep -q "cpus reserved for it" "$O/rsnap.txt" && grep -q "cpus reserved for it" "$O/rsum.txt" && ok "status and summary say which run reserves cpus" || fail "reserve not shown: $(cat $O/rsnap.txt $O/rsum.txt)"
export TESTSLOT_RESERVE=600

# 10g. A head the load holds back while anything holds (its cpus on top of the load go over the load cap) can start
# only on an idle slot, so it must not hold back runs that fit meanwhile (the 2026-10-21 jam). Cap 20, load-cap 10,
# a 4-cpu holder, a 12-cpu head, then a 1-cpu and a 4-cpu run: both start while the holder still runs, the head starts
# once it ends. Reserve 1 s, so the head's longer wait (6 x 1 s) is past the smaller runs' start but short of the
# holder's end. Then, past the 6 s mark, a later run waits for the head: the reserve does fire (the trade against
# starvation). Waits are polled, so a run that never starts fails the test instead of hanging it.
# A run that starts behind such a head
# needs --max-minutes, as the two runs here carry; one without waits for the head (case 25b).
export TESTSLOT_RESERVE=1
until_long() { for _ in $(seq 200); do eval "$1" && return 0; sleep 0.1; done; echo "     (timed out after 20s waiting for: $1)"; return 1; }
G="env TESTSLOT_CAP=20 TESTSLOT_LOAD_CAP=10 $T"
# the holder's sleep carries the scratch folder in its argv, so the exit trap finds it
$G run --cpus 4 -- bash -c "date +%s.%N > $O/g4; python3 -c 'import time; time.sleep(12)  # $TESTSLOT_DIR'; date +%s.%N > $O/g4e" >/dev/null 2>&1 &
until_true '[ -s "$O/g4" ] && [ "$(holding light)" = 1 ]' || fail "10g: the holder never started or never showed as holding"
$G run --cpus 12 -- bash -c "date +%s.%N > $O/g12" >/dev/null 2>"$O/g12.err" &
until_true 'grep -q "waiting" "$O/g12.err"' || fail "10g: the 12-cpu head never showed as waiting"
sleep 1.5   # past the plain reserve time (1 s), short of the longer one for this head
$G run --cpus 1 --max-minutes 5 -- bash -c "date +%s.%N > $O/g1" >/dev/null 2>&1 &
$G run --cpus 4 --max-minutes 5 -- bash -c "date +%s.%N > $O/g4b" >/dev/null 2>&1 &
until_true '[ -s "$O/g1" ] && [ -s "$O/g4b" ]' || fail "10g: the smaller runs never started behind the head"
[ ! -s "$O/g4e" ] && need g1 g4b && ok "runs that fit start, while the holder runs, behind the over-load-cap head" || fail "10g: the smaller runs started only after the holder ended"
sleep 5.5   # the head has now waited past 6 x RESERVE
$G run --cpus 1 -- bash -c "date +%s.%N > $O/g5" >/dev/null 2>"$O/g5.err" &
until_true 'grep -q "reserved" "$O/g5.err"' && ok "past six times the reserve time the head reserves, and a later run waits for it" || fail "10g: no reserve at the 6x mark: $(head -1 $O/g5.err)"
until_long '[ -s "$O/g12" ] && [ -s "$O/g5" ]' || fail "10g: the head or the later run never started"
need g4e g12 g5 && awk -v e="$(cat $O/g4e)" -v h="$(cat $O/g12)" -v l="$(cat $O/g5)" 'BEGIN{exit !(h >= e && l >= h)}' \
  && ok "the over-load-cap head starts once the slot is idle, then the run behind it" || fail "10g: the head did not start after the holder"

# 10i. The same at a load that isn't zero: at load 4.7 a head of 8 cpus (4.7 + 8 is over the load cap 10) can't start
# while anything holds either, though 8 is under the cap, so it must not reserve at the plain reserve time.
echo "4.70 4.00 3.00 1/100 1" > "$TESTSLOT_LOADAVG"
$G run --cpus 1 -- bash -c "date +%s.%N > $O/i1; python3 -c 'import time; time.sleep(9)  # $TESTSLOT_DIR'; date +%s.%N > $O/i1e" >/dev/null 2>&1 &
until_true '[ -s "$O/i1" ] && [ "$(holding light)" = 1 ]' || fail "10i: the holder never started or never showed as holding"
$G run --cpus 8 -- bash -c "date +%s.%N > $O/i8" >/dev/null 2>"$O/i8.err" &
until_true 'grep -q "waiting" "$O/i8.err"' || fail "10i: the 8-cpu head never showed as waiting"
sleep 1.5
$G run --cpus 1 --max-minutes 5 -- bash -c "date +%s.%N > $O/i2" >/dev/null 2>"$O/i2.err" &
until_true '[ -s "$O/i2" ]' && [ ! -s "$O/i1e" ] && ok "at load 4.7 a head of 8 cpus doesn't hold back a run that fits" || fail "10i: the 1-cpu run waited behind the 8-cpu head: $(head -1 $O/i2.err)"
until_long '[ -s "$O/i8" ]' || fail "10i: the 8-cpu head never started"
echo "0.00 0.00 0.00 1/100 1" > "$TESTSLOT_LOADAVG"
export TESTSLOT_RESERVE=600

# 10h. A --heavy run asks for the whole cap, over the load cap too, but still reserves after the plain reserve time
# (it drains the slot that way): cap 4, load-cap 2, a 1-cpu holder, a heavy head, then a 1-cpu run that would fit.
export TESTSLOT_RESERVE=1
H="env TESTSLOT_CAP=4 TESTSLOT_LOAD_CAP=2 $T"
$H run --cpus 1 -- bash -c "date +%s.%N > $O/h1; python3 -c 'import time; time.sleep(4)  # $TESTSLOT_DIR'; date +%s.%N > $O/h1e" >/dev/null 2>&1 &
until_true '[ -s "$O/h1" ] && [ "$(holding light)" = 1 ]' || fail "10h: the holder never started or never showed as holding"
$H run --heavy -- bash -c "date +%s.%N > $O/hh" >/dev/null 2>"$O/hh.err" &
until_true 'grep -q "waiting" "$O/hh.err"' || fail "10h: the heavy head never showed as waiting"
sleep 1.5
$H run --cpus 1 -- bash -c "date +%s.%N > $O/h2" >/dev/null 2>"$O/h2.err" &
until_true 'grep -q "reserved" "$O/h2.err"' && ok "a heavy head reserves after the plain reserve time" || fail "10h: a heavy head did not reserve: $(head -1 $O/h2.err)"
until_long '[ -s "$O/hh" ] && [ -s "$O/h2" ]' || fail "10h: the heavy head or the run behind it never started"
export TESTSLOT_RESERVE=600

# 11. The load is a second gate: a run waits while the load is at or over the cap, even with nothing
# else under testslot (outside work counts), and, with another run going, while load + its cpus is over.
echo "3.50 3.00 2.00 1/100 1" > "$TESTSLOT_LOADAVG"
TESTSLOT_CAP=4 timeout 5 "$T" run -- true >/dev/null 2>&1 && ok "with nothing else running, a load under the cap doesn't block" || fail "a lone run waited on a load under the cap"
echo "4.50 3.00 2.00 1/100 1" > "$TESTSLOT_LOADAVG"
TESTSLOT_CAP=4 timeout 5 "$T" run -- true >/dev/null 2>"$O/lone.err"; c=$?
[ $c = 124 ] && grep -q "load: 4.5" "$O/lone.err" && ok "a lone run waits while outside load is over the cap" || fail "a lone run started over the cap ($c)"
# the load gate has its own level when load-cap is set (the Mac sets one in $DIR/load-cap)
TESTSLOT_LOAD_CAP=6 timeout 5 "$T" run -- true >/dev/null 2>&1 && ok "with load-cap 6, load 4.5 doesn't block" || fail "load-cap 6 ignored at load 4.5"
echo "6.50 3.00 2.00 1/100 1" > "$TESTSLOT_LOADAVG"
TESTSLOT_LOAD_CAP=6 timeout 5 "$T" run -- true >/dev/null 2>"$O/lc.err"; c=$?
[ $c = 124 ] && grep -q "load cap 6" "$O/lc.err" && ok "with load-cap 6, load 6.5 holds the run" || fail "load-cap 6 at load 6.5: exit $c"
echo 6 > "$TESTSLOT_DIR/load-cap"
"$T" status --json | python3 -c 'import json,sys; j=json.load(sys.stdin); sys.exit(not (j["load_cap"] == 6 and j["platform"] == "'"$PLAT"'"))' \
  && ok "status --json shows load_cap and platform" || fail "status --json load_cap/platform"
echo "4.50 3.00 2.00 1/100 1" > "$TESTSLOT_LOADAVG"
timeout 5 "$T" run -- true >/dev/null 2>&1 && ok "with the load-cap file at 6 (cap 2), load 4.5 doesn't block" || fail "the load-cap file was ignored at load 4.5"
echo "6.50 3.00 2.00 1/100 1" > "$TESTSLOT_LOADAVG"
timeout 1 "$T" run -- true >/dev/null 2>&1; c=$?
[ $c = 124 ] && ok "the load-cap file holds a run at load 6.5" || fail "the load-cap file didn't gate (exit $c)"
"$T" status | grep -q "closed" && ok "status says closed over the load cap" || fail "status didn't say closed at load 6.5"
echo inf > "$TESTSLOT_DIR/load-cap"
TESTSLOT_LOAD_CAP=nan "$T" status --json | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["load_cap"] != 2)' \
  && ok "inf and nan load caps are ignored" || fail "a non-finite load cap was taken"
rm -f "$TESTSLOT_DIR/load-cap"
echo "3.50 3.00 2.00 1/100 1" > "$TESTSLOT_LOADAVG"
TESTSLOT_CAP=4 "$T" run -- bash -c "sleep 3" >/dev/null 2>&1 &
until_true '[ "$(holding light)" = 1 ]'
TESTSLOT_CAP=4 "$T" run -- bash -c "date +%s.%N > $O/ld" >/dev/null 2>"$O/ld.err" &
until_true 'grep -q "load: 3.5" "$O/ld.err"' && ok "a run waits while the load is too high, and says so" || fail "the load gate: $(head -1 $O/ld.err)"
[ -s "$O/ld" ] && fail "it started anyway" || { s=$(stamp); echo "0.50 1.00 1.00 1/100 1" > "$TESTSLOT_LOADAVG"; until_true '[ -s "$O/ld" ]'
  awk -v s="$s" -v b="$(cat $O/ld)" 'BEGIN{exit !(b - s < 2.5)}' && ok "it starts once the load drops" || fail "it didn't start when the load dropped"; }
wait
echo "0.00 0.00 0.00 1/100 1" > "$TESTSLOT_LOADAVG"

# 12. --cpus checks: over the cap gets the cap (and says so); a bad number or two modes is a usage error.
"$T" run --cpus 9 -- true >/dev/null 2>"$O/big.err"; c=$?
[ $c = 0 ] && grep -q "over the cap; this run gets all 2" "$O/big.err" && ok "--cpus over the cap gets the cap" || fail "--cpus 9: exit $c"
for bad in "--cpus 0" "--cpus x" "--cpus 1 --heavy" "--heavy --track"; do
  "$T" run $bad -- true >/dev/null 2>&1; c=$?
  [ $c = 2 ] && ok "run $bad is a usage error" || fail "run $bad exited $c"
done

# 13. History: every finished run leaves one line with its times and exit; a killed wrapper's run is
# written by the next run's prune, marked lost; a cancelled one keeps its signal.
H=$TESTSLOT_DIR/history.jsonl
: > "$H"
"$T" run --cpus 2 -- bash -c "sleep 0.3; exit 3" >/dev/null 2>&1
"$T" run --heavy -- bash -c "sleep 2" >/dev/null 2>&1 &
w=$!; until_true '[ "$(holding heavy)" = 1 ]'; kill -TERM $w; wait $w
"$T" run --heavy -- bash -c "sleep 2" >/dev/null 2>&1 &
w=$!; until_true '[ "$(holding heavy)" = 1 ]'; kill -9 $w; sleep 2.3
"$T" run -- true >/dev/null 2>&1   # its prune finds the dead wrapper
python3 - "$H" <<'PY' && ok "history: exit, times, cancel and lost are recorded" || fail "history content"
import json, sys
rs = [json.loads(l) for l in open(sys.argv[1])]
assert len(rs) == 4, len(rs)
a = rs[0]
assert a["exit"] == 3 and a["cpus"] == 2 and a["queued"] <= a["started"] <= a["ended"], a
assert a["run_s"] >= 0.3 and a["wait_s"] >= 0 and not a.get("lost"), a
assert rs[1]["exit"] == 143, rs[1]
lost = [r for r in rs if r.get("lost")]
assert len(lost) == 1 and lost[0]["exit"] is None and lost[0]["kind"] == "heavy", lost
assert rs[-1]["exit"] == 0 and rs[-1]["cpus"] == 1, rs[-1]
for k in ("pid", "pgid", "account", "repo", "command", "kind", "cpus", "queued", "started", "ended", "exit",
          "wait_s", "run_s", "load_at_start", "log"):
    assert k in a, k
PY

# 14. summary: --json counts the history; the plain form prints; --since narrows it.
"$T" summary --json > "$O/sum.json"
python3 - "$O/sum.json" <<'PY' && ok "summary --json counts runs, waits and cpus over time" || fail "summary --json content"
import json, sys
s = json.load(open(sys.argv[1]))
h = s["history"]
assert h["runs"] == 4 and h["ok"] == 1 and h["failed"] == 1 and h["cancelled"] == 1 and h["lost"] == 1, h
assert h["run_s"]["median"] is not None and h["wait_s"]["max"] is not None, h
assert len(h["cpus_over_time"]["cpus"]) == 24, h["cpus_over_time"]
assert "running" in s["now"] and "cap" in s["now"], s["now"].keys()
PY
# over a minute, the buckets are short enough to show those few seconds of cpus
"$T" summary --since 60s --json | python3 -c 'import json,sys; c=json.load(sys.stdin)["history"]["cpus_over_time"]["cpus"]; sys.exit(not (len(c) == 24 and max(c) > 0))' \
  && ok "cpus over time shows the runs" || fail "cpus over time stayed empty"
"$T" summary | grep -q "^last 12h: 4 runs" && ok "summary prints the last 12 hours" || fail "summary plain form: $("$T" summary | sed -n 2p)"
sleep 1.1
"$T" summary --since 1s --json | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["history"]["runs"])' && ok "summary --since 1s leaves the older runs out" || fail "summary --since"
"$T" summary --since 12x >/dev/null 2>&1; [ $? = 2 ] && ok "a bad --since is a usage error" || fail "a bad --since"

# 14b. summary and history show a backfilled run: a 3-cpu run holds (cap 4), a 2-cpu run waits, a 1-cpu run
# backfills ahead of it. History marks only that run; summary counts it and, while it runs, says so.
: > "$H"
export TESTSLOT_RESERVE=600
TESTSLOT_CAP=4 "$T" run --cpus 3 -- bash -c "date +%s.%N > $O/bf3; sleep 3" >/dev/null 2>&1 &
until_true '[ -s "$O/bf3" ]'
TESTSLOT_CAP=4 "$T" run --cpus 2 -- true >/dev/null 2>"$O/bf2.err" &
until_true 'grep -q "waiting" "$O/bf2.err"'
TESTSLOT_CAP=4 "$T" run --cpus 1 --max-minutes 5 -- bash -c "date +%s.%N > $O/bf1; sleep 1.5" >/dev/null 2>&1 &
until_true '[ -s "$O/bf1" ]'
TESTSLOT_CAP=4 "$T" summary > "$O/bsum.txt"
wait
grep -q "(started by backfill)" "$O/bsum.txt" && ok "summary says which running run started by backfill" || fail "summary text: $(cat $O/bsum.txt)"
python3 - "$H" <<'PY' && ok "history marks only the backfilled run" || fail "history backfill key"
import json, sys
rs = [json.loads(l) for l in open(sys.argv[1])]
assert len(rs) == 3 and all("backfill" in r for r in rs), rs
assert sorted((r["cpus"], r["backfill"]) for r in rs) == [(1, True), (2, False), (3, False)], rs
PY
"$T" summary --json | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["history"]["backfilled"] != 1)' \
  && ok "summary --json counts the backfilled run" || fail "summary --json backfilled"
"$T" summary | grep -q "^last 12h: 3 runs.*1 started by backfill" && ok "summary prints the backfill count" || fail "summary plain form: $("$T" summary | sed -n 2p)"

# 15. history rolls over to history.jsonl.1 past its size, and summary still reads both.
: > "$H"; rm -f "$H.1"
for i in 1 2 3; do TESTSLOT_HISTORY_MAX=200 "$T" run -- true >/dev/null 2>&1; done
n=$(cat "$H" "$H.1" 2>/dev/null | wc -l | tr -d ' ')
[ -s "$H.1" ] && [ "$n" = 2 ] && [ "$("$T" summary --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["history"]["runs"])')" = 2 ] \
  && ok "history rolls over, one old file kept, summary reads both" || fail "rollover: $n lines, .1 $( [ -s "$H.1" ] && echo present || echo missing)"

# 16. Attack fixes: a stopped (Ctrl-Z) waiter gives up its place; a holder whose pid now belongs to
# another process counts as gone; a command that exits 130 by itself is failed, not cancelled; nan is
# not a span.
"$T" run --heavy -- sleep 1.5 >/dev/null 2>&1 &
until_true '[ "$(holding heavy)" = 1 ]'
"$T" run --heavy -- true >/dev/null 2>&1 &
z=$!; until_true '"$T" status | grep -q "^waiting:"'; kill -STOP $z
timeout 4 "$T" run -- true >/dev/null 2>&1 && ok "a stopped waiter doesn't block the queue" || fail "a stopped waiter blocked the queue"
kill -CONT $z; wait
sleep 30.271 & sp=$!
echo "{\"pid\": $sp, \"start\": 1, \"account\": \"x\", \"repo\": \"/r\", \"command\": \"c\", \"kind\": \"heavy\", \"cpus\": 2, \"state\": \"running\", \"queued\": 1, \"since\": 1, \"pgid\": null, \"log\": \"l\"}" > "$TESTSLOT_DIR/holders/$sp.json"
timeout 2 "$T" run --heavy -- true >/dev/null 2>&1 && ok "a reused pid doesn't hold cpus" || fail "a holder with a reused pid kept its cpus"
[ -e "$TESTSLOT_DIR/holders/$sp.json" ] && fail "prune kept the reused pid's holder" || ok "prune dropped the reused pid's holder"
kill $sp 2>/dev/null; wait $sp 2>/dev/null
: > "$H"; rm -f "$H.1"
"$T" run -- bash -c 'exit 130' >/dev/null 2>&1
"$T" summary --since 1m --json | python3 -c 'import json,sys; h=json.load(sys.stdin)["history"]; sys.exit(not (h["failed"] == 1 and h["cancelled"] == 0))' \
  && ok "exit 130 from the command itself counts as failed" || fail "exit 130 counted as cancelled"
"$T" summary --since nan >/dev/null 2>&1; [ $? = 2 ] && ok "--since nan is a usage error" || fail "--since nan accepted"

# 17. Fix round 2: a run ended by `testslot stop` counts as cancelled; the shared cap file beats the env;
# --since inf is refused.
: > "$H"; rm -f "$H.1"
"$T" run -- sleep 30 >/dev/null 2>&1 &
until_true '[ "$(holding light)" = 1 ]'
"$T" stop "$(pgid_of light)" >/dev/null; wait
"$T" summary --since 1m --json | python3 -c 'import json,sys; h=json.load(sys.stdin)["history"]; sys.exit(not (h["cancelled"] == 1 and h["failed"] == 0))' \
  && ok "a run ended by testslot stop counts as cancelled" || fail "a stopped run counted as failed"
echo 5 > "$TESTSLOT_DIR/cap"
TESTSLOT_CAP=2 "$T" status --json | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["cap"] != 5)' && ok "the shared cap file beats the env" || fail "the env beat the cap file"
rm -f "$TESTSLOT_DIR/cap"
"$T" summary --since inf >/dev/null 2>&1; [ $? = 2 ] && ok "--since inf is a usage error" || fail "--since inf accepted"

# 18. Send-back fixes: a command killed by a signal of its own (the OOM killer, say) counts as failed;
# stop and stop --kill go through the wrapper, so both count as cancelled.
: > "$H"; rm -f "$H.1"
"$T" run -- bash -c 'kill -KILL $$' >/dev/null 2>&1; c1=$?
"$T" run -- bash -c 'kill -TERM $$' >/dev/null 2>&1
"$T" run -- python3 -c 'import os,signal; os.kill(os.getpid(), signal.SIGINT)' >/dev/null 2>&1
[ $c1 = 137 ] && ok "a self-KILLed command exits 137" || fail "a self-KILLed command exited $c1"
"$T" summary --since 1m --json | python3 -c 'import json,sys; h=json.load(sys.stdin)["history"]; sys.exit(not (h["failed"] == 3 and h["cancelled"] == 0))' \
  && ok "self-killed commands (KILL, TERM, INT) count as failed" || fail "self-killed commands counted as cancelled"
: > "$H"
"$T" run -- bash -c 'trap "" TERM; sleep 30' >/dev/null 2>&1 &
z=$!; until_true '[ "$(holding light)" = 1 ]'
"$T" stop --kill "$(pgid_of light)" >/dev/null; kill -CONT $z 2>/dev/null; bwaitp $z || fail "18: the stop --kill run did not end in 30s"
"$T" summary --since 1m --json | python3 -c 'import json,sys; h=json.load(sys.stdin)["history"]; sys.exit(not (h["cancelled"] == 1 and h["failed"] == 0))' \
  && ok "a run ended by testslot stop --kill counts as cancelled" || fail "a stop --kill run counted as failed"
: > "$H"
# five times: before the copy thread's signal mask, a stop here lost about half the time
czf=0
for i in 1 2 3 4 5; do
  "$T" run -- sleep 30 >/dev/null 2>&1 &
  z=$!; until_true '[ "$(holding light)" = 1 ]'
  zp=$(pgid_of light)   # the pgid is known once the command runs; stopping the wrapper earlier (inside its start, which on Linux takes a systemd scope) is a different case
  kill -STOP $z
  "$T" stop "$zp" >"$O/cz.out" 2>&1
  grep -q "nothing left" "$O/cz.out" || { czf=$i; sed 's/^/     /' "$O/cz.out"; "$T" status | sed 's/^/     /'; "$T" stop --kill "$(pgid_of light)" >/dev/null 2>&1; }
  wait $z
  [ $czf = 0 ] || break
  [ $i = 5 ] || : > "$H"
done
[ $czf = 0 ] && ok "stop ends a run whose wrapper was Ctrl-Z'd (5 of 5)" || fail "stop of a Ctrl-Z'd run (try $czf)"
timeout 2 "$T" run --heavy -- true >/dev/null 2>&1 && ok "its slot is free after" || fail "a Ctrl-Z'd run kept its slot"
"$T" summary --since 1m --json | python3 -c 'import json,sys; h=json.load(sys.stdin)["history"]; sys.exit(not (h["cancelled"] == 1 and h["failed"] == 0))' \
  && ok "and it counts as cancelled" || fail "a stopped Ctrl-Z'd run counted as failed"
# A command that handles TERM and exits 0 still reports a cancel when stopped: only the wrapper can tell.
"$T" run -- bash -c ": tsorph.$$; trap 'exit 0' TERM; while :; do sleep 0.1; done" >/dev/null 2>&1 &
z=$!; until_true '[ "$(holding light)" = 1 ]'
"$T" stop "$(pgid_of light)" >/dev/null; kill -CONT $z 2>/dev/null; bwaitp $z || fail "18: the stopped run did not end in 30s"; c=$bwc
[ $c = 143 ] && ok "a stopped run whose command exits 0 on TERM reports 143" || fail "a stopped run that trapped TERM exited $c"

# 18b. A half-written holder record (another account's, by hand) doesn't crash status or a waiter.
sleep 31.9 & d=$!; echo "{\"pid\": $d, \"state\": \"running\", \"kind\": \"light\", \"cpus\": 2}" > "$TESTSLOT_DIR/holders/$d.json"
"$T" status >/dev/null 2>&1 && "$T" status --json >/dev/null 2>&1 && ok "status reads a half-written holder" || fail "status crashed on a half-written holder"
timeout 1 "$T" run -- true >/dev/null 2>"$O/half.err"; c=$?
[ $c = 124 ] && ! grep -q Traceback "$O/half.err" && ok "a waiter prints a half-written holder" || fail "a waiter on a half-written holder: exit $c"
kill $d; wait $d 2>/dev/null; rm -f "$TESTSLOT_DIR/holders/$d.json"
# wrong types (a string where a number goes) beside a normal record: sorting and arithmetic don't crash
sleep 31.8 & d=$!; echo "{\"pid\": $d, \"state\": \"running\", \"kind\": \"light\", \"cpus\": \"two\", \"queued\": \"soon\", \"since\": \"now\", \"pgid\": \"x\"}" > "$TESTSLOT_DIR/holders/$d.json"
"$T" run -- sleep 3 >/dev/null 2>&1 & e=$!
until_true '[ "$(holding light)" = 2 ]'
"$T" status >/dev/null 2>"$O/wt.err" && "$T" status --json >/dev/null 2>>"$O/wt.err" && ! grep -q Traceback "$O/wt.err" \
  && ok "status reads a record with wrong types" || { fail "status crashed on wrong types"; sed 's/^/     /' "$O/wt.err"; }
kill $d; wait $d 2>/dev/null; rm -f "$TESTSLOT_DIR/holders/$d.json"; wait $e

# 19. Another account can swap a shared name for a link to a private file: it is never followed or chmodded.
printf secret > "$O/victim"; chmod 600 "$O/victim"
mv "$H" "$H.keep" 2>/dev/null; ln -s "$O/victim" "$H"
"$T" run -- true >/dev/null 2>&1
[ "$(cat "$O/victim")" = secret ] && [ "$(stat -c %a "$O/victim" 2>/dev/null || stat -f %Lp "$O/victim")" = 600 ] \
  && ok "a history link to a private file is neither written nor chmodded" || fail "the history link was followed"
rm -f "$H"; mv "$H.keep" "$H" 2>/dev/null

# sync points: wait until status shows N runs waiting / running (poll, not a fixed sleep)
nwait() { for _ in $(seq 100); do "$T" status --json 2>/dev/null | python3 -c "import json,sys; sys.exit(not (len(json.load(sys.stdin)['waiting']) >= $1))" && return 0; sleep 0.1; done; return 1; }
nrun() { for _ in $(seq 100); do "$T" status --json 2>/dev/null | python3 -c "import json,sys; sys.exit(not (len(json.load(sys.stdin)['running']) >= $1))" && return 0; sleep 0.1; done; return 1; }

# 10c. A cap raised while a run waits reaches it: the waiting run reads the cap file on each check.
# Cap 2, a 2-cpu run holds it, a second 2-cpu run waits; the cap file goes to 4 and the second starts within a few checks.
echo 2 > "$TESTSLOT_DIR/cap"
"$T" run --cpus 2 -- bash -c "sleep 7" >/dev/null 2>&1 &
h10=$!
nrun 1 || fail "10c: the holder never showed as running"
"$T" run --cpus 2 -- bash -c "date +%s.%N > $O/rc2" >/dev/null 2>&1 &
r10=$!
nwait 1 || fail "10c: the second run never showed as waiting"; sleep 1.2
[ ! -e "$O/rc2" ] || fail "10c: the second run started before the cap changed"
echo 4 > "$TESTSLOT_DIR/cap"; raised=$(stamp)
until_long '[ -e "$O/rc2" ]' || true
bwaitp $r10 || fail "10c: the second run did not end in 30s"
bwaitp $h10 || fail "10c: the holder did not end in 30s"
# admission is the run's recorded start (history "started"), not the command's first output: on Linux the command
# starts a moment later, behind a systemd scope
adm=$(python3 -c "
import json
for l in open('$TESTSLOT_DIR/history.jsonl'):
    r = json.loads(l)
    if 'rc2' in (r.get('command') or ''): print(r['started'])" | tail -1)
[ -n "$adm" ] && awk -v s="$raised" -v e="$adm" 'BEGIN{exit !(e - s < 3)}' \
  && ok "a cap raised while a run waits starts it within a few checks" || fail "a waiting run did not see the raised cap (admitted at '$adm', raised at $raised)"
wait

# 10d. A cap lowered while a run waits holds it to the lower cap. Cap 4: A and C (1 cpu each) run, B (3 cpus) queues and
# waits for cpus; the cap goes to 2. Old code starts B at once when A ends (1 + 3 <= 4); now B counts as 2 and waits for C.
echo 4 > "$TESTSLOT_DIR/cap"
"$T" run --cpus 1 -- bash -c "sleep 4" >/dev/null 2>&1 &
"$T" run --cpus 1 -- bash -c "date +%s.%N > $O/ldc; sleep 9; date +%s.%N > $O/ldce" >/dev/null 2>&1 &
nrun 2 || fail "10d: A and C never showed as running"
"$T" run --cpus 3 -- bash -c "date +%s.%N > $O/ldb" >/dev/null 2>&1 &
nwait 1 || fail "10d: B never showed as waiting"
echo 2 > "$TESTSLOT_DIR/cap"
wait
need ldc ldce ldb && awk -v e="$(cat "$O/ldce")" -v s="$(cat "$O/ldb")" 'BEGIN{exit !(s >= e - 0.05)}' \
  && ok "a lowered cap holds a waiting run, and the running run finishes untouched" || fail "a lowered cap: the waiting run started before the running one ended"

# 10e. A heavy run queued under a low cap gets the whole cap after a raise (it is stored as heavy, not as 2 cpus), and status
# counts it at the live cap. Cap 2: a 1-cpu run holds, a heavy run waits; cap 4, run ends: heavy shows 4 cpus.
echo 2 > "$TESTSLOT_DIR/cap"
"$T" run --cpus 1 -- bash -c "sleep 6" >/dev/null 2>&1 &
nrun 1 || fail "10e: the 1-cpu holder never showed as running"
"$T" run --heavy -- bash -c "sleep 3" >/dev/null 2>&1 &
nwait 1 || fail "10e: the heavy run never showed as waiting"
echo 4 > "$TESTSLOT_DIR/cap"
seen4=
for _ in $(seq 50); do "$T" status --json 2>/dev/null | python3 -c "import json,sys; w=json.load(sys.stdin)['waiting']; sys.exit(not (w and w[0]['cpus']==4))" && { seen4=1; break; }; sleep 0.1; done
[ -n "$seen4" ] || fail "10e: the waiting heavy run never showed cpus 4"
"$T" status --json > "$O/hsnap.json" 2>/dev/null
python3 -c "
import json; w=json.load(open('$O/hsnap.json'))['waiting']
raise SystemExit(0 if w and w[0]['cpus']==4 else 1)" \
  && ok "a queued heavy run is counted at the raised cap" || fail "a queued heavy run kept its old size"
wait

# 10f. The cap file empty for an instant (echo N > cap truncates first) does not reset the cap to 0.8 x cores.
echo 3 > "$TESTSLOT_DIR/cap"
: > "$TESTSLOT_DIR/cap"
python3 -c "
import importlib.machinery, importlib.util, os
os.environ.pop('TESTSLOT_CAP', None)
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load('$(cd "$(dirname "$T")" 2>/dev/null && pwd)/$(basename "$T")')
import time
open('$TESTSLOT_DIR/cap', 'w').write('3\n'); a = m.read_cap()
time.sleep(0.3)  # past the quarter-second reuse
open('$TESTSLOT_DIR/cap', 'w').write(''); b = m.read_cap()
raise SystemExit(0 if (a, b) == (3, 3) else 1)" 2>/dev/null \
  && ok "an empty cap file keeps the last good cap" || fail "an empty cap file reset the cap"
rm -f "$TESTSLOT_DIR/cap"; wait

# 11. Observed cpu. TESTSLOT_OBSERVED stands in for every run's reading and
# TESTSLOT_SAMPLE_S=0.5 (the floor) makes the wrapper read it every half second. Cap 10: A declares 4 and "uses" 8, so
# B (4 cpus) waits (8 + 4 > 10) although 4 + 4 would fit; when A's reading falls to 4, B starts.
echo 10 > "$TESTSLOT_DIR/cap"; echo 8 > "$O/obs"
export TESTSLOT_SAMPLE_S=0.5 TESTSLOT_OBSERVED=$O/obs
"$T" run --cpus 4 -- bash -c "sleep 40" >/dev/null 2>&1 &   # stopped at the end of 11d
until_true '"$T" status --json | python3 -c "import json,sys; r=json.load(sys.stdin)[\"running\"]; sys.exit(not (r and r[0][\"observed\"] == 8))"' \
  || fail "11: the running run's observed reading never reached status"
"$T" run --cpus 4 -- bash -c "date +%s.%N > $O/ob_b" >/dev/null 2>"$O/ob_b.err" &
until_true 'grep -q "cpus: 8 of 10 in use, this run needs 4" "$O/ob_b.err"' || fail "11: B never said it waits on 8 of 10"
# B has waited through at least two of its once-a-second checks, so a wrong admission would have shown by now
until_true '"$T" status --json | python3 -c "import json,sys; w=json.load(sys.stdin)[\"waiting\"]; sys.exit(not (w and w[0][\"wait_s\"] >= 2.5))"' \
  || fail "11: B never showed 2.5 s of waiting in status"
[ ! -e "$O/ob_b" ] && ok "a run declared at 4 that uses 8 holds a 4-cpu run back (8 + 4 > 10)" || fail "B started beside a run using 8 of 10"
"$T" status --json > "$O/ob.json"; "$T" status > "$O/ob.txt"
python3 - "$O/ob.json" <<'PY' && grep -q "4 cpus (using 8)" "$O/ob.txt" && ok "status shows declared and observed cpus, and charges the larger" || fail "status declared/observed fields"
import json, sys
s = json.load(open(sys.argv[1]))
a = s["running"][0]
assert (a["cpus"], a["observed"], a["charged"]) == (4, 8, 8), a
assert s["cpus_in_use"] == 8 and s["cpus_free"] == 2, s
PY
"$T" summary > "$O/ob-sum.txt" 2>&1; "$T" summary --json > "$O/ob-sum.json" 2>&1
grep -q "4 cpus (using 8)" "$O/ob-sum.txt" && python3 -c "
import json; r = json.load(open('$O/ob-sum.json'))['now']['running']
raise SystemExit(0 if r and (r[0]['cpus'], r[0]['observed'], r[0]['charged']) == (4, 8, 8) else 1)" \
  && ok "summary shows declared and observed cpus too, text and --json" || fail "summary declared/observed fields"
echo 4 > "$O/obs"
until_true '[ -e "$O/ob_b" ]' || fail "11: B never started after the reading fell to 4"
[ -e "$O/ob_b" ] && ok "the waiting run starts once the observed reading falls" || fail "B stayed waiting"

# 11d. A failed read: the reading goes bad (the hook file holds text), the wrapper records no reading, and the run
# is charged what it declared again.
echo 8 > "$O/obs"
until_true '"$T" status --json | python3 -c "import json,sys; r=json.load(sys.stdin)[\"running\"]; sys.exit(not (r and r[0][\"observed\"] == 8 and r[0][\"charged\"] == 8))"' \
  || fail "11d: the reading never came back to 8"
echo "not a number" > "$O/obs"
until_true '"$T" status --json | python3 -c "import json,sys; r=json.load(sys.stdin)[\"running\"]; sys.exit(not (r and r[0][\"observed\"] is None and r[0][\"charged\"] == 4))"' \
  && ok "a failed read clears the reading: the run is charged what it declared" || fail "11d: a failed read left the last reading charged"
unset TESTSLOT_OBSERVED; rm -f "$O/obs" "$TESTSLOT_DIR/cap"
"$T" stop "$(pgid_of light)" >/dev/null 2>&1; wait

# 11e. TESTSLOT_SAMPLE_S is clamped: 0 and 0.1 go to the 0.5 floor, inf and text to the default 3, 1e308 to 3600; and a run
# started with inf (which would otherwise kill the sampler with a traceback) runs clean.
TP=$(command -v "$T")
for v in 0 0.1 inf nan abc 1e308 7; do
  printf '%s ' "$v"; TESTSLOT_SAMPLE_S=$v python3 -c "
import importlib.machinery, importlib.util
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load('$TP')
print(m.SAMPLE_S)" 2>/dev/null
done > "$O/sample.txt"
[ "$(tr '\n' ' ' < "$O/sample.txt")" = "0 0.5 0.1 0.5 inf 3.0 nan 3.0 abc 3.0 1e308 3600.0 7 7.0 " ] \
  && ok "TESTSLOT_SAMPLE_S is clamped: a floor of 0.5, a ceiling of 3600, 3 for anything not a finite number" || fail "TESTSLOT_SAMPLE_S clamp: $(tr '\n' ' ' < "$O/sample.txt")"
TESTSLOT_SAMPLE_S=inf "$T" run --cpus 1 -- sleep 1.5 >/dev/null 2>"$O/inf.err"; c=$?
[ $c = 0 ] && ! grep -q Traceback "$O/inf.err" && ok "a run with TESTSLOT_SAMPLE_S=inf runs clean" || fail "TESTSLOT_SAMPLE_S=inf: exit $c, $(grep -c Traceback "$O/inf.err") traceback(s)"

# 11b. The real sampler: two busy processes in one run show up as more than one core (the group's cpu time, not ps %cpu),
# and no holder file is left behind afterwards.
export TESTSLOT_SAMPLE_S=0.5
"$T" run --cpus 1 -- bash -c ": $TESTSLOT_DIR; for i in 1 2; do (while :; do :; done) & done; sleep 7" >/dev/null 2>&1 &   # the marker lets the exit trap find the loops
until_true '"$T" status --json | python3 -c "import json,sys; r=json.load(sys.stdin)[\"running\"]; sys.exit(not (r and (r[0][\"observed\"] or 0) >= 1.0))"' \
  && ok "the sampler sees two busy processes as at least one core" || fail "11b: no observed reading of 1 core or more from two busy loops"
wait
[ -z "$(ls "$TESTSLOT_DIR/holders" 2>/dev/null)" ] && ok "the sampler leaves no holder record behind" || fail "11b: a holder record is left: $(ls "$TESTSLOT_DIR/holders")"
unset TESTSLOT_SAMPLE_S

# 11c. What a holder costs the cap, one check per kind of reading, so each fails on the old function for its own reason:
# no usable reading (none, text, True, negative, NaN, inf, huge) costs what it declared; a usable one is the larger of
# the two, held to the cap; an orphan's reading is stale; a heavy run is the whole cap. (Cap 10, set for this
# check alone: the suite's own cap of 2 would clamp the declared 4.)
TESTSLOT_CAP=10 python3 -c "
import importlib.machinery, importlib.util
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load('$TP')
h = {'kind': 'light', 'cpus': 4}
c = lambda **kw: m.charged_cpus(dict(h, **kw))
checks = [
  ('no reading is charged what it declared', c() == 4),
  ('text, a bool and a list are charged what they declared', c(observed='x') == 4 and c(observed=True) == 4 and c(observed=[8]) == 4),
  ('a negative reading is charged what it declared', c(observed=-1) == 4 and c(observed=-0.5) == 4),
  ('NaN is charged what it declared', c(observed=float('nan')) == 4),
  ('inf is charged what it declared', c(observed=float('inf')) == 4 and c(observed=float('-inf')) == 4),
  ('a huge reading (1e9) is charged what it declared', c(observed=1e9) == 4),
  ('a reading over the declared size is charged as read', c(observed=8.5) == 8.5),
  ('a reading under the declared size is charged what it declared', c(observed=2) == 4),
  ('a reading over the cap is held to the cap', c(observed=14) == 10),
  ('an orphan is charged what it declared', c(observed=8, orphan=True) == 4),
  ('a heavy run is the whole cap', m.charged_cpus({'kind': 'heavy', 'observed': 3}) == 10),
]
v = getattr(m, 'valid_observed', None)
if v:
    checks.append(('valid_observed refuses what charged_cpus refuses', all(v(dict(h, observed=x)) is None for x in (None, 'x', True, -1, float('nan'), float('inf'), 1e9)) and v(dict(h, observed=8)) == 8.0))
for name, good in checks:
    print(('PASS ' if good else 'FAIL ') + 'charged_cpus: ' + name)" 2>/dev/null > "$O/charged.txt"
[ -s "$O/charged.txt" ] || fail "charged_cpus: the check did not run"
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "$rest" || fail "$rest"; done < "$O/charged.txt"

# 11f. Idle shrink. charged_cpus: a run counted by cgroup whose wrapper has seen it under its size
# for the shrink time (`shrunk` in its record) is charged observed + margin, never above what it declared and never under 1;
# a process-group reading, an orphan's, one that has climbed back, or a record without the flag is charged as before.
# Cap 10, margin 1 (the default).
cat > "$O/shrink_unit.py" <<'PY'
import importlib.machinery, importlib.util, sys, time
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load(sys.argv[1])
h = {'kind': 'light', 'cpus': 4, 'observed': 0.1, 'observed_via': 'cgroup', 'shrunk': True, 'sampled_at': time.time(), 'sample_s': 3}
c = lambda **kw: round(m.charged_cpus(dict(h, **kw)), 3)
def with_margin(v, f):
    old, m.SHRINK_MARGIN = m.SHRINK_MARGIN, v
    try:
        return f()
    finally:
        m.SHRINK_MARGIN = old
checks = [
  ('a shrunk 4-cpu run at 0.1 is charged 1.1', c() == 1.1),
  ('with a margin of 2 (this process) the same run is charged 2.1, and 4 at most', with_margin(2.0, lambda: c() == 2.1 and c(observed=3) == 4)),
  ('a shrunk run is never charged above what it declared (3.8 + 1 -> 4)', c(observed=3.8) == 4),
  ('a shrunk run is never charged under 1', c(observed=0) == 1 and c(cpus=1) == 1),
  ('a process-group reading is never shrunk', c(observed_via='group') == 4 and c(observed_via=None) == 4),
  ('a record without the flag is charged what it declared', c(shrunk=False) == 4 and c(shrunk=None) == 4 and c(shrunk='yes') == 4),
  ('a reading that has climbed back to the size is charged in full at once', c(observed=4) == 4 and c(observed=6.5) == 6.5),
  ('an orphan is charged what it declared', c(orphan=True) == 4),
  ('a bad reading is charged what it declared', c(observed=float('nan')) == 4 and c(observed=-1) == 4 and c(observed='x') == 4),
  ('an 8-cpu run: shrunk at 0.1 -> 1.1, at 2.0 -> 3 (it follows the reading), at 8 -> 8 (back to its declaration)',
     m.charged_cpus(dict(h, cpus=8)) == 1.1 and c(cpus=8, observed=2.0) == 3 and c(cpus=8, observed=8) == 8),
  ('a record not rewritten for over 4 sample intervals + 1 s (a dead sampler) is charged in full',
     c(sampled_at=time.time() - 14) == 4 and c(sampled_at=time.time() - 5) == 1.1 and c(sampled_at=None) == 4 and c(sampled_at='x') == 4
     and c(sampled_at=time.time() - 3, sample_s=0.5) == 4 and c(sampled_at=time.time() - 1, sample_s=0.5) == 1.1),
  ('a track run is never shrunk', c(kind='track', cpus=0) == 0.1 and c(kind='track', cpus=0, shrunk=False) == 0.1),
  ('a heavy run flagged shrunk is still the whole cap', m.charged_cpus({'kind': 'heavy', 'observed': 0.1, 'observed_via': 'cgroup', 'shrunk': True, 'sampled_at': time.time(), 'sample_s': 3}) == 10),
  ('the margin comes from the record, else this process: record 2 -> 2.1, none -> 1.1, a bad one -> 1.1', c(shrink_margin=2) == 2.1 and c() == 1.1 and c(shrink_margin='x') == 1.1 and c(shrink_margin=-3) == 1.1 and c(shrink_margin=True) == 1.1),
  ('a record\'s sample_s counts for at most 4 x this process\'s interval (3 s): 3600 s is cut to 12 s + 1', c(sample_s=3600, sampled_at=time.time() - 60) == 4 and c(sample_s=3600, sampled_at=time.time() - 5) == 1.1),
  ('status prints N from the record when it is a usable number, else this process\'s',
     [m.job(dict(h, pid=1, queued=1.0, state='running', account='a', repo='r', command='c', shrink_after=x), 2.0)['shrink_after'] for x in (45, 45.5, 'x', None, float('nan'), float('inf'), True, 0, -5, 1e9, [3])]
     == [45.0, 45.5] + [m.SHRINK_AFTER_S] * 9),
  ('a garbage shrink_after in a record cannot break the status text', all(isinstance(m.seen_text(m.job(dict(h, pid=1, queued=1.0, state='running', account='a', repo='r', command='c', shrink_after=x), 2.0)), str) for x in ('x', float('nan'), float('inf'), [1], {}))),
  ('status marks the shrunk charge', m.job(dict(h, pid=1, queued=1.0, state='running', account='a', repo='r', command='c'), 2.0).get('shrunk') is True),
]
for name, good in checks:
    print(('PASS ' if good else 'FAIL ') + 'idle shrink: ' + name)
PY
TESTSLOT_CAP=10 python3 "$O/shrink_unit.py" "$TP" 2>"$O/shrink_unit.err" > "$O/shrink.txt"
[ -s "$O/shrink.txt" ] || { fail "idle shrink: the unit check did not run"; sed 's/^/     /' "$O/shrink_unit.err"; }
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "$rest" || fail "$rest"; done < "$O/shrink.txt"
# the shrink time and the margin are set like the reserve ($DIR file, else env var), validated and clamped
cat > "$O/shrink_cfg.py" <<'PY'
import importlib.machinery, importlib.util, sys
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load(sys.argv[1])
print(getattr(m, 'SHRINK_AFTER_S', None), getattr(m, 'SHRINK_MARGIN', None))
PY
cfg() { TESTSLOT_SHRINK_AFTER=$1 TESTSLOT_SHRINK_MARGIN=$2 python3 "$O/shrink_cfg.py" "$TP" 2>/dev/null; }
cfgd=$(mktemp -d /tmp/testslot-test.XXXXXX)
got=$(for a in "" 30 abc nan inf 0 -5 1e9; do printf '%s;' "$(TESTSLOT_DIR=$cfgd cfg "$a" 1)"; done)
[ "$got" = "600.0 1.0;30.0 1.0;600.0 1.0;600.0 1.0;600.0 1.0;1.0 1.0;1.0 1.0;86400.0 1.0;" ] \
  && ok "the shrink time is validated and clamped: garbage and non-finite -> 600 s, 0 and negatives -> 1 s, huge -> a day" || fail "shrink time config: $got"
got=$(for g in "" 2 abc nan inf -1 1e9; do printf '%s;' "$(TESTSLOT_DIR=$cfgd cfg 30 "$g")"; done)
[ "$got" = "30.0 1.0;30.0 2.0;30.0 1.0;30.0 1.0;30.0 1.0;30.0 0.0;30.0 64.0;" ] \
  && ok "the margin is validated and clamped: garbage and non-finite -> 1, negatives -> 0, huge -> 64" || fail "shrink margin config: $got"
echo 45 > "$cfgd/shrink-after"; echo 2.5 > "$cfgd/shrink-margin"
got="$(TESTSLOT_DIR=$cfgd cfg 30 3);"; echo junk > "$cfgd/shrink-after"; echo nan > "$cfgd/shrink-margin"
got="$got $(TESTSLOT_DIR=$cfgd cfg 20 3)"
[ "$got" = "45.0 2.5; 20.0 3.0" ] && ok "the \$DIR files win over the env vars, and a garbage file falls through to the env var" || fail "shrink config files: $got"
rm -rf "$cfgd"
# End to end, with faked readings (TESTSLOT_OBSERVED_VIA=cgroup records them as a cgroup's): cap 10, shrink after 6 s.
# A is an 8-cpu holder that "uses" 0.1 and B a 4-cpu waiter (a 4-cpu holder with a 4-cpu waiter would fit the cap and never
# wait), so B waits at first (8 + 4 > 10); once A has sat under its size for 6 s it is charged 1.1, status says so, and B
# starts. A's reading then climbs back to its declaration, 8: charged in full on the next check, and when it falls again
# the clock starts over, so the charge stays full at the first reading of 0.1. (The literal "4-cpu run at 0.1" is the unit case.)
echo 10 > "$TESTSLOT_DIR/cap"; echo 0.1 > "$O/obs"; rm -f "$O/sh_b"
export TESTSLOT_SAMPLE_S=0.5 TESTSLOT_OBSERVED=$O/obs TESTSLOT_OBSERVED_VIA=cgroup TESTSLOT_SHRINK_AFTER=6
"$T" run --cpus 8 -- bash -c ": $TESTSLOT_DIR; sleep 60" >/dev/null 2>&1 &
until_true '"$T" status --json | python3 -c "import json,sys; r=json.load(sys.stdin)[\"running\"]; sys.exit(not (r and r[0][\"observed\"] == 0.1))"' \
  || fail "11f: the reading never reached status"
"$T" run --cpus 4 -- bash -c ": $TESTSLOT_DIR; date +%s.%N > $O/sh_b" >/dev/null 2>"$O/sh_b.err" &
until_true 'grep -q "cpus: 8 of 10 in use, this run needs 4" "$O/sh_b.err"' || fail "11f: B never said it waits on 8 of 10"
[ ! -e "$O/sh_b" ] && ok "a 4-cpu run waits behind an 8-cpu run that has not yet sat idle long enough" || fail "11f: B started before the shrink time"
for _ in $(seq 150); do [ -e "$O/sh_b" ] && break; sleep 0.2; done
[ -e "$O/sh_b" ] && ok "a waiting run starts once the idle run is charged observed + margin" || fail "11f: B never started (30 s)"
"$T" status --json > "$O/sh.json"; "$T" status > "$O/sh.txt"
python3 - "$O/sh.json" <<'PY' && grep -q "charged 1.1 of 8" "$O/sh.txt" && ok "status shows the shrunk charge (json and text)" || fail "11f: status does not show the shrunk charge"
import json, sys
s = json.load(open(sys.argv[1]))
a = next(j for j in s["running"] if j["cpus"] == 8)
assert (a["observed"], a["charged"], a["shrunk"]) == (0.1, 1.1, True), a
PY
echo 8 > "$O/obs"
until_true '"$T" status --json | python3 -c "import json,sys; r=[j for j in json.load(sys.stdin)[\"running\"] if j[\"cpus\"] == 8]; sys.exit(not (r and r[0][\"observed\"] == 8 and r[0][\"charged\"] == 8 and not r[0][\"shrunk\"]))"' \
  && ok "a run whose reading climbs back is charged its full size again" || fail "11f: the charge stayed shrunk after the reading climbed back"
echo 0.1 > "$O/obs"
until_true '"$T" status --json | python3 -c "import json,sys; r=[j for j in json.load(sys.stdin)[\"running\"] if j[\"cpus\"] == 8]; sys.exit(not (r and r[0][\"observed\"] == 0.1))"' || fail "11f: the low reading never came back"
"$T" status --json | python3 -c "import json,sys; r=[j for j in json.load(sys.stdin)['running'] if j['cpus'] == 8]; sys.exit(not (r and r[0]['observed'] == 0.1 and r[0]['charged'] == 8))" \
  && ok "after a climb the idle clock starts over: the first low reading is charged in full" || fail "11f: the shrink came back at once"
"$T" stop "$(pgid_of light)" >/dev/null 2>&1; wait
# A reading counted by process group (no TESTSLOT_OBSERVED_VIA, scope off) is never shrunk, however long it stays low.
unset TESTSLOT_OBSERVED_VIA; export TESTSLOT_NO_CGROUP=1 TESTSLOT_SHRINK_AFTER=1
"$T" run --cpus 8 -- bash -c ": $TESTSLOT_DIR; sleep 60" >/dev/null 2>&1 &
until_long2() { for _ in $(seq 150); do eval "$1" && return 0; sleep 0.2; done; echo "     (timed out after 30s waiting for: $1)"; return 1; }
until_long2 '"$T" status --json | python3 -c "import json,sys; r=json.load(sys.stdin)[\"running\"]; sys.exit(not (r and r[0][\"observed\"] == 0.1 and r[0][\"run_s\"] >= 4))"' \
  && ok "a run counted by process group stays at its full size after 4 s under a 1 s shrink time" || fail "11f: no group-counted run reached 4 s"
"$T" status --json | python3 -c "import json,sys; r=json.load(sys.stdin)['running']; sys.exit(not (r and r[0]['observed_via'] == 'group' and r[0]['charged'] == 8 and not r[0]['shrunk']))" \
  && ok "a process-group reading is never shrunk" || fail "11f: a group-counted run was shrunk"
"$T" stop "$(pgid_of light)" >/dev/null 2>&1; wait
# A non-default margin changes the charge: margin 2 on the 8-cpu run at 0.1 is 2.1, read by status from the record
# (this status process has the default margin), and status prints N as that run's wrapper read it.
unset TESTSLOT_NO_CGROUP; export TESTSLOT_OBSERVED_VIA=cgroup
TESTSLOT_SHRINK_MARGIN=2 TESTSLOT_SHRINK_AFTER=1 "$T" run --cpus 8 -- bash -c ": $TESTSLOT_DIR; sleep 60" >/dev/null 2>&1 &
until_long2 '"$T" status --json | python3 -c "import json,sys; r=json.load(sys.stdin)[\"running\"]; sys.exit(not (r and r[0][\"charged\"] == 2.1 and r[0][\"shrunk\"] and r[0][\"shrink_after\"] == 1))"' \
  && ok "a margin of 2 charges the idle 8-cpu run 2.1, and the record carries N and the margin" || fail "11f: margin 2 did not give 2.1"
"$T" status | grep -q "charged 2.1 of 8: under its size for 0m01s or more" \
  && ok "status prints the run's own N" || fail "11f: status did not print the run's N"
"$T" stop "$(pgid_of light)" >/dev/null 2>&1; wait
unset TESTSLOT_OBSERVED TESTSLOT_OBSERVED_VIA TESTSLOT_SHRINK_AFTER TESTSLOT_SAMPLE_S; rm -f "$O/obs" "$TESTSLOT_DIR/cap"
# why_wait with numbers reported from a real queue: cap 20, load-cap 10, one 8-cpu holder (12 of 20 free),
# load 7.5. A 4-cpu head fits the cpus but not the load (7.5 + 4 > 10), so it waits on the load; runs of 1 and 2 cpus fit it
# (8.5, 9.5), 3 does not (10.5), and on an idle slot (no holder) the 4-cpu head starts.
vd=$(mktemp -d /tmp/testslot-test.XXXXXX); mkdir -p "$vd/holders"; echo "7.5 7.5 7.5 1/100 1" > "$vd/loadavg"
TESTSLOT_DIR=$vd TESTSLOT_CAP=20 TESTSLOT_LOAD_CAP=10 TESTSLOT_LOADAVG=$vd/loadavg python3 - "$TP" > "$O/why.txt" 2>"$O/why.err" <<'PY'
import importlib.machinery, importlib.util, sys
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load(sys.argv[1])
hold = [{'pid': 4242, 'state': 'running', 'kind': 'light', 'cpus': 8}]
w = lambda hs, n: m.why_wait(hs, 1, 100.0, n)
msg = w(hold, 4)
import os, time
set_load = lambda v: open(os.environ['TESTSLOT_LOADAVG'], 'w').write(v + ' 7.5 7.5 1/100 1\n') and None
head = lambda age: {'pid': 4243, 'state': 'waiting', 'kind': 'light', 'cpus': 4, 'queued': time.time() - age}
big = lambda hs: m.why_wait(hs, 1, time.time(), 1)   # a 1-cpu run queued behind the head, no time limit
bigl = lambda hs: m.why_wait(hs, 1, time.time(), 1, 300)   # the same run with a 5 minute limit: only a limited run passes a head
rsv = lambda hs: (big(hs) or '').startswith('cpus are reserved for the run at the head')
for name, good in [
  ('a 4-cpu head queued 700 s ago (past the 600 s reserve) holds no reservation: the load holds it, so smaller runs backfill', not rsv(hold + [head(700)]) and bigl(hold + [head(700)]) is None),
  ('and the head itself still waits on the load', bool(m.why_wait(hold + [head(700)], 4243, time.time() - 700, 4))),
  ('the reservation comes only past 6 x the reserve time (3600 s): at 3500 s none, at 3700 s cpus are reserved', not rsv(hold + [head(3500)]) and rsv(hold + [head(3700)])),
  ('a head the load does not hold back (load 1.0) reserves cpus after 600 s: queued 700 s ago it is reserved', set_load('1.0') or rsv(hold + [head(700)])),
  ('and back at load 7.5 it is not', set_load('7.5') or not rsv(hold + [head(700)])),
  ('a 4-cpu head waits on the load at 7.5 with 12 of 20 cpus free', bool(msg) and msg.startswith('load: 7.5 now, this run needs 4, load cap 10')),
  ('a 3-cpu run waits on the load too (10.5 > 10)', bool(w(hold, 3)) and w(hold, 3).startswith('load:')),
  ('a 2-cpu run starts (9.5 <= 10)', w(hold, 2) is None),
  ('a 1-cpu run starts', w(hold, 1) is None),
  ('the 4-cpu head starts on an idle slot, with the load at 7.5', w([], 4) is None),
]:
    print(('PASS ' if good else 'FAIL ') + 'why_wait at load 7.5: ' + name)
PY
[ -s "$O/why.txt" ] || { fail "why_wait at load 7.5: the check did not run"; sed 's/^/     /' "$O/why.err"; }
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "$rest" || fail "$rest"; done < "$O/why.txt"
rm -rf "$vd"

# 12. Peak and suggest. TESTSLOT_OBSERVED fakes the reading, as in case 11; each run lasts
# 2 s, so the sampler (every 0.5 s, the floor) reads it a few times. Keys below are unique to this case.
export TESTSLOT_SAMPLE_S=0.5 TESTSLOT_OBSERVED=$O/pobs
suggested() { "$T" suggest "$@" 2>&1; }
none=$(suggested --key pk/j4/none)
[ -z "$none" ] && [ "$(suggested --key pk/j4/none --default 3)" = 3 ] && ok "suggest prints nothing without data, or the default asked for" || fail "suggest with no data printed '$none'"
echo 5.4 > "$O/pobs"
"$T" run --cpus 1 --key pk/j4/a,b -- sleep 2 >/dev/null 2>&1
r=$(suggested --key pk/j4/a,b)
[ "$r" = 6 ] && ok "the second run is offered the first's peak (5.4 cores, as a whole 6)" || fail "suggest after a run at 5.4 printed '$r'"
python3 -c "
import json
rows = [json.loads(l) for l in open('$TESTSLOT_DIR/history.jsonl') if '\"pk/j4/a,b\"' in l]
raise SystemExit(0 if rows and rows[-1]['key'] == 'pk/j4/a,b' and rows[-1]['peak'] == 5.4 else 1)" \
  && ok "the history line carries the run's key and peak" || fail "the history line has no key and peak"
echo 3 > "$O/pobs"
"$T" run --cpus 1 --key pk/j4/a,b -- sleep 2 >/dev/null 2>&1
r=$(suggested --key pk/j4/a,b)
[ "$r" = 3 ] && ok "the latest run's peak is the one offered" || fail "suggest after a later run at 3 printed '$r'"
echo "not a number" > "$O/pobs"
"$T" run --cpus 1 --key pk/j4/a,b -- sleep 2 >/dev/null 2>&1
r=$(suggested --key pk/j4/a,b)
[ "$r" = 3 ] && ok "a run with no usable reading is ignored" || fail "a run with no reading changed the suggestion to '$r'"
# no --key: the command with its paths and long hex or number tokens taken out is the key
echo 7 > "$O/pobs"
"$T" run --cpus 1 -- bash -c "sleep 2" /tmp/aaa1111111/tree/t.sh --log /tmp/one/x.log >/dev/null 2>&1
r=$(suggested -- bash -c "sleep 2" /tmp/zzz3333333/other/t.sh --log /tmp/two/y.log)
[ "$r" = 7 ] && ok "a command with no key is matched without its paths and log argument" || fail "derived key: suggest printed '$r'"
r=$(suggested -- bash -c "sleep 3" /tmp/zzz3333333/other/t.sh)
[ -z "$r" ] && ok "a different command is not matched" || fail "a different command was offered '$r'"
# a key of any length: past 200 characters it is stored as a hash
long=$(python3 -c "print('pk/j4/' + ','.join('test_module_%d' % i for i in range(40)))")
echo 4 > "$O/pobs"
"$T" run --cpus 1 --key "$long" -- sleep 2 >/dev/null 2>&1
r=$(suggested --key "$long")
[ "${#long}" -gt 200 ] && [ "$r" = 4 ] && grep -q '"key": "sha256:' "$TESTSLOT_DIR/history.jsonl" && ok "a long key works and is stored as a hash" || fail "long key: suggest printed '$r'"
# a track run's reading is an API wait and a heavy run's is the whole box: neither is recorded or offered, even under
# the same key as a light run
echo 8 > "$O/pobs"
"$T" run --track --key pk/j4/kind -- sleep 2 >/dev/null 2>&1
"$T" run --heavy --key pk/j4/kind -- sleep 2 >/dev/null 2>&1
r=$(suggested --key pk/j4/kind)
[ -z "$r" ] && ok "track and heavy runs are not offered as a peak" || fail "a track or heavy run was offered '$r'"
echo 2 > "$O/pobs"
"$T" run --cpus 1 --key pk/j4/kind -- sleep 2 >/dev/null 2>&1
echo 8 > "$O/pobs"
"$T" run --track --key pk/j4/kind -- sleep 2 >/dev/null 2>&1
r=$(suggested --key pk/j4/kind)
[ "$r" = 2 ] && ok "a later track run doesn't replace a light run's peak" || fail "after a track run suggest printed '$r', not 2"
# history lines from before (no key, no peak) still parse: summary reads them, suggest skips them
printf '{"pid": 1, "kind": "light", "cpus": 1, "queued": 1, "started": 2, "ended": %s, "exit": 0, "run_s": 1}\n' "$(date +%s)" >> "$TESTSLOT_DIR/history.jsonl"
"$T" summary >/dev/null 2>&1; c=$?; r=$(suggested --key pk/j4/a,b)
[ $c = 0 ] && [ "$r" = 3 ] && ok "a history line with no key or peak is read and skipped" || fail "old history line: summary exit $c, suggest '$r'"
printf '{"key": "pk/j4/a,b", "peak": 9, "ended": "x"}\n{"key": "pk/j4/a,b", "peak": 9, "ended": true}\n' >> "$TESTSLOT_DIR/history.jsonl"
"$T" summary >/dev/null 2>&1; c=$?; r=$(suggested --key pk/j4/a,b)
[ $c = 0 ] && [ "$r" = 3 ] && ok "a history line with a non-numeric ended is skipped and spoils nothing" || fail "bad ended line: summary exit $c, suggest '$r'"
"$T" suggest >/dev/null 2>&1; c=$?
[ $c != 0 ] && ok "suggest with no key and no command is a usage error" || fail "suggest with no arguments exited 0"
unset TESTSLOT_OBSERVED TESTSLOT_SAMPLE_S; rm -f "$O/pobs"

# 20. Observed cpu by cgroup. Linux only: each command runs in its own systemd user scope, so
# a child that calls setsid and exits within a second still counts. Test hooks: TESTSLOT_NO_CGROUP=1 forces the
# process-group path, TESTSLOT_CGROUP_ROOT points the cgroup root at a folder of the test's own, TESTSLOT_LAUNCH_S
# shortens the wait for a launcher. Children are named "sleep 6NN.$$" (600-609 children and the harmless group, 610-619
# leaders), so a pattern anchored at "^sleep" finds a child alone, not the bash -c that carries its name.
# Not covered (a known window, stated in the done note): stopping the wrapper before the pgid exists; the start now
# includes starting a scope, so that window is wider than before, and stop has no pgid to name in it.
export TESTSLOT_SAMPLE_S=0.5
cg_ok() { linux && systemd-run --user --scope --quiet --collect true >/dev/null 2>&1; }
# a field of the first running job, or nothing
# the background run ($bp, the pid of the last one started) lasts a few seconds: wait for it, but never for ever
bwait() { bwaitp "$bp"; }
# like until_true but 15s: a loaded box can be slow to start a scope
until_long() { for _ in $(seq 150); do eval "$1" && return 0; sleep 0.1; done; echo "     (timed out after 15s waiting for: $1)"; return 1; }
jfield() { "$T" status --json | python3 -c "import json,sys; r=json.load(sys.stdin)['running']; v = r[0].get(sys.argv[1]) if r else None; print('' if v is None else v)" "$1"; }
# the pgid of the running job whose command contains $1
jpg() { "$T" status --json | python3 -c "import json,sys; print(next((r['pgid'] for r in json.load(sys.stdin)['running'] if sys.argv[1] in (r.get('command') or '')), ''))" "$1"; }
# forge SRC_PGID NEW_PGID NAME [orphan]: a copy of the holder record with pgid SRC, naming pgid NEW, queued first
forge() { python3 - "$TESTSLOT_DIR" "$1" "$2" "$3" "${4:-}" <<'PY'
import glob, json, sys
d, src, new, name, orphan = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
for f in glob.glob(d + "/holders/*.json"):
    h = json.load(open(f))
    if h.get("pgid") == src:
        h.update(pgid=new, queued=0)
        if orphan:
            h["orphan"] = True
        json.dump(h, open(d + "/holders/" + name + ".json", "w"))
PY
}
# the history line of the last run under key $1, a field: cpu_s
hist_of() { python3 -c "
import json,sys
r=[json.loads(l) for l in open('$TESTSLOT_DIR/history.jsonl') if json.loads(l).get('key')==sys.argv[1]]
v = r[-1].get(sys.argv[2]) if r else None
print('' if v is None else v)" "$1" "$2"; }
if linux; then
  # 20b. The fallback: with no scope the process-group path counts, and status says so (a field, and the text).
  TESTSLOT_NO_CGROUP=1 "$T" run --cpus 1 -- sleep 3 >/dev/null 2>&1 &
  bp=$!
  until_long '[ -n "$(jfield pgid)" ]' || fail "20b: the fallback run never showed as running"
  [ "$(jfield observed_via)" = group ] && [ -n "$(jfield cgroup_note)" ] && ok "a forced fallback is counted by group, and status json says why" || fail "20b: observed_via '$(jfield observed_via)', note '$(jfield cgroup_note)'"
  "$T" status | grep -q "counted by process group, not cgroup" && ok "status text names the fallback" || fail "20b: status text does not name the fallback"
  bwait || fail "20b: the run did not end in 30s"
  # 20m-v1. A host without cgroup v2 (a root with no cgroup.controllers) falls back, saying so.
  mkdir -p "$O/cg0"
  TESTSLOT_CGROUP_ROOT="$O/cg0" "$T" run --cpus 1 -- sleep 3 >/dev/null 2>&1 &
  bp=$!
  until_long '[ -n "$(jfield pgid)" ]' || fail "20m: the v1 run never showed as running"
  [ "$(jfield observed_via)" = group ] && [ "$(jfield cgroup_note)" = "no cgroup v2 here" ] && ok "a host without cgroup v2 falls back, saying so" || fail "20m: v1 observed_via '$(jfield observed_via)', note '$(jfield cgroup_note)'"
  bwait || fail "20m: the v1 run did not end in 30s"
  # 20j. A systemd-run that fails (a shim that exits 1, as a bus hiccup would make it): the command never ran, so it runs
  # once, by group, with the reason in status. A failed launch must not fail the caller's run.
  mkdir -p "$O/shim"; printf '#!/bin/sh\nexit 1\n' > "$O/shim/systemd-run"; chmod +x "$O/shim/systemd-run"
  rm -f "$O/l.out"
  PATH="$O/shim:$PATH" "$T" run --cpus 1 -- bash -c "echo x >> $O/l.out; sleep 3" >/dev/null 2>&1 &
  bp=$!
  until_long '[ -n "$(jfield pgid)" ]' || fail "20j: the run behind a failing systemd-run never showed as running"
  [ "$(jfield observed_via)" = group ] && case "$(jfield cgroup_note)" in *"failed to start"*) true ;; *) false ;; esac && ok "a failed launch is rerun by group with a note ($(jfield cgroup_note))" || fail "20j: observed_via '$(jfield observed_via)', note '$(jfield cgroup_note)'"
  bwait || fail "20j: the run did not end in 30s"
  [ "$(wc -l < "$O/l.out" | tr -d ' ')" = 1 ] && ok "the command ran exactly once after a failed launch" || fail "20j: the command ran $(wc -l < "$O/l.out" 2>/dev/null) times"
  # 20r. A launcher that stays alive and never starts the command: after TESTSLOT_LAUNCH_S the launcher is stopped, the
  # command runs once by group, and nothing of the launcher is left. The wait is bounded (the slot is not held for ever).
  printf '#!/bin/sh\nexec sleep 619.%s\n' "$$" > "$O/shim/systemd-run"
  rm -f "$O/r.out"
  TESTSLOT_LAUNCH_S=1 PATH="$O/shim:$PATH" "$T" run --cpus 1 -- bash -c "echo x >> $O/r.out; sleep 2" >/dev/null 2>&1 &
  bp=$!
  until_long '[ -n "$(jfield pgid)" ]' || fail "20r: the run behind a stuck launcher never showed as running"
  case "$(jfield cgroup_note)" in *"did not start the command in 1 s"*) ok "a stuck launcher is stopped after the launch bound, with a note" ;; *) fail "20r: note '$(jfield cgroup_note)'" ;; esac
  bwait || fail "20r: the run did not end in 30s"
  [ "$(wc -l < "$O/r.out" | tr -d ' ')" = 1 ] && ok "the command ran exactly once after a stuck launcher" || fail "20r: the command ran $(wc -l < "$O/r.out" 2>/dev/null) times"
  pgrep -f "^sleep 619\\.$$" >/dev/null && fail "20r: the stuck launcher was left running" || ok "the stuck launcher was stopped"
  rm -f "$O/shim/systemd-run"
  if cg_ok; then
    # 20a. Four children, each setsid, each burn 0.5 cpu-seconds and exit inside about a second. The run's recorded cpu
    # (history cpu_s) matches what they used (each writes its own process_time). The old group path saw none of them.
    printf 'import sys, time\nwhile time.process_time() < 0.5: pass\nopen(sys.argv[1], "w").write(str(time.process_time()))\n' > "$O/burn.py"
    rm -f "$O"/burn.[1-4]
    "$T" run --cpus 1 --key cg/burst -- bash -c 'for i in 1 2 3 4; do setsid python3 "$0" "$1/burn.$i" & done; sleep 3' "$O/burn.py" "$O" >/dev/null 2>&1
    used=$(python3 -c "
import glob
print(round(sum(float(open(f).read()) for f in glob.glob('$O/burn.[1-4]')), 2))")
    got=$(hist_of cg/burst cpu_s)
    [ -n "$got" ] && awk -v u="$used" -v g="$got" 'BEGIN{exit !(u >= 1.9 && g >= 0.8 * u)}' && ok "short-lived setsid children are counted: cpu_s $got of $used used" || fail "20a: history cpu_s '$got' for $used cpu-seconds of setsid burners"
    # 20c. status says it counts by cgroup, with no fallback note.
    "$T" run --cpus 1 -- sleep 3 >/dev/null 2>&1 &
    bp=$!
    until_long '[ -n "$(jfield pgid)" ]' || fail "20c: the run never showed as running"
    [ "$(jfield observed_via)" = cgroup ] && [ -z "$(jfield cgroup_note)" ] && ok "status json says the run is counted by cgroup" || fail "20c: observed_via '$(jfield observed_via)', note '$(jfield cgroup_note)'"
    bwait || fail "20c: the run did not end in 30s"
    # 20d. stop ends a setsid child too, and its scope is gone.
    "$T" run --cpus 1 -- bash -c "setsid sleep 600.$$ & sleep 610.$$" >/dev/null 2>&1 &
    bp=$!
    until_long '[ -n "$(jfield pgid)" ] && pgrep -f "^sleep 600\\.$$" >/dev/null && pgrep -f "^sleep 610\\.$$" >/dev/null' || fail "20d: the run and its setsid child never both showed"
    sc=$(jfield cgroup); pg=$(jfield pgid)
    [ -d "$sc" ] || fail "20d: no scope directory '$sc'"
    timeout 30 "$T" stop "$pg" | grep -q "nothing left" && ok "stop ended the group and the cgroup" || fail "20d: stop did not report nothing left"
    bwait || fail "20d: the run did not end in 30s"
    until_long '! pgrep -f "^sleep 60[0-9]\\.$$" >/dev/null' && ok "stop ended the setsid child" || fail "20d: the setsid child survived stop"
    until_long '[ -n "$sc" ] && [ ! -e "$sc" ]' && ok "the scope is gone after stop" || fail "20d: scope $sc is still there"
    # 20e. A wrapper killed with -9 leaves its command (as before); stop then ends all of it, scope too.
    "$T" run --cpus 1 -- bash -c "setsid sleep 601.$$ & sleep 611.$$" >/dev/null 2>&1 &
    w=$!; bp=$w
    until_long '[ -n "$(jfield pgid)" ] && pgrep -f "^sleep 601\\.$$" >/dev/null && pgrep -f "^sleep 611\\.$$" >/dev/null' || fail "20e: the run and its setsid child never both showed"
    sc=$(jfield cgroup); pg=$(jfield pgid)
    [ -d "$sc" ] || fail "20e: no scope directory '$sc'"
    kill -9 $w; wait $w 2>/dev/null
    until_long 'pgrep -f "^sleep 601\\.$$" >/dev/null' || fail "20e: the command did not outlive its wrapper"
    timeout 30 "$T" stop "$pg" >/dev/null 2>&1
    until_long '! pgrep -f "^sleep 6[01][01]\\.$$" >/dev/null' && ok "stop ended an orphaned run's setsid child" || fail "20e: the setsid child survived"
    until_long '[ -n "$sc" ] && [ ! -e "$sc" ]' && ok "the orphan's scope is gone after stop" || fail "20e: scope $sc is still there"
    # 20f. A normal end: the setsid child the command leaves is ended with the run, and the scope goes.
    "$T" run --cpus 1 -- bash -c "setsid sleep 602.$$ & sleep 0.5" >/dev/null 2>&1
    until_long '! pgrep -f "^sleep 602\\.$$" >/dev/null' && ok "a normal end clears a setsid leftover" || fail "20f: the setsid leftover survived the run"
    # 20g (a guard, not a discriminator: origin/main passes it). systemd-run keeps the command's pid, the exit code (and no
    # second start after a real failure), a signal death, and the caller's stdin.
    "$T" run --cpus 1 -- bash -c "echo \$\$ > $O/g.pid; sleep 3" >/dev/null 2>&1 &
    bp=$!
    until_long '[ -n "$(jfield pgid)" ] && [ -s "$O/g.pid" ]' || fail "20g: the run never wrote its pid"
    [ "$(cat "$O/g.pid")" = "$(jfield pgid)" ] && ok "the command's pid is the run's pgid (the scope keeps the pid)" || fail "20g: command pid $(cat "$O/g.pid") is not pgid $(jfield pgid)"
    bwait || fail "20g: the run did not end in 30s"
    rm -f "$O/g.out"
    "$T" run --cpus 1 -- bash -c "echo x >> $O/g.out; exit 3" >/dev/null 2>&1; c=$?
    [ $c = 3 ] && [ "$(wc -l < "$O/g.out" | tr -d ' ')" = 1 ] && ok "exit 3 comes back as 3 through the scope, and the command ran once" || fail "20g: exit $c, started $(wc -l < "$O/g.out" 2>/dev/null) times"
    "$T" run --cpus 1 -- bash -c 'kill -TERM $$' >/dev/null 2>&1; c=$?
    [ $c = 143 ] && ok "a command killed by TERM returns 143 through the scope" || fail "20g: TERM death came back as $c"
    r=$(echo hello-stdin | "$T" run --cpus 1 -- cat 2>/dev/null)
    [ "$r" = hello-stdin ] && ok "the command reads the caller's stdin through the scope" || fail "20g: stdin gave '$r'"
    # 20h. A long argument list (past what one environment string holds) runs, by the group path, and says why.
    long=$(python3 -c "print(' '.join(['x' * 99] * 1500))")
    "$T" run --cpus 1 -- bash -c "echo done > $O/h.out; sleep 3" _ $long >/dev/null 2>&1 &
    bp=$!
    until_long '[ -n "$(jfield pgid)" ]' || fail "20h: the long-argument run never showed as running"
    [ "$(jfield observed_via)" = group ] && [ -n "$(jfield cgroup_note)" ] && ok "a 150 KB argument list takes the group path with a note ($(jfield cgroup_note))" || fail "20h: observed_via '$(jfield observed_via)', note '$(jfield cgroup_note)'"
    bwait || fail "20h: the run did not end in 30s"
    [ "$(cat "$O/h.out" 2>/dev/null)" = done ] && ok "the long-argument command ran" || fail "20h: the long-argument command did not run"
    # 20o. 950 arguments of 99 characters (the command is about 98,000 bytes as JSON, under the 100,000 line) still run in a scope.
    mid=$(python3 -c "print(' '.join(['x' * 99] * 950))")
    "$T" run --cpus 1 -- bash -c "echo done > $O/o.out; sleep 3" _ $mid >/dev/null 2>&1 &
    bp=$!
    until_long '[ -n "$(jfield pgid)" ]' || fail "20o: the run never showed as running"
    [ "$(jfield observed_via)" = cgroup ] && ok "a 98 KB command runs in a scope" || fail "20o: observed_via '$(jfield observed_via)', note '$(jfield cgroup_note)'"
    bwait || fail "20o: the run did not end in 30s"
    [ "$(cat "$O/o.out" 2>/dev/null)" = done ] && ok "the 98 KB command ran" || fail "20o: the 98 KB command did not run"
    # 20i. A leader that exits while a setsid child lives on, with the wrapper killed: the record stays (orphan), status
    # lists it, and stop reaches the child through the scope.
    "$T" run --cpus 1 -- bash -c "setsid sleep 603.$$ & sleep 2" >/dev/null 2>&1 &
    w=$!; bp=$w
    until_long '[ -n "$(jfield pgid)" ] && pgrep -f "^sleep 603\\.$$" >/dev/null' || fail "20i: the run and its setsid child never both showed"
    sc=$(jfield cgroup); pg=$(jfield pgid)
    [ -d "$sc" ] || fail "20i: no scope directory '$sc'"
    kill -9 $w; wait $w 2>/dev/null
    until_long '! kill -0 $pg 2>/dev/null' || fail "20i: the leader did not exit"
    "$T" status | grep -q "WITHOUT a slot" && ok "a setsid child alone in the scope still counts as a run without a slot" || fail "20i: status lost the orphan once its leader had exited"
    timeout 30 "$T" stop "$pg" >/dev/null 2>&1
    until_long '! pgrep -f "^sleep 603\\.$$" >/dev/null' && ok "stop ended the child of a run whose leader had exited" || fail "20i: the child survived stop"
    until_long '[ -n "$sc" ] && [ ! -e "$sc" ]' && ok "its scope is gone" || fail "20i: scope $sc is still there"
    # 20n. A scope directory that exists but has no cpu.stat: the loop below makes an empty twin of each testslot scope
    # under a root of its own, so the run finds the directory and cannot read cpu from it. (The trap kills the loop.)
    mkdir -p "$O/cg3"; : > "$O/cg3/cgroup.controllers"
    ( while :; do for f in $(find /sys/fs/cgroup/user.slice -maxdepth 6 -name 'testslot-*.scope' -type d 2>/dev/null); do mkdir -p "$O/cg3${f#/sys/fs/cgroup}"; done; sleep 0.05; done ) &
    mir=$!
    TESTSLOT_CGROUP_ROOT="$O/cg3" "$T" run --cpus 1 -- sleep 4 >/dev/null 2>&1 &
    bp=$!
    until_long '[ -n "$(jfield pgid)" ]' || fail "20n: the run never showed as running"
    [ "$(jfield observed_via)" = group ] && [ "$(jfield cgroup_note)" = "its cpu.stat is not readable" ] && ok "a scope with no readable cpu.stat falls back, with its own note" || fail "20n: observed_via '$(jfield observed_via)', note '$(jfield cgroup_note)'"
    bwait || fail "20n: the run did not end in 30s"
    kill $mir 2>/dev/null; wait $mir 2>/dev/null; mir=
    # 20m. A scope directory that is not there (a root with cgroup.controllers and no scope under it) falls back, saying so.
    mkdir -p "$O/cg1"; : > "$O/cg1/cgroup.controllers"
    TESTSLOT_CGROUP_ROOT="$O/cg1" "$T" run --cpus 1 -- sleep 4 >/dev/null 2>&1 &
    bp=$!
    until_long '[ -n "$(jfield pgid)" ]' || fail "20m: the run never showed as running"
    case "$(jfield cgroup_note)" in "its scope was not found"*) ok "a scope directory that is not there falls back, saying so" ;; *) fail "20m: note '$(jfield cgroup_note)'" ;; esac
    bwait || fail "20m: the run did not end in 30s"
    # 20k. TESTSLOT_NO_CGROUP=0 is not "off": only 1 forces the fallback.
    TESTSLOT_NO_CGROUP=0 "$T" run --cpus 1 -- sleep 3 >/dev/null 2>&1 &
    bp=$!
    until_long '[ -n "$(jfield pgid)" ]' || fail "20k: the run never showed as running"
    [ "$(jfield observed_via)" = cgroup ] && ok "TESTSLOT_NO_CGROUP=0 leaves the cgroup on" || fail "20k: observed_via '$(jfield observed_via)'"
    bwait || fail "20k: the run did not end in 30s"
    # 20p (a guard, not a discriminator: origin/main drops it too). A dead orphan whose scope is gone is dropped by the next run.
    dp=$(sh -c 'echo $$')
    [ -n "$dp" ] && printf '{"pid": %s, "pgid": %s, "start": 1, "state": "running", "since": 1, "kind": "light", "cpus": 1, "account": "x", "repo": "x", "command": "forged-dead", "queued": 1, "cgroup": "/sys/fs/cgroup/user.slice/testslot-%s-1.scope"}' "$dp" "$dp" "$dp" > "$TESTSLOT_DIR/holders/$dp.json"
    "$T" run --cpus 1 -- true >/dev/null 2>&1
    [ -n "$dp" ] && [ ! -e "$TESTSLOT_DIR/holders/$dp.json" ] && ok "a dead orphan with an empty scope is dropped" || fail "20p: the record of a dead orphan with an empty scope is still there"
    # 20q. Forged holder records against stop. A live run A (sleep 604) and a harmless setsid group Z (sleep 605).
    "$T" run --cpus 1 -- sleep 604.$$ >/dev/null 2>&1 &
    bp=$!
    until_long '[ -n "$(jpg "sleep 604.$$")" ]' || fail "20q: the live run never showed"
    apg=$(jpg "sleep 604.$$")
    setsid sleep 605.$$ &
    until_long 'pgrep -f "^sleep 605\\.$$" >/dev/null' || fail "20q: the harmless group never started"
    zp=$(pgrep -f "^sleep 605\\.$$" | head -1)
    # (1) A's pid, scope and a harmless pgid. Stop on that pgid ends the harmless group, not A.
    forge "$apg" "$zp" forged
    [ -s "$TESTSLOT_DIR/holders/forged.json" ] || fail "20q: no forged record was made"
    timeout 30 "$T" stop "$zp" >/dev/null 2>&1; rm -f "$TESTSLOT_DIR/holders/forged.json"
    until_long '! pgrep -f "^sleep 605\\.$$" >/dev/null' && ok "stop on a forged pgid ended the harmless group" || fail "20q1: the harmless group survived"
    sleep 1
    pgrep -f "^sleep 604\\.$$" >/dev/null && [ "$(jpg "sleep 604.$$")" = "$apg" ] && ok "the live run was left alone by a forged record" || fail "20q1: the live run was stopped through a forged record"
    # (2) The same record marked orphan, with a harmless pgid again: an orphan claim in the file is not believed.
    setsid sleep 605.$$ &
    until_long 'pgrep -f "^sleep 605\\.$$" >/dev/null' || fail "20q2: the harmless group never started"
    zp=$(pgrep -f "^sleep 605\\.$$" | head -1)
    forge "$apg" "$zp" forged orphan
    timeout 30 "$T" stop "$zp" >/dev/null 2>&1; rm -f "$TESTSLOT_DIR/holders/forged.json"
    until_long '! pgrep -f "^sleep 605\\.$$" >/dev/null' && ok "a forged orphan record's harmless group was ended" || fail "20q2: the harmless group survived"
    sleep 1
    pgrep -f "^sleep 604\\.$$" >/dev/null && ok "the live run was left alone by a forged orphan record" || fail "20q2: the live run was stopped through a forged orphan record"
    # (3) A lone record with the group's leader gone: the group is ended, A's wrapper (the record's pid) is not signalled.
    setsid bash -c "sleep 606.$$ & exit 0" &
    until_long 'pgrep -f "^sleep 606\\.$$" >/dev/null' || fail "20q3: the leaderless group never started"
    lp=$(ps -o pgid= -p "$(pgrep -f "^sleep 606\\.$$" | head -1)" | tr -d ' ')
    forge "$apg" "$lp" forged
    timeout 30 "$T" stop "$lp" >/dev/null 2>&1; rm -f "$TESTSLOT_DIR/holders/forged.json"
    until_long '! pgrep -f "^sleep 606\\.$$" >/dev/null' && ok "a leaderless group was ended through a lone forged record" || fail "20q3: the leaderless group survived"
    sleep 1
    pgrep -f "^sleep 604\\.$$" >/dev/null && ok "the live run's wrapper was not signalled for a leaderless group" || fail "20q3: the live run was stopped through a lone forged record"
    # (4) A forged record that carries ANOTHER live run B's pid and scope and A's pgid, queued first: stop on A's pgid
    # stops A (its own record is the genuine one), and B is left alone.
    "$T" run --cpus 1 -- sleep 607.$$ >/dev/null 2>&1 &
    b4=$!
    until_long '[ -n "$(jpg "sleep 607.$$")" ]' || fail "20q4: the second live run never showed"
    bpg=$(jpg "sleep 607.$$")
    forge "$bpg" "$apg" forged
    timeout 30 "$T" stop "$apg" >/dev/null 2>&1; rm -f "$TESTSLOT_DIR/holders/forged.json"
    until_long '! pgrep -f "^sleep 604\\.$$" >/dev/null' && ok "stop ended the run its pgid names, through the genuine record" || fail "20q4: the named run survived"
    sleep 1
    pgrep -f "^sleep 607\\.$$" >/dev/null && ok "the other live run was left alone by a forged record sharing the pgid" || fail "20q4: the other live run was stopped through a forged record"
    timeout 30 "$T" stop "$bpg" >/dev/null 2>&1
    bwaitp $b4 || fail "20q4: the second live run did not end in 30s"
    bwait || fail "20q: the first live run did not end in 30s"
    "$T" run --cpus 1 -- true >/dev/null 2>&1   # a run prunes the records of the killed wrappers above
    [ -z "$(ls "$TESTSLOT_DIR/holders" 2>/dev/null)" ] && ok "no holder left after the cgroup runs" || fail "20: holder left: $(ls "$TESTSLOT_DIR/holders")"
  else
    echo "skip 20a, 20c to 20i, 20k, 20m (scope absent), 20n to 20q: no systemd user manager here (systemd-run --user --scope failed)"
  fi
else
  echo "skip the cgroup cases 20 (Linux only; this run is $PLAT)"
fi
unset TESTSLOT_SAMPLE_S

# 8z. A process whose command line holds a byte that is not UTF-8 (a ps listing from a real box had 0xe9) must not
# crash a waiting run: it waits, names the holder, runs, and prints no traceback. A shim ps adds such a line to the
# `args=` listing and passes every other call to the real ps.
realps=$(command -v ps); mkdir -p "$O/nonutf"
printf '#!/bin/sh\ncase "$*" in *args=*) %s "$@"; printf "99999 99999 caf\\351 --x\\n";; *) exec %s "$@";; esac\n' "$realps" "$realps" > "$O/nonutf/ps"
chmod +x "$O/nonutf/ps"
"$T" run --cpus 2 -- bash -c ": $TESTSLOT_DIR; sleep 3" >/dev/null 2>&1 &
until_true '[ "$(holding light)" = 1 ]' || fail "8z: the holder never showed as holding"
rm -f "$O/nonutf.ran"
PATH="$O/nonutf:$PATH" timeout 60 "$T" run --cpus 1 -- bash -c ": $TESTSLOT_DIR; touch $O/nonutf.ran" >/dev/null 2>"$O/nonutf.err" &
nu=$!; bwaitp $nu || fail "8z: the waiting run did not end in 30s"; c=$bwc
wait
[ $c = 0 ] && [ -e "$O/nonutf.ran" ] && grep -q "held by:" "$O/nonutf.err" && grep -q "sleep 3" "$O/nonutf.err" && ! grep -q Traceback "$O/nonutf.err" \
  && ok "a non-UTF-8 byte in the ps listing: the run waits, names the holder and runs" \
  || { fail "a non-UTF-8 byte in the ps listing (exit $c)"; sed 's/^/     /' "$O/nonutf.err"; }

# 8y. testslot's own failure exits 70 and says "testslot error" on stderr; a failing command keeps its own code.
TESTSLOT_TEST_CRASH=boom "$T" status >/dev/null 2>"$O/crash.err"; c=$?
[ $c = 70 ] && grep -q "^testslot error: RuntimeError: boom" "$O/crash.err" && ! grep -q Traceback "$O/crash.err" \
  && ok "an internal error exits 70 and says testslot error on stderr" || { fail "an internal error: exit $c"; sed 's/^/     /' "$O/crash.err"; }
TESTSLOT_TEST_CRASH=boom "$T" run --cpus 1 -- true >"$O/crashrun.out" 2>"$O/crashrun.err"; c=$?
[ $c = 70 ] && grep -q "^testslot error: RuntimeError: boom" "$O/crashrun.err" \
  && ok "run returns 70 on an internal error" || fail "run on an internal error: exit $c"
"$T" run --cpus 1 -- bash -c "exit 3" >/dev/null 2>&1; c=$?
[ $c = 3 ] && ok "a failing command keeps its own exit code" || fail "a failing command exited $c"
# an internal error after the command has finished keeps the command's code and still says so
TESTSLOT_TEST_CRASH=after-wait "$T" run --cpus 1 -- bash -c "exit 3" >/dev/null 2>"$O/aw.err"; c=$?
[ $c = 3 ] && grep -q "^testslot error: RuntimeError: after the command ended" "$O/aw.err" \
  && ok "an internal error after the command ended keeps the command's code (3) and prints the line" || { fail "after-wait: exit $c"; sed 's/^/     /' "$O/aw.err"; }
[ -z "$(ls "$TESTSLOT_DIR/holders" 2>/dev/null)" ] && ok "and the run leaves no holder behind" || fail "after-wait left a holder"
# the line numbers testslot's own frame, and a closed pipe is not an internal error
grep -q "(line [0-9]*)$" "$O/aw.err" && ok "the error line names a line of testslot itself" || fail "no (line N) in: $(cat "$O/aw.err")"
TESTSLOT_TEST_CRASH=pipe "$T" status >/dev/null 2>"$O/pipe.err"; c=$?
[ $c = 141 ] && ! grep -q "testslot error" "$O/pipe.err" && ok "a closed stdout (BrokenPipeError) exits 141, not as a testslot error" || fail "BrokenPipe: exit $c"
# a cwd or command line that isn't UTF-8 must not crash status, even with a strict stdout
nd="$O/d$(printf '\351')"
if mkdir "$nd" 2>/dev/null; then
  ( cd "$nd" && PYTHONIOENCODING=utf-8:strict "$T" run --cpus 1 -- bash -c ": $TESTSLOT_DIR; for _ in \$(seq 600); do [ -e $O/odd.go ] && break; sleep 0.1; done" >/dev/null 2>&1 ) &
  # the run holds until we have looked (up to 60s), so a slow box can't end it before status sees it
  for _ in $(seq 300); do PYTHONIOENCODING=utf-8:strict "$T" status 2>/dev/null | grep -q "^  light" && break; sleep 0.1; done
  PYTHONIOENCODING=utf-8:strict "$T" status 2>/dev/null | grep -q "^  light" || fail "8y: the run in the odd folder never showed in status"
  PYTHONIOENCODING=utf-8:strict "$T" status >"$O/odd.out" 2>"$O/odd.err"; c=$?
  [ $c = 0 ] && ! grep -q "Traceback\|testslot error" "$O/odd.err" && grep -q "^  light" "$O/odd.out" \
    && ok "status lists a run whose folder name isn't UTF-8, under a strict stdout" || { fail "status with a non-UTF-8 folder: exit $c"; sed 's/^/     /' "$O/odd.err"; }
  : > "$O/odd.go"; wait
else echo "skip the non-UTF-8 folder case (this filesystem refuses non-UTF-8 names)"; fi

# 8x. A clock near 0 (a fresh boot, or a sandbox whose time.monotonic() counts from process start: 0.005 seen in a Claude
# Code shell) must not make ps_table() take its empty initial table for a fresh listing, which read every holder as dead.
# The check patches time.monotonic before the first call (a clock hook, not a real boot), through the ps path
# (TESTSLOT_PLATFORM=darwin makes Linux take it), and wants the process itself and a running holder in the answer.
cat > "$O/clock0.py" <<'PY'
import importlib.machinery, importlib.util, io, os, sys, time
os.environ["TESTSLOT_PLATFORM"] = "darwin"
time.monotonic = lambda: 0.005
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load(sys.argv[1])
mine = m.proc_stat(os.getpid())
print(("PASS" if mine and m.alive(os.getpid()) and os.getpid() in m.ps_table() else "FAIL") + " clock near 0: ps_table lists this process and alive() sees it")
sys.argv = ["testslot", "status"]
buf, sys.stdout = sys.stdout, io.StringIO()
code = m.main()
out, sys.stdout = sys.stdout.getvalue(), buf
print(("PASS" if code == 0 and "\n  light" in out and "sleep 4" in out else "FAIL") + " clock near 0: status lists the running holder")
PY
TESTSLOT_PLATFORM=darwin "$T" run --cpus 1 -- bash -c ": $TESTSLOT_DIR; sleep 4" >/dev/null 2>&1 &
until_true 'TESTSLOT_PLATFORM=darwin "$T" status 2>/dev/null | grep -q "^  light"' || fail "8x: the run never showed in status on the ps path"
python3 "$O/clock0.py" "$TP" > "$O/clock0.txt" 2>"$O/clock0.err"
[ -s "$O/clock0.txt" ] || { fail "8x: the clock-near-0 check did not run"; sed 's/^/     /' "$O/clock0.err"; }
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "$rest" || fail "$rest"; done < "$O/clock0.txt"
wait

# 9a. With no cap file and no TESTSLOT_CAP, status is still quick (the retry for a half-written file must not run when the
# file is simply absent): a fresh slot folder.
D2=$(mktemp -d /tmp/testslot-test.XXXXXX); mkdir -p "$D2/holders" "$D2/logs"
s=$(stamp); env -u TESTSLOT_CAP TESTSLOT_DIR=$D2 "$T" status >/dev/null; e=$(stamp)
awk -v s="$s" -v e="$e" 'BEGIN{exit !(e - s < 0.5)}' && ok "status with no cap file under 0.5s" || fail "status with no cap file took $(awk -v s=$s -v e=$e 'BEGIN{print e-s}')s"
rm -rf "$D2"

# 9. status is quick.
s=$(stamp); "$T" status >/dev/null; e=$(stamp)
awk -v s="$s" -v e="$e" 'BEGIN{exit !(e - s < 0.5)}' && ok "status under 0.5s" || fail "status took $(awk -v s=$s -v e=$e 'BEGIN{print e-s}')s"

# 21. Start-rate throttle. TESTSLOT_FAKE_START_RATE stands in for the host's starts a second, so
# the host's own load can't make these flaky; a watcher rewrites it from the run leader's state (T while paused).
# Each case first asserts a pause count, which is absent (0) on code without the throttle.
P=$O/tsrate.py
cat > "$P" <<'PY'
import importlib.machinery, importlib.util, sys
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load(sys.argv[1])
def check(ok, what): print(("PASS " if ok else "FAIL ") + what)
check(m.pid_starts(1000, 1400) == 399, "21a: macOS reading, probe pids 1000 then 1400 read 399 starts")
check(m.pid_starts(99990, 120) == 28, "21g: across the pid wrap (99990 then 120: 99991-99998 and 100-120, less the probe) 28 starts, not a burst")
# the reader starts and reaps a probe child of its own each reading (Popen stubbed)
made = []
class Fake:
    def __init__(self, argv, **kw):
        made.append(self); self.argv = argv; self.pid = [1000, 1400][len(made) - 1]; self.waited = False
    def wait(self):
        self.waited = True; return 0
m.LINUX, m.FAKE_START_RATE = False, ""
m.subprocess.Popen = Fake
times = iter([10.0, 11.0])
m.time.monotonic = lambda: next(times)
r = m.StartRate(); first = r.read(); second = r.read()
check(first is None and second == 399 and len(made) == 2 and all(p.waited and p.argv == ["/usr/bin/true"] for p in made),
      f"21a: the macOS reader starts and reaps its own /usr/bin/true each reading (read {first}, {second})")
PY
python3 "$P" "$T" > "$O/tsrate.txt" 2>"$O/tsrate.err"
[ -s "$O/tsrate.txt" ] || { fail "21a: the unit checks did not run"; sed 's/^/     /' "$O/tsrate.err"; }
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "$rest" || fail "$rest"; done < "$O/tsrate.txt"

export TESTSLOT_START_RATE_CAP=120 TESTSLOT_FAKE_START_RATE=$O/rate
R=$O/rate
rpg() { "$T" status --json | python3 -c "import json,sys; print(next((r['pgid'] for r in json.load(sys.stdin)['running'] if sys.argv[1] in (r.get('command') or '') and r.get('pgid')), ''))" "$1"; }
lstate() { ps -o stat= -p "$1" 2>/dev/null | tr -d ' ' | cut -c1; }
# watch_rate PGID HIGH LOW [once]: LOW while the leader is stopped, HIGH while it runs; with once, LOW for good from the first stop
watch_rate() { while kill -0 "$1" 2>/dev/null; do if [ "$(lstate "$1")" = T ]; then echo "$3" > "$R"; [ -n "${4:-}" ] && return; else echo "$2" > "$R"; fi; sleep 0.1; done; }
# the history field $2 of the last run whose command holds $1
rhist() { python3 -c "
import json,sys
r=[json.loads(l) for l in open('$TESTSLOT_DIR/history.jsonl') if sys.argv[1] in (json.loads(l).get('command') or '')]
v = r[-1].get(sys.argv[2]) if r else None
print('' if v is None else v)" "$1" "$2"; }
num() { awk -v a="$1" -v op="$2" -v b="$3" 'BEGIN{ if (a == "") exit 1; if (op == ">") exit !(a > b); if (op == "<=") exit !(a <= b); exit !(a == b) }'; }

# 21b. Its own burst: over the cap, then under 80% once paused. It pauses, resumes, says so once, and history counts it.
echo 300 > "$R"
"$T" run --cpus 1 -- bash -c ": rate2.$$; sleep 8" >/dev/null 2>"$O/r2.err" & bp=$!
until_long '[ -n "$(rpg "rate2.$$")" ]' || fail "21b: the run never showed as running"
pg=$(rpg "rate2.$$"); watch_rate "$pg" 300 50 once & wp=$!
bwaitp "$bp"; kill $wp 2>/dev/null; wait $wp 2>/dev/null
p=$(rhist "rate2.$$" pauses); pt=$(rhist "rate2.$$" paused_s)
num "$p" ">" 0 && num "$pt" ">" 0 && ok "21b: a run over the start-rate cap paused its own burst ($p pauses, ${pt}s)" || fail "21b: no pause recorded (pauses '$p', paused_s '$pt')"
grep -q "^testslot: paused (up to 3s): host starts [0-9]*/s, cap 120/s" "$O/r2.err" && ok "21b: the first pause printed its line" || fail "21b: no first-pause line: $(grep testslot: "$O/r2.err" | tail -2)"
[ "$bwc" = 0 ] && ok "21b: the paused run still exited 0" || fail "21b: exit $bwc"

# 21c. Outside work: the rate stays over the cap whatever the run does. One pause, about 3 s, then the hold-off line.
echo 300 > "$R"
"$T" run --cpus 1 -- bash -c ": rate3.$$; sleep 8" >/dev/null 2>"$O/r3.err" & bp=$!
bwaitp "$bp"
p=$(rhist "rate3.$$" pauses); mx=$(rhist "rate3.$$" max_pause_s)
num "$p" "==" 1 && ok "21c: outside starts paused the run exactly once" || fail "21c: pauses '$p', want 1"
num "$mx" "<=" 3.5 && num "$mx" ">" 2 && ok "21c: that pause lasted about 3s (${mx}s)" || fail "21c: max_pause_s '$mx'"
grep -q "did not fall while this run was paused.*not pausing it for 60s" "$O/r3.err" && ok "21c: the hold-off line was printed" || fail "21c: no hold-off line: $(grep testslot: "$O/r3.err" | tail -2)"

# 21d. A cancel while paused is a cancel, and nothing of the group is left.
echo 300 > "$R"
"$T" run --cpus 1 -- bash -c ": rate4.$$; sleep 30" >/dev/null 2>&1 & bp=$!
until_long '[ -n "$(rpg "rate4.$$")" ]' || fail "21d: the run never showed as running"
pg=$(rpg "rate4.$$")
until_long '[ "$(lstate "$pg")" = T ]' || fail "21d: the run was never paused"
"$T" stop "$pg" >/dev/null; bwaitp "$bp"
[ "$(rhist "rate4.$$" cancelled)" = True ] && [ "$(rhist "rate4.$$" exit)" = 143 ] && num "$(rhist "rate4.$$" pauses)" ">" 0 \
  && ok "21d: stop on a paused run is recorded as a cancel (143)" || fail "21d: cancelled '$(rhist "rate4.$$" cancelled)', exit '$(rhist "rate4.$$" exit)'"
[ -z "$(pgrep -g "${pg:-0}" 2>/dev/null)" ] && ok "21d: nothing of the paused group is left" || fail "21d: left in group $pg: $(pgrep -g "$pg")"

# 21e. Pauses stay short: over the cap while running, under 80% while paused, for 30 s. Many short pauses, the longest
# about 3 s (a pause ends on a 1-second reading, so the bound allows half a second of scheduling), and at most two lines.
echo 300 > "$R"
"$T" run --cpus 1 -- bash -c ": rate5.$$; sleep 30" >/dev/null 2>"$O/r5.err" & bp=$!
until_long '[ -n "$(rpg "rate5.$$")" ]' || fail "21e: the run never showed as running"
pg=$(rpg "rate5.$$"); watch_rate "$pg" 300 50 & wp=$!
for _ in $(seq 450); do kill -0 "$bp" 2>/dev/null || break; sleep 0.1; done; bwaitp "$bp"; kill $wp 2>/dev/null; wait $wp 2>/dev/null
p=$(rhist "rate5.$$" pauses); mx=$(rhist "rate5.$$" max_pause_s); lines=$(grep -c "^testslot: paused" "$O/r5.err")
num "$p" ">" 3 && ok "21e: a run that keeps bursting alternates ($p pauses in 30s)" || fail "21e: pauses '$p', want several"
num "$mx" "<=" 3.5 && ok "21e: no pause over about 3s (longest ${mx}s)" || fail "21e: max_pause_s '$mx'"
[ "$lines" -ge 1 ] && [ "$lines" -le 2 ] && ok "21e: $lines pause lines (first pause, then the 30s summary)" || fail "21e: $lines pause lines"

# 21f. A wrapper killed while its run is paused: the next status resumes the group.
echo 300 > "$R"
"$T" run --cpus 1 -- bash -c ": tsorph.$$ rate6; sleep 20" >/dev/null 2>&1 & w=$!
until_long '[ -n "$(rpg "rate6")" ]' || fail "21f: the run never showed as running"
pg=$(rpg "rate6")
until_long '[ "$(lstate "$pg")" = T ]' || fail "21f: the run was never paused"
kill -9 $w; wait $w 2>/dev/null
[ "$(lstate "$pg")" = T ] || fail "21f: the group was no longer stopped once the wrapper died (the check proves nothing)"
"$T" status >/dev/null
until_true '[ "$(lstate "$pg")" = S ] || [ "$(lstate "$pg")" = R ]' && ok "21f: status resumed the orphaned paused group" || fail "21f: group $pg still '$(lstate "$pg")'"
"$T" stop "$pg" >/dev/null; until_long '[ -z "$(pgrep -g "$pg")" ]' || fail "21f: the orphaned group outlived stop"

# 21h. status shows the cap and the rate the running wrappers read.
echo 50 > "$R"
"$T" run --cpus 1 -- bash -c ": rate8.$$; sleep 4" >/dev/null 2>&1 & bp=$!
until_long '"$T" status | grep -q "^start-rate cap 120 process starts/s for the host; 50/s now"' && ok "21h: status shows the start-rate cap and the host rate" \
  || fail "21h: $("$T" status | grep start-rate)"
bwaitp "$bp"
unset TESTSLOT_START_RATE_CAP TESTSLOT_FAKE_START_RATE
# 21i. With no cap there is no start-rate line (and with no cap the rest of this suite is the proof the throttle changes nothing).
! "$T" status | grep -q "start-rate" && ok "21i: no cap, no start-rate line" || fail "21i: a start-rate line with no cap"

# 22. Load pause. TESTSLOT_LOADAVG is the load and TESTSLOT_OBSERVED_DIR/<pgid> is one run's own
# reading, so no real load or real over-use is needed. The decider is checked on made-up holder records first.
P=$O/tsload.py
cat > "$P" <<'PY'
import importlib.machinery, importlib.util, sys, time
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load(sys.argv[1])
def check(ok, what): print(("PASS " if ok else "FAIL ") + what)
m.read_cap = lambda: 20
def h(pid, cpus, seen, kind="light", since=100, state="running", **kw):
    d = {"pid": pid, "cpus": cpus, "kind": kind, "observed": seen, "since": since, "queued": since, "state": state, "orphan": False}
    d.update(kw); return d
w = m.worst_over_user
pid = lambda r: r and r["pid"]
check(pid(w([h(1, 1, 4), h(2, 1, 1), h(3, 1, 1)])) == 1, "22a: the run using 4 of 1 declared is the worst over-user")
check(pid(w([h(1, 1, 2), h(2, 2, 6), h(3, 1, 1)])) == 2, "22a: over-use is in cpus (6 of 2 is 4 over, 2 of 1 is 1 over)")
check(pid(w([h(1, 1, 3, since=100), h(2, 1, 3, since=200), h(3, 1, 1)])) == 2, "22a: a tie goes to the run started last")
check(w([h(1, 1, 1), h(2, 1, 1), h(3, 1, 1)]) is None, "22b: nobody over what they declared: nobody is chosen")
check(w([h(1, 1, None), h(2, 1, None)]) is None, "22b: a run with no reading is never chosen")
check(w([h(1, 1, 9, orphan=True), h(2, 1, 1)]) is None, "22b: an orphan's stale reading is never used")
check(w([h(1, 4, 9, kind="heavy"), h(2, 1, 1), h(3, 1, 1)]) is None, "22b: a heavy run is never chosen")
check(w([h(1, 1, 9, kind="track"), h(2, 1, 1), h(3, 1, 1)]) is None, "22b: a track run is never chosen")
check(w([h(1, 1, 9)]) is None, "22b: the only run is never chosen")
check(w([h(1, 1, 9), h(2, 1, 1, load_paused_since=time.time())]) is None, "22b: not the last run going when the rest are paused")
check(pid(w([h(1, 1, 9, load_paused_since=time.time()), h(2, 1, 3), h(3, 1, 1)])) == 2, "22c: one already paused by load, the next worst is chosen")
check(pid(w([h(1, 1, 9, paused_since=time.time()), h(2, 1, 3), h(3, 1, 1)])) == 2, "22c: one paused by the start-rate throttle is skipped too")
check(m.pausing({"load_paused_since": time.time()}) is True and m.pausing({}) is False, "22d: pausing() sees a load pause")
PY
python3 "$P" "$T" > "$O/tsload.txt" 2>"$O/tsload.err"
[ -s "$O/tsload.txt" ] || { fail "22a: the unit checks did not run"; sed 's/^/     /' "$O/tsload.err"; }
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "$rest" || fail "$rest"; done < "$O/tsload.txt"

oldcap=$(cat "$TESTSLOT_DIR/cap" 2>/dev/null); echo 6 > "$TESTSLOT_DIR/cap"
# the settle window (case 103) at its floor, 5 s: 22i, 22j and 23 pause and resume the same run again within seconds, which the 30 s default
# would hold for longer than until_long waits, so this is required. Their assertions are as before
export TESTSLOT_PAUSE_WINDOW=5
unset TESTSLOT_OBSERVED TESTSLOT_START_RATE_CAP TESTSLOT_FAKE_START_RATE
export TESTSLOT_SAMPLE_S=0.5 TESTSLOT_OBSERVED_DIR=$O/obsdir TESTSLOT_FAKE_START_RATE=$O/rate2; echo 0 > "$O/rate2"
rm -rf "$O/obsdir"; mkdir -p "$O/obsdir"
echo "0.50 0.50 0.50 1/100 1" > "$TESTSLOT_LOADAVG"
for n in A B C; do "$T" run --cpus 1 -- bash -c ": load$n.$$; sleep 40" >/dev/null 2>"$O/ld$n.err" & eval "lp$n=\$!"; done
for n in A B C; do until_long '[ -n "$(rpg "load$n.$$")" ]' || fail "22e: run $n never showed as running"; eval "pg$n=\$(rpg \"load$n.$$\")"; done
echo 4 > "$O/obsdir/$pgA"; echo 1 > "$O/obsdir/$pgB"; echo 1 > "$O/obsdir/$pgC"
sleep 3
[ "$(lstate "$pgA")" != T ] && ok "22e: low load, the over-using run is left alone" || fail "22e: paused with the load low"
echo "1000.00 5.00 5.00 1/100 1" > "$TESTSLOT_LOADAVG"
until_long '[ "$(lstate "$pgA")" = T ]' && ok "22f: high load pauses the worst over-user" || fail "22f: run A (4 of 1) was not paused, state '$(lstate "$pgA")'"
sleep 3
[ "$(lstate "$pgB")" != T ] && [ "$(lstate "$pgC")" != T ] && ok "22f: the honest runs keep going" || fail "22f: B '$(lstate "$pgB")', C '$(lstate "$pgC")'"
grep -q "^testslot: paused: load 1000 on [0-9]* cores is over 1.5 times the cores, and this run uses 4 cpus but declared 1" "$O/ldA.err" \
  && ok "22g: the pause printed its line" || fail "22g: no pause line: $(grep testslot: "$O/ldA.err" | tail -2)"
"$T" status > "$O/ldstat.txt"; grep -q "paused: load 1000 on [0-9]* cores" "$O/ldstat.txt" && ok "22g: status says the run is paused for load" || fail "22g: status: $(grep -n paused "$O/ldstat.txt")"
echo "0.50 5.00 5.00 1/100 1" > "$TESTSLOT_LOADAVG"
until_long '[ "$(lstate "$pgA")" != T ]' && ok "22h: the run resumes when the load falls under the load cap" || fail "22h: still stopped"
grep -q "^testslot: resumed after [0-9]*s: load 0.5 is under the load cap" "$O/ldA.err" && ok "22h: the resume printed its line" || fail "22h: no resume line"

# 22i. A run under both pauses is not resumed until both clear: the start-rate pause ends after 3 s while the load pause holds.
echo "1000.00 5.00 5.00 1/100 1" > "$TESTSLOT_LOADAVG"
until_long '[ "$(lstate "$pgA")" = T ]' || fail "22i: A was not paused again"
echo 120 > "$TESTSLOT_DIR/start-rate-cap"; echo 300 > "$O/rate2"   # the cap file is read live; the fake rate stays over it
sleep 9
[ "$(lstate "$pgA")" = T ] && ok "22i: after a start-rate pause ended, the load pause still holds the run" || fail "22i: A is '$(lstate "$pgA")' with the load still high"
rm -f "$TESTSLOT_DIR/start-rate-cap"; echo 0 > "$O/rate2"
echo "0.50 5.00 5.00 1/100 1" > "$TESTSLOT_LOADAVG"
until_long '[ "$(lstate "$pgA")" != T ]' && ok "22i: with the load low it resumes" || fail "22i: still stopped"

# 22j. Stop on a load-paused run is a cancel and leaves nothing behind.
echo "1000.00 5.00 5.00 1/100 1" > "$TESTSLOT_LOADAVG"
until_long '[ "$(lstate "$pgA")" = T ]' || fail "22j: A was not paused again"
"$T" stop "$pgA" >/dev/null; bwaitp "$lpA"
[ "$(rhist "loadA.$$" cancelled)" = True ] && [ -z "$(pgrep -g "$pgA" 2>/dev/null)" ] && ok "22j: stop on a load-paused run is a cancel and nothing is left" || fail "22j: cancelled '$(rhist "loadA.$$" cancelled)', left '$(pgrep -g "$pgA")'"
num "$(rhist "loadA.$$" pauses)" ">" 0 && ok "22i: the start-rate pause on the load-paused run was counted too" || fail "22i: pauses '$(rhist "loadA.$$" pauses)'"
for n in B C; do p=$(rpg "load$n.$$"); [ -n "$p" ] && "$T" stop "$p" >/dev/null 2>&1; done
bwaitp "$lpB"; bwaitp "$lpC"
echo "0.00 0.00 0.00 1/100 1" > "$TESTSLOT_LOADAVG"
unset TESTSLOT_OBSERVED_DIR TESTSLOT_SAMPLE_S TESTSLOT_FAKE_START_RATE
[ -n "$oldcap" ] && echo "$oldcap" > "$TESTSLOT_DIR/cap" || rm -f "$TESTSLOT_DIR/cap"

# 23. Requeue. Same fakes as case 22: TESTSLOT_LOADAVG is the load and TESTSLOT_OBSERVED_DIR/<pgid> is one
# run's own reading (TESTSLOT_OBSERVED the fallback, for a run with no file of its own); TESTSLOT_REQUEUE_AFTER_S=3 stands for 5 minutes.
P=$O/tsrequeue.py
cat > "$P" <<'PY'
import importlib.machinery, importlib.util, sys
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load(sys.argv[1])
def check(ok, what): print(("PASS " if ok else "FAIL ") + what)
m.read_cap = lambda: 6
m.REQUEUE_AFTER_S = 300.0
trigger = m.LOAD_TRIGGER_X * m.CORES
high = trigger + 1
due = lambda rec=None, others=1, load=None, since=301.0: m.requeue_due(rec if rec is not None else {"kind": "light"}, others, high if load is None else load, since)
check(due() is True, "23a: first load-paused 5 minutes ago, still over twice, load over the trigger, another run going: requeue")
check(due(since=299.0) is False, "23a: not before the 5 minutes after the first load pause")
check(due(since=None) is False, "23b: never paused by the load pause since it went over (or not over, or no usable reading): no requeue")
check(due(load=trigger) is False, "23a: the load back at the trigger or under: no requeue")
check(due(others=0) is False, "23b: the last run going is never requeued")
check(due({"kind": "heavy"}) is False and due({"kind": "track"}) is False, "23b: a heavy or a track run is never requeued")
check(due({"kind": "light", "requeued_from": {"declared": 1, "peak": 4, "cpus": 4}}) is False, "23c: a run already requeued once is not requeued again")
check(m.requeue_size(4.0) == 4 and m.requeue_size(4.2) == 5 and m.requeue_size(0.3) == 1, "23d: the new size is the peak rounded up, at least 1")
check(m.requeue_size(40.0) == 6, "23d: and held to the cap")
PY
python3 "$P" "$T" > "$O/tsrequeue.txt" 2>"$O/tsrequeue.err"
[ -s "$O/tsrequeue.txt" ] || { fail "23a: the unit checks did not run"; sed 's/^/     /' "$O/tsrequeue.err"; }
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "$rest" || fail "$rest"; done < "$O/tsrequeue.txt"

oldcap=$(cat "$TESTSLOT_DIR/cap" 2>/dev/null); echo 6 > "$TESTSLOT_DIR/cap"
unset TESTSLOT_OBSERVED TESTSLOT_START_RATE_CAP TESTSLOT_FAKE_START_RATE
rm -rf "$O/obsdir3"; mkdir -p "$O/obsdir3"; echo 1 > "$O/obs3"
export TESTSLOT_SAMPLE_S=0.5 TESTSLOT_OBSERVED_DIR=$O/obsdir3 TESTSLOT_OBSERVED=$O/obs3 TESTSLOT_REQUEUE_AFTER_S=3
rm -f "$O/x_starts" "$O/w_start"
echo "0.50 0.50 0.50 1/100 1" > "$TESTSLOT_LOADAVG"
"$T" run --cpus 1 -- bash -c ": reqY.$$; sleep 60" >/dev/null 2>&1 & lpY=$!
"$T" run --cpus 1 -- bash -c ": reqX.$$; date +%s.%N >> $O/x_starts; sleep 15; exit 7" >/dev/null 2>"$O/reqX.err" & bpX=$!
until_long '[ -n "$(rpg "reqY.$$")" ] && [ -n "$(rpg "reqX.$$")" ]' || fail "23e: the runs never showed as running"
pgY=$(rpg "reqY.$$"); pgX=$(rpg "reqX.$$")
echo 1 > "$O/obsdir3/$pgY"; echo 4 > "$O/obsdir3/$pgX"; echo 9 > "$O/obs3"     # the first X uses 4 of 1; a requeued X (no file) reads 9, over twice its 4
"$T" run --cpus 5 -- bash -c ": reqW.$$; date +%s.%N > $O/w_start; sleep 1" >/dev/null 2>&1 & bpW=$!
until_long '"$T" status --json | python3 -c "import json,sys; sys.exit(not any(\"reqW.$$\" in (w.get(\"command\") or \"\") for w in json.load(sys.stdin)[\"waiting\"]))"' || fail "23e: W never showed as waiting"
sleep 5
[ -z "$(rhist "reqX.$$" cancelled)" ] && [ "$(lstate "$pgX")" != T ] && ok "23e: low load, the over-using run is left alone for longer than the requeue time" || fail "23e: X was touched with the load low (state '$(lstate "$pgX")')"
echo "1000.00 5.00 5.00 1/100 1" > "$TESTSLOT_LOADAVG"
# X has read over twice for longer than the requeue time already (23e): the load pause comes first, and the clock starts at it
until_long '[ "$(lstate "$pgX")" = T ]' && ok "23f: high load: the over-using run is paused first" || fail "23f: X was not paused (state '$(lstate "$pgX")')"
sleep 1.5
[ -z "$(rhist "reqX.$$" cancelled)" ] && [ "$(lstate "$pgX")" = T ] && ok "23f: and it is not cancelled in the first 1.5 s after its pause, though it was over for longer than the requeue time before the load rose" || fail "23f: cancelled or gone right after the pause (cancelled '$(rhist "reqX.$$" cancelled)', state '$(lstate "$pgX")')"
until_long '[ "$(rhist "reqX.$$" cancelled)" = True ]' && ok "23f: the requeue time after the pause, with the load still high: the run was cancelled (history says cancel)" || fail "23f: X was never cancelled"
[ "$(rhist "reqX.$$" exit)" = 143 ] && ok "23f: the cancelled run's history exit is 143" || fail "23f: exit '$(rhist "reqX.$$" exit)'"
grep -q "^testslot: requeued: this run used 4 cpus against the 1 it declared .*starting again at the head of the queue declaring 4" "$O/reqX.err" \
  && ok "23g: the caller's stderr says why, with the peak and the new size" || fail "23g: no requeue line: $(grep testslot: "$O/reqX.err" | tail -2)"
# the new run waits at the head of the queue (the load gate holds every start while the load is over the load cap), ahead of W
until_long '"$T" status --json | python3 -c "import json,sys; w=json.load(sys.stdin)[\"waiting\"]; sys.exit(not (len(w) >= 2 and \"reqX.$$\" in (w[0].get(\"command\") or \"\") and w[0][\"cpus\"] == 4 and w[0][\"requeued\"] and \"reqW.$$\" in (w[1].get(\"command\") or \"\")))"' \
  && ok "23g: status shows the requeued run first in the queue, declaring 4, ahead of the 5-cpu run" || fail "23g: status json: $("$T" status --json | python3 -c "import json,sys; d=json.load(sys.stdin); print([(j['command'][:20], j['cpus'], j['requeued']) for j in d['waiting'] + d['running']])")"
"$T" status | grep -q "requeued once: declared 1, peak 4, now 4" && ok "23g: status text says requeued once" || fail "23g: status text: $("$T" status | grep -n requeued)"
echo "0.50 5.00 5.00 1/100 1" > "$TESTSLOT_LOADAVG"
until_long '[ -n "$(rpg "reqX.$$")" ]' || fail "23h: the requeued run never started"
pgX2=$(rpg "reqX.$$")
[ -n "$pgX2" ] && [ "$pgX2" != "$pgX" ] && ok "23h: it started again (a new process group) before the 5-cpu run that was waiting first" || fail "23h: pgid '$pgX2' (first was $pgX)"
echo "1000.00 5.00 5.00 1/100 1" > "$TESTSLOT_LOADAVG"
sleep 8     # past REQUEUE_AFTER_S again: the new run reads over twice, the load is high, and it is paused, but not requeued a second time
n=$(python3 -c "
import json,sys
print(sum(1 for l in open('$TESTSLOT_DIR/history.jsonl') if 'reqX.$$' in (json.loads(l).get('command') or '') and json.loads(l).get('cancelled')))")
[ "$n" = 1 ] && [ "$(lstate "$pgX2")" = T ] && ok "23i: a second overrun is paused but not requeued again (one cancel in history)" || fail "23i: $n cancels, state '$(lstate "$pgX2")': $(python3 -c "
import json
for l in open('$TESTSLOT_DIR/history.jsonl'):
    h=json.loads(l)
    if 'reqX.$$' in (h.get('command') or ''): print(h['pid'], h['pgid'], h['cpus'], h['cancelled'], h['exit'], round(h['run_s'] or 0,1), h.get('requeued'), end=' | ')
")"
echo "0.50 5.00 5.00 1/100 1" > "$TESTSLOT_LOADAVG"
bwaitp "$bpX"
[ "$bwc" = 7 ] && ok "23j: the caller got the second run's exit code (7)" || fail "23j: exit $bwc"
bwaitp "$bpW"
[ "$(wc -l < "$O/x_starts" | tr -d ' ')" = 2 ] && ok "23j: the command started twice" || fail "23j: starts: $(wc -l < "$O/x_starts")"
x2=$(sed -n 2p "$O/x_starts"); w1=$(cat "$O/w_start" 2>/dev/null)
awk -v a="$x2" -v b="$w1" 'BEGIN{exit !(a != "" && b != "" && a < b)}' && ok "23j: the requeued run started before the 5-cpu run that was already waiting (head of the queue)" || fail "23j: requeued run started at $x2, W at $w1"
pgY=$(rpg "reqY.$$"); [ -n "$pgY" ] && "$T" stop "$pgY" >/dev/null 2>&1; bwaitp "$lpY"
echo "0.00 0.00 0.00 1/100 1" > "$TESTSLOT_LOADAVG"
unset TESTSLOT_OBSERVED_DIR TESTSLOT_OBSERVED TESTSLOT_SAMPLE_S TESTSLOT_REQUEUE_AFTER_S TESTSLOT_PAUSE_WINDOW
[ -n "$oldcap" ] && echo "$oldcap" > "$TESTSLOT_DIR/cap" || rm -f "$TESTSLOT_DIR/cap"

# 24. Wait reason. A waiting run records why it waits as a stable code (reserved, queued-ahead, cpus,
# load, gate, no-limit) in its holder, `testslot status` shows it, and the history line of the admitted run carries the last one. The
# text of a reason carries live numbers; the code never does, so it changes only when the reason does.
# 24a. Every reason the admission path can give reaches a code: wait_check's five, and take_slots' gate (driven live in 24c).
wd=$(mktemp -d /tmp/testslot-test.XXXXXX); mkdir -p "$wd/holders"; echo "1.0 1.0 1.0 1/100 1" > "$wd/loadavg"
TESTSLOT_DIR=$wd TESTSLOT_CAP=20 TESTSLOT_LOAD_CAP=10 TESTSLOT_LOADAVG=$wd/loadavg python3 - "$T" > "$O/wr.txt" 2>"$O/wr.err" <<'PY'
import importlib.machinery, importlib.util, os, sys, time
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load(sys.argv[1])
set_load = lambda v: open(os.environ['TESTSLOT_LOADAVG'], 'w').write(v + ' 1.0 1.0 1/100 1\n')
run = lambda n: {'pid': 4242, 'state': 'running', 'kind': 'light', 'cpus': n}
wait = lambda age, n=4: {'pid': 4243, 'state': 'waiting', 'kind': 'light', 'cpus': n, 'queued': time.time() - age}
def code(hs, n=1, ci=False):
    try:
        r = m.wait_check(hs, 1, time.time(), n, None, ci) if ci else getattr(m, 'wait_check', lambda *a: ('no wait_check',))(hs, 1, time.time(), n)
    except TypeError:
        return 'no ci argument'
    return r[0] if r else None
ciw = lambda age, n=1: {'pid': 4244, 'state': 'waiting', 'kind': 'light', 'cpus': n, 'queued': time.time() - age, 'ci': True}
seen = set()
for want, hs, n, load in [
  ('reserved', [run(8), wait(700)], 1, '1.0'),
  ('queued-ahead', [wait(5, 1)], 1, '1.0'),
  ('cpus', [run(20)], 1, '1.0'),
  ('load', [], 1, '11.0'),
  ('no-limit', [wait(5, 4)], 1, '1.0'),
  ('load', [run(8)], 3, '9.0'),
]:
    set_load(load)
    got = code(hs, n); seen.add(got)
    print(('PASS ' if got == want else 'FAIL ') + f'wait_check gives code {want}' + ('' if got == want else f' (got {got})'))
set_load('1.0')
for want, hs, n, ci in [('ci-first', [ciw(5)], 1, False), ('ci-priority', [run(20)], 1, True)]:
    got = code(hs, n, ci); seen.add(got)
    print(('PASS ' if got == want else 'FAIL ') + f'wait_check gives code {want}' + ('' if got == want else f' (got {got})'))
codes = getattr(m, 'WAIT_CODES', None)
print(('PASS ' if codes and set(codes) - {'gate'} == seen else 'FAIL ') + 'every code but the gate is driven above, and WAIT_CODES lists them all (a new reason without a code fails here)')
print(('PASS ' if codes and 'gate' in codes else 'FAIL ') + 'WAIT_CODES names the gate code that take_slots gives')
import inspect, re
lit = set(re.findall(r'wait_why\(\s*"([a-z-]+)"', inspect.getsource(m.wait_check) + inspect.getsource(m.take_slots))) if hasattr(m, 'wait_check') else None
print(('PASS ' if lit and codes and lit == set(codes) else 'FAIL ') + 'the code literals in wait_check and take_slots are exactly WAIT_CODES (a new reason with an unlisted code fails here, and wait_why refuses it at run time)')
try:
    m.wait_why('not-a-code', 'x'); refused = False
except ValueError:
    refused = True
print(('PASS ' if refused else 'FAIL ') + 'wait_why refuses a code that is not in WAIT_CODES')
set_load('1.0')
tx = m.why_wait([run(20)], 1, time.time(), 1)
print(('PASS ' if tx and tx.startswith('cpus:') else 'FAIL ') + 'why_wait still returns the reason text')
PY
[ "$(wc -l < "$O/wr.txt" | tr -d ' ')" = 13 ] || { fail "24a: the check printed $(wc -l < "$O/wr.txt") of 13 lines (it stopped early)"; sed 's/^/     /' "$O/wr.err"; }
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "24a: $rest" || fail "24a: $rest"; done < "$O/wr.txt"
rm -rf "$wd"
# 24b. A run held on the cpus: its holder and status carry "cpus" while it waits, and its history line carries it once admitted.
: > "$TESTSLOT_DIR/history.jsonl"
"$T" run --heavy -- bash -c "sleep 8; : wr24b-hold" >/dev/null 2>&1 &
hp=$!
until_true '[ "$(holding heavy)" = 1 ]' || fail "24b: the holding run never showed as holding"
"$T" run --cpus 1 -- bash -c ": wr24b-wait" >/dev/null 2>"$O/wrw.err" &
wp=$!
until_true 'grep -q "waiting" "$O/wrw.err"' || fail "24b: the second run never waited"
waiter_code() { "$T" status --json | python3 -c "import json,sys; w=json.load(sys.stdin)['waiting']; print(w[0].get('wait_reason') if w else 'none')"; }
holder_code() { python3 -c "
import glob, json, sys
for f in glob.glob('$TESTSLOT_DIR/holders/*'):
    try: h = json.load(open(f))
    except (OSError, ValueError): continue
    if h.get('state') == 'waiting' and sys.argv[1] in (h.get('command') or ''): print(h.get('wait_reason')); sys.exit()
print('none')" "$1"; }
until_true '[ "$(waiter_code)" = cpus ]' && ok "24b: status --json gives the waiting run's wait_reason (cpus)" || fail "24b: status --json wait_reason is '$(waiter_code)'"
[ "$(holder_code wr24b-wait)" = cpus ] && ok "24b: the waiting run's holder file carries wait_reason cpus" || fail "24b: the holder's wait_reason is '$(holder_code wr24b-wait)'"
"$T" status | grep -q "(waiting: cpus)" && ok "24b: status text shows the waiter's reason" || fail "24b: status text has no '(waiting: cpus)'"
wait $wp $hp
python3 - "$TESTSLOT_DIR/history.jsonl" > "$O/wh.txt" 2>&1 <<'PY'
import json, sys
rows = {('wait' if 'wr24b-wait' in (r.get('command') or '') else 'hold'): r for r in map(json.loads, open(sys.argv[1])) if 'wr24b' in (r.get('command') or '')}
w, h = rows.get('wait', {}), rows.get('hold', {})
print('PASS' if w.get('wait_reason') == 'cpus' else 'FAIL', "the admitted waiter's history line has wait_reason cpus (got %r)" % w.get('wait_reason', 'no field'))
print('PASS' if h.get('wait_reason') == '' else 'FAIL', "a run that never waited has an empty wait_reason (got %r)" % h.get('wait_reason', 'no field'))
PY
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "24b: $rest" || fail "24b: $rest"; done < "$O/wh.txt"
# 24c. The gate reason: a lock held outside testslot holds a run that has nothing in its way, and that reaches wait_reason too.
: > "$TESTSLOT_DIR/history.jsonl"
echo "0.00 0.00 0.00 1/100 1" > "$TESTSLOT_LOADAVG"   # the load check comes before the gate: keep it out of the way
outside_hold 8
"$T" run --cpus 1 -- bash -c ": wr24c-gate" >/dev/null 2>"$O/wrg.err" &
gp=$!
until_true 'grep -q "the test gate" "$O/wrg.err"' || fail "24c: the run never said it waits on the test gate"
until_true '[ "$(waiter_code)" = gate ]' && ok "24c: a run held by the outside gate shows wait_reason gate" || fail "24c: wait_reason is '$(waiter_code)' while the gate is held"
wait $gp
python3 -c "
import json
r=[json.loads(l) for l in open('$TESTSLOT_DIR/history.jsonl') if 'wr24c-gate' in l]
print('PASS' if r and r[0].get('wait_reason') == 'gate' else 'FAIL', 'the gate waiter has wait_reason gate in its history line')" > "$O/wg.txt" 2>&1
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "24c: $rest" || fail "24c: $rest"; done < "$O/wg.txt"

# 25. Time limit for a run that starts while another is queued ahead. A run that
# starts past a waiting run needs --max-minutes (within the backfill limit); testslot stops it, as a cancel with
# stop_reason "time limit", once the limit passes while a run it started past still waits. Caps are 4 here.
export TESTSLOT_RESERVE=600
wr25() { python3 -c "
import json, sys
rows = [json.loads(l) for l in open('$TESTSLOT_DIR/history.jsonl') if sys.argv[1] in (json.loads(l).get('command') or '')]
print(json.dumps(rows[-1]) if rows else '{}')" "$1"; }
# 25a. A head waits (4 cpus, behind a 3-cpu holder), a 1-cpu run with a 3 s limit starts past it and would run for 60 s:
# it is stopped once past its limit, as a cancel with the reason, and the head then starts.
: > "$TESTSLOT_DIR/history.jsonl"
TESTSLOT_CAP=4 "$T" run --cpus 3 -- bash -c ": wr25a-holder; sleep 2.5" >/dev/null 2>&1 &
ah=$!
until_true '[ "$(holding light)" = 1 ]' || fail "25a: the holder never showed as holding"
TESTSLOT_CAP=4 "$T" run --cpus 4 -- bash -c ": wr25a-head; date +%s.%N > $O/wr25a-head" >/dev/null 2>"$O/wr25a-head.err" &
ahd=$!
until_true 'grep -q "waiting" "$O/wr25a-head.err"' || fail "25a: the head never waited"
TESTSLOT_CAP=4 "$T" run --cpus 1 --max-minutes 0.05 -- bash -c ": wr25a-limited; sleep 60" >/dev/null 2>"$O/wr25a-lim.err" &
alp=$!
bwaitp $alp || fail "25a: the limited run did not end in 30s"
bwaitp $ahd || fail "25a: the head did not end in 30s"
wait $ah 2>/dev/null
python3 - "$(wr25 wr25a-limited)" "$(wr25 wr25a-head)" "$(grep -c wr25a-limited "$TESTSLOT_DIR/history.jsonl")" > "$O/w25a.txt" 2>&1 <<'PY'
import json, sys
lim, head = json.loads(sys.argv[1]), json.loads(sys.argv[2])
chk = [
  ("the limited run started past the waiting head (backfill true)", lim.get("backfill") is True),
  ("it was stopped as a cancel with stop_reason 'time limit'", lim.get("cancelled") is True and lim.get("stop_reason") == "time limit"),
  ("it was stopped between 3 and 12 s after its start (limit 3 s, plus a watcher tick and the 5 s grace)", lim.get("run_s") is not None and 3 <= lim["run_s"] <= 12),
  ("it was not requeued, and left exactly one history row", lim.get("requeued") is False and lim.get("limit_s") == 3 and int(sys.argv[3]) == 1),
  ("the head started after the stop, within a few seconds", head.get("started") is not None and lim.get("ended") is not None and 0 <= head["started"] - lim["ended"] <= 8),
]
for name, good in chk: print(("PASS " if good else "FAIL ") + name)
PY
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "25a: $rest" || fail "25a: $rest"; done < "$O/w25a.txt"
[ "$(wc -l < "$O/w25a.txt" | tr -d ' ')" = 5 ] || fail "25a: the check printed $(wc -l < "$O/w25a.txt") of 5 lines: $(head -3 "$O/w25a.txt")"
# 25b. A head waits; a 2-cpu run with no limit (2 cpus, so the next run isn't queued behind one of its own size), and one with a limit over the backfill limit (set to 1 minute), don't start,
# and their wait reason names the run ahead and the limit. Both show the code no-limit.
TESTSLOT_CAP=4 "$T" run --cpus 3 -- bash -c ": wr25b-holder; sleep 9" >/dev/null 2>&1 &
bh=$!
until_true '[ "$(holding light)" = 1 ]' || fail "25b: the holder never showed as holding"
TESTSLOT_CAP=4 "$T" run --cpus 4 -- bash -c ": wr25b-head" >/dev/null 2>"$O/wr25b-head.err" &
bhd=$!
until_true 'grep -q "waiting" "$O/wr25b-head.err"' || fail "25b: the head never waited"
TESTSLOT_CAP=4 "$T" run --cpus 2 -- bash -c ": wr25b-nolimit; date +%s.%N > $O/wr25b-n" >/dev/null 2>"$O/wr25b-n.err" &
bn=$!
until_true 'grep -q "no time limit" "$O/wr25b-n.err"' || fail "25b: the no-limit run never waited"   # queued before the over-limit run, or it would wait as queued-ahead
TESTSLOT_CAP=4 TESTSLOT_BACKFILL_LIMIT=1 "$T" run --cpus 1 --max-minutes 5 -- bash -c ": wr25b-over; date +%s.%N > $O/wr25b-o" >/dev/null 2>"$O/wr25b-o.err" &
bo=$!
until_long 'grep -q "no time limit" "$O/wr25b-n.err" && grep -q "backfill limit" "$O/wr25b-o.err"' || { fail "25b: a wait reason did not name the missing or too long limit"; sed 's/^/     n: /' "$O/wr25b-n.err" | head -4; sed 's/^/     o: /' "$O/wr25b-o.err" | head -4; "$T" status | sed 's/^/     status: /'; }
[ ! -e "$O/wr25b-n" ] && [ ! -e "$O/wr25b-o" ] && ok "25b: a run with no limit, and one over the backfill limit, don't start past a waiting head" || fail "25b: a run started past the waiting head"
grep -Eq "run ahead \(pid [0-9]+, 4 cpus\)" "$O/wr25b-n.err" && ok "25b: the wait reason names the run ahead (its pid and cpus)" || fail "25b: the reason does not name the run ahead: $(head -1 "$O/wr25b-n.err")"
nolimit_code() { "$T" status --json | python3 -c "import json,sys; w=[j for j in json.load(sys.stdin)['waiting'] if sys.argv[1] in j['command']]; print(w[0].get('wait_reason') if w else 'none')" "$1"; }
until_true '[ "$(nolimit_code wr25b-nolimit)" = no-limit ] && [ "$(nolimit_code wr25b-over)" = no-limit ]' && ok "25b: status --json gives wait_reason no-limit for both" || fail "25b: wait_reasons are '$(nolimit_code wr25b-nolimit)' and '$(nolimit_code wr25b-over)'"
bwaitp $bhd; bwaitp $bn; bwaitp $bo; wait $bh 2>/dev/null
# 25c. A limited run that starts with nothing queued ahead is never stopped for its limit.
: > "$TESTSLOT_DIR/history.jsonl"
TESTSLOT_CAP=4 "$T" run --cpus 1 --max-minutes 0.05 -- bash -c ": wr25c; sleep 5" >/dev/null 2>&1
c25=$(wr25 wr25c)
python3 -c "import json,sys; r=json.loads(sys.argv[1]); sys.exit(not (r.get('cancelled') is False and r.get('exit') == 0 and r.get('run_s', 0) >= 4.5))" "$c25" \
  && ok "25c: a limited run with no run ahead is not stopped at its limit" || fail "25c: the run was stopped or failed: $c25"
# 25d. A limited run that started past a waiting head, once that head has started, is not stopped at its limit.
: > "$TESTSLOT_DIR/history.jsonl"
TESTSLOT_CAP=4 "$T" run --cpus 3 -- bash -c ": wr25d-holder; sleep 1" >/dev/null 2>&1 &
dh=$!
until_true '[ "$(holding light)" = 1 ]' || fail "25d: the holder never showed as holding"
TESTSLOT_CAP=4 "$T" run --cpus 3 -- bash -c ": wr25d-head; sleep 0.5" >/dev/null 2>"$O/wr25d-head.err" &
dhd=$!
until_true 'grep -q "waiting" "$O/wr25d-head.err"' || fail "25d: the head never waited"
TESTSLOT_CAP=4 "$T" run --cpus 1 --max-minutes 0.05 -- bash -c ": wr25d-limited; sleep 7" >/dev/null 2>&1 &
dl=$!
bwaitp $dl; bwaitp $dhd; wait $dh 2>/dev/null
d25=$(wr25 wr25d-limited)
python3 -c "import json,sys; r=json.loads(sys.argv[1]); sys.exit(not (r.get('backfill') is True and r.get('cancelled') is False and r.get('exit') == 0 and r.get('run_s', 0) >= 6.5))" "$d25" \
  && ok "25d: a limited run is not stopped once the head it started past has started" || fail "25d: the run was stopped or failed: $d25"
# 25e. Past the reserve time a light run that fits and has a limit starts; one without waits, naming the reservation.
export TESTSLOT_RESERVE=1
: > "$TESTSLOT_DIR/history.jsonl"
TESTSLOT_CAP=4 "$T" run --cpus 3 -- bash -c ": wr25e-holder; sleep 6" >/dev/null 2>&1 &
eh=$!
until_true '[ "$(holding light)" = 1 ]' || fail "25e: the holder never showed as holding"
TESTSLOT_CAP=4 "$T" run --cpus 2 -- bash -c ": wr25e-head" >/dev/null 2>"$O/wr25e-head.err" &
ehd=$!
until_true 'grep -q "waiting" "$O/wr25e-head.err"' || fail "25e: the head never waited"
sleep 1.5   # past the reserve time (1 s)
TESTSLOT_CAP=4 "$T" run --cpus 2 -- bash -c ": wr25e-nolimit" >/dev/null 2>"$O/wr25e-n.err" &
en=$!
TESTSLOT_CAP=4 "$T" run --cpus 1 --max-minutes 5 -- bash -c ": wr25e-limited; date +%s.%N > $O/wr25e-l" >/dev/null 2>"$O/wr25e-l.err" &
el=$!
until_true '[ -s "$O/wr25e-l" ]' && ok "25e: past the reserve time a light run that fits and has a limit starts" || fail "25e: the limited run did not start: $(head -1 "$O/wr25e-l.err")"
until_true 'grep -q "reserved" "$O/wr25e-n.err"' && ok "25e: and one without a limit waits, naming the reservation" || fail "25e: the no-limit run's wait: $(head -1 "$O/wr25e-n.err")"
bwaitp $el; bwaitp $ehd; bwaitp $en; wait $eh 2>/dev/null
export TESTSLOT_RESERVE=600
# 25f. The bound, in process: a run may pass a reserved head only if its limit ends within the backfill limit of the moment
# the head reserved. RESERVE 600 s, backfill limit 30 min, a head queued 700 s ago reserved 100 s ago, so the bound is 1700 s away.
wf=$(mktemp -d /tmp/testslot-test.XXXXXX); mkdir -p "$wf/holders"; echo "1.0 1.0 1.0 1/100 1" > "$wf/loadavg"
TESTSLOT_DIR=$wf TESTSLOT_CAP=20 TESTSLOT_LOAD_CAP=10 TESTSLOT_LOADAVG=$wf/loadavg TESTSLOT_RESERVE=600 python3 - "$T" > "$O/w25f.txt" 2>"$O/w25f.err" <<'PY'
import importlib.machinery, importlib.util, sys, time
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load(sys.argv[1])
run = {'pid': 4242, 'state': 'running', 'kind': 'light', 'cpus': 8}
head = lambda age: {'pid': 4243, 'state': 'waiting', 'kind': 'light', 'cpus': 4, 'queued': time.time() - age}
# a head the load holds back (12 cpus on top of load 1.0 is over the load cap 10): it reserves at 6 x RESERVE = 3600 s
lhead = lambda age: {'pid': 4243, 'state': 'waiting', 'kind': 'light', 'cpus': 12, 'queued': time.time() - age}
def code(hs, limit):
    r = m.wait_check(hs, 1, time.time(), 1, limit)
    return r[0] if r else None
rows = [
  ('reserved head, limit 600 s: starts', code([run, head(700)], 600) is None),
  ('reserved head, limit 1600 s (ends before the bound): starts', code([run, head(700)], 1600) is None),
  ('reserved head, limit 1790 s (ends past the bound): waits as reserved', code([run, head(700)], 1790) == 'reserved'),
  ('reserved head, no limit: waits as reserved', code([run, head(700)], None) == 'reserved'),
  ('head not yet reserved (queued 5 s ago), no limit: waits as no-limit', code([run, head(5)], None) == 'no-limit'),
  ('head not yet reserved, limit 300 s: starts', code([run, head(5)], 300) is None),
  ('head not yet reserved, limit 2000 s (over the 30 min backfill limit): waits as no-limit', code([run, head(5)], 2000) == 'no-limit'),
  ('nothing ahead, no limit: starts', code([run], None) is None),
  ('load-held head queued 700 s ago (not reserved: needs 3600 s), no limit: waits as no-limit, not reserved', code([run, lhead(700)], None) == 'no-limit'),
  ('load-held head queued 700 s ago, limit 300 s: starts', code([run, lhead(700)], 300) is None),
  ('load-held head queued 3700 s ago (reserved 100 s ago), limit 1600 s: starts', code([run, lhead(3700)], 1600) is None),
  ('load-held head queued 3700 s ago, limit 1790 s (ends past the bound): waits as reserved', code([run, lhead(3700)], 1790) == 'reserved'),
]
for name, good in rows: print(('PASS ' if good else 'FAIL ') + name)
PY
[ "$(wc -l < "$O/w25f.txt" | tr -d ' ')" = 12 ] || { fail "25f: the check printed $(wc -l < "$O/w25f.txt") of 12 lines"; sed 's/^/     /' "$O/w25f.err" | tail -3; }
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "25f: $rest" || fail "25f: $rest"; done < "$O/w25f.txt"
rm -rf "$wf"
# 25g. The limit is kept on a requeue (exec_requeue puts --max-minutes back, in decimal minutes from limit_s) and shown by status.
python3 - "$T" > "$O/w25g.txt" 2>"$O/w25g.err" <<'PY'
import importlib.machinery, importlib.util, sys
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load(sys.argv[1])
seen = []
m.os.execv = lambda exe, argv: seen.append(argv)
rec = {'requeue_peak': 3.0, 'requeue_declared': 1.0, 'requeue_load': 5.0, 'key': 'k', 'limit_s': 120}
m.exec_requeue(rec, ['true'], '/dev/null')
argv = seen[0] if seen else []
ok = '--max-minutes' in argv and float(argv[argv.index('--max-minutes') + 1]) == 2.0
print(('PASS ' if ok else 'FAIL ') + 'a requeued run keeps its limit: --max-minutes 2 from limit_s 120')
rec2 = dict(rec); rec2.pop('limit_s'); seen.clear()
m.exec_requeue(rec2, ['true'], '/dev/null')
print(('PASS ' if seen and '--max-minutes' not in seen[0] else 'FAIL ') + 'a run with no limit is requeued with none')
PY
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "25g: $rest" || fail "25g: $rest"; done < "$O/w25g.txt"
[ "$(wc -l < "$O/w25g.txt" | tr -d ' ')" = 2 ] || fail "25g: the check printed $(wc -l < "$O/w25g.txt") of 2 lines: $(head -2 "$O/w25g.err")"
TESTSLOT_CAP=4 "$T" run --cpus 1 --max-minutes 2 -- bash -c ": wr25g; sleep 4" >/dev/null 2>&1 &
gp=$!
until_true '[ "$(holding light)" = 1 ]' || fail "25g: the limited run never showed as holding"
"$T" status --json | python3 -c "import json,sys; r=json.load(sys.stdin)['running']; sys.exit(not (r and r[0].get('limit_s') == 120 and 0 < r[0].get('limit_left_s', 0) <= 120))" \
  && ok "25g: status --json gives limit_s 120 and the time left" || fail "25g: status --json has no limit: $("$T" status --json | head -c 300)"
"$T" status | grep -q "limit 2m" && ok "25g: status text shows the limit" || fail "25g: status text has no 'limit 2m'"
bwaitp $gp

# 25h. Behind a head the load holds back (cap 20, load cap 10: a 12-cpu head waits behind a 4-cpu holder, as in 10g), a run with
# no limit waits with the code no-limit, and a run with a 3 s limit starts past it and is stopped as in 25a.
: > "$TESTSLOT_DIR/history.jsonl"
H25="env TESTSLOT_CAP=20 TESTSLOT_LOAD_CAP=10 $T"
$H25 run --cpus 4 -- bash -c ": wr25h-holder; sleep 9" >/dev/null 2>&1 &
hh=$!
until_true '[ "$(holding light)" = 1 ]' || fail "25h: the holder never showed as holding"
$H25 run --cpus 12 -- bash -c ": wr25h-head; date +%s.%N > $O/wr25h-head" >/dev/null 2>"$O/wr25h-head.err" &
hhd=$!
until_true 'grep -q "waiting" "$O/wr25h-head.err"' || fail "25h: the load-held head never waited"
$H25 run --cpus 2 -- bash -c ": wr25h-nolimit; date +%s.%N > $O/wr25h-n" >/dev/null 2>"$O/wr25h-n.err" &
hn=$!
until_true 'grep -q "no time limit" "$O/wr25h-n.err"' && ok "25h: behind a load-held head a run with no limit waits, naming the missing limit" || fail "25h: the no-limit run's wait: $(head -1 "$O/wr25h-n.err")"
hcode() { "$T" status --json | python3 -c "import json,sys; w=[j for j in json.load(sys.stdin)['waiting'] if 'wr25h-nolimit' in j['command']]; print(w[0].get('wait_reason') if w else 'none')"; }
until_true '[ "$(hcode)" = no-limit ]' && ok "25h: and its wait_reason is no-limit" || fail "25h: wait_reason is '$(hcode)'"
[ ! -e "$O/wr25h-n" ] && ok "25h: it did not start" || fail "25h: the no-limit run started past the load-held head"
$H25 run --cpus 1 --max-minutes 0.05 -- bash -c ": wr25h-limited; sleep 60" >/dev/null 2>&1 &
hl=$!
bwaitp $hl || fail "25h: the limited run did not end in 30s"
h25=$(wr25 wr25h-limited)
python3 -c "import json,sys; r=json.loads(sys.argv[1]); sys.exit(not (r.get('backfill') is True and r.get('cancelled') is True and r.get('stop_reason') == 'time limit' and 3 <= r.get('run_s', 0) <= 12))" "$h25" \
  && ok "25h: a limited run started past a load-held head is stopped at its limit as a cancel" || fail "25h: the limited run: $h25"
bwaitp $hhd; bwaitp $hn; wait $hh 2>/dev/null
# 25i. The same as 25a and 25b with a 3-cpu head (cap 4, a 2-cpu holder leaves 2 free): a limited run is stopped at its limit
# and the head then starts; a run with no limit waits as no-limit.
: > "$TESTSLOT_DIR/history.jsonl"
TESTSLOT_CAP=4 "$T" run --cpus 2 -- bash -c ": wr25i-holder; sleep 7" >/dev/null 2>&1 &
ih=$!
until_true '[ "$(holding light)" = 1 ]' || fail "25i: the holder never showed as holding"
TESTSLOT_CAP=4 "$T" run --cpus 3 -- bash -c ": wr25i-head; date +%s.%N > $O/wr25i-head" >/dev/null 2>"$O/wr25i-head.err" &
ihd=$!
until_true 'grep -q "waiting" "$O/wr25i-head.err"' || fail "25i: the 3-cpu head never waited"
TESTSLOT_CAP=4 "$T" run --cpus 2 -- bash -c ": wr25i-nolimit; date +%s.%N > $O/wr25i-n" >/dev/null 2>"$O/wr25i-n.err" &
inl=$!
until_true 'grep -q "no time limit" "$O/wr25i-n.err"' && [ ! -e "$O/wr25i-n" ] && ok "25i: behind a 3-cpu head a run with no limit waits" || fail "25i: the no-limit run: $(head -1 "$O/wr25i-n.err")"
TESTSLOT_CAP=4 "$T" run --cpus 1 --max-minutes 0.05 -- bash -c ": wr25i-limited; sleep 60" >/dev/null 2>&1 &
il=$!
bwaitp $il || fail "25i: the limited run did not end in 30s"
i25=$(wr25 wr25i-limited)
python3 -c "import json,sys; r=json.loads(sys.argv[1]); sys.exit(not (r.get('backfill') is True and r.get('cancelled') is True and r.get('stop_reason') == 'time limit'))" "$i25" \
  && ok "25i: a limited run started past a 3-cpu head is stopped at its limit" || fail "25i: the limited run: $i25"
bwaitp $ihd; bwaitp $inl; wait $ih 2>/dev/null
[ -s "$O/wr25i-head" ] && ok "25i: the 3-cpu head started" || fail "25i: the 3-cpu head never started"

# 25j. A bad --max-minutes is a usage error, and the backfill limit reads its file, then the environment, then 30.
bad25=0
for v in 0 -1 nan inf x ""; do "$T" run --max-minutes "$v" -- true >/dev/null 2>"$O/wr25j.err"; [ $? = 2 ] && grep -q "max-minutes" "$O/wr25j.err" || { bad25=1; echo "     (--max-minutes '$v' was taken)"; }; done
[ $bad25 = 0 ] && ok "25j: --max-minutes 0, -1, nan, inf, x and empty are usage errors" || fail "25j: a bad --max-minutes was taken"
wj=$(mktemp -d /tmp/testslot-test.XXXXXX); mkdir -p "$wj/holders"
python3 - "$T" "$wj" > "$O/w25j.txt" 2>"$O/w25j.err" <<'PY'
import importlib.machinery, importlib.util, os, sys
os.environ.pop('TESTSLOT_BACKFILL_LIMIT', None)
os.environ['TESTSLOT_DIR'] = sys.argv[2]
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load(sys.argv[1])
res = [('no file, no env: 30', m.read_backfill_limit() == 30.0)]
os.environ['TESTSLOT_BACKFILL_LIMIT'] = '7'
res.append(('env 7', m.read_backfill_limit() == 7.0))
open(os.path.join(sys.argv[2], 'backfill-limit'), 'w').write('12\n')
res.append(('file 12 beats env 7', m.read_backfill_limit() == 12.0))
for bad in ('0', '-3', 'nan', 'inf', 'x'):
    open(os.path.join(sys.argv[2], 'backfill-limit'), 'w').write(bad + '\n')
    res.append((f'file {bad!r} is ignored (env 7 stands)', m.read_backfill_limit() == 7.0))
for name, good in res: print(('PASS ' if good else 'FAIL ') + name)
PY
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "25j: backfill limit: $rest" || fail "25j: backfill limit: $rest"; done < "$O/w25j.txt"
[ "$(wc -l < "$O/w25j.txt" | tr -d ' ')" = 8 ] || fail "25j: the check printed $(wc -l < "$O/w25j.txt") of 8 lines: $(head -3 "$O/w25j.err")"
rm -rf "$wj"

# 96. testslot-not-set-up-message: a missing state folder is explained with only what the public repo has (make the folder
# with holders/ and logs/, or set TESTSLOT_DIR), and names no script outside it.
out=$(TESTSLOT_DIR="$O/no-such-state-dir" "$T" run --cpus 1 -- true 2>&1); rc=$?
[ "$rc" = 2 ] && ok "96a: a missing state folder exits 2" || fail "96a: a missing state folder exited $rc, not 2"
case $out in *"not set up"*) ok "96b: the message says the folder is not set up";; *) fail "96b: no 'not set up' in: $out";; esac
case $out in *holders*logs*TESTSLOT_DIR*|*TESTSLOT_DIR*holders*logs*) ok "96c: it says to make holders/ and logs/ or set TESTSLOT_DIR";; *) fail "96c: the message names neither the folders nor TESTSLOT_DIR: $out";; esac
case $out in *provision-linux*|*setup-mac*|*agent-tools*) fail "96d: the message names a script or repo outside testslot: $out";; *) ok "96d: the message names no script or repo outside testslot";; esac
case $out in *"make holders/ and logs/ inside it"*) ok "96e: the TESTSLOT_DIR alternative says to make holders/ and logs/ inside the chosen folder";; *) fail "96e: the TESTSLOT_DIR alternative does not say to make holders/ and logs/ inside it: $out";; esac
case $out in *README*g+rws*) ok "96f: it points at the README's sharing steps (group, g+rws)";; *) fail "96f: no pointer to the README's sharing steps in: $out";; esac
# the recovery the message describes works: an owned empty folder is still not set up, and is once holders/ and logs/ are in it
rd="$O/own-state-dir"; mkdir -p "$rd"
TESTSLOT_DIR="$rd" "$T" run --cpus 1 -- true >/dev/null 2>&1; rc1=$?
mkdir -p "$rd/holders" "$rd/logs"
TESTSLOT_DIR="$rd" "$T" run --cpus 1 -- true >/dev/null 2>&1; rc2=$?
[ "$rc1" = 2 ] && [ "$rc2" = 0 ] && ok "96g: an owned folder fails until holders/ and logs/ are made in it, then runs" || fail "96g: owned folder exit codes were $rc1 then $rc2, not 2 then 0"

# 97. Contributor kit (testslot-contrib-kit): the files exist beside the tool, name nothing from the project they were
# copied from, and the YAML ones load. An installed copy has no README beside it, so the case skips there.
d=$(dirname "$T")
if [ -f "$d/README.md" ]; then
  kit="CONTRIBUTING.md SECURITY.md .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/idea.yml .github/ISSUE_TEMPLATE/config.yml .github/workflows/ci.yml .github/dependabot.yml"
  miss=; for f in $kit; do [ -s "$d/$f" ] || miss="$miss $f"; done
  [ -z "$miss" ] && ok "97a: every contributor kit file exists" || fail "97a: kit files missing:$miss"
  if [ -z "$miss" ]; then
    src=neck; src=${src}beard   # the project the forms were copied from, spelled so this file does not name it
    n=$(cd "$d" && grep -rli "$src" $kit | tr '\n' ' ')
    [ -z "$n" ] && ok "97b: no kit file names the project it was copied from" || fail "97b: kit files naming the source project: $n"
    cl=$(wc -l < "$d/CONTRIBUTING.md"); [ "$cl" -ge 10 ] && [ "$cl" -le 15 ] && ok "97c: CONTRIBUTING.md is 10 to 15 lines" || fail "97c: CONTRIBUTING.md is $cl lines"
    yl="$d/.github/ISSUE_TEMPLATE/bug_report.yml $d/.github/ISSUE_TEMPLATE/idea.yml $d/.github/ISSUE_TEMPLATE/config.yml $d/.github/workflows/ci.yml $d/.github/dependabot.yml"
    if python3 -c 'import yaml' 2>/dev/null; then
      python3 -c 'import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]' $yl && ok "97d: the kit's YAML files load" || fail "97d: a kit YAML file does not load"
    elif command -v ruby >/dev/null 2>&1; then
      ruby -ryaml -e 'ARGV.each { |f| YAML.safe_load(File.read(f)) }' $yl && ok "97d: the kit's YAML files load" || fail "97d: a kit YAML file does not load"
    else echo "skip 97d (no YAML parser: python3 yaml or ruby)"; fi
    grep -q 'id: example' "$d/.github/ISSUE_TEMPLATE/idea.yml" && ok "97f: idea.yml asks for an example (the source form's example field, in testslot's words)" || fail "97f: idea.yml has no example field"
    grep -q 'bash test.sh ./testslot' "$d/.github/workflows/ci.yml" && ok "97e: ci.yml runs bash test.sh ./testslot" || fail "97e: ci.yml does not run bash test.sh ./testslot"
  fi
else
  echo "skip 97 (no README.md beside the tool: an installed copy)"
fi

# 98. Public release: testslot/LICENSE is the MIT text skills-for-agents ships, and the README links it.
# The files sit beside the tool; an installed copy has no README, so the case skips there.
d=$(dirname "$T")
if [ -f "$d/README.md" ]; then
  want=2d0c56ecde491da5f63660e904fc924fcb6d107a69877284a32b660f1f2dfd29
  got=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$d/LICENSE" 2>/dev/null)
  [ "$got" = "$want" ] && ok "98a: LICENSE is the MIT text" || fail "98a: LICENSE sha256 is '${got:-missing}', not the MIT text"
  grep -qx '## License' "$d/README.md" && grep -qF '[LICENSE](./LICENSE)' "$d/README.md" \
    && ok "98b: README has a License section linking ./LICENSE" || fail "98b: README has no License section linking ./LICENSE"
  # 98c: the front page reads in order for a stranger: eight headings, in this order.
  got=$(grep -E '^#{2} ' "$d/README.md" | sed 's/^## //' | paste -sd, -)
  want="Quick start,Usage,Sharing across accounts,How it works,Requirements,Running the tests,Specification,License"
  [ "$got" = "$want" ] && ok "98c: README headings are $want" || fail "98c: README headings are '$got', want '$want'"
  # 98e: the Quick start runs `make install` and quotes the line it prints, which puts .local/bin on PATH and sets TESTSLOT_DIR
  # (the quoted lines are checked against the real output in 100j).
  qs=$(awk '/^## Quick start/{f=1;next} /^## /{f=0} f' "$d/README.md")
  if printf '%s\n' "$qs" | grep -qx 'make install' && printf '%s\n' "$qs" | grep -qE '^export PATH="[^"]*/\.local/bin:\$PATH" TESTSLOT_DIR="[^"]+"$'; then
    ok "98e: README's Quick start runs make install and quotes the line it prints"
  else fail "98e: README's Quick start has no 'make install' line, or no quoted export of .local/bin onto PATH with TESTSLOT_DIR"; fi
  # 98g: CHANGELOG.md sits beside the README, and the README links it.
  [ -s "$d/CHANGELOG.md" ] && grep -qF '[CHANGELOG.md](./CHANGELOG.md)' "$d/README.md" && grep -qF '[Changelog](./CHANGELOG.md)' "$d/README.md" \
    && ok "98g: CHANGELOG.md exists and the README links it twice" || fail "98g: CHANGELOG.md is missing or empty, or the README does not link it at the top and in the License paragraph"
  # 98f: the README opens with the logo: a first-line <img> whose src is images/logo.png, with an alt text, and the file exists.
  first=$(head -1 "$d/README.md")
  if printf '%s' "$first" | grep -qE '^<img src="images/logo\.png" alt="[^"]+"' && [ -f "$d/images/logo.png" ]; then
    ok "98f: README opens with the logo image"
  else fail "98f: README's first line is not an <img> of images/logo.png with an alt text (or the file is missing): $first"; fi
  # 98d: the README names no word from the owner's private-word list. The list lives outside the repo (GUARD_WORDS, one word
  # a line, blank and # lines skipped, a whole word matched as written, as in the other public repos' guard); none is written here.
  if [ -z "${GUARD_WORDS:-}" ]; then
    echo "skip 98d (no GUARD_WORDS list, so no private word was checked in the README)"
  elif [ ! -f "$GUARD_WORDS" ] || [ ! -r "$GUARD_WORDS" ]; then
    fail "98d: can't read the private-word list GUARD_WORDS names"
  else
    tr -d '\r' < "$GUARD_WORDS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -vE '^(#|$)' > "$O/guardwords"
    if [ ! -s "$O/guardwords" ]; then fail "98d: the private-word list holds no words"
    elif grep -n -w -F -f "$O/guardwords" "$d/README.md" > "$O/guardhits"; then
      fail "98d: README names a private word: $(cut -c1-80 "$O/guardhits" | head -3 | paste -sd' ' -)"
    else ok "98d: README names no private word"; fi
  fi
else
  echo "skip 98 (no README.md beside the tool: an installed copy)"
fi

# 99. Regression cases for bugs found by the TLA+ model (spec/); no opt-in gate is required.
# The exit-before-reap race is fixed on Linux; macOS still uses the old returncode check.
  # A past bug (fixed on Linux; model property CancelNotFailure, TLC trace in spec/README.md): a command that has
  # exited on its own, and a wrapper that has not reaped it yet, then `testslot stop`. Before the fix, forward() tested
  # proc.returncode, which only the wrapper's wait() set, so the stop was recorded as a cancel (exit 143) for a command that finished by
  # itself. Reached by stopping the wrapper (SIGSTOP, as Ctrl-Z would), letting the command exit 0 while a child keeps the
  # group alive (so `stop` has something to stop), then stopping the run. The command's own code should stand.
  linux && {
    "$T" run -- bash -c "sleep 31 & sleep 3; exit 0" >/dev/null 2>&1 &
    z=$!; until_true '[ "$(holding light)" = 1 ]'
    zp=$(pgid_of light)
    kill -STOP $z
    until_true '[ "$(ps -o stat= -p $zp 2>/dev/null | cut -c1)" = Z ]' || fail "99a: the command never exited"
    "$T" stop "$zp" >"$O/known1.out" 2>&1; kill -CONT $z 2>/dev/null
    bwaitp $z || fail "99a: the stopped run did not end in 30s"; c=$bwc
    pkill -g "$zp" 2>/dev/null   # only this run's group
    [ $c = 0 ] && ok "a stop after the command exited by itself leaves its code 0" || fail "a stop after the command exited by itself changed its code to $c"
  } || skip "99a: stop after exit"

# 100. Install targets (testslot-install-targets): `make install` and `make install-shared`, only ever into a scratch
# folder here (PREFIX, STATE and SHARED), never a real system folder. The Makefile sits beside the tool; an installed copy has none.
d=$(dirname "$T")
if [ -f "$d/Makefile" ] && command -v make >/dev/null; then
  I=$O/inst; mkdir -p "$I"
  mk() { make -s -C "$d" "$@"; }
  mk install PREFIX="$I/prefix" STATE="$I/state" > "$I/out1" 2>&1; c=$?
  [ $c = 0 ] && [ -x "$I/prefix/bin/testslot" ] && cmp -s "$d/testslot" "$I/prefix/bin/testslot" \
    && ok "100a: make install puts an identical executable copy in PREFIX/bin" || fail "100a: make install (exit $c) did not put an identical executable copy in PREFIX/bin"
  [ -d "$I/state/holders" ] && [ -d "$I/state/logs" ] \
    && ok "100b: make install makes the state folder with holders/ and logs/" || fail "100b: make install did not make STATE/holders and STATE/logs"
  want="export PATH=\"$I/prefix/bin:\$PATH\" TESTSLOT_DIR=\"$I/state\""
  grep -qxF "$want" "$I/out1" \
    && ok "100c: make install prints the exact export line" || fail "100c: make install printed no line '$want': $(head -c 300 "$I/out1" | paste -sd'|' -)"
  mk install PREFIX="$I/prefix" STATE="$I/state" > "$I/out2" 2>&1; c=$?
  [ $c = 0 ] && cmp -s "$I/out1" "$I/out2" \
    && ok "100d: a second make install exits 0 and prints the same" || fail "100d: the second make install (exit $c) differs: $(head -c 300 "$I/out2" | paste -sd'|' -)"
  out=$(TESTSLOT_DIR="$I/state" "$I/prefix/bin/testslot" run --cpus 1 -- echo ok 2>/dev/null)
  [ "$out" = ok ] && ok "100e: the installed copy runs the check and prints ok" || fail "100e: the installed copy printed '$out', not ok"
  S=$I/shared
  mk install-shared SHARED="$S" > "$I/sh0.out" 2> "$I/sh0.err"; c=$?
  [ $c != 0 ] && [ "$(wc -l < "$I/sh0.err" | tr -d ' ')" = 1 ] && grep -q "usage: .*GROUP=" "$I/sh0.err" && [ ! -e "$S" ] \
    && ok "100f: install-shared without GROUP refuses with a one-line usage and changes nothing" \
    || fail "100f: install-shared without GROUP (exit $c) gave '$(paste -sd'|' "$I/sh0.err" | head -c 200)' or made $S"
  g=$(id -gn)
  mk install-shared GROUP="$g" SHARED="$S" > "$I/sh1.out" 2>&1; c=$?
  python3 - "$S" "$g" <<'PY' && shok=1 || shok=0
import grp, os, sys
s, g = sys.argv[1], sys.argv[2]
for p in (s, s + "/holders", s + "/logs"):
    st = os.stat(p)
    assert grp.getgrgid(st.st_gid).gr_name == g, (p, "group")
    assert st.st_mode & 0o2060 == 0o2060, (p, oct(st.st_mode))   # g+rws: group read, write, setgid
PY
  [ $c = 0 ] && [ $shok = 1 ] \
    && ok "100g: install-shared GROUP= makes the shared folder with holders/ and logs/, in the group, g+rws" \
    || fail "100g: install-shared GROUP=$g (exit $c, folder ok=$shok): $(head -c 300 "$I/sh1.out" | paste -sd'|' -)"
  grep -qxF "export TESTSLOT_DIR=\"$S\"" "$I/sh1.out" \
    && ok "100h: install-shared prints the TESTSLOT_DIR line for each account" || fail "100h: install-shared printed no TESTSLOT_DIR line for $S"
  mk install-shared GROUP="$g" SHARED="$S" > "$I/sh2.out" 2>&1 && cmp -s "$I/sh1.out" "$I/sh2.out" \
    && ok "100i: a second install-shared exits 0 and prints the same" || fail "100i: the second install-shared differs or failed"
  # 100j and 100k: the README's quoted output is what the targets really print (paths and the group name swapped for the README's
  # example user, folder and group). Only where the README sits beside the tool.
  if [ -f "$d/README.md" ]; then
    H=$I/alice; mkdir -p "$H"
    real=$(HOME="$H" make -s -C "$d" install 2>&1 | sed "s#$H#/home/alice#g")
    quoted=$(grep -E '^(Installed testslot in |Add this line to your shell profile \(and run|export PATH=.* TESTSLOT_DIR=)' "$d/README.md")
    [ -n "$quoted" ] && [ "$real" = "$quoted" ] && ok "100j: the README quotes what make install really prints" \
      || fail "100j: the README's quoted make install output differs from the real one: real '$(printf %s "$real" | paste -sd'|' -)' quoted '$(printf %s "$quoted" | paste -sd'|' -)'"
    S2=$I/shared2
    real=$(make -s -C "$d" install-shared GROUP="$g" SHARED="$S2" 2>&1 | sed "s#$S2#/var/lib/testslot#g; s#the group $g\.#the group testers.#")
    quoted=$(grep -E '^(Made the shared state folder |Each account adds this line|export TESTSLOT_DIR="/var/lib/testslot"$)' "$d/README.md")
    [ -n "$quoted" ] && [ "$real" = "$quoted" ] && ok "100k: the README quotes what make install-shared really prints" \
      || fail "100k: the README's quoted make install-shared output differs from the real one: real '$(printf %s "$real" | paste -sd'|' -)' quoted '$(printf %s "$quoted" | paste -sd'|' -)'"
  fi
else
  echo "skip 100 install targets (no Makefile beside the tool, or no make)"
fi

# 101. The package (testslot-package-split): the code is lib/testslot/*.py behind a short entry script, and make install swaps it in
# without a moment of no testslot. Scratch folders only. The tree checks need the checkout (lib/ and Makefile beside the tool).
d=$(dirname "$T")
if [ -f "$d/Makefile" ] && [ -d "$d/lib/testslot" ] && command -v make >/dev/null; then
  # 101a to 101c: the shape of the tree (the entry script under 40 lines, no module over 600, standard library only, nothing
  # imported inside a function, no cycle between modules, and util imports nothing from the package).
  python3 -I - "$d" > "$O/shape.txt" 2>&1 <<'PY'
import ast, glob, os, sys
d = sys.argv[1]
bad = []
n = len(open(os.path.join(d, "testslot")).read().splitlines())
print("entry %d lines" % n)
if n >= 40: bad.append("101a: the entry script is %d lines, not under 40" % n)
std = set("datetime fcntl getpass hashlib json math os pwd re shutil signal subprocess sys threading time traceback".split())
mods = sorted(os.path.basename(f)[:-3] for f in glob.glob(os.path.join(d, "lib", "testslot", "*.py")) if not f.endswith("__init__.py"))
deps = {}
for m in mods:
    path = os.path.join(d, "lib", "testslot", m + ".py"); src = open(path).read(); t = ast.parse(src)
    if len(src.splitlines()) > 600: bad.append("101a: %s.py has %d lines, over 600" % (m, len(src.splitlines())))
    deps[m] = set()
    for node in ast.walk(t):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            top = node.col_offset == 0
            names = [a.name for a in node.names]
            if not top: bad.append("101b: %s.py imports inside a function (line %d)" % (m, node.lineno))
            if isinstance(node, ast.ImportFrom):
                if node.module != "testslot": bad.append("101b: %s.py: from %s import (line %d)" % (m, node.module, node.lineno))
                deps[m] |= set(names)
            else:
                for x in names:
                    if x.split(".")[0] not in std: bad.append("101b: %s.py imports %s, not the standard library" % (m, x))
if deps.get("util"): bad.append("101c: util imports from the package: %s" % sorted(deps["util"]))
state = {}
def visit(u, path):
    if u in path: bad.append("101c: import cycle %s" % " -> ".join(path[path.index(u):] + [u])); return
    if state.get(u): return
    state[u] = 1
    for v in sorted(deps.get(u, ())): visit(v, path + [u])
for m in mods: visit(m, [])
print("\n".join(bad) if bad else "ALL OK")
PY
  if grep -q '^ALL OK' "$O/shape.txt"; then
    ok "101a: the entry script is under 40 lines and no module is over 600"; ok "101b: modules import only the standard library, none inside a function"; ok "101c: no import cycle, and util imports nothing from the package"
  else
    for c in 101a 101b 101c; do grep -q "^$c" "$O/shape.txt" && fail "$(grep "^$c" "$O/shape.txt" | head -2 | paste -sd'|' -)" || ok "$c: shape check passed"; done
  fi
  # 101d: make install twice leaves one code folder and one link; over an old single-file install it replaces the file in one rename
  P=$I/pk; mkdir -p "$P/bin"; printf '#!/bin/sh\necho old\n' > "$P/bin/testslot"; chmod 755 "$P/bin/testslot"
  mk install PREFIX="$P" STATE="$P/st" > "$P/out1" 2>&1; c1=$?
  mk install PREFIX="$P" STATE="$P/st" > "$P/out2" 2>&1; c2=$?
  n=$(ls -d "$P"/lib/testslot-* 2>/dev/null | wc -l | tr -d ' ')
  if [ $c1 = 0 ] && [ $c2 = 0 ] && [ -L "$P/bin/testslot" ] && [ "$n" = 1 ] && [ "$(ls -A "$P/bin" | tr '\n' ' ')" = "testslot " ] && cmp -s "$P/out1" "$P/out2" \
     && [ "$(ls -A "$P/lib" | grep -c tmp)" = 0 ]; then
    ok "101d: make install over an old single-file install, twice: one link, one code folder, nothing of the old file, same output"
  else fail "101d: install over an old file (exit $c1/$c2): link=$([ -L "$P/bin/testslot" ] && echo y || echo n) folders=$n bin=[$(ls -A "$P/bin" | tr '\n' ' ')]"; fi
  # 101e: the installed testslot runs from another folder, and through a link of its own in another folder
  mkdir -p "$I/elsewhere"; ln -s "$P/bin/testslot" "$I/elsewhere/ts-link"
  out=$(cd / && TESTSLOT_DIR="$P/st" "$P/bin/testslot" run --cpus 1 -- echo ok 2>/dev/null)
  out2=$(cd "$I/elsewhere" && TESTSLOT_DIR="$P/st" ./ts-link run --cpus 1 -- echo ok2 2>/dev/null)
  [ "$out" = ok ] && [ "$out2" = ok2 ] && ok "101e: the installed command runs from another folder, and through a link in another folder" \
    || fail "101e: installed command printed '$out' and through a link '$out2'"
  # 101f: two more installs of changed code keep the current folder and the one before it, and drop the older
  V=$I/tree2; mkdir -p "$V"; cp -R "$d/Makefile" "$d/testslot" "$d/lib" "$V/"; find "$V" -name __pycache__ -prune -exec rm -r {} + 2>/dev/null
  echo "# v2" >> "$V/lib/testslot/util.py"; make -s -C "$V" install PREFIX="$P" STATE="$P/st" >/dev/null 2>&1
  echo "# v3" >> "$V/lib/testslot/util.py"; make -s -C "$V" install PREFIX="$P" STATE="$P/st" >/dev/null 2>&1
  n=$(ls -d "$P"/lib/testslot-* 2>/dev/null | wc -l | tr -d ' ')
  tgt=$(readlink "$P/bin/testslot"); h3=$(basename "$(dirname "$tgt")")
  [ "$n" = 2 ] && [ -x "$P/lib/$h3/testslot" ] && grep -q '^# v3' "$P/lib/$h3/lib/testslot/util.py" \
    && ok "101f: three installs of changing code leave the current folder and the one before" || fail "101f: $n code folders after three installs, link to $tgt"
  # 101g: an install while a run holds a slot: the run finishes, frees its slot, and the new code is what starts next
  echo "# v4" >> "$V/lib/testslot/util.py"
  hb=$(grep -c '"exit": 7' "$P/st/history.jsonl" 2>/dev/null); hb=${hb:-0}
  TESTSLOT_DIR="$P/st" "$P/bin/testslot" run --cpus 1 -- bash -c 'sleep 4; exit 7' >/dev/null 2>"$P/g.err" &
  rp=$!; sleep 1.5
  make -s -C "$V" install PREFIX="$P" STATE="$P/st" >/dev/null 2>&1; ic=$?
  wait $rp; rc=$?
  left=$(ls "$P/st/holders" 2>/dev/null | wc -l | tr -d ' ')
  out=$(TESTSLOT_DIR="$P/st" "$P/bin/testslot" run --cpus 1 -- echo after 2>/dev/null)
  ha=$(grep -c '"exit": 7' "$P/st/history.jsonl" 2>/dev/null); ha=${ha:-0}
  # the exit code and the empty holders folder are not enough: the holder is unlinked before the history line is written, so a run
  # that lost its code at the end would still exit 7. Its stderr must hold no error, and its history line must be written.
  [ $ic = 0 ] && [ $rc = 7 ] && [ "$left" = 0 ] && [ "$out" = after ] && ! grep -q '^testslot error' "$P/g.err" && [ "$ha" = $((hb + 1)) ] \
    && ok "101g: an install during a run: the run ended with its own exit code 7, freed its slot, wrote its history line with no error, and the next run starts on the new code" \
    || fail "101g: install exit $ic, run exit $rc (want 7), holders left $left, next run printed '$out', history lines with exit 7 $hb -> $ha, stderr: $(head -c 160 "$P/g.err" | paste -sd'|' -)"
  # 101h: an internal error names the line in the module where it happened, as it named a line of the one file before
  TESTSLOT_TEST_CRASH=boom "$T" status >/dev/null 2>"$O/crash2.err"
  grep -qE '^testslot error: RuntimeError: boom \(line [0-9]+\)$' "$O/crash2.err" \
    && ok "101h: an internal error prints the error and a line number from the package" || fail "101h: the internal error line was: $(head -c 200 "$O/crash2.err")"
  # 101i: running from the checkout leaves no bytecode behind
  "$T" --help >/dev/null 2>&1
  [ -z "$(find "$d/lib" -name __pycache__ 2>/dev/null | head -1)" ] && ok "101i: no __pycache__ in the checkout after running it" || fail "101i: a __pycache__ folder sits under lib/"
else
  echo "skip 101 package checks (no Makefile or lib/ beside the tool, or no make)"
fi

# 102. The history line carries testslot's own error (testslot-history-records-errors). A run testslot broke after it was admitted
# records `error` (the text after "testslot error: ", without the "(line N)"), and `exit` is the command's own code when the command had
# ended (null when it never started). A run with no error of its own has no `error` field. hist_field prints one field of the last
# history line as JSON, or <absent>; hist_find prints it for the last line whose command holds a word.
hist_field() { python3 - "$TESTSLOT_DIR/history.jsonl" "$1" "${2:-}" <<'PY'
import json, sys
last = None
for l in open(sys.argv[1]):
    l = l.strip()
    if l:
        d = json.loads(l)
        if not sys.argv[3] or sys.argv[3] in (d.get("command") or ""):
            last = d
print(json.dumps(last.get(sys.argv[2], "<absent>") if last else "<noline>"))
PY
}
# 102a and 102b: the crash after the command ended (the after-wait hook): the line has exit 3 and the same text the stderr line prints
: > "$TESTSLOT_DIR/history.jsonl"
TESTSLOT_TEST_CRASH=after-wait "$T" run --cpus 1 -- bash -c "exit 3" >/dev/null 2>"$O/h102a.err"; c=$?
[ "$c" = 3 ] && [ "$(hist_field exit)" = 3 ] && ok "102a: an after-wait crash: the process exits 3 and the history line has exit 3 (null before this item)" \
  || fail "102a: process exit $c, history exit $(hist_field exit)"
want=$(sed -n 's/^testslot error: \(.*\) (line [0-9]*)$/\1/p' "$O/h102a.err")
[ -n "$want" ] && [ "$(hist_field error)" = "\"$want\"" ] && ok "102b: the history line's error is the text of the stderr line, without its (line N)" \
  || fail "102b: stderr says '$want', history error $(hist_field error)"
# 102c: the crash after admission and before the command starts: the command never runs, exit null, and the error is recorded
: > "$TESTSLOT_DIR/history.jsonl"; rm -f "$O/h102c.ran"
TESTSLOT_TEST_CRASH=after-admit "$T" run --cpus 1 -- bash -c "touch $O/h102c.ran" >/dev/null 2>"$O/h102c.err"; c=$?
[ "$c" = 70 ] && [ ! -e "$O/h102c.ran" ] && [ "$(hist_field exit)" = null ] && [ "$(hist_field error)" = '"RuntimeError: after admission, before the command"' ] \
  && ok "102c: a crash after admission and before the command: exit 70, the command never ran, history exit null with the error" \
  || fail "102c: process exit $c, ran $([ -e "$O/h102c.ran" ] && echo yes || echo no), history exit $(hist_field exit) error $(hist_field error)"
# 102d: the group outlived the kill (the keep-holder hook): the holder record stays, and the next run's prune writes the line with exit and error
: > "$TESTSLOT_DIR/history.jsonl"
TESTSLOT_TEST_KEEP_HOLDER=1 TESTSLOT_TEST_CRASH=after-wait "$T" run --cpus 1 -- bash -c "exit 7" >/dev/null 2>&1; c=$?
[ -n "$(ls "$TESTSLOT_DIR/holders" 2>/dev/null)" ] && [ "$(hist_field exit)" = '"<noline>"' ] || fail "102d: expected a kept holder and no line yet (holders: $(ls "$TESTSLOT_DIR/holders" | tr '\n' ' '), line: $(hist_field exit))"
"$T" run --cpus 1 -- true >/dev/null 2>&1
[ "$c" = 7 ] && [ "$(hist_field exit 'exit 7')" = 7 ] && [ "$(hist_field error 'exit 7')" = '"RuntimeError: after the command ended"' ] \
  && ok "102d: prune writes the kept run's line with exit 7 and the error" || fail "102d: process exit $c, line exit $(hist_field exit 'exit 7') error $(hist_field error 'exit 7')"
# 102e: guard: a run with no testslot error has no error field, and a crash before admission writes no line, as before
: > "$TESTSLOT_DIR/history.jsonl"
"$T" run --cpus 1 -- bash -c "exit 4" >/dev/null 2>&1
[ "$(hist_field exit)" = 4 ] && [ "$(hist_field error)" = '"<absent>"' ] && ok "102e: a run with no testslot error has exit 4 and no error field" || fail "102e: exit $(hist_field exit), error $(hist_field error)"
: > "$TESTSLOT_DIR/history.jsonl"
TESTSLOT_TEST_CRASH=boom "$T" run --cpus 1 -- true >/dev/null 2>&1
[ "$(hist_field exit)" = '"<noline>"' ] && ok "102f: a crash before admission writes no history line" || fail "102f: a line was written: exit $(hist_field exit)"
# 102g: an internal error in the cleanup after the command (the in-cleanup hook) is recorded too: the process keeps the command's
# code and prints the line, the record is kept, and the next prune writes exit 6 and the error
: > "$TESTSLOT_DIR/history.jsonl"
TESTSLOT_TEST_CRASH=in-cleanup "$T" run --cpus 1 -- bash -c "exit 6" >/dev/null 2>"$O/h102g.err"; c=$?
"$T" run --cpus 1 -- true >/dev/null 2>&1
[ "$c" = 6 ] && grep -q '^testslot error: RuntimeError: in the cleanup' "$O/h102g.err" && [ "$(hist_field exit 'exit 6')" = 6 ] \
  && [ "$(hist_field error 'exit 6')" = '"RuntimeError: in the cleanup"' ] \
  && ok "102g: an error in the cleanup is recorded: the process exits 6 and prints it, and prune writes exit 6 and the error" \
  || fail "102g: process exit $c, line exit $(hist_field exit 'exit 6') error $(hist_field error 'exit 6'); stderr: $(head -c 160 "$O/h102g.err")"
# 102h: the error text in a history line is cut to 500 characters (prune writes lines from any account's holder file)
dd=$(cd "$(dirname "$T")" && pwd)
if [ -d "$dd/lib/testslot" ]; then
  n=$(python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from testslot import state; print(len(state.history_line({"since": 1, "error": "x" * 10000}, 2, 0)["error"]))' "$dd/lib" 2>&1)
  [ "$n" = 500 ] && ok "102h: a 10000-character error is cut to 500 in the history line" || fail "102h: the error field was $n characters long"
fi

# 103. The load pause waits for load to settle (testslot-pause-settle): at most one load pause and one load resume per window
# across the host, the newest pause resuming first. TESTSLOT_TEST_CLOCK names a file holding the time every pause read uses
# (frozen between steps, so nothing here waits a real window); the state is $TESTSLOT_DIR/pause-window-state.
P=$O/tspause.py
cat > "$P" <<'PY'
import importlib.machinery, importlib.util, sys, time, os, json
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load(sys.argv[1])
def check(ok, what): print(("PASS " if ok else "FAIL ") + what)
D = os.environ["TESTSLOT_DIR"]
def window(env=None, file=None):
    for k in ("TESTSLOT_PAUSE_WINDOW",):
        os.environ.pop(k, None)
    f = os.path.join(D, "pause-window")
    if os.path.exists(f): os.unlink(f)
    if env is not None: os.environ["TESTSLOT_PAUSE_WINDOW"] = env
    if file is not None: open(f, "w").write(file + "\n")
    try: return m.read_pause_window()
    finally:
        os.environ.pop("TESTSLOT_PAUSE_WINDOW", None)
        if os.path.exists(f): os.unlink(f)
check(window() == 30, "103a: no setting: the window is 30 s")
check(window(file="10") == 10, "103a: a pause-window file of 10 gives 10")
check(window(file="1000") == 300, "103a: 1000 clamps to 300")
check(window(file="1") == 5, "103a: 1 clamps to 5")
check(window(env="20", file="10") == 20, "103a: TESTSLOT_PAUSE_WINDOW beats the file")
check(window(env="1000", file="10") == 300, "103a: the environment value is clamped too")
check(window(env="junk", file="12") == 12, "103a: a bad environment value falls through to the file")
check(window(file="junk") == 30, "103a: a bad file falls through to the default")
st = os.path.join(D, "pause-window-state")
if os.path.exists(st): os.unlink(st)
c = m.window_claim
check(c("pause", 30, 1000.0) is True, "103b: the first pause is allowed")
check(c("pause", 30, 1029.0) is False, "103b: a second pause 29 s later is refused")
check(c("pause", 30, 1030.0) is True, "103b: a second pause 30 s later is allowed")
check(c("resume", 30, 1031.0) is True, "103b: a resume is a window of its own: a pause just before does not hold it")
check(c("resume", 30, 1040.0) is False, "103b: a second resume 9 s later is refused")
check(json.load(open(st)) == {"pause": 1030.0, "resume": 1031.0}, "103b: pause-window-state holds the last pause and the last resume")
check(c("pause", 30, 500.0) is True, "103b: a clock that went back is outside the window")
check(os.path.exists(os.path.join(D, "pause.lock")), "103b: the window is read and written under pause.lock")
lk = os.path.join(D, "pause.lock"); os.unlink(lk); os.mkdir(lk)   # a lock that can't be opened: the throttle thread must not die
check(m.window_claim_safe("pause", 30, 9000.0) is False and m.window_claim_safe("resume", 30, 9000.0) is True, "103b: a lock that can't be opened: no pause is taken, a resume is")
os.rmdir(lk)
def h(pid, since, **kw):
    d = {"pid": pid, "load_paused_since": since, "orphan": False}; d.update(kw); return d
n = m.newest_paused
check(n([h(1, 100.0), h(2, 300.0), h(3, 200.0)])["pid"] == 2, "103c: the newest load pause is chosen")
check(n([h(1, 100.0), h(2, 300.0, orphan=True)])["pid"] == 1, "103c: an orphan is skipped, so a dead record never blocks a resume")
check(n([h(1, None), h(2, None)]) is None, "103c: no load-paused run: none")
check(n([h(1, 100.0, paused_since=50.0), h(2, None)])["pid"] == 1, "103c: a run held by both pauses still counts")
ck = os.path.join(D, "clock-unit"); open(ck, "w").write("5000\n"); m.TEST_CLOCK = ck
check(m.now() == 5000.0, "103c: the clock seam gives the time in its file")
check(m.pausing({"resumed_at": 5000.0}) is True and m.pausing({"resumed_at": 4000.0}) is False, "103c: pausing() reads the seam's time, not the wall clock")
m.TEST_CLOCK = ""; os.unlink(ck)
check(abs(m.now() - time.time()) < 5, "103c: with no seam, the wall clock")
PY
python3 "$P" "$T" > "$O/tspause.txt" 2>"$O/tspause.err"
[ -s "$O/tspause.txt" ] || { fail "103a: the unit checks did not run"; sed 's/^/     /' "$O/tspause.err"; }
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "$rest" || fail "$rest"; done < "$O/tspause.txt"
rm -f "$TESTSLOT_DIR/pause-window-state" "$TESTSLOT_DIR/pause.lock"

oldcap=$(cat "$TESTSLOT_DIR/cap" 2>/dev/null); echo 6 > "$TESTSLOT_DIR/cap"
unset TESTSLOT_OBSERVED TESTSLOT_START_RATE_CAP TESTSLOT_FAKE_START_RATE TESTSLOT_PAUSE_WINDOW
export TESTSLOT_SAMPLE_S=0.5 TESTSLOT_OBSERVED_DIR=$O/obsdir103 TESTSLOT_FAKE_START_RATE=$O/rate103; echo 0 > "$O/rate103"
rm -rf "$O/obsdir103"; mkdir -p "$O/obsdir103"; rm -f "$TESTSLOT_DIR/pause-window"
CK=$O/clock103; echo 1000000 > "$CK"; export TESTSLOT_TEST_CLOCK=$CK
held() { [ -n "$1" ] && [ "$(lstate "$1")" = T ]; }
going() { [ -n "$1" ] && [ -n "$(lstate "$1")" ] && [ "$(lstate "$1")" != T ]; }   # alive and not stopped: false for a run that never started
clk() { echo "$1" > "$CK.tmp" && mv "$CK.tmp" "$CK"; }   # atomic: a tick must never read a half-written clock
wst() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ''))" "$TESTSLOT_DIR/pause-window-state" "$1" 2>/dev/null; }
echo "0.50 0.50 0.50 1/100 1" > "$TESTSLOT_LOADAVG"
# A, B and C over-use (4, 3 and 2 cpus of 1 declared), D is honest (a guard: it is never paused)
for n in A B C D; do "$T" run --cpus 1 -- bash -c ": settle$n.$$; sleep 120" >/dev/null 2>"$O/st$n.err" & eval "sp$n=\$!"; done
for n in A B C D; do until_long '[ -n "$(rpg "settle$n.$$")" ]' || fail "103d: run $n never showed as running"; eval "sg$n=\$(rpg \"settle$n.$$\")"; done
echo 4 > "$O/obsdir103/$sgA"; echo 3 > "$O/obsdir103/$sgB"; echo 2 > "$O/obsdir103/$sgC"; echo 1 > "$O/obsdir103/$sgD"
sleep 2
# 103d. a held trigger and three over-users: one pause now, the next one a window after it, the third a window after that
echo "1000.00 5.00 5.00 1/100 1" > "$TESTSLOT_LOADAVG"
until_long 'held $sgA' && ok "103d: the worst over-user is paused" || fail "103d: A was not paused, state '$(lstate "$sgA")'"
sleep 3
going $sgB && going $sgC && ok "103d: with the trigger held, no second or third run is paused inside the window" || fail "103d: B '$(lstate "$sgB")', C '$(lstate "$sgC")' (the clock has not moved)"
num "$(wst pause)" == 1000000 && ok "103d: pause-window-state records the pause time" || fail "103d: state pause '$(wst pause)'"
clk 1000029; sleep 3
going $sgB && ok "103d: 29 s later the second run is still not paused" || fail "103d: B paused at 29 s"
clk 1000030
until_long 'held $sgB' && ok "103d: 30 s later the next over-user is paused" || fail "103d: B was not paused after the window, state '$(lstate "$sgB")'"
num "$(wst pause)" == 1000030 && ok "103d: the two recorded pauses are 30 s apart (the default window)" || fail "103d: state pause '$(wst pause)'"
sleep 3
going $sgC && ok "103d: the third over-user is not paused inside the second window" || fail "103d: C paused with the clock still"
clk 1000060
until_long 'held $sgC' && ok "103d: one more window on, the third is paused" || fail "103d: C was not paused, state '$(lstate "$sgC")'"
going $sgD && ok "103d: the honest run is never paused" || fail "103d: D was paused"
# 103e. load falls with A, B and C paused: newest pause first (C, B, A), a window apart
echo "0.50 5.00 5.00 1/100 1" > "$TESTSLOT_LOADAVG"
until_long 'going $sgC' && ok "103e: the newest-paused run resumes first" || fail "103e: C still stopped"
sleep 3
held $sgB && held $sgA && ok "103e: the older pauses stay held inside the window" || fail "103e: A '$(lstate "$sgA")', B '$(lstate "$sgB")' resumed with the clock still"
num "$(wst resume)" == 1000060 && ok "103e: pause-window-state records the resume time" || fail "103e: state resume '$(wst resume)'"
clk 1000089; sleep 3
held $sgB && ok "103e: 29 s after the first resume the next is still held" || fail "103e: B resumed at 29 s"
clk 1000090
until_long 'going $sgB' && ok "103e: one window after the first, the next-newest resumes" || fail "103e: B still stopped after the window"
num "$(wst resume)" == 1000090 && ok "103e: the two recorded resumes are 30 s apart" || fail "103e: state resume '$(wst resume)'"
sleep 3
held $sgA && ok "103e: the oldest pause is not resumed inside the second window" || fail "103e: A resumed early"
clk 1000120
until_long 'going $sgA' && ok "103e: and the oldest one a window after that" || fail "103e: A still stopped"
# 103f. the window setting is live: a pause-window file of 10, then 1000 (clamped to 300), read from the gap between recorded pauses
echo 10 > "$TESTSLOT_DIR/pause-window"; clk 1000200; sleep 2
echo "1000.00 5.00 5.00 1/100 1" > "$TESTSLOT_LOADAVG"
until_long 'held $sgA' && num "$(wst pause)" == 1000200 || fail "103f: A was not paused again"
clk 1000209; sleep 3
going $sgB && ok "103f: with a window of 10, 9 s after a pause nothing else is paused" || fail "103f: B paused at 9 s"
clk 1000210
until_long 'held $sgB' && num "$(wst pause)" == 1000210 && ok "103f: 10 s after, the next is paused: the recorded gap is the file's 10 s" || fail "103f: B not paused after 10 s (state pause '$(wst pause)')"
echo 1000 > "$TESTSLOT_DIR/pause-window"; clk 1000509; sleep 3
going $sgC && ok "103f: a window of 1000 is clamped to 300: 299 s after a pause nothing is paused" || fail "103f: C paused at 299 s"
clk 1000510
until_long 'held $sgC' && num "$(wst pause)" == 1000510 && ok "103f: 300 s after, the next is paused: the recorded gap is 300 s" || fail "103f: C not paused after 300 s (state pause '$(wst pause)')"
# 103g. a stop of a load-paused run is not held by the resume window: with the load low the newest pause (C) resumes and takes the
# window (clock frozen, so it is open), then a stop of B, still load-paused, ends it at once
echo "0.50 5.00 5.00 1/100 1" > "$TESTSLOT_LOADAVG"
until_long 'going $sgC' || fail "103g: C did not resume"
num "$(wst resume)" == 1000510 && held $sgB || fail "103g: the resume window is not open with B held (state resume '$(wst resume)', B '$(lstate "$sgB")')"
"$T" stop "$sgB" >/dev/null; bwaitp "$spB"
[ -z "$(pgrep -g "$sgB" 2>/dev/null)" ] && ok "103g: stop on a load-paused run while the resume window is closed ends it" || fail "103g: group $sgB left"
for n in A C D; do eval "g=\$sg$n"; "$T" stop "$g" >/dev/null 2>&1; done
bwaitp "$spA"; bwaitp "$spC"; bwaitp "$spD"
echo "0.00 0.00 0.00 1/100 1" > "$TESTSLOT_LOADAVG"
unset TESTSLOT_OBSERVED_DIR TESTSLOT_SAMPLE_S TESTSLOT_FAKE_START_RATE TESTSLOT_TEST_CLOCK
rm -f "$TESTSLOT_DIR/pause-window" "$TESTSLOT_DIR/pause-window-state" "$TESTSLOT_DIR/pause.lock"
[ -n "$oldcap" ] && echo "$oldcap" > "$TESTSLOT_DIR/cap" || rm -f "$TESTSLOT_DIR/cap"

# 104. The README's badge row (testslot-badge-ci-label, testslot-badges-house-order): CI first, labelled CI, then the license, the release badge, CodeQL last; and the
# CHANGELOG says so in a 1.2.0 section above 1.1.0. The files sit beside the tool; an installed copy has no README.
d=$(dirname "$T")
if [ -f "$d/README.md" ]; then
  row=$(grep -m1 '^\[!\[' "$d/README.md")
  want='[![CI](https://github.com/jerrydboonstra/testslot/actions/workflows/ci.yml/badge.svg)](https://github.com/jerrydboonstra/testslot/actions/workflows/ci.yml) [![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) [![release](https://img.shields.io/github/v/release/jerrydboonstra/testslot)](https://github.com/jerrydboonstra/testslot/releases/latest) [![CodeQL](https://github.com/jerrydboonstra/testslot/actions/workflows/github-code-scanning/codeql/badge.svg)](https://github.com/jerrydboonstra/testslot/actions/workflows/github-code-scanning/codeql)'
  [ "$row" = "$want" ] && ok "104a: the README badge row is CI, license, release, CodeQL, in that order (no neckbeard badge: testslot is a tool, not a plugin)" || fail "104a: the README badge row is '$row'"
  case $row in "[![CI]("*) ok "104b: the first badge is labelled CI" ;; *) fail "104b: the first badge is not labelled CI: '${row%%]*}'" ;; esac
  u=$(grep -n '^## 1\.2\.0 ' "$d/CHANGELOG.md" | head -1 | cut -d: -f1); r=$(grep -n '^## 1\.1\.0 ' "$d/CHANGELOG.md" | head -1 | cut -d: -f1)
  [ -n "$u" ] && [ -n "$r" ] && [ "$u" -lt "$r" ] && sed -n "${u},${r}p" "$d/CHANGELOG.md" | grep -q 'badge.*CI\|CI.*badge' \
    && ok "104c: the CHANGELOG has a 1.2.0 section above 1.1.0 that says the badge is labelled CI" || fail "104c: no 1.2.0 section above 1.1.0 naming the CI badge (1.2.0 at line '${u:-none}', 1.1.0 at '${r:-none}')"
  a=$(grep -n '^## 1.2.1' "$d/CHANGELOG.md" | head -1 | cut -d: -f1); b=$(grep -n '^## 1.2.0' "$d/CHANGELOG.md" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && sed -n "${a},${b}p" "$d/CHANGELOG.md" | awk '/^### README/{f=1;next} /^##/{f=0} f' | grep -q 'CodeQL' \
    && ok "104e: the 1.2.1 CHANGELOG section has a README line naming the CodeQL badge" || fail "104e: no README line naming CodeQL under 1.2.1 (1.2.1 at line '${a:-none}', 1.2.0 at '${b:-none}')"
  grep -q 'The README shows a tests badge' "$d/CHANGELOG.md" && ok "104d: the shipped 1.1.0 line about the tests badge is left as written" || fail "104d: the shipped 1.1.0 line was edited"
fi

# 105. CI first: `testslot run --ci`, only for the users in $DIR/ci-users; while a CI run waits or holds,
# no new non-CI run is admitted; a CI run goes ahead of every queued non-CI run; status says which is which.
P=$O/tsci.py
cat > "$P" <<'PY'
import importlib.machinery, importlib.util, os, sys, time
import os, sys; sys.path.insert(0, os.environ['TS_SHIM_DIR']); import test_shim
m = test_shim.load(sys.argv[1])
def check(ok, what): print(("PASS " if ok else "FAIL ") + what)
set_load = lambda v: open(os.environ['TESTSLOT_LOADAVG'], 'w').write(v + ' 1.0 1.0 1/100 1\n')
set_load('1.0')
run = lambda n, **k: dict({'pid': 4242, 'state': 'running', 'kind': 'light', 'cpus': n}, **k)
wait = lambda age, n=4, **k: dict({'pid': 4243, 'state': 'waiting', 'kind': 'light', 'cpus': n, 'queued': time.time() - age}, **k)
def wc(hs, n=1, ci=False):
    try:
        r = m.wait_check(hs, 1, time.time(), n, None, ci)
    except TypeError:
        return ('no ci argument',)
    return r
code = lambda r: r[0] if r else None
check(code(wc([run(1, ci=True)])) == 'ci-first', "105a: a CI run holding a slot holds back a non-CI run (ci-first)")
check(code(wc([wait(5, 1, ci=True, pid=4244)])) == 'ci-first', "105a: so does a CI run still waiting")
check(wc([run(1)]) is None, "105a: with no CI run on the host a non-CI run starts as before")
check(code(wc([wait(100, 1)])) == 'queued-ahead', "105a: a non-CI run queued behind a non-CI one waits its turn (the base case)")
check(wc([wait(100, 1)], 1, True) is None, "105a: a CI run goes ahead of a queued non-CI run")
check(wc([run(8), wait(700)], 1, True) is None, "105a: a CI run is not held by the reservation for a non-CI head")
check(code(wc([run(8), wait(700)], 1, False)) == 'reserved', "105a: the same head still holds a non-CI run (the base case)")
r = wc([run(20)], 1, True)
check(code(r) == 'ci-priority' and r[1].startswith('ci priority: cpus:'), "105a: a CI run held for cpus says ci priority and the usual reason")
check(wc([run(1, ci=True)], 1, True) is None, "105a: a CI run starts beside a running CI run while cpus are free (CI runs among themselves share the cap)")
r = wc([wait(5, 1, ci=True, pid=4244)], 1, True)
check(code(r) == 'ci-priority' and 'queued ahead' in r[1], "105a: a CI run keeps turn order behind an earlier CI run of its size (ci priority, queued ahead)")
import subprocess, signal
sp = subprocess.Popen(['sleep', '60']); time.sleep(0.2); os.kill(sp.pid, signal.SIGSTOP); time.sleep(0.3)
check(code(wc([run(1, ci=True, pid=sp.pid)])) == 'ci-first', "105a: a CI run stopped by the load pause still holds back a non-CI run")
os.kill(sp.pid, signal.SIGCONT); sp.kill(); sp.wait()
check(m.requeue_due({'kind': 'light'}, 1, 1e6, 301.0) and not m.requeue_due({'kind': 'light', 'ci': True}, 1, 1e6, 301.0), "105a: a CI run is never requeued (the restart would lose --ci); the same plain run is")
check('ci-first' in getattr(m, 'WAIT_CODES', ()) and 'ci-priority' in getattr(m, 'WAIT_CODES', ()), "105a: WAIT_CODES lists both new codes")
PY
TESTSLOT_CAP=20 TESTSLOT_LOAD_CAP=10 python3 "$P" "$T" > "$O/tsci.txt" 2>"$O/tsci.err"
[ -s "$O/tsci.txt" ] || { fail "105a: the unit checks did not run"; sed 's/^/     /' "$O/tsci.err"; }
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "$rest" || fail "$rest"; done < "$O/tsci.txt"

# 105b. --ci is for the users in ci-users, by the account's real name: no file, an environment variable and a USER override do not grant it
me_user=$(id -un); cif=$TESTSLOT_DIR/ci-users; rm -f "$cif"
"$T" run --ci --cpus 1 -- true >"$O/ci1.out" 2>"$O/ci1.err"; c=$?
[ "$c" != 0 ] && grep -q "$cif" "$O/ci1.err" && ok "105b: --ci with no ci-users file is refused and names the file" || fail "105b: exit $c, stderr: $(head -c 200 "$O/ci1.err")"
TESTSLOT_CI_USERS=$me_user "$T" run --ci --cpus 1 -- true >/dev/null 2>"$O/ci2.err"; c=$?
[ "$c" != 0 ] && grep -q "$cif" "$O/ci2.err" && ok "105b: TESTSLOT_CI_USERS does not grant --ci (the caller sets its own environment)" || fail "105b: TESTSLOT_CI_USERS granted --ci"
echo zzciuser > "$cif"
USER=zzciuser LOGNAME=zzciuser "$T" run --ci --cpus 1 -- true >/dev/null 2>"$O/ci3.err"; c=$?
[ "$c" != 0 ] && grep -q "$cif" "$O/ci3.err" && ok "105b: USER and LOGNAME set to a listed name do not grant --ci (the real account is checked)" || fail "105b: exit $c with USER set to a listed name: $(head -c 200 "$O/ci3.err")"
"$T" run --ci --cpus 1 -- true >/dev/null 2>"$O/ci4.err"; c=$?
[ "$c" != 0 ] && grep -q "$cif" "$O/ci4.err" && ok "105b: a user not in the file is refused, naming the file" || fail "105b: an unlisted user ran --ci"
printf '# %s\n   # %s\n\n' "$me_user" "$me_user" > "$cif"
"$T" run --ci --cpus 1 -- true >/dev/null 2>"$O/ci4b.err"; c=$?
[ "$c" != 0 ] && grep -q "$cif" "$O/ci4b.err" && ok "105b: a user named only in a # comment line is refused" || fail "105b: a commented-out name granted --ci"
printf '# the CI accounts\n\n%s\n' "$me_user" > "$cif"
"$T" run --ci --cpus 1 -- true >/dev/null 2>"$O/ci5.err"; c=$?
[ "$c" = 0 ] && ok "105b: a user in the file (comments and blank lines ignored) runs with --ci" || fail "105b: a listed user was refused, exit $c: $(head -c 200 "$O/ci5.err")"
"$T" run --ci --track -- true >/dev/null 2>"$O/ci6.err"; c=$?
[ "$c" != 0 ] && ok "105b: --ci with --track is refused (a track run takes no slot)" || fail "105b: --ci --track ran"

# 105c. the order: a holder with the whole cap, a non-CI run queued, then a --ci run queued behind it. When cpus free the CI run starts
# first, the non-CI run (and a later one) wait until it ends, and status says which is which.
rm -f "$O"/ci-*; export TESTSLOT_SAMPLE_S=0.5
now() { python3 -c "import time; print(time.time())"; }
"$T" run --cpus 2 -- bash -c ": cih.$$; sleep 14" >/dev/null 2>&1 & ciH=$!
until_long '[ -n "$(rpg "cih.$$")" ]' || fail "105c: the holder never showed as running"
"$T" run --cpus 1 -- bash -c ": cin1.$$; python3 -c 'import time; print(time.time())' > $O/ci-n1s; sleep 2; python3 -c 'import time; print(time.time())' > $O/ci-n1e" >/dev/null 2>&1 & ciN1=$!
until_long '"$T" status --json | python3 -c "import json,sys; sys.exit(not any(\"cin1.$$\" in (w.get(\"command\") or \"\") for w in json.load(sys.stdin)[\"waiting\"]))"' || fail "105c: the non-CI run never showed as waiting"
"$T" run --ci --cpus 1 -- bash -c ": cici.$$; python3 -c 'import time; print(time.time())' > $O/ci-cs; sleep 4; python3 -c 'import time; print(time.time())' > $O/ci-ce" >/dev/null 2>"$O/ci7.err" & ciC=$!
sleep 3
"$T" run --cpus 1 -- bash -c ": cin2.$$; python3 -c 'import time; print(time.time())' > $O/ci-n2s" >/dev/null 2>&1 & ciN2=$!
sleep 2
"$T" status > "$O/cistat.txt"; "$T" status --json > "$O/cistat.json"
python3 - "$O/cistat.json" "$O/ci7.err" > "$O/cijson.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
w = {(j.get("command") or ""): j for j in d["waiting"]}
def find(tag):
    return next((j for c, j in w.items() if tag in c), None)
n1, ci, n2 = find("cin1."), find("cici."), find("cin2.")
print("PASS" if n1 and n1.get("wait_reason") == "ci-first" and n1.get("ci") is False else "FAIL", "105c: the earlier non-CI run waits with code ci-first and ci false in status --json (" + str(n1 and (n1.get("wait_reason"), n1.get("ci"))) + ")")
print("PASS" if n2 and n2.get("wait_reason") == "ci-first" else "FAIL", "105c: a non-CI run queued after the CI run waits ci-first too")
print("PASS" if ci and ci.get("ci") is True and (ci.get("wait_reason") or "").startswith("ci-priority") else "FAIL", "105c: the waiting CI run has ci true and the code ci-priority (" + str(ci and (ci.get("wait_reason"), ci.get("ci"))) + ")")
PY
while read -r verdict rest; do [ "$verdict" = PASS ] && ok "$rest" || fail "$rest"; done < "$O/cijson.txt"
grep -q "cin1\.$$" "$O/cistat.txt" && grep -q "(waiting: ci first)" "$O/cistat.txt" && ok "105c: status prints (waiting: ci first) on a held run" || fail "105c: status has no '(waiting: ci first)': $(grep -n 'waiting:' "$O/cistat.txt" | head -3)"
grep -q "(ci, priority)" "$O/cistat.txt" && ok "105c: status prints (ci, priority) on the CI run" || fail "105c: status has no '(ci, priority)'"
grep "(ci, priority)" "$O/cistat.txt" | grep -q "(waiting: ci priority: cpus: " && ok "105c: the waiting CI row also says what holds it (waiting: ci priority: cpus: ...)" || fail "105c: the CI row has no reason: $(grep -n 'ci, priority' "$O/cistat.txt" | head -2)"
python3 - "$O/cistat.json" <<'PY' && ok "105c: --json carries the CI run's wait_text (ci priority: cpus: ...)" || fail "105c: the CI run's wait_text is wrong in --json"
import json, sys
d = json.load(open(sys.argv[1]))
ci = next(j for j in d["waiting"] if "cici." in (j.get("command") or ""))
sys.exit(0 if (ci.get("wait_text") or "").startswith("ci priority: cpus: ") else 1)
PY
bwaitp "$ciH"
until_long '[ -s "$O/ci-cs" ]' && ok "105c: when the cpus free, the CI run starts" || fail "105c: the CI run never started"
sleep 2
[ ! -e "$O/ci-n1s" ] && [ ! -e "$O/ci-n2s" ] && ok "105c: no non-CI run starts while the CI run runs, though a cpu is free" || fail "105c: a non-CI run started during the CI run (n1 $(cat "$O/ci-n1s" 2>/dev/null), n2 $(cat "$O/ci-n2s" 2>/dev/null))"
bwaitp "$ciC"
until_long '[ -s "$O/ci-n1s" ] && [ -s "$O/ci-ce" ]' || fail "105c: the non-CI run never started after the CI run ended"
num "$(cat "$O/ci-n1s" 2>/dev/null)" ">" "$(cat "$O/ci-ce" 2>/dev/null)" && ok "105c: the non-CI run, queued first, starts only after the CI run ended" || fail "105c: n1 started at $(cat "$O/ci-n1s" 2>/dev/null), the CI run ended at $(cat "$O/ci-ce" 2>/dev/null)"
bwaitp "$ciN1"; bwaitp "$ciN2"

# 105d. a CI run's reason in status follows what it waits on: behind an earlier CI run first (queued ahead), then for cpus once that one runs
"$T" run --cpus 2 -- bash -c ": cdh.$$; sleep 10" >/dev/null 2>&1 & cdH=$!
until_long '[ -n "$(rpg "cdh.$$")" ]' || fail "105d: the holder never showed as running"
"$T" run --ci --cpus 2 -- bash -c ": cdc1.$$; sleep 5" >/dev/null 2>&1 & cdC1=$!
until_long '"$T" status --json | python3 -c "import json,sys; sys.exit(not any(\"cdc1.$$\" in (w.get(\"command\") or \"\") for w in json.load(sys.stdin)[\"waiting\"]))"' || fail "105d: the first CI run never showed as waiting"
"$T" run --ci --cpus 1 -- bash -c ": cdc2.$$; sleep 1" >/dev/null 2>&1 & cdC2=$!
cdtext() { "$T" status --json | python3 -c "import json,sys; print(next((w.get('wait_text') or '' for w in json.load(sys.stdin)['waiting'] if 'cdc2.$$' in (w.get('command') or '')), ''))"; }
until_long '[ -n "$(cdtext)" ]' || fail "105d: the second CI run never showed as waiting"
case "$(cdtext)" in "ci priority: "*"ahead"*) ok "105d: a CI run behind an earlier CI run says the run ahead holds it";; *) fail "105d: wait_text is '$(cdtext)'";; esac
until_long 'case "$(cdtext)" in "ci priority: cpus: "*) true;; *) false;; esac' && ok "105d: the text is rewritten to the cpus hold once the earlier CI run runs" || fail "105d: wait_text stayed '$(cdtext)'"
bwaitp "$cdH"; bwaitp "$cdC1"; bwaitp "$cdC2"
rm -f "$cif" "$O"/ci-*; unset TESTSLOT_SAMPLE_S

# 106. every `uses:` line in testslot's own workflows names a full 40-hex commit sha, with its tag in a "# v" comment (pin-checkout-sha; Scorecard's Pinned-Dependencies)
wf="$TS_SHIM_DIR/.github/workflows"
usesre='^[[:space:]]*(-[[:space:]]+)?uses:'
if [ -d "$wf" ]; then
  nuses=$(grep -rcE "$usesre" "$wf" | awk -F: '{n += $NF} END {print n + 0}')
  unpinned=$(grep -rnE "$usesre" "$wf" | grep -vE 'uses:[[:space:]]+([^[:space:]@]+@[0-9a-f]{40}[[:space:]]+# v[0-9]|\./)' || true)   # a local action (./x) has no ref to pin
  if [ "$nuses" -lt 1 ]; then fail "106: no uses: line found under $wf, so nothing was checked"
  elif [ -z "$unpinned" ]; then ok "106: every uses: line ($nuses) in the workflows is a 40-hex sha with a # v comment"
  else fail "106: a uses: line is not pinned to a sha with a # v comment"; echo "$unpinned" | sed 's/^/     /'; fi
else
  echo "skip 106 (no .github/workflows folder beside test.sh: a copy of testslot outside the repo, nothing checked)"
fi

# 107. SECURITY.md says how to report privately: the direct GitHub advisory link, a reply time, and no email address (security-reporting-link; Scorecard's Security-Policy)
sec="$TS_SHIM_DIR/SECURITY.md"
if [ -f "$sec" ]; then
  grep -qF 'https://github.com/jerrydboonstra/testslot/security/advisories/new' "$sec" && ok "107: SECURITY.md links the private advisory form" || fail "107: SECURITY.md lacks the private advisory link"
  grep -qF 'I aim to reply within 7 days.' "$sec" && ok "107: SECURITY.md states a reply time" || fail "107: SECURITY.md states no reply time"
  grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$sec" && fail "107: SECURITY.md publishes an email address" || ok "107: SECURITY.md publishes no email address"
else
  ok "107: no SECURITY.md beside test.sh (a copy of testslot outside the repo), nothing to check"
fi

echo "$fails failed"
exit $((fails > 0))
