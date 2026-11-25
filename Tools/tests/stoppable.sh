#!/bin/bash
# lib/stoppable.sh, through a driver that sources it as Tools/loops, calls, and mca do: an INT during the setup (a
# background command running, a waited-for one that ignores INT, as nm and the demangling are run) ends the tool with
# everything it started; a TERM while run_stoppable waits stops its command at once, and a command that ignores TERM,
# in a pipeline or run directly, is KILLed after 2 s.
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-stoppable.XXXXXX")"
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: got '$2', want '$3'"; exit 1; fi; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
tag="stoppable-check-$$"
# On any exit, a failed check too: what the tool under check left running (none, when it works), and the work directory.
trap 'pkill -KILL -f "^$tag-" 2> /dev/null; rm -rf "$work"' EXIT

cat > "$work/driver" <<EOF
#!/bin/bash
source "$here/../lib/common.sh" || exit 2
source "$here/../lib/stoppable.sh" || exit 2
stop_on_signals
[[ "\$1" == window ]] || scratch_dir
case "\$1" in
    setup)
        perl -e '\$0 = "$tag-background"; sleep 30' &
        run_stoppable perl -e '\$0 = "$tag-foreground"; \$SIG{INT} = "IGNORE"; sleep 1'
        echo finished ;;
    pipeline)
        stubborn() { perl -e '\$0 = "$tag-pipe"; \$SIG{TERM} = "IGNORE"; sleep 30' | cat; }
        run_stoppable stubborn ;;
    root) run_stoppable perl -e '\$0 = "$tag-root"; \$SIG{TERM} = "IGNORE"; sleep 30' ;;
    window)
        # A scratch directory made, the signal arriving before an EXIT trap would remove it.
        SCRATCH="\$(mktemp -d "\${TMPDIR:-/tmp}/experiments-tool.XXXXXX")"
        echo "\$SCRATCH" > "$work/window-dir"
        kill -TERM \$\$
        sleep 5 ;;
    psfail)
        # A ps that fails its first two calls of each kind (as under a process limit): the stop must still list and
        # KILL the command, which ignores TERM.
        export PATH="$work/fakeps:\$PATH" FAKE_PS_COUNTS="$work/fakeps"
        run_stoppable perl -e '\$0 = "$tag-psfail"; \$SIG{TERM} = "IGNORE"; sleep 30' ;;
    psnoanswer)
        # A ps whose -p listings always fail: the stop must take that as "all still there" and KILL at the deadline.
        export PATH="$work/fakeps:\$PATH" FAKE_PS_COUNTS="$work/fakeps" FAKE_PS_FAIL_P=1
        run_stoppable perl -e '\$0 = "$tag-noanswer"; \$SIG{TERM} = "IGNORE"; sleep 30' ;;
    spawner)
        spawner() { while :; do perl -e '\$0 = "$tag-spawn"; sleep 30' & sleep 0.01; done; }
        run_stoppable spawner ;;
esac
EOF
chmod +x "$work/driver"
left() { pgrep -f "^$tag-" | grep -c .; }

# INT to the driver alone during its setup: the foreground command ignores it, then the trap ends the driver.
# (Started with INT at its default: a background command of a non-interactive bash starts with INT ignored, which a
# shell can't trap.)
perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' "$work/driver" setup > "$work/out" 2>&1 &
pid=$!
perl -MTime::HiRes=sleep -e 'sleep 0.3'
kill -INT "$pid"
wait "$pid"
rc=$?
check "INT during the setup: exit 130, not finished, the background command stopped" "$rc $(grep -c finished "$work/out") $(left)" "130 0 0"

for mode in pipeline root; do
    "$work/driver" "$mode" > /dev/null 2>&1 &
    pid=$!
    perl -MTime::HiRes=sleep -e 'sleep 0.5'
    t0="$(now)"
    kill -TERM "$pid"
    wait "$pid"
    rc=$?
    t="$(perl -e "print $(now) - $t0 >= 1.9 && $(now) - $t0 < 3 ? 'about 2 s' : $(now) - $t0")"
    check "TERM, the $mode ignoring it: exit 143 after about 2 s, KILLed" "$rc $t $(left)" "143 about 2 s 0"
    pkill -KILL -f "^$tag-" 2> /dev/null || true
done

# TERM while the command keeps starting processes (as a pipeline starts its next command): none outlives the driver,
# not even one started after the stop first listed them.
"$work/driver" spawner > /dev/null 2>&1 &
pid=$!
perl -MTime::HiRes=sleep -e 'sleep 0.5'
kill -TERM "$pid"
wait "$pid"
rc=$?
check "TERM while processes are being started: exit 143, none left right after" "$rc $(left)" "143 0"
pkill -KILL -f "^$tag-" 2> /dev/null || true

# A signal between making the scratch directory and scratch_dir's EXIT trap: the directory is removed all the same.
"$work/driver" window > /dev/null 2>&1
rc=$?
check "a signal before scratch_dir's EXIT trap: exit 143, the scratch directory removed" \
    "$rc $(test -s "$work/window-dir" && echo named) $(test -e "$(cat "$work/window-dir")" && echo left || echo removed)" "143 named removed"

# A `ps` that fails at first (each kind of call fails twice): retried, so the command, which ignores TERM, is still found
# and KILLed after the 2 s.
mkdir "$work/fakeps"
printf '#!/bin/bash\n[[ -z "$FAKE_PS_FAIL_P" || " $* " != *" -p "* ]] || exit 1\nf="$FAKE_PS_COUNTS/count-$(echo "$*" | tr -c "a-z" "_")"\nn="$(cat "$f" 2> /dev/null || echo 0)"\necho $((n + 1)) > "$f"\n[[ $n -ge 2 ]] || exit 1\nexec /bin/ps "$@"\n' > "$work/fakeps/ps"
chmod +x "$work/fakeps/ps"
"$work/driver" psfail > /dev/null 2>&1 &
pid=$!
perl -MTime::HiRes=sleep -e 'sleep 0.5'
kill -TERM "$pid"
wait "$pid"
rc=$?
check "TERM, ps failing at first: exit 143, the command KILLed" "$rc $(left)" "143 0"
pkill -KILL -f "^$tag-" 2> /dev/null || true

# A ps whose -p listings (the wait for the TERMed processes to go) always fail, past the stop's own retries: no answer
# means all still there, so the command, which ignores TERM, is KILLed at the deadline rather than left running.
rm -f "$work"/fakeps/count-*
"$work/driver" psnoanswer > /dev/null 2>&1 &
pid=$!
perl -MTime::HiRes=sleep -e 'sleep 0.5'
kill -TERM "$pid"
wait "$pid"
rc=$?
check "TERM, ps -p never answering: exit 143, the command KILLed" "$rc $(left)" "143 0"
pkill -KILL -f "^$tag-" 2> /dev/null || true
