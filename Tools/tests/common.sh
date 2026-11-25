#!/bin/bash
# Tools/lib/common.sh's helpers. with_timeout: keeps the exit status (127 for a program it can't run); stops the
# command, its children, and children in process groups of their own, at the timeout (124) and at once for 0 s;
# passes standard input; leaves the caller's fd 3 and traps as they were; on TERM stops the command, runs the
# caller's EXIT trap with the caller's own variables, and ends 143; doesn't freeze a command that sets terminal modes.
# need_number rejects leading zeros. compiled_tool caches by content and survives concurrent builds; debuggable
# survives concurrent signing.
# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh" || exit 2
set +e
work="$(mktemp -d "${TMPDIR:-/tmp}/check-common.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2034 # Read by compiled_tool.
TOOLS_CACHE="$work/cache"
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }
running() { pgrep -f "^sleep $1\$" > /dev/null && echo yes || echo no; }

with_timeout 5 sh -c 'exit 7'
check "exit status kept" "$?" 7
with_timeout 5 /nonexistent/program 2> /dev/null
check "a program it can't run is 127" "$?" 127

# (sleep's interval must be valid, or the grandchild ends at once and the check proves nothing: 37.PID seconds.)
with_timeout 2 sh -c "sleep 37.$$ & sleep 38.$$; wait"
check "timeout status" "$?" 124
sleep 1
check "a child in its group stopped at the timeout" "$(running "37.$$")" no

with_timeout 2 perl -e 'if (!fork) { setpgrp(0, 0); exec "sleep", $ARGV[0] } sleep 30' "41.$$"
check "timeout status, child in its own group" "$?" 124
sleep 1
check "a child in a group of its own stopped too" "$(running "41.$$")" no
# Descendants that end on TERM are waited for only as long as they take, not a fixed 2 s.
start="$(perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000')"
with_timeout 1 perl -e 'if (!fork) { setpgrp(0, 0); exec "sleep", $ARGV[0] } sleep 60' "42.$$"
ended="$(perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000')"
check "a stop whose descendants end on TERM takes well under 2 s more" "$(( ended - start < 2200 ))" 1
check "and they're gone" "$(running "42.$$")" no

# A descendant that takes half a second to finish on TERM gets that time (its handler runs to the end, not KILLed).
with_timeout 1 perl -e 'if (!fork) { setpgrp(0, 0); $SIG{TERM} = sub { select undef, undef, undef, 0.5; open my $f, ">", $ARGV[1]; exit 0 }; sleep 60; exit 1 } sleep 60' "43.$$" "$work/graceful"
check "a slow TERM handler finishes before any KILL" "$([[ -e "$work/graceful" ]] && echo yes)" yes

# One that ignores TERM is KILLed 2 s after it by the clock, not after 20 polls that can run long under load. Measured
# from the TERM itself (the descendant's handler records when it arrived and carries on), so the time with_timeout
# takes to get there under load doesn't count.
with_timeout 1 perl -MTime::HiRes=time -e 'if (!fork) { setpgrp(0, 0); $SIG{TERM} = sub { open my $f, ">", "$ARGV[1].tmp"; printf $f "%d\n", time * 1000; close $f; rename "$ARGV[1].tmp", $ARGV[1] }; sleep 1 while 1 } sleep 60' "44.$$" "$work/termed"
ended="$(perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000')"
termed="$(cat "$work/termed" 2>/dev/null || echo 0)"
check "a TERM-ignoring descendant is KILLed about 2 s after TERM" "$(( ended - termed >= 1900 && ended - termed < 3000 ))" 1
check "and it's gone" "$(running "44.$$")" no

start=$SECONDS
with_timeout 0 sleep "4.$$"
check "with_timeout 0" "$?" 124
check "with_timeout 0 stops at once" "$(( SECONDS - start < 3 ))" 1

check "stdin passed through" "$(echo piped-in | with_timeout 5 cat)" piped-in

exec 3> "$work/fd3"
with_timeout 5 true
echo still-open >&3
written=$?
check "the caller's fd 3 kept (writable after)" "$written" 0
exec 3>&-

