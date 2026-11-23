# AGENTS.md

How to do performance and compiler investigations in this repository: the tools in `Tools/`, the workflow
they support, what was learned doing it, and the macOS/Homebrew environment they run in. Project READMEs are
for people; this file and each project's `RESULTS.md` are the working record.

## Repository

Independent experiments, each its own SwiftPM package (no root package). The performance ones:

| Project | What | Record |
|---|---|---|
| `Bytes` | Span-based binary reading/writing (`BytesReader`/`BytesWriter` at bit granularity, `AlignedBytesReader`/`AlignedBytesWriter` for whole bytes, `BigEndianBytesReader`/`LittleEndianBytesReader` and writers for integers by type, named bit fields (`BitFlag`, `BitField`, `BitPattern`), records (`BinaryParsable`), `BitBuffer`/`BitWriter` for entropy coding, `ByteBuffer`, `ByteLanes` SIMD scanning and NEON shuffles via the `CBytesNEON` C target), CRC-32 and Adler-32 (`RunningChecksum`), byte pipelines (`ByteTransform`), `LentBytes` for parallel work, `RawStorage` (memory made once, pages given back between uses); `BytesBase64` (vectorized Base64 encoding and decoding: NEON `tbl`/`tbx` block kernels, auto-vectorized `ld3`/`st4` group kernels; whitespace-skipping decoding for PEM; was the `Base64` package, record `RESULTS-base64.md`); `BytesAsync` (async buffers, pipelines, parallel codecs; the waiting primitives Disk, NativeAEA, and NativeZip share: `Continuation`/`withContinuation`, `WaiterQueue`, `AsyncLimiter`, `AsyncIndexPool`, `AsyncLatch`, `AsyncQueue`, `AsyncHandoff`; and `RelaxedCounter`, `MonotonicClock`, `withPriority`); `BytesMacros` (`@BitFields`, `@BinaryRecord`); `BytesFoundation` (`Data` with spans); `BytesCompression` (DEFLATE/zlib/gzip and Brotli, both directions, and Deflate64 decoding (`DeflateDecoder(variant:)`, and decoding into a caller's buffer after its history); Zstandard decoding, XXH64; LZMA, LZMA2, and `.xz` decoding, whole or streaming (`LZMADecoder`, `XZDecoder`; one `Decompressor` over every format, `DecompressionFormat`, for clients that choose at run time), CRC-64; bzip2 decoding, whole or streaming; Apple's LZFSE, LZVN, LZ4, LZBITMAP, and LZRAVEN decoding, and LZFSE, LZVN, and LZBITMAP encoding (all three byte for byte as Compression's; the open references' parse as an option)); `BytesCrypto` (ChaCha20-Poly1305, AES-GCM and AES-CTR on ARM's AES/PMULL instructions via the `CBytesCrypto` C target, SHA-1/256/384/512, HMAC, PBKDF2, HKDF, scrypt, TLS 1.3's key schedule and record layer, sealing in parallel; P-256 and P-384 ECDSA verification and ECDH (keys and signatures in DER and PEM, both ways), HPKE; RSA PKCS #1 v1.5 verification (1024–4096-bit keys, SHA-1/256/384/512); DER, PEM, and X.509 parsing, and certificate signatures (`isSigned(by:)`, RSA and ECDSA)) | `Benchmarks/RESULTS.md` (and its `RESULTS-*.md`) |
| `MQTT` | MQTT 5 packets on Bytes: `MQTTFrame` (zero-copy header + body), per-type `init(parsing:)`/`write(to:)` | `Benchmarks/RESULTS.md` |
| `SocketStream` (was `MQTTSocketStream`) | MQTT over sockets with a PR toolchain's I/O interfaces, optionally compressed and TLS-encrypted through Bytes pipelines; concurrency hops | `RESULTS.md` |
| `NativeZipArchive` | ZIP: stored, DEFLATE, Deflate64, bzip2, LZMA, xz, Zstandard, every one decoded by BytesCompression's streaming decoders (no zlib, Compression, or libbz2 in the library or `nunzip`; tests and benchmarks use them as references); ZipCrypto and WinZip AES (on BytesCrypto, decrypted as streamed); `ZipExtractor` (many archives, one worker pool, an optional quarantine for everything extracted); `nunzip` (Info-ZIP unzip's options) | `Benchmarks/RESULTS.md` |
| `NativeAEA` | Apple Encrypted Archives (`.aea`: Xcode's, iOS IPSWs' disk images) and Apple Archives (`.aar`, plain or `pbz`): all six AEA profiles (signatures and certificate chains, symmetric, ECDH, and scrypt keys, IPSWs' WKMS keys by HPKE), all on BytesCrypto; segments and blocks decoded in parallel with BytesCompression (no Compression framework or Foundation parser anywhere: WKMS's JSON has its own reader on Bytes; every file read through Disk's `InputFile`); the Apple Archive stream walked with no copies; files written as `aa extract` writes them, byte for byte (APFS `decmpfs` compression with BytesCompression's encoders, extended attributes, ACLs, hard links, FIFOs, quarantine) by writers outside a file system semaphore; decryption to a file, with ranges; Xcode's `.xip` too (XAR TOC, RSA signature and chain to Apple Root CA on BytesCrypto, pbzx blocks of xz, the cpio stream walked into the same extractor, files stored as `xip --expand` stores them); `nunarchiver` (was `unaea`); FORMAT.md documents the formats, ARCHITECTURE.md the pipeline and its threads | `RESULTS.md`, `XIP-REPORT.md` |
| `Disk` | Writing extracted trees, shared by NativeAEA and NativeZip: `EntryPath` (validated relative paths), `Destination` (contained creation with `O_NOFOLLOW_ANY`/`O_RESOLVE_BENEATH`, staging then `publish`/`publishUnwrapped` (Archive Utility's naming)/`discard`), `FileWriter` (one thread, no allocations), `Extraction.run` with a `Planner` and `ContentSource`/`PieceSource` (writers outside a file-system limiter, large files in pieces), APFS `decmpfs` storage as `aa extract` and `xip --expand` store it, metadata in one `fsetattrlist`, quarantine, hard and symbolic links; `ExtractionProgress` (relaxed per-writer counters, polled; `read()` gives the entry-weighted fraction that never goes back); `Destination.reopened(with:)` (clients extract into the caller's `Destination`); `DiskError(wrapping:)`/`isCancellation`; `MappedFile` (the archive being read), `InputFile` (reads at offsets, small whole files such as keys), and `OutputFile` (one file at the caller's path); a `SyscallCounting` trait for the benchmarks | `RESULTS.md`, `ARCHITECTURE.md` |
| `Nunarchiver` | macOS app (TCA26, Xcode project) replacing Archive Utility for `.zip`, `.aea`, `.aar`, `.xip`: expands next to the archive through Disk's staging as Archive Utility does (compared item by item), progress window polling `ExtractionProgress` (throughput in GB/s from the polled bytes), passwords and keys asked for in the row. Build with its `build.sh` (shared scheme, coverage off) | — |
| `BinaryParsingComparison` | Bytes vs swift-binary-parsing | `RESULTS.md` |
| `NativeISO8601`, `*Benchmark` | Smaller benchmarks | READMEs |

Benchmarks use [ordo-one/package-benchmark](https://github.com/ordo-one/package-benchmark); saved baselines are in
each package's `.benchmarkBaselines/`, allocation thresholds in `Thresholds/`. Compiler bug reports and
reproducers live outside the repo, in `~/Scratch/swift-bugs/` (numbered `NN-swift-…md` with a
`repro-NN-…/` directory, a zip in `attachments/`, and an index row in its READMEs).

## Ground rules

- Measure, don't assume: every optimization claim gets a benchmark baseline before and after, and the
  numbers go in the project's `RESULTS.md` (`Tools/bench-table` makes the table).
- Check the machine code, not just the timing: "vectorized" means `Tools/loops` says `vector128` for the hot
  loop (and `Tools/counters --mode simd_fp_unit_instructions` shows SIMD work at run time); "no
  allocations" means a zero-malloc threshold passes (and `Tools/allocations` explains any that don't).
- Don't touch project READMEs beyond what the user asks: they're for humans. Don't commit unless asked.
- Code builds without warnings (sources, tests, and benchmark targets, with Xcode's toolchain), unless the
  warning is the point of an experiment or compiler investigation. Check with `swift build --build-tests`
  after touching the files (an incremental build doesn't repeat warnings for files it doesn't recompile).
  In tests, `#expect(throws:) { _ = try … }` for calls whose result is only there to throw.
- After renaming or moving public API, check Bytes' DocC links: `swift build --target Bytes -Xswiftc
  -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc /abs/sg`, then `xcrun docc convert
  Sources/Bytes/Bytes.docc --additional-symbol-graph-dir /abs/sg --output-path /abs/out --analyze` and look for
  "doesn't exist". Members of `BytesReader`/`BytesWriter` are documented on `GenericBytesReader`/
  `GenericBytesWriter` (the short names are typealiases), so link them as ``GenericBytesReader/read(_:)``.
- Swift style here: public API `@inlinable` (but measure: it can change codegen), `sending` over
  `@Sendable` where it fits, every `unsafe` expression with a comment saying why it's safe.
- New Xcode projects (and targets added to them) turn off the MainActor default: Xcode's templates set
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; set it to `nonisolated` right after creating the project.
  Xcode 27 projects are JSON (`X.xcodeproj/project.xcproj`), so check the file for any target still set to
  `MainActor`.
- Executables that take options use [swift-argument-parser](https://github.com/apple/swift-argument-parser)
  (`@main struct …: ParsableCommand`/`AsyncParsableCommand`, so not in a `main.swift`), never hand-parsed
  `CommandLine.arguments`: `--help`, typed values, and validation for free. Make option enums
  `ExpressibleByArgument` (`String`-backed and `CaseIterable` need no more than the conformance). Examples:
  `NativeZipArchive/Sources/nunzip`, `SocketStream/Sources/socket-stream`. Benchmark executables
  (package-benchmark parses their arguments) are the exception.
- Use Edit/Write for file changes rather than `sed -i`/scripts; jq for JSON, yq for XML/YAML/TOML (no inline
  Python); never `rm -rf "$VAR"` without checking the variable is set and points where you expect.
- Test files aren't checked in, only the scripts that make them: `Tools/test-data` downloads or generates them
  into the ignored `TestData/`, and nothing that writes test data writes or deletes outside it (below).
- Files outside the repository live in `~/Scratch`: the user's example files (Xcode's `.xip` and `.aea` archives),
  the compiler bug reports (`~/Scratch/swift-bugs`), and anything large an experiment makes that should outlast a
  session. Never read or write `~/Downloads`, `~/Desktop`, or `~/Documents`: there's no permission to, and a
  privacy prompt there hangs the program. Tests' own files stay in `TestData/` (below).
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
Tools/loops --target Bytes BytesBase64 encodeBlocks --require tbl,zip --forbid mov.b,ins
Tools/loops --target Bytes BytesBase64 'encode\(_:into:alphabet:\)' --require ld3.16b,st4.16b
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

**`Tools/slim-baselines [--check] [--min-size SIZE] PATH...`** — shrinks saved baselines (`results.json`) about 9x
(the repository's 421: 4.4 GB → 477 MB; the largest, 405 MB → 5.7 MB) without changing anything they report: each metric's HDR histogram is rebased to start at its smallest recorded
value and end at its largest, with every bin keeping its bounds. Run it after every `baseline update`.

**`Tools/debuggable PROGRAM`** — prints `PROGRAM-debuggable`, signed with `get-task-allow`.

**`Tools/untracked [--timeout S] [--keep DIR] -- COMMAND ARGS`** — runs COMMAND as a launchd job (`launchctl submit`,
a unique label, removed after), outside this provenance-tracked process tree: in a tracked process (anything started
from a downloaded terminal) the kernel owns `com.apple.provenance` on what it creates, so a restored value never reads
back. Same directory and environment, stdout and stderr streamed back through files, the command's exit status.
`Tools/untracked -- swift test --package-path NativeZipArchive --filter restoresALinksAttributes` checks the read-back
that `SystemAttributes.isProvenanceTracked` skips (the test prints which branch ran).

**`Tools/socket-ceiling [--pairs N] [--bytes SIZE] [--write SIZE] [--buffer SIZE] [--unix] [--runs N]`** — the
kernel's local-socket throughput with blocking C sockets on plain threads (loopback TCP or a Unix socketpair):
the ceiling to compare networking benchmarks against (SocketStream's transfers reach most of it).

**`Tools/cpu-probe freq | insn [NAME...] | latency [SIZE...] | bandwidth read|store [--bytes SIZE] [THREADS...]`** — what
one core of this Mac can do, in C and inline assembly: the P-core clock (a dependent scalar `add` chain), instruction
latency and throughput in cycles (one dependent chain; 16 independent ones), load-to-use latency by working set (random
pointer chase over 128-byte lines), and read/store bandwidth by thread count. The cost model behind "a 4-register `tbl`
is 3 vector slots" or "two cores saturate memory"; run it on a new machine before reasoning about its micro-op costs.
The M1 Max's numbers: `Bytes/Benchmarks/RESULTS.md`, "What the cores can do".

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
`TestData/SET/` at the repository root (ignored by git). Run `Tools/test-data fetch` on a fresh clone; tests that
need a missing set fail saying which `fetch` to run. Two kinds of set:
- **Downloaded**, pinned to a revision and checked by SHA-256: `swift-binary-parsing` (its PNG, QOI, ELF, PCAPNG,
  and binary plist samples, read by BinaryParsingComparison after its own `Data/`), `wycheproof` (C2SP's AEAD,
  HMAC, HKDF, ECDSA, and ECDH vectors, for BytesCrypto), `rfc8448` (TLS 1.3's example handshake traces, for the key
  schedule and record tests), `rfc9180` (HPKE's test vectors), `c-references` (the lzfse and libzbitmap sources
  BytesCompression's LZFSE, LZVN, and LZBITMAP coders were compared against; not built now: Bytes'
  RESULTS-lz4-lzfse.md and RESULTS-lzbitmap.md say how to add them back as targets).
- **Generated** by a checked-in script, run with the output directory as its argument and made again when any
  file in the script's directory changes: `swift-help-lz4` (`BinaryParsingComparison/TestDataGenerators`:
  swift-binary-parsing's `ELF/swift-help` through `lz4 -9`; lz4 1.11.1 reproduces the benchmarked file byte for
  byte, and the script warns when another version doesn't), `nativezip-formats` and `nativezip-lzma`
  (`NativeZipArchive/Tests/NativeZipTests/Fixtures/{formats,lzma}`, read through the tests' `testDataFile`). `nativeaea-synthetic`
  (`NativeAEA/Benchmarks/Fixtures`: an Xcode-like Apple Archive stream in a signed `aea` container, about 1 GB;
  the signature differs each time, the archived files don't). When
  a generated file is what benchmarks measure, the generator checks its SHA-256 against the measured one.

Don't check in archives, images, or other test binaries: add a download line or a generator to the script.
Scripts that write test data source `Tools/lib/testdata.sh` and call `in_testdata PATH` before every write or
delete (it resolves `..` and symbolic links, and refuses anything outside `TestData/`); Python generators have the
same check (`in_testdata` in each). Temporary work goes inside the output directory too (`OUTPUT/.work`).
(`Tools/corpus` is the compression corpus, cached outside the repository.)

## Toolchains

Xcode's toolchain is the default. Others (swift.org snapshots, unmerged-PR builds) are installed in
`~/Library/Developer/Toolchains`, selected with `TOOLCHAINS=<bundle id>` (xcrun, `swift build`, and every
Tool honor it), and never on PATH (the shell profile doesn't add them).

- **Registry:** `Tools/toolchains.json` lists the toolchains the experiments need: how to install each
  (`{"swiftly": SPEC}` for releases and snapshots; `{"url": TARBALL}` for what swiftly can't install, like PR
  builds from `download.swift.org/tmp/pull-request/<PR>/<build>/xcode/swift-PR-<PR>-<build>-osx.tar.gz`, which
  extract into `~/Library/Developer/Toolchains` and **expire**) and, once installed, its directory and
  bundle id. A package needing one names it in `PACKAGE/.swift-toolchain` (SocketStream: `pr-91981`).
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

## Lessons (vectorization, allocation, concurrency)

Vectorization on ARM64 with Swift 6.4 (details and numbers: `Bytes/Benchmarks/RESULTS-base64.md`,
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
`Tools/calls --target PKG TARGET PATTERN --callee swift_task_switch`. In SocketStream, 55–113
`swift_task_switch` calls per transfer turned out to be zero hops for the socket tasks.
`nonisolated(nonsending)` keeps async functions on the caller's executor. System Call Trace (`syscall`
table) counts syscalls without the breakpoint perturbation.

Enums: big `switch`es over payload enums in hot code can get poorly optimized; the MQTT fix was per-type
`init(parsing:)`/`write(to:)` with a single dispatch (`MQTT/Sources/MQTT/Framing.swift`).

Old and new code in one benchmark run (variants of a function chosen by a constant `Bool`, so one run
compares them without drift): check that each variant really is specialized. LLVM's function merging can
fold the two copies back into one `merged …` function taking the constant as a parameter, and a closure
that captures the flag is specialized once, taking it at run time: both variants then test it in their
hot loop. Look for `merged` symbols (`nm --defined-only X.o | xcrun swift-demangle | grep merged`), and pass
the constant as a literal at the inlined call inside the closure (BinaryParsingComparison's LZ4). Likewise
don't measure a new path and its reference in one function behind a run-time flag: changing one path moved
the other's register allocation (an unchanged reference went 70 → 102 K instructions). Give each its own
`@inline(never)` function over a shared `@inline(__always)` body. And compare instruction counts across two
builds of a harness with care: identical code differed by a constant ~1.3 K per iteration between them.

Rare paths stay out of line even when they're the thing being optimized: Bytes' faster short-distance
back-reference, inlined, grew DEFLATE's decode loop 15% and cost 12–14% on text, where it never runs. As a
static function taking values (Bytes' slow-path pattern), it kept its gain (−38% on pixel runs) at no cost
elsewhere. Check the hot loop's size with `Tools/loops` before and after.

`@inlinable` doesn't mean inlined: a new `BytesWriter` initializer, only `@inlinable`, was called out of line
from NativeZip's decode function (789 → 891 instructions, the writer returned through memory). Anything a
hot function calls once per entry, initializers included, should be `@inline(__always)`; check with
`Tools/calls … --callee init` after adding API.

Constant vectors: `SIMD16<UInt8>` array literals (`[0, 16, 32, …]`) inside inlinable library code compiled
to calls to `SIMD.init(_:)` in the caller's loop (Base64's decoder: 3 calls per block, then 5 per call for
its table, ~1,200 instructions); in other functions the same literals folded. Write them as `Byte16`
literals (bytes in memory order, `0x00_10_20_…`) and take `.vector`: integer constants always fold. Check
new kernels with `Tools/calls … --callee 'SIMD.init'`.

LLVM narrows loads to the lanes a shuffle uses: the first round of `uzp1`s needs only the even bytes, so a
64-byte block feeding `ByteLanes.deinterleave` was loaded as 8-, 4-, 2-, and 1-byte lane loads (`ld1.b`,
`mov.h`, `ext`): 91 instructions per block against 45. An empty `asm` on the vectors before the shuffle
(`CBytesNEON.h`) keeps the loads whole.

Shifts bind tighter than multiplication in Swift: `count &* 3 &>> 2` is `count &* (3 &>> 2)`, which is 0.
Parenthesize (`(count &* 3) &>> 2`).

Portable byte shuffles: a `SIMD16<UInt8>` built from `v[k]` picks of one vector with constant `k` (or
constant zeros), `SIMD16(v[4], v[3], …, 0)`, compiles to one shuffle: a single-register `tbl` on ARM64,
`pshufb` on x86-64 macOS (SSE2-only x86-64 expands it into a longer sequence). Bytes' `GroupShuffle` packs
and unpacks 3- and 5–7-byte groups this way with no C; a one-register `tbl` is a quarter of a 64-byte
one's micro-ops, and for iterators it beat the NEON lookups by 22–44%, so every build uses it there. Two traps, both from LLVM merging what it can see:
building the vector from computed scalars and then shuffling became one byte insert per byte (40 per
vector), and taking values out of the vector into a caller's body kept the body scalar. The portable fix
for both (no `asm` barrier) is a small stack buffer (`withUnsafeTemporaryAllocation`, no allocation):
compute values into it with a plain loop and load vectors back, or unpack into it and run the body over
it, so the plain loops vectorize on their own.

Emulating a lookup that's one instruction on one CPU is no portable fallback: Bytes' 64-byte `tbl` shuffles,
emulated a lane at a time in C, ran 37–113x slower than the NEON build and 15–54x slower than the plain
Swift loops. Gate such algorithms on the instruction being there (`ByteLanes.isLookupVectorized`), and
measure the other builds (`Bytes/bench portable`, `portable-no-c`).

Table lookups in a `Span` lose their bounds checks only while the optimizer knows the count: 256-entry
spans for a CRC's byte tables folded the checks in one loop and not another, and a precondition stating
the counts fixed that loop and made the other spill and check again. For hot tables, pointers into
borrowed storage, with the reason in a comment (Bytes' `CRC32._Tables`).

On M3, NEON `ld4`/`st3` didn't beat `uzp` and `tbl` shuffles for Base64 decoding (C, 12.9 against 12.5
GB/s): the loop is bound by vector-pipe micro-ops, and each `tbl`/`tbx` costs one per table register. Count
those (a 64-byte `tbx` is 4) when choosing a lookup: Base64's decoder went from a 128-byte table (`tbl` +
`tbx` on 64 each) to an 80-byte window (64 + 16), 69 to 61 micro-ops per block, +11%.

Closures passed to a generic `throws(E)` parameter: unannotated, `{ x in … }` is inferred as
`throws(any Error)` (Swift 6.4, without `FullTypedThrows`), and such a closure wasn't inlined into Bytes'
array builder: the writer went through memory, +3% instructions. Annotated `{ (x) throws(BytesError) in … }`,
it was inlined. An overload taking only `throws(BytesError)` doesn't fix it: the unannotated closure still
infers `any Error`, then fails to convert. Annotate the error type of closures in hot code. (The builder
itself now reserves an empty array and appends, through the standard library's specialized
`append(addingCapacity:)`, where both forms measure the same.)

The standard library's `[UInt8](capacity:initializingWith:)` (the `OutputSpan` initializer) and
`init(unsafeUninitializedCapacity:)` allocate through an unspecialized function: ~500 instructions and ~27
ns per array more than `reserveCapacity` then `append(addingCapacity:)`, or `Array(UnsafeRawBufferPointer)`,
at any size. For small arrays in hot code, use those.

Compression and crypto (details: `Bytes/Benchmarks/RESULTS.md`, `SocketStream/RESULTS.md`):

- **Compression bugs often show only as size.** Matches are verified, so a broken match finder still
  round-trips: DEFLATE's 16-bit positions rebased on `position - base == 32768`, positions that weren't
  inserted (a flush's last bytes) stepped over it, and every match after was lost (14% → 62% after 26 MB of
  a socket stream). Use `>=` for boundary checks, and test long streams with flushes against one-shot size.
- **Pick an adaptive path by what the optimization saves, measured, not a proxy.** Brotli's tag filter
  (8 extra hash bits per bucket entry, 16 compared at once) was 17–30% slower on text and 35% faster on
  x-ray. Copied fraction and average match length didn't predict it; the entries the tags rule out did
  (text 3–6 of 16, binaries 10–14). Sampled every 32nd search, decided per meta-block: best of both.
- **Specialize hot loops on a constant, as a copy:** Brotli quality 1's one-entry table ran through the
  bucket code's loop, 7–10% more instructions. Two `@inline(never)` wrappers over an `@inline(__always)`
  body with a constant `Bool` fixed it (check for `merged` symbols, above).
- **Reused state carries stale entries.** A reset that keeps a table by moving the position base leaves
  every old entry out of range but still scanned: check the newest entry first (a 1.6 KB stream −24%).
  Breaking out of the scan loop instead cost large inputs 3–5%.
- **Vector code needs independent chains, not just lanes.** ChaCha20 on four blocks (`SIMD4<UInt32>`) was
  four dependent quarter-round chains, the vector pipes half idle; eight blocks (`SIMD8<UInt32>`, all 32
  registers) +36%. For scalar multiply chains, fewer wide products: Poly1305 in radix 2^64 (4 + 2
  products per block) against 2^44 (9), +12%.
- **`a.f(g(&a))` reads `a` before `g` mutates it:** `Array(wire.prefix(send(into: &wire)))` copied the old,
  empty array (the inout access made a copy-on-write). Take the result into a local first.
- **Never pass a `throws(E)` closure to an untyped generic `rethrows` API** (`Array.withUnsafeMutableBytes`,
  `withUnsafeBytes`, `func f<R>(_: () throws -> R) rethrows -> R`). Swift 6.4.2 throws the wrong error,
  silently: the closure throws an `any Error` box as an `E`, and the caller catches the box's address as the
  enum (a `BytesError` printed `()`). With a `Void` or tuple result the compiler crashes instead.
  `~/Scratch/swift-bugs/25-…`, swiftlang/swift#90291. Use Bytes' `array.withOutputRawSpan { … }` (or
  `array.mutableSpan.withUnsafeMutableBytes`), which are generic over the error type and keep it. A span of
  a class instance's stored array lasts only for that property access: bind the array to a local `let` (a
  retain, no copy). A `~Copyable` stored property (a `ByteBuffer`) can't be bound that way: pass it `inout`
  to a function that does the work.
- **Move bytes with Bytes' helpers, not `withUnsafeMutableBytes` and `copyMemory`** (`Bytes/Sources/Bytes/
  Buffers.swift`): `OutputRawSpan.append(copying:)` and `withFreeCapacity { span, written in … }` (a
  `MutableRawSpan` over the free capacity, counting what the closure reports); `copyBytes(from:toByteOffset:)`
  and `copyBytes(within:toByteOffset:)` (overlapping) on `MutableRawSpan` and `MutableSpan<UInt8>`;
  `[UInt8].withOutputRawSpan(overwritingFrom:)`; and `ByteBuffer`, a buffer filled at the end
  (`fill`, or `receive` from an async source such as a socket) and drained from the front, compacting below a
  threshold. Moving the codecs, TLS records, `Pipeline`, and SocketStream onto them changed no instruction
  count beyond the reported resolution (`Bytes/Benchmarks/RESULTS.md`, 2026-11-16). Two traps: `[1, 2, 3].span.bytes` is an `[Int]`'s 24 bytes (type the literal `[UInt8]`), and a sync
  method and an `async` overload of one name taking a `throws(E)` closure are ambiguous from async code
  (hence `fill` and `receive`).
- **Nonce reuse hides in `reset()`.** A TLS sealer reset with the same keys must not restart its record
  sequence; the opener gets `reset(sequence:)` to replay records in tests and benchmarks.
- **`@inline(__always)` is a hint; `@inline(always)` is a guarantee.** The SIL inliner declined Brotli's
  `@inline(__always)` match search into the parse loop ("Not profitable to inline … cost = 785" in
  `Tools/remarks --passes sil-inliner`) once the loop grew, and LLVM then found it "too costly": quality 5
  ran 2–8% more instructions. `@inline(always)` (Swift 6.4) inlined it. After growing a hot loop, check its
  callees with `Tools/calls`.
- **Byte-only formats use `AlignedBytesReader` and `AlignedBytesWriter`.** These are `GenericBytesReader` and
  `GenericBytesWriter` in the `ByteAligned` mode: the same byte-level API, with a bit offset that's the constant
  0.
  - Measured: MQTT encode −6%, parse −1 to −3%, Base64 encode −2 to −8% on short inputs, DEFLATE decode −2
    to −4%.
  - Builders: `[UInt8](alignedByteCapacity:)`, `withAlignedBytesWriter`. `String(utf8Capacity:)` gives an aligned
    writer.
  - Keep `BytesReader`/`BytesWriter` for sub-byte fields in the stream. `Byte` and its bit fields work in both.
  - Out-of-line helpers on the cursors belong in the `BitAddressable`-constrained extensions, so they aren't
    generic. Check new ones with `Tools/calls … --callee metadata`.
  - One exception measured: QOI's run-filling decoder ran 54% more instructions with the aligned reader. LLVM
    nested its fill loops inside the pixel loop, so it keeps `BytesReader`. Measure when switching a hot loop.
- **A safe helper's one check per call can cost more than the work in a hot loop.** Measure before moving
  a hot loop onto a checked core API.
  - Bytes' `commonPrefixLength` checks its bounds once per call (one sign test of the bounds ORed together,
    about eight instructions). Called per match candidate, it cost the compressors 3–18%.
  - `BitWriter.flush()`'s capacity check cost the encoders 0.2–1.7%.
  - Both have `@unsafe` forms (`unsafeCommonPrefixLength`, `unsafeFlush`) for loops that prove their bounds
    once per block. The safety argument goes in a comment at the call site.
  - Fixing `BitBuffer`'s bit order at compile time saved nothing: the run-time `let` folds wherever the buffer
    is inlined. (Brotli's decoder ran 1–2 K more instructions on 1.6 KB streams with `BitBuffer.rewind(to:)`
    than with a new buffer, inlined or not, cause unknown: it keeps the new buffer.)
- **Hot decode loops keep their state in locals.** Brotli's bit buffer passed `inout` to a function that
  wasn't inlined lived in memory for the whole loop (and its bit order was tested at run time): copy it into
  a local, pass values, and store it back after. Masked indices (`types & 0xFF`, `context & 0x3F`) let span
  checks fold; Huffman tables built from only the used symbols, sorted, cost in proportion to them. Together
  20–42% faster across the corpus, 1.6 KB streams the most.
- **Truncated input looks like data.** A bit reader's zeros past the end can decode as a valid but wrong
  symbol (DEFLATE's code-length code 16 at index 0, "repeat the previous length", threw `invalidValue` when
  the input ended 8 bytes into a dynamic header): when a decoder rejects a value, check `isOverrun` and ask
  for more input instead. Find such bugs by recording a stream's calls and replaying them cut at every point.
- **Copies stop at the data's end, not the buffer's.** A parse whose lazy step reused `maxLength - 1` from
  the first position let a second delay's copy run a byte past `dataEnd`. Sequentially that read past the
  input (unchecked loads); in a parallel chunk, the next chunk's bytes matched and the stream decoded a byte
  long. Random test inputs never triggered it: build inputs that force the path (Bytes'
  `copiesStopAtChunkEnds`), and check parallel outputs with an independent decoder on real corpora.
- **Parallel compression: avoid rounds.** Rounds of one chunk per lane with a barrier after each lost
  0.1–0.7 ms per round to thread wake-ups and cores still at low clocks, plus the serial copy of the round's
  output. One `concurrentPerform` (or task group) per call, workers taking the next chunk, output handed to
  slots by swapping buffers and copied in order by whichever worker finishes the next chunk
  (`ChunkScheduler`): 8–22% faster with two rounds, 22–41% with four, even with one (interleaved; across
  benchmark runs these rows swing 10–30%, so A/B parallel changes in one process). Keep chunks a whole
  number per lane (39 chunks on 24 lanes take as long as 48). State reused across calls must be reset per call: a slot still naming chunk 0 from the last call
  looked ready. Task groups beat `concurrentPerform` by up to 10% here; async APIs that take `inout`
  storage are `nonisolated(nonsending)` (otherwise `@concurrent`, and callers must send `self`).
- **Extracting files: the kernel is the limit** (`NativeZipArchive/Benchmarks/RESULTS.md`, step15). Small files
  cost `open`, `write`, `close`, and metadata syscalls (decoding was 2%), and APFS creation contends beyond about 8
  writers (12 or more got slower, 24 took 3x as long). Writes to one file are serialized: parallel `pwrite`s of a
  1 GB file gained nothing, and parallel copies into a shared mapping of it were 1.4–3x slower. What helped:
  overlapping serial planning with the writes (a queue filled while planning, −17% on 20,000 files), one pool
  for several archives (8 archives of one large entry each, 4.6x), working in cache-sized pieces (checksum
  8 MB, then write it: −29% for 1 GB stored), and setting times and mode in one `fsetattrlist`. Put benchmark
  output in a `*.noindex` directory: Spotlight indexing what you extract loads the machine.
- **Payload structs with resilient fields (`Date?`) copy through value witnesses** (`swift_cvw_initWithCopyImpl`
  in profiles): jobs that are queued, sorted, and handed between tasks are cheaper as final classes.

API design and code generation (the 2026-11-17 proposals pass; numbers in `Bytes/Benchmarks/RESULTS.md`):

- **Check a new API's codegen from another module** (a throwaway package depending on the dev tree, `@inline(never)`
  probes beside hand-written equivalents, `objdump`): LLVM merges identical functions, which is the proof. Named bit
  fields (`flags[ConnectFlags.userName]`) matched hand shifts; a `BitPattern` literal folded to its two masks only
  with `@inline(__always)` on both initializers (otherwise a run-time parse per call).
- **The standard library's `ByteOrder.==` is a call** (derived `==` of any other module's `@frozen` enum is:
  `~/Scratch/swift-bugs/26`). `switch` over the order instead; a byte-ordered writer went 71 → 53 instructions.
- **Store a checked value unmasked.** An enum field setter with `assert` + mask cost MQTT's PUBLISH encoding 0.8%;
  `precondition(raw <= mask)` then an unmasked store folds both away when the enum's raw values are visible.
- **An empty default closure isn't free, and compilers disagree about it.** MQTT's properties validation with a
  `visit: { _ in }` parameter cost 2% under Xcode's compiler; forced inline, it gained 1% there and cost SocketStream
  (PR toolchain) 10%. Give the plain path its own body; force-inline only the variant that needs it.
- **Generated code needs `@inline(__always)`.** `@BinaryRecord`'s `init(parsing:)` stayed a call (the 17-field record
  returned through memory): 297 K against 199 K instructions for the same hand-written parser. Forced inline, equal.
- **Moving code to another module can cost instructions even when it's inlined.** `HuffmanCodeBuilder` in Bytes
  instead of BytesCompression: +2 K per 1.6 KB Brotli stream with `@inlinable`, `@inline(__always)`, and
  `@inline(always)` alike; it went back. Benchmark every move.
- **Stitch scalar work into vector loops.** Poly1305 (integer multiplies) between ChaCha20's eight-block rounds
  (vector, all 32 registers): sealing 1 MB −40% time, 1.52 → 2.50 GB/s, instructions barely changed.
- **A cheaper mask isn't a cheaper loop.** `ByteMatches.nibbleMask` (one `shrn`, from plain Swift) beats `bitmask`
  for finding the first lane, but Brotli's tag filter walking 4-bit slots ran 2.7% more instructions than with the
  one-bit gather.
- **Spans can't be captured through two closures** ("lifetime-dependent variable escapes its scope"), nor borrowed
  from a property while another property is mutated in a closure: pass both as parameters to a static function
  (TLS sealer's `ByteBuffer`s).
- **Overloads and literals:** a generic `write(_: some FixedWidthInteger, as:)` beside `write(_: T.Integer, as: T)`
  takes integer literals (they default to `Int`) unless `@_disfavoredOverload`; a bare `writer.write(7)` is ambiguous
  between `Byte`, `UInt8`, and `Int8`, which is right: state the width.
- **`.macro` targets need `import CompilerPluginSupport`**; without it the manifest fails as a type-check timeout
  (`~/Scratch/swift-bugs/27`).
- **Cross-toolchain checks:** SocketStream builds with a PR toolchain whose inliner differs; a change that helps MQTT
  under Xcode's compiler can hurt SocketStream. Track both.

The 2026-11-18 pass (Zstandard, native crypto and TLS, parallel sealing; numbers in each package's RESULTS.md):

- **A count check is one unsigned compare.** `UInt(bitPattern: n) <= UInt(bitPattern: remaining)` rejects negative and
  too-large counts at once; `n >= 0 && n <= remaining` cost BinaryParsingComparison's LZ4 2% in instructions.
- **`InlineArray` passed `borrowing` can be copied at every subscript.** The zstd decoder's FSE spreading loop copied a
  512-byte table (`memmove`) per access: 16,000 copies per 4 KB frame, 22% of its time. Hot tables go in raw memory
  the decoder owns (a workspace), indexed through a pointer, with the safety argument in a comment.
- **An out-of-line `mutating` call makes its struct live in memory for the whole loop.** The zstd bit reader's reload
  (and Brotli's bit buffer before it) kept the reader spilled while one cold path called a `mutating` method on it:
  make such helpers static functions that take values and return them.
- **Lane-mask tricks need varied test data.** `ByteMatches.nibbleMask` shifted bytes right before narrowing, so odd
  lanes reported bit 3: bytes like `0x70` matched. Tests with one filler byte never showed it. Spread the high bit
  first (an arithmetic shift by 7), and test with varied bytes around each match.
- **`~Copyable` members made on first use:** an `Optional`. `x!.mutate()` works in place, but `x!.property` in a read
  consumes the optional ("cannot partially consume 'self'"): borrow with `switch x { case let .some(y): … }`
  (SE-0432). NativeZip's staging buffer and streaming decoder are made this way, on the first encrypted entry. A
  benchmark that makes its decoder inside the measured closure then counts that first-use setup as per-iteration
  mallocs.
- **Records are independent once their sequence numbers are fixed.** TLS sealing in parallel: full records have known
  sizes, so each lane seals its records straight into their places in the output (`concurrentPerform` over pointers
  in an `@unchecked Sendable` wrapper). 3.6–3.8x on 4 lanes, 5.8–6.9x on 8. Opening isn't symmetric: a record's
  plaintext length (inner type and padding at its end) is known only after decrypting it.
- **Register pressure beats instruction choice:** ChaCha20's rotate by 8 as a `tbl` byte shuffle (one instruction
  instead of shift and insert) took the eight-block double round from 264 to 323 instructions, from spills of the
  shuffle's table. Reverted.
- **A shuffle-heavy SSE kernel isn't a NEON kernel.** Base64's reshuffling encoder (one-register `tbl`s, then shifts
  and masks per 32-bit lane) was 75 instructions per block against the deinterleaving kernel's 32, which LLVM folds
  into `st2` stores. Per-lane shift amounts on `SIMD8<UInt16>` compiled to split halves (143); lane picks across two
  vectors became byte inserts unless written as a contiguous run (one `ext`).
- **Bytes' crypto types share CryptoKit's names** (`SHA256`, `HMAC`, `HKDF`, `AES`, `HashFunction`): qualify with the
  module in code importing both (`CryptoKit.AES.GCM`).
- **Don't take `.span` of a throwing call's result directly**: at `-Onone` the LLVM verifier crashed
  (`~/Scratch/swift-bugs/28`). Bind the result to a local first.
- **Test reads that end exactly at the data's end.** `read(_:asciiDigits:)`'s two-load path lacked a `count > 8`
  condition, so short reads near the end loaded 8 bytes past the data (unchecked loads); every test with bytes after
  the field passed. Every fast path with wide loads gets a test whose input ends where the field does.
- **`pointwiseMin`/`pointwiseMax` on `SIMD16<UInt8>` are calls** (Swift 6.4): use a vector comparison
  (`a .<= b`, one `cmhs`/`cmhi`) and `replacing(with:where:)`.
- **ASCII tags fold:** `Byte4(ascii: "IHDR")` (`@inline(__always)`, a `StaticString` read in a loop over the
  constant width) compiles to the same code as the hex literal; LLVM merged the two benchmark functions. A
  `static let` of it would still be lazily initialized.

Apple Encrypted Archives and the LZMA decoder (NativeAEA/RESULTS.md, Bytes' RESULTS.md 2026-11-18; format in
NativeAEA/FORMAT.md):

- **APFS file creation peaks at about 4 threads** (46,000 small files a second) and slows beyond 8, in one directory
  or many: the contention is in the file system. Keep CPU work (compression) outside a semaphore around the calls;
  extracting Xcode went 11.4 → 9.0 s with 24 writers and at most 6 in the kernel (Apple's `aa extract`, 32 threads
  in the kernel: 47 s, 347 s of system time). Instrument the stages (time per call kind, summed) before guessing.
- **Creating entries relative to an open parent wasn't faster** than paths from the destination (3% slower: the
  name cache makes lookups cheap, and opening each directory is one more call). Deep paths cost ~20% in a
  microbenchmark but not in the pipeline.
- **Setting an extended attribute checks the file's mode, not the descriptor's**: `fsetxattr` on a file created
  0444 fails with `EACCES` even with the descriptor open for writing. Create owner-writable, `fchmod` at the end.
- **APFS compression (`decmpfs`) is three calls after `open`:** the resource fork (`fsetxattr("com.apple.ResourceFork",
  position)`), `com.apple.decmpfs` (16-byte header, data inline when small), `fchflags(UF_COMPRESSED)`. Chunks are
  64 KiB, 0xFF + raw bytes when they don't compress. `clonefile` keeps all of it but was slower than creating (23,000
  a second on 4 threads, one source).
- **A pool of slots that jobs hold until they finish waits on the queue's latency**, not the work's: 4 large-file
  slots made the walker wait 6.0 s of 9.0 s, because a piece's job sat behind 16,000 queued small files. Size such
  pools for the queue.
- **Overwrite consumed input in place** to compress pieces in parallel without memory: each 64 KiB chunk's output
  moves back over the piece's own consumed bytes while the output stays behind the unread input (it can grow by a
  byte per chunk), falling back to a buffer when it would catch up.
- **Shared mutable state the walker reads to decide reference handoffs is a leak**: a writer cleared a large file's
  fork type while the walker used it to decide whether to pass a buffer reference on; the reference leaked and
  `DispatchSemaphore` trapped at deinit (freed below its initial value). Keep the decider's own copy.
- **package-benchmark's malloc interposer traps on thread exit** (`count_free` → `_tlv_get_addr` → `calloc` in
  `_pthread_tsd_cleanup`): benchmarks that start threads can't count mallocs. Count them in single-threaded ones.
- **`aea` rejects some PEM keys**: a P-256 private scalar with a leading zero byte (1 in 256) DER-encodes in 31
  bytes, and `aea` fails with "Error parsing PEM blob". CryptoKit's PKCS #8 PEM isn't accepted at all; use
  `openssl ecparam -genkey` and check the octet string is 32 bytes.
- **`aea decrypt -o -` doesn't write to stdout**: it writes a file named `-`.
- **LZMA decoding (the decoder agent):** LLVM turned a range coder's `one ? 1 : 0` into a branch that mispredicted
  half the literal bits; the bit from the borrow (`(UInt64(code) &- UInt64(bound)) >> 63`) cut cycles 20%. Load both
  children's probabilities (adjacent `UInt16`s, one 32-bit load) while the parent bit decodes (−14%). `x < 1 << 24`
  compiles to `lsr`+`cmp`; a threshold in a register is one `cmp` (−5%). The normalization branch predicts well:
  every branchless form was 2–10% slower. CRC-64 by `pmull` folding: 24–41 GB/s against a table's 2.2.
- **Destructive shell sequences:** `perl … > new && diff …; cp new file` copied an empty file over a source file when
  the script failed to compile (the `;` ran `cp` anyway), and the new package wasn't in git yet. Chain every step
  with `&&`, or use Edit.

Apple's formats, curves, and running five agents at once (2026-11-18; NativeAEA/RESULTS.md, Bytes' RESULTS-*.md):

- **CommonCrypto's CTR mode (`kCCModeOptionCTR_BE`) counts only the block's last 8 bytes**, wrapping with no carry
  into the first 8 (checked from an IV at 2⁶⁴ − 1). Apple Encrypted Archives use it: `AES.Counter(bigEndian64BitCounterIn:)`.
  The difference from a 128-bit counter shows only when the low word wraps, so test IVs about to wrap.
- **Undocumented Apple codecs can be read from libcompression**: `ipsw dyld extract` pulls the dylib from the shared
  cache; its local symbols (`_rav_decode_buffer`, `RavGetLitLamContext(unsigned char)::lut`) name the functions and
  tables. Transcribe to a C reference first and check it decodes Compression's output exactly; then write Swift.
- **Generic standard-library SIMD conversions are inlined only while they have few callers**: `SIMD8<UInt16>(
  truncatingIfNeeded:)` in LZBITMAP's decoder was inlined until the LZFSE and LZVN encoders, in the same module,
  used SIMD conversions too; then it stayed a call (6 per 16 groups), and decoding ran 12–15% more instructions
  with no change to the decoder's file. Found by bisecting the module's files in a copy of the package. In hot
  code, widen with a byte zip (lane picks of two vectors: `zip1`/`zip2`) and narrow with Bytes' `_lowBytes`
  (`Builtin.trunc`: one `xtn`, or `shrn` after a shift); picking even bytes to narrow was merged by LLVM into
  lane moves. Recheck hot loops with `Tools/calls --callee 'specialized SIMD'` after adding code to their module.
- **An encoder's output can depend on the room it's given**: Compression's LZBITMAP (and Bytes' copy of it) needs
  working room beyond its result, so a chunk given exactly its own size can fail, or come out larger, where 64 KiB
  of room compresses it. `aa extract` gives every APFS chunk 64 KiB; giving each its own size left 1,604 of Xcode's
  files stored differently. Compare stored bytes, not just storage forms, and find such rules from the data (fit
  the rule against every file: NativeAEA/RESULTS.md, 2026-11-19).
- **Probe a decoder with crafted streams, and expect two rule sets**: Compression's LZBITMAP decoder has a fast loop
  and a careful one for a chunk's end, which disagree on corrupt input. Its buffer API also stops once the output
  is full and returns that count, so it "decodes" streams missing their end; 0 is its only failure.
- **Vectorize independent work, not a dependent chain**: Salsa20/8 as `SIMD4<UInt32>` diagonals was clean
  `vector128` code and 3x slower than scalar (each step 4 dependent vector instructions). And SLP turns a scalar
  kernel's 16 loads or stores into vector ops with lane moves: load and store `UInt64` pairs (−6%); check with
  `Tools/loops --forbid mov.s,fmov,ins,umov`.
- **Write out fixed-count loops of multi-limb arithmetic**: LLVM left Montgomery's row loop rolled with the
  accumulator in memory (P-384 −13% time written out). A field multiply that wins alone (wide integers, special
  reductions) can lose inlined into point formulas: measure the whole operation. Constant-time ladders: Jacobian
  formulas with the special cases selected by masks beat complete formulas (−28%).
- **Spans and Swift Testing**: `#expect`, `#require`, and `Optional.map` don't take `~Escapable` values (compute a
  `Bool` first, use `if let`). `array[i].span` is a temporary's (bind `let x = array[i]`), and so is the span of a `let`
  assigned inside a `switch` ("lifetime-dependent value escapes its scope"): bind it to another constant.
- **Typed throws**: `do { } catch` around a typed-throws call boxes the error (`swift_allocError`) unless written
  `do throws(E)`.
- **C references in SwiftPM build at `-Os` without `NDEBUG`**: their asserts stay in (lzfse's cost 18%): set
  `cSettings: [.define("NDEBUG")]` before comparing. Release tests with `@testable` need `-Xswiftc -enable-testing`;
  elliptic-curve code in debug is hundreds of times slower.
- **`Darwin.membership` is an explicit submodule** (`mbr_identifier_to_uuid` for ACL qualifiers): `import
  Darwin.membership`, no shim needed.
- **`aa archive` hangs on a FIFO in the tree** (it opens it to read). `pbz` blocks have no checksums: damage to a
  stored block isn't detected (by `aa` either); test corruption on a compressed block.
- **The first URLSession request to a new domain waits on a security prompt** (the program hangs, curl doesn't): tell
  the user to look for it, as for the attach prompt.
- **zsh's `status` is read-only**: `local status=$?` aborts a zsh script; name it `rc`.
- **Agent worktrees stay locked by the parent session** (`git worktree remove` refuses: "locked working tree, lock
  reason: claude agent"): once the agent has finished and its files are merged, `git worktree unlock` then remove.
  Before removing old worktrees, compare each changed file's added lines with main, not just whole files.
- **Five agents benchmarking under one lock**: their timed runs queue (an hour of a three-hour task was waiting), and
  each run still meets the others' builds. Judge by instruction counts during the work; time on an idle machine after.

Xcode's `.xip`, bzip2, RSA, and Compression's LZVN (2026-11-19; NativeAEA/XIP-REPORT.md, FORMAT.md §4, Bytes'
RESULTS-bzip2.md, RESULTS-rsa.md, RESULTS-lz4-lzfse.md):

- **Find an Apple tool's storage rule from every file, in its units.** `xip --expand` compresses files over 16 KiB
  that aren't PNGs when the fork saves a fifth of the **4 KiB blocks** (`ceil(fork/4096)×5 ≤ ceil(size/4096)×4`); by
  bytes, ratios from 0.787 to 0.864 went both ways. `aa extract`'s rule is in bytes (93%). The room differs too: `xip`
  gives each LZVN chunk only its own size (LZVN needs 1–10 bytes beyond its stream, so 42 short last chunks were stored
  raw where 64 KiB of room compressed them), `aa` gives every LZBITMAP chunk 64 KiB.
- **`fchflags(UF_COMPRESSED)` sets the file's modification time to now**: set times after the flags (and locking flags
  after the times).
- **Compression's LZVN (0x900) is the open lzvn reference with another hash**: `((v & 0xFFFFFF) × 0x9E3779B1) >> 18`
  against the reference's `× 4161 >> 12`, and every room check the reference's (1–10 bytes beyond the stream; under 8
  bytes of input it returns 0). Compression's LZFSE differs from the reference in one constant (pending literals pushed
  past 945, not 2,520). Read the library's code (`ipsw dyld extract`, Binary Ninja) and check a patched C reference on
  every corpus file and capacity before writing Swift; Bytes' encoders now match both byte for byte.
- **A `.xip`'s signature is RSA PKCS #1 v1.5 of the TOC checksum itself** (the 20 SHA-1 bytes as the `DigestInfo`
  digest), chained to the 2006 Apple Root CA; check the certificates' validity at the TOC's `creation-time`. This
  macOS's `xar` no longer signs (`--sign` is gone): tests write their XAR archives in Swift and sign with `openssl
  pkeyutl`.
- **APFS spends ~280 µs of kernel CPU on every `linkat`** (first or later link, plain or compressed file, measured
  alone): Xcode's 26,000 later names cost 2.6 s on 6 threads, and links made during the writes slowed the writers by
  as much. Hard links are the xip's largest serial phase.
- **bzip2 decoding**: a nested function that captures the decoder's state is heap-boxed (7 allocations a block); hot
  loops with any call spill their registers; loading the bit buffer's refill one symbol ahead takes a load off each
  symbol's critical path; the inverse BWT (a dependent load per byte) runs 24 interleaved walks of ~1 KB segments.
- **A program blocked in `open` at 0% CPU on a file in ~/Downloads (or Desktop, Documents; why example files are in
  `~/Scratch` now) waits on a privacy
  prompt**, whatever binary opens it, tests included (a `.enabled(if:)` trait that lists the folder blocks too): tell
  the user to look for it. A `gtimeout`ed `swift test` can leave `swiftpm-testing-helper` behind: find it by its
  `--test-bundle-path` and kill it by PID.

Threads to structured concurrency (2026-11-19; NativeAEA/RESULTS.md, ARCHITECTURE.md §9):

- **Mark internal async functions `nonisolated(nonsending)`**, and the public entry points `@concurrent`: without it
  NativeAEA's walker made about 4 `swift_task_switch` checks per entry (21,374 → 1,481 for 1,001 files).
- **Waits are `Mutex` state plus a continuation, taken synchronously under the lock when nothing has to wait**; check
  again under the lock inside the continuation's body, remove a waiter under the lock, resume it outside. A
  `CheckedContinuation` allocates per wait: `UnsafeContinuation` in release builds for waits that happen per file.
- **One `withTaskCancellationHandler` per operation** that closes the pools and queues (every waiter wakes) beats a
  handler per await; workers still drain queued jobs after a failure, to release what the jobs hold.
- **CPU-bound tasks filling the cooperative pool didn't starve the others** (32 decoders, one walker, 24 writers):
  yields and priorities measured no different. Measure before adding an executor.
- **An async main task runs at priority 21**, not user-initiated: start the work in a child task with a priority.
- **`sending` closures can't append to a caller's local** that's read afterwards; a plain closure parameter can.
- **A buffer sized for the largest item stays resident at that size**: `madvise(MADV_FREE_REUSABLE)` past a floor
  after each use, `MADV_FREE_REUSE` before (32 read buffers of 16 MiB: −170 to −230 MB, no system time).
- **`stat`'s block counts of freshly extracted `decmpfs` files vary run to run**: compare contents and sizes.
- **`xargs -P` interleaves its children's output lines**: hash files serially, or one output file per process.

Bytes cleanup (2026-11-19, later; Bytes' RESULTS.md):

- **Offload synchronous work with a `@concurrent` function taking a non-escaping `@Sendable` closure**
  (`BytesAsync`'s `perform(_:)`, `ByteTransform.concurrently()`): off any actor, no thread switch from a nonisolated
  task, nothing allocated. DEFLATE level 1 in 64 KiB calls: same time as in place, a Dispatch queue hop +7%. A generic
  `@concurrent` function called on a type parameter warns that its conformance "may be isolated" under
  `InferIsolatedConformances`, even with `SendableMetatype`; the closure form doesn't. APIs that borrow caller storage
  (`inout`, spans) stay `nonisolated(nonsending)` and move only their workers off the caller.
- **Values mutated by `@inline(__always)` nested functions can stay in memory behind `swift_beginAccess`**: SHA-512's
  state and schedule as captured variables cost 12 access checks a block (638 instructions); as structs with mutating
  methods, 519, then 489. Prefer structs with mutating methods to nested functions over captured `var`s in kernels.
- **A table that becomes a compile-time constant can make LLVM rematerialize its address in the loop**: CRC-32's
  literal tables (no more `swift_once`) cost 64-byte checksums +10.7% until the inner update was `@inline(never)`
  (the address opaque again). Measure after removing a lazy global, not just `Tools/calls`.
- **Literal `static let` arrays and `InlineArray`s are statically initialized** (no `swift_once`): only computed
  initializers (`(0..<n).map`, closures) are lazy. Check with `nm` (no once token) or `Tools/calls --callee swift_once`.
- **A stitched decrypt-and-authenticate must restore the buffer on a bad tag** (re-encrypt with the same counter):
  AES-GCM open in one pass, −12% instructions, TLS open −14%; every forged case leaves the buffer byte-identical.

A second machine (M1 Max, 2026-11-19; `Writeups/M1-Max-vs-M3-Ultra.md`, `Bytes/OPTIMIZATION.md`, Part III "The second machine"):

- **One core is the clock** (1.31x time for 1.25x clock, over 773 benchmarks with identical instruction counts); more
  cores change parallel work by the lane count. Keep Instructions beside times when comparing machines: they show whether
  the same code ran.
- **After moving to new hardware, re-run something unchanged on an idle machine first.** Spotlight/`mediaanalysisd` were
  indexing the new files during the first runs; one memory-bound row read 2.2x slow. A standalone probe (a C copy of the
  kernel, or a plain Swift loop over the API) that disagrees with a benchmark row is the signal. `TestData/` has a
  `.metadata_never_index` marker for this.
- **`udot` (FEAT_DotProd) was the unused instruction:** Adler-32's two sums are dot products against ones and against
  64…1, 1.9x faster than the 16-bit Swift SIMD version (57 GB/s, within 10% of libdeflate). Swift SIMD has no widening dot
  product; a `static inline` C wrapper (`bytes_crc_udot`), loop in Swift.
- **Efficiency cores:** queue-fed workers gain from them (the DEFLATE encoder 3–9%, the decoder 7–12% once it took
  segments from a queue); statically split work loses (the decoder with one even segment per lane: 20–35%, because one
  segment lands on a slow core). "Lanes = performance cores" suits only the second kind.
- **Measure a core's instructions rather than assuming** (`Tools/cpu-probe insn`): on the M1 Max, `tbl` with 3 or 4 table
  registers is 2–3 vector slots and `tbx` one per register (4: 8 cycles of latency); 1–2 `tbl` registers are full speed;
  `udot`, `pmull`, `aese` run 4 a cycle at 3 cycles of latency, and `aese`+`aesmc` fuse (3 cycles a round).
- **A throughput probe needs latency × rate independent chains:** the first M1 Max probe had 8, so every 3-cycle
  instruction read 2.7 a cycle instead of 4, and two conclusions built on it were wrong (Adler-32 "bound by `udot`",
  AES-CTR "90% of the bound": it is at the bound of its eight round chains, and 12 blocks could reach about 1.5x).
  Calibrate cycles with a dependent scalar `add` chain (1 cycle); a vector `add` reading 2.00 cycles confirms it.
- **Change a parallel splitter, sweep the corpus:** the decoder's four segments per lane rejected its speculation on one
  stream (mozilla level 1) at 6 of 16 lane counts, sequentially 7x slower; the benchmarks' inputs never hit it. Check
  `lastSegmentCount` over every corpus file and lane count.
- **A throughput probe needs latency × width independent chains** (12 for a 3-cycle instruction on four pipes). The M1 Max
  probe used eight and read 8/3 = 2.7 a cycle for `udot`, `pmull`, `aese`: its own limit (the M3 Ultra reads 2.7 with 8
  chains, 4 with 16; 2026-11-20). Measure with `Tools/probe` (below), which takes the best of 8, 16, and 24.
- **Break a latency bound with chains that nothing carries, not more accumulators.** Adler-32's `udot` loop was bound at
  3 cycles per 64 B by `udot`'s latency *and* by its `prefix` adds (one per byte-sum accumulator a block); 16
  accumulators doubled the adds (+3%). Computing each 128-byte step's byte sum as one `udot` chain from zero, folded in
  with two carried adds, took 19 vector operations per 128 B and 1 MB from 76 to 101 GB/s. Count every vector operation
  (adds, `movi`) against the pipes, not just the expensive instruction, and check both bounds before adding accumulators.
- **Compare machines with `Tools/probe`, not one-off probes** (`Tools/probes/README.md`): `Tools/probe all` on each, then
  `Tools/probe compare`. It takes the best of 8, 16, and 24 chains (on the M3 Ultra, three-source instructions like
  `eor3` fall to 2.8 a cycle at 24) and calibrates the clock next to each instruction (a P cluster's clock moved
  3.6–4.06 GHz under load; a cold first calibration made the first M3 probe's latencies 3% low).
- **Compare instruction counts only between rows measured with the same metrics.** Rows that also counted mallocs (the
  interposer active) read about 700 fewer instructions per sample on 1–100 K-instruction rows than the same rows without
  it (`m3-1120` against `speed-after`, system libraries included).
- **Speculation must fail locally.** `ParallelDeflateDecoder` decoded the whole stream sequentially if any of its
  `4 × lanes` split points was a false `00 00 FF FF` (one inside Huffman-coded data, not just stored data): mozilla level
  1 was 14x slower at 11, 22, 25, and 28–32 lanes, and the benchmarks ran only 8 and 24. Now the segment before a bad
  split decodes on past it, and a failed region is decoded again in place after the real history. Sweep every lane count
  from 1 to the machine's cores in tests (`Tools/probe bytes segments`), not just the counts the benchmarks use.
- **Profile the calling thread of a parallel call, not just the workers.** The parallel decoder's serial copy of the
  joined output was a quarter of its time, and a serial split scan another 8%. Hand each finished piece to the output
  from whichever worker makes it ready, and make each worker's setup depend only on its own piece so workers do it.

The Disk package and the Nunarchiver app (2026-11-20; `Disk/RESULTS.md`, `NativeAEA/RESULTS.md`):

- **A GUI app working with no frontmost window runs at background QoS** (App Nap): every thread at priority 4 in `ps -M -p PID`,
  efficiency cores only. Xcode's xip in Nunarchiver was past 83 s against the CLI's 11. Start the work at `.userInitiated`
  and hold `ProcessInfo.beginActivity([.userInitiated, .idleSystemSleepDisabled], …)` while it runs.
- **Xcode 27's autogenerated scheme can instrument Release builds for coverage, packages included**: the LZVN encoder's
  loop went from 188 to 585 instructions (an `adrp`/`ldr`/`add`/`str` per counter), and 24 threads sharing the counters
  made Xcode's expansion over 3 minutes. `-enableCodeCoverage NO` applies only to `test`: commit a shared scheme with
  coverage off, and check built apps with `otool -l APP | grep __llvm_prf_cnts`. Compare an app's hot loop with the CLI's
  (`Tools/loops` on both binaries) when the app is slower.
- **`fsetattrlist` sets times, mode, and flags in one call and keeps the times** even with `UF_COMPRESSED`, where `fchflags`
  resets them; with flags alone it costs 62 K more kernel instructions than `fchflags`.
- **TCA26's `onMount(id:)` remounts the whole feature it modifies, children included**: put it on an empty `Update` of its
  own, or every child's effect restarts when the id changes.
- **`NSApp.terminate` called on the main queue** (from a task or a dispatch source) hangs if it can return
  `.terminateLater`: its nested run loop doesn't drain the main queue. Request it with `RunLoop.main.perform(inModes:)`.
- zsh has a `log` builtin: use `/usr/bin/log`.

One implementation each (2026-11-21; `Disk/RESULTS.md`, `NativeAEA/RESULTS.md`, `NativeZipArchive/Benchmarks/RESULTS.md`):

- **Shared concurrency primitives go in BytesAsync, and moving them there cost nothing** when every type is `@frozen`
  or has `@usableFromInline` state and every method is `@inlinable`: Disk's, NativeAEA's, and NativeZip's waits
  (`Continuation`, `WaiterQueue`, limiter, index pool, latch, queue, handoff) and `RawStorage` moved with identical
  mallocs, calls, and (within the rows' spread) instructions. Check a move with `Tools/calls --target PKG TARGET '.*'
  --callee 'MODULE|swift_getGenericMetadata' --sum`: specialized copies in the client are fine, calls into the other
  module's unspecialized generics aren't. `#if DEBUG` in inlinable code is decided when the *defining* module is built.
- **Before writing a helper, look for it one module down**: two packages had the same 160 lines of waiting code, and
  three had a class around `Atomic<Int>`. But one user and a format's own layout (NativeAEA's segment pool, Disk's
  job-and-path queue) stay where they are.
- **A sync method and an `async` one of the same name are ambiguous across modules too** when the closure names its
  error type: Disk can't call BytesAsync's `RawSpan.withLentBytes` (Bytes has the sync one) and keeps a two-line helper.
- **package-benchmark prints "Build complete!" for its tool, then builds the benchmark targets.** An edit made after
  that line broke a queued baseline's build. Don't touch a package (or what it depends on) until its first result
  table prints; queue every "before" baseline before the first edit.
- **Build new Bytes API with SocketStream's PR toolchain as well**: it warned ("result of 'offer' cannot be returned":
  region isolation) about enums returned from `Mutex.withLock` that Xcode's compiler accepted. Make such types `Sendable`.
- **A directory isn't always made by its own entry.** Disk's planner assumed a listed directory had the mode its
  `mkdir` gave it; one made earlier as a file's parent (an archive listing it after its contents), or already there,
  kept 0755. And parents an archive never lists (ZIP) got no quarantine. Test archives that list directories last, and
  not at all.
- **A quarantine belongs in the writers, not in a walk afterwards**: one `fsetxattr` on the open file (and one
  `setxattr` per directory in the passes) against a second traversal on one thread, which doubled an 8,060-entry
  archive's time in the app.

Matching Archive Utility (2026-11-21, later; `Disk/RESULTS.md`, `NativeZipArchive/Benchmarks/RESULTS.md`,
`NativeAEA/RESULTS.md`):

- **Compare with the real tool, item by item, before believing what it "reportedly" does.** Archive Utility
  (`open -W -a "Archive Utility" FILE`, each archive copied into a directory of its own under `~/Scratch`, the
  copy given a `com.apple.quarantine`) against Nunarchiver, both trees through one manifest (type, mode, flags,
  owner, size, mtime, link target, SHA-256, every extended attribute, the ACL's text), then `diff`. Times the
  expansion itself set are normalized (anything later than the corpus is NOW). What it showed that nobody had
  written down: the folder for several items is 0700 unless the archive has an entry for its root (`aa archive -d`:
  then that entry's mode and time); AppleDouble entries are merged (beside the item or under `__MACOSX`), ACLs
  included (`com.apple.acl.text`); symbolic links get their archived times; ZIP names are written decomposed
  (`fileSystemRepresentation`), Apple Archive names as stored; everything is quarantined, the folder too, except a
  `.xip`'s contents.
- **A tool's output can be an accident of its pass order: decide whether to copy it.** Archive Utility restores a
  `.xip`'s directory times before it writes the files, so only directories holding nothing but directories keep
  them (1,877 of Xcode's 30,068, found by classifying every directory by what it holds). Nunarchiver restores all
  of them and says so.
- **A GUI tool's failures are dialogs on the user's screen.** Archive Utility's alerts block `open -W` until someone
  clicks OK, and nothing in a session without Screen Recording or Accessibility can see or dismiss them. Run it
  only on archives it should accept (ordinary `ditto`/`zip`/`aa` output, Xcode's archives), with a timeout, add one
  feature at a time to a known-good archive, and never bisect a failing one by running it again. Its reason is in
  the log: `log show --last 2m --predicate 'process == "ArchiveService"'` ("Main key derivation failed", "Couldn't
  read the header of the entry: … Code=79"). Don't run two `open -W` of one app at once: the second waits on the
  first's dialog.
- **Foundation's directory enumerators leave `._` files out** (`FileManager.enumerator(atPath:)`): a test that lists
  an extracted tree to show no AppleDouble file is left passes whatever is there. List with `readdir`.
- **macOS's `unzip` and `ditto -x -k` merge AppleDouble entries too**, so a raw copy of one for a test comes from an
  extraction with merging off (NativeZip's `mergesAppleDouble = false`) or `python3 -m zipfile -e`.
- **A directory can't have a resource fork**: `fsetxattr("com.apple.ResourceFork")` on one fails with `EPERM`
  (`ditto` warns and goes on; Archive Utility refuses the archive). Leave it out rather than fail the entry.
- **Throughput in a polled UI is the counter's gain over the last n ticks of the poll timer**: no clock reads, no
  Foundation `Progress`; a sample every tick even when nothing changed, so a stalled rate falls to zero. State
  what the bytes are (here: file contents written to disk, before APFS compression).
- **A progress bar by bytes is full before the work is** (a `.xip`'s hard links and directory passes: 3.4 s of
  Xcode's 10.2, measured from the app's polls). A finishing state from `fraction >= 1` left the bar indeterminate for
  that third; now each entry counts as 64 KiB beside the bytes (`ExpansionProgress.fraction(entries:of:bytes:of:)`),
  so the bar moves through the links too, and the app keeps the largest fraction read (totals go from an estimate
  to exact mid-run).
- **`aea encrypt -profile 5` refuses short passwords** ("Password is too short"): tests use a long one.
- **`open` as an instance method hides Darwin's `open`** inside the type: write `Darwin.open`.

Reviewing the Nunarchiver app (2026-11-21, review pass; the app's sources and tests):

- **The pfw-tca26 skill's interface is older than the TCA26 the app builds with** (module `ComposableArchitecture`,
  `forEach(\.x)` and `scope(\.x)` without `action:`, `.transformEnvironment` test traits, `store.run`, `store.trigger`).
  Read the checkout: `Nunarchiver/.build/DerivedData-Debug/SourcePackages/checkouts/TCA26` (DocC articles under
  `Sources/ComposableArchitecture/Documentation.docc/Articles`, behaviour in `Tests/` and `Examples/`).
- **A parent commands a child with a `@Trigger` in the child's state, not by sending the child's actions**
  (TCA26's Triggers article): `for expansion in store.expansions { try expansion.cancel() }` in a store task. In a
  `TestStoreActor` the trigger's state changes are asserted in the `send` that caused it; no extra `receive`.
- **A `TestStoreActor` applies an effect's actions as they arrive, before `receive` asserts them**: after anything
  that can end a child (a cancel), `store.send(to: \.children[0], …)` or reading `$0.state.children[0]` races the
  removal and traps (index out of range, taking the whole test process with it). Test a row's own guards on a store
  of the child feature alone.
- **Is the bar really determinate? Ask AppKit**: SwiftUI's linear `ProgressView` is an `NSProgressIndicator` on
  macOS, so a temporary timer walking the window's views can log `isIndeterminate` and `doubleValue` (and count
  `body` evaluations) to the system log, read with `/usr/bin/log stream --level debug --predicate 'subsystem == …'`
  started before the app. `cacheDisplay(in:to:)` does not capture SwiftUI's text. `open --env NAME=VALUE` passes
  the switch; remove the code afterwards.
- **`open -a APP symlink` hands the app the link's target**: an expansion "next to the archive" went to `~/Scratch`.
  Give the app a hard link (same volume) or a copy in the scratch directory.
- **Automatic grammar agreement (`^[\(n) item](inflect: true)`) isn't applied by `String(localized:)`** for an app
  with no String Catalog: the markup came out as written (in tests, and it's what VoiceOver's value would read).
  Use two keys ("1 item", "%lld items") until a catalog carries plural variations.
- **Rates: `Int64.formatted(.byteCount(style: .file).locale(…))` plus a localized "\(amount)/s"**. Foundation has no
  data-rate format style (macOS 27 SDK: `Measurement` has no information-per-time dimension). Other locales put a
  no-break space (U+00A0, or U+202F in French) before the unit: tests spell it out.
- **`#expect(try localFunction(…) == x)` inside a closure failed to compile** ("errors thrown from here are not
  handled", Swift Testing in Xcode 27.2) where `#expect(try Data(contentsOf:) == x)` beside it compiled: bind the
  result with `let` first.
- **A user-facing string held in a `String` property is never localized** (`Text(string)` is verbatim): computed
  titles and captions are `LocalizedStringResource`s (on the feature's state, so tests read them with
  `String(localized:)`), AppKit's take `String(localized:)`.
- **Split a row by what the poll timer changes**: with the icon lookup in the same `body` as the polled progress,
  `NSWorkspace.icon(forFile:)` ran 4 times a second per row; as views of their own (icon by URL; progress by store),
  the counts over a 10 s expansion were icon 1, row 1, list 1, progress 39.
- **An xcodebuild failure can hide behind `| tail`**: `./build.sh … | tail -3` exits 0 with a stale app in place
  (the measurement then ran the old binary). Read build.sh's first line (`exit N`) before using the product.
- **`SWIFT_STRICT_MEMORY_SAFETY = YES` in an app target with TCA26's macros** produced no warnings of the macros'
  own: only the app's two C calls needed `unsafe`. It's on for Nunarchiver, so the "every `unsafe` has its reason"
  rule is checked there too.

Every zip method in Swift (2026-11-22, M1 Max; NativeZipArchive's RESULTS.md step17, Bytes' RESULTS.md):

- **A whole-output decoder becomes a streaming one by its window, not its loop.** LZMA and xz kept their decode loops
  and got a flat window that slides the dictionary to its front (within 0.1–0.8% of the whole decode); bzip2 decodes a
  block into its workspace and makes only the run expansion resumable (+0.2–0.5%). Split input costs nothing when the
  careful path near the input's end decodes each symbol first without effect, then for real.
- **A per-symbol bounds check can become an output limit computed per round**: when each iteration reads at most k
  bits per byte it writes, a limit on output guarantees the input. DEFLATE's decode loop: −8 to −11% instructions,
  with named `BitField` reads of table entries instead of range subscripts worth 3–5% of that.
- **Instructions aren't the cost for range coders**: Bytes' xz runs 7.6% more instructions than Compression's liblzma
  and finishes 29% sooner. The trade was memory: a window of the dictionary plus as much room (16 MiB for 8 MiB),
  against a circular one.
- **A quarantined terminal app makes every file this session creates carry `com.apple.provenance`** (iTerm installed
  by Homebrew Cask: its descendants are provenance-tracked, and the kernel owns the attribute, so `xattr -d` and
  `setxattr` silently do nothing). Tests comparing extended attributes must ignore it; `ditto -c` then writes a `._NAME`
  for every symbolic link, and `aa extract` run from such a session writes a fresh `com.apple.quarantine` instead of the
  archive's. A `launchctl submit` job runs untracked when a clean reference is needed.
- **Checked helpers in a loop whose bounds are proven per round cost 12–20 instructions a match.** DEFLATE's fast loop
  on locals with unchecked refills, stores, and its own match copy (libdeflate's design, the round's proof in comments):
  −36 to −39% instructions, below libdeflate's, but only −4 to −7% cycles (the loop is latency- and
  misprediction-bound). Weigh instruction wins against `Tools/counters`.
- **Codegen traps met there:** an `@inline(__always)` throwing helper taking an `inout MutableRawSpan` stayed a call in
  a large loop (`@inline(always)` inlined it: −10% → −35%); an `inout` span's base address is reloaded before every
  store (rebind it to a local); constants the loop keeps in registers are rematerialized after every call in it (a
  division's magic number: use shifts, keep rare cases' constants off the loop); table entries with flags beat a kind
  field (one `tbnz` per decision); a failed vector check should skip to the failing lane, not step a byte.
- **Fewer instructions can be slower for range coders:** LZMA's branchless matched-literal coder runs 1.14x liblzma's
  instructions on x-ray (mostly matched literals) and 20% fewer cycles. A cheaper index formula: −1.7% instructions,
  +0.8% cycles; not kept.
- **Bytes' `Pipeline` didn't fit decrypt-then-decode** (ZipDecoder's encrypted entries): +2–3% instructions, because the
  second stage is driven only through `transform` (DEFLATE loses its decode-into-the-output-buffers path), an encrypted
  LZMA header must be decrypted before the format is known, and an in-place stage can only follow another stage. The
  hand-written pump stays.
- **Read-ahead (`F_RDADVISE`) cut cold-cache read stalls ~60% and changed no wall time** (decoding dominates). For a cold
  cache per run, read an APFS clone (`cp -c`): its page cache is its own.
- **`#expect` can't read a `~Copyable` value's property**: bind it to a `let` first. `URL.resolvingSymlinksInPath()`
  drops `/private` from `/private/var/…`: use `realpath`. Nunarchiver's `project.xcproj` has trailing commas (jq can't
  parse it): edit it by hand. Without the team's certificate, `./build.sh … CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=` builds and tests ad hoc.
- **Baseline names are shared with the repository**: `ab-old-*`/`ab-new-*` are tracked in several packages, and
  `baseline update` overwrites them silently. Name a session's baselines after the work (`zipnative-old-1`), and check
  `git status` for modified `results.json` files after a run.
- **Attribute every allocation with LLDB when Instruments' callers are truncated.** Breakpoints on `swift_slowAlloc`,
  `malloc`, `malloc_type_malloc`, `calloc`, `realloc` with `bt 14; continue`, on the `-debuggable` release binary, then
  group stops by the first frame in your own code (drop a `malloc` stop whose frame #1 is `swift_slowAlloc`: the same
  allocation). 7,000 stops took 40 s. A condition (`-c '$x0 > 1000000'`) lists the large ones. NativeAEA/RESULTS.md,
  2026-11-22 evening. Why Instruments wasn't enough: its stacks are full (4–85 frames), but the `<Call stack limit
  reached>` rows are allocations made before it attached (all at time 0, one placeholder frame), and the only
  per-allocation table `xctrace export` gives (`Allocations List`) holds live allocations only: anything freed, such as a
  per-segment box, never appears there, only in the Statistics counts. `discardEventsForFreedMemory` is already false.
- **Malloc stack logging is a run-time switch, and its full mode changes what it measures.** `MallocStackLogging=1` is
  lite mode now (live allocations only, like `leaks --atExit`). `MallocStackLoggingNoCompact=1` (full) records every
  event with its stack, and `malloc_history PID -allEvents` prints them while the process lives (stop it at `exit`
  under LLDB, then run `malloc_history` from LLDB's `script`): every allocation of a 6 s extraction in 8 s. But in full
  mode libobjc gives every autorelease pool push a fresh 4 KiB page, and Swift Concurrency pushes one per job run on
  Darwin: 42,148 page allocations that a normal run doesn't make (LLDB without stack logging: 44,695 pushes, 31 pages,
  no `malloc_zone_memalign`; Instruments: 2). Use full mode for stacks; count with breakpoints or Instruments.
- **A local `var` pointer assigned in branches and borrowed by spans was heap-boxed**: `var stored:
  UnsafeRawBufferPointer` in `SegmentStream.decode`, one 32-byte `swift_allocObject` per segment (find the size and the
  call with `disassemble`). Constants, each set once on every path (`let x: T; if … { x = … } else { x = … }`), need no
  box. `Tools/calls … --callee swift_allocObject` on hot functions catches it statically.
- **A nearly full volume inflates kernel-heavy rows.** At 98% full, every 32 MB extraction read +5% instructions (kernel
  allocation) and a parallel row ran 3–5x slower, which looked like a regression of the change under test; an
  interleaved control showed it in both trees, and freeing 20 GB removed it. Check `df` before believing a file-system
  row, and remove scratch trees (copies of the repository with `.build`s are 2–5 GB each) when they're merged.

## Tests

- **Two sets.** `swift test` (debug) runs the fast set; `BULK_TESTS=1 swift test -c release -Xswiftc -enable-testing`
  adds the bulk sweeps (`--filter BulkTests` for only those). Default runs (2026-11-19): Bytes ~40 s (was 429),
  NativeZipArchive ~14 s (71), NativeAEA ~13 s (23), SocketStream ~2.5 s (9).
- **Where a new expensive test goes:** large inputs, corpora, every capacity/size/vector, thousands of mutations go in a
  `@Suite(.bulk) struct XxxBulkTests` (the trait is Bytes' `BytesTesting` product, which every package uses) sharing
  a static helper with the fast test.
- **Shared helpers are Bytes' support products**, not copies: `BytesTestSupport` (no Swift Testing, so benchmarks and
  sources can use it: `SplitMix64(seed:)`, `SampleBytes`, `Lazy`, `TestData.file(set:name:)`, `Corpus.root`,
  `TemporaryDirectory`, `ExternalTool.run`, `hex`), `BytesTesting` (`.bulk`, `runsBulkTests`), and
  `BytesReferenceCodecs` (zlib's and Compression's buffer APIs as references: `Zlib`, `AppleCompression`); for extracted
  trees, Disk's `DiskTestSupport` (`readTree` with `readdir`, so `._` files show; `TreeParts` to choose what's read;
  extended attributes, ACL text, `decmpfs` helpers; `SystemAttributes.ignoredByDefault`, `com.apple.provenance`, left
  out of comparisons unless asked for). The fast form keeps every edge case: boundary sizes, block remainders, one vector of each Wycheproof
  (result, flags) class. Fast plus bulk must check everything.
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
- `baseline read --filter` is ignored (bench-table filters itself). JMH export requires the built-in
  throughput metric. Markdown units vary (K/M, μs/ms): bench-table normalizes.
- **A benchmark costs a few seconds at most, and one run is enough.** No 30-minute suites, no repeated runs unless
  asked for, and no waiting for a quiet machine to run them (2026-11-19):
  - package-benchmark starts the benchmark executable once to list the benchmarks and again for **each** benchmark,
    and every start runs the whole `benchmarks` closure (`--filter` and `list` too). That closure only registers:
    fixtures are made lazily in a benchmark's `setup:` (which runs only in that benchmark's process, unmeasured), and
    so are result checks (run the operation once there and check it: that's the warmup too). Base64's eager
    fixtures cost 3 s per start: 340 s a suite, 53 s lazy; Bytes' CompressionBenchmarks 20 s per start (RSA key
    generation, every codec's checks), 830 starts: 5.6 hours, 6.6 minutes lazy. No data-derived counts in names
    (they need the data in every process). Check registration stays in milliseconds: `time
    .build/release/TARGET --filter NOTHING`. The `Lazy` box and `register` helper in
    `Bytes/Benchmarks/CompressionBenchmarks/Fixtures.swift` are the pattern; slow or random fixtures (RSA keys,
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
`raw.githubusercontent.com` for single files. Reports follow the format in `~/Scratch/swift-bugs/` (a
summary, a minimal reproducer with `repro.sh` and expected output, analysis down to the pass, workarounds,
timing). `Tools/sil-trace` finds the pass; `-Xllvm -sil-disable-pass` confirms it.

## Cleanup

- Tool scratch directories are removed on exit; your own go in the scratchpad.
- No `*.opt.yaml`, `.ll`, `.sil` or `.o` files left in the workspace root (SwiftPM's working directory).
- `PROGRAM-debuggable` copies live next to the build products in `.build` (rebuilt or removed with it).
- Kill background processes you started (`xctrace`, drivers, servers); close Binary Ninja tabs you opened;
  close only the browser tabs you opened.
