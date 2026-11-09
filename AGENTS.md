# AGENTS.md

How to do performance and compiler investigations in this repository: the tools in `Tools/`, the workflow
they support, what was learned doing it, and the macOS/Homebrew environment they run in. Project READMEs are
for people; this file and each project's `RESULTS.md` are the working record.

## Repository

Independent experiments, each its own SwiftPM package (no root package). The performance ones:

| Project | What | Record |
|---|---|---|
| `Bytes` | Span-based binary reading/writing (`BytesReader`, `BytesWriter`, `ByteLanes` SIMD scanning and NEON shuffles via the `CBytesNEON` C target), CRC, DEFLATE | `Benchmarks/RESULTS.md` |
| `MQTT` | MQTT 5 packets on Bytes: `MQTTFrame` (zero-copy header + body), per-type `init(parsing:)`/`write(to:)` | `Benchmarks/RESULTS.md` |
| `MQTTSocketStream` | MQTT over sockets with a PR toolchain's I/O interfaces; concurrency hops | `RESULTS.md` |
| `Base64` | Vectorized Base64 encoder on Bytes (`tbl` kernel, auto-vectorized `ld3`/`st4` kernel) | `Benchmarks/RESULTS.md` |
| `NativeZipArchive` | ZIP/DEFLATE | `Benchmarks/RESULTS.md` |
| `BinaryParsingComparison` | Bytes vs swift-binary-parsing | `RESULTS.md` |
| `NativeISO8601`, `*Benchmark` | Smaller benchmarks | READMEs |

