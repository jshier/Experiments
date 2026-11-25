#!/bin/bash
# Tools/untracked: output, directory, and exit status come back; --timeout stops the command and removes the job; when
# the tool is killed outright (SIGKILL), the job stops the command's process group and removes itself; when the job's
# wrapper is killed outright, launchd's restart of it stops the command (by the start time, or by the PID the command
# wrote itself) and removes the job; a reused --keep runs again; a tool in another time zone is still seen as alive.
#
# The commands are Perl sleepers, `/usr/bin/perl -e 'sleep N' MARKER`, found as running processes by their exact
# command line (`sleeping N`): never the tool's or the wrapper's own command lines, which hold the same words quoted.
# (macOS's sleep takes several intervals and fails on a marker word, so `sleep N MARKER` would end at once.)
set -u
tool="$(cd "$(dirname "$0")/.." && pwd)/untracked"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-untracked.XXXXXX")"
marker="check-untracked-$$"
sleeper() { echo "/usr/bin/perl -e 'sleep $1' $marker"; }
sleeping() { pgrep -f "^/usr/bin/perl -e sleep $1 $marker\$" > /dev/null; }
cleanup() {
    pkill -KILL -f "^/usr/bin/perl -e sleep 5[0-9] $marker\$" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }
jobs_left() { launchctl list | grep -c "local\.experiments\.untracked\.$1\." ; }

cd "$work" || exit 1
out="$("$tool" -- /bin/sh -c 'pwd -P; exit 5' 2> /dev/null)"
check "exit status" "$?" 5
check "directory" "$out" "$(pwd -P)"
out="$(env CHECK_VALUE=passed 'CHECK_EQUALS=b=c' "$tool" -- /bin/sh -c 'echo "$CHECK_VALUE $CHECK_EQUALS"' 2> /dev/null)"
check "exported variables, one holding an =" "$out" "passed b=c"

# A caller's umask that would leave the job's own files unreadable (0477): the job still starts, and the command gets
# the umask.
out="$( (umask 0477; "$tool" --timeout 20 -- /bin/sh -c 'umask') 2> /dev/null)"
check "a caller's umask of 0477: the command runs, with it" "$?/$out" "0/0477"

"$tool" --timeout 3 -- /bin/sh -c "$(sleeper 51) & $(sleeper 52)" 2> /dev/null
check "--timeout fails" "$?" 1
sleep 1
sleeping '5[12]'
check "--timeout stopped the command's group" "$?" 1

# The tool's scratch directory (a copy of the caller's environment) goes in a temporary directory of its own here, so
# the check can see that the job removes it.
mkdir "$work/tmp"
TMPDIR="$work/tmp" "$tool" -- /bin/sh -c "$(sleeper 53) & $(sleeper 54)" 2> /dev/null &
victim=$!
for ((i = 0; i < 40; i++)); do
    [[ "$(jobs_left "$victim")" == 1 ]] && sleeping 53 && sleeping 54 && break
    sleep 0.25
done
check "job running, both sleepers too" "$(jobs_left "$victim")/$(sleeping 53 && sleeping 54 && echo both)" 1/both
kill -KILL "$victim"
wait "$victim" 2> /dev/null
for ((i = 0; i < 20; i++)); do
    [[ "$(jobs_left "$victim")" == 0 ]] && ! sleeping '5[34]' && break
    sleep 0.5
done
sleeping '5[34]'
check "after SIGKILL of the tool: the command stopped" "$?" 1
check "after SIGKILL of the tool: the job removed itself" "$(jobs_left "$victim")" 0
check "after SIGKILL of the tool: its job directory is gone" "$(find "$work/tmp" -mindepth 1 | grep -c .)" 0

"$tool" --keep "$work/keep" -- /bin/sh -c 'echo first; exit 3' > /dev/null 2>&1
check "--keep, first run" "$?" 3
out="$("$tool" --keep "$work/keep" -- /bin/sh -c 'echo second; exit 4' 2> /dev/null)"
check "--keep reused: the second run's status" "$?" 4
check "--keep reused: the second run's output" "$out" second