trap 'echo mine' INT
with_timeout 2 true
check "the caller's INT trap kept" "$(trap -p INT)" "trap -- 'echo mine' SIGINT"
trap - INT

# A tool that keeps a program's PID in `pid` and stops it from its EXIT trap, then is sent TERM inside with_timeout.
cat > "$work/term.sh" <<EOF
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
sleep 61.$$ &
pid=\$!
trap 'kill "\$pid" 2> /dev/null' EXIT
with_timeout 30 sleep 62.$$
EOF
/bin/bash "$work/term.sh" &
tool=$!
sleep 2
kill -TERM "$tool"
wait "$tool"
check "TERM ends the tool with 143" "$?" 143
sleep 1
check "the command stopped on TERM" "$(running "62.$$")" no
check "the caller's EXIT trap saw its own pid" "$(running "61.$$")" no

# A plain call under set -e (common.sh's default), Ctrl-C to the whole group, as a terminal sends it: the command is
# stopped before the tool ends (the polling sleep dies with the group; it mustn't end the tool first).
cat > "$work/plain.sh" <<EOF
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
with_timeout 30 sleep 63.$$
EOF
# (Launched with `&`, a process starts with SIGINT ignored; a terminal's foreground job doesn't: reset it.)
perl -e '$SIG{INT} = "DEFAULT"; setpgrp(0, 0); exec "/bin/bash", @ARGV' "$work/plain.sh" &
tool=$!
sleep 2
kill -INT -- "-$tool"
wait "$tool"
check "Ctrl-C to a plain call under set -e ends the tool with 130" "$?" 130
sleep 1
check "and the command is stopped" "$(running "63.$$")" no

# QUIT (Ctrl-\) is handled like INT, and the tool's EXIT trap still runs (bash doesn't run it when QUIT kills it).
cat > "$work/quit.sh" <<EOF
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap 'touch "$work/quit-cleaned"' EXIT
with_timeout 30 sleep 64.$$
EOF
# (Launched with `&`, a process starts with SIGQUIT ignored too: reset it, as a terminal's foreground job has it.)
perl -e '$SIG{QUIT} = "DEFAULT"; exec "/bin/bash", @ARGV' "$work/quit.sh" &
tool=$!
sleep 2
kill -QUIT "$tool"
wait "$tool" 2> /dev/null
check "QUIT ends the tool with 131" "$?" 131
sleep 1
check "and the command is stopped" "$(running "64.$$")" no
check "and the tool's EXIT trap ran" "$([[ -e "$work/quit-cleaned" ]] && echo yes)" yes

# Ctrl-\ to the whole group while with_timeout polls leaves no crash report (a plain `sleep` dies of QUIT and leaves one).
touch "$work/before-quit"
perl -e '$SIG{QUIT} = "DEFAULT"; setpgrp(0, 0); exec "/bin/bash", @ARGV' "$work/quit.sh" &
tool=$!
# Only once the command runs (with_timeout's traps are in place by then), at most 5 s.
for ((tenth = 0; tenth < 50; tenth++)); do
    [[ "$(running "64.$$")" == no ]] || break
    sleep 0.1
done
sleep 0.3
kill -QUIT -- "-$tool"
wait "$tool" 2> /dev/null
check "Ctrl-\\ to the group ends the tool with 131" "$?" 131
sleep 1
# Reports from the tool or its children only (by pid or parentPid: other runs on the machine send QUIT too, and
# ReportCrash rewrites older reports, so names and times alone aren't ours).
reports=''
while IFS= read -r report; do
    grep -Eq "\"(pid|parentPid)\" : $tool," "$report" 2> /dev/null && reports="$reports $report"
done < <(find "$HOME/Library/Logs/DiagnosticReports" -name '*.ips' -newer "$work/before-quit" 2> /dev/null)
check "and leaves no crash report" "$reports" ""