Benchmarks use [ordo-one/package-benchmark](https://github.com/ordo-one/package-benchmark); saved baselines are in
each package's `.benchmarkBaselines/`, allocation thresholds in `Thresholds/`. Compiler bug reports and
reproducers live outside the repo, in `~/Downloads/swift-bugs/` (numbered `NN-swift-…md` with a
`repro-NN-…/` directory, a zip in `attachments/`, and an index row in its READMEs).

## Ground rules

- Measure, don't assume: every optimization claim gets a benchmark baseline before and after, and the
  numbers go in the project's `RESULTS.md` (`Tools/bench-table` makes the table).
- Check the machine code, not just the timing: "vectorized" means `Tools/loops` says `vector128` for the hot
  loop (and `Tools/counters --mode simd_fp_unit_instructions` shows SIMD work at run time); "no
  allocations" means a zero-malloc threshold passes (and `Tools/allocations` explains any that don't).
- Don't touch project READMEs beyond what the user asks: they're for humans. Don't commit unless asked.
- Swift style here: public API `@inlinable` (but measure: it can change codegen), `sending` over
  `@Sendable` where it fits, every `unsafe` expression with a comment saying why it's safe.
- Use Edit/Write for file changes rather than `sed -i`/scripts; jq for JSON, yq for XML/YAML/TOML (no inline
  Python); never `rm -rf "$VAR"` without checking the variable is set and points where you expect.
- Temporary files go in the session scratchpad (or `mktemp -d`), never the workspace root. SwiftPM runs
  `swiftc` from the workspace root, so relative output paths passed with `-Xswiftc` land in `Experiments/`:
  always pass absolute paths.
- Analysis tooling goes in `Tools/`, generalized, not in a project's `Scripts/`: if a project needs a check
  or a harness that a Tool almost does, extend the Tool (as `--target` and `toolchain` were). Projects keep
  only their own experiment drivers (e.g. `BackgroundSessionExperiment/run.sh`).
- Never hardcode a toolchain's path, bundle id, or an Xcode path in a package, script, or Tool: builds get
  renamed and deleted. A package that needs a non-Xcode toolchain names a `Tools/toolchains.json` entry in
  its `.swift-toolchain` file; run it through `Tools/toolchain` (see Toolchains below). Use `xcode-select -p`
  and `xcrun` for Xcode.

### Programs you launch get `get-task-allow`; prompts need the user

Anything that attaches to a process (Instruments' Allocations/Leaks templates, lldb, `sample`) needs the
target signed with the `com.apple.security.get-task-allow` entitlement. SwiftPM release builds don't have
it; the symptom is xctrace's "Failed to attach to target process". So:

- The Tools that launch programs (`allocations`, `counters`, `profile`, `sample-top`, `runtime-count`)
  always launch `PROGRAM-debuggable`, a copy next to `PROGRAM` signed with the entitlement (kept until
  `PROGRAM` is rebuilt). Do the same for anything you launch by hand: `"$(Tools/debuggable PROGRAM)" ARGS`.
- Separately, attaching needs the `system.privilege.taskport` right. With Developer Mode off
  (`DevToolsSecurity -status`), macOS shows an authentication prompt the first time, and the approval lasts
  10 hours for the login session. The user may not see the prompt: the tool then hangs (xctrace waits) or
  fails to attach. Use timeouts (`Tools/allocations --timeout`, `gtimeout 120 …`), and when something
  hangs or fails to attach, **tell the user to look for the prompt** rather than retrying silently.
  `sudo DevToolsSecurity -enable` removes the prompt for good; that's the user's call, never run it yourself.
- Other things that need the user: `sudo` (powermetrics, dtrace, `fs_usage`); Binary Ninja's MCP server
  (it runs inside the app; someone has to open it and start the server); `gh` authentication.

## Start here

```sh
Tools/doctor        # CPU, SIP, Xcode/Swift and its LLVM, other toolchains, Homebrew tools, Binary Ninja
```

All tools share conventions (`Tools/lib/common.sh`): `--help` prints usage; results on stdout,
tab-separated where tabular (pipe to `column -t -s $'\t'`); notes on stderr; exit 0 success, 1 a check
failed, 2 bad usage or missing dependency. Xcode tools are found with `xcrun`, so `TOOLCHAINS=<bundle id>`
switches the toolchain for every tool. They're bash and Perl only (plus jq/yq where noted), no gawk/GNU sed
needed.

## The workflow

1. **Benchmark** the package; save a baseline: `swift package --disable-sandbox benchmark baseline update
   NAME --no-progress` (add `--filter` for a subset).
2. **Find the hot loop's machine code:** `Tools/loops --target PKG TARGET PATTERN` (builds release and reads
   the target's objects, merged into one with `ld -r`). Any object or binary works too: `Tools/loops FILE
   PATTERN`.
3. **If it isn't vectorized, ask the compiler why:** `Tools/remarks --target PKG TARGET --function PATTERN`.
4. **If something is called that shouldn't be** (retain/release, `outlined destroy`, `swift_task_switch`,
   unspecialized generics): `Tools/calls`, then `Tools/sil-trace` to find the pass that left it.
5. **Estimate** the loop's throughput bound with `Tools/mca`; **measure** what the CPU did with
   `Tools/counters`; find time per function with `Tools/profile` or `Tools/sample-top`.
6. **Count runtime events** (hops, allocations) with `Tools/runtime-count`; explain allocations with
   `Tools/allocations`.
7. Re-benchmark, save a new baseline, `Tools/bench-table PKG old new`, and record it in `RESULTS.md`.

## Tools

### Static: what the compiler produced

`loops`, `calls`, and `mca` read compiled code from `FILE` (an object or binary) or from `--target
PACKAGE_DIR TARGET` (built release, objects merged into `.build/agent-tools/TARGET.o`; honors `TOOLCHAINS`).

**`Tools/loops FILE|--target PKG TARGET PATTERN [--tsv] [--body] [--require OPS] [--forbid OPS]`** — each loop in matching
functions (a branch back to an earlier `<Ln>` label in `objdump --symbolize-operands` output), its size,
depth, mix and a verdict: `vector128`, `vector64` (often a vectorizer epilogue), `scalar`, `+lane-moves`
(single lanes moved with `mov.b v3[2], w12`/`ins`/`umov`: a shuffle built a lane at a time), `+calls`.
`--require`/`--forbid` make it an assertion (exit 1):

```sh
Tools/loops --target Base64 Base64 encodeBlocks --require tbl,zip --forbid mov.b,ins
Tools/loops --target Base64 Base64 'encode\(_:into:alphabet:\)' --require ld3.16b,st4.16b
```
PATTERN is a regex on simplified demangled names, which don't include parameter types: anchor it (`…:\)`)
or overloads and similarly named functions match too and must each pass.

**`Tools/remarks FILE.swift [-- swiftc args]` / `Tools/remarks --target PKG TARGET`** — optimization remarks
from Swift's own LLVM: loops vectorized (with width) or not and why ("Cannot vectorize early exit loop" =
usually a bounds-check trap; "loop control flow is not understood" = branches in the body). `--passes` picks
others: `sil-inliner`, `sil-generic-specializer`, `inline`, `slp-vectorizer`, `licm`.

**`Tools/swiftc-target [--debug] [--refresh] [--print] PKG TARGET -- ARGS`** — a SwiftPM target's exact
`swiftc` command (captured from `swift build -v`, cached in `.build/agent-tools/`) with outputs stripped and
yours added: `-emit-sil -o /abs/x.sil`, `-emit-ir -o /abs/x.ll`, `-S -o /abs/x.s`. The way to get SIL, IR or
remarks for a package target with its real flags and dependencies. (`-Xswiftc -save-optimization-record` in
a normal SwiftPM build produces empty records or multi-threaded-WMO errors.)

**`Tools/calls FILE|--target PKG TARGET PATTERN [--callee REGEX] [--sum]`** — static call sites per caller
and callee (demangled): from relocations in objects (`objdump -dr`), from `otool -tV` in linked binaries
(which names stubs; plain objdump mislabels stub calls).

**`Tools/sil-trace FILE.swift FUNCTION MATCH` / `--target PKG TARGET FUNCTION MATCH`** — prints the SIL
instructions matching MATCH after every pass that changed them (`-Xllvm -sil-print-function=…
-sil-print-all`, which release compilers accept). Finds the pass that introduces or fails to remove a
`release_value`, `destroy_addr`, `alloc_box`, `apply`.

**`Tools/mca FILE PATTERN [--loop N] [--cpu apple-m3] [--full]`** — llvm-mca on the loop: block reciprocal
throughput, IPC, busiest units. Homebrew LLVM. Treat it as a lower bound only: LLVM's Apple models derive
from Cyclone (every `tbl` one micro-op whatever its table count); it predicted 7.7 cycles/48 bytes for two
Base64 kernels measured at 9.1 and 8.4.

**`Tools/bn …`** — Binary Ninja's MCP server from the shell (see below): `status`, `tools`, `call TOOL
JSON`, and `loop-il FILE PATTERN [--level llil|mlil|lifted]`, which prints just the loop blocks of a function
as IL, with NEON as intrinsics.

### Dynamic: what the program did

**`Tools/counters [--mode MODE] [--keep F] [--time-limit T] -- PROGRAM ARGS`** (or `--trace F`,
`--list-modes`) — CPU Counters (xctrace; no sudo). `bottlenecks` (default): share of cycles useful /
discarded / delivery (front end) / processing (back end); `processing`, `delivery` break those down.
`simd_fp_unit_instructions` counts SIMD arithmetic, loads, stores: **the run-time proof of vectorization**
(Base64's driver: 18.5 G SIMD ops; its scalar variant: 0). Per cycle and per unit of work is the useful form.

**`Tools/profile [--top N] [--high-frequency] [--keep F] -- PROGRAM ARGS`** — Time Profiler, symbolicated
from a dSYM made with `dsymutil`, so leaf frames include **inlined** functions (Base64: `bytes_interleave4`
39% inside `encodeBlocks`). Without a dSYM, xctrace leaves SwiftPM binaries unsymbolicated.

**`Tools/sample-top [--seconds N] [--delay N] -- PROGRAM`** (or `--pid`, `--file`) — macOS `sample`, self
samples per thread with kernel waits folded into "(waiting)". No Instruments; attaches to a running process.

**`Tools/runtime-count [--break SYM[@MODULE]]... [--who SYM=REG] -- PROGRAM ARGS`** — LLDB breakpoints that
count and continue: `swift_task_switch@libswift_Concurrency.dylib` (executor hops), `swift_allocObject`,
`malloc`, `swift_retain`. `--who swift_task_switch=x0` tallies which async function switched. Each hit costs
tens of µs and perturbs timing: run two workload sizes to separate per-iteration from fixed counts. (DTrace
can't trace system libraries with SIP on.)

**`Tools/allocations [--top N] [--timeout S] [--keep F] -- PROGRAM ARGS`** — Instruments' Allocations: counts
by size class, then by responsible caller. Use when a malloc threshold fails. Needs the attach prompt
approved (above).

**`Tools/tasks [--top N] [--keep F] [--time-limit T] -- PROGRAM ARGS`** (or `--trace F`) — Instruments' Swift
Concurrency template: per task, its runs, the threads it ran on, thread and actor switches (real hops),
continuation waits, and the wait from runnable to running; per-thread running time; totals. It records
moves, not executor checks (`swift_task_switch` fast paths change no state): pair it with
`Tools/runtime-count` for those.

**`Tools/bench-table PKG [--metric R] [--filter R] [--percentile p50] BASELINE...`** — baselines side by side
with change, units normalized (counts unscaled, times in µs).

**`Tools/debuggable PROGRAM`** — prints `PROGRAM-debuggable`, signed with `get-task-allow`.

**`Tools/socket-ceiling [--pairs N] [--bytes SIZE] [--write SIZE] [--buffer SIZE] [--unix] [--runs N]`** — the
kernel's local-socket throughput with blocking C sockets on plain threads (loopback TCP or a Unix socketpair):
the ceiling to compare networking benchmarks against (MQTTSocketStream's transfers reach most of it).

**`Tools/toolchain …`** — non-Xcode toolchains: `list`, `install`, `register`, and running commands,
programs (`--runtime`), and tests (`test`) with one. See Toolchains below.

## Toolchains

Xcode's toolchain is the default. Others (swift.org snapshots, unmerged-PR builds) are installed in
`~/Library/Developer/Toolchains`, selected with `TOOLCHAINS=<bundle id>` (xcrun, `swift build`, and every
Tool honor it), and never on PATH (the shell profile doesn't add them).

- **Registry:** `Tools/toolchains.json` lists the toolchains the experiments need: how to install each
  (`{"swiftly": SPEC}` for releases and snapshots; `{"url": TARBALL}` for what swiftly can't install, like PR
  builds from `download.swift.org/tmp/pull-request/<PR>/<build>/xcode/swift-PR-<PR>-<build>-osx.tar.gz`, which
  extract into `~/Library/Developer/Toolchains` and **expire**) and, once installed, its directory and
  bundle id. A package needing one names it in `PACKAGE/.swift-toolchain` (MQTTSocketStream: `pr-91981`).
- **`Tools/toolchain list`** shows each entry (installed or missing, used by which packages), plus
  unregistered installed toolchains and broken links (a `swift-latest` symlink to a deleted snapshot is
  typical). `Tools/doctor` reports the same problems.
- **Installing:** `Tools/toolchain install NAME` (swiftly, or download, check, and extract; PR builds are
  ~3 GB: ask the user first). It records the installed directory and bundle id. When you install one by
  hand, remember it: `Tools/toolchain register NAME --url URL --path ~/Library/Developer/Toolchains/X.xctoolchain`.
  If a PR build's URL has expired, probe newer build numbers of the same PR (`curl -sI …/<PR>/<n>/…`),
  then register the new one.
- **Using one:** NAME is a registry name, a package directory (its `.swift-toolchain`), or an installed
  toolchain's name, bundle id, or alias.
  ```sh
  eval "$(Tools/toolchain MQTTSocketStream env)"     # TOOLCHAINS, TOOLCHAIN, TOOLCHAIN_RUNTIME
  Tools/toolchain MQTTSocketStream -- swift run --package-path MQTTSocketStream -c release mqtt-socket-stream
  Tools/toolchain MQTTSocketStream -- swift package --package-path MQTTSocketStream --disable-sandbox benchmark
  Tools/toolchain MQTTSocketStream test             # tests against the toolchain's runtime
  Tools/toolchain pr-91981 -- Tools/loops --target Base64 Base64 encodeBlocks   # codegen with another compiler
  ```
- **The toolchain's runtime:** code using APIs newer than the OS's Concurrency/stdlib must load the
  toolchain's runtime. `swift test` and the benchmark plugin replace `DYLD_LIBRARY_PATH` for the processes
  they start, so executables embed it (`-Xlinker -dyld_env -Xlinker DYLD_LIBRARY_PATH=…`), computed in
  Package.swift from `TOOLCHAIN_RUNTIME` or `TOOLCHAINS` (see MQTTSocketStream/Package.swift: no path is
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

## Lessons (vectorization, allocation, concurrency)

Vectorization on ARM64 with Swift 6.4 (details and numbers: `Base64/Benchmarks/RESULTS.md`,
`Bytes/Benchmarks/RESULTS.md`):

- Loops from one typed span to another (`Span<InlineArray<3, UInt8>>` → `MutableSpan<InlineArray<4,
  UInt8>>`) auto-vectorize to `ld3`/`st4`; bounds checks on typed elements fold away. Offset loads from a
  `RawSpan` are each bounds-checked and don't.
- A table lookup in a loop is a gather: it blocks the vectorizer. Compute instead, with arithmetic masks
  (`(v &+ 128 &- k) &>> 7`), not `if`/ternary chains: LLVM threads correlated conditions into branches,
  then reports "loop control flow is not understood".
- `SIMD16<UInt8>` on 6.4: comparisons of two vectors (`a .== b`, `a .>= b`) are one instruction (`cmeq`,
  `cmhs`), but the overloads taking a scalar (`v .== 0`, `v .>= 0x80`) compile lane by lane; `any()`/`all()`
  are inlined (`umaxv`) in some loops and out-of-line calls elsewhere. Splat scalars
  (`SIMD16(repeating:)`), or use `ByteLanes`. All fixed in 6.5-dev. The dynamic subscript is per lane on
  both. NEON `tbl` isn't reachable from Swift: use a small C target (`CBytesNEON`) with `static inline`
  intrinsics.
- LLVM merges consecutive shuffles: two rounds of `zip`s written with Swift lane initializers became
  four-source shuffles lowered to 1 `zip` and 14 lane inserts per vector. `bytes_interleave4` in C keeps
  the rounds apart with an empty `asm("" : "+w"(v))` (a standalone C version without it didn't merge, in a
  later check). Shuffles chosen by a `Bool` parameter, and vectors built from an array literal then mutated
  per lane, also become inserts (16 for the literal).
- The Base64 `tbl` kernel ends up bound by `tbl` throughput (vector unit pressure), not instruction count:
  fewer instructions didn't mean faster. Measure variants.

Allocations: package-benchmark's malloc counter with a `Thresholds/` file at 0 is the gate (names without
spaces: thresholds for names with spaces break, ordo-one/package-benchmark#373). To find a source:
`Tools/calls … --callee 'swift_allocObject|swift_slowAlloc|malloc'` statically, `Tools/runtime-count
--break swift_allocObject` dynamically, `Tools/allocations` for responsible callers.

Concurrency: find actual hops with `Tools/tasks` (Instruments' `SwiftTaskStateTable`: thread and actor per
Running interval); count executor checks with `Tools/runtime-count --break
swift_task_switch@libswift_Concurrency.dylib` (and `--who …=x0`); check suspension points statically with
`Tools/calls --target PKG TARGET PATTERN --callee swift_task_switch`. In MQTTSocketStream, 55–113
`swift_task_switch` calls per transfer turned out to be zero hops for the socket tasks.
`nonisolated(nonsending)` keeps async functions on the caller's executor. System Call Trace (`syscall`
table) counts syscalls without the breakpoint perturbation.

Enums: big `switch`es over payload enums in hot code can get poorly optimized; the MQTT fix was per-type
`init(parsing:)`/`write(to:)` with a single dispatch (`MQTT/Sources/MQTT/Framing.swift`).

## Benchmarks (ordo-one/package-benchmark)

- Run: `swift package --disable-sandbox benchmark [--filter REGEX]`; save: `… baseline update NAME`;
  compare: `… baseline compare A B` or `Tools/bench-table PKG A B`. Thresholds: `… thresholds update`.
- `baseline read --filter` is ignored (bench-table filters itself). JMH export requires the built-in
  throughput metric. Markdown units vary (K/M, μs/ms): bench-table normalizes.
- A custom metric named `.throughput` collides with the built-in: name it otherwise (`.inputThroughput`).
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
- Serialize anything timing-sensitive with a shared lock:
  `lockf -k "$SCRATCH_ROOT/bench.lock" swift package --disable-sandbox benchmark …`.
- Give each agent its own packages to edit; a shared dependency (Bytes) stays read-only while others
  compile against it, and new API for it is proposed (prototyped in the consumer), not added mid-run.
- Give each agent its own scratch subdirectory; agents overwrote each other's helper scripts in a shared one.
- Don't wait for another job with `until ! pgrep -f 'PATTERN'; do sleep 5; done`: the waiting shell's own
  command line contains PATTERN, so `pgrep -f` always finds it and the loop never ends (ten such loops
  outlived their agents). Wait on the job's PID (`while kill -0 $pid …`), on its output file, or let the
  harness notify you when a background job exits.

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
in Settings → MCP). The headless stdio server needs Commercial/Ultimate. If it isn't running when a session
starts, its MCP tools fail to load (ECONNREFUSED); `Tools/bn` talks to it with curl once it is.

75 tools; the useful ones here: `bn_open_item_open`/`close`, `bn_analysis_update_and_wait`,
`bn_function_search`, `bn_function_disassembly`, `bn_function_basic_blocks` (marks back edges),
`bn_function_il` (lifted/llil/mlil/hlil), `bn_memory_read`, cross-references.

Assessment: **complementary, not a replacement for the scripts.** It adds CFGs with back-edge flags,
demangled names everywhere, cross-references and interactive navigation, and its LLIL shows NEON as
intrinsics (`vqtbl3q_s8`, `vzip1q_s8`), which reads well. But some NEON lifts poorly (`usra` unimplemented,
`st2` expanded to scalar stores, lane operations as one statement per lane), HLIL is noisy for vector code,
constant pools in `.o` files read as empty (open linked binaries), it needs the app running, and it can't
assert. Use `Tools/loops` for checks and iteration; open Binary Ninja to understand an unfamiliar function's
control flow. Close what you open (`Tools/bn loop-il` does).

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

## Compiler bug reports

Search before writing: `gh search issues --repo swiftlang/swift "…"` and `gh search prs` (the search API
rate-limits: space out queries), plus the forums. For the source, a sparse, shallow clone of swiftlang/swift
(`git clone --filter=blob:none --sparse --depth 1`, then `git sparse-checkout set lib/IRGen …`) or
`raw.githubusercontent.com` for single files. Reports follow the format in `~/Downloads/swift-bugs/` (a
summary, a minimal reproducer with `repro.sh` and expected output, analysis down to the pass, workarounds,
timing). `Tools/sil-trace` finds the pass; `-Xllvm -sil-disable-pass` confirms it.

## Cleanup

- Tool scratch directories are removed on exit; your own go in the scratchpad.
- No `*.opt.yaml`, `.ll`, `.sil` or `.o` files left in the workspace root (SwiftPM's working directory).
- `PROGRAM-debuggable` copies live next to the build products in `.build` (rebuilt or removed with it).
- Kill background processes you started (`xctrace`, drivers, servers); close Binary Ninja tabs you opened;
  close only the browser tabs you opened.