# The wrapper killed outright: launchd restarts it (launchd itself leaves the command running), and the restart stops
# the first one's command, found by the PID and start its launcher wrote. Once as it happens; once with the `command`
# file pointing at a decoy instead (a live process leading a group of its own, as a reused PID might), whose start
# differs from the one written: the restart must leave it alone.
kill_wrapper() {
    local name="$1" decoy="$2" owner wrapper i decoy_pid=''
    "$tool" --keep "$work/$name" -- /bin/sh -c "$(sleeper 55) & $(sleeper 56)" > /dev/null 2>&1 &
    owner=$!
    for ((i = 0; i < 40; i++)); do
        [[ "$(jobs_left "$owner")" == 1 && -f "$work/$name/command" ]] && sleeping 55 && sleeping 56 && break
        sleep 0.25
    done
    check "$name: both sleepers running" "$(sleeping 55 && sleeping 56 && echo both)" both
    if [[ -n "$decoy" ]]; then
        /usr/bin/perl -e 'setpgrp(0, 0); sleep 57' "$marker" &
        decoy_pid=$!
        sleep 1
        echo "$decoy_pid $(( $(date +%s) - 3 ))" > "$work/$name/command" # 3 s before the decoy started
    fi
    wrapper="$(launchctl list | perl -ane "print \$F[0] if \$F[2] =~ /^local\\.experiments\\.untracked\\.$owner\\./")"
    check "$name: found the wrapper" "$([[ "$wrapper" =~ ^[0-9]+$ ]] && echo yes || echo "no: '$wrapper'")" yes
    kill -KILL "$wrapper"
    sleep 1
    check "$name: the command outlives its killed wrapper" "$(sleeping 56 && echo running)" running
    wait "$owner"
    check "$name: the tool fails" "$?" 2
    if [[ -n "$decoy" ]]; then
        check "$name: the restart left the decoy alone" "$(kill -0 "$decoy_pid" 2>/dev/null && echo alive)" alive
        kill -KILL "$decoy_pid"
        wait "$decoy_pid" 2>/dev/null
        pkill -KILL -f "^/usr/bin/perl -e sleep 5[56] $marker\$"
    else
        for ((i = 0; i < 20; i++)); do
            sleeping '5[56]' || break
            sleep 0.5
        done
        sleeping '5[56]'
        check "$name: the restarted wrapper stopped the first one's command" "$?" 1
    fi
    check "$name: and removed the job" "$(jobs_left "$owner")" 0
}
kill_wrapper killed-wrapper ''
kill_wrapper reused-pid decoy

# The caller's variables reach the command, never the wrapper's own shell (whose state has such names).
out="$(env dir=/nowhere tool=1 tool_start=x label=y launcher=z same_process=w "$tool" -- /bin/sh -c 'echo "$dir $label"; exit 4' 2> /dev/null)"
check "variables named like the wrapper's: the command's exit status" "$?" 4
check "variables named like the wrapper's: the command sees them" "$out" "/nowhere y"

# The caller's umask and soft descriptor limit (launchd's are 0022 and 256).
out="$(umask 077; ulimit -Sn 300; "$tool" -- /bin/sh -c 'umask; ulimit -n' 2> /dev/null | tr '\n' ' ')"
check "the umask and descriptor limit" "$out" "0077 300 "

# The tool in another time zone and locale than launchd's: the wrapper must still see the tool as alive.
out="$(TZ=Asia/Tokyo LC_ALL=ja_JP.UTF-8 "$tool" -- /bin/sh -c 'sleep 2; echo zoned; exit 6' 2> /dev/null)"
check "another time zone: the command runs to its end" "$?/$out" "6/zoned"

"$tool" --timeout 2>/dev/null
check "--timeout without a value" "$?" 2
"$tool" --timeout abc -- true 2>/dev/null
check "--timeout abc" "$?" 2

# A job launchd never starts (a fake `launchctl` first on PATH: `submit` loads nothing that runs, `list` shows it loaded
# with no PID and a last exit status, `remove` forgets it): the run fails within seconds, with that status, not waiting
# forever, and leaves nothing behind.
mkdir -p "$work/fake/bin" "$work/fake/tmp"
cat > "$work/fake/bin/launchctl" <<FAKE
#!/bin/bash
case "\$1" in
    submit) touch "$work/fake/loaded" ;;
    list) [[ -e "$work/fake/loaded" ]] || exit 1; printf '{\n\t"LastExitStatus" = 19968;\n\t"Label" = "%s";\n};\n' "\$2" ;;
    remove) rm -f "$work/fake/loaded" ;;
esac
FAKE
chmod +x "$work/fake/bin/launchctl"
t0=$SECONDS
PATH="$work/fake/bin:$PATH" TMPDIR="$work/fake/tmp" "$tool" --timeout 20 -- /bin/echo never > "$work/out" 2> "$work/err"
rc=$?
check "a job launchd never starts: exit 2, within 10 s" "$rc/$(( SECONDS - t0 <= 10 ))" "2/1"
check "with launchd's status" "$(grep -c "couldn't start.*19968" "$work/err")" 1
check "and nothing left behind" "$(find "$work/fake/tmp" -mindepth 1 | grep -c .)/$([[ -e "$work/fake/loaded" ]] && echo loaded)" "0/"