# A tool that ignores INT (started with `&`) keeps its whole limit under a storm of INTs to its group: the poll's pauses
# aren't cut short.
cat > "$work/storm.sh" <<EOF
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
set +e
start=\$SECONDS
with_timeout 3 sleep 71.$$
echo "\$? \$(( SECONDS - start ))" > "$work/storm.out"
EOF
perl -e '$SIG{INT} = "IGNORE"; setpgrp(0, 0); exec "/bin/bash", @ARGV' "$work/storm.sh" &
tool=$!
perl -e 'for (1 .. 60) { kill "INT", -$ARGV[0]; select undef, undef, undef, 0.03 }' "$tool"
wait "$tool"
read -r storm_status storm_seconds < "$work/storm.out"
check "an ignored INT storm doesn't end the limit early: status" "$storm_status" 124
check "after the whole limit" "$(( storm_seconds >= 3 ))" 1

# stop_group with a start time that isn't PGID's leader's (a reused PID) signals nothing.
perl -e 'setpgrp(0, 0); if (!fork) { exec "sleep", $ARGV[0] } sleep 30' "69.$$" &
victim=$!
sleep 1
stop_group "$victim" "Thu Jan 1 00:00:00 1970"
check "stop_group leaves a leader with another start time alone" "$(kill -0 "$victim" 2> /dev/null && echo alive)" alive
check "and its group" "$(running "69.$$")" yes
kill -KILL -- "-$victim" 2> /dev/null
wait "$victim" 2> /dev/null

# stop_tree with a start time that isn't PID's (a reused PID) leaves the process and its group alone.
perl -e 'setpgrp(0, 0); if (!fork) { exec "sleep", $ARGV[0] } sleep 30' "65.$$" &
victim=$!
sleep 1
stop_tree "$victim" "Thu Jan 1 00:00:00 1970"
check "stop_tree leaves a PID with another start time alone" "$(kill -0 "$victim" 2> /dev/null && echo alive)" alive
check "and its group" "$(running "65.$$")" yes
kill -KILL -- "-$victim" 2> /dev/null
wait "$victim" 2> /dev/null

# A PID that reads as gone, then names a lone process (reused in between: a `ps` first on PATH reports no start time
# for it), isn't signalled: a gone PID only has its group stopped, and this one has none.
mkdir "$work/gone-shim"
cat > "$work/gone-shim/ps" <<'EOF'
#!/bin/bash
[[ "$*" == "-o lstart= -p "* ]] && exit 1
exec /bin/ps "$@"
EOF
chmod +x "$work/gone-shim/ps"
sleep 72.$$ &
lone=$!
PATH="$work/gone-shim:$PATH" stop_tree "$lone" "Thu Jan 1 00:00:00 1970"
check "stop_tree leaves a lone process that took a gone PID alone" "$(running "72.$$")" yes
kill "$lone" 2> /dev/null
wait "$lone" 2> /dev/null

# A leader that has exited (and been reaped) still has the members of its group stopped.
perl -e 'setpgrp(0, 0); if (!fork) { exec "sleep", $ARGV[0] } sleep 1' "66.$$" &
leader=$!
leader_start="$(process_start "$leader")"
wait "$leader"
stop_tree "$leader" "$leader_start"
check "stop_tree stops a reaped leader's group" "$(running "66.$$")" no

# More Ctrl-Cs (or a hang-up to the group: a closed terminal) while stop_tree works can't end the tool, or cut its
# listing short, before a grandchild in a group of its own is stopped: a `ps` first on PATH sends the signal to its own
# group (as a terminal does) every time it runs once the stop has begun (a start time read empty would make stop_tree
# take the command for gone).
mkdir "$work/shim"
cat > "$work/shim/ps" <<EOF
#!/bin/bash
if [[ -f "$work/fire" ]]; then touch "$work/fired"; kill -"\$(cat "$work/fire")" 0; fi
exec /bin/ps "\$@"
EOF
chmod +x "$work/shim/ps"
for signal in INT HUP; do
    tag="68${#signal}.$$"
    cat > "$work/second.sh" <<EOF
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
with_timeout 30 perl -e 'if (!fork) { setpgrp(0, 0); exec "sleep", "$tag" } sleep 60'
EOF
    rm -f "$work/fired"
    PATH="$work/shim:$PATH" perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; setpgrp(0, 0); exec "/bin/bash", @ARGV' \
        "$work/second.sh" &
    tool=$!
    sleep 2
    echo "$signal" > "$work/fire"
    kill -INT -- "-$tool"
    wait "$tool"
    rc=$?
    want=130
    [[ $signal == INT ]] || want=129
    check "$signal to the group during stop_tree: the tool ends with $want" "$rc" "$want"
    rm -f "$work/fire"
    check "and the $signal reached the stop" "$([[ -e "$work/fired" ]] && echo fired)" fired
    sleep 1
    check "and the grandchild in a group of its own is stopped" "$(running "$tag")" no
