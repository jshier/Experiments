# Tools

The full reference for the analysis tools in this directory, the toolchains, the two LLVMs, and the macOS and
Homebrew tools they build on (moved out of AGENTS.md on 2026-11-25; AGENTS.md has the summary and the workflow).
Every tool also prints its usage with `--help`. The last sections, Tests and Benchmarks, are the full rules for running
them, with the numbers behind each.

All tools share conventions (`Tools/lib/common.sh`): `--help` prints usage; results on stdout,
tab-separated where tabular (pipe to `column -t -s $'\t'`); notes on stderr; exit 0 success, 1 a check
failed, 2 bad usage or missing dependency. Xcode tools are found with `xcrun`, so `TOOLCHAINS=<bundle id>`
switches the toolchain for every tool. They're bash and Perl only (plus jq/yq where noted), no gawk/GNU sed
needed.

## Tools

### Static: what the compiler produced

`loops`, `calls`, and `mca` read compiled code from `FILE` (an object or binary) or from `--target
PACKAGE_DIR TARGET` (built release, objects merged into `.build/agent-tools/TARGET.o`; honors `TOOLCHAINS`; the build
waits for another build of the same package, as `swift build` does, its own SwiftPM temporary directories stay in
TMPDIR, as with `swift build`, and a TERM, HUP, or INT stops it with the tool).

**`Tools/loops FILE|--target PKG TARGET PATTERN [--tsv] [--body] [--require OPS] [--forbid OPS]`** — the natural
loops of each matching function's control-flow graph (`lib/loops.pl`: basic blocks from numeric branch targets,
dominators, a back edge latch→header where the header dominates the latch, the body every block that reaches the
latch without passing the header, loops sharing a header merged), `irreducible` loops (cycles entered at more than
one block that no natural loop explains, such as a vectorizer's remainder or a retry loop; their entries are their
headers), and `natural+side-entry` loops (a cycle that is a natural loop plus side blocks with no cycle of their own,
also entered from before the loop: a refill path laid out before the header, an outer loop whose preheader can be
bypassed; headed by the natural loop's header, which keeps its own row, so an innermost loop never grows). Depth comes
from containment. A loop's blocks need not be contiguous: a cold path LLVM lays out after the return belongs to the
loop that branches to it. A branch with a relocation, or out of the function, is a tail call, not a loop; a branch to
its own address without a relocation is a one-instruction loop. A `switch`'s `br` leads to its cases, read from the
table in `__const`: the count from a bounds check every path passes, else from the index's width (`ldrb`/`ldrh`,
`uxtb`/`uxth`, an `and` mask, `ubfx`, `lsr`, `mov`, traced back to the index's last write; a call writes x0–x18 and
x30), capped by the table's extent: the nearer of the next symbol and the next address in `__const` the code refers
to (an object's PAGEOFF12 relocations and addends, from `otool -r`, by symbol number, so each copy in a merged
object is its own; in a linked binary the `adrp`s decoded from `__text`, with their
`add` or load/store offsets), so another function's table is never read as cases. A table without a bounds check stops
before its first entry outside the function; one that nothing bounds but its section's end stops at its last entry
naming a block only a table reaches. Relocations (names may hold spaces) and merged objects' duplicate symbols
included. A table that can't be read has its cases placed by position, with a warning. The file is read by its own
header (`lib/macho.pl`): a universal file for its arm64 slice (else arm64e, else arm64e.x1 or another arm64e one), copied out
by the fat table's offset and size;
archives, dSYM debug files, truncated files, other architectures, and other files refused (exit 2); a binary stripped of local symbols (over a quarter of its function starts without one) gets a
warning; only text symbols in code sections are functions. The file is disassembled once (the listed symbols while
their names take at most 512 KB, or what ARG_MAX leaves after the environment, `LOOPS_LIST_MAX`; an objdump that fails
(E2BIG) is an error, exit 2, never "no loops"; listing costs in proportion to the code it covers, nunzip's whole
file 1.3 s) and functions are analysed in parallel, one process per performance core (`LOOPS_JOBS=1` for one, at most
999999, capped at four per core). TERM, HUP, or INT to the tool, from its start, stops everything it started (a
`--target` build too, its build directory removed; frozen and
listed again until nothing new appears, then TERM, KILL after 2 s), removes its scratch directory, and exits 143, 129,
or 130: about 0.5 s for a 2 MB object (was about 20 s), 2 s for nunzip. Known
limit: a linked binary's table followed by constants no `adrp` refers to directly reads them as entries. Output doesn't depend on Perl's hash order; a worker that fails
stops the run (exit 2).
Per loop: span, instruction count, depth, mix, a header/pieces line when it isn't one contiguous run, and a
verdict over its own instructions: `vector128`, `vector64` (often a vectorizer epilogue), `scalar`, `+lane-moves`
(single lanes moved with `mov.b v3[2], w12`/`ins`/`umov`: a shuffle built a lane at a time), `+calls`. `--tsv` adds
headers (comma-separated), pieces, and `natural|irreducible` columns; `--body` prints the blocks in address order
with gaps marked. (Until 2026-11-24 it took any backward branch as a loop's end: it invented loops, split loops with two
back edges, and counted tail calls; counts quoted before then may differ, see the re-check in Bytes'
Benchmarks/RESULTS.md.) `--require`/`--forbid` make it an assertion (exit 1):

```sh
Tools/loops --target Bytes BytesBase64 encodeBlocks --require tbl,zip --forbid mov.b,ins
Tools/loops --target Bytes BytesBase64 'encode\(_:into:alphabet:\)' --require ld3.16b,st4.16b
```
PATTERN is a regex on simplified demangled names, which don't include parameter types: anchor it (`…:\)`)
or overloads and similarly named functions match too and must each pass.

**`Tools/remarks FILE.swift [-- swiftc args]` / `Tools/remarks --target PKG TARGET`** — optimization remarks
from Swift's own LLVM: loops vectorized (with width) or not and why ("Cannot vectorize early exit loop" =
usually a bounds-check trap; "loop control flow is not understood" = branches in the body). `--passes` picks
others: `sil-inliner`, `sil-generic-specializer`, `inline`, `slp-vectorizer`, `licm`. One line per distinct remark,
its count first: two loops inlined from one library function report the same location and count 2.

**`Tools/swiftc-target [--debug] [--refresh] [--print] PKG TARGET -- ARGS`** — a SwiftPM target's exact
`swiftc` command (captured from `swift build -v`), with outputs stripped, the working directory set to yours, and
your arguments added: `-emit-sil -o /abs/x.sil`, `-emit-ir -o /abs/x.ll`, `-S -o /abs/x.s`. The target is built first
(`swift build --target`), and the command is cached in `.build/agent-tools/` per toolchain (`xcrun --find swiftc`),
captured again when `Package.swift` is newer, the target's Swift files change, or the cached swiftc is gone. The way
to get SIL, IR or remarks for a package target with its real flags and dependencies. (`-Xswiftc -save-optimization-record` in
a normal SwiftPM build produces empty records or multi-threaded-WMO errors.)

