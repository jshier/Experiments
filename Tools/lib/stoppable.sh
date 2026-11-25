# shellcheck shell=bash
# stoppable.sh — for Tools/loops, calls, and mca, sourced after lib/common.sh.
#
# stop_on_signals: from now on a TERM, HUP, or INT sent to the tool's own process (what `gtimeout` and `kill PID` send;
# a Ctrl-C) stops everything the tool started and ends it with the signal's status (143, 129, 130; the EXIT trap
# runs). Call it first, before read_input_stoppable and scratch_dir (the scratch directory, and a --target build's
# directory, are removed even when the signal comes before their EXIT trap), so a signal during the setup isn't lost:
# without a trap a non-interactive bash dies at once and leaves its background commands (the objdump of __const) running.
#
# run_stoppable COMMAND...: runs COMMAND (a shell function holding a pipeline, or a program) in the background and
# waits for it, so the trap runs at once. Run anything that takes time this way (nm and the demangling too): bash runs
# a trap only after a foreground command ends, and drops an INT it got meanwhile when that command didn't die of it (it
# never got it). A signal during a short foreground command (a one-line Perl) acts when that command ends; an INT then
# is lost. Exit status: COMMAND's.
#
# The stop: every process the tool started is frozen (STOP), listed again until no new one appears (so one started
# after a snapshot can't escape), sent TERM and CONT, and KILLed if still there after 2 s, its own commands included; it
# returns as soon as they're gone (as common.sh's stop_tree does). A process that has exited but not been
# reaped (a zombie) counts as gone.
stop_on_signals() {
    trap '_rs_signalled 143' TERM
    trap '_rs_signalled 129' HUP
    trap '_rs_signalled 130' INT
}

run_stoppable() {
    "$@" &
    wait "$!"
}

# read_input_stoppable ARGS...: common.sh's read_input, with a --target build run through run_stoppable (inside `$(…)`
# a signal would wait for the whole build, which then ran on), its log and its result in a directory of its own
# (TARGET_LOG_DIR), removed with them when a signal stops the build. The build keeps the caller's TMPDIR: SwiftPM's
# lock between builds of one package lives there (a private one made concurrent builds fail, "database is locked").
# shellcheck disable=SC2034 # INPUT and INPUT_ARGS are read_input's, read by the tool.
read_input_stoppable() {
    if [[ "${1:-}" != --target ]]; then
        read_input "$@"
        return
    fi
    local rc=0
    need_xcode_tools
    [[ $# -ge 3 ]] || usage 2
    _RS_TARGET="$(mktemp -d "${TMPDIR:-/tmp}/experiments-target.XXXXXX")"
    run_stoppable _rs_target_object "$2" "$3" || rc=$?
    [[ $rc == 0 && -s "$_RS_TARGET/object" ]] || { rm -rf "$_RS_TARGET"; exit "$(( rc == 0 ? 2 : rc ))"; }
    INPUT="$(cat "$_RS_TARGET/object")"
    INPUT_ARGS=3
    rm -rf "$_RS_TARGET"
    _RS_TARGET=''
}
_rs_target_object() { TARGET_LOG_DIR="$_RS_TARGET" target_object "$1" "$2" > "$_RS_TARGET/object"; }

_rs_signalled() { # _rs_signalled STATUS
    trap '' TERM HUP INT
    _rs_stop "$$"
    # The scratch directory, when the signal came before scratch_dir set its EXIT trap (only a directory scratch_dir names).
    if [[ "${SCRATCH:-}" == */experiments-tool.* && -d "$SCRATCH" ]]; then rm -rf "$SCRATCH"; fi
    if [[ "${_RS_TARGET:-}" == */experiments-target.* && -d "$_RS_TARGET" ]]; then rm -rf "$_RS_TARGET"; fi   # a --target build's
    exit "$1"
}

_rs_stop() { # _rs_stop PID: stop PID's descendants (not PID); KILL to those left after 2 s
    # Frozen first (STOP), then listed again until no new one appears, so a process started after a snapshot (a pipeline's
    # next command) can't escape; then TERM and CONT to all. This perl and its `ps` are left out.
    perl -MTime::HiRes=time -e '
        my $root = shift;
        # A `ps` that fails (it lists no one, not even itself) is run again: read as "no one", it would end the listing,
        # or the wait before the KILL, early.
        my $ps = sub { for (1 .. 50) { my @lines = `ps @_ 2>/dev/null`; return @lines if grep { (split)[0] == $$ } @lines; select undef, undef, undef, 0.02 } return () };
        my $descendants = sub {
            my %children;
            for ($ps->("-A", "-o", "pid=,ppid=")) { my ($pid, $parent) = split; push @{$children{$parent}}, $pid }
            my @all;
            my @todo = ($root);
            while (@todo) {
                for my $child (@{$children{shift @todo} || []}) {
                    next if $child == $$;   # this perl (and so its ps)
                    push @all, $child;
                    push @todo, $child;
                }
            }
            return @all;
        };
        my (%seen, @pids);
        for (1 .. 20) {
            my @new = grep { !$seen{$_}++ } $descendants->();
            last unless @new;
            kill "STOP", @new;
            push @pids, @new;
        }
        exit 0 unless @pids;
        kill "TERM", @pids;
        kill "CONT", @pids;
        my $alive = sub {   # those still running: neither gone nor a zombie (this perl listed too: a `ps` that fails lists no one)
            my @lines = $ps->("-o", "pid=,stat=", "-p", join(",", $$, @pids));
            return @pids unless @lines;   # no answer: all still there, until the deadline
            my %state = map { (split)[0, 1] } @lines;
            grep { defined $state{$_} && $state{$_} !~ /^Z/ } @pids;
        };
        my $deadline = time + 2;
        while (1) {
            @pids = $alive->();
            last unless @pids && time < $deadline;
            select undef, undef, undef, 0.02;
        }
        kill "KILL", @pids if @pids;' "$1" || true
}