done

# Ctrl-C while a timeout's stop waits on a command that ignores TERM isn't lost: the tool ends with 130, not 124, and
# only once the stop is done (its EXIT trap finds the command's grandchild, in a group of its own, already stopped).
cat > "$work/stubborn.sh" <<EOF
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
set +e
trap 'pgrep -f "^sleep 70.$$\$" > /dev/null && echo alive > "$work/stubborn.exit"' EXIT
with_timeout 1 perl -e '\$SIG{TERM} = "IGNORE"; if (!fork) { setpgrp(0, 0); exec "sleep", "70.$$" } exec { "sleep" } "sleep", "67.$$"'
echo "returned \$?" > "$work/stubborn.out"
EOF
perl -e '$SIG{INT} = "DEFAULT"; setpgrp(0, 0); exec "/bin/bash", @ARGV' "$work/stubborn.sh" &
tool=$!
sleep 2.5
kill -INT -- "-$tool"
wait "$tool"
check "Ctrl-C during a timeout's stop ends the tool with 130" "$?" 130
check "rather than returning 124" "$(cat "$work/stubborn.out" 2> /dev/null)" ""
check "and the command is stopped" "$(running "67.$$")" no
check "and its EXIT trap ran after the stop" "$(cat "$work/stubborn.exit" 2> /dev/null)" ""
check "and the grandchild is stopped" "$(running "70.$$")" no

# A caller trap whose text names other signals doesn't count as a trap on them: with_timeout's own INT and QUIT traps
# are removed afterwards, so Ctrl-C ends the tool again.
cat > "$work/named.sh" <<EOF
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
set +e
trap 'echo got SIGINT or SIGQUIT' TERM
with_timeout 5 true
echo "INT: \$(trap -p INT) QUIT: \$(trap -p QUIT)"
EOF
check "a trap naming other signals leaves no with_timeout trap behind" "$(/bin/bash "$work/named.sh")" "INT:  QUIT: "

# QUIT to a caller whose (TERM) trap text names SIGQUIT still exits 131 with its EXIT trap run: it has no QUIT trap.
cat > "$work/named-quit.sh" <<EOF
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap 'echo got SIGQUIT' TERM
trap 'touch "$work/named-quit-cleaned"' EXIT
with_timeout 30 sleep 75.$$
EOF
perl -e '$SIG{QUIT} = "DEFAULT"; exec "/bin/bash", @ARGV' "$work/named-quit.sh" &
tool=$!
sleep 1
kill -QUIT "$tool"
wait "$tool" 2> /dev/null
check "QUIT to a caller whose trap text names SIGQUIT ends it with 131" "$?" 131
check "and its EXIT trap ran" "$([[ -e "$work/named-quit-cleaned" ]] && echo yes)" yes

# A hang-up to the group while with_timeout reads COMMAND's start time (a `ps` first on PATH holds it for 2 s) doesn't
# end a plain call under set -e before COMMAND is stopped.
mkdir "$work/slow-ps"
cat > "$work/slow-ps/ps" <<EOF
#!/bin/bash
if [[ "\$*" == "-o lstart= -p "* && -f "$work/slow" ]]; then rm -f "$work/slow"; sleep 2; fi
exec /bin/ps "\$@"
EOF
chmod +x "$work/slow-ps/ps"
cat > "$work/hup-start.sh" <<EOF
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
with_timeout 30 sleep 76.$$
EOF
touch "$work/slow"
PATH="$work/slow-ps:$PATH" perl -e 'setpgrp(0, 0); exec "/bin/bash", @ARGV' "$work/hup-start.sh" &
tool=$!
sleep 1
kill -HUP -- "-$tool"
wait "$tool"
check "HUP while the start time is read ends the tool with 129" "$?" 129
sleep 1
check "and the command is stopped" "$(running "76.$$")" no