**`Tools/calls FILE|--target PKG TARGET PATTERN [--callee REGEX] [--sum]`** — static call sites per caller
and callee (demangled): from relocations in objects (`objdump -dr`); in linked binaries, from objdump with targets named from the stubs
(`otool -Iv`) or the symbol at the address. Kinds: `call` (`bl`; `blr` as `(indirect)`), `tail` (`b`
to a symbol), `jump` (`br`: `(jump table)` when its register was last written by an `add` of a table entry, else
`(indirect)`). One disassembly and one bulk demangle for all matches (about 0.5 s for a 2 MB object). Exit 1 when
nothing matches
(`--callee swift_retain` finding none is that answer). Aliases are counted like the function they name. A name defined in several merged
objects (or several objects of a linked binary) gets a note; its counts cover every copy. Callee names are read whole
(Objective-C methods hold spaces); a call to an address with several names is named by the lowest. The file is read by its
own header, as for loops (universal files' arm64 slice; archives and other architectures refused; a stripped binary
warned about: a static function's calls count toward the function before it), disassembled for the listed matches up
to 512 KB of names, and stopped with everything it started by TERM, HUP, or INT from its start (a `--target` build
included). objdump's failure (E2BIG) exits 2, never "no calls"; the
listing's size adapts to the environment (`CALLS_LIST_MAX`).

**`Tools/sil-trace FILE.swift FUNCTION MATCH` / `--target PKG TARGET FUNCTION MATCH`** — prints the SIL
instructions matching MATCH after every pass that changed them (`-Xllvm -sil-print-function=…
-sil-print-all`, which release compilers accept). Finds the pass that introduces or fails to remove a
`release_value`, `destroy_addr`, `alloc_box`, `apply`.

**`Tools/mca FILE PATTERN [--loop N] [--cpu apple-m3] [--bottleneck] [--full]`** — llvm-mca on the loop `Tools/loops`
finds (all its blocks in layout order, branches included, pc-relative targets rewritten to `.` so loops anywhere in
large objects and linked binaries work; a name defined in several merged objects says which copy it used; it shares
`Tools/loops`' disassembly, and an irreducible loop is shown with its entries): block
reciprocal throughput, IPC, busiest units;
`--bottleneck` adds llvm-mca's bottleneck analysis. llvm-mca runs 500 iterations of loops up to 100 instructions, 50
from 1,000 (50,000 instructions in all between): an 11,610-instruction loop in 1.3 s instead of 5.2, the same
throughput and IPC. With several matches it uses the first (its loops or "no loops in" it) and names ten others. Tools/loops' own
failure (exit 2 or more: objdump's E2BIG, a bad file) is passed on with its message and status, never read as "no
loops". TERM, HUP, or INT stops it and everything it started, from its start (a `--target` build included).
llvm-mca's warnings reach stderr; calls in the loop (`bl`/`blr`,
modelled as 100 cycles) and several matching functions (the first is used) are warned about. Homebrew LLVM. Treat it as a lower bound only: LLVM's Apple models derive
from Cyclone (every `tbl` one micro-op whatever its table count); it predicted 7.7 cycles/48 bytes for two
Base64 kernels measured at 9.1 and 8.4.

**`Tools/bn …`** — Binary Ninja's MCP server from the shell (see below): `status`, `tools`, `call TOOL
JSON`, and `loop-il FILE PATTERN [--level llil|mlil|lifted|hlil]`, which prints the loops `Tools/loops` finds in the
first match (the same set and matching; Objective-C names included), each loop's instructions as IL, with NEON as
intrinsics. Binary Ninja's function is found exactly: in a linked binary at objdump's address (failing if the name resolves
only elsewhere), else every function the name names (its symbol, exact search rows), one or the tool fails; never a
similar name. Exit 2 also when the server stops answering, even during the lookup (each
request `BN_LIMIT`, 60 s; the analysis `BN_ANALYSIS_LIMIT`, 1,800 s: a large linked binary takes minutes, said before
it starts). Exit 2 when no server
answers. Every request runs in the background, so TERM, HUP, and INT, sent to bn or to its whole process group
(gtimeout, a closing terminal), act at once: they stop everything it started (requests, Tools/loops, a universal file's
slice copy) and close the item it opened (the cleanup runs once, from the signal handler or the exit, whichever comes
first; what it stopped is waited for, at most 3 s); an open in flight is left to finish (it ignores TERM and HUP; curl's time
limit bounds it) and its reply names the item to close. An open that doesn't answer within BN_LIMIT ends the tool
(exit 2, said) and leaves its item open in the app: the handle is only in the reply. Tools/loops' own failure is passed on with its status, as in
mca.

### Dynamic: what the program did

**`Tools/counters [--mode MODE] [--keep F.trace] [--time-limit T] [--timeout S] -- PROGRAM ARGS`** (or `--trace F`,
`--list-modes`) — CPU Counters (xctrace; no sudo). `bottlenecks` (default): share of cycles useful /
discarded / delivery (front end) / processing (back end); `delivery` breaks the front end down.
`simd_fp_unit_instructions` counts SIMD arithmetic, loads, stores: **the run-time proof of vectorization**
(Base64's driver: 18.5 G SIMD ops; its scalar variant: 0). Cycles and counts are exact integers, per cycle 4
significant digits. Per cycle and per unit of work is the useful form. Bottleneck modes' tables hold every interval at
two precisions (1 ms and 10 ms): only the 1 ms rows are counted (before 2026-11-24 their cycles read double). Not every
mode records on every CPU (on the M1 Max, `processing`, `sme_streaming`, `sme_engine_instructions` record nothing: exit 2
saying so), and the `*_sampling` modes' shares print as `-` (read them in Instruments). xctrace stops PROGRAM at
`--time-limit` (then reports) or `--timeout` (default 300 s; then fails).

**`Tools/profile [--top N] [--high-frequency] [--keep F.trace] [--time-limit T] [--timeout S] -- PROGRAM ARGS`** — Time
Profiler, symbolicated from a dSYM made with `dsymutil`, so leaf frames include **inlined** functions (Base64:
`bytes_interleave4` 39% inside `encodeBlocks`). Without a dSYM, xctrace leaves SwiftPM binaries unsymbolicated. A
recording with no samples exits 2 ("no samples"); one the dSYM names nothing in (every sample outside PROGRAM's code,
or a `--dsym` that isn't the recorded program's) is shown, and kept with `--keep`, unsymbolicated, with a note saying
which program and that the dSYM may not match.

**`Tools/sample-top [--seconds N] [--delay N] -- PROGRAM`** (or `--pid`, `--file`) — macOS `sample`, self
samples per thread with kernel waits folded into "(waiting)". No Instruments; attaches to a running process. A
launched PROGRAM is stopped once sampling ends; a `--pid` process is left running.

**`Tools/runtime-count [--break SYM[@MODULE]]... [--who SYM=REG]... [--timeout S] -- PROGRAM ARGS`** — LLDB breakpoints
that count and continue: `swift_task_switch@libswift_Concurrency.dylib` (executor hops), `swift_allocObject`,
`malloc`, `swift_retain`. `--who swift_task_switch=x0` tallies which async function switched (several `--who` on one
symbol are tallied apart, as `who SYM=REG count value`; a value that isn't an address in an image is shown in hex).
Counts from threads hitting breakpoints at the same moment are lower bounds (LLDB can miss a few: 2,397–2,399 of
2,400); what's tallied is attributed to the right thread. Exits 1, counts still printed, when PROGRAM crashes or exits
non-zero, or a breakpoint never resolves (`hits NAME 0 (unresolved)`); `--timeout` (default 300 s) stops LLDB and
PROGRAM. Each hit costs tens of µs and perturbs timing: run two workload sizes to separate per-iteration from fixed
counts. (DTrace can't trace system libraries with SIP on.)

**`Tools/allocations [--top N] [--timeout S] [--keep F] -- PROGRAM ARGS`** — Instruments' Allocations: allocations made,
still live, and bytes by size class (`== categories`, Instruments' "All …" rows apart under `== totals`), then live
allocations by responsible caller. Use when a malloc threshold fails. Needs the attach prompt approved (above); xctrace
stops PROGRAM at `--timeout` (default 120 s). Its callers cover only allocations still live at the end: **`--history`**
finds the ones freed again (a box per item, a temporary array) by running PROGRAM under LLDB with malloc stack logging
in full mode, dumping `malloc_history PID -allEvents` at `exit` (by PID, so another process of the same name doesn't
interfere; its errors are passed on), and grouping every allocation by the innermost frame of PROGRAM's own code
(standard-library specializations skipped). Full mode allocates an autorelease pool page per Swift Concurrency job that
a normal run doesn't; they're left out and counted. About 9 s for a 6 s, 30,000-file extraction.

**`Tools/tasks [--top N] [--keep F.trace] [--time-limit T] [--timeout S] -- PROGRAM ARGS`** (or `--trace F`) —
Instruments' Swift Concurrency template: per task, its runs, the threads it ran on, thread and actor switches (real
hops), continuation waits, and the wait from runnable to running; per-thread running time (threads named with their
id, `NAME (0x…)`); totals. It records moves, not executor checks (`swift_task_switch` fast paths change no state): pair
it with `Tools/runtime-count` for those. (Before 2026-11-24 it merged every pool thread into one, so its thread and
switch counts read 1 and 0: recheck conclusions drawn from them, such as SocketStream's "zero hops".)

The recording tools (`allocations`, `counters`, `profile`, `tasks`) share these rules: xctrace's own `--time-limit`
ends PROGRAM; if xctrace hangs 60 s past it (an attach prompt), it's interrupted and only the processes it started are
stopped; Ctrl-C or TERM to the tool does the same. A recording whose table is empty or missing (a failed recording, a
program with no Swift tasks for `tasks`, a mode that records nothing on this CPU) or, for `counters`, made in another
mode exits 2 with the reason (the recording's `end-reason`, or the metrics it holds), never 0 with nothing printed.
`--time-limit` takes a whole number from 1 with ms/s/m/h, at most 10,000,000 s. `--keep` takes a new path ending in
`.trace` or an earlier recording (replaced); anything else is refused with exit 2 and left alone (`--history`'s and
sample-top's `--keep` take a new file).

**`Tools/bench-table PKG [--metric R] [--filter R] [--percentile p50] BASELINE...`** — baselines side by side
with change, units normalized (counts unscaled from K–P, times in µs from ns–Ms). A benchmark name used in two
benchmark targets is shown as `TARGET: NAME`. Values are the markdown's 3–4 significant digits.

**`Tools/slim-baselines [--check] [--min-size SIZE] PATH...`** — shrinks saved baselines (`results.json`) about 9x
(the repository's 421: 4.4 GB → 477 MB; the largest, 405 MB → 5.7 MB) without changing anything they report: each metric's HDR histogram is rebased to start at its smallest recorded
value and end at its largest, with every bin keeping its bounds. Run it after every `baseline update`.

**`Tools/debuggable PROGRAM`** — prints `PROGRAM-debuggable`, signed with `get-task-allow`.

**`Tools/job start NAME -- COMMAND…` / `run NAME -- COMMAND…` / `wait NAME [--timeout S]` / `status NAME` / `log NAME`** —
a long command that can be waited for reliably. `start` launches the runner detached and returns as soon as COMMAND
runs (it fails if the runner ends first), with the old status cleared and NAME.pid written, so a `wait` (or a signal)
right after it never meets the previous run's result; `run` runs it in the foreground (or with the Bash tool's
background mode, whose own notification is then the wait: a `wait` racing a backgrounded `run` can read the previous
run's status). Both hold an flock on `NAME.lock` from their idle check through writing NAME.pid, so of any number at
once exactly one runs the name and the others exit 2 (one waiting for the lock refuses as soon as NAME.pid names a live
runner, so refusing starts don't queue behind each other's checks); the kernel drops the lock when its holder dies, a lock file
deleted while held is noticed (by inode) and taken again, `status` reads `running` while it's held, and an old
`NAME.lock` directory is removed. A runner `start` launched waits for that lock with no time limit and runs COMMAND
only if NAME.pid names it. The runner holds `NAME.run` for its life, so `wait` blocks on it and wakes the moment it
ends (a 0.2 s job's wait returns in about 0.2 s, not 1), using next to no CPU, with `--timeout` kept to about 0.1 s; a
`wait` killed outright leaves no waiter behind. Start times are compared in the C locale and UTC. The runner starts
COMMAND in a process group of its own, with exactly the caller's descriptors (the job's own three are picked at run
time below the soft limit, so a limit of 64 works and a caller's 197–199 pass through; below 16 the tool refuses,
exit 2), standard input /dev/null when the caller's is closed, passes TERM, INT, and HUP
on to it (one arriving before COMMAND exists is recorded as 128 + N), and records COMMAND's own exit status in
`NAME.status` (from an EXIT trap); the runner's own errors go to `NAME.log` with COMMAND's output. `status` prints
`running`, `exit N`, `orphaned PID` (runner killed outright, COMMAND still running), `died`, or `none` (`died` also
when NAME.status can't be read or holds no exit status (0 to 255, written plainly), which this tool never writes: a note names the file, `wait` exits 125, and a
`start` replaces it; a job whose NAME.pid changes during five looks in a row reads `running`); `died`,
`orphaned`, and `none` only when NAME.pid and NAME.status didn't change during the look (a restart meanwhile reads as
`running`), and a status removed as it's read is read again. `wait` prints
the same line and exits with COMMAND's status, 124 when still running at the timeout (default 540 s, under the Bash
tool's limit; the job keeps running), 125 when died or orphaned (the printed line tells a COMMAND's own 124 or 125
apart), 2 for no such job. Files in `~/Scratch/jobs.noindex` (`EXPERIMENTS_JOBS_DIR`): NAME.pid, .log, .status, .lock,
.run. A closed stdin, stdout, or stderr, or a reader that has gone (`| head -1`: SIGPIPE), changes no exit status and
adds nothing to stderr. See "Parallel agents" for when to wait.

**`Tools/disk-space [--check GB] [PATH]`** — a volume's space three ways: free now (`statfs`, what `df` shows),
available (free plus purgeable space the system frees on demand: Finder's figure), and opportunistic (what background
work may take without purging), and `read-only yes|no`: six tab-separated fields. PATH defaults to the Data volume
(`/System/Volumes/Data`); `/` itself in any spelling (`/.`, `/System/..`, `/Volumes/Macintosh HD`) is measured as the
Data volume, and any other path on the sealed system volume, new top-level ones included (`/Scratch/x`, a typo for
`~/Scratch`), reads as read-only (so `--check` fails). A PATH that doesn't exist yet is measured at its nearest
existing ancestor (a dangling link at its target's), except under a volume in /Volumes that isn't mounted (in any
spelling, `/System/Volumes/Data/Volumes` too), which is refused (exit 2); a note says which. Only APFS has purgeable space: on exFAT, FAT, and HFS+ volumes both "available"
figures are the free space. `--check GB` exits 1 when less than GB is available or the volume is read-only (only a
note when just "free now" is short); run it before extracting or generating anything large, instead of `df`.

**`Tools/untracked [--timeout S] [--keep DIR] -- COMMAND ARGS`** — runs COMMAND as a launchd job (`launchctl submit`,
a unique label, removed after), outside this provenance-tracked process tree: in a tracked process (anything started
from a downloaded terminal) the kernel owns `com.apple.provenance` on what it creates, so a restored value never reads
back. Same directory, environment (applied to COMMAND only, never to the job's own shell), umask, and soft descriptor
limit; launchd's lower scheduling priority stays (`ps -o pri` 20 against 31). stdout and stderr stream back through
files; the command's exit status is the tool's. The job's own files are written with umask 077 whatever the caller's
(COMMAND still gets the caller's), and a job launchd can't start fails the run after 5 s with launchd's exit status.
The job watches the tool's PID: if the tool is killed outright, it stops COMMAND's process group, deletes the job's
directory (a copy of the caller's environment; not `--keep`'s), and removes itself (a job launchd never starts fails the run after 5 s instead); if the job's wrapper is killed
outright, launchd's restart of it stops the first one's command (its PID and start, written by its launcher before it
execs; `ps` must put the start at most 10 s before that and not after, so a reused PID is left alone) and removes the
job. A reused `--keep DIR` runs the command again (the last
run's status is cleared first). `Tools/untracked -- swift test --package-path NativeZipArchive --filter
restoresALinksAttributes` checks the read-back that `SystemAttributes.isProvenanceTracked` skips (the test prints which
branch ran).

**`Tools/socket-ceiling [--pairs N] [--bytes SIZE] [--write SIZE] [--buffer SIZE] [--unix] [--runs N]`** — the
kernel's local-socket throughput with blocking C sockets on plain threads (loopback TCP or a Unix socketpair):
the ceiling to compare networking benchmarks against (SocketStream's transfers reach most of it). TSV: `pairs`,
`bytes` (received in total, exact; SIZE suffixes are powers of 1024), `ms`, `GB_per_s` (10^9 bytes a second). It
raises the soft descriptor limit for its pairs (2 a pair, plus a listener over TCP), counting descriptors already
open; macOS allows a process only 25 descriptors when its soft limit is 26 to 50, so it steps over that range, and
with a hard limit there runs only what fits in 25 (10 TCP pairs, 11 with `--unix`, with only stdio open) and refuses
more with the reason. A failed socket call exits 2.

**`Tools/cpu-probe freq | insn [NAME...] | latency [SIZE...] | bandwidth read|store [--bytes SIZE] [THREADS...]`** — what
one core of this Mac can do, in C and inline assembly: the P-core clock (a dependent scalar `add` chain), instruction
latency and throughput in cycles (one dependent chain; 16 independent ones; NAME selects the row it names exactly,
ignoring case, `insn pmull`, else every row whose name or id contains it, `insn ld4`, `insn tbl`; one that selects
nothing exits 1, an empty one 2), load-to-use latency by working set (random pointer chase over 128-byte lines), and
read/store bandwidth by thread count. SIZE: digits, an optional fraction, an optional K/M/G (no sign, space, hex, or
exponent), from 128 bytes, with what it allocates (latency: the size and a 1/16 order array; bandwidth: every thread's
buffer) at most half of `hw.memsize` (`CPU_PROBE_MEMORY_BYTES` stands in for it, for the checks). The cost model behind
"a 4-register `tbl` is 3 vector slots" or "two cores saturate memory"; run it on a new machine before reasoning about
its micro-op costs. The M1 Max's numbers: `Bytes/Benchmarks/RESULTS.md`, "What the cores can do".

**`Tools/probe machine|insn|mem|bytes|all|compare|steps`** — what a Mac's cores and memory can do, measured the same
way on any Apple silicon Mac (M1–M5) so machines compare row by row: `insn` (latency from one dependent chain,
throughput from 8/16/24 chains, cycles from a dependent-`add` calibration next to each instruction, medians of 3 runs;
instructions the chip lacks skipped by `FEAT_*` sysctl), `mem` (pointer-chase latency per 128-byte line, one-thread
bandwidth, read bandwidth by thread count), `bytes` (BytesProbe: CRC-32/Adler-32 by size, parallel DEFLATE by lane
count, decoder segments at every lane count; needs `Tools/corpus fetch`). `Tools/probe all` writes one TSV per table to
`~/Scratch/probes/CHIP-DATE/` (about 1.5 minutes); `Tools/probe compare A B` puts directories side by side with ratios.
Reference sets in `Tools/probes/results/`; method and pitfalls in `Tools/probes/README.md`. Run on an idle Mac on AC
power (`machine.tsv` records load and power).

**`Tools/toolchain …`** — non-Xcode toolchains: `list`, `install`, `register`, and running commands,
programs (`--runtime`), and tests (`test`) with one. See Toolchains below.

**`Tools/test-data [fetch [SET...]|path [SET]|list]`** — test and benchmark files that aren't checked in, in
`TestData/SET/` at the repository root (ignored by git). Run `Tools/test-data fetch` on a fresh clone (exit 1 if any
set failed); `fetch SET` also fetches the sets SET's generator reads. Tests that need a missing set fail saying which
`fetch` to run. Two kinds of set:
- **Downloaded**, pinned to a revision and checked by SHA-256: `swift-binary-parsing` (its PNG, QOI, ELF, PCAPNG,
  and binary plist samples, read by BinaryParsingComparison after its own `Data/`), `wycheproof` (C2SP's AEAD,
  HMAC, HKDF, ECDSA, and ECDH vectors, for BytesCrypto), `rfc8448` (TLS 1.3's example handshake traces, for the key
  schedule and record tests), `rfc9180` (HPKE's test vectors), `c-references` (the lzfse and libzbitmap sources
  BytesCompression's LZFSE, LZVN, and LZBITMAP coders were compared against; not built now:
  BytesCompression/Benchmarks/RESULTS-lz4-lzfse.md and RESULTS-lzbitmap.md say how to add them back as targets).
  Repository snapshots (`*.unpack.tar.gz`) are unpacked into a staging directory and swapped in; their `.unpacked`
  marker records every file's SHA-256, and a set that no longer matches it (a file deleted or edited, or left over
  from an older pin) is unpacked again.
- **Generated** by a checked-in script, run with an empty staging directory as its argument that then replaces the
  set. `GENERATED`'s third column names the sets a generator reads, its fourth the tools whose resolved paths and
  versions are part of its hash (lz4; xz and zstd, each with Homebrew's library that it and Python's lzma and zstd
  modules load (liblzma, libzstd); python3; openssl; clang; macos, by product and build version; `TESTDATA_HOMEBREW_DIR`
  replaces Homebrew's prefix, for tests). Generators run with a fixed PATH (Homebrew's bin, then `/usr/bin:/bin:/usr/sbin:/sbin`;
  `TESTDATA_GENERATOR_PATH` replaces it), so a fetch from launchd or `env -i` runs the same tools and computes the same
  hashes. A set is made again when any file in the script's directory, its input sets (their pins and markers, or
  stamps), those tools, or `Tools/lib/testdata.sh` change: `swift-help-lz4` (`BinaryParsingComparison/TestDataGenerators`:
  swift-binary-parsing's `ELF/swift-help` through `lz4 -9`; lz4 1.11.1 reproduces the benchmarked file byte for
  byte, and the script warns when another version doesn't), `nativezip-formats` and `nativezip-lzma`
  (`NativeZipArchive/Tests/NativeZipTests/Fixtures/{formats,lzma}`, read through the tests' `testDataFile`). `nativeaea-synthetic`
  (`NativeAEA/Benchmarks/Fixtures`: an Xcode-like Apple Archive stream in a signed `aea` container, about 1 GB;
  the signature differs each time, the archived files don't). `archive-coverage` (`Disk/Fixtures/archive-coverage`,
  about 100 MB, 20 s): one deterministic tree with every case an extraction meets (2,000 small files, large ones, 24
  levels, 255-byte and NFC/NFD names, every kind of symbolic link, hard links, extended attributes and resource forks,
  ACLs, special modes, flags, APFS-compressed files), archived by `aa` (plain and six codecs), `aea` (profiles 0–5,
  test keys beside them), `ditto -c -k --sequesterRsrc`, and `zip -y`, plus case-colliding names (from a small
  case-sensitive disk image it attaches and detaches); with manifests (`source.json`, `aa.json`, `ditto.json`, …) of
  what `aa extract` and `ditto -x -k` made of each at generation time, read by DiskTestSupport's `TreeManifest`, so
  tests compare NativeAEA's and NativeZip's extractions item by item without running Apple's tools. When
  a generated file is what benchmarks measure, the generator checks its SHA-256 against the measured one.

Don't check in archives, images, or other test binaries: add a download line or a generator to the script.
Scripts that write test data source `Tools/lib/testdata.sh` and call `in_testdata PATH` before every write or
delete. It resolves `..` and symbolic links, and refuses anything outside `TestData/`, a symbolic link as the last
component, a dangling link anywhere in the path, and a `TestData` that is itself a link unless `TESTDATA_ALLOW_LINK=1`.
Python generators have the same check (`in_testdata` in each). Temporary work goes inside the output directory too
(`OUTPUT/.work`). Downloads, unpacking, and generation happen in staging beside the sets
(`.SET.download|unpack|generate.XXXXXX`; `.SET.old.XXXXXX` holds a set being replaced), each with an `.owner` file
naming the fetch that made it (PID and start time, read in C and UTC by `process_start`, so fetches in different time
zones or locales recognise each other; written under a temporary name and renamed in): a fetch interrupted with INT,
TERM, HUP, or QUIT (signals during its cleanup are ignored) puts back an old set whose place is empty (a directory with nothing in it, or nothing at all;
a link or file there keeps the old copy, with an error) and removes its staging; one killed outright leaves them, `list` shows them as `(staging)` rows, and the next `fetch`
reclaims them, restoring an orphaned old set first. Two fetches racing on one set both succeed, and the last one's
set wins. A fetch removing staging first renames it `.….trash.PID.START` (so of several sweeping one leftover, one
removes it and says so); `list` reports one being removed, and a trash whose fetch is gone is removed by the next.
Staging a plain `rm -rf` can't remove gets what stops it cleared, never following a link and never touching a file
that may be someone else's: flags (uchg, uappnd), ACLs, and modes of directories and of files whose every link is
inside, only on its own volume (`rm -x`, `find -x`, and every change only to an entry on the staging directory's
device, or, for one an ACL hides from `lstat`, on its file system by `statfs`: a mount point is never changed, whatever
path reaches it); directories hidden by their ACL (`deny readsecurity`) are unhidden, hidden files and links only
unlinked (which works where deleting them is allowed). A staging or trash name that isn't a directory (a file or a link,
hidden or not) is left alone and not listed. On HFS+, where `link(2)` works on a directory without privilege and even a
plain `rm` would follow one out of TestData, a leftover is refused before any `rm` unless every directory in it has one
link and can be checked. Volumes mounted at or inside a leftover (disk images and network shares alike, matched by
device and file id, not by path spelling) are unmounted (`umount -f`), and their images detached (`hdiutil`, never `diskutil`) unless another volume of the
image is mounted elsewhere; neither is claimed unless it worked, and a leftover that is itself a mount point it can't
unmount is refused. What stays, the fetch reports, and goes on.
(`Tools/corpus` is the compression corpus, in `~/Scratch/corpus.noindex` (`EXPERIMENTS_CORPUS`), every Silesia file
pinned by SHA-256; `web/SOURCE` records the macOS its web files came from and must list every web file this Mac would
copy (a missing line counts as damage and brings a fresh copy), and web files found without one are recorded as they
are, not replaced; an interrupted fetch (INT, TERM, HUP, QUIT) removes its temporary directory and web/'s partial
copies, and a killed fetch's `.silesia.*` directory is removed by the next fetch, and `list` shows it as
`(temporary)`.)

## Toolchains

Xcode's toolchain is the default. Others (swift.org snapshots, unmerged-PR builds) are installed in
`~/Library/Developer/Toolchains`, selected with `TOOLCHAINS=<bundle id>` (xcrun, `swift build`, and every
Tool honor it), and never on PATH (the shell profile doesn't add them).

- **Registry:** `Tools/toolchains.json` lists the toolchains the experiments need: how to install each
  (`{"swiftly": SPEC}` for releases and snapshots; `{"url": TARBALL}` for what swiftly can't install, like PR
  builds from `download.swift.org/tmp/pull-request/<PR>/<build>/xcode/swift-PR-<PR>-<build>-osx.tar.gz`, which
  extract into `~/Library/Developer/Toolchains` and **expire**) and, once installed, its directory and
  bundle id. A package needing one names it in `PACKAGE/.swift-toolchain` (SocketStream: `pr-91981`).
- **swiftly is installed without shell integration** (no PATH proxies, no `swiftly use` in effect): use it only to
  install and remove specific open-source toolchains (`swiftly install 6.3`, `swiftly install main-snapshot-2026-11-20`;
  through a registry entry, `{"swiftly": SPEC}` and `Tools/toolchain install NAME`, which never passes `--use`), then
  call them manually: `TOOLCHAINS=<bundle id>` or `Tools/toolchain NAME -- …`. Never `swiftly use` or `swiftly run`,
  which would change what the shell's `swift` is.
- **Clean up toolchains no longer used**, as part of finishing the work that installed them: `Tools/toolchain list`
  shows what each package uses (`used by`, from the `.swift-toolchain` files); remove an unused one with `swiftly
  uninstall SPEC` (swiftly's) or by deleting its directory (a downloaded PR build), and drop its registry entry. Ask the
  user before removing a toolchain this work didn't install.
- **`Tools/toolchain list`** shows each entry (installed or missing, used by which packages), plus
  unregistered installed toolchains and broken links (a `swift-latest` symlink to a deleted snapshot is
  typical). `Tools/doctor` reports the same problems.
- **Installing:** `Tools/toolchain install NAME` (swiftly, or download, check, and extract; PR builds are
  ~3 GB: ask the user first). A tarball is checked against the entry's optional `"sha256"` (`register NAME --url URL
  --sha256 SUM`) and refused before extraction if any path is outside `Library/Developer/Toolchains` or has a `..`
  component. It records the installed directory and bundle id; `register` checks `--path` before writing the registry,
  and a `toolchains.json` that isn't valid JSON of the registry's shape (entries and installs as objects, their fields
  as strings) stops every command (exit 2). `EXPERIMENTS_SYSTEM_TOOLCHAINS` replaces `/Library/Developer/Toolchains`
  (for tests). When you install one by
  hand, remember it: `Tools/toolchain register NAME --url URL --path ~/Library/Developer/Toolchains/X.xctoolchain`.
  If a PR build's URL has expired, probe newer build numbers of the same PR (`curl -sI …/<PR>/<n>/…`),
  then register the new one.
- **Using one:** NAME is a registry name, a package directory (its `.swift-toolchain`), or an installed
  toolchain's name, bundle id, or alias. Exact matches win over substrings, and a link such as `swift-latest` counts
  as the toolchain it points to; a registered toolchain that isn't installed exits 2. `Tools/toolchain NAME test`
  builds release with `-enable-testing` (for `@testable` imports).
  ```sh
  eval "$(Tools/toolchain SocketStream env)"     # TOOLCHAINS, TOOLCHAIN, TOOLCHAIN_RUNTIME
  Tools/toolchain SocketStream -- swift run --package-path SocketStream -c release socket-stream
  Tools/toolchain SocketStream -- swift package --package-path SocketStream --disable-sandbox benchmark
  Tools/toolchain SocketStream test             # tests against the toolchain's runtime
  Tools/toolchain pr-91981 -- Tools/loops --target Bytes BytesBase64 encodeBlocks   # codegen with another compiler
  ```
- **The toolchain's runtime:** code using APIs newer than the OS's Concurrency/stdlib must load the
  toolchain's runtime. `swift test` and the benchmark plugin replace `DYLD_LIBRARY_PATH` for the processes
  they start, so executables embed it (`-Xlinker -dyld_env -Xlinker DYLD_LIBRARY_PATH=…`), computed in
  Package.swift from `TOOLCHAIN_RUNTIME` or `TOOLCHAINS` (see SocketStream/Package.swift: no path is
  hardcoded); tests run through `Tools/toolchain NAME test`, which drives `swiftpm-testing-helper` itself.

## Swift's LLVM vs Homebrew's

There are two different LLVMs on this machine; don't mix up what they tell you.

- **Swift's own LLVM** is linked into `swiftc`: Apple's fork in Xcode (`xcrun clang --version` → "Apple
  clang 21 / clang-2100.x" for Swift 6.4), swiftlang/llvm-project in swift.org and PR toolchains. What it
  did is what you ship. Ask it with `-save-optimization-record*` (Tools/remarks), `-emit-ir`, `-S`, and
  `-Xllvm` options it recognizes (`-sil-print-*`, `-debug-only` doesn't work in release builds). Neither
  Xcode nor swift.org toolchains ship `opt` or `llvm-mca`.
- **Homebrew's `llvm`** (`brew install llvm`; keg-only at `$(brew --prefix llvm)/bin`, not on PATH; found by
  `llvm_bin` in `Tools/lib/common.sh`) is upstream and newer: `llvm-mca`, `opt`, `llc`, `llvm-mc`,
  `llvm-exegesis`, `llvm-remarkutil`. Use it for what Swift lacks: `llvm-mca` on Swift's assembly is fine
  (it's just ARM64). Running brew `opt` on Swift IR (`-emit-ir -Xfrontend -disable-llvm-optzns`, then `opt
  -passes='default<O3>' -pass-remarks-output=r.yaml`) is an **approximation**: a different LLVM, without
  Swift's pass pipeline and LLVM-level Swift passes. Good for experiments ("would this IR vectorize if…");
  confirm with Swift's remarks.
- Other Swift toolchains embed their own swiftlang/llvm-project LLVM (`Tools/toolchain list` shows each
  one's version): compare codegen across them with `Tools/toolchain NAME -- Tools/loops …`.

## Compiler flags worth knowing

| Flag | Use |
|---|---|
| `-emit-sil`, `-emit-ir`, `-S` | optimized SIL / IR / assembly (via `Tools/swiftc-target` for packages) |
| `-Xfrontend -disable-llvm-optzns` | IR before LLVM optimization (for `opt` experiments) |
| `-save-optimization-record=yaml -save-optimization-record-path P -save-optimization-record-passes R` | LLVM remarks from Swift's LLVM |
| `-Xllvm -sil-print-function=MANGLED -Xllvm -sil-print-all` | SIL after every pass, one function |
| `-Xllvm -sil-disable-pass=NAME` | bisect which SIL pass causes a change |
| `-Xfrontend -disable-type-layout`, `-Xfrontend -disable-aggressive-reg2mem` | IRGen experiments (type-layout lowering vs value witnesses; `swiftc -frontend -help-hidden` lists more) |
| `-module-name X` | needed when compiling a file alone repeatedly: otherwise the module is named after the output file and mangled names change |
## macOS tools: what's useful for this

| Tool | Verdict |
|---|---|
| `objdump` (`xcrun objdump`, LLVM's) | The workhorse: `-d --no-show-raw-insn --symbolize-operands` (branch targets as `<L0>` labels, so loops are visible), `--disassemble-symbols=MANGLED`, `-r` for relocations (call targets in `.o`). Lines start with spaces then a tab. |
| `otool -tV` | Resolves stub calls in linked binaries ("symbol stub for: _swift_retain"); `otool -h` for the file type (1 = object). |
| `nm` | `--defined-only` (double dash with Xcode's nm), `T`/`t` text symbols. Demangle with `xcrun swift-demangle --simplified`. |
| `lldb --batch` | Breakpoint counting (Tools/runtime-count), `disassemble -n`, register reads. Breakpoints perturb timing. |
| `sample` | Quick per-thread stacks of a live process (Tools/sample-top). |
| `xctrace` / Instruments | See below. Useful: CPU Counters, Time Profiler, Allocations, Swift Tasks/Actors/Executors, System Call Trace. Processor Trace: unsupported on M3 Ultra ("does not have a CPU that supports Processor Trace"). |
| `dsymutil` | Makes the dSYM xctrace needs to symbolicate SwiftPM binaries. |
| DTrace, `fs_usage`, `powermetrics` | Need sudo; DTrace can't see system libraries with SIP on. Avoid. |

### xctrace

- `xctrace list templates`; `xctrace record --template T --show-recording-options` prints a template's
  options as JSON; change them with jq and pass `--recording-options FILE`.
- CPU Counters modes are defined in `$(xcode-select -p)/../SharedFrameworks/RecountDT.framework/Versions/A/
  Resources/Analysis/{bottleneck,characteristics,metrics}.json`; select one with
  `.["CPU Counters"].selectedCountingMode = {analysisMode, countingMode}`. Bottleneck modes put weights in
  table `MetricAggregationForThread`; count modes put counts in `MetricTableForThread`.
- Export: `xctrace export --input T --toc` lists tables; `--xpath '/trace-toc/run[@number="1"]/data/
  table[@schema="NAME"]'` exports one as XML. Repeated values are written once with `id` and later as
  `ref`: convert with `yq -p xml -o json` and resolve `"+@ref"` against `"+@id"` in jq (the `resolve`
  snippet in `Tools/counters`). Allocations data is under `tracks/track[@name="Allocations"]/details/
  detail[@name="Statistics"|"Allocations List"]` instead, as XML attributes.

## Binary Ninja MCP

Binary Ninja 6 Personal has an MCP server inside the GUI app (HTTP, `http://127.0.0.1:24642/mcp`; start it
in Settings → MCP). The headless stdio server needs Commercial/Ultimate. The user has added it to Claude Code as an
MCP server (2026-11-24): when Binary Ninja is open with its server started at session start, its tools load directly
(`claude mcp list` shows it; agents can call them like any MCP tool), so use them for control-flow graphs, IL, and
cross-references of unfamiliar functions alongside `Tools/loops`/`calls`. If it isn't running when a session starts,
its MCP tools fail to load (ECONNREFUSED); `Tools/bn` talks to it with curl once it is (`Tools/bn status` exits 2 when
no server answers).

75 tools; the useful ones here: `bn_open_item_open`/`close`, `bn_analysis_update_and_wait`,
`bn_function_search`, `bn_function_disassembly`, `bn_function_basic_blocks` (marks back edges),
`bn_function_il` (lifted/llil/mlil/hlil), `bn_memory_read`, cross-references.

Assessment: **complementary, not a replacement for the scripts.** It adds CFGs with back-edge flags,
demangled names everywhere, cross-references and interactive navigation, and its LLIL shows NEON as
intrinsics (`vqtbl3q_s8`, `vzip1q_s8`), which reads well. But some NEON lifts poorly (`usra` unimplemented,
`st2` expanded to scalar stores, lane operations as one statement per lane), HLIL is noisy for vector code,
constant pools in `.o` files read as empty (open linked binaries), it needs the app running, and it can't
assert. Use `Tools/loops` for checks and iteration; open Binary Ninja to understand an unfamiliar function's
control flow. Close what you open: `Tools/bn loop-il` reads all of the IL (pages of 1,000), opens the file as an item of its
own (Binary Ninja opens a file
again even when it's already open) and closes that item at the end, discarding changes and restoring the view that was active. Binary Ninja makes no function at offset 0 of an
object and doesn't resolve jump tables in objects, so `loop-il` can lack a function or a case's IL that `Tools/loops`
lists.

## Homebrew tools and portable scripts

macOS ships BSD userland and old versions; Homebrew adds newer or GNU ones. Detect, don't assume:

| Need | macOS has | Homebrew | Detect |
|---|---|---|---|
| awk | `/usr/bin/awk` and brew's `awk` formula are one-true-awk: no `strtonum`, `gensub`, `\s`, `--version` behaves differently | `gawk` | `command -v gawk` |
| sed | BSD: `sed -i ''`, no `\b`, `\+` | `gnu-sed` → `gsed` | `command -v gsed` |
| date/timeout/numfmt | `date` without `%N`, no `timeout` | `coreutils` → `gdate`, `gtimeout`, `gnumfmt` (g-prefixed) | `command -v gtimeout` |
| JSON | — | `jq` | |
| XML/YAML/TOML/plist→JSON | `plutil`, `xmllint` | `yq` (mikefarah v4: `yq -p xml -o json`, `-p toml`) | `yq --version` mentions mikefarah |
| LLVM tools | not in Xcode | `llvm` (keg-only) | `$(brew --prefix llvm)/bin/llvm-mca` |
| benchmarking commands | — | `hyperfine` | |
| search | `grep` | `ripgrep` → `rg` | `command -v rg` (Claude Code's own `rg` may be a shell function, not a binary) |

The repository's `Brewfile` lists what the Tools and the test-data generators use (llvm, jq, yq, hyperfine, coreutils,
lz4, xz, python, gh, shellcheck). `Tools/doctor` reports `brew bundle check` against it and installs nothing; `brew
bundle --file Brewfile` installs, and that's the user's call. Lint Tools scripts with `shellcheck` (`Tools/.shellcheckrc`
turns off the two false positives every tool would show: computed `source` paths and jq/Perl programs in single quotes).

Prefer Perl (always present) over awk/sed for anything non-trivial; it's what the Tools use. If a script
needs gawk, use `need_gawk` from `Tools/lib/common.sh` and call `$GAWK`.

Script gotchas met on this machine:
- The Bash tool runs zsh: `echo ======` is an expansion error (quote it); globs that don't match are errors;
  unquoted `$flags` isn't word-split (`${=flags}`, or an array).
  Write scripts with a `#!/bin/bash` (3.2!) or `#!/bin/zsh` shebang and stick to it.
- Bash parses `$var–` (a non-ASCII character after a name) as part of the name: write `${var}`.
- Perl: `\Q…\E` around an interpolated `$ENV{…}` works, around a variable holding regex text from elsewhere
  use `quotemeta`.
- `cat -A` doesn't exist: `cat -vet`. `plutil` key paths split on `.`: escape them
  (`'com\.apple\.security\.get-task-allow'`); `plutil -replace` won't create a missing key: `-insert`.
- Functions called in `$(…)` don't inherit `set -e` in bash: check each step.
- `swift package describe --type json | jq` for target paths; `swift build --show-bin-path` for products.

## Tests

- **Two sets.** `swift test` (debug) runs the fast set; `BULK_TESTS=1 swift test -c release -Xswiftc -enable-testing`
  adds the bulk sweeps (`--filter BulkTests` for only those). Default runs (2026-11-23, M1 Max, idle, `--skip-build`,
  wall): Bytes 81 s (its 302 compression tests 64 s), NativeAEA 33 s, Disk 18 s, HTTPBytes 16 s, NativeZipArchive 11 s,
  MQTT 4 s. Alone, the slowest compression suites take 4–9 s each in debug (ParallelInflate, ParallelInflateSegment,
  OneShotReuse, ParallelDeflate, the LZ parity suites).
- **Small groups first, the whole suite last.** While changing an area, build once (`swift build --build-tests`, which
  also shows warnings) and run only its suites, `swift test --skip-build --filter 'SuiteName/'` (several `--filter`s
  work; the bare `Suite/` form, not a regex with `\.`), and a client package's suites that use it; run the full set
  once at the end. Time one suite alone with the same filter (parallel runs report every test's time from the run's
  start). In a zsh loop over names, split the list with `${=names}`.
- **Where a new expensive test goes:** large inputs, corpora, every capacity/size/vector, thousands of mutations go in a
  `@Suite(.bulk) struct XxxBulkTests` (the trait is Bytes' `BytesTesting` product, which every package uses) sharing
  a static helper with the fast test.
- **Shared helpers are Bytes' support products**, not copies: `BytesTestSupport` (no Swift Testing, so benchmarks and
  sources can use it: `SplitMix64(seed:)`, `SampleBytes`, `Lazy`, `TestData.file(set:name:)`, `Corpus.root`,
  `TemporaryDirectory`, `ExternalTool.run`, `hex`), `BytesTesting` (`.bulk`, `runsBulkTests`), and the BytesCompression
  package's `BytesReferenceCodecs` (zlib's and Compression's buffer APIs as references: `Zlib`, `AppleCompression`); for extracted
  trees, Disk's `DiskTestSupport` (`readTree` with `readdir`, so `._` files show; `TreeParts` to choose what's read;
  extended attributes, ACL text, `decmpfs` helpers; `SystemAttributes.ignoredByDefault`, `com.apple.provenance`, left
  out of comparisons unless asked for). The fast form keeps every edge case: boundary sizes, block remainders, one vector of each Wycheproof
  (result, flags) class. Fast plus bulk must check everything.
- **Every suite that touches Disk carries `.diskLifetimes`** (defined in each package's test support from Bytes'
  `LifetimeChecks` and DiskTestSupport's `DiskLifetimes`): close what a test opens, at the end of its use.
- **No `.serialized`, no `@MainActor` or other global actor in tests**: per-test temporary directories, port 0,
  immutable `static let` fixtures. Never set process-wide state (umask, working directory, environment), not even to
  read it: NativeAEA's `umask(0); umask(old)` raced between parallel extractions (now `getumask()`, macOS 27).
- **In debug builds, test helpers can cost more than the code tested**: decode into uninitialized room
  (`UnsafeMutableRawBufferPointer.allocate`), not `[UInt8](repeating: 0, count: huge)` (a DEFLATE helper zero-filled
  about 1 GB per call, half a test's time); build samples, archives, keys, and decoded vector files once in `static
  let`s. Debug codec and crypto code runs 30–250x slower than release: that's why bulk runs in release.

## Benchmarks (ordo-one/package-benchmark)

- Run: `swift package --disable-sandbox benchmark [--filter REGEX]`; save: `… baseline update NAME`;
  compare: `… baseline compare A B` or `Tools/bench-table PKG A B`. Thresholds: `… thresholds update`.
- **Slim every baseline before committing it: `Tools/slim-baselines PKG`.** package-benchmark saves each metric as an
  HDR histogram of about 21,500 slots, almost all zero, so a full suite's baseline was 60–400 MB (GitHub refuses
  files over 100 MB). Slimmed, `baseline read`, `compare`, and `bench-table` print the same numbers (checked: every
  percentile, mean, and standard deviation in `--format histogram`). `Tools/slim-baselines --check .` lists any
  left unslimmed.
- Bytes has three builds, chosen by package traits, each benchmarked with `Bytes/bench BUILD [benchmark
  args]`, which gives each its own build directory: `optimized` (default, the C modules' NEON and CRC
  instructions), `portable` (`--traits Portable`: the C modules' fallbacks for other CPUs, on Apple
  silicon), `portable-no-c` (`--disable-default-traits`: Swift only). Clients inlining Bytes' code compile
  its C headers themselves, so a Swift target needs `-Xcc -DBYTES_PORTABLE` too for a portable build.
  BytesCompression mirrors the traits (passing each on to Bytes) and has the same script, `BytesCompression/bench`,
  with its own `Benchmarks/portable-subset.txt`.
- `baseline read --filter` is ignored (bench-table filters itself). JMH export requires the built-in
  throughput metric. Markdown units vary (K/M, μs/ms): bench-table normalizes.
- **A benchmark costs a few seconds at most, and one run is enough.** No 30-minute suites, no repeated runs unless
  asked for, and no waiting for a quiet machine to run them (2026-11-19):
  - package-benchmark starts the benchmark executable once to list the benchmarks and again for **each** benchmark,
    and every start runs the whole `benchmarks` closure (`--filter` and `list` too). That closure only registers:
    fixtures are made lazily in a benchmark's `setup:` (which runs only in that benchmark's process, unmeasured), and
    so are result checks (run the operation once there and check it: that's the warmup too). Base64's eager
    fixtures cost 3 s per start: 340 s a suite, 53 s lazy; CompressionBenchmarks 20 s per start (RSA key
    generation, every codec's checks), 830 starts: 5.6 hours, 6.6 minutes lazy. No data-derived counts in names
    (they need the data in every process). Check registration stays in milliseconds: `time
    .build/release/TARGET --filter NOTHING`. The `Lazy` box and `register` helper in
    `BytesCompression/Benchmarks/CompressionBenchmarks/Fixtures.swift` are the pattern; slow or random fixtures (RSA keys,
    compressed corpora) are cached in the corpus cache.
  - Code in the benchmark closure before `startMeasurement()` runs for every sample and counts toward
    `maxDuration`: a 32 MB random buffer made per sample left NativeZip's CRC benchmarks with 2 samples.
  - Size iterations by the work: about 100 iterations or 0.5–1 s for work up to a millisecond, 20 for 5–50 ms, 1–3
    for whole archives and socket transfers. Instruction p50s match a 1,000-iteration run (within 0.3% for
    single-threaded work). Don't change `scalingFactor` on an existing benchmark: its printed numbers change.
  - Whole-archive benchmarks need no warmup iteration: read the input once in `setup:` to fill the page cache.
    Deleting an extracted tree costs about as much as extracting it (APFS: about 70 µs an entry; parallel `rm`
    saves 10–15%): for a large tree, extract each sample into its own directory and remove them once in
    `teardown`, with no `chmod -R` unless removal fails. (For 2,000 small files, deleting after each sample,
    unmeasured, was faster than deferring.)
  - What one run can't tell: file-system benchmarks vary 20–40% between samples (their instruction counts include
    the kernel's), all-core and transfer times ±20% or more on a loaded machine, and instruction counts under about
    100 K per iteration ±10% between processes. Judge by the larger single-threaded counts.
  - Every plugin invocation costs about 25 s of build before anything runs (it relinks its tool each time): batch
    filters into one invocation (several `--filter` flags work). It builds the source on disk when it starts: don't
    edit a package while a run of it is queued.
- **No lazy globals inside a measured loop.** A global or `static let` read in the loop checks its `swift_once`
  token every iteration, and for tens of milliseconds after first use libdispatch hasn't marked it done (it stores a
  generation until the quiescent counter moves), so each check calls `swift_once` → `dispatch_once_f` (~36
  instructions). Bytes' "Runs: … 3-byte" rows were bimodal for this (78 K and 104 K instructions; the p50 floated
  with load, and looked like a regression). Capture fixtures as locals or parameters. A row whose p0 and p50 differ
  by a constant per element is the sign.
- **Only the work goes inside `for _ in benchmark.scaledIterations`**: no clocks, no `benchmark.measurement`
  calls, no fixture lookups (dictionaries, removing and reinserting buffers), no result checks. Prepare
  fixtures before registering (Base64's `Fixture`: inputs and raw output buffers made once), check results
  once before registering, and capture what the loop needs. For bytes or packets per second, use the
  framework's `.throughput` (iterations per second, measured outside the loop) times the work per
  iteration, stated in the benchmark's name or a comment; don't time inside the loop with a custom metric.
  The one exception is SocketStream's socket transfers, which report the transfer's own timing (first
  listener to last end of stream, so starting executor threads isn't counted).
- A custom metric named `.throughput` collides with the built-in: name it otherwise.
- The malloc interposer costs ~10% on large transfers: keep allocation and timing benchmarks separate.
- Closure type ambiguity in `Benchmark(...) { benchmark in }`: annotate `(benchmark: Benchmark) in`.
- `--filter` must match the whole benchmark name (`'.*Bytes.*'`, not `'Bytes'`); a filter that matches
  nothing still prints "Updated baseline" and saves nothing.
- The benchmark plugin rebuilds swift-syntax (2.5–3 minutes) after any change; run `benchmark list` first so
  a timed or locked run doesn't include the build.
- **Compare times only within one interleaved run.** Even with nothing else benchmarking, this machine's
  single-core times drift 5–10% between runs minutes apart, and up to 10% between days (unchanged
  controls like Foundation's encoder move too); transfers vary ±20%. To verify a timing change, extract
  the old code (`git archive <commit> Pkg Bytes … | tar -x -C "$SCRATCH/old"`), build both, and alternate
  old and new runs (`baseline update ab-old-1`, `ab-new-1`, `ab-old-2`, …), then compare round by round.
  Instruction counts don't drift.
- Benchmark sizes that are all multiples of a kernel's block size hide its remainder path: include odd
  sizes (Base64's 16-byte-remainder sizes hid a 42% short-input improvement).

### Parallel agents

Several agents can update packages at once (builds and static analysis run in parallel fine), but timings
can't be trusted then, even serialized: other agents' builds load the machine (unchanged code measured
5–15% slower). So:

- Judge changes by instruction counts, allocation counts, and codegen (`Tools/loops`, `Tools/calls`); re-run
  timed benchmarks one package at a time afterwards on an idle machine.
- Don't queue benchmark runs behind a shared lock or wait for a quiet machine (four agents sharing one lock spent
  most of an hour waiting, 2026-11-19): run them, compare instruction counts, and label wall times as taken under
  load. A lock only for a final timing the user asked for.
- Give each agent its own packages to edit; a shared dependency (Bytes) stays read-only while others
  compile against it, and new API for it is proposed (prototyped in the consumer), not added mid-run.
- Give each agent its own scratch subdirectory; agents overwrote each other's helper scripts in a shared one.
- Don't wait for another job with `until ! pgrep -f 'PATTERN'; do sleep 5; done`: the waiting shell's own
  command line contains PATTERN, so `pgrep -f` always finds it and the loop never ends (ten such loops
  outlived their agents). Wait on the job's PID (`while kill -0 $pid …`), on its output file, or let the
  harness notify you when a background job exits.
- Nor with `grep -c PATTERN LOG` in the loop's test when the log can hold NUL bytes (an xcodebuild log does):
  grep prints "Binary file LOG matches" instead of a count, the comparison never succeeds, and the loop never
  ends. `grep -a -c`, or wait on the PID.
- Nor on a benchmark log showing results: `baseline update` prints "Updated baseline 'NAME'" and no results table, so
  two `until grep -q Instructions LOG` loops ran ~15 hours after their run finished (2026-11-24). When an agent
  finishes, check `ps -eo pid,ppid,etime,command` for shells it left (their parent is the session's `claude`) and stop
  them.
- Nor with a hand-written `while kill -0 PID; do sleep 15; done`: it has no deadline (a hung job hangs the waiter), a
  reused PID keeps it waiting on an unrelated process, it learns nothing about how the job ended, and it polls a job
  the harness already tracks (an agent's foreground loop also blocks it from anything else, 2026-11-24).
- **How to wait, in order of preference.** (1) Don't: start the job with the Bash tool's background mode and carry on;
  the harness notifies when it exits, with its status. (2) When a step can't continue without the result, run it as
  `Tools/job start NAME -- …` (not `Tools/job run … &`: a `wait` right after that can still read the previous run's
  status) and block with `Tools/job wait NAME --timeout S`, which always ends, and the moment the job does: the job's exit
  status, 124 at the deadline (the job keeps running), or 125 if it died or was orphaned, with the outcome printed
  (`exit N`, `running`, `died`, `orphaned PID`); `Tools/job status NAME` looks without waiting. (3) For other agents' work, wait for their task notification, never poll; to see whether one is stuck, look
  at its processes (`ps`, their CPU) rather than its log.
