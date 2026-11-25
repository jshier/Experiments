# AGENTS.md

How to do performance and compiler investigations here: the rules, the workflow, and where the detail lives. Project
READMEs are for people; this file, its companions, and each project's `RESULTS.md` are the working record.

| File | Holds |
|---|---|
| `PACKAGES.md` | What every package and target contains, in detail |
| `Tools/README.md` | Every tool's full reference (options, edge cases, exit codes), toolchains, the two LLVMs, compiler flags, xctrace, Binary Ninja, Homebrew; the full Tests, Benchmarks, and Parallel agents rules with their numbers |
| `LESSONS.md` | Everything investigations found, by date, with a topic index: **read the sections for your area before starting** |
| `PROJECT/RESULTS.md`, `Writeups/` | Numbers, per project; surveys, plans, and cross-machine comparisons |
| `~/Scratch/swift-bugs/` | Compiler bug reports (`NN-swift-…md`, `repro-NN-…/`, a zip in `attachments/`, an index row in its READMEs); package-benchmark's in `~/Scratch/package-benchmark-bugs.noindex/`, SwiftFormat's in `~/Scratch/swiftformat-bugs.noindex/` |

Add new lessons to `LESSONS.md` under a dated heading; add a rule here only when it applies to all work.

## Repository

Independent experiments, each its own SwiftPM package (no root package):