# A trapped signal ends the poll's pause at once, not at the pause's end: TERM to a tool polling in 1 s pauses.
cat > "$work/latency.sh" <<EOF
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
with_timeout 30 sleep 73.$$
EOF
/bin/bash "$work/latency.sh" &
tool=$!
sleep 2.2
sent="$(perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000')"
kill -TERM "$tool"
wait "$tool" 2> /dev/null
ended="$(perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000')"
check "TERM during a 1 s pause ends the tool within 600 ms" "$(( ended - sent < 600 ))" 1

# need_xcode_tools: names the tool xcrun can't find, and leaves no files behind.
check "need_xcode_tools names a missing tool" \
    "$(TMPDIR="$work" /bin/bash -c "source '$(dirname "$0")/../lib/common.sh'; xtool() { [[ \$1 == nm ]] || echo /x/\$1; }; need_xcode_tools" 2>&1)" \
    "error: xcrun can't find nm (is Xcode selected? xcode-select -p)"
check "need_xcode_tools finds the four" \
    "$(/bin/bash -c "source '$(dirname "$0")/../lib/common.sh'; need_xcode_tools; [[ -x \$OBJDUMP && -x \$OTOOL && -x \$NM && -x \$DEMANGLE ]] && echo all")" all
check "and leaves no files in TMPDIR" "$(find "$work" -maxdepth 1 -name 'xtool*')" ""

# COMMAND starts with INT at its default (not the ignore bash gives background commands): a shell COMMAND can trap it.
check "a shell COMMAND can trap INT" "$(with_timeout 5 /bin/bash -c 'trap "echo trapped" INT; kill -INT $$; true')" trapped

(with_timeout 5) 2> /dev/null
check "with_timeout without a command is bad usage" "$?" 2

# A command named like an option reaches exec, not perl's option parsing.
printf '#!/bin/sh\necho dash-ran\n' > "$work/-dash"
chmod +x "$work/-dash"
check "a command whose name starts with -" "$(PATH="$work:$PATH" with_timeout 5 -dash)" dash-ran

