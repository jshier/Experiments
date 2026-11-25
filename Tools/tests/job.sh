#!/bin/bash
# Tools/job: `start` then `wait` never reads the previous run's status; wait's own outcomes (timeout 124, died or
# orphaned 125) are printed apart from a command's 3, 4, 124; TERM and INT reach the command at once and its status is
# recorded; a runner killed outright leaves an "orphaned" command that `status` reports; a restart while a reader looks
# never reads as died or as a status with no number; refusing starts don't queue on the lock; closed or departed
# standard descriptors change no status; bad options exit 2.
source "$(dirname "$0")/../lib/common.sh" || exit 2
set +e +o pipefail
job="$(cd "$(dirname "$0")/.." && pwd)/job"
# Every `run` under a time limit of its own: a run that hangs fails its check in seconds (status 124), not at the
# suite's cap.
limited() { with_timeout 20 "$@"; }
work="$(mktemp -d "${TMPDIR:-/tmp}/check-job.XXXXXX")"
export EXPERIMENTS_JOBS_DIR="$work/jobs"
# Nothing may write into $work while it's removed, even when a check failed partway: the background helpers (NAME.pid
# writers, lock holders, readers, starts) are stopped and waited for (TERM, then KILL after 2 s), and jobs still running
# are stopped through their runners and waited for (a runner writes NAME.status when it ends).
cleanup() {
    local p n tries runner
    # Signals ignored from here: a helper stopped here (with_timeout, in a background subshell) passes the TERM on to
    # `$$`, which is this script, and would end the cleanup before the removal.
    trap '' TERM INT HUP
    [[ -n "${orphan:-}" ]] && kill -KILL "$orphan" 2>/dev/null
    for p in $(jobs -p); do kill -TERM "$p" 2>/dev/null; done
    for ((tries = 0; tries < 20; tries++)); do
        [[ -n "$(jobs -pr)" ]] || break
        sleep 0.1
    done
    for p in $(jobs -p); do kill -KILL "$p" 2>/dev/null; done
    wait 2>/dev/null
    for p in "$EXPERIMENTS_JOBS_DIR"/*.pid; do
        [[ -f "$p" ]] || continue
        n="$(basename "$p" .pid)"
        runner="$(head -1 "$p")"
        # (older.pid names this script on purpose.)
        [[ "$runner" != "$$" && "$("$job" status "$n" 2>/dev/null)" == running ]] || continue
        kill -TERM "$runner" 2>/dev/null
        "$job" wait "$n" --timeout 5 > /dev/null 2>&1
    done
    rm -rf "$work"
}
trap cleanup EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }

limited "$job" run stale -- /bin/sh -c 'exit 7'
check "run exits with the command's status" "$?" 7
"$job" start stale -- /bin/sh -c 'sleep 2; exit 0' 2> /dev/null
check "start returns at once" "$?" 0
check "status right after start" "$("$job" status stale)" running
out="$("$job" wait stale --timeout 20 2> /dev/null)"
check "wait after start: the new run's status" "$?/$out" "0/exit 0"

limited "$job" run three -- /bin/sh -c 'exit 3'
out="$("$job" wait three --timeout 5 2> /dev/null)"
check "a command's own 3" "$?/$out" "3/exit 3"
limited "$job" run four -- /bin/sh -c 'exit 124'
out="$("$job" wait four --timeout 5 2> /dev/null)"
check "a command's own 124 is told apart by the line" "$?/$out" "124/exit 124"

"$job" start slow -- /bin/sleep 30 2> /dev/null
out="$("$job" wait slow --timeout 1 2> /dev/null)"
check "wait's timeout" "$?/$out" "124/running"
("$job" start slow -- /bin/true) 2> /dev/null
check "start refuses a running job" "$?" 2
runner="$(head -1 "$EXPERIMENTS_JOBS_DIR/slow.pid")"
start=$SECONDS
kill -TERM "$runner"
out="$("$job" wait slow --timeout 10 2> /dev/null)"
check "TERM is passed to the command and recorded" "$?/$out" "143/exit 143"
check "TERM acted at once" "$((SECONDS - start < 5))" 1

"$job" start interrupted -- /bin/sleep 30 2> /dev/null
sleep 0.5
kill -INT "$(head -1 "$EXPERIMENTS_JOBS_DIR/interrupted.pid")"
out="$("$job" wait interrupted --timeout 10 2> /dev/null)"
check "INT is passed to the command (not ignored)" "$?/$out" "130/exit 130"

"$job" start orphan -- /bin/sleep 30 2> /dev/null
sleep 0.5
orphan="$(sed -n 3p "$EXPERIMENTS_JOBS_DIR/orphan.pid")"
kill -KILL "$(head -1 "$EXPERIMENTS_JOBS_DIR/orphan.pid")"
sleep 0.5
check "status after SIGKILL of the runner" "$("$job" status orphan)" "orphaned $orphan"
out="$("$job" wait orphan --timeout 5 2> /dev/null)"
check "wait on an orphan" "$?/$out" "125/orphaned $orphan"
("$job" start orphan -- /bin/true) 2> /dev/null
check "start refuses while the orphan runs" "$?" 2
kill -KILL "$orphan"
sleep 0.5
check "status once the orphan is gone" "$("$job" status orphan)" died
out="$("$job" wait orphan --timeout 5 2> /dev/null)"
check "wait on a dead job" "$?/$out" "125/died"
"$job" status orphan >&- 2> "$work/err"
check "status of a dead job with stdout closed: exit 0, nothing on stderr" "$?/$(cat "$work/err")" "0/"
"$job" wait orphan --timeout 5 >&- 2> "$work/err"
check "wait on it with stdout closed: 125, and only its note on stderr" "$?/$(grep -c . "$work/err")" "125/1"

TZ=Asia/Tokyo LC_ALL=ja_JP.UTF-8 "$job" start zones -- /bin/sleep 5 2> /dev/null
check "a job started in another time zone and locale reads as running" \
    "$(TZ=Pacific/Auckland LC_ALL=fr_FR.UTF-8 "$job" status zones)" running
kill -TERM "$(head -1 "$EXPERIMENTS_JOBS_DIR/zones.pid")"
"$job" wait zones --timeout 10 > /dev/null 2>&1

# COMMANDs here are Perl sleepers counted by their exact command line (the runners' own command lines hold the same
# words, unanchored).
marker="check-job-many-$$"
commands() { pgrep -f "^/usr/bin/perl -e sleep $1 $marker\$" | grep -c .; }
for attempt in 1 2 3 4; do
    pids=()
    for ((i = 0; i < 24; i++)); do
        "$job" start many -- /usr/bin/perl -e 'sleep 2' "$marker" 2>> "$work/many.err" &
        pids+=($!)
    done
    codes=()
    for p in "${pids[@]}"; do
        wait "$p"
        codes+=($?)
    done
    sleep 0.3
    check "24 starts at once ($attempt): one runs, 23 refuse" "$(printf '%s\n' "${codes[@]}" | sort | uniq -c | tr -s ' \n' '  ')" " 1 0 23 2 "
    check "24 starts at once ($attempt): one command" "$(commands 2)" 1
    "$job" wait many --timeout 10 > /dev/null 2>&1
done
check "nothing but the expected messages" "$(grep -c -v -E 'started|already running' "$work/many.err")" 0
check "nothing left beside the job's files" "$(find "$EXPERIMENTS_JOBS_DIR" -name 'many*' | sed 's/.*many//' | sort | tr '\n' ' ')" ".lock .log .pid .run .status "

# A `start` killed outright after launching its runner and before writing NAME.pid (made by hand: NAME.pid names a
# process that's gone): the runner runs nothing, and a later `start` runs COMMAND once.
/bin/sh -c 'exit 0' &
dead=$!
wait "$dead"
printf '%s\n%s\n' "$dead" "Mon Jan  1 00:00:00 2024" > "$EXPERIMENTS_JOBS_DIR/killed.pid"
limited env JOB_STARTED_BY="killed:$dead" "$job" run killed -- /usr/bin/perl -e 'sleep 3' "$marker" > /dev/null 2>&1 &
orphaned_runner=$!
sleep 1
check "a runner NAME.pid doesn't name runs nothing" "$(commands 3)" 0
wait "$orphaned_runner"
check "and records nothing" "$("$job" status killed)" died
"$job" start killed -- /usr/bin/perl -e 'sleep 3' "$marker" 2> /dev/null
check "a later start runs it once" "$?/$(commands 3)" "0/1"
"$job" wait killed --timeout 10 > /dev/null 2>&1

"$job" start early -- /bin/sleep 30 2> /dev/null
kill -TERM "$(head -1 "$EXPERIMENTS_JOBS_DIR/early.pid")"
out="$("$job" wait early --timeout 10 2> /dev/null)"
check "TERM right after start: recorded, not died" "$?/$out" "143/exit 143"

touch "$EXPERIMENTS_JOBS_DIR/older.status"
echo 9 > "$EXPERIMENTS_JOBS_DIR/older.status"
touch -t 202001010000 "$EXPERIMENTS_JOBS_DIR/older.status"
printf '%s\n' "$$" "$(LC_ALL=C TZ=UTC0 ps -o lstart= -p $$ | tr -s ' ' | sed 's/^ //;s/ $//')" > "$EXPERIMENTS_JOBS_DIR/older.pid"
check "a status older than the PID file is ignored" "$("$job" status older)" running

# A NAME.status that can't be read or holds no exit status, 0 to 255 written plainly (written by something else): died,
# with a note naming it; wait ends (125); a start runs the job again and replaces it. ("unreadable" is a status file of
# mode 000.)
limited "$job" run garbled -- /bin/sh -c 'exit 0'
for content in '' garbage -1 ' 0' 256 99999999999999999999 007 08 unreadable 2-NUL-5 5-three-newlines; do
    case "$content" in
        unreadable)
            printf '3' > "$EXPERIMENTS_JOBS_DIR/garbled.status"
            chmod 000 "$EXPERIMENTS_JOBS_DIR/garbled.status" ;;
        2-NUL-5) printf '2\0005' > "$EXPERIMENTS_JOBS_DIR/garbled.status" ;;
        5-three-newlines) printf '5\n\n\n' > "$EXPERIMENTS_JOBS_DIR/garbled.status" ;;
        *) printf '%s' "$content" > "$EXPERIMENTS_JOBS_DIR/garbled.status" ;;
    esac
    check "status file '$content': died" "$("$job" status garbled 2> /dev/null)" died
    out="$("$job" wait garbled --timeout 5 2> "$work/err")"
    check "status file '$content': wait 125, its note names the file" \
        "$?/$out/$(grep -c "garbled.status can't be read or holds no exit status" "$work/err")" "125/died/1"
    "$job" start garbled -- /bin/sh -c 'exit 6' 2> /dev/null
    out="$("$job" wait garbled --timeout 10 2> /dev/null)"
    check "status file '$content': a start runs the job again" "$?/$out" "6/exit 6"
done
# A 2 GiB status file (sparse): died, read in a few bytes, not whole (it took 2.1 GB of memory).
perl -e 'open(my $f, ">", shift) or die; truncate($f, 2 ** 31) or die' "$EXPERIMENTS_JOBS_DIR/garbled.status"
/usr/bin/time -l "$job" status garbled > "$work/out" 2> "$work/time"
check "a 2 GiB status file: died, in under 50 MB of memory ($(grep 'maximum resident' "$work/time" | tr -s ' '))" \
    "$(cat "$work/out")/$(perl -ne 'print $1 < 50e6 ? "small" : "large" if /(\d+)\s+maximum resident/' "$work/time")" "died/small"
rm -f "$EXPERIMENTS_JOBS_DIR/garbled.status"
# Statuses across the range (one digit, two, the 100s, 200-249, 250-255), with and without the newline `finish` writes.
for content in 255 0 42 231 7 199 250; do
    for ending in '' '\n'; do
        printf "%s$ending" "$content" > "$EXPERIMENTS_JOBS_DIR/garbled.status"
        out="$("$job" wait garbled --timeout 5 2> /dev/null)"
        check "status file '$content$ending': wait exits $content" "$?/$out" "$content/exit $content"
    done
done

# A NAME.pid that changes during every look (rewritten every millisecond; dead runner, no status, no lock): after 5
# looks, running (something is starting the job), never died.
/bin/sh -c 'exit 0' &
dead=$!
wait "$dead"
perl -e 'my ($f, $dead, $n) = (shift, shift, 0); my $end = time + 3;
    while (time < $end) {
        open(my $o, ">", "$f.tmp") or die; print $o "$dead\nMon Jan  1 00:00:00 2024\n", $n++, "\n"; close($o);
        rename("$f.tmp", $f) or die; select(undef, undef, undef, 0.001);
    }' "$EXPERIMENTS_JOBS_DIR/churn.pid" "$dead" &
churner=$!
sleep 0.2
check "status of a job whose NAME.pid changes during every look: running" "$("$job" status churn 2> /dev/null)" running
kill "$churner" 2> /dev/null
wait "$churner" 2> /dev/null

# Shims on PATH that make one call slow, to widen the windows between `start`'s steps: SHIM_SLOW (the call number,
# counted from 0 across processes in SHIM_COUNT) sleeps SHIM_SLEEP seconds, then runs the real command. Once SHIM_COUNT
# is gone (a runner that inherited the PATH outliving $work), they just run the real command.
mkdir -p "$work/bin"
for tool in mv ps; do
    cat > "$work/bin/$tool" <<EOF
#!/bin/bash
n=0
while [[ -d "\$SHIM_COUNT" ]] && ! mkdir "\$SHIM_COUNT/\$n" 2> /dev/null; do n=\$((n + 1)); done
[[ -d "\$SHIM_COUNT" ]] || exec /bin/$tool "\$@"
[[ \$n == "\$SHIM_SLOW" ]] && sleep "\$SHIM_SLEEP"
exec /bin/$tool "\$@"
EOF
    chmod +x "$work/bin/$tool"
done
shimmed() { # TOOL CALL SECONDS COMMAND...: COMMAND with TOOL's call CALL slowed by SECONDS
    local tool="$1" call="$2" seconds="$3" count
    shift 3
    count="$(mktemp -d "$work/count.XXXXXX")"
    mkdir -p "$work/path-$tool"
    ln -sf "$work/bin/$tool" "$work/path-$tool/$tool"
    PATH="$work/path-$tool:$PATH" SHIM_COUNT="$count" SHIM_SLOW="$call" SHIM_SLEEP="$seconds" "$@"
}
# The shims with their count directory gone: they run the real command at once, never spin.
touch "$work/shim-a"
SHIM_COUNT="$work/gone" SHIM_SLOW=0 SHIM_SLEEP=0 with_timeout 3 "$work/bin/mv" "$work/shim-a" "$work/shim-b"
check "the mv shim with its count directory gone: runs mv" "$?/$([[ -f "$work/shim-b" ]] && echo moved)" "0/moved"
out="$(SHIM_COUNT="$work/gone" SHIM_SLOW=0 SHIM_SLEEP=0 with_timeout 3 "$work/bin/ps" -o pid= -p $$)"
check "the ps shim with its count directory gone: runs ps" "$?/${out// /}" "0/$$"

# A `start` slowed between launching its runner and writing the runner's PID (its second `mv`): the runner waits for
# the lock however long that takes, so COMMAND still runs, once.
shimmed mv 1 1 "$job" start slow -- /usr/bin/perl -e 'sleep 1' "$marker" 2> /dev/null
check "a start slowed before naming its runner: exit 0" "$?" 0
out="$("$job" wait slow --timeout 10 2> /dev/null)"
check "and its command ran to its end" "$?/$out" "0/exit 0"

# A `status` and a `wait` while a `start` holds the lock (its first write of NAME.pid, slowed, after it removed the
# finished run's status): the job reads as running, and the wait gets the new run's status, never the old one's.
limited "$job" run window -- /bin/sh -c 'exit 7'
shimmed mv 0 1.5 "$job" start window -- /bin/sh -c 'exit 0' 2> /dev/null &
starter=$!
sleep 0.6
check "status while a start holds the lock: running" "$("$job" status window)" running
out="$("$job" wait window --timeout 10 2> /dev/null)"
check "a wait begun then: the new run's status" "$?/$out" "0/exit 0"
wait "$starter"

# Shims that slow every call: `ps` by SLOW_PS seconds; the Perl that reads a NAME.status file by 1 s.
mkdir -p "$work/slow-ps" "$work/slow-read"
printf '#!/bin/bash\nsleep "$SLOW_PS"\nexec /bin/ps "$@"\n' > "$work/slow-ps/ps"
printf '#!/bin/bash\n[[ "$*" == *.status* ]] && sleep 1\nexec /usr/bin/perl "$@"\n' > "$work/slow-read/perl"
chmod +x "$work/slow-ps/ps" "$work/slow-read/perl"

# A restart while a `wait` looks: it read the old NAME.pid (old runner, no status: the start removed it and holds the
# lock, its NAME.pid write slowed), and its checks (every `ps` slowed 2 s) end after the start let go. The old runner
# and command are gone, no status, no lock: one look reads "died". The wait must get the new run's status instead.
limited "$job" run restart -- /bin/sh -c 'exit 7'
shimmed mv 0 1.5 "$job" start restart -- /bin/sh -c 'sleep 2; exit 0' 2> /dev/null &
starter=$!
sleep 0.5
out="$(PATH="$work/slow-ps:$PATH" SLOW_PS=2 "$job" wait restart --timeout 30 2> /dev/null)"
check "a wait looking while the job restarts: the new run's status, not died" "$?/$out" "0/exit 0"
wait "$starter"

# A status removed by a `start` while a reader reads it (slowed 1 s): no "exit " with no number (wait's `exit ""`).
limited "$job" run removed -- /bin/sh -c 'exit 5'
PATH="$work/slow-read:$PATH" "$job" status removed > "$work/removed.status" 2>&1 &
status_reader=$!
PATH="$work/slow-read:$PATH" "$job" wait removed --timeout 30 > "$work/removed.wait" 2> /dev/null &
wait_reader=$!
sleep 0.4
"$job" start removed -- /bin/sh -c 'sleep 1; exit 0' 2> /dev/null
wait "$status_reader"
check "status of a job whose status is removed as it's read: running" "$?/$(cat "$work/removed.status")" "0/running"
wait "$wait_reader"
check "and a wait then gets the new run's status" "$?/$(cat "$work/removed.wait")" "0/exit 0"

# A status that appears and is removed within one look, so the snapshots around it are equal: the reader's runner check
# (`ps` slowed 1 s) outlasts the run, whose status then appears; its read (slowed 1 s) outlasts a new start's removal of
# it, whose NAME.pid write is slowed 3 s. The failed read must mean "look again" (then: running), not died.
"$job" start appears -- /bin/sh -c 'sleep 1; exit 0' 2> /dev/null
sleep 0.3
PATH="$work/slow-ps:$work/slow-read:$PATH" SLOW_PS=1 "$job" status appears > "$work/appears.out" 2> "$work/appears.err" &
appears_reader=$!
sleep 1.3
shimmed mv 0 3 "$job" start appears -- /bin/sh -c 'exit 0' 2> /dev/null &
appears_starter=$!
wait "$appears_reader"
check "a status that appears and is removed within one look: running, no note" \
    "$(cat "$work/appears.out")/$(grep -c . "$work/appears.err")" "running/0"
wait "$appears_starter"
"$job" wait appears --timeout 10 > /dev/null 2>&1

# 24 starts of a running job with every `ps` slowed 0.5 s (a loaded machine): the refusing ones don't queue on NAME.lock
# behind each other's idle checks (23 of them outlast `lock`'s 10 s), they refuse as soon as NAME.pid names a live
# runner: "already running", never "stayed locked".
pids=()
: > "$work/slow.err"
t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
for ((i = 0; i < 24; i++)); do
    PATH="$work/slow-ps:$PATH" SLOW_PS=0.5 "$job" start loaded -- /usr/bin/perl -e 'sleep 30' "$marker" 2>> "$work/slow.err" &
    pids+=($!)
done
codes=()
for p in "${pids[@]}"; do
    wait "$p"
    codes+=($?)
done
t1="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
check "24 starts with slow ps: one runs, 23 refuse" "$(printf '%s\n' "${codes[@]}" | sort | uniq -c | tr -s ' \n' '  ')" " 1 0 23 2 "
check "and all within 5 s (about 2 s: refusals don't wait out the lock)" \
    "$(perl -e 'my $d = $ARGV[1] - $ARGV[0]; print $d < 5 ? "yes" : "no: $d"' "$t0" "$t1")" yes
check "and only the expected messages ($(grep -v -E 'started|already running' "$work/slow.err" | head -1))" \
    "$(grep -c -v -E 'started|already running' "$work/slow.err")" 0
kill -TERM "$(head -1 "$EXPERIMENTS_JOBS_DIR/loaded.pid")"
"$job" wait loaded --timeout 20 > /dev/null 2>&1

# NAME.lock deleted while a `start` is slowed, then a second `start`: one command runs, the other start refuses. Once
# slowing the start's first `ps` (its own start time: taken before the lock, so it must not fall between the idle
# check and NAME.pid), once its second (the idle check's `ps` of a dead runner, while it holds the lock).
for call in 0 1; do
    /bin/sh -c 'exit 0' &
    dead=$!
    wait "$dead"
    printf '%s\n%s\n' "$dead" "Mon Jan  1 00:00:00 2024" > "$EXPERIMENTS_JOBS_DIR/deleted.pid"
    rm -f "$EXPERIMENTS_JOBS_DIR/deleted.status"
    shimmed ps "$call" 2 "$job" start deleted -- /usr/bin/perl -e 'sleep 4' "$marker" 2> /dev/null &
    first=$!
    sleep 0.7
    rm -f "$EXPERIMENTS_JOBS_DIR/deleted.lock"
    "$job" start deleted -- /usr/bin/perl -e 'sleep 4' "$marker" 2> /dev/null
    second_rc=$?
    wait "$first"
    first_rc=$?
    sleep 0.3
    check "lock deleted while ps call $call is slow: one start runs, one refuses" "$(echo "$first_rc $second_rc" | tr ' ' '\n' | sort | tr '\n' ' ')" "0 2 "
    check "lock deleted while ps call $call is slow: one command" "$(commands 4)" 1
    "$job" wait deleted --timeout 10 > /dev/null 2>&1
done

# A name's first start holding NAME.lock before it has written any NAME.pid: `status` reads running, not none.
perl -MFcntl=:flock -e 'open(my $f, ">>", shift) or die; flock($f, LOCK_EX) or die; sleep 2' "$EXPERIMENTS_JOBS_DIR/first.lock" &
holder=$!
sleep 0.5
check "a first start holding the lock, no NAME.pid yet: running" "$("$job" status first)" running
wait "$holder"
check "and none once it's let go" "$("$job" status first)" none
# A `status` of a job never run (NAME.lock there, no NAME.pid) whose lock probe (slowed 1 s) ends after the job's first
# start let go: the look says none, but NAME.pid appeared meanwhile, so it looks again: running.
mkdir -p "$work/slow-probe"
printf '#!/bin/bash\ncase "$*" in *"LOCK_SH | LOCK_NB"*) /bin/sleep 1 ;; esac\nexec /usr/bin/perl "$@"\n' > "$work/slow-probe/perl"
chmod +x "$work/slow-probe/perl"
touch "$EXPERIMENTS_JOBS_DIR/fresh.lock"
PATH="$work/slow-probe:$PATH" "$job" status fresh > "$work/fresh.status" 2>&1 &
reader=$!
sleep 0.3
"$job" start fresh -- /bin/sleep 2 2> /dev/null
wait "$reader"
check "status of a never-run job while its first start runs: running, not none" "$(cat "$work/fresh.status")" running
"$job" wait fresh --timeout 10 > /dev/null 2>&1
# A wait on such a job (running, but no NAME.run held: it's free at once) still keeps its deadline.
perl -MFcntl=:flock -e 'open(my $f, ">>", shift) or die; flock($f, LOCK_EX) or die; sleep 4' "$EXPERIMENTS_JOBS_DIR/held.lock" &
holder=$!
sleep 0.3
t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
out="$("$job" wait held --timeout 1 2> /dev/null)"
rc=$?
t1="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
check "wait --timeout 1 while a start holds the lock and nothing holds NAME.run: 124 at 1 s" \
    "$rc/$out/$(perl -e 'my $d = $ARGV[1] - $ARGV[0]; print abs($d - 1) <= 0.3 ? "on time" : "late: $d"' "$t0" "$t1")" "124/running/on time"
wait "$holder"

# A NAME.lock directory left by an older version of this tool: removed when it holds only its owner file, refused
# (exit 2) when it holds more.
mkdir "$EXPERIMENTS_JOBS_DIR/legacy.lock"
echo 1 > "$EXPERIMENTS_JOBS_DIR/legacy.lock/owner"
limited "$job" run legacy -- /bin/sh -c 'exit 0'
check "an old lock directory with its owner file: replaced, and the job runs" "$?/$([[ -f "$EXPERIMENTS_JOBS_DIR/legacy.lock" ]] && echo file)" "0/file"
mkdir "$EXPERIMENTS_JOBS_DIR/busy.lock"
touch "$EXPERIMENTS_JOBS_DIR/busy.lock/something"
limited "$job" run busy -- /bin/sh -c 'exit 0' 2> "$work/err"
check "an old lock directory holding more: exit 2" "$?" 2
check "and says what to do" "$(grep -c 'remove it' "$work/err")" 1

# COMMAND gets exactly the caller's descriptors: its 3 and 9 open, nothing else of the job's.
list_fds='my @o; for my $n (0 .. 255) { my $f; push @o, $n if open($f, "<&=", $n) || open($f, ">&=", $n) } print "@o"'
fds="$( (exec 3< /dev/null 9< /dev/null; limited "$job" run fds -- /usr/bin/perl -e "$list_fds") > /dev/null; cat "$EXPERIMENTS_JOBS_DIR/fds.log")"
check "COMMAND's descriptors are the caller's" "$fds" "0 1 2 3 9"
fds="$( (exec 197< /dev/null 198< /dev/null 199< /dev/null; limited "$job" run fds -- /usr/bin/perl -e "$list_fds") > /dev/null; cat "$EXPERIMENTS_JOBS_DIR/fds.log")"
check "the caller's 197-199 reach COMMAND too" "$fds" "0 1 2 197 198 199"
out="$( (ulimit -Sn 64; limited "$job" run low -- /bin/sh -c 'echo ran; exit 3') > /dev/null; echo "$?"; cat "$EXPERIMENTS_JOBS_DIR/low.log")"
check "a soft descriptor limit of 64: the job runs" "$(echo "$out" | tr '\n' ' ')" "3 ran "

# wait wakes when the runner ends, not on a 1 s poll.
"$job" start quick -- /bin/sleep 0.2 2> /dev/null
t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
"$job" wait quick --timeout 10 > /dev/null 2>&1
t1="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
check "wait on a 0.2 s job ends within 0.6 s" "$(perl -e 'print $ARGV[1] - $ARGV[0] < 0.6 ? "yes" : "no: " . ($ARGV[1] - $ARGV[0])' "$t0" "$t1")" yes

# A running job's runner holds NAME.run; a wait on it blocks there: its --timeout kept to 0.1 s, next to no CPU spent,
# and a wait killed outright leaves no waiter behind.
"$job" start long -- /usr/bin/perl -e 'sleep 12' "$marker" 2> /dev/null
check "a running job's NAME.run is held" \
    "$(perl -MFcntl=:flock -e 'open(my $f, "<", shift) or die; print flock($f, LOCK_SH | LOCK_NB) ? "free" : "held"' "$EXPERIMENTS_JOBS_DIR/long.run")" held
/usr/bin/time -p "$job" wait long --timeout 2 > "$work/out" 2> "$work/time"
check "wait --timeout 2 on a running job: 124, running" "$?/$(cat "$work/out")" "124/running"
check "it took 2 s, to 0.1 s ($(grep real "$work/time"))" "$(perl -ane 'print abs($F[1] - 2) <= 0.1 ? "yes" : "no" if $F[0] eq "real"' "$work/time")" yes
check "and next to no CPU ($(grep -E 'user|sys' "$work/time" | tr '\n' ' '))" \
    "$(perl -ane '$cpu += $F[1] if $F[0] =~ /^(user|sys)$/; END { print $cpu < 0.1 ? "yes" : "no" }' "$work/time")" yes
# The deadline is kept to the fraction of a second, not to whole seconds: three waits begun a third of a second apart
# (a whole-second deadline would be off by up to a second for at least one of them).
for offset in 1 2 3; do
    sleep 0.33
    t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
    "$job" wait long --timeout 1 > /dev/null 2>&1
    t1="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
    check "wait --timeout 1, sample $offset: 1 s to 0.1 s" \
        "$(perl -e 'my $d = $ARGV[1] - $ARGV[0]; print abs($d - 1) <= 0.1 ? "yes" : "no: $d"' "$t0" "$t1")" yes
done
"$job" wait long --timeout 60 > /dev/null 2>&1 &
waiter=$!
sleep 0.5
waiter_child="$(pgrep -P "$waiter" | head -1)"
kill -KILL "$waiter"
wait "$waiter" 2> /dev/null
sleep 0.5
check "a wait killed outright: its waiter is gone too" "$([[ -n "$waiter_child" ]] && ! kill -0 "$waiter_child" 2>/dev/null && echo gone)" gone
"$job" wait long --timeout 15 > /dev/null 2>&1

# Closed or redirected standard descriptors: a line piped into `run` reaches COMMAND; `run <&-` still runs COMMAND
# (standard input /dev/null); `start` with stderr closed; `wait`, `status`, and `log` with stdout closed, with nothing
# on stderr but wait's own note (no "write error", no result line flushed there by a later note), and with stdin and
# stderr closed; and `wait` and `start` whose reader has gone (SIGPIPE) keep their status.
echo piped-line | limited "$job" run piped -- /bin/cat
check "a line piped into run reaches COMMAND" "$?/$(cat "$EXPERIMENTS_JOBS_DIR/piped.log")" "0/piped-line"
limited /bin/sh -c 'exec "$@" <&-' sh "$job" run closed -- /bin/sh -c 'echo ran; exit 3'
check "run with standard input closed runs COMMAND" "$?/$(cat "$EXPERIMENTS_JOBS_DIR/closed.log")" "3/ran"
"$job" start quiet -- /bin/sleep 0.3 2>&-
check "start with stderr closed: exit 0" "$?" 0
"$job" wait quiet --timeout 10 >&- 2> "$work/err"
check "wait with stdout closed: the job's status" "$?" 0
check "and only its note on stderr" "$(grep -c . "$work/err")/$(grep -c '^job quiet: exit 0 ' "$work/err")" "1/1"
"$job" status quiet >&- 2> "$work/err"
check "status with stdout closed: exit 0" "$?" 0
check "and nothing on stderr" "$(cat "$work/err")" ""
"$job" log quiet >&- 2> "$work/err"
check "log with stdout closed: exit 0, nothing on stderr" "$?/$(cat "$work/err")" "0/"
out="$("$job" wait quiet --timeout 10 <&- 2>&-)"
check "wait with stdin and stderr closed" "$?/$out" "0/exit 0"
out="$("$job" status quiet <&- 2>&-)"
check "status with stdin and stderr closed" "$?/$out" "0/exit 0"
out="$("$job" log quiet <&- 2>&-)"
check "log with stdin and stderr closed" "$?/$out" "0/$EXPERIMENTS_JOBS_DIR/quiet.log"
# The reader gone before the tool writes (`| true`): its writes meet SIGPIPE, which mustn't become its status (141).
limited "$job" run gone -- /bin/sh -c 'exit 3'
gone_codes=''
for _ in 1 2 3 4 5; do
    (sleep 0.2; "$job" wait gone --timeout 10 2>&1) | true
    gone_codes+=" ${PIPESTATUS[0]}"
done
check "wait 2>&1 | true: the job's status every time" "$gone_codes" " 3 3 3 3 3"
(sleep 0.2; "$job" start gone -- /bin/sh -c 'exit 4' 2>&1) | true
check "start 2>&1 | true: exit 0" "${PIPESTATUS[0]}" 0
out="$("$job" wait gone --timeout 10 2> /dev/null)"
check "and the job ran" "$?/$out" "4/exit 4"
(sleep 0.2; "$job" wait none-such 2>&1) | true
check "wait on no job 2>&1 | true: exit 2" "${PIPESTATUS[0]}" 2

# Soft descriptor limits too low to work with (10, and 15, just below the 16 needed): a clear refusal (exit 2), at
# once. 16 works.
for n in 10 15; do
    out="$( (ulimit -Sn "$n"; limited "$job" run tight -- /bin/sh -c 'exit 0') 2>&1; echo "rc $?")"
    check "a soft limit of $n: exit 2, saying why" "$(echo "$out" | grep -c 'too low')/$(echo "$out" | tail -1)" "1/rc 2"
done
out="$( (ulimit -Sn 16; limited "$job" run sixteen -- /bin/sh -c 'echo ran; exit 3') 2>&1; echo "rc $?")"
check "a soft limit of 16: the job runs" "$(echo "$out" | tail -1)/$(cat "$EXPERIMENTS_JOBS_DIR/sixteen.log")" "rc 3/ran"

"$job" wait three --timeout 2> /dev/null
check "--timeout without a value" "$?" 2
"$job" wait three --timeout abc 2> /dev/null
check "--timeout abc" "$?" 2
"$job" status none-such > /dev/null
out="$("$job" status none-such)"
check "status of no job" "$out" none
"$job" wait none-such 2> /dev/null
check "wait on no job" "$?" 2
"$job" status none-such >&- 2> "$work/err"
check "status of no job with stdout closed: exit 0, nothing on stderr" "$?/$(cat "$work/err")" "0/"
"$job" wait none-such >&- 2> "$work/err"
check "wait on no job with stdout closed: 2, and only its error on stderr" "$?/$(grep -c . "$work/err")" "2/1"