| Project | What | Record |
|---|---|---|
| `Bytes` | Span-based binary reading/writing (bit and byte cursors, bit fields, records), SIMD scanning (`ByteLanes`, NEON via `CBytesNEON`), checksums, buffers; `BytesBase64`; `BytesAsync` (async pipelines and the waiting primitives Disk, NativeAEA, NativeZip share); `BytesMacros`; `BytesFoundation`; `BytesCrypto` (AEADs on ARM's AES/PMULL, hashes, KDFs, TLS 1.3, P-256/P-384, HPKE, RSA, DER/PEM/X.509) | `Benchmarks/RESULTS.md`, `RESULTS-*.md` |
| `BytesCompression` | The codecs: DEFLATE/zlib/gzip, Brotli, Zstandard (and encoding at levels 1–4), LZMA/LZMA2/xz, bzip2, Apple's LZFSE/LZVN/LZ4/LZBITMAP/LZRAVEN; containers' identifiers mapped to formats, `Compressor`, `ChunkedDecompressor`, `PBZ`; `BytesCompressionAsync` (`ParallelBlockDecoder`); `BytesReferenceCodecs` | `RESULTS.md`, `Benchmarks/RESULTS-*.md` |
| `MQTT` | MQTT 5 packets on Bytes | `Benchmarks/RESULTS.md` |
| `SocketStream` | MQTT over sockets with a PR toolchain's I/O, compressed and TLS-encrypted through Bytes pipelines | `RESULTS.md` |
| `NativeZipArchive` | ZIP extraction, every method and encryption in Swift; `ZipExtractor`; `nunzip`; typed `throws(ZipError)` | `Benchmarks/RESULTS.md` |
| `NativeAEA` | `.aea` (all six profiles), `.aar`, `.xip`, extracted as `aa extract`/`xip --expand` do; `nunarchiver`; `FORMAT.md`, `ARCHITECTURE.md` | `RESULTS.md`, `XIP-REPORT.md` |
| `Disk` | Writing extracted trees (contained paths, staging, writers, `decmpfs`, metadata, quarantine, progress), `MappedFile`/`InputFile`/`OutputFile`, explicit `close()` | `RESULTS.md`, `ARCHITECTURE.md` |
| `HTTPBytes` | HTTP/1.1, HTTP/2, HTTP/3 framing and fields, no allocations per message; benchmarks are their own package | `RESULTS.md`, `PLAN.md`, `WRITEUP.md` |
| `Nunarchiver` | macOS app (TCA26, Xcode project) replacing Archive Utility; build with its `build.sh` | — |
| `BinaryParsingComparison` | Bytes vs swift-binary-parsing | `RESULTS.md` |
| `NativeISO8601`, `*Benchmark` | Smaller benchmarks | READMEs |

Benchmarks use [ordo-one/package-benchmark](https://github.com/ordo-one/package-benchmark); baselines in each
package's `.benchmarkBaselines/`, allocation thresholds in `Thresholds/`.

## Ground rules

- **Measure, don't assume**: a baseline before and after every optimization claim, numbers in the project's
  `RESULTS.md` (`Tools/bench-table` makes the table).
- **Check the machine code, not just the timing**: "vectorized" means `Tools/loops` says `vector128` for the hot loop
  (and `Tools/counters --mode simd_fp_unit_instructions` shows SIMD work); "no allocations" means a zero-malloc
  threshold passes (`Tools/allocations` explains any that don't).
- Don't touch project READMEs beyond what the user asks. Don't commit unless asked.
- **Access control follows usage, not API stability**: nothing here is stable. `public` for what another package or
  the app uses, `package` for the package's own targets, `internal` otherwise; reshape public API freely, no
  deprecated aliases. Find the real surface with the symbol graph and clients' sources (`LESSONS.md`, 2026-11-22).
- **No warnings** in sources, tests, or benchmarks with Xcode's toolchain (unless the warning is the experiment):
  `swift build --build-tests` after touching files (an incremental build doesn't repeat warnings for files it doesn't
  recompile). In tests, `#expect(throws:) { _ = try … }`.
- After renaming or moving public API, check Bytes' DocC links: `swift build --target Bytes -Xswiftc
  -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc /abs/sg`, then `xcrun docc convert
  Sources/Bytes/Bytes.docc --additional-symbol-graph-dir /abs/sg --output-path /abs/out --analyze`, and look for
  "doesn't exist". Link reader/writer members on `GenericBytesReader`/`GenericBytesWriter`.
- **Swift style**: public API `@inlinable` (measure: it changes codegen), `sending` over `@Sendable` where it fits,
  every `unsafe` expression with a comment saying why it's safe.
- New Xcode projects and targets: set `SWIFT_DEFAULT_ACTOR_ISOLATION` to `nonisolated` (templates say `MainActor`);
  Xcode 27 projects are JSON (`X.xcodeproj/project.xcproj`): check no target still says `MainActor`.
- Executables with options use swift-argument-parser (`@main struct …: ParsableCommand`, option enums
  `ExpressibleByArgument`), never hand-parsed `CommandLine.arguments`. Examples: `nunzip`, `socket-stream`. Benchmark
  executables are the exception.
- **Adversarial review for plans and the biggest changes only**: a plan before implementing it; a new subsystem, a
  rewrite, new or reshaped public API, new concurrency or unsafe code, or a hot loop's restructuring. Smaller changes
  get one when the user asks. It runs in parallel (a separate read-only agent given the changed files and the reason,
  not your conclusions; probes in `~/Scratch/…noindex`) while you test and document. Confirm each finding with a
  probe, fix the real ones, say which you rejected and why. Fixes don't get another review unless large. A
  review-and-fix cycle the user asks for runs until a review comes back clean or the user ends it. (Reviews have found
  defects every test passed.)
- **SwiftFormat**: `swiftformat .` from the root (options and their reasons in `.swiftformat`) at the end of every
  change set, after tests pass; then only `swift build --build-tests` per package (and Nunarchiver's `build.sh`), no
  warnings. Never while another agent edits the tree. Agents format the files they changed before reporting. Known
  traps: `redundantParens` turns `!(unsafe f())` into unparseable `!unsafe f()` (write `unsafe !f()`); the `isEmpty`
  rule breaks types with `count` but no `isEmpty` (add one; keep tuple counts out of `count == 0`); `redundantSelf`
  can drop a TCA26 `@FeatureEnvironment` `self.` (`// swiftformat:disable:next redundantSelf`). Bug reports:
  `~/Scratch/swiftformat-bugs.noindex/`.
- **Edit/Write for file changes**, not `sed -i` or scripts; jq for JSON, yq for XML/YAML/TOML, no inline Python; never
  `rm -rf "$VAR"` without checking the variable. The Edit tool drops trailing whitespace from its strings (it glued
  `packagevar`, `structName`, `=try` in three batch edits): end replacements at a non-space character, and after a
  batch edit grep for the glued form. Chain destructive shell steps with `&&`, never `;`.
- **Test data isn't checked in**, only the scripts that make it: `Tools/test-data` downloads or generates `TestData/`
  sets from fixed seeds and times (archives: `archive-coverage`, `nativeaea-synthetic`, `nativezip-formats`). The
  Xcode archives in `~/Scratch` are for opt-in local runs only (`NATIVEAEA_ARCHIVE=… benchmark`,
  `NATIVEAEA_CONFORMANCE=1`); a test that needs one is skipped visibly (`.enabled(if:, "reason")`), never by
  returning early. New coverage goes into a generator, with the reference tool's manifest made at generation time.
  Writers of test data call `in_testdata PATH` (`Tools/lib/testdata.sh`) before every write or delete.
- **Files outside the repository live in `~/Scratch`**. Never read or write `~/Downloads`, `~/Desktop`, or
  `~/Documents`: a privacy prompt there hangs the program.
- **Delete only what your work created.** `~/Scratch` mixes the user's files (Xcode archives, bug reports) with
  agents' outputs; an agent once deleted the archives. Before any `rm` outside the session scratchpad, confirm the
  target is yours; when freeing space, list candidates and ask about the rest.
- **Where agents write**: `$TMPDIR`/`mktemp -d`/tests' `TemporaryDirectory` for files that live as long as a command;
  otherwise `~/Scratch/<work>.noindex` or `TestData/`. Never the workspace root. SwiftPM runs `swiftc` from the root,
  so pass absolute paths with `-Xswiftc`.
- Analysis tooling goes in `Tools/`, generalized (extend a Tool rather than add a project script); projects keep only
  their own experiment drivers.
- **Never hardcode a toolchain's path, bundle id, or an Xcode path**: name a `Tools/toolchains.json` entry in the
  package's `.swift-toolchain` and run through `Tools/toolchain`; use `xcode-select -p` and `xcrun` for Xcode.

### Attaching needs `get-task-allow`, and prompts need the user

Instruments' attaching templates, lldb, and `sample` need the target signed with `get-task-allow` (else xctrace's
"Failed to attach to target process"). The Tools that launch programs use `PROGRAM-debuggable`; do the same by hand:
`"$(Tools/debuggable PROGRAM)" ARGS`. With Developer Mode off, the first attach shows an authentication prompt (valid
10 hours) the user may not see: use timeouts, and when something hangs or fails to attach, **tell the user to look for
the prompt**. `sudo DevToolsSecurity -enable` is the user's call, never yours. Also the user's: `sudo` (powermetrics,
dtrace, `fs_usage`), starting Binary Ninja's MCP server, `gh` authentication. A program blocked at 0% CPU in `open`
of a protected folder, or on its first URLSession request to a new domain, is waiting on a prompt too.

## Start here

```sh
Tools/doctor        # CPU, SIP, Xcode, toolchains, generators' dependencies, Homebrew and the Brewfile; exit 1 if anything required is missing
Tools/tests/run     # the Tools' own regression checks (or `run NAME…`; some attach: the prompt above)
Tools/test-data fetch   # TestData on a fresh clone
```

Tool conventions (`Tools/lib/common.sh`): `--help`; results on stdout, tab-separated where tabular (`column -t -s
$'\t'`); notes on stderr; exit 0 success, 1 a check failed, 2 bad usage or missing dependency. `TOOLCHAINS=<bundle
id>` switches every tool's toolchain. Bash and Perl only, plus jq/yq.

## The workflow

1. **Benchmark** and save a baseline: `swift package --disable-sandbox benchmark baseline update NAME --no-progress`
   (`--filter` for a subset); then `Tools/slim-baselines PKG`.
2. **Find the hot loop's machine code:** `Tools/loops --target PKG TARGET PATTERN`.
3. **Not vectorized? Ask the compiler why:** `Tools/remarks --target PKG TARGET --function PATTERN`.
4. **Something called that shouldn't be** (retain/release, `outlined destroy`, `swift_task_switch`, unspecialized
   generics): `Tools/calls`, then `Tools/sil-trace` for the pass that left it.
5. **Estimate** throughput with `Tools/mca` (a lower bound); **measure** with `Tools/counters`; time per function with
   `Tools/profile` or `Tools/sample-top`.
6. **Count runtime events** with `Tools/runtime-count`; explain allocations with `Tools/allocations`.
7. Re-benchmark, `Tools/bench-table PKG old new`, record in `RESULTS.md`.

## Tools

One line each; the reference is `Tools/README.md`.

| Tool | Use |
|---|---|
| `loops FILE\|--target PKG TARGET PATTERN [--require OPS] [--forbid OPS]` | Natural and irreducible loops of matching functions with a verdict (`vector128`, `scalar`, `+lane-moves`, `+calls`); an assertion with `--require`/`--forbid`. PATTERN is a regex on demangled names without parameter types: anchor it (`…:\)`) |
| `remarks` | Swift's own LLVM optimization remarks (vectorized or why not; `--passes sil-inliner`, `inline`, …) |
| `swiftc-target PKG TARGET -- ARGS` | A target's exact `swiftc` command plus yours: SIL, IR, assembly with real flags |
| `calls FILE\|--target … PATTERN [--callee REGEX] [--sum]` | Static call sites per caller and callee; exit 1 when nothing matches (that's the answer to "no `swift_retain`") |
| `sil-trace` | SIL instructions matching MATCH after every pass that changed them |
| `mca` | llvm-mca on the loop `loops` finds; a lower bound (Apple models derive from Cyclone) |
| `bn` | Binary Ninja's MCP server from the shell; `loop-il` prints loops' IL |
| `counters` | CPU Counters: bottlenecks, `simd_fp_unit_instructions` (run-time proof of vectorization); some modes record nothing on the M1 Max |
| `profile` | Time Profiler symbolicated from a dSYM, inlined frames included |
| `sample-top` | macOS `sample`, self samples per thread; attaches to a running process |
| `runtime-count` | LLDB breakpoints that count (`swift_task_switch`, `swift_allocObject`, `malloc`); `--who SYM=REG`; perturbs timing |
| `allocations [--history]` | Instruments' Allocations, live callers; `--history` for freed ones (malloc stack logging) |
| `tasks` | Swift Concurrency template: real hops per task (moves, not executor checks: pair with `runtime-count`) |
| `bench-table PKG BASELINE…` | Baselines side by side, units normalized, 3–4 significant digits |
| `slim-baselines` | Shrinks saved baselines ~9x without changing what they report; run after every `baseline update` |
| `debuggable PROGRAM` | Prints a `get-task-allow`-signed copy |
| `job start\|run\|wait\|status\|log NAME` | A long command that can be waited for reliably (`~/Scratch/jobs.noindex`) |
| `disk-space [--check GB]` | Free, available (with purgeable), and opportunistic space: use instead of `df` before large writes |
| `untracked -- CMD` | Runs CMD as a launchd job, outside provenance tracking |
| `socket-ceiling` | The kernel's local-socket throughput: the ceiling for networking benchmarks |
| `cpu-probe`, `probe` | What a core can do (clock, instruction latency/throughput, memory); `probe all`/`compare` across Macs (`Tools/probes/README.md`) |
| `toolchain` | Non-Xcode toolchains: list, install, register, run with one |
| `test-data`, `corpus` | `TestData/` sets (downloaded and pinned, or generated); the compression corpus in `~/Scratch/corpus.noindex` |

## Toolchains

Xcode's toolchain is the default. Others live in `~/Library/Developer/Toolchains`, selected with `TOOLCHAINS=<bundle
id>`, never on PATH. `Tools/toolchains.json` is the registry (`{"swiftly": SPEC}` or `{"url": TARBALL}` for PR builds,
which expire); a package names its entry in `.swift-toolchain` (SocketStream: `pr-91981`).

- swiftly is installed without shell integration: use it only to install and remove (`Tools/toolchain install NAME`),
  never `swiftly use` or `swiftly run`. PR builds are ~3 GB: ask first.
- `Tools/toolchain list` shows entries, users, unregistered toolchains, and broken links. Remove toolchains your work
  installed once unused; ask before removing others.
- Use: `eval "$(Tools/toolchain SocketStream env)"`, `Tools/toolchain SocketStream -- swift run …`, `Tools/toolchain
  SocketStream test`, `Tools/toolchain pr-91981 -- Tools/loops …`. Code needing the toolchain's runtime embeds
  `DYLD_LIBRARY_PATH` computed in Package.swift (see SocketStream's).
- Two LLVMs: Swift's own (in `swiftc`: what ships; ask with remarks, `-emit-ir`, `-S`, `-Xllvm`) and Homebrew's
  keg-only `llvm` (`llvm-mca`, `opt`, `llc`). Brew `opt` on Swift IR is an approximation: confirm with Swift's remarks.

## Rules the lessons keep teaching

The details and numbers are in `LESSONS.md`; these came up more than once.

- **Inlining**: `@inlinable` isn't inlined. Anything a hot function calls once per entry, initializers included, is
  `@inline(__always)`; when the SIL inliner declines that hint in a grown loop, `@inline(always)`. After growing a hot
  loop or adding API to its module, check its callees with `Tools/calls` (trivial getters, `SIMD.init`,
  `specialized SIMD`, `metadata`).
- **Hot state in locals**: an out-of-line `mutating` call, an `inout` struct, or an `inout` span keeps state in memory
  for the whole loop. Pass values to static functions, rebind spans to locals, keep rare paths out of line as static
  functions taking values.
- **Hidden allocations**: a `var` pointer assigned in branches and borrowed by a span is heap-boxed (use `let`s set on
  every path); `do { } catch` around typed throws boxes (write `do throws(E)`); nested functions capturing state are
  boxed. Check new hot code with `Tools/calls … --callee swift_allocObject`.
- **Typed throws**: annotate closures' error type (`{ (x) throws(BytesError) in … }`), and never pass a `throws(E)`
  closure to an untyped `rethrows` API (wrong error, silently; swiftlang/swift#90291): use Bytes' span helpers.
- **No lazy globals in measured or hot loops** (each read checks `swift_once`); literal `static let`s are static. A
  table that becomes a constant can be rematerialized per iteration: measure after removing a lazy global.
- **SIMD on Swift 6.4**: scalar-operand comparisons, `pointwiseMin`/`Max`, and array-literal vectors compile badly;
  splat scalars, use `ByteLanes`, write constants as `Byte16` literals. Count micro-ops per pipe (`tbl`/`tbx` cost one
  per table register) rather than instructions.
- **Instructions aren't cycles** for latency- and misprediction-bound loops (range coders, parsers, Huffman): judge by
  `Tools/counters`, not instruction counts alone.
- **Comparing variants in one binary**: look for LLVM's `merged` functions, and give each variant its own
  `@inline(never)` function over a shared `@inline(__always)` body.
- **Tests that catch what others missed**: input ending exactly where a wide-load field ends; trickled input a byte at
  a time with a time limit (quadratic re-scans); truncated input at every cut; short streams after long ones (resets);
  varied filler bytes around matches; every lane count and capacity in sweeps; a differential against the previous
  code or another implementation. Break a fix once to see its test fail.
- **Hostile sizes**: bound every size where it's parsed and saturate sums; believe a header's size only as far as the
  input can expand; reserve from claims with a cap.
- **Compare with the real tool, item by item** (manifests of every attribute) before believing what it reportedly
  does; find its rules from every file, in its units.
- **File systems**: APFS creation peaks around 4–8 threads; keep CPU work outside the file-system limiter. A nearly full
  volume inflates kernel-heavy rows (`Tools/disk-space`); benchmark output goes in a `*.noindex` directory.
- Swift's `&>>` binds tighter than `&*`: parenthesize. Foundation's file APIs decompose names; compare paths by `utf8`.

## Tests

- **Two sets**: `swift test` (debug) is the fast set; `BULK_TESTS=1 swift test -c release -Xswiftc -enable-testing`
  adds the bulk sweeps (`--filter BulkTests` for only those). Large inputs, corpora, and every size/capacity go in a
  `@Suite(.bulk) struct XxxBulkTests` sharing a static helper with the fast test; the fast form keeps every edge case.
- **Small groups first, the whole suite last**: `swift build --build-tests`, then `swift test --skip-build --filter
  'Suite/'` (several `--filter`s work) plus clients' suites; the full set once at the end.
- **Shared helpers are Bytes' support products**, not copies: `BytesTestSupport` (`SplitMix64`, `SampleBytes`,
  `TestData.file`, `TemporaryDirectory`, `ExternalTool.run`), `BytesTesting` (`.bulk`), `BytesReferenceCodecs`, Disk's
  `DiskTestSupport` (`readTree` with `readdir`, `TreeParts`, xattrs/ACLs/`decmpfs`; `com.apple.provenance` ignored by
  default).
- Every suite that touches Disk carries `.diskLifetimes`: close what a test opens at the end of its use.
- **No `.serialized`, no global actors, no process-wide state** in tests (umask, working directory, environment):
  per-test temporary directories, port 0, immutable `static let` fixtures.
- In debug, helpers can cost more than the code tested: decode into uninitialized room, build fixtures once.

## Benchmarks

- Run `swift package --disable-sandbox benchmark [--filter REGEX]` (the filter matches the whole name: `'.*Bytes.*'`; a
  filter matching nothing still prints "Updated baseline"). Save with `baseline update NAME`, named after the work
  (`ab-old-*`/`ab-new-*` are tracked and get overwritten); check `git status` for modified `results.json`; slim with
  `Tools/slim-baselines PKG` before committing. Compare with `Tools/bench-table`.
- Bytes has three builds by trait (`Bytes/bench optimized|portable|portable-no-c`); BytesCompression mirrors them.
- **A benchmark costs a few seconds, and one run is enough.** The `benchmarks` closure only registers (it runs in
  every process start): fixtures are made lazily in `setup:` (the `Lazy`/`register` pattern in
  `BytesCompression/Benchmarks/CompressionBenchmarks/Fixtures.swift`), results checked there. No data-derived names.
  Check registration with `time .build/release/TARGET --filter NOTHING`.
- **Only the work inside `for _ in benchmark.scaledIterations`**: no clocks, fixture lookups, result checks, or lazy
  globals. Throughput from `.throughput` times work per iteration (SocketStream's transfers are the exception).
- Iterations by the work: ~100 or 0.5–1 s up to a millisecond, 20 for 5–50 ms, 1–3 for archives and transfers. Don't
  change `scalingFactor` on an existing benchmark.
- **Compare times only within one interleaved run** (old and new built side by side, alternated): times drift 5–10%
  between runs. Instruction counts don't drift, but compare them only between rows measured with the same metrics.
  File-system rows vary 20–40%; counts under ~100 K instructions ±10% between processes.
- Every plugin invocation rebuilds (~25 s, swift-syntax 2.5–3 min after a change): batch filters, run `benchmark list`
  first, and don't edit a package (or its dependencies) until a queued run's first table prints.
- Include odd sizes (remainder paths). Thresholds' names have no spaces (package-benchmark#373). The malloc
  interposer costs ~10% and traps on thread exit: count mallocs in single-threaded benchmarks, time separately.

### Parallel agents

- Timings aren't trustworthy while other agents build: judge by instruction and allocation counts and codegen; time on
  an idle machine afterwards. No shared benchmark locks or waiting for quiet, except for a final timing the user asks
  for.
- Each agent gets its own packages to edit and its own scratch directory; a shared dependency (Bytes) stays read-only
  (propose new API, prototyped in the consumer). A COW clone (`cp -cR`, without `.build`s) lets two agents change one
  package.
- **How to wait**: (1) don't: run with the Bash tool's background mode and let the harness notify you; (2) when a step
  needs the result, `Tools/job start NAME -- …` then `Tools/job wait NAME --timeout S`; (3) other agents' work: their
  task notification. Never poll with `pgrep -f` loops (they match themselves), `grep` on logs (NUL bytes; `baseline
  update` prints no results table), or `while kill -0` loops. When an agent finishes, check `ps -eo
  pid,ppid,etime,command` for shells it left and stop them.

## macOS and Homebrew tools

`xcrun objdump` (`-d --no-show-raw-insn --symbolize-operands`, `-r`) is the workhorse; `otool -tV` resolves stubs;
`nm --defined-only` with `xcrun swift-demangle --simplified`; `dsymutil` for symbolication. DTrace, `fs_usage`,
`powermetrics` need sudo: avoid. xctrace details and Binary Ninja's MCP server (complementary to the scripts: CFGs, IL,
cross-references; close what you open) are in `Tools/README.md`.

macOS userland is BSD: no `gawk`, GNU `sed`, `timeout` (`gtimeout` from coreutils), or `%N` in `date`. Prefer Perl for
anything non-trivial. The `Brewfile` lists what the Tools use (`Tools/doctor` checks it; installing is the user's
call); lint Tools scripts with `shellcheck`. Script gotchas:

- The Bash tool runs zsh: quote `======`, unmatched globs are errors, `$flags` isn't word-split (`${=flags}`), and
  `status`, `path`, and `log` are special (name them `rc`, `file`; use `/usr/bin/log`). Scripts use a `#!/bin/bash`
  (3.2) or `#!/bin/zsh` shebang.
- Bash reads `$var–` (non-ASCII after a name) as part of the name: `${var}`. Functions in `$(…)` don't inherit `set -e`.
- `cat -vet`, not `cat -A`; `plutil` key paths split on `.` (escape them), `-replace` won't create a key (`-insert`).
- Strip ANSI codes from Xcode-style build logs before grepping; read `build.sh`'s exit line before using its product.

## Compiler bug reports

Search first (`gh search issues --repo swiftlang/swift "…"`, `gh search prs`, the forums; space out queries). Source:
a sparse, shallow clone of swiftlang/swift or `raw.githubusercontent.com`. Reports follow `~/Scratch/swift-bugs/`'s
format (summary, minimal reproducer with `repro.sh` and expected output, analysis down to the pass, workarounds,
timing); `Tools/sil-trace` finds the pass, `-Xllvm -sil-disable-pass` confirms it.

## Cleanup

- Your scratch goes in the session scratchpad; no `*.opt.yaml`, `.ll`, `.sil`, or `.o` files in the workspace root.
- `PROGRAM-debuggable` copies live in `.build`; compiled helpers in `~/Scratch/tools-cache.noindex` can be deleted any
  time.
- Kill background processes you started (`xctrace`, drivers, servers); close Binary Ninja tabs and browser tabs you
  opened.