# TOOLS_DIR and EXPERIMENTS_DIR are the same however common.sh's path is spelled (`.`, `..`, doubled slashes, relative).
tools="$(cd "$(dirname "$0")/.." && pwd)"
for spelling in "$tools/lib/common.sh" "$tools/tests/../lib/common.sh" "$tools/./lib/common.sh" "${tools%/*}//Tools/lib/common.sh"; do
    check "TOOLS_DIR from $spelling" "$(/bin/bash -c "source '$spelling'; echo \"\$TOOLS_DIR|\$EXPERIMENTS_DIR\"")" \
        "$tools|${tools%/*}"
done
check "TOOLS_DIR from a relative path" "$(cd "$tools" && /bin/bash -c "source lib/common.sh; echo \"\$TOOLS_DIR\"")" "$tools"

# Start times read the same whatever the caller's time zone and locale.
check "process_start ignores TZ" "$(TZ=Asia/Tokyo process_start $$)" "$(process_start $$)"
check "process_start ignores the locale" "$(LC_ALL=fr_FR.UTF-8 process_start $$)" "$(process_start $$)"

# A signal the caller ignores stays ignored, and the command runs on to its end.
cat > "$work/ignored.sh" <<EOF
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap '' TERM
with_timeout 30 sleep 3
echo "status \$?"
EOF
/bin/bash "$work/ignored.sh" > "$work/ignored.out" &
tool=$!
sleep 1
kill -TERM "$tool"
wait "$tool"
check "an ignored TERM leaves the command running to its end" "$(cat "$work/ignored.out")" "status 0"

start=$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000')
with_timeout 5 true
elapsed=$(( $(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000') - start ))
check "a quick command returns within half a second" "$(( elapsed < 500 ))" 1

# In a terminal (a pty from script(1)), a command that sets terminal modes isn't stopped by SIGTTOU.
cat > "$work/tty.sh" <<EOF
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
with_timeout 10 stty -echo
echo "status \$?"
stty echo
EOF
start=$SECONDS
check "stty -echo in a terminal" "$(script -q /dev/null /bin/bash "$work/tty.sh" < /dev/null | grep -o 'status [0-9]*')" "status 0"
check "and promptly" "$(( SECONDS - start < 5 ))" 1

(need_value --check) 2> /dev/null
check "need_value without a value" "$?" 2
# die, fail, and note keep their statuses with stderr closed (a failed echo under set -e would make them 1).
(set -e; die closed) 2>&-
check "die with stderr closed" "$?" 2
(set -e; note closed; exit 7) 2>&-
check "note with stderr closed" "$?" 7
# Nor with stderr a pipe whose reader has gone (SIGPIPE ends only the subshell writing the message).
perl -e '$SIG{PIPE} = "DEFAULT"; exec "/bin/bash", "-c", @ARGV' \
    "source '$(dirname "$0")/../lib/common.sh'; sleep 0.5; note gone; die gone" 2>&1 | true
check "note and die with stderr's reader gone" "${PIPESTATUS[0]}" 2

# A process table that can't be read (`ps` failing: fork can fail under load) never reads as "nothing left".
# The shim counts the two process-table reads apart (start times: signal_listed and wait_listed; with parents:
# descendants) and fails the calls whose numbers are in ps-fail-at and tree-fail-at, or every start-time read while
# ps-fail-all exists.
mkdir "$work/failing-ps"
cat > "$work/failing-ps/ps" <<EOF
#!/bin/bash
case "\$*" in
    "-A -o pid=,lstart=") kind=ps ;;
    "-A -o pid=,ppid=,lstart=") kind=tree ;;
    *) exec /bin/ps "\$@" ;;
esac
n=\$(( \$(cat "$work/\$kind-count" 2> /dev/null || echo 0) + 1 ))
echo "\$n" > "$work/\$kind-count"
[[ \$kind == ps && -e "$work/ps-fail-all" ]] && exit 1
[[ " \$(cat "$work/\$kind-fail-at" 2> /dev/null) " == *" \$n "* ]] && exit 1
exec /bin/ps "\$@"
EOF
chmod +x "$work/failing-ps/ps"
fresh_shim() { rm -f "$work/ps-count" "$work/tree-count" "$work/ps-fail-at" "$work/tree-fail-at" "$work/ps-fail-all"; }
touch "$work/ps-fail-all"
check "wait_listed counts a listed process as there when ps fails" \
    "$(echo "$$ $(process_start $$)" | PATH="$work/failing-ps:$PATH" wait_listed 0.3)" 1
check "signal_listed fails, printing nothing, when ps fails" \
    "$(echo "$$ $(process_start $$)" | PATH="$work/failing-ps:$PATH" signal_listed 0; echo "rc $?")" "rc 1"
# stop_tree, its `ps` failing at a given point, against a descendant in a group of its own: one that ignores TERM
# (TAG IGNORE) must still be KILLed; one that ends on TERM (TAG MARK FILE) must get the TERM, not only a KILL.
stop_with_failing_ps() {
    perl -e 'setpgrp(0, 0); if (!fork) { setpgrp(0, 0); if ($ARGV[1] eq "IGNORE") { $SIG{TERM} = "IGNORE" } else { $SIG{TERM} = sub { open my $f, ">", $ARGV[2]; exit 0 } } exec { "sleep" } "sleep", $ARGV[0] if $ARGV[1] eq "IGNORE"; sleep 1 while 1 } sleep 60' "$@" &
    local holder=$!
    sleep 0.5
    PATH="$work/failing-ps:$PATH" stop_tree "$holder" 2> /dev/null
    wait "$holder" 2> /dev/null
}
fresh_shim
echo 2 > "$work/ps-fail-at"
stop_with_failing_ps "78.$$" IGNORE
check "a failed ps during stop_tree's wait doesn't skip the KILL" "$(running "78.$$")" no
check "and the failure was met" "$(( $(cat "$work/ps-count" 2> /dev/null || echo 0) >= 2 ))" 1
fresh_shim
echo 1 2 3 4 5 6 7 8 9 10 > "$work/ps-fail-at"
stop_with_failing_ps "79.$$" IGNORE
check "signal_listed failing for good on TERM doesn't skip the wait and the KILL" "$(running "79.$$")" no
fresh_shim
echo 1 > "$work/ps-fail-at"
stop_with_failing_ps "80.$$" MARK "$work/termed-80"
check "signal_listed's ps failing once still delivers the TERM" "$([[ -e "$work/termed-80" ]] && echo yes)" yes
fresh_shim
echo 1 2 > "$work/tree-fail-at"
stop_with_failing_ps "81.$$" IGNORE
check "descendants' ps failing twice still finds the descendant to KILL" "$(running "81.$$")" no
check "and the failures were met" "$(( $(cat "$work/tree-count" 2> /dev/null || echo 0) >= 3 ))" 1
fresh_shim
# descendants whose `ps` fails for good says so and fails, rather than reading as "no descendants".
echo 1 2 3 4 5 6 7 8 9 10 > "$work/tree-fail-at"
desc_out="$(PATH="$work/failing-ps:$PATH" descendants $$ 2> "$work/desc.err")"
check "descendants failing for good: status 1, nothing printed" "$?/$desc_out" "1/"
check "  with a note" "$(grep -c 'process table could not be read' "$work/desc.err")" 1
fresh_shim
(need_number --runs abc) 2> /dev/null
check "need_number rejects abc" "$?" 2
(need_number --seconds 08) 2> /dev/null
check "need_number rejects a leading zero" "$?" 2
(need_number --runs 18446744073709551617) 2> /dev/null
check "need_number rejects a number bash's arithmetic would wrap" "$?" 2
(need_decimal --seconds 1.5)
check "need_decimal takes 1.5" "$?" 0

printf 'int main(void) { return 3; }\n' > "$work/three.c"
binary="$(compiled_tool three "$work/three.c" -O2)"
"$binary"
check "compiled_tool builds" "$?" 3
check "compiled_tool reuses its build" "$(compiled_tool three "$work/three.c" -O2)" "$binary"
printf 'int main(void) { return 4; }\n' > "$work/three.c"
changed="$(compiled_tool three "$work/three.c" -O2)"
"$changed"
check "compiled_tool rebuilds when the source changes" "$?" 4

mkdir "$work/headers"
printf '#define ANSWER 6\n' > "$work/headers/answer.h"
printf '#include "answer.h"\nint main(void) { return ANSWER; }\n' > "$work/headers/six.c"
"$(compiled_tool six "$work/headers/six.c" -O0)"
check "compiled_tool with a header" "$?" 6
printf '#define ANSWER 7\n' > "$work/headers/answer.h"
"$(compiled_tool six "$work/headers/six.c" -O0)"
check "compiled_tool rebuilds when a header beside the source changes" "$?" 7

printf 'int main(void) { return 5; }\n' > "$work/five.c"
(compiled_tool five "$work/five.c" -O0 > /dev/null) & first=$!
(compiled_tool five "$work/five.c" -O0 > /dev/null) & second=$!
wait "$first"; one=$?
wait "$second"; two=$?
check "two concurrent compiled_tool builds both succeed" "$one $two" "0 0"

xcrun clang -O0 -o "$work/prog" "$work/five.c"
for index in 1 2 3 4; do
    (debuggable "$work/prog" > /dev/null 2>&1; echo $? > "$work/signed.$index") &
done
wait
check "four concurrent debuggable calls all succeed" "$(cat "$work"/signed.*)" "$(printf '0\n0\n0\n0')"
check "the debuggable copy has get-task-allow" "$(has_get_task_allow "$work/prog-debuggable" && echo yes)" yes

xcrun clang -O0 -o "$work/readonly" "$work/five.c"
chmod 555 "$work/readonly"
debuggable "$work/readonly" > /dev/null 2>&1
check "the debuggable copy keeps the program's mode" "$(stat -f %Lp "$work/readonly-debuggable")" 555
