# Making Swift fast for binary data: the techniques behind Bytes

Binary formats (network packets, archives, compressed streams, encrypted records) are a good test of a language's
performance story. The data is dense, the work per byte is small, and the program spends nearly all its time in a few
loops. This document explains how those loops were made fast in Swift: what the CPU does with them, what the Swift
compiler turns them into, which library APIs keep them cheap, and which techniques came out of measuring each change.
<!-- src: general framing; scope per BRIEF.md -->

**What Bytes is.** Bytes is a Swift package for parsing and writing binary data. At its core are reading and writing
cursors (`BytesReader`, `BytesWriter`) over borrowed memory, with fields from 1 bit to 16 bytes, named bit fields, and
macros that generate a format's parsers from a declaration. Around that core are modules for checksums, Base64,
compression (DEFLATE, zlib, gzip, Brotli, Zstandard, LZMA/xz, bzip2, and Apple's LZFSE family), cryptography (AES-GCM,
ChaCha20-Poly1305, the SHA family, P-256/P-384, RSA verification, TLS 1.3 records), async pipelines, and Foundation
conversions.
<!-- src: AGENTS.md "Repository" table, Bytes row; Bytes/OPTIMIZATION.md (old) intro, module list -->

**The projects built on it.** Each is its own Swift package and each exercises a different kind of workload:

| Project | What it does | What it stresses |
|---|---|---|
| MQTT | MQTT 5 packets: zero-copy frames, per-type parse and write | Small records, many fields, enum dispatch |
| NativeZipArchive | ZIP (stored, DEFLATE, Deflate64, bzip2, LZMA, xz, Zstandard, every one decoded by Bytes' streaming decoders; ZipCrypto and WinZip AES), `nunzip` | File-system limits, parallel extraction, DEFLATE |
| NativeAEA | Apple Encrypted Archives, Apple Archives, Xcode's `.xip` | Decode pipelines, crypto, APFS behavior |
| Disk | Writing extracted trees, shared by NativeAEA and NativeZipArchive: contained creation, staging and publishing as Archive Utility does, APFS compression, metadata in one call, progress | The file system's limits, matching an Apple tool item by item |
| Nunarchiver | A macOS app replacing Archive Utility for `.zip`, `.aea`, `.aar`, `.xip`, built on the three packages above | The app's own traps: background quality of service, coverage counters |
| SocketStream | MQTT over sockets, optionally compressed and encrypted | Concurrency, executors, buffers |
| BinaryParsingComparison | Bytes against swift-binary-parsing on the same formats | Honest comparison of two designs |
| HTTPBytes | HTTP/1.1, HTTP/2, and HTTP/3 framing, HPACK and QPACK, Structured Field Values, content codings | Branch-bound scanning of short lines, tables and hash chains, allocation gates, differential testing |

<!-- src: AGENTS.md "Repository" table, rows MQTT, SocketStream, NativeZipArchive, NativeAEA, Disk, Nunarchiver, BinaryParsingComparison -->
<!-- src: AGENTS.md "Repository" table, HTTPBytes row; HTTPBytes/WRITEUP.md "What's in the package" -->

**Headline results.** Every figure is on the machine described below, release builds, medians:

- Base64 encoding reaches 20.4 GB/s at 1 MB (21.5 in the earlier `d2-final` run, with the same instruction count), near
  a C kernel that uses `ld3` and `st4` (ARM's deinterleaving load and interleaving store, [Part I](#part-i-foundations))
  directly, which reached 23.1 GB/s in that earlier run.
  <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): row "Encode 1 MB: Bytes (BytesReader → BytesWriter)", 205,695 ns for 4 MiB, 2,799,615 instructions; Bytes/Benchmarks/RESULTS-base64.md "Encoding" table (M3 Ultra column, d2-final: 21.5 GB/s at 1 MB) and "The ceiling: a C kernel with ld3 and st4" (23.1 GB/s; same-design C 21.8) -->
- CRC-32 uses ARM's carry-less multiply and CRC instructions: 1 MB in 15.3 µs (69 GB/s; 77 GB/s on 32 MB in the probe)
  against zlib's 25.2 µs, and 2.3x zlib at 64 bytes.
  <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "CRC-32 1 MB: Bytes" 15,295 ns and ": zlib" 25,215 ns, "CRC-32 64 B (×16 K): Bytes" 108,479 ns and ": zlib" 248,959 ns (2.30x); Tools/probes/results/M3-Ultra-2026-11-20/checksums.tsv (32 MB: 77.0 GB/s) -->
- The Zstandard decoder is faster than libzstd on every Silesia input and level: 1.13–1.50x for one call, with 8–22%
  fewer instructions.
  <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "Zstd decode L1/L3/L19 {dickens, mozilla, samba, x-ray, xml}: Bytes" against ": libzstd" (time 1.127 x-ray L1 to 1.503 x-ray L19; instructions 0.782 x-ray L1 to 0.918) -->
- The Zstandard encoder, levels 1 to 4, makes libzstd's frames byte for byte (it was ported decision for decision, and libzstd's
  output was the test oracle), in −14% to +5.4% of libzstd's cycles on every one-call row, and with no allocations once its
  tables exist.
  <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-23, Zstandard encoding" (frames libzstd 1.5.7's byte for byte; cycles −14% to +5.4% of libzstd's on every one-call row; zero mallocs with a reused encoder); Bytes/Benchmarks/RESULTS-zstd-encoder.md "Targets" -->
- ChaCha20-Poly1305 seals 1 MB at 2.37 GB/s (Poly1305's work interleaved into ChaCha20's rounds, −40% time), 2.80x
  CryptoKit's `ChaChaPoly` in the `m3-final` run. AES-128-GCM seals 1 MB at 9.0 GB/s (CryptoKit, on the same run, 9.6).
  <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): rows "ChaCha20-Poly1305 seal 1 MB (x1): Bytes" 442,623 ns, ": CryptoKit" 1,241,087 ns; "AES-128-GCM seal 1 MB (x1): Bytes" 116,095 ns, ": CryptoKit" 108,991 ns; the −40% is the dated change from 1.52 → 2.50 GB/s (RESULTS.md line 762) -->
- TLS 1.3 records sealed on several cores: AES-128-GCM 6.4 / 20.8 / 35.9 GB/s on 1 / 4 / 8 lanes (parallel workers).
  <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): rows "TLS seal 4 MB AES-128-GCM (1 / 4 / 8 lanes): Bytes", 652,799 / 201,471 / 116,799 ns for 4 MiB -->
- Parsing MQTT PUBLISH packets as views of the input, not copies, is 8.6x faster on one core than conventional parsing
  into `[UInt8]` and `String`, and 18.6x on all cores.
  <!-- src: MQTT/Benchmarks/RESULTS.md 2026-11-19 "The views against the conventional code" (M3, d2-final's code: 8.6x one core, 18.6x all cores; supersedes the older 5.5x) -->
- HTTPBytes (HTTP framing in Swift, on the M1 Max) parses 401 real request heads in 35 µs: 2.6x picohttpparser and llhttp
  (92 and 89 µs) and level with cursed-http, a C parser built on the same design (38 µs). Its HPACK encoder is 16x NIOHPACK's
  (89 against 1,422 µs) and 2.7x cursed-http's, its QPACK encoder 7x ls-qpack's (and, since round 2, as small as
  ls-qpack's output: 53,137 bytes against 53,087 for 383 responses), it parses an HTTP date in 13 ns against Foundation's 457, and every per-message path
  allocates nothing.
  <!-- src: HTTPBytes/Benchmarks baseline final-1, "Time (wall clock)" rows "HTTP/1 request heads (401 requests, 232 KB)" (HTTPBytes 35, picohttpparser 92, llhttp 89, cursed-http 38), "HPACK encode (401 requests)" (HTTPBytes 89, cursed-http 244, NIOHPACK 1,422), "QPACK encode (401 requests, 4,096 table)" (107 against ls-qpack 751); ratios 92/35 = 2.6, 1,422/89 = 16, 244/89 = 2.7, 751/107 = 7.0; the zero-malloc gates: every `Allocations:` row of final-1 but Body_chunked_gzip (see Part III section 12) -->
  <!-- src: HTTPBytes/RESULTS.md "QPACK encoder: draining, Duplicate, names alone" (383 responses, 4,096 table, acknowledged at once: 53,137 B against ls-qpack's 53,087) and "round 2, dates and field values" (13 ns per date; Foundation 457 ns) -->

**How to read this document.** It is organized by concept rather than by chronology. Each technique follows the
same shape: the problem, why the CPU or compiler behaves that way, the technique, a small example, the measured effect,
and when not to use it. Terms are **bold** where they are defined and collected in the [Glossary](#glossary), an
appendix at the end.
Every number is followed by an HTML comment naming its source in the repository; the comments are invisible when the
Markdown is rendered. Assembly listings come from release builds of the library and from small probe programs, so they
can differ slightly from the current code.
<!-- src: BRIEF.md "Audience and voice"; Part I "A note on the listings" -->

[Part I](#part-i-foundations) builds the vocabulary: CPUs, SIMD, assembly, the Swift compiler, and measurement. [Part II](#part-ii-the-bytes-toolkit-bottom-up) walks through the
library's APIs from the bottom up. [Part III](#part-iii-techniques-by-problem) is organized by problem and technique, with examples from the codecs, the
crypto, and the consumer projects. [Part IV](#part-iv-concurrency-and-further-reading) covers Swift concurrency for performance, SocketStream's prototypes, known
compiler limitations, and further reading.

**The machine and the measurements.** Unless a section says otherwise, numbers come from an Apple M3 Ultra (24
performance and 8 efficiency cores, about 4.05 GHz maximum performance-core clock, 256 GB of LPDDR5-6400), macOS 27.2.1,
Xcode 27.3, Swift 6.4.2 and, for the later measurements (all of the 2026-11-20 ones), 6.4.4, release builds. A second machine, an Apple M1 Max
(8 performance and 2 efficiency cores, about 3.23 GHz), is used where a section says so; the work of 2026-11-22 (every
zip method decoded in Swift, the decoder cleanups, the second cleanup pass) was measured on it, in interleaved rounds on an otherwise idle machine, and its
rows are labeled "M1 Max" and are not comparable with the M3 Ultra's. The HTTPBytes case study (Part III, [section 12](#12-case-study-httpbytes)) was
measured entirely on the M1 Max, against references run on it in the same session, as was the Zstandard encoder's
comparison with libzstd (Part III, [section 8](#zstandard-encoding)).
<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md header (M1 Max);  HTTPBytes/RESULTS.md header (M1 Max, 8 performance and 2 efficiency cores, macOS 27.2, Swift 6.4 / Xcode 27.3); HTTPBytes/WRITEUP.md header -->
<!-- src: Bytes/Benchmarks/RESULTS.md "Streaming decoders for NativeZip (2026-11-22, M1 Max; …)", "Cleanups after the unification (2026-11-22, M1 Max; …)", "The second cleanup pass (2026-11-22, late, M1 Max; …)"; NativeZipArchive/Benchmarks/RESULTS.md step17 ("Measured on the M1 Max (not comparable with the M3 Ultra rows above)"); Bytes/Benchmarks/RESULTS.md lines 14-26 (machine table; "Xcode 27.3's Swift 6.4.4"); "2026-11-20, M3 Ultra" (macOS 27.2.1, Xcode 27.3, Swift 6.4.4); Tools/probes/results/M3-Ultra-2026-11-20/machine.tsv; Bytes/OPTIMIZATION.md (old) intro ("Swift 6.4.2 (Xcode 27.3; 6.4.4 for the 2026-11-17 and later measurements)") -->
Timings are medians from [package-benchmark](https://github.com/ordo-one/package-benchmark). "GB/s" is bytes processed
per second, and "x% faster" means x% less time unless it says "throughput". Where a number was taken while other jobs
loaded the machine, the text says so, and the claim rests on instruction counts, which do not depend on load.
<!-- src: Bytes/OPTIMIZATION.md (old) intro, paragraph "All numbers are from one machine"; AGENTS.md "Parallel agents" -->

## Contents

- [Part I. Foundations](#part-i-foundations)
  - [1. How a modern CPU runs your code](#1-how-a-modern-cpu-runs-your-code)
  - [2. SIMD and NEON](#2-simd-and-neon)
  - [3. Reading ARM64 assembly](#3-reading-arm64-assembly)
  - [4. How Swift becomes machine code](#4-how-swift-becomes-machine-code)
  - [5. Measuring](#5-measuring)
- [Part II. The Bytes toolkit, bottom-up](#part-ii-the-bytes-toolkit-bottom-up)
  - [1. Borrowed memory: spans and `InlineArray`](#1-borrowed-memory-spans-and-inlinearray)
  - [2. Byte-sized value types: `Bits`, `Byte2`…`Byte16`, byte order, ASCII tags](#2-byte-sized-value-types-bits-byte2byte16-byte-order-ascii-tags)
  - [3. Cursors: `BytesReader`, `BytesWriter`, and their modes](#3-cursors-bytesreader-byteswriter-and-their-modes)
  - [4. Bit-level fields: `BitFlag`, `BitField`, `BitPattern`](#4-bit-level-fields-bitflag-bitfield-bitpattern)
  - [5. Structure: sections, length prefixes, LEB128, records, text, dates](#5-structure-sections-length-prefixes-leb128-records-text-dates)
  - [6. Entropy coding building blocks: `BitBuffer`, `BitWriter`, `HuffmanTable`](#6-entropy-coding-building-blocks-bitbuffer-bitwriter-huffmantable)
  - [7. Scanning and shuffles: `ByteLanes`, `ByteMatches`, `GroupShuffle`, `CBytesNEON`](#7-scanning-and-shuffles-bytelanes-bytematches-groupshuffle-cbytesneon)
  - [8. Checksums: `CRC32`, `Adler32`, `CRC64`, `XXHash64`, `RunningChecksum`](#8-checksums-crc32-adler32-crc64-xxhash64-runningchecksum)
  - [9. Buffers and moving bytes](#9-buffers-and-moving-bytes)
  - [10. Pipelines: `ByteTransform`, `Pipeline`, and why composition costs nothing](#10-pipelines-bytetransform-pipeline-and-why-composition-costs-nothing)
  - [11. Async: `BytesAsync`](#11-async-bytesasync)
  - [12. Codec and crypto entry points](#12-codec-and-crypto-entry-points)
  - [13. `BytesBase64` and `BytesFoundation`](#13-bytesbase64-and-bytesfoundation)
  - [14. Macros: `@BitFields` and `@BinaryRecord`](#14-macros-bitfields-and-binaryrecord)
  - [15. Builds and traits: optimized, `Portable`, and no-C](#15-builds-and-traits-optimized-portable-and-no-c)
- [Part III. Techniques, by problem](#part-iii-techniques-by-problem)
  - [1. Keep hot state in registers](#1-keep-hot-state-in-registers)
  - [2. Remove the checks the compiler cannot prove away](#2-remove-the-checks-the-compiler-cannot-prove-away)
  - [3. Let LLVM vectorize your loops](#3-let-llvm-vectorize-your-loops)
  - [4. Write SIMD by hand, and reach instructions Swift cannot name](#4-write-simd-by-hand-and-reach-instructions-swift-cannot-name)
  - [5. Inlining and specialization](#5-inlining-and-specialization)
  - [6. Allocation-free code](#6-allocation-free-code)
  - [7. Branches and data-dependent work](#7-branches-and-data-dependent-work)
  - [8. Algorithms and data structures, codec by codec](#8-algorithms-and-data-structures-codec-by-codec)
  - [9. Crypto](#9-crypto)
  - [10. Parallelism](#10-parallelism)
  - [11. Techniques in the projects built on Bytes](#11-techniques-in-the-projects-built-on-bytes)
  - [12. Case study: HTTPBytes](#12-case-study-httpbytes)
  - [13. Measuring honestly](#13-measuring-honestly)
- [Part IV. Concurrency and further reading](#part-iv-concurrency-and-further-reading)
  - [1. Swift concurrency for performance, from first principles](#1-swift-concurrency-for-performance-from-first-principles)
  - [2. SocketStream: what the PR toolchain's I/O interfaces made possible](#2-socketstream-what-the-pr-toolchains-io-interfaces-made-possible)
  - [3. NativeAEA: from threads to structured concurrency](#3-nativeaea-from-threads-to-structured-concurrency)
  - [4. NativeZipArchive's worker pools and BytesAsync's offload](#4-nativeziparchives-worker-pools-and-bytesasyncs-offload)
  - [5. Limitations and compiler bugs met in concurrency and nearby](#5-limitations-and-compiler-bugs-met-in-concurrency-and-nearby)
  - [6. Further reading](#6-further-reading)
- [Glossary](#glossary)

## Part I. Foundations

Everything in Parts II–IV rests on a small number of ideas about hardware and compilers. This part introduces them with
real machine code taken from the repository's own build products, so that later sections can say "this loop became
`ld3`, `tbl`, `st4`" and mean something specific.

**A note on the listings.** The repository's records (the `RESULTS` files) describe machine code in prose but do not
contain disassembly. The listings here were made for this document in two ways, and each says which: by running
`objdump -d --no-show-raw-insn --symbolize-operands` (the flags AGENTS.md recommends) over object files that
`Tools/loops` had already built in the repository, or by compiling a tiny probe function with Xcode's `swiftc -O`
(Swift 6.4.4) or `clang -O2` and disassembling it. Probes are labeled as such; what they show is the compiler's output
for that probe, not a number from the benchmarks.
<!-- src: AGENTS.md "macOS tools: what's useful for this" (objdump flags); listings produced from Bytes/.build/agent-tools/*.o and scratchpad probes -->

### 1. How a modern CPU runs your code

A handful of hardware facts explain nearly every result in this document. This section covers them in the order a
program meets them: instructions, registers, memory, and branches.

#### 1.1 Instructions, pipelines, and issue width

A CPU executes **instructions**: small steps such as "add these two registers" or "load 8 bytes from this address". It
does not run them one at a time. A **pipeline** breaks each instruction into stages (fetch, decode, execute, write
back), so a new instruction can enter the first stage while earlier ones are in later stages. A **superscalar** core
goes further: it can start several instructions in the same **cycle** (one tick of the core's clock). An M3 performance
core can start about 8 instructions per cycle, provided they do not wait on each other, and a cycle at about 4 GHz is
about 0.25 ns.
<!-- src: Bytes/OPTIMIZATION.md (old) §1 "Instructions are cheap; waiting is expensive" (about 8 per cycle; cycle ~0.25 ns at ~4 GHz) -->

Inside the core, an instruction is split into smaller **micro-ops**, and some limits are counted in micro-ops rather than
instructions. A table-lookup instruction that reads four table registers costs more micro-ops than one that reads a
single register. On an M1 Max core, measured with `Tools/cpu-probe` (small test programs), a `tbl` ([section 2.4](#24-table-lookup-tbl-and-tbx)) with one or two table registers runs 4 per cycle, with
three registers 2 per cycle, with four registers 1.3 per cycle, and a four-register `tbx` about 0.95 per cycle.
<!-- src: Bytes/Benchmarks/RESULTS.md "What the cores can do: instruction and memory measurements (one P core)" table, re-measured 2026-11-21 (tbl 1-2 regs: 4/cycle; 3: 2.0; 4: 1.33; tbx 4: 0.92-0.97) -->

The core also runs instructions **out of order**: while an earlier instruction waits for its inputs, later ones that do
not depend on it can run, within a window of a few hundred instructions. This is what lets two independent chains of
work overlap.
<!-- src: Bytes/OPTIMIZATION.md (old) §13 glossary "Out-of-order execution" -->

#### 1.2 Latency, throughput, and dependency chains

Two numbers describe an instruction. Its **latency** is how many cycles pass before its result can be used. Its
**throughput** is how many of that instruction the core can start per cycle. On the M1 Max, a vector `add` (an add on
several values at once, [section 2](#2-simd-and-neon)) has 2 cycles of latency and a throughput of 4 per cycle: there are four 128-bit vector
pipes (the units that execute vector instructions). `udot`, `pmull`, and `aese` have 3 cycles of latency and also run 4
per cycle, and `aesmc` has 2 cycles at 4 per cycle; an `aese` followed by an `aesmc` on its result fuses into one
operation, 3 cycles for the pair. Sections [2.8](#28-dot-products-udot) and [2.9](#29-carry-less-multiply-crc-aes-and-sha-instructions) describe these instructions.
<!-- src: Bytes/Benchmarks/RESULTS.md "What the cores can do" table, re-measured 2026-11-21 with Tools/cpu-probe (clock 3.21 GHz from a scalar add chain; vector add 2.00 cycles, 4.0/cycle; udot, pmull, aese: 3 / 4; aesmc 2 / 4; aese+aesmc pair 3 / 3.9) -->

Measuring throughput takes enough independent chains to cover the latency: at 4 per cycle and 3 cycles of latency, 12
instructions must be in flight. The first probe used 8 chains, so every 3-cycle instruction read as 8 ÷ 3 = 2.7 per
cycle, and `fmla` (4 cycles) as 2; with 16 chains, both run 4 per cycle. The same eight-chain probe on an M3 Ultra also read 2.7, and 4 per cycle with 16.
<!-- src: Bytes/Benchmarks/RESULTS.md "What the cores can do" (re-measurement note: 8 chains → 2.7; 16 chains → 4); "2026-11-20, M3 Ultra" (8 and 16 chains) -->

A **dependency chain** is a sequence of instructions where each needs the previous one's result. A chain runs at the
speed of its links' latencies, however wide the core is. A loop's longest chain is its **critical path**. So two loops
with the same instruction count can differ 2x in time. The first field-parsing benchmark in this project folded every
field into `checksum = checksum * 31 + value`: 13 dependent multiplies per record, each waiting about 3 cycles for the
last. That chain took longer than the parsing itself, so four different parsers all measured 19 µs; a plain sum showed
the real differences, 10 to 17 µs.
<!-- src: Bytes/OPTIMIZATION.md (old) §1 and §2 ("measure the code, not the benchmark": 13 dependent multiplies, 19 µs, then 10 to 17 µs) -->

The remedy is **independent chains**: give the core several unrelated pieces of work at once. The ChaCha20 cipher written
with four blocks in flight was four dependent chains of quarter-rounds (the cipher's basic step), with the vector pipes
half idle; with eight blocks in flight, sealing 1 MB went from 1.00 to 1.34 GB/s.
<!-- src: Bytes/Benchmarks/RESULTS.md "ChaCha20-Poly1305 against CryptoKit" ("ChaCha20 eight blocks at a time ... 1.00 → 1.34"); Bytes/IMPROVEMENTS.md (same); AGENTS.md "Vector code needs independent chains" and old OPTIMIZATION.md §10 say +36%, which the recorded 1.00 → 1.34 GB/s doesn't match, so the GB/s are given -->

A loop is **compute-bound** when the core's arithmetic units limit it, and **memory-bound** when memory delivery does.
A loop that runs as fast from cache as from main memory is compute-bound.
<!-- src: Bytes/OPTIMIZATION.md (old) §13 glossary "Compute-bound, memory-bound" -->

#### 1.3 Registers and the register file

A **register** is a storage slot inside the core, and the only place instructions operate on directly. ARM64 has 31
general-purpose 64-bit registers and 32 vector registers of 128 bits. A value in a register costs nothing to access; a
value in memory must be loaded and stored around each use. A value must be in memory whenever its address is needed:
passing it `inout` or calling a non-inlined `mutating` method hands out a pointer, so it lives in memory for the whole
function, even on paths that never make the call. Moving a register's value to the stack is a **spill**. [Section 4](#4-how-swift-becomes-machine-code) and
Part III (["Keep hot state in registers"](#1-keep-hot-state-in-registers)) return to this constantly.
<!-- src: Bytes/OPTIMIZATION.md (old) §1 "Registers are free; memory costs" (31 general-purpose, 32 128-bit vector registers; spill) -->

Registers are scarce, so more work in a loop is not always free. ChaCha20's eight-block loop already uses all 32 vector
registers. Replacing the rotate-by-8 with a one-instruction `tbl` byte shuffle needed a register for the shuffle's
table, and the double round grew from 264 to 323 instructions in spills. That change was reverted.
<!-- src: AGENTS.md "Register pressure beats instruction choice" (264 to 323; reverted) -->

#### 1.4 The memory hierarchy, cache lines, and prefetching

Main memory is far away (100 ns or more), so the CPU keeps recently used data in small fast **caches**. Memory moves in
fixed-size blocks called **cache lines**: 128 bytes on Apple silicon (64 on most x86 chips). The first level (L1) is
about 3 cycles away; the second (L2) is shared by a cluster of cores. Measured on the M1 Max by pointer-chasing (each
load's address comes from the previous load), one pointer per 128-byte line, in random order:

| Working set | Load-to-use latency |
|---|---|
| 16–128 KB (L1 data) | 0.93 ns (3 cycles) |
| 256 KB–2 MB (L2) | 5.5 ns (17.6 cycles) |
| 4 / 8 MB | 6.3 / 9–10 ns |
| 16 / 32 MB | 40 / 70 ns (system-level cache, and page walks) |
| 128–512 MB (DRAM) | 122–125 ns |

<!-- src: Bytes/Benchmarks/RESULTS.md "What the cores can do" memory table (M1 Max, re-measured 2026-11-21 with Tools/cpu-probe latency) -->

The M3 Ultra's performance-core clusters have 16 MB of L2 shared by 6 cores; the M1 Max's have 12 MB.
<!-- src: Writeups/M1-Max-vs-M3-Ultra.md "The machines" table, "P-cluster L2" row -->

Sequential reads are fast because the hardware **prefetches**: it detects the pattern and loads lines before the
program asks. On the M3 Ultra one core reads about 78 GB/s from memory (133 GB/s from L1), and all cores together about
254 GB/s, reached at 16 threads and flat to 32; the 819 GB/s on the spec sheet is shared with the GPU and Neural Engine,
and the CPU clusters' links cap at about 31% of it. On the same chip the pointer chase reads 1.0 ns (4 cycles) in L1, 4.4–6.0
ns (18–24 cycles) in L2, 25–64 ns for 16–64 MB, and 127 ns in DRAM.
<!-- src: Tools/probes/results/M3-Ultra-2026-11-20/mem-threads.tsv (1 thread 78.5 GB/s, 16 threads 252.2, 24 254.8, 32 253.3 of 819 = 31%), mem-bandwidth.tsv (132.5 GB/s at 32 KB), mem-latency.tsv (L1 0.99–1.00 ns, 3.9–4.0 cycles; L2 4.41–6.03 ns, 17.9–24.4 cycles; 16–64 MB 24.6–64.1 ns; 256 MB 127.0 ns) -->

The M1 Max's table above is its own; the M3 Ultra's L1 is a cycle slower (4 cycles) at a faster clock.
On the M1 Max one core reads 60 GB/s, two already reach 112 GB/s, and all ten reach 125 GB/s, so beyond two, more cores
add little for a pure read. Stores are the same from one core (62 GB/s) and lower from all of them (about 104 GB/s).
<!-- src: Bytes/Benchmarks/RESULTS.md "What the cores can do" bandwidth paragraph (re-measured 2026-11-21, Tools/cpu-probe bandwidth) -->

Prefetching also explains a negative result. A software prefetch added to CRC-32 on the M1 Max did not help, because the
fold already ran at the memory rate; a prefetch distance of 8 KB hurt.
<!-- src: Writeups/M1-Max-vs-M3-Ultra.md; Bytes/OPTIMIZATION.md (old) §15 "What did not help" (software prefetch on CRC-32; a distance of 8 KB hurt) -->

#### 1.5 Branches, prediction, and mispredicts

A **branch** is an instruction that may change which instruction runs next (`if`, a loop's end, a bounds check). The
core cannot wait to find out which way it goes, so it predicts and runs ahead (**branch prediction**). A wrong guess
(a **mispredict**) throws away the work done on the wrong path, about 15 cycles. Predictable branches, such as a
bounds check that always passes, are nearly free; unpredictable ones are not.
<!-- src: Bytes/OPTIMIZATION.md (old) §1 "Branches are guesses" (~15 cycles) -->

The measured example is the LZMA range decoder, the arithmetic decoder that turns LZMA's compressed bits back into
symbols. LLVM (the optimizer and code generator inside the Swift compiler, [section 4.1](#41-the-pipeline-sil-then-llvm)) turned `one ? 1 : 0` (the next
decoded bit) into a branch that mispredicted about half the literal bits. Taking the bit from the arithmetic borrow
instead, `(UInt64(code) &- UInt64(bound)) >> 63`, removed the branch and cut cycles by 20%. The other branch in that
loop, the normalization test, predicts well: every branchless form of it was 2–10% slower. Whether arithmetic beats a
branch depends on how well the branch predicts.
<!-- src: AGENTS.md "LZMA decoding (the decoder agent)" (one ? 1 : 0; borrow bit cut cycles 20%; normalization branchless forms 2–10% slower) -->

#### 1.6 Stores, forwarding, and why memory-resident values are slow

A **store** writes a register to memory; a later **load** of the same address must get that value. A core can often pass
the stored value straight to the waiting load (**store-to-load forwarding**) without waiting for the cache, but a value
that is stored and immediately reloaded still adds latency to the chain that carries it. This is the cost behind
"keep the cursor in registers": a cursor (Bytes' reader or writer, which tracks a position in the data) kept in memory
does a store and a load around every field.
<!-- src: general background (definition); the cost claim is the register-vs-memory argument in Bytes/OPTIMIZATION.md (old) §1 and §5. No repository measurement isolates forwarding itself. -->

Stores are also where the two machines differ most. On the M1 Max, copies of short-distance back-references (a
decompressor copying bytes it wrote 1–7 positions earlier) are 1.6–1.85x slower than on the M3 at identical instruction counts, and plain stores are 1.85x slower (114
against 62 GB/s). Partial-width loads that cannot forward from recent stores are a guess at the cause, not a measurement.
<!-- src: Bytes/OPTIMIZATION.md (old) §15 "What did not help" (1.6–1.85x for the back-references); Bytes/Benchmarks/RESULTS.md "Not done" ("Raw SIMD stores run 62 GB/s on the M1 Max"; M1 Max side) and "2026-11-20, M3 Ultra" (baseline m3-final): BytesBenchmarks row "Write: Raw SIMD store (reference), in cache (4 MB)" 36,639 ns (114 GB/s; was 113 on the M3 in that note), 114/62 = 1.85; forwarding "consistent with ... but no probe was run"); Writeups/M1-Max-vs-M3-Ultra.md "Short copies" ("A guess ... not probed") -->

#### 1.7 Performance cores, efficiency cores, and clocks

Apple's chips have two kinds of cores. **Performance cores (P cores)** are fast and wide; **efficiency cores (E cores)**
are slower. The M3 Ultra has 24 P and 8 E cores; the M1 Max has 8 P and 2 E. Over 773 Bytes benchmarks whose instruction
counts are identical on both machines, one M1 Max core takes 1.31x as long as one M3 Ultra core; the clock ratio is 1.25
(4.05 against 3.23 GHz), so the M3 does about 4% more per clock. Work spread over many cores follows the core count
instead: the parallel codecs are 2.4x apart.
<!-- src: Writeups/M1-Max-vs-M3-Ultra.md "The short version" items 1-2 (1.31; clock 1.25; 4%; 2.4x for parallel codecs) -->

E cores change how work should be split. On the M1 Max, the two E cores added 3–9% to the parallel DEFLATE encoder,
whose workers take the next chunk from a queue. They cost the parallel decoder 20–35% while its segments were split
evenly across lanes (parallel workers; the word also names a SIMD register's slots, [section 2.1](#21-what-simd-is)); since the decoder
started taking segments from a queue too, they make it 7–12% faster. On the M3 Ultra every core (32 lanes) is now faster than the 24 performance cores alone. Part III (["Static splits and efficiency cores"](#static-splits-and-efficiency-cores)) has the measurements.
<!-- src: Bytes/Benchmarks/RESULTS.md "Parallel lanes: the efficiency cores help both codecs now" (re-run 2026-11-21); "2026-11-20, parallel DEFLATE: no fallback at any lane count; joins overlap decoding" (32 lanes up to 23% less time than 24); AGENTS.md "Efficiency cores" lesson and "Speculation must fail locally" -->

### 2. SIMD and NEON

#### 2.1 What SIMD is

**SIMD** (Single Instruction, Multiple Data) means one instruction operating on several values at once. A 128-bit
vector register holds 16 bytes, or 8 16-bit, 4 32-bit, or 2 64-bit values; each slot is a **lane**. One `add` of
two vectors of bytes adds 16 pairs. Arm's SIMD instruction set is **NEON**, with registers `v0`–`v31`. Swift's
`SIMD16<UInt8>` is one such register.
<!-- src: Bytes/OPTIMIZATION.md (old) §1 "SIMD does 16 things at once" -->

A vector instruction does the same thing in every lane, in lockstep. So anything that could differ per lane has no single
vector instruction: which way a branch goes, whether to leave the loop, which address to load from, what an opaque
function call does. This one rule explains every limit of the compiler's auto-vectorizer ([section 2.2](#22-what-vectorized-means-concretely)) in [Part III](#part-iii-techniques-by-problem).
<!-- src: Bytes/OPTIMIZATION.md (old) §1 "A vector instruction does the same thing in every lane, in lockstep" -->

#### 2.2 What "vectorized" means concretely

The compiler's **auto-vectorization** rewrites a loop to process several elements per iteration with SIMD instructions.
When it cannot, the loop runs one element at a time (**scalar** code), typically 3–10x slower, and nothing in the
program tells you. "Vectorized" has a precise, checkable meaning here: the hot loop's machine code uses 128-bit vector
registers (`q`/`v`), and the **vector instructions** show up when counted at run time.
<!-- src: Bytes/OPTIMIZATION.md (old) §1 "The compiler vectorizes for you, sometimes" (3–10x); AGENTS.md "Ground rules" ('vectorized' means Tools/loops says vector128 and counters show SIMD work) -->

Here is a loop from a probe: adding one byte buffer into another, `a[i] = a[i] &+ b[i]`, compiled with `swiftc -O`.
Two forms of the same loop are shown (a third is described below); the compiler wrote all of them and picks one at run
time.

```asm
; probe: addInPlace(_ a: UnsafeMutablePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ n: Int)   x0 = a, x1 = b, x2 = n
<L6>:                                   ; the vector loop: 64 bytes per iteration
  ldp   q0, q1, [x9, #-0x20]            ; load 32 bytes of a into v0, v1 (ldp = load a pair of registers)
  ldp   q2, q3, [x9]                    ; load the next 32 bytes of a into v2, v3
  ldp   q4, q5, [x10, #-0x20]           ; load 32 bytes of b into v4, v5
  ldp   q6, q7, [x10], #0x40            ; load the next 32 bytes of b; then x10 += 64 (post-increment)
  add.16b v0, v4, v0                    ; 16 byte-lane adds at once: v0 = v4 + v0
  add.16b v1, v5, v1                    ; the same for the next 16 bytes
  add.16b v2, v6, v2
  add.16b v3, v7, v3
  stp   q0, q1, [x9, #-0x20]            ; store 32 bytes back to a
  stp   q2, q3, [x9], #0x40             ; store the next 32 bytes; x9 += 64
  subs  x11, x11, #0x40                 ; remaining -= 64, and set the condition flags
  b.ne  <L6>                            ; if remaining != 0, go around again
...
<L2>:                                   ; the scalar loop: one byte per iteration
  ldrb  w11, [x8]                       ; load 1 byte of a into w11
  ldrb  w12, [x10], #1                  ; load 1 byte of b; x10 += 1
  add   w11, w12, w11                   ; 1 add
  strb  w11, [x8], #1                   ; store the byte; x8 += 1
  subs  x9, x9, #1                      ; count down
  b.ne  <L2>                            ; loop until the count reaches 0
```

<!-- src: scratchpad probe, `swiftc -O -c a.swift` (addInPlace), disassembled with xcrun objdump; shape of "vector128 verdict" per AGENTS.md Tools/loops -->

The vector loop does 64 byte-adds with 4 `add`s; the scalar loop does one byte per 6 instructions. The compiler also
emitted a check before the loop that the two buffers do not overlap (`cmp x0, x8 … b.hs`): a vector loop would give wrong
answers if `a` and `b` overlapped, so the compiler tests and falls back to the scalar copy when they might. The listing
omits an 8-byte loop (`add.8b`, the half-width form) that handles leftovers. None of this is in the source: the compiler
made all of it.
<!-- src: scratchpad probe addInPlace (alias checks cmp x0, x8 / cmp x1, x8; 8-byte epilogue add.8b) -->

**Lane-by-lane code is the failure mode.** `Tools/loops` labels a loop `+lane-moves` when single lanes are moved into
a vector one at a time (`mov.b v3[2], w12`, `ins`, `umov`): a shuffle built a lane at a time. [Part III](#part-iii-techniques-by-problem) covers how to
avoid it.
<!-- src: AGENTS.md "Tools/loops" description (verdicts vector128, vector64, scalar, +lane-moves, +calls) -->

#### 2.3 Structure loads and stores: `ld1`, `ld3`, `ld4`, `st3`, `st4`

`ld1` loads vectors from consecutive memory. The **structure** loads deinterleave as they load: `ld3` reads 48 bytes and
puts bytes 0, 3, 6, … in the first register, bytes 1, 4, 7, … in the second, and bytes 2, 5, 8, … in the third. `st4`
does the reverse for four registers, writing 64 bytes interleaved. These are ideal for formats with fixed-size groups:
Base64 reads 3-byte groups and writes 4-byte groups. The interleaving happens inside the load and store units, and Swift
code shaped as "groups in, groups out" gets these instructions from the vectorizer at no extra cost.
<!-- src: Bytes/OPTIMIZATION.md (old) §13 glossary "Structure loads and stores (ld3, st4)"; Bytes/Benchmarks/RESULTS-base64.md "The ceiling: a C kernel with ld3 and st4" -->

```asm
; probe (clang -O2): vld3q_u8 then vst4q_u8
ld3.16b { v0, v1, v2 }, [x0]            ; load 48 bytes; v0 = bytes 0,3,6.. v1 = bytes 1,4,7.. v2 = bytes 2,5,8..
mov.16b v3, v0                          ; (the probe's fourth register: a copy of v0)
st4.16b { v0, v1, v2, v3 }, [x1]        ; store 64 bytes: v0[0] v1[0] v2[0] v3[0] v0[1] v1[1] ...
```

<!-- src: scratchpad probe c.c `ldst`, `clang -O2 -march=armv8.4-a+crypto+sha3`, disassembled with xcrun objdump -->

The same instructions appear in real code. The portable Base64 encoder in `BytesBase64` is written as plain Swift loops
over typed spans of 3-byte and 4-byte groups (a span is a view of contiguous memory, in effect a pointer and a
count; Part II, ["Borrowed memory: spans and `InlineArray`"](#1-borrowed-memory-spans-and-inlinearray)), and LLVM turned it into this. The middle (the arithmetic
that maps each 6-bit value to a character) is elided with `…`.

```asm
<L8>:                                   ; loop: 16 groups (48 bytes in, 64 bytes out) per iteration
  ld3.16b { v19, v20, v21 }, [x12], #48 ; load 48 bytes, deinterleaved: v19 = first byte of each group, v20 = second, v21 = third; x12 += 48
  movi.16b v22, #0x66                   ; 0x66 = 128 - 26 in every lane...
  usra.16b v22, v19, #0x2               ; ...plus (v19 >> 2), "unsigned shift right and accumulate": the top bit is now set where the 6-bit value is >= 26
  ...                                   ; the same test for 52, 62, 63; compares (cmlt) and masks (and/add) pick each lane's offset: no branches, no table
  and.16b v19, v21, v18                 ; the fourth 6-bit value is (third byte & 0x3f)
  ...                                   ; its character, computed the same way
  st4.16b { v22, v23, v24, v25 }, [x13], #64 ; store the four character vectors interleaved: 64 bytes; x13 += 64
  subs  x14, x14, #0x10                 ; 16 fewer groups to go
  b.ne  <L8>                            ; loop while groups remain
```

<!-- src: objdump of Bytes/.build/agent-tools/BytesBase64.o (built 2026-11-19), the loop at offsets db0–ee8 (the portable encode(_:into:alphabet:) kernel); constants 0x66/0x4c/0x42/0x41 = 128 − 26/52/62/63 per RESULTS-base64.md "How it got here" ("Arithmetic masks, (v + 128 - k) >> 7 ... add + cmlt per test") -->

No source line says `ld3` or `st4`, and no table lookup is in the loop. The loop is 79 instructions per 48 bytes in the
object shown here (the record measured 77 with Swift 6.4.2), and they are mostly the arithmetic character mapping: an
`add` and a `cmlt` per range test where a single `cmhi` would do.
<!-- src: count of the listing's loop (0xdb0–0xee8, 79 instructions); Bytes/Benchmarks/RESULTS-base64.md "Toolchains" ("Portable groups (ld3, st4) | 77" with 6.4.2) and "How it got here" (add + cmlt per test where a single cmhi would do) -->

#### 2.4 Table lookup: `tbl` and `tbx`

`tbl` is a table lookup in registers. Each of 16 index lanes picks one byte out of a table of 1 to 4 vector registers
(up to 64 bytes); an out-of-range index gives 0. `tbx` is the same, but an out-of-range index leaves the destination
lane unchanged. It is a **gather** (loading each lane from a different, computed place) done inside registers; NEON has
no gather from memory. Bytes uses it to move the bytes of 3-, 5-, 6-, and 7-byte values into whole lanes, and
Base64 uses it to map 6-bit values to characters.
<!-- src: Bytes/OPTIMIZATION.md (old) §9 "tbl: table lookup"; §13 glossary "Gather" -->

```asm
; probe (clang -O2): vqtbl4q_u8(table, idx), a lookup in a 64-byte table held in v0..v3
tbl.16b v0, { v0, v1, v2, v3 }, v4      ; v0[i] = table[v4[i]] for each of the 16 lanes (0 if v4[i] >= 64)
```

<!-- src: scratchpad probe c.c `lookup` -->

The records count a `tbl` or `tbx` on the M3 as one micro-op per table register, so a 4-register lookup is much more
expensive than a 1-register one (on the M1 Max, measured, a 4-register `tbl` takes 3 vector slots and a 4-register `tbx`
4; [section 1.1](#11-instructions-pipelines-and-issue-width)). For this reason Base64's decoder went from a 128-byte table (a 64-byte `tbl` plus a 64-byte `tbx`) to an
80-byte window (64 + 16 bytes), and gained 11% (69 to 61 micro-ops per block).
<!-- src: AGENTS.md "On M3, NEON ld4/st3 didn't beat uzp and tbl shuffles" (each tbl/tbx costs one per table register; 128-byte table, tbl + tbx on 64 each, to an 80-byte window, 69 to 61 micro-ops, +11%); Bytes/Benchmarks/RESULTS.md "What the cores can do" (4-register tbl three slots, tbx four) -->

#### 2.5 Rearranging lanes: `zip`, `uzp`, `ext`

`zip1`/`zip2` interleave two vectors lane by lane (`a0 b0 a1 b1 …`), taking the low or high halves of the inputs.
`uzp1`/`uzp2` do the reverse (take the even or odd lanes of two vectors). `ext` extracts a 16-byte window from the
concatenation of two vectors at a given byte offset, which is a shift across registers.
<!-- src: Bytes/OPTIMIZATION.md (old) §9 "zip: interleave"; AGENTS.md "Portable byte shuffles" (ext) -->

```asm
; probes (clang -O2)
zip1.16b v0, v0, v1                     ; v0 = a0 b0 a1 b1 ... a7 b7   (low halves of a and b interleaved)
ext.16b  v0, v0, v1, #0x4               ; v0 = bytes 4..15 of a, then bytes 0..3 of b   (a window starting at byte 4)
uzp1.16b v0, v0, v1                     ; v0 = even bytes of a, then even bytes of b
```

<!-- src: scratchpad probes c.c `z1`, `ext4`, `uz` -->

These are cheap: on an M1 Max, `zip1`, `uzp1`, `ext`, and one- or two-register `tbl` all run 4 per cycle with 2 cycles of
latency. Replacing four 4-register `tbl`s with eight `zip`s made Base64 encoding 15% faster in the Swift encoder at
1 MB (18.9 → 21.7 GB/s) and 12% faster in the C kernels of the same design (19.5 → 21.8 GB/s). An earlier 2.3x cut in
instruction count had not helped, because the loop is bound by `tbl` throughput rather than by instruction count.
<!-- src: Bytes/Benchmarks/RESULTS.md "What the cores can do" table (zip1, uzp1, ext: 2 / 4); Bytes/Benchmarks/RESULTS-base64.md "How it got here" table (tbl-spans 18.9 → zip 21.7 GB/s at 1 MB) and "The ceiling" table (19.5 → 21.8, "gained 12%") -->

#### 2.6 Comparing and reducing: `cmeq`, `cmhs`, `umaxv`

`cmeq` compares lanes for equality and writes `0xFF` (all bits set) in lanes that match and `0` elsewhere, a **mask**.
`cmhs` is the same for "unsigned higher or same". To ask "did any lane match?", a **reduction** combines all lanes into one value:
`umaxv` takes the largest lane, so the result is non-zero exactly when some lane matched.
<!-- src: Bytes/OPTIMIZATION.md (old) §8 and §13 glossary ("Mask", "Reduction"); AGENTS.md "SIMD16<UInt8> on 6.4" (cmeq, cmhs, umaxv) -->

```asm
; probe (clang -O2): vmaxvq_u8(v)
umaxv.16b b0, v0                        ; b0 = the largest of the 16 byte lanes of v0
fmov    w0, s0                          ; move it to a general-purpose register
```

<!-- src: scratchpad probe c.c `maxv` -->

The Swift standard library's `any(_:)`, applied to the mask a `SIMD16<UInt8>` comparison returns, should be this, and
sometimes is: AGENTS.md records that on 6.4 `any()`/`all()` are inlined as `umaxv` in some loops and out-of-line calls
elsewhere. A probe shows the call:

```asm
; probe: func anyZero(_ v: SIMD16<UInt8>) -> Bool { any(v .== SIMD16(repeating: 0)) }   (Swift 6.4.4)
  stp   x29, x30, [sp, #-0x10]!         ; open a stack frame: this function makes a call
  mov   x29, sp                         ; set the frame pointer
  cmeq.16b v0, v0, #0                   ; one instruction: lanes equal to zero become 0xFF
  bl    <relocation: specialized SIMD.min()>   ; ...but any() became a CALL to a separate function (sminv, fmov, ret): the smallest lane as a signed byte
  ubfx  w0, w0, #7, #1                  ; bit 7 of that minimum: set if some lane was 0xFF (-1). That is the Bool
  ldp   x29, x30, [sp], #0x10           ; close the frame
  ret                                   ; return the Bool in w0
```

<!-- src: scratchpad probe a.swift `anyZero`; xcrun objdump -dr shows ARM64_RELOC_BRANCH26 to "specialized SIMD<>.min()", defined in the same object as sminv.16b b0, v0 / fmov w0, s0 / ret; AGENTS.md "SIMD16<UInt8> on 6.4" (any()/all() out-of-line calls elsewhere; fixed in 6.5-dev) -->

This is why Bytes' `ByteLanes` builds its tests from wrapping arithmetic and bitwise operations (Part II, ["Scanning and
shuffles: `ByteLanes`, `ByteMatches`, `GroupShuffle`, `CBytesNEON`"](#7-scanning-and-shuffles-bytelanes-bytematches-groupshuffle-cbytesneon)).
<!-- src: Bytes/OPTIMIZATION.md (old) §8 "Which SIMD16 operations are safe on Swift 6.4" -->

#### 2.7 Narrowing and widening: `shrn`, `xtn`

`xtn` ("extract narrow") keeps the low half of each lane: eight 16-bit lanes become eight bytes. `shrn` shifts right and
narrows in one instruction. A common use is to compress a comparison mask: shifting 16-bit lanes right by 4 and narrowing
gives four bits per byte lane, all 16 lanes packed into 64 bits, which is how `ByteMatches.nibbleMask` works (after first
spreading each lane's match bit through the lane).
<!-- src: AGENTS.md "Lane-mask tricks need varied test data" (ByteMatches.nibbleMask: one shrn; spread the high bit first); "Generic standard-library SIMD conversions..." (xtn, or shrn after a shift); Bytes/Sources/Bytes/ByteScan.swift nibbleMask (sshr, shrn, fmov, and; lane i in bit 4i + 3) -->

```asm
; probes (clang -O2)
xtn.8b  v0, v0                          ; 8 x 16-bit lanes -> 8 bytes (the low byte of each lane)
shrn.8b v0, v0, #0x4                    ; shift each 16-bit lane right by 4, then keep the low byte
```

<!-- src: scratchpad probes c.c `xt`, `shr` -->

#### 2.8 Dot products: `udot`

`udot` (the `FEAT_DotProd` feature, present on every Apple silicon Mac from the M1 on) multiplies groups of four bytes
from two vectors and adds each group's sum into a 32-bit lane: `acc[i] += a[4i]*b[4i] + a[4i+1]*b[4i+1] + …`.
Adler-32 needs exactly two sums, the sum of the bytes and the position-weighted sum, and they are a dot product against
all-ones and a dot product against `64, 63, …, 1`. Moving Adler-32 onto `udot` made it 1.9x faster on the M1 Max (29.6 to
56.9 GB/s at 1 MB, in a probe), within 10% of libdeflate's 62 GB/s, and on the M3 Ultra it cut the instructions for 1 MB from
555 K to 271 K (−51%). A later change arranged the sums so that no `udot` waits on the previous step's, and the M3 Ultra
now runs Adler-32 at 101 GB/s at 1 MB.
<!-- src: Bytes/Sources/CBytesCRC/include/CBytesCRC.h bytes_crc_udot comment; Bytes/Benchmarks/RESULTS.md "Adler-32 with UDOT: 2x faster" (29 → 55 GB/s in the table; probe re-run 2026-11-21: 29.6 → 56.9 GB/s at 1 MB, libdeflate 62.2); Bytes/Benchmarks/RESULTS.md "Cleanup and improvements (2026-11-19)" (baselines speed-after → p3-spot, M3 Ultra); "2026-11-20, Adler-32: past `udot`'s latency"; Tools/probes/results/M3-Ultra-2026-11-20/checksums.tsv (Adler32 1 MB 101.2 GB/s) -->

```asm
; probe (clang -O2): vdotq_u32(acc, a, b)
udot.4s v0, v1, v2                      ; for each of 4 lanes: v0[i] += v1[4i..4i+3] . v2[4i..4i+3]  (4 byte-products summed)
```

<!-- src: scratchpad probe c.c `dot` -->

You do not always need to write `udot` yourself. This probe sums an array of bytes into a `UInt32`, and the compiler
chose `udot` against a vector of ones.

```asm
; probe: for b in s { total &+= UInt32(b) }     x0 = pointer, x1 = count
<L3>:                                   ; main loop: 64 bytes per iteration
  ldp   q5, q6, [x8, #-0x20]            ; load 32 bytes
  ldp   q7, q16, [x8], #0x40            ; load 32 more; x8 += 64
  udot.4s v0, v5, v1                    ; v1 holds all-ones bytes: each lane gets the sum of four bytes added to v0
  udot.4s v2, v6, v1                    ; four independent accumulators (v0, v2, v3, v4): four chains, not one
  udot.4s v3, v7, v1
  udot.4s v4, v16, v1
  subs  x10, x10, #0x40                 ; 64 fewer bytes to go
  b.ne  <L3>                            ; loop while bytes remain
  add.4s v0, v2, v0 ...                 ; after the loop: add the accumulators, then
  addv.4s s0, v0                        ; "add across vector": horizontal sum of the four lanes
```

<!-- src: scratchpad probe a.swift `sumBytes`, swiftc -O 6.4.4 -->

Note the four accumulators: the compiler broke one dependency chain into four independent ones ([section 1.2](#12-latency-throughput-and-dependency-chains)).
Adler-32's weighted sum is different, and Swift's SIMD types have no widening dot product, so Bytes' `Adler32` calls a
`static inline` C wrapper around the instruction and keeps the loop in Swift. Part II (["Adler-32: `udot`"](#adler-32-udot)) describes the
loop, and Part III (["Reaching instructions Swift cannot name"](#reaching-instructions-swift-cannot-name)) walks through its machine code.
<!-- src: Bytes/Benchmarks/RESULTS.md "Adler-32 with UDOT: 2x faster" -->

#### 2.9 Carry-less multiply, CRC, AES, and SHA instructions

ARM64 has instructions for whole algorithms, which Swift cannot express and which Bytes reaches through small C targets
(Part II, ["Builds and traits: optimized, `Portable`, and no-C"](#15-builds-and-traits-optimized-portable-and-no-c)).

**`pmull`: carry-less multiply.** A carry-less multiply multiplies two bit strings with XOR in place of addition. A CRC is
polynomial division over GF(2) (arithmetic on single bits, where addition is XOR), so it is built from carry-less
multiplies. `pmull` does a 64x64 multiply to a 128-bit result in one instruction, and `pmull2` does it on the upper
halves. CRC-32 folds eight 16-byte accumulators forward (multiplies each by constants and XORs in new data), so the
whole loop runs at the memory rate (58–62 GB/s on the M1 Max).
<!-- src: Bytes/OPTIMIZATION.md (old) §13 glossary "Carry-less multiplication"; Bytes/OPTIMIZATION.md (old) §15 ("CRC-32's pmull fold (58–62 GB/s) at the memory rate") -->

Here is Bytes' real CRC-32 folding loop, the start of an iteration, from the release object:

```asm
<L0>:                                   ; one iteration consumes 128 bytes (8 vectors)
  cmp   x8, x12                         ; position vs. a limit: the cursor's overflow check (still here)
  b.gt  <L4>                            ; past the limit: leave the loop
  add   x8, x8, #0x80                   ; advance the byte offset by 128
  cmp   x10, x8                         ; bounds check: is there enough input left?
  b.lo  <L5>                            ; not enough: leave the loop
  cmp   x9, #0x0                        ; is the base pointer null?
  csel  x14, xzr, x13, eq               ; if the base pointer is null use 0 (so a null span is safe)
  str   x8, [x1, #0x18]                 ; store the cursor's new offset back (it lives in memory here)
  pmull.1q  v18, v7, v16                ; v18 = (low 64 bits of accumulator v7) x (low 64 bits of constant v16): a 128-bit carry-less product
  pmull2.1q v7, v7, v17                 ; v7  = (high 64 bits of v7) x (high 64 bits of constant v17)
  ldp   q19, q20, [x14]                 ; load the next 32 bytes of input
  eor3.16b v7, v18, v7, v19             ; v7 = v18 ^ v7 ^ v19: three-way XOR in ONE instruction: new accumulator
  pmull.1q  v18, v5, v16                ; the same for the next accumulator, v5 ...
  pmull2.1q v5, v5, v17
  eor3.16b  v5, v18, v5, v20            ; ... and its 16 input bytes
  ...                                   ; six more accumulators; the whole iteration (0x49484 to the `b.hi` at 0x49520) is 40 instructions for 128 bytes
```

<!-- src: objdump of Bytes/.build/agent-tools/Bytes.o (built 2026-11-19), CRC32._fold(_:_:) at 0x49484–0x494f4; constants are CRC32.fold1024 in Bytes/Sources/Bytes/CRC32.swift -->

Read it as the shape of the algorithm: each accumulator's low and high halves are multiplied by two constants (`pmull`,
`pmull2`) that advance it 128 bytes, and the products are XOR-ed with new data (`eor3`). Eight independent accumulators
give the core eight independent chains. The first few instructions are the cursor's bounds and overflow checks; the
tests are cheap but do take issue slots.
<!-- src: Bytes/OPTIMIZATION.md (old) §10 "CRC-32: 1.7–2.3x zlib" (eight accumulators, 128 bytes ahead, pmull/pmull2 constants); the annotation of the checks is the listing's own text -->

**`crc32x`, `crc32b`: the CRC32 instructions.** These compute the CRC-32 (the IEEE polynomial) of 8 bytes, or 1 byte, in
one instruction. Bytes uses these for inputs under 256 bytes and for the end of the buffer after folding; the other variant,
`crc32c*` (Castagnoli polynomial), is not used in the sources.
<!-- src: Bytes/Sources/CBytesCRC/include/CBytesCRC.h bytes_crc32_u64 (__crc32d), bytes_crc32_u8 (__crc32b); Bytes/Sources/Bytes/CRC32.swift foldThreshold (256) and _hardwareUpdate; grep of Bytes/Sources finds no crc32c -->

```asm
<L3>:                                   ; CRC32._hardwareUpdate: whole 8-byte groups of the tail
  ldr   x12, [x10], #0x8                ; load 8 bytes; pointer += 8
  crc32x w0, w0, x12                    ; w0 = CRC-32 of (w0, those 8 bytes): one instruction
  subs  x11, x11, #0x1                  ; one fewer group
  b.ne  <L3>                            ; loop while groups remain
<L5>:                                   ; the last 0-7 bytes, one at a time
  ldrb  w11, [x10, x9]                  ; load a byte
  crc32b w0, w0, w11                    ; fold it in
  add   x9, x9, #0x1                    ; index += 1
  cmp   x9, x8                          ; at the end?
  b.lt  <L5>                            ; no: next byte
```

<!-- src: objdump of Bytes/.build/agent-tools/Bytes.o, CRC32._hardwareUpdate at 0x49254–0x4928c -->

**`aese`, `aesmc`: one AES round.** `aese` does the AddRoundKey, SubBytes, and ShiftRows steps; `aesmc` does
MixColumns. A round is the pair. AES-128 is ten `aese` with nine `aesmc` between them (the last round has no
MixColumns), then an XOR with the last round key. On an M1 Max the core fuses the pair: 3 cycles of latency per round
and almost 4 rounds per cycle. So the limit is the chain, not the units. Bytes' counter mode keeps eight blocks in
flight, and each round of the eight waits 3 cycles for the last, so a group of 128 bytes takes about 32 cycles, about 4
bytes a cycle or 12.8 GB/s at 3.2 GHz. The measured AES-128-CTR (12 GB/s) is at that bound. The units alone would
allow about 1.5x that with 12 blocks in flight (a candidate, not tried: Part III, ["Crypto"](#9-crypto)).
<!-- src: Bytes/Benchmarks/RESULTS.md "What the cores can do" (re-measured 2026-11-21: aese+aesmc pair 3 cycles, 3.9/cycle; AES.swift eight blocks interleaved; 8 blocks × 16 B / ~32 cycles; measured 12 GB/s) -->

```asm
; probe (clang -O2 -march=armv8.4-a+crypto): vaesmcq_u8(vaeseq_u8(state, roundKey))
aese.16b  v0, v1                        ; v0 = SubBytes(ShiftRows(v0 ^ round key v1))
aesmc.16b v0, v0                        ; v0 = MixColumns(v0): together, one AES round for 16 bytes
```

<!-- src: scratchpad probe c.c `aes_round` -->

Counter mode (CTR, which encrypts a counter and XORs the result into the data) encrypts eight blocks at a time: eight
independent `aese`/`aesmc` chains, as ChaCha20 needs eight blocks to fill the pipes.
<!-- src: Bytes/OPTIMIZATION.md (old) §10 "AES-GCM and TLS 1.3 in Swift" ("Counter mode encrypts eight blocks at a time") -->

**`sha256h`, `sha256h2`, `sha256su0`, `sha256su1`: SHA-256.** Two instructions (`sha256h`, `sha256h2`) perform four
rounds of the compression function, and two (`sha256su0`, `sha256su1`) compute four new words of the message schedule.
Here is a real excerpt from Bytes' SHA-256 code, loading a 64-byte block and doing its first rounds:

```asm
  ldur  q26, [x11, #-0x70]              ; load 16 bytes of the message block
  rev32.16b v30, v26                    ; reverse the bytes in each 32-bit word: SHA-256 words are big-endian
  ...                                   ; (three more loads and byte reversals: v28, v29, v27)
  add.4s v31, v30, v2                   ; add the round constants K[0..3] to the message words W[0..3]
  mov.16b v8, v0                        ; copy state words A-D (the state is A-D in v0, E-H in v1); sha256h2 needs the old A-D
  sha256h.4s  q8, q1, v31               ; 4 rounds: the new A-D
  mov.16b v26, v1                       ; copy state words E-H
  sha256h2.4s q26, q0, v31              ; the same 4 rounds: the new E-H (from the old A-D in q0)
  sha256su0.4s v30, v28                 ; message schedule, step 1
  sha256su1.4s v30, v29, v27            ; message schedule, step 2: produces W[16..19], used in rounds 16-19
```

<!-- src: objdump of Bytes/.build/agent-tools/BytesCrypto.o (built 2026-11-19), specialized static SHA256.compressWithInstructions(_:blocks:), at 0x6fc94–0x6fcd0 -->

SHA-512 and SHA-384 use the matching `sha512h`/`sha512h2` (two rounds) and `sha512su0`/`sha512su1` (two schedule words):
489 instructions a block, which took SHA-512 of 1 MB from 38 M to 4.01 M instructions (CryptoKit: 4.34 M). On the M1
Max, `sha256h` and `sha512h` start at half an instruction per cycle, the slowest in the core's table.
<!-- src: Bytes/Benchmarks/RESULTS.md "Crypto cleanup (2026-11-19)" (sha512h/sha512h2 two rounds, su0/su1 two schedule words; 489 instructions a block; 38 M → 4.01 M, 0.64 ms against CryptoKit's 0.64 ms); "What the cores can do" table (sha256h, sha512h: 0.5 per cycle) -->

#### 2.10 Reaching these from Swift

Swift has no intrinsics (functions that map to one instruction) for `tbl` with run-time indices, `pmull`, `crc32`,
`udot`, or the AES and SHA instructions. Bytes reaches them through three small C targets (`CBytesNEON`, `CBytesCRC`,
`CBytesCrypto`) of `static inline` functions over C vector types that Swift imports as SIMD types (`SIMD16<UInt8>`,
`SIMD4<UInt32>`); Swift inlines them, so each call becomes the single instruction. `ld3`/`st4` on explicit vectors are
out of reach both ways (a C wrapper would need pointers): Bytes gets them only from the vectorizer. Part III (["Write
SIMD by hand, and reach instructions Swift cannot name"](#4-write-simd-by-hand-and-reach-instructions-swift-cannot-name)) covers how, and what goes wrong.
<!-- src: Bytes/OPTIMIZATION.md (old) §9; Bytes/Sources/CBytesNEON, CBytesCRC, CBytesCrypto (target names; ext_vector_type(16) u8 and ext_vector_type(4) u32 typedefs); Bytes/Benchmarks/RESULTS-base64.md "The ceiling" ("Swift has no way to emit them for explicit vectors: Swift has no intrinsics, and a C wrapper would need pointers"); Bytes/Benchmarks/RESULTS.md line 578 -->

### 3. Reading ARM64 assembly

You do not need to write assembly to use it as a tool. Reading a loop's disassembly answers questions no benchmark can:
whether it vectorized, whether anything is called that should not be, whether bounds checks remain, whether the cursor
is in memory.

#### 3.1 Registers and names

- `x0`–`x30` are 64-bit integer registers; `w0` is the low 32 bits of `x0`. `sp` is the stack pointer, `x29` the frame
  pointer, `x30` the link register (the return address). `xzr`/`wzr` read as zero.
- `v0`–`v31` are 128-bit vector registers, with other names for their parts: `q0` is all 128 bits, `d0` the low 64, `s0`
  the low 32, `b0` the low 8.
- Calling convention: arguments arrive in `x0`–`x7` (and `v0`–`v7` for vectors), results leave in `x0` (or `v0`; Swift
  can return a value in up to four registers). Swift additionally puts `self` for methods, and the context for
  closures, in `x20`, and a thrown error in `x21`.
- A suffix after the mnemonic gives the lane arrangement in `objdump`'s output: `add.16b` adds 16 byte lanes, `add.8h`
  8 halfwords, `add.4s` 4 32-bit words, `add.2d` 2 doublewords; `.8b`, `.4h`, `.2s` are the 64-bit half-width forms.
  (This is Apple's syntax; Arm's manuals write `add v0.16b, v1.16b, v2.16b`.) `rev32.16b` reverses the bytes within
  each 32-bit lane, a byte swap of four words at once.
<!-- src: Bytes/OPTIMIZATION.md (old) §2 "Enough Arm64 assembly for this document" box (x/w/v/q, suffixes, rev32.16b); the x20 self/context convention is visible in the probe listings of Box.v.getter (x20 used as self); x21 is set on the throw paths of the check/checkAny probes (d.swift); the rest is the AArch64 procedure-call standard and Swift's calling convention (general background) -->

#### 3.2 Loads, stores, and addressing modes

| Form | Meaning |
|---|---|
| `ldr x8, [x0]` | load 8 bytes from the address in `x0` |
| `ldr x8, [x0, #16]` | load from `x0 + 16` (immediate offset) |
| `ldr x8, [x0, x2]` | load from `x0 + x2` (register offset) |
| `ldr x8, [x0, x2, lsl #3]` | load from `x0 + x2 * 8` (scaled index: array of 8-byte elements) |
| `ldr x8, [x0], #8` | load from `x0`, then `x0 += 8` (post-increment) |
| `stp x29, x30, [sp, #-16]!` | `sp -= 16` first, then store there (pre-increment, the `!`) |
| `ldur q0, [x0, #-0x70]` | load at an unscaled (here negative) immediate offset |
| `ldp x6, x7, [x0, #16]` | load a pair: two registers from consecutive addresses at once |
| `ldrb w0, [x1]`, `ldrh`, `ldr w0` | load 1, 2, 4 bytes (zero-extended) |
| `str`, `stp`, `strb` | the stores |
| `ldr q0, [x0]`, `ldp q0, q1, [x0]` | load one or two 16-byte vector registers |

<!-- src: addressing modes seen in the listings in this part (Base64 encode kernel, CRC fold, probes); Bytes/OPTIMIZATION.md (old) §2 ("[x17, #16] is the address x17 + 16"; `ldp w6, w7, [x16, #16]` loads two adjacent 4-byte fields) -->

Pair loads matter in this project: when a record's adjacent 4-byte fields are loaded, the compiler merges them into one
`ldp w6, w7, [x16, #16]` (two fields from address `x16 + 16`).
<!-- src: Bytes/OPTIMIZATION.md (old) §6 "Give the record a known size" -->

#### 3.3 Arithmetic, bit manipulation, and byte swaps

- `add`, `sub`, `mul`, `lsl`/`lsr`/`asr` (shifts), `and`/`orr`/`eor` (bitwise) do what they say. `adds`/`subs` also set the
  condition flags (carry, overflow, zero, negative).
- `ubfx x0, x1, #7, #1`: **unsigned bit-field extract**, which takes 1 bit starting at bit 7 of `x1`. Shift-and-mask in one
  instruction.
- `bfi w0, w1, #12, #20`: **bit-field insert**, which puts the low 20 bits of `w1` into `w0` starting at bit 12. This is how
  `(x & 0xFFF) | (y << 12)` compiles (probe: one instruction).
- `rev w0, w8`: reverse the bytes of a 32-bit value (big-endian ↔ little-endian), one instruction.
- `usra`, `ushr`, `shl`: vector shifts (`usra` shifts right and accumulates).
<!-- src: scratchpad probes lowBits (bfi w0, w1, #12, #20), readBE32 (rev w0, w8), anyZero (ubfx w0, w0, #7, #1); bit-field semantics are the ISA's -->

Because the CPU is little-endian, reading a big-endian field is "load, then `rev`". Converting byte order therefore
costs one instruction.
<!-- src: Bytes/OPTIMIZATION.md (old) §13 glossary "Byte order (endianness)" ("Converting is a byte swap (rev on Arm), one instruction") -->

#### 3.4 Compare, branch, and select

- `cmp x8, #4` compares (it is `subs` with the result thrown away, setting flags). `tst` is the bitwise version.
- `b.ne L`, `b.lt`, `b.hs` (unsigned higher-or-same), `b.lo` (unsigned lower), `b.vs` (overflow set), `b.eq`: conditional
  branches on the flags. `b L` is unconditional. `bl L` is a call (branch with link, writing the return address to `x30`).
- `cbz x0, L`/`cbnz`: branch if a register is zero or non-zero, with no separate compare. `tbnz x0, #63, L`: branch if bit
  63 is set (a sign test).
- `csel x0, x0, x1, ne`: **conditional select**, `x0 = flags say ne ? x0 : x1`, with no branch. `cset w0, eq` sets a
  register to 1 or 0 from the flags. `ccmp` is a conditional compare that chains tests without a branch.
- `brk #0x1`: a trap. Swift's checks that fail (an array index out of range, an arithmetic overflow, a `precondition`)
  land on a `brk`. **A `brk` at the end of a function, reached by a conditional branch above it, is a bounds or
  overflow check.**
<!-- src: scratchpad probes (spanAt, overflow, wrap, sel, readBE32); the brk-as-trap reading is evident in the listings of Base64.encodeBlocks (L2: brk) and overflow(_:_:) -->

Two probes show the difference between checking and not checking:

```asm
; probe: func overflow(_ a: Int, _ b: Int) -> Int { a + b }        ; plain +: traps on overflow
  adds  x0, x0, x1                      ; add and set flags
  b.vs  <L0>                            ; branch if the overflow flag is set...
  ret                                   ; no overflow: return the sum
<L0>:
  brk   #0x1                            ; ...to a trap

; probe: func wrap(_ a: Int, _ b: Int) -> Int { a &+ b }           ; &+: wraps, never traps
  add   x0, x1, x0                      ; one instruction, no check
  ret                                   ; return the sum
```

<!-- src: scratchpad probe d.swift `overflow` and `wrap` -->

#### 3.5 Calls and what they cost

`bl` calls a function. In an object file (before linking), `objdump` shows `bl` with a placeholder target. **`objdump -dr`
prints the relocation, which names the callee** (`ARM64_RELOC_BRANCH26 _swift_retain`); a relocation is the object
file's note telling the linker what to fill in at that place. In a linked binary, calls to other libraries go through
stubs (small jump functions), and `otool -tV` resolves them. A call has costs beyond its body: the caller must save any values it keeps in registers the
callee may overwrite (the caller-saved ones), and the optimizer cannot see through the call.
<!-- src: AGENTS.md "Tools/calls" description (relocations from objdump -dr in objects; otool -tV in linked binaries, which names stubs; plain objdump mislabels stub calls); AGENTS.md "macOS tools" table -->

For Swift performance work, the callees worth spotting are the runtime's: `swift_retain`/`swift_release` (reference
counting), `swift_allocObject` (a heap allocation), `swift_beginAccess` (dynamic exclusivity checking), `swift_once` (lazy
global initialization), `swift_allocError` (boxing an error), and `swift_task_switch` (an executor check: whether an
async function is already running where it must run; Part IV, ["Executor checks and real hops: `swift_task_switch`"](#12-executor-checks-and-real-hops-swift_task_switch)).
[Section 4](#4-how-swift-becomes-machine-code) shows probes that call several of them.
<!-- src: AGENTS.md "Workflow" step 4 and "Lessons" (retain/release, outlined destroy, swift_task_switch); scratchpad probe d.swift relocations -->

#### 3.6 How to find the loop

A loop is a branch back to an earlier address. With `--symbolize-operands`, `objdump` turns branch targets into `<L0>`,
`<L1>` labels, so a backward branch to a label printed above it is a loop; `Tools/loops` automates that, and reports each
loop's size, depth, instruction mix, and verdict.
<!-- src: AGENTS.md "Tools/loops FILE|--target PKG TARGET PATTERN" description ("a branch back to an earlier <Ln> label in objdump --symbolize-operands output") -->

The one-liners:

```sh
objdump -d --no-show-raw-insn --symbolize-operands --disassemble-symbols=MANGLED FILE.o   # one function, loop labels
objdump -dr FILE.o                                                                          # with relocations: callee names
nm --defined-only FILE.o | xcrun swift-demangle --simplified                                # find a mangled symbol
```

<!-- src: AGENTS.md "macOS tools" table (objdump flags, nm --defined-only, swift-demangle --simplified) -->

#### 3.7 A worked example: a cursor read

Bytes' `BytesReader` checks that enough bytes remain, loads, and byte-swaps. The cursor's check is
`span.byteCount &- offset >= n`, with wrapping arithmetic because the cursor knows it cannot overflow.
<!-- src: Bytes/OPTIMIZATION.md (old) §6 "Tell the optimizer the invariant" -->
A probe with the same shape (check, then an unaligned big-endian 32-bit load, returning `nil` when short):

```swift
func readBE32(_ p: UnsafeRawBufferPointer, _ offset: Int) -> UInt32? {
    guard offset >= 0, p.count - offset >= 4 else { return nil }
    return UInt32(bigEndian: p.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
}
```

```asm
; x0 = base pointer, x1 = end pointer, x2 = offset     result: x0 = value, or 0x1_0000_0000 for nil
  tbnz  x2, #0x3f, <L0>                 ; offset < 0 (bit 63 set)? -> return nil
  sub   x8, x1, x0                      ; x8 = count = end - base
  cmp   x0, #0x0                        ; is the base pointer null (an empty buffer)?
  csel  x8, xzr, x8, eq                 ; if so, count = 0 (no branch)
  sub   x8, x8, x2                      ; x8 = count - offset
  cmp   x8, #0x4                        ; at least 4 bytes left?
  b.lt  <L0>                            ; no: return nil
  cbz   x0, <L1>                        ; (a null base here would be a trap: unreachable in practice)
  ldr   w8, [x0, x2]                    ; the load: 4 bytes from base + offset (unaligned is fine on ARM64)
  rev   w0, w8                          ; byte-swap: big-endian to native
  ret                                   ; return the value
<L0>:
  mov   x0, #0x100000000                ; the Optional's "nil": a 32-bit payload plus a "no value" flag in bit 32
  ret                                   ; return nil
```

<!-- src: scratchpad probe a.swift `readBE32`, swiftc -O 6.4.4 -->

Read it as: seven instructions of check (`tbnz`, `sub`, `cmp`, `csel`, `sub`, `cmp`, `b.lt`) and a null test (`cbz`),
one load, one byte swap. Everything in Parts [II](#part-ii-the-bytes-toolkit-bottom-up) and [III](#part-iii-techniques-by-problem) about cursors is about making sure this is all that is left.
When many reads share a check (a fixed-size record), the checks fold into one, which is why a record read as its own
cursor beats field-by-field reading: 200 K against 286 K instructions for 2,000 zip directory entries.
<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): BytesBenchmarks rows "Fields: Bytes, fixed-size records" 199,807 and "Fields: Bytes" 285,695 instructions; Bytes/Benchmarks/RESULTS.md 2026-11-17 "Results, t0 → final" ("Zip directory with @BinaryRecord vs field by field / ParserSpan | 285 / 461 K | 199 K"); Bytes/OPTIMIZATION.md (old) §6 "Give the record a known size" (301 K first measurement, 285 K latest, 199 K) -->

#### 3.8 A worked example: the Base64 encoding kernel

Here is the Base64 encoder's 48-byte block loop, on ARM64, in full, from the release build of `BytesBase64`. It reads 48
input bytes (16 three-byte groups) and writes 64 characters. Registers `v0`–`v3` hold the 64-character alphabet,
`v4`–`v6` hold three constant index vectors, and `v7` holds `0x3f`.

```asm
; Base64.encodeBlocks(_ input: Span<InlineArray<48, UInt8>>, into: inout MutableSpan<InlineArray<64, UInt8>>, table: ...)
; x0 = input pointer, x1 = block count, x2 = pointer to the output span (its pointer, then its count)
  ldr   x8, [x2, #0x8]                  ; x8 = output block count
  cmp   x8, x1                          ; equals the input's block count?
  b.ne  <L2>                            ; no: trap (brk). THE bounds check: once, before the loop
  cbz   x1, <L1>                        ; zero blocks: nothing to do
  ldr   x9, [x2]                        ; x9 = output pointer
  ... ; (pointer setup and loading the index constants v4–v6 and the 0x3f mask v7)
<L0>:                                   ; ---- the loop: 32 instructions per 48 bytes ----
  ldp   q16, q17, [x8, #-0x20]          ; load input bytes 0..31 (x8 runs 32 bytes ahead of the block start)
  ldr   q18, [x8], #0x30                ; load input bytes 32..47; then x8 += 48 (next block)
  tbl.16b v19, { v16, v17, v18 }, v4    ; v19 = the FIRST byte of each of 16 groups (a 48-byte, 3-register lookup)
  tbl.16b v20, { v16, v17, v18 }, v5    ; v20 = the SECOND byte of each group
  tbl.16b v16, { v16, v17, v18 }, v6    ; v16 = the THIRD byte of each group
  ushr.16b v17, v19, #0x2               ; 6-bit value 0 = first >> 2
  tbl.16b v17, { v0, v1, v2, v3 }, v17  ; map it to its character: a lookup in the 64-byte alphabet
  shl.16b v18, v19, #0x4                ; value 1 = (first << 4) ...
  usra.16b v18, v20, #0x4               ; ... + (second >> 4), shift-right-and-accumulate in one instruction
  and.16b v18, v18, v7                  ; keep 6 bits (& 0x3f)
  tbl.16b v18, { v0, v1, v2, v3 }, v18  ; character 1
  shl.16b v19, v20, #0x2                ; value 2 = (second << 2) ...
  usra.16b v19, v16, #0x6               ; ... + (third >> 6)
  and.16b v19, v19, v7
  tbl.16b v19, { v0, v1, v2, v3 }, v19  ; character 2
  and.16b v16, v16, v7                  ; value 3 = third & 0x3f
  tbl.16b v16, { v0, v1, v2, v3 }, v16  ; character 3
  zip1.16b v20, v17, v18                ; interleave char0 and char1: c0[0] c1[0] c0[1] c1[1] ...  (low halves)
  zip2.16b v17, v17, v18                ; the same for the high halves
  zip1.16b v21, v19, v16                ; interleave char2 and char3 (low halves)
  zip2.16b v18, v19, v16                ; (high halves)
  sub   x10, x9, #0x20                  ; x10 = output start of this block (x9 runs 32 ahead)
  st2.4h { v20, v21 }, [x10]            ; store 16-bit pairs (c0c1, c2c3) interleaved: groups 0-3 as 16 bytes
  zip2.8h v16, v20, v21                 ; the same interleave for groups 4-7 ...
  stur  q16, [x9, #-0x10]               ; ... stored as one 16-byte vector
  add   x10, x9, #0x40                  ; next block's output pointer (+64)
  st2.4h { v17, v18 }, [x9], #16        ; groups 8-11; then x9 += 16
  zip2.8h v16, v17, v18                 ; groups 12-15
  str   q16, [x9]                       ; stored
  mov   x9, x10                         ; advance the output
  subs  x1, x1, #0x1                    ; one fewer block
  b.ne  <L0>                            ; loop
<L1>:
  ret                                   ; done
<L2>:
  brk   #0x1                            ; the trap for the count mismatch
```

<!-- src: objdump of Bytes/.build/agent-tools/BytesBase64.o (built 2026-11-19), symbol Base64.encodeBlocks(_:into:table:) at 0x984–0xa40, re-run by the fact-checker: identical; loop is 32 instructions per 48-byte block per Bytes/Benchmarks/RESULTS-base64.md line 411 ("ARM64 blocks (tbl, zip): 32 instructions per 48 bytes") -->

What to take from it:

- **There is one bounds check, before the loop** (`cmp x8, x1; b.ne … brk`). The loop body has none, because each span
  element is a whole 48- or 64-byte block and the loop count equals both spans' counts. [Section 4](#4-how-swift-becomes-machine-code) and Part III (["Remove
  the checks the compiler cannot prove away"](#2-remove-the-checks-the-compiler-cannot-prove-away)) explain how the compiler knows.
- **The seven `tbl`s are the bound** (three 3-register ones that split bytes, four 4-register ones that map to
  characters), and the interleave is eight cheap `zip`s, two of which LLVM folded into the two `st2` stores. Counting a
  `tbl` or `tbx` as one micro-op per table register, the kernel is 7 `tbl` instructions and 25 micro-ops, with 10 other
  instructions for the fields.
  <!-- src: Bytes/Benchmarks/RESULTS-base64.md line 186 ("Deinterleave, compute, interleave (kept) | 32 | 7 tbl (25 micro-ops), 10 for the fields, interleave folded into 2 st2") -->
- **It runs 32 instructions in about 9.5 cycles**, 3.4 instructions per cycle, at 20.4 GB/s at 1 MB (about 9 cycles at the
  21.5 GB/s of the earlier `d2-final` run). The C kernel using `ld3`/`st4` directly reached 23.1 GB/s in that run, so the
  Swift version was at 93% of it then and is at 88% of it against this run's rate.
  <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): row "Encode 1 MB: Bytes (BytesReader → BytesWriter)" 205,695 ns and 2,799,615 instructions for 4 MiB (32.0 per 48-byte block; 48 B / 20.39 GB/s × 4.02 GHz = 9.5 cycles); Bytes/OPTIMIZATION.md (old) §10 "Base64: 0.86 → 21.4 GB/s" (23.1 GB/s; 93%); Bytes/Benchmarks/RESULTS-base64.md "Encoding" table (M3 Ultra, d2-final: 21.5 GB/s at 1 MB) -->
- **Instruction count is not the limit.** In an earlier version of this kernel, reducing the instruction count 2.3x (by
  removing bounds checks) did not change the speed, because the checks had run in spare slots beside the `tbl`s, which
  were the bottleneck.
  <!-- src: Bytes/OPTIMIZATION.md (old) §6 "Loop over typed spans" ("Instructions fell 2.3x; throughput didn't move") -->

### 4. How Swift becomes machine code

Swift's optimizer is a pipeline of passes, and understanding which pass does what explains why the same-looking code
sometimes compiles to a single instruction and sometimes to a call into the runtime.

#### 4.1 The pipeline: SIL, then LLVM

The compiler lowers Swift in stages. It first produces **SIL** (Swift Intermediate Language), a representation that still
knows about Swift's types, reference counting, and generics. SIL passes do Swift-specific work: **inlining** (replacing a
call with the callee's body), **generic specialization** (making a copy of a generic function for the concrete types it is
called with), reference-count removal, and moving boxed locals to the stack. The result is lowered to **LLVM IR** (LLVM's
lower-level, language-neutral intermediate representation), which LLVM optimizes with its general passes (the loop
vectorizer and the SLP vectorizer of [section 4.10](#410-the-two-vectorizers-and-their-remarks), instruction combining, jump threading, function merging) and then
turns into ARM64.
<!-- src: AGENTS.md "Swift's LLVM vs Homebrew's" (Swift's own LLVM is linked into swiftc; SIL printing via -Xllvm -sil-print-*); AGENTS.md "Tools/sil-trace" ("prints the SIL instructions ... after every pass that changed them"); stage descriptions are general background -->

Two tools look at the stages. `Tools/swiftc-target` captures a package target's exact `swiftc` command so you can emit
SIL (`-emit-sil`), IR (`-emit-ir`), or assembly (`-S`) with the real flags. `Tools/sil-trace` prints the SIL
instructions matching a pattern (a `release_value`, `alloc_box`, `apply`) after every pass that changed them, finding the
pass that introduces or fails to remove one; `-Xllvm -sil-disable-pass=NAME` confirms it by turning a pass off.
<!-- src: AGENTS.md "Tools/swiftc-target", "Tools/sil-trace", "Compiler flags worth knowing" table -->

Swift's LLVM and Homebrew's `llvm` are different: Swift's is Apple's (or swiftlang's) fork linked into `swiftc`, and what it
did is what ships. Homebrew's is newer upstream and has tools Swift lacks (`llvm-mca`, `opt`). Use the first to ask what
the compiler did, the second for experiments.
<!-- src: AGENTS.md "Swift's LLVM vs Homebrew's" -->

#### 4.2 Inlining and its cost model

Inlining ([section 4.1](#41-the-pipeline-sil-then-llvm)) removes the call's overhead, but its larger benefit is that the optimizer then sees one
function: it can keep values in registers across what was a call boundary, fold
constants, and merge checks. **Outlining** is the reverse: moving code into a separate function.
<!-- src: Bytes/OPTIMIZATION.md (old) §13 glossary "Inlining" -->

Both Swift's SIL inliner and LLVM's inliner use a **cost model**: they inline when the estimated benefit exceeds the
callee's estimated size. Both can decline. The SIL inliner declined an `@inline(__always)` match search into Brotli's parse
loop once the loop grew ("Not profitable to inline … cost = 785", visible with `Tools/remarks --passes sil-inliner`), and
LLVM then found it "too costly".
<!-- src: AGENTS.md "@inline(__always) is a hint; @inline(always) is a guarantee" -->

Swift has three levels of request:

- `@inlinable` makes the function's body visible to other modules so they *can* inline and specialize it. It does not mean
  "inline". A new `BytesWriter` initializer, only `@inlinable`, was called out of line from NativeZip's decode function
  (789 → 891 instructions, the writer returned through memory).
  <!-- src: AGENTS.md "`@inlinable` doesn't mean inlined" (789 → 891) -->
- `@inline(__always)` is the older, underscored attribute: a strong hint without a guarantee. Anything a hot function
  calls once per entry, initializers included, should be `@inline(__always)`.
  <!-- src: AGENTS.md "`@inlinable` doesn't mean inlined" -->
- `@inline(always)` (Swift Evolution proposal SE-0496, in Swift 6.4) is a guarantee. Adopting it, with the decoder split
  into small functions that each hold their cursors as locals, was the largest of the changes that took the DEFLATE
  decoder from 2x slower than zlib to faster. It also made Brotli's match search inline where `@inline(__always)` had
  not (quality 5 ran 2–8% more instructions without it).
  <!-- src: Bytes/OPTIMIZATION.md (old) §5 "2. A function that isn't inlined" (SE-0496, DEFLATE); AGENTS.md "@inline(__always) is a hint; @inline(always) is a guarantee" (quality 5, 2–8%) -->

An inlinable function is not free to *add*: a rare path inlined into a hot function grows it, and can slow the inputs
that never take it. So inlining is chosen per function, measured both ways; Part III (["Rare paths stay out of line"](#rare-paths-stay-out-of-line))
has the DEFLATE case.
<!-- src: AGENTS.md "Rare paths stay out of line even when they're the thing being optimized" -->

#### 4.3 Generics, specialization, and metadata

A generic function compiled once for all types must work without knowing a type's size or how to copy it. It receives
**type metadata** and **witness tables** (per-type tables of function pointers for protocol requirements) and calls through
them: slow, and opaque to the optimizer. Specialization ([section 4.1](#41-the-pipeline-sil-then-llvm)) makes a copy for the concrete type, in which the
metadata calls become direct operations or disappear. It happens when the generic function's body is visible (in the
same module, or from another module through `@inlinable`) and the call site knows the type. Otherwise the
unspecialized fallback runs, with calls through metadata.
<!-- src: general background; Bytes/OPTIMIZATION.md (old) §13 glossary "Value witness table"; AGENTS.md "Byte-only formats use AlignedBytesReader" ("Check new ones with Tools/calls … --callee metadata") -->

This is why Bytes' cursors are generic over a mode: `GenericBytesReader<Mode>` with `BitAddressable` and `ByteAligned`
modes. After specialization, the byte-aligned mode's bit offset is the constant 0 and every test of it folds. An
out-of-line helper on the cursor that is not constrained to one mode stays generic and takes type metadata at every call,
so such helpers belong in the `BitAddressable`-constrained extensions. `Tools/calls … --callee metadata` finds the ones
that slipped.
<!-- src: AGENTS.md "Byte-only formats use AlignedBytesReader and AlignedBytesWriter" ("Out-of-line helpers on the cursors belong in the BitAddressable-constrained extensions, so they aren't generic. Check new ones with Tools/calls … --callee metadata"); Bytes/Benchmarks/RESULTS.md line 843, 850 -->

Standard-library generics can also fail to inline: `SIMD8<UInt16>(truncatingIfNeeded:)` in LZBITMAP's decoder was
inlined until the LZFSE and LZVN encoders in the same module also used SIMD conversions. Then it stayed a call (6 per
16 groups), and decoding ran 12–15% more instructions with no change to the decoder's file. Bytes widens with a byte
zip and narrows with `_lowBytes` instead.
<!-- src: AGENTS.md "Generic standard-library SIMD conversions are inlined only while they have few callers" -->

**Existentials.** A value of type `any P` is an **existential**: a box holding a value of unknown type plus the witness
table for `P`. Calls through it are dynamic and the box may allocate. Bytes' cursor design avoids them: "no class, no
buffer, no existential".
<!-- src: Bytes/OPTIMIZATION.md (old) §3 "A small struct of plain values" (no class, no buffer, no existential) -->

#### 4.4 Reference counting (ARC)

Classes (and closures that capture, and arrays' storage) are reference counted: copying a reference **retains** (adds one
to its count) and dropping it **releases** (subtracts one, freeing at zero). These are runtime calls (`swift_retain`,
`swift_release`) doing atomic updates, costly in any loop that makes them. SIL has passes that remove pairs. Seeing `swift_retain` or `swift_release` in a hot loop's `Tools/calls` output means one was not removed.
<!-- src: AGENTS.md "Workflow" step 4 ("If something is called that shouldn't be (retain/release, outlined destroy, swift_task_switch, unspecialized generics): Tools/calls, then Tools/sil-trace"); mechanism is general background -->

Two probes show runtime calls that even simple class code makes. The first reads a stored property of a `final class`
instance:

```swift
public final class Node { public var next: Node?; public let value: Int; init(_ v: Int) { value = v } }
func second(_ n: Node) -> Int { n.next?.value ?? 0 }
```

```asm
; probe: second(_:)    x0 = the Node
  sub   sp, sp, #0x40                   ; a stack frame, because...
  stp   x20, x19, [sp, #0x20]           ; (saving registers)
  stp   x29, x30, [sp, #0x30]           ; (saving the frame pointer and return address)
  add   x29, sp, #0x30                  ; set the frame pointer
  mov   x19, x0                         ; keep the object across the call
  add   x0, x0, #0x10                   ; x0 = address of the `next` field
  add   x1, sp, #0x8                    ; x1 = scratch space for the access record
  mov   x2, #0x0                        ; x2 = 0: "read access"
  mov   x3, #0x0                        ; x3 = 0 (the fourth argument)
  bl    <relocation: swift_beginAccess> ; ...the DYNAMIC EXCLUSIVITY CHECK: is anyone else modifying `next` right now?
  ldr   x8, [x19, #0x10]                ; load `next`
  cbz   x8, <L1>                        ; nil?
  ldr   x0, [x8, #0x18]                 ; load next.value
  b     <L2>                            ; to the shared exit (not shown)
```

<!-- src: scratchpad probe d.swift `second`; relocation names from xcrun objdump -dr d.o (swift_beginAccess) -->

The call is **exclusivity enforcement**: Swift checks at run time that a class property is not read while being modified.
The probe also shows the cost of a class property in a hot loop: a runtime call where a struct field would be a load.
The second probe, which pushes an object into an array, calls `swift_unknownObjectRetain` (the array then holds a
reference) and the array's append machinery.
<!-- src: scratchpad probe d.swift `keep` (relocations: swift_unknownObjectRetain, specialized Array._appendElementAssumeUniqueAndCapacity) -->

The remedy is in the design. Bytes' cursors are structs of plain values (a `RawSpan`, the untyped span of bytes; a byte
offset; a bit offset; a bit order: 40 bytes), and parsed values are views of the input, so there is nothing to retain. MQTT's views parse 8.6x
faster than conventional parsing into `[UInt8]` and `String` on one core, and 18.6x on all cores, where the conventional
code's allocations contend for the allocator.
<!-- src: Bytes/OPTIMIZATION.md (old) §3 "A small struct of plain values" (40 bytes); MQTT/Benchmarks/RESULTS.md 2026-11-19 "The views against the conventional code" (8.6x one core, 18.6x all cores on the M3; supersedes the older 5.5x / 11x) and "Interpretation" (the Current section attributes the poor scaling to the allocator) -->

**Value witnesses and resilience.** A struct that contains a resilient field (one whose layout the compiler cannot see,
such as `Date?` from a framework) is copied through its type's value-witness functions (the per-type functions that
copy, move, and destroy a value; `swift_cvw_initWithCopyImpl` in profiles) instead of with a `memcpy`. Jobs that are queued, sorted, and handed between tasks are cheaper as final classes.
<!-- src: AGENTS.md "Payload structs with resilient fields (`Date?`) copy through value witnesses" -->
Likewise, a `~Escapable` struct (a type whose values cannot outlive what they borrow; Part II, ["`~Escapable`: the
compiler checks the lifetime"](#escapable-the-compiler-checks-the-lifetime)) with more than 6 leaf fields is destroyed at `-O` even when every field is trivial; from
another module, the destroy is an indirect call to a no-op through the type's value witness table, costing 2.5–3% of
MQTT's per-packet time.
<!-- src: Bytes/OPTIMIZATION.md (old) §12 table row "~Escapable structs with more than 6 leaf fields" -->

An `outlined destroy` or `outlined copy` in a profile is the compiler's out-of-line helper for copying or destroying a
compound value; like the above, it signals values the optimizer could not keep in registers.
<!-- src: AGENTS.md "Workflow" step 4 (outlined destroy named among things to chase); Bytes/OPTIMIZATION.md (old) §11 "Big enums are expensive to pass around" ("each test of its case calls an outlined ... get tag function") -->

Big enums show the same effect: MQTT's `MQTTPacket` enum is 153 bytes, too big for registers, so it is returned through a
pointer, and testing its case calls an out-of-line "get tag" function. Giving each packet type its own
`init(parsing:)` and `write(to:)`, dispatched once on the frame's type, raised encoding throughput 68% and parsing
throughput 58%.
<!-- src: Bytes/OPTIMIZATION.md (old) §11 "Big enums are expensive to pass around"; AGENTS.md "Enums" -->

#### 4.5 Lazy globals: `swift_once`

A `static let` or a global is initialized **lazily**: every use checks a once-token inline and, until the token says
done, calls `swift_once`, which runs the initializer the first time. If the compiler can evaluate the initializer at
compile time (a literal), the value is stored statically and no check remains. A probe makes both visible:

```swift
public struct Table { public static let squares: [Int] = (0..<256).map { $0 * $0 } }   // computed: lazy
public struct Tag   { public static let magic: UInt32 = 0x504B0102 }                   // literal: static
```

```asm
; probe: Table.squares[i & 255]       x0 = i
  adrp  x8, <the once-token page>       ; x8 = address of the "has it been initialized" token
  ldr   x8, [x8]                        ; load the token
  cmn   x8, #0x1                        ; compare with -1 ("done")
  b.ne  <L1>                            ; not done yet: go call swift_once, which runs the initializer
<L0>:
  ... ldr x10, [x8, #0x10]              ; load the array's count
  cmp   x9, x10                         ; index in range? (the array bounds check)
  b.hs  <L3>                            ; else trap
  add   x8, x8, x9, lsl #3              ; address = base + index*8
  ldr   x0, [x8, #0x20]                 ; load the element (the elements start 0x20 into the array object)

; probe: Tag.magic
  mov   w0, #0x102                      ; 0x504B0102 as two instructions: the constant is in the code
  movk  w0, #0x504b, lsl #16            ; (move-keep: put 0x504B into the upper half-word)
  ret                                   ; no check, no load
```

<!-- src: scratchpad probe d.swift `square` and `magic` (relocation _swift_once in square) -->

Only computed initializers are lazy: literal `static let` arrays and `InlineArray`s are statically initialized with no
`swift_once` (check with `nm` for no once token, or `Tools/calls --callee swift_once`).
<!-- src: AGENTS.md "Literal `static let` arrays and `InlineArray`s are statically initialized" -->

The cost shows in measured places. An initializer that the compile-time evaluator could not fold cost zip-record parsing
41% more instructions, and a global read inside a measured loop made one benchmark bimodal (78 K and 104 K instructions
per iteration). Removing a lazy global can also cost: CRC-32's tables, made literals, cost 64-byte checksums +10.7% until
the inner update was moved out of line. Part III (["Technique 6: no lazy globals on the hot path"](#technique-6-no-lazy-globals-on-the-hot-path) and ["No lazy globals
inside a measured loop"](#no-lazy-globals-inside-a-measured-loop)) has the details.
<!-- src: Bytes/OPTIMIZATION.md (old) §11 "Write constants as literals" (41%); AGENTS.md "No lazy globals inside a measured loop" (78 K / 104 K); AGENTS.md "A table that becomes a compile-time constant can make LLVM rematerialize its address in the loop" (+10.7%) -->

#### 4.6 Bounds checks and overflow checks

Swift checks array and span indices and traps on integer overflow. Each check is a compare and a well-predicted branch
([section 3.4](#34-compare-branch-and-select)), cheap on its own, but two things make them costly in hot code. A failing check is an *early exit*, which
blocks vectorization ([section 2.1](#21-what-simd-is)). And checks the optimizer cannot merge pile up.
<!-- src: Bytes/OPTIMIZATION.md (old) §6 intro -->

`&+`, `&-`, `&*` are the **wrapping** operators: they never trap, and compile to the bare instruction (the `overflow` and
`wrap` probe above: `adds`+`b.vs`+`brk` against one `add`). Bytes' cursor arithmetic uses them where overflow is
impossible by construction.
<!-- src: scratchpad probe d.swift; Bytes/OPTIMIZATION.md (old) §6 ("with wrapping arithmetic (&-) because the cursor knows it can't overflow") -->

An index of a plain `Array` shows both a sign test and a count compare:

```asm
; probe: func spanAt(_ s: [UInt8], _ i: Int) -> UInt8 { s[i] }     x0 = array object, x1 = i
  tbnz  x1, #0x3f, <L0>                 ; i < 0? trap
  ldr   x8, [x0, #0x10]                 ; the array's count (stored at offset 0x10 of the object)
  cmp   x1, x8                          ; compare i with the count
  b.hs  <L1>                            ; i >= count (unsigned: also catches negatives)? trap
  add   x8, x0, x1                      ; x8 = object address + i
  ldrb  w0, [x8, #0x20]                 ; the bytes start at offset 0x20
  ret                                   ; return the byte
<L0>: brk #0x1                          ; trap: negative index
<L1>: brk #0x1                          ; trap: index past the end
```

<!-- src: scratchpad probe a.swift `spanAt` -->

(The first test is redundant with the unsigned compare; the compiler emitted both for the array subscript.) Part III
(["Remove the checks the compiler cannot prove away"](#2-remove-the-checks-the-compiler-cannot-prove-away)) shows how Bytes removes them: a loop over typed spans leaves one check per span;
`assume` states an invariant the cursor maintains; a count check is a single unsigned compare
(`UInt(bitPattern: n) <= UInt(bitPattern: remaining)`).
<!-- src: Bytes/OPTIMIZATION.md (old) §6; AGENTS.md "A count check is one unsigned compare" -->

**`assume`, `likely`, `unlikely`.** Bytes has internal wrappers over compiler builtins: `assume(_:)` tells the optimizer a
condition holds ("Unchecked: if `condition` is false, behavior is undefined"), and `likely`/`unlikely` set a branch's
weight. `assume(_byteOffset <= span.byteCount)` lets LLVM merge field checks. But hints can hurt: the fourth assumption,
`_byteOffset >= 0`, is true but was deliberately left out, because it alone stopped LLVM from vectorizing loops of single
reads (14 against 113 GB/s). Without `likely`/`unlikely`, bit-field parsing took 14% more instructions (689 K → 787 K).
<!-- src: Bytes/Sources/Bytes/Builtins.swift (assume, likely, unlikely definitions and docs); Bytes/OPTIMIZATION.md (old) §6 ("14 against 113 GB/s") and §11 "Measure hints" (689 K → 787 K) -->

#### 4.7 `unsafe` and strict memory safety

Bytes compiles most targets with Swift's **strict memory safety** (`.strictMemorySafety()` in `Package.swift`): the compiler
flags every use of an unsafe construct (a raw pointer, an unchecked load) unless it is marked with the `unsafe`
keyword. The project's rule is that every `unsafe` expression carries a comment saying why it is safe. This confines
unchecked code to a few functions, each behind the cursor's own check, instead of scattering it.
<!-- src: Bytes/Package.swift lines 21 (strictSettings uses .strictMemorySafety()); AGENTS.md "Swift style here" ("every unsafe expression with a comment saying why it's safe"); Bytes/OPTIMIZATION.md (old) §6 ("the unchecked accesses stay, confined to a few functions") -->

Measured against the safe alternatives, checked cursor reads cost 24% more instructions for field parsing and 2–8x for
odd widths, and stopped bulk loops from vectorizing; the standard library's span bounds check needs `offset >= 0`, which the cursor
deliberately does not assume, so it stays a second check.
<!-- src: Bytes/OPTIMIZATION.md (old) §6 "When the standard library's safe accessors cost too much" -->

#### 4.8 Typed throws and error boxing

A function that `throws` (untyped) can throw any error, so the error travels as an `any Error` box and creating one
allocates (`swift_allocError`). **Typed throws** (`throws(BytesError)`) says exactly which error, so it can travel as a
plain value. A probe shows the difference at the throw site:

```swift
enum E: Error { case bad }
func check(_ x: Int) throws(E) -> Int    { if x < 0 { throw .bad }; return x }   // typed
func checkAny(_ x: Int) throws -> Int    { if x < 0 { throw E.bad }; return x }  // untyped
```

The untyped version's throw path calls `swift_allocError` (a heap allocation to box the error) and `swift_willThrow`. The
typed version calls `swift_willThrowTypedImpl` instead (after an OS-version availability check,
`_stdlib_isOSVersionAtLeastOrVariantVersionAtLeast`) and allocates nothing. The success path of both is the same two
instructions (`tbnz`, `ret`).
<!-- src: scratchpad probe d.swift `check` and `checkAny`, relocations from xcrun objdump -dr (check: _stdlib_isOSVersionAtLeastOrVariantVersionAtLeast, _swift_willThrowTypedImpl; checkAny: _swift_allocError, _swift_willThrow); the availability-check overhead matches Bytes/OPTIMIZATION.md (old) §12 table row "Typed-throw sites check OS availability" -->

Two traps. A `do { } catch` around a typed-throws call boxes the error (`swift_allocError`) unless it is written
`do throws(E) { }`. And an unannotated closure `{ x in … }` passed to a generic `throws(E)` parameter is inferred as
`throws(any Error)` (Swift 6.4, without the `FullTypedThrows` feature). Such a closure was not inlined into Bytes' array
builder: the writer went through memory, +3% instructions. Annotated `{ (x) throws(BytesError) in … }`, it was inlined.
<!-- src: AGENTS.md "Typed throws: do { } catch ... boxes the error"; AGENTS.md "Closures passed to a generic throws(E) parameter" -->

#### 4.9 Function merging, and benchmarks that lie

LLVM merges functions whose code is identical, and in Swift's pipeline also functions that differ only in constants,
which become a parameter of one `merged …` function. That is useful as a proof (two probes becoming one symbol shows an
abstraction is free), and it is also a trap. When a benchmark compares two variants chosen by a constant `Bool`, LLVM
can fold the two copies back into one `merged …` function taking the constant as a parameter, so both variants test it
in the hot loop.
Part III (["Function merging can undo a specialization"](#function-merging-can-undo-a-specialization)) has the cases and how to check for them.
<!-- src: AGENTS.md "Old and new code in one benchmark run" paragraph; Bytes/OPTIMIZATION.md (old) §2 "Check a new API's code from another module" -->

#### 4.10 The two vectorizers and their remarks

LLVM has two relevant vectorizers. The **loop vectorizer** rewrites a loop to handle several iterations per pass: it needs
a loop whose iterations are independent, without early exits or per-lane addresses. The **SLP vectorizer** (superword-level
parallelism) merges *straight-line* scalar operations on neighboring data into vector operations: for example, 16 scalar
loads or stores in a kernel become vector ops with lane moves. Both estimate with a cost model ([section 4.2](#42-inlining-and-its-cost-model)) whether the
vector form pays, and Swift has no loop pragma (a source annotation that would force the choice) to override it.
<!-- src: Bytes/OPTIMIZATION.md (old) §7 table ("Two 64-bit lanes: LLVM's cost model ... Swift has no loop pragma"); AGENTS.md "Vectorize independent work, not a dependent chain" (SLP turns a scalar kernel's 16 loads or stores into vector ops with lane moves); AGENTS.md "Tools/remarks" (passes slp-vectorizer, licm) -->

`Tools/remarks` asks Swift's LLVM why. Typical answers: "Cannot vectorize early exit loop" (usually a bounds-check trap),
and "loop control flow is not understood" (branches in the body). The second is often caused by LLVM's **jump
threading**, a pass that turns correlated `if`s into direct jumps between their outcomes.
<!-- src: AGENTS.md "Tools/remarks" description -->

A probe of the early-exit case, `for b in s where b == 0 { return true }`:

```asm
<L0>:                                   ; one byte per iteration
  ldrb  w10, [x0], #0x1                 ; load a byte; pointer += 1
  cmp   w10, #0x0                       ; is it zero?
  cset  w8, eq                          ; the answer so far: 1 if the byte is zero
  cmp   w10, #0x0                       ; the same test again, for the exit condition
  ccmp  x9, #0x0, #0x4, ne              ; keep going only if (byte != 0) AND (count remaining != 0)
  sub   x9, x9, #0x1                    ; count -= 1
  b.ne  <L0>                            ; next byte
```

<!-- src: scratchpad probe a.swift `firstNonzero` -->

The loop leaves when it finds a zero, so it must examine bytes in order: scalar, 7 instructions per byte. The fix, in
Bytes, is explicit SIMD that tests 16 bytes per step (Part II, ["Scanning and shuffles: `ByteLanes`, `ByteMatches`,
`GroupShuffle`, `CBytesNEON`"](#7-scanning-and-shuffles-bytelanes-bytematches-groupshuffle-cbytesneon)), and the zip signature search that uses it is 15x faster (34 µs to 2.3 µs for 64 KB).
<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): BytesBenchmarks rows "Search 64 KB backwards: RawSpan.load per offset" 33,983 ns and ": lastByteOffset(of:)" 2,293 ns (14.8x); Bytes/OPTIMIZATION.md (old) §8 "Searching 16 positions at once" -->

### 5. Measuring

Every claim about speed in this document rests on a measurement, and the measurement habits matter as much as the
techniques. The ground rules from the repository: *measure, don't assume* (every optimization claim gets a benchmark
baseline before and after), and *check the machine code, not just the timing*.
<!-- src: AGENTS.md "Ground rules" first two bullets -->

#### 5.1 Instructions, cycles, and time

Three quantities, three roles:

- **Time** is what users feel, but it drifts: single-core times move 5–10% between runs minutes apart, up to 10% between
  days (unchanged controls such as Foundation's encoder move too), and transfers vary ±20%. Memory-bound runs were
  worse: one switched between two levels about 20% apart (about 2,250 and 2,760 µs), unchanged code and `memset`
  included.
  <!-- src: AGENTS.md "Compare times only within one interleaved run"; Bytes/OPTIMIZATION.md (old) §2 "Compare times only within one interleaved run" (2,250 and 2,760 µs) -->
- **Instructions** are deterministic for single-threaded work: a run with far fewer iterations gives a p50 (the median)
  within 0.3% of a 1,000-iteration run's. But counts under about 100 K per iteration vary ±10% between processes, and file-system benchmarks
  include the kernel's instructions and vary 20–40% between samples. Judge by the larger single-threaded counts.
  <!-- src: AGENTS.md "Benchmarks" bullet "Size iterations by the work" (within 0.3%) and "What one run can't tell" (±10%, 20–40%) -->
- **Cycles** (from hardware counters) show what the core was doing with its time. Set beside instructions they explain a
  mismatch: a change that cuts 20% of instructions but no time means the loop is bound by something else (latency,
  memory, one busy execution unit), which is itself information.
  <!-- src: Bytes/OPTIMIZATION.md (old) §2 "Count instructions, not just time" and "Ask the CPU"; AGENTS.md "Tools/counters" -->

Use instruction counts to judge a change and times to confirm it. On a second machine, keep both: an M1 Max core took
1.31x as long as an M3 Ultra core over 773 benchmarks with *identical* instruction counts, which is how it was known that
the same code ran on both.
<!-- src: Writeups/M1-Max-vs-M3-Ultra.md "The short version" 1 and "How the comparison was made" -->

Even instruction counts can mislead. An unchanged 3-byte-run benchmark went 104 → 78 → 104 K instructions across three
steps in code nobody touched. It was first attributed to code layout; the cause was a lazy global read inside the
measured loop ([section 4.5](#45-lazy-globals-swift_once)). Identical code also differed by a constant of about 1.3 K per iteration between two builds
of a harness. So a move under about 1% needs a second look before it is called a regression or a win.
<!-- src: Bytes/OPTIMIZATION.md (old) §2 "Track every change across every package" (104 → 78 → 104 K, "layout"; under about 1% needs a second look); AGENTS.md "No lazy globals inside a measured loop" (Bytes' "Runs: … 3-byte" rows bimodal, 78 K and 104 K, from swift_once); AGENTS.md "Old and new code in one benchmark run" (~1.3 K) -->

#### 5.2 package-benchmark and its process model

Benchmarks use [ordo-one/package-benchmark](https://github.com/ordo-one/package-benchmark): `swift package
--disable-sandbox benchmark [--filter REGEX]`, `… baseline update NAME` to save a baseline, `… baseline compare A B` or
`Tools/bench-table PKG A B` to compare. Saved baselines live in each package's `.benchmarkBaselines/`, allocation
thresholds in `Thresholds/`. It reports wall-clock time, instructions, and `malloc` counts at percentiles (p0, p25, p50,
p75, p90, p99, p100); this document's numbers are p50.
<!-- src: AGENTS.md "Repository" paragraph and "Benchmarks (ordo-one/package-benchmark)" first bullet; Tools/bench-table usage (--percentile p0 p25 p50 p75 p90 p99 p100, default p50) -->

The framework's **process model** shapes how benchmarks must be written: it starts the benchmark executable once to list the
benchmarks and again for *each* benchmark, and every start runs the whole `benchmarks` closure. That closure should only
register. Fixtures (the input data a benchmark works on) are made lazily in a benchmark's `setup:` (which runs only in
that benchmark's process, unmeasured).
Part III (["Measuring honestly"](#13-measuring-honestly)) gives what eager fixtures cost and the other rules for the measured loop.
<!-- src: AGENTS.md "A benchmark costs a few seconds at most" bullet (process model) -->

Two practical rules: every plugin invocation costs about 25 s of build, so batch filters into one invocation, and
`--filter` must match the whole benchmark name. And it prints "Build complete!" for its own tool, then builds the benchmark
targets: an edit made after that line broke a queued baseline's build, so queue every "before" baseline before the first
edit, and do not touch a package (or what it depends on) until the first result table prints.
<!-- src: AGENTS.md "Benchmarks" bullets "Every plugin invocation costs about 25 s", "--filter must match the whole benchmark name"; "One implementation each" lesson "package-benchmark prints 'Build complete!' for its tool, then builds the benchmark targets" -->

#### 5.3 Allocation gates

A workload that should not allocate gets a benchmark counting only `malloc` calls against a **threshold** file at 0: a
**gate** that fails if anything allocates. To find a source when one fails: `Tools/calls … --callee
'swift_allocObject|swift_slowAlloc|malloc'` statically, `Tools/runtime-count --break swift_allocObject` dynamically, and
`Tools/allocations` for responsible callers. The malloc interposer (the framework's replacement `malloc` that counts
calls) costs about 10% on large transfers and biases comparisons with libraries that allocate per call (Part III,
["Malloc counting biases comparisons with libraries"](#malloc-counting-biases-comparisons-with-libraries)), so allocation and timing benchmarks are kept separate. It also traps on thread exit, so benchmarks that start threads cannot
count mallocs; count them in single-threaded ones.
<!-- src: AGENTS.md "Allocations: package-benchmark's malloc counter with a Thresholds/ file at 0 is the gate"; "The malloc interposer costs ~10%" bullet; "package-benchmark's malloc interposer traps on thread exit"; Bytes/Benchmarks/RESULTS.md "Benchmark coverage pass (2026-11-19)" ("the timed configurations no longer count mallocs (the interposer biased comparisons with libraries that allocate per call") -->

Instruments' Allocations is not always enough to find a source, and the reason is worth knowing. Its export lists only the
allocations *still live* at the end of the recording, and the callers of allocations made before it attached read
"<Call stack limit reached>". Anything allocated and freed again, such as a heap box per item or a temporary array,
shows up only in the counts by size class, never with a caller. Two methods find those. LLDB breakpoints on
`swift_slowAlloc`, `malloc`, `malloc_type_malloc`, `calloc`, and `realloc`, each running `bt 14; continue`, on the
`-debuggable` release binary, then grouped by the first stack frame in the program's own code (an allocation through
`swift_slowAlloc` stops twice, so a `malloc` stop whose caller is `swift_slowAlloc` is dropped). Or **`Tools/allocations
--history`**, which runs the program under LLDB with **malloc stack logging in full mode** (`MallocStackLoggingNoCompact`:
every event recorded with its stack, where the default lite mode keeps only live allocations), stops at `exit`, dumps the
events with `malloc_history -allEvents`, and groups every allocation by the innermost frame of the program's own image.
Full mode changes what it measures: libobjc then gives each autorelease pool push a fresh 4 KiB page, and Swift
Concurrency pushes a pool per job on Darwin, so those pages, which a normal run does not allocate, are left out and
counted separately. Use full mode to find *where* allocations come from, and a benchmark's malloc counter or a
breakpoint count to say *how many* there are.
The first use traced a whole NativeAEA extraction (30,363 entries, 189 segments, about 40 s under the debugger): 7,364
heap allocations in the process, none per file, and the two that grew with the data were both found this way (Part III,
["Technique 9"](#technique-9-a-var-pointer-borrowed-by-spans-is-heap-boxed)).
<!-- src: Tools/allocations --help (Instruments' export lists live allocations only; "<Call stack limit reached>"; --history, MallocStackLoggingNoCompact, malloc_history -allEvents, autorelease pool pages left out); NativeAEA/RESULTS.md "2026-11-22, evening: allocations in an extraction, traced" "Method" and "What it found" (the breakpoint list and `bt 14; continue`; 189 segments, 30,363 entries, "about 40 s under the debugger"; "7,364 heap allocations in the whole process … none per file") -->

**`Tools/untracked`** is the other process-level trap this repository met. A session started from a downloaded terminal
is tracked by the kernel, which then owns `com.apple.provenance` on everything the session creates, so a test that
restores that attribute never reads back its own value; `Tools/untracked -- COMMAND` runs the command as a `launchctl`
job outside the tracked process tree.
<!-- src: AGENTS.md "Tools/untracked"; NativeZipArchive/Benchmarks/RESULTS.md "2026-11-21 (later)" parenthetical (2026-11-22) ("in a session macOS tracks, the kernel puts it on everything made, references included") -->

#### 5.4 Interleaved A/B runs

To verify a timing change: extract the old code (`git archive <commit> Pkg Bytes … | tar -x -C "$SCRATCH/old"`), build
both, and alternate old and new runs (`baseline update ab-old-1`, `ab-new-1`, `ab-old-2`, …), then compare round by round.
A regression that showed in both rounds of one comparison vanished in three more alternating runs. For parallel changes,
compare old and new in one process. One `concurrentPerform` per call, with workers taking the next chunk, was 8–22%
faster than two rounds of one chunk per lane (parallel worker) and 22–41% faster than four, measured interleaved; across
benchmark runs those rows swing 10–30%.
<!-- src: AGENTS.md "Compare times only within one interleaved run" and "Parallel compression: avoid rounds"; Bytes/OPTIMIZATION.md (old) §2 (regression vanished in three more alternating runs) -->

Sharing a function misleads too. When a new path and its reference sat in one function behind a run-time flag, changing
the new path moved the reference's register allocation, and the unchanged reference went 70 → 102 K instructions. So
variants compared in one run each get their own `@inline(never)` function over a shared `@inline(__always)` body.
<!-- src: AGENTS.md "Old and new code in one benchmark run" (70 → 102 K) -->

#### 5.5 The tools in `Tools/`, one example each

All tools share conventions: `--help` prints usage; results on stdout, tab-separated where tabular (pipe to `column -t -s
$'\t'`); notes on stderr; exit 0 success, 1 a check failed, 2 bad usage or missing dependency. Xcode tools are found with
`xcrun`, so `TOOLCHAINS=<bundle id>` switches the toolchain for every tool. `Tools/doctor` reports the machine's CPU,
toolchains, and tools.
<!-- src: AGENTS.md "Start here" -->

**Static: what the compiler produced.**

- **`Tools/loops`** finds each loop in matching functions, with its size, depth, mix, and a verdict (`vector128`,
  `vector64`, `scalar`, `+lane-moves`, `+calls`). With `--require`/`--forbid` it is an assertion:
  `Tools/loops --target Bytes BytesBase64 encodeBlocks --require tbl,zip --forbid mov.b,ins` fails (exit 1) if the
  Base64 kernel lost its `tbl`/`zip` or grew lane inserts. PATTERN is a regex on demangled names without parameter types:
  anchor it or overloads match too.
  <!-- src: AGENTS.md "Tools/loops" description and its two examples; RESULTS-base64.md line 15 -->
- **`Tools/remarks`** shows Swift's own LLVM optimization remarks: loops vectorized (with width) or not, and why;
  `--passes` selects others (`sil-inliner`, `sil-generic-specializer`, `inline`, `slp-vectorizer`, `licm`).
  <!-- src: AGENTS.md "Tools/remarks" -->
- **`Tools/calls`** lists static call sites per caller and callee (demangled), from relocations in objects: *"is
  `swift_retain` still called from the hot function?"*; `--callee 'SIMD.init'` finds the vector-literal trap.
  <!-- src: AGENTS.md "Tools/calls"; AGENTS.md "Constant vectors" lesson (Check new kernels with Tools/calls … --callee 'SIMD.init') -->
- **`Tools/sil-trace`** and **`Tools/swiftc-target`** ([section 4.1](#41-the-pipeline-sil-then-llvm)).
- **`Tools/mca`** runs `llvm-mca` (LLVM's static throughput model) on a loop for a throughput bound. Treat it as a lower
  bound only: LLVM's Apple models derive from Cyclone, an early Apple core (every `tbl` is one micro-op whatever its
  table count). It predicted 7.7 cycles per 48 bytes for two Base64 kernels measured at 9.1 and 8.4.
  <!-- src: AGENTS.md "Tools/mca" -->
- **`Tools/bn`** drives the MCP server built into Binary Ninja (a disassembler) for intermediate-language (IL) views of
  loops, with NEON shown as intrinsics (`vqtbl3q_s8`, `vzip1q_s8`). It complements the scripts and needs the app
  running.
  <!-- src: AGENTS.md "Tools/bn" and "Binary Ninja MCP" assessment -->

**Dynamic: what the program did.**

- **`Tools/counters`** uses Instruments' CPU Counters through `xctrace` (no `sudo`). The default `bottlenecks` mode gives
  the share of cycles useful, discarded, front-end-delivery-limited, and back-end-processing-limited;
  `simd_fp_unit_instructions` counts SIMD work, the run-time proof of vectorization: Base64's driver executed 18.5 G SIMD
  ops, its scalar variant 0.
  <!-- src: AGENTS.md "Tools/counters"; Bytes/OPTIMIZATION.md (old) §2 point 4 (18.5 billion; zero) -->
- **`Tools/profile`** is a Time Profiler run symbolicated from a dSYM (the debug-symbol bundle `dsymutil` makes), so
  leaf frames include *inlined* functions: in
  Base64, `bytes_interleave4` took 39% inside `encodeBlocks`. **`Tools/sample-top`** uses macOS `sample` for per-thread
  stacks of a live process.
  <!-- src: AGENTS.md "Tools/profile", "Tools/sample-top" -->
- **`Tools/runtime-count`** uses LLDB breakpoints that count and continue (`swift_task_switch`, `swift_allocObject`,
  `malloc`, `swift_retain`); each hit costs tens of µs and perturbs timing, so run two workload sizes to separate
  per-iteration from fixed counts. `--who swift_task_switch=x0` tallies which async function switched. In NativeAEA,
  marking internal async functions `nonisolated(nonsending)` (which keeps an async function on its caller's executor;
  [Part IV](#part-iv-concurrency-and-further-reading)) took checks from 21,374 to 1,467–1,481 for 1,001 files (the two records differ).
  <!-- src: AGENTS.md "Tools/runtime-count" and "Threads to structured concurrency" bullet 1 -->
- **`Tools/tasks`** uses Instruments' Swift Concurrency template: per task, its runs, threads, thread and actor switches
  (real hops), continuation waits, and the wait from runnable to running. It records moves but not executor checks, so
  pair it with `Tools/runtime-count`.
  <!-- src: AGENTS.md "Tools/tasks" -->
- **`Tools/allocations`** uses Instruments' Allocations (counts by size class, then by responsible caller) when a malloc
  threshold fails. It sees only allocations still live at the end; `--history` runs the program under LLDB with malloc
  stack logging in full mode to find the ones freed again ([section 5.3](#53-allocation-gates)).
  <!-- src: AGENTS.md "Tools/allocations"; Tools/allocations --help -->
- **`Tools/bench-table`** puts baselines side by side with change, units normalized (counts unscaled, times in µs).
  <!-- src: AGENTS.md "Tools/bench-table" -->
- **`Tools/socket-ceiling`** measures the kernel's local-socket throughput with blocking C sockets on plain threads, the
  ceiling for networking benchmarks (SocketStream's transfers reach most of it).
  <!-- src: AGENTS.md "Tools/socket-ceiling" -->
- **`Tools/cpu-probe`** measures what one core can do, in C and inline assembly: the clock, instruction latency and
  throughput in cycles, load-to-use latency by working set, and read/store bandwidth by thread count. The M1 Max numbers
  in this document ([section 1](#1-how-a-modern-cpu-runs-your-code)) come from it.
  <!-- src: AGENTS.md "Tools/cpu-probe" -->

Anything that attaches to a process (Instruments' Allocations, `lldb`, `sample`) needs the target signed with the
`com.apple.security.get-task-allow` entitlement; the tools that launch programs run a copy, `PROGRAM-debuggable`, signed
that way. Attaching also needs an authorization the first time, which shows a prompt the user may not see. When a tool
hangs or fails to attach, the prompt is the first suspect.
<!-- src: AGENTS.md "Programs you launch get get-task-allow; prompts need the user" -->

#### 5.6 The workflow in one pass

The repository's own recipe, which this document follows throughout:

1. Benchmark the package; save a baseline.
2. Find the hot loop's machine code with `Tools/loops`.
3. If it did not vectorize, ask the compiler why (`Tools/remarks`).
4. If something is called that should not be (retain/release, outlined destroy, `swift_task_switch`, unspecialized
   generics), find it with `Tools/calls`, and the pass that left it with `Tools/sil-trace`.
5. Estimate the loop's throughput bound with `Tools/mca`; measure what the CPU did with `Tools/counters`; find time per
   function with `Tools/profile`.
6. Count runtime events (hops, allocations) with `Tools/runtime-count`; explain allocations with `Tools/allocations`.
7. Re-benchmark, save a new baseline, `Tools/bench-table PKG old new`, and record it.
<!-- src: AGENTS.md "The workflow" -->

#### 5.7 Two habits that paid for themselves

**Check a new API's code from another module.** Clients see only what is inlinable, so the proof that an abstraction is
free is a throwaway package depending on the library, with `@inline(never)` probe functions beside hand-written
equivalents, compiled and disassembled. LLVM merges identical functions, so "the two probes became one symbol" is the check.
Named bit fields passed it; a `BitPattern` literal passed it only after both its initializers got `@inline(__always)`
(otherwise a run-time parse of the pattern string per call).
<!-- src: AGENTS.md "Check a new API's codegen from another module" -->

**Track every change across every package.** Bytes' clients each keep a benchmark baseline. A change that helped the
library's own benchmarks moved a client by 10%, and one move of code between modules cost 1.3–1.7% on small Brotli streams
where nothing else changed. Neither shows up if only the edited code is benchmarked. Part III (["Measuring honestly"](#13-measuring-honestly)) returns
to this.
<!-- src: Bytes/OPTIMIZATION.md (old) §2 "Track every change across every package" -->

## Part II. The Bytes toolkit, bottom-up

[Part I](#part-i-foundations) explains what the CPU and the compiler do with your code. This part walks through the library built around those
facts, from the lowest layer (borrowed memory) up to the codecs, the crypto entry points, and the macros. Each section
says what a piece is, shows a small example with real API names, explains why it is fast (what the compiler can prove,
what code comes out, what it costs), and quotes the measurement that justified it. "Measured" always means the Apple M3
Ultra unless a sentence says M1 Max. Sections that name a technique in passing leave its full treatment to Part III
(["Techniques, by problem"](#part-iii-techniques-by-problem)).

### 1. Borrowed memory: spans and `InlineArray`

Everything in Bytes reads from, or writes into, memory that somebody else owns. The types that express that are recent
standard-library types (the library is written for Swift 6.4), and its design is mostly a consequence of how they work.

#### The family

A **span** is a view of contiguous memory: conceptually a pointer and a count, plus a promise from the compiler that the
memory stays valid for as long as the view is used. <!-- src: Bytes/OPTIMIZATION.md (old version) §3 "A small struct of plain values: a RawSpan (pointer and count)"; Bytes/Sources/Bytes/Lending.swift RawSpan(_unsafeBytes:) -->
The family:

| Type | What it is | Bytes uses it for |
|---|---|---|
| `Span<T>` | read-only view of `T`s | typed views of input (`read(_:count:)`), tables |
| `RawSpan` | read-only view of bytes, no element type | the input of every reader, checksum, and codec |
| `MutableSpan<T>` | writable view, exclusive | typed output (`write(_:count:filling:)`) |
| `MutableRawSpan` | writable view of bytes, exclusive | the output of every writer; in-place ciphers |
| `OutputSpan<T>`, `OutputRawSpan` | a buffer's capacity plus a count of how much is initialized | appending output into new memory |
| `InlineArray<N, T>` | `N` elements stored in place, no heap block | fixed records, blocks, tables |

<!-- src: Bytes/Sources/Bytes/Buffers.swift, BytesReader.swift, BytesWriter.swift (the types appear in these signatures); Bytes/Sources/Bytes/Bytes.docc/Bytes.md overview -->

An **output span** is the interesting one. A `MutableRawSpan` covers memory that already holds bytes. An `OutputRawSpan`
covers memory that may hold garbage, together with a count of the bytes that have been written so far. Appending moves the
count. This is why Bytes can build a new array without first filling it with zeros: the writer stores into the
array's spare capacity, and only the bytes it reports writing are committed. <!-- src: Bytes/OPTIMIZATION.md (old version) §4 "BytesWriter: writes into … an OutputSpan's uninitialized capacity so new buffers aren't zero-filled first"; Bytes/Sources/Bytes/BytesWriter.swift withBytesWriter -->

```swift
// An array of exactly the bytes written, with no zero-fill and one allocation.
let bytes = try [UInt8](byteCapacity: 64) { (writer) throws(BytesError) in
    try writer.write(0x504B_0304 as Byte4)     // 4 bytes
    try writer.write(Byte(7))                  // 1 byte
}
// bytes.count == 5, whatever the capacity was
```

#### `~Escapable`: the compiler checks the lifetime

The span family is **non-escapable** (`~Escapable`): a value of such a type can't be stored in a class or a global,
captured by an escaping closure, or returned from a function, unless the function declares whose lifetime it
borrows. The declaration is `@_lifetime(...)`. That is how the compiler can promise that a span never outlives its memory,
with no reference count and no runtime check. <!-- src: Bytes/Sources/Bytes/Buffers.swift ByteBuffer.unread `@_lifetime(borrow self)`; Bytes/Sources/Bytes/BytesReader.swift init `@_lifetime(copy span)`; Bytes/Package.swift comment "`@_lifetime`: `Bytes` is `~Escapable` and hands out spans that borrow the memory it reads" -->

Bytes leans on it everywhere. A cursor (`BytesReader`, [section 3](#3-cursors-bytesreader-byteswriter-and-their-modes)) is itself non-escapable and non-copyable (`~Copyable`:
a value with one owner, which can be moved but not copied), and everything it hands out is a view of the same memory:

```swift
// The result views the same memory as `data` and may live as long as that memory does.
// (Needs the `Lifetimes` experimental feature.)
@_lifetime(copy data)
func payload(of data: RawSpan) throws(BytesError) -> RawSpan {
    var reader = BigEndianBytesReader(data)
    try reader.skip(byteCount: 4)           // a 4-byte header
    return reader.readRemainingBytes()      // a RawSpan of the same memory: no copy
}
```

The `copy` in `@_lifetime(copy data)` copies a *lifetime dependence*, not bytes. `data` is itself non-escapable: it
carries the lifetime of the memory it views. `copy data` says the result inherits that same lifetime, so a caller can
keep the returned span for as long as the memory lives, after `data`'s own variable has gone. The other form, `@_lifetime(borrow x)`,
says the result borrows the value `x` itself and stays valid only while `x` does. That's the form for a source that
owns its memory rather than viewing it: an `Array`'s `span` and a `ByteBuffer`'s `unread` are `@_lifetime(borrow self)`.
For a span parameter, `borrow data` would tie the result to the caller's `data` variable instead of to the memory
behind it, a narrower promise than the function can make. Neither form generates any code; both are checked at compile
time. <!-- src: Bytes/Sources/Bytes/BytesReader.swift init `@_lifetime(copy span)`, readRemainingBytes `@_lifetime(copy self)`; Bytes/Sources/Bytes/Buffers.swift ByteBuffer.unread `@_lifetime(borrow self)`; Swift's Lifetimes feature (SE-0446 non-escapable types; the lifetime dependency annotations) -->

<!-- src: Bytes/Sources/Bytes/BytesReader.swift readRemainingBytes (`@_lifetime(copy self)`), skip(byteCount:); Bytes/Sources/Bytes/Bytes.docc/WritingParsers.md "Parse" (the `@_lifetime` and `Lifetimes` note) -->

Because parsed values are views, a parser allocates nothing. MQTT's PUBLISH packet keeps its topic as a `UTF8Span` (a span of validated UTF-8) and its
payload as a `RawSpan`. <!-- src: Bytes/OPTIMIZATION.md (old version) §3 "Parsed values are views of the input" --> Against conventional MQTT parsing into `[UInt8]` and `String`, parsing every field and property
through views takes 1/8.6 of the time on one core and 1/18.6 on all cores, where the conventional code's allocations (3–4
per packet) contend in the allocator. <!-- src: MQTT/Benchmarks/RESULTS.md "The views against the conventional code" (Conventional parse / views parse: 8.6x one core, 18.6x all cores, M3 Ultra) and "Against the conventional code" (3–4 allocations per packet) -->

#### Why spans, and not `Data`, `[UInt8]` slices, or pointers

- **Against owning containers.** A parser that returns `[UInt8]` and `String` has to allocate and copy for every field it
  keeps. The conventional MQTT parse allocates 3–4 times per packet, and copying out of the views (2 allocations per
  packet) "scales about as badly". <!-- src: MQTT/Benchmarks/RESULTS.md "Against the conventional code" -->
  A span is never an owner, so handing one out costs nothing and holds nothing alive.
- **Against raw pointers.** An `UnsafeRawPointer` has no length, so every access is on the programmer. A span has a
  length, and the standard library's loads check it. Bytes goes one step further and reads through unchecked loads
  *behind its own single check*, confined to a handful of functions, each with a comment saying why it is safe ([section 3](#3-cursors-bytesreader-byteswriter-and-their-modes)
  explains the check). <!-- src: Bytes/Benchmarks/RESULTS.md "Safe constructs instead of unsafe ones" ("Kept unsafe (each with a comment saying why it is safe)"); Bytes/Sources/Bytes/BytesReader.swift `enum Load` doc comment -->
- **Against `Data`.** `Data` already has a `bytes` view, but no way to append a span or start from one; that is the
  entire content of the `BytesFoundation` module ([section 13](#13-bytesbase64-and-bytesfoundation)). <!-- src: Bytes/Sources/BytesFoundation/Data.swift header comment -->

The one thing a span cannot do is cross threads (it is non-escapable, so no task or closure that outlives the call can
capture it). Parallel code gets the same memory through *lending*, covered in [section 9](#9-buffers-and-moving-bytes).

#### `InlineArray`: fixed-size storage in place

`InlineArray<N, T>` stores exactly `N` elements inline, in the value that holds it: no allocation, no reference count.
Bytes uses it for blocks (`InlineArray<48, UInt8>` is one Base64 input block), for the raw bytes of custom types
(`ByteRepresentable`, [section 2](#2-byte-sized-value-types-bits-byte2byte16-byte-order-ascii-tags)), and for small tables. <!-- src: Bytes/Sources/BytesBase64/Base64.swift encodeBlocks signature; Bytes/Sources/Bytes/ByteRepresentable.swift doc comment -->

It has one trap. Indexing an `InlineArray` that is a stored property or a `borrowing` parameter can copy the whole array
for each access. The Zstandard decoder's FSE (finite state entropy) table builder read a 256-entry `InlineArray<256, Int16>` passed `borrowing`;
every subscript copied its 512 bytes (a `memmove`), 16,000 copies per 4 KB frame, 22% of the decode's time. <!-- src: AGENTS.md Lessons "InlineArray passed borrowing can be copied at every subscript"; Bytes/Benchmarks/RESULTS.md "Zstandard decoding … How it got there" -->
The DEFLATE block writer had the same problem with a 1.4 KB array per literal. <!-- src: Bytes/OPTIMIZATION.md (old version) §12 "Indexing an InlineArray field of a struct value" (1.4 KB memmove per literal, 2.8x slower) --> The fix is to take a span once and
index that:

```swift
// Slow: each `table[i]` may copy all 256 entries first.
func total(_ table: borrowing InlineArray<256, Int16>) -> Int {
    var sum = 0
    for i in 0..<256 { sum += Int(table[i]) }
    return sum
}

// Fast: one view, then ordinary indexing.
func total(_ table: borrowing InlineArray<256, Int16>) -> Int {
    let view = table.span
    var sum = 0
    for i in view.indices { sum += Int(view[i]) }
    return sum
}
```

(For hot tables, the Zstandard decoder goes further: it keeps them in raw memory the decoder owns, indexed through a
pointer, with the safety argument in a comment. <!-- src: AGENTS.md Lessons "Hot tables go in raw memory the decoder owns (a workspace)" -->)

#### Typed spans of blocks: one bounds check for the whole loop

A bounds check inside a loop is a compare and a branch per access, and an early exit stops the vectorizer. If the input is
viewed as a `Span` of *blocks*, the loop index comes from `blocks.indices`, so it is provably in range, and one comparison
of the two spans' counts before the loop covers every store. Base64's encoder is built this way:

```swift
// Input: Span<InlineArray<48, UInt8>>.  Output: MutableSpan<InlineArray<64, UInt8>>.
precondition(output.count == blocks.count)       // the only check
for block in blocks.indices {
    output[block] = encodeBlock(blocks[block], table: table)
}
```

<!-- src: Bytes/Sources/BytesBase64/Base64.swift encodeBlocks -->
The previous version loaded three vectors per block at byte offsets from a `RawSpan` and stored four. Each access was
checked, 14 of the loop's 45 instructions. <!-- src: Bytes/Benchmarks/RESULTS-base64.md "How it got here" ("checked each access: 14 of 45 instructions") --> The typed-span form cut instructions from 5.0 M to 2.2 M per 4 MB of input. Throughput did not move
(from 19.1 to 18.9 GB/s), because the loop was bound by its table lookups, not by the checks. <!-- src: Bytes/Benchmarks/RESULTS-base64.md "How it got here" table (rows `tbl` and `tbl-spans`) --> [Section 13](#13-bytesbase64-and-bytesfoundation) shows the machine code, where the
single check is the first three instructions of the function.

#### When not to use it

A typed `Span` over `InlineArray<N, UInt8>` elements loads each element through the span's subscript as a byte aggregate,
and LLVM merges those byte loads only for 4-byte elements. Iterating a zero-copy span of 4-byte elements runs at memory
speed (104 GB/s in cache, 75 GB/s from memory); for 6-byte elements it reached 17 GB/s against 35 GB/s for `forEach`,
and for 16-byte elements 32 GB/s against 103 GB/s. <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final), 4 MiB in cache: BytesBenchmarks rows "Zero-copy: for-in Span<InlineArray<4, UInt8>>" 40,479 ns (104 GB/s), "Zero-copy: for-in Span<InlineArray<6, UInt8>> (MAC bytes)" 251,647 ns (16.7), "MAC: forEach(Byte6.self), raw bytes (reference)" 119,551 (35.1), "Zero-copy: for-in Span<InlineArray<16, UInt8>> (IPv6 bytes)" 130,175 (32.2), "IPv6: forEach(Byte16.self), raw bytes (reference)" 40,799 (103); from memory: "Bandwidth: Byte4, memory (512 MB), 1 core" 7,139,327 ns for 512 MiB (75.2 GB/s); the 6- and 16-byte memory columns are not in the new run --> Bytes loads its own groups as a same-size integer
and `bitCast`s, which is why `forEach` ([section 3](#3-cursors-bytesreader-byteswriter-and-their-modes)) is the path that is at raw speed for every size.

### 2. Byte-sized value types: `Bits`, `Byte2`…`Byte16`, byte order, ASCII tags

Binary formats are made of widths the standard library has no types for: 3 bits, 24 bits, 6 bytes. Bytes gives each a
type, and the point of the types is to give the compiler a constant.

#### `Bits<width>`: 1 to 8 bits

`Bits<let width: Int>` is a value of 1 through 8 bits held in one `UInt8`. Its width is an *integer generic parameter*
(SE-0452), so it is a compile-time constant: masks and shifts become immediates (constants encoded in the
instruction), and range checks fold away. The aliases
are `Bit` (1), `Crumb` (2), `Nibble` (4), and `Byte` (8; the type of a flags byte). <!-- src: Bytes/Sources/Bytes/Bits.swift (struct Bits<let width: Int>, typealiases); Bytes/OPTIMIZATION.md (old version) §4 "Bits<let width: Int>" -->

```swift
var flags: Byte = 0b1010_0000
flags[bit: 0] = true                 // 0b1010_0001
flags.toggleBit(at: 7)               // 0b0010_0001
let type = flags.highHalf            // a Nibble: 0b0010
flags.lowHalf = 0b1111               // 0b0010_1111
let version: Nibble = "0100"         // a binary string literal
```

<!-- src: Bytes/Sources/Bytes/Bits.swift doc comment example -->
They compile to what you would write by hand: setting a nibble half is an `and` and an `orr`, setting a bit one `orr`,
toggling one `eor`. <!-- src: Bytes/Benchmarks/RESULTS.md "Convenience APIs" -->

#### `Byte2`…`Byte16`: N bytes, as they appear in memory

A **byte group** (`Byte2` through `Byte16`, protocol `ByteGroup`) is N consecutive bytes, with *no byte order applied*. It
is stored in the narrowest unsigned integer that holds N bytes: `Byte3` in a `UInt32`, `Byte5`–`Byte7` in a `UInt64`,
`Byte9`–`Byte16` in a `UInt128`. <!-- src: Bytes/Sources/Bytes/ByteGroup.swift `public let littleEndian: UInt32` etc. for Byte3, Byte5, Byte16 -->
The integer holds the bytes as a little-endian number, so the first byte in memory is the least significant:

```swift
let length = try reader.read(Byte3.self, .bigEndian)       // a UInt32 holding a 24-bit big-endian length
let signature: Byte4 = 0x50_4B_03_04                        // the bytes 50 4B 03 04, as a hex dump shows them
let masked = payload ^ maskingKey                           // Byte4 ^ Byte4: byte-wise, no byte order involved
```

<!-- src: Bytes/Sources/Bytes/ByteGroup.swift doc comments (literal digits are the bytes in memory order; `^ & | ~` are byte-wise) -->

Why the representation is fast:

- **A read is one load.** On a little-endian CPU the integer *is* the loaded bytes. An odd width (3, 5, 6, 7) uses two
  overlapping loads that never read past the value (bytes 0–1 and 1–2 for a `Byte3`), combined with a shift. <!-- src: Bytes/OPTIMIZATION.md (old version) §4 "Byte2 … Byte16" and §7 "Odd widths with overlapping loads" -->
- **A byte-order conversion is a byte swap**, one instruction (`rev`), and for 9–16 bytes it is computed on two 64-bit
  halves, because LLVM does not vectorize 128-bit arithmetic. <!-- src: Bytes/Sources/Bytes/ByteGroup.swift `extension ByteGroup where Integer == UInt128 { var bigEndian }` doc comment -->
- **Literals fold.** Write the digits in memory order. A `static let signature: Byte4 = 0x50_4B_01_02` is a lazily
  initialized global if the compiler cannot evaluate its initializer at compile time, and every use then checks a
  `swift_once` flag. The first version of the literal initializer used `init(bigEndian:)`, whose byte swap the
  compile-time evaluator cannot fold, and parsing zip records with such a constant took 41% more instructions (281 K
  against 199 K). The current initializer reverses the bytes with shifts, which fold. <!-- src: Bytes/Benchmarks/RESULTS.md "Integer literals for byte groups" --> An initializer call that
  byte-swaps still cannot fold:

```swift
static let signature: Byte4 = 0x50_4B_01_02              // folded into the code
static let signature = Byte4(0x504B_0102, .bigEndian)    // a byte swap: swift_once on every use
```

<!-- src: Bytes/Benchmarks/RESULTS.md "Integer literals for byte groups" ("`static let signature = Byte4(0x504B_0102, .bigEndian)` compiles to the `swift_once` check again") -->

- **Byte-wise operators need no order.** `^`, `&`, `|`, and `~` work byte by byte in memory order, so they cannot be
  ambiguous the way a shift of a group would be ("shift by a byte" depends on which end is first). There are deliberately no
  shifts; the byte subscript and `lowHalf`/`highHalf` say which byte is meant. <!-- src: Bytes/Benchmarks/RESULTS.md "Group operations: ByteGroup operators …" -->
- **A vector view.** `Byte16.vector` turns a group into a `SIMD16<UInt8>` with a bit cast and no instructions, which
  matters for building constant vectors ([section 7](#7-scanning-and-shuffles-bytelanes-bytematches-groupshuffle-cbytesneon)). <!-- src: Bytes/Sources/Bytes/ByteGroup.swift Byte16.vector doc comment -->

#### ASCII tags

File formats label things with ASCII text: PNG's `IHDR`, QOI's `qoif`. `Byte4(ascii: "IHDR")` builds the group from a
`StaticString`, and inlined it folds to the hex constant `0x49_48_44_52`. When the benchmark compared 20,000 chunk-type
tests written both ways, LLVM merged the two functions into one: the instruction counts and times were identical (524 K
instructions, 36 µs). <!-- src: Bytes/Benchmarks/RESULTS.md "ASCII without tricks" table row 1 -->

```swift
switch try reader.read(Byte4.self) {
case Byte4(ascii: "IHDR"): …
case Byte4(ascii: "IEND"): …
default: …
}
```

<!-- src: Bytes/Sources/Bytes/ASCII.swift ByteGroup.init(ascii:) doc comment -->
Use it where it is evaluated, or in a computed property: a `static let` initialized with it is lazily initialized for the
same reason as above. <!-- src: Bytes/Sources/Bytes/ASCII.swift init(ascii:) doc comment -->

#### `ByteRepresentable`: your own fixed-size types

A type such as an IPv4 address is 4 bytes with a name. Conform it to `ByteRepresentable` by exposing its bytes as an
`InlineArray<N, UInt8>`:

```swift
struct IPv4Address: ByteRepresentable {
    var rawBytes: InlineArray<4, UInt8>
    init(rawBytes: InlineArray<4, UInt8>) { self.rawBytes = rawBytes }
}
let address = try reader.read(IPv4Address.self)
```

<!-- src: Bytes/Sources/Bytes/ByteRepresentable.swift doc comment -->

The library needs its own protocol because the standard library's `ConvertibleFromBytes` ("any bit pattern is a valid
value") is closed to user types: in Swift 6.4 only standard-library types may conform to it, so a user type cannot be
loaded from raw memory directly. The protocol's associated `RawBytes` (an `InlineArray` of bytes) *can* be, and
`init(rawBytes:)` then compiles away when it only stores its argument. <!-- src: Bytes/Sources/Bytes/ByteRepresentable.swift doc comment; Bytes/Benchmarks/RESULTS.md "Custom byte-backed types" -->

The load itself is chosen with care. Loading an `InlineArray<4, UInt8>` as itself compiles to four `ldrb`s and repacking;
loading it as a `UInt32` and reinterpreting with `bitCast` is one `ldr`. So sizes 1, 2, 4, 8, and 16 go through the
same-size integer. <!-- src: Bytes/Benchmarks/RESULTS.md "Custom byte-backed types" --> Measured on one core (GB/s, in cache / from memory):

| Reading IPv4 addresses | GB/s |
|---|---|
| `forEach(IPv4Address.self)` | 111 / 78 |
| a loop of `read(IPv4Address.self)` | 110 / 78 |
| naive: four `read(Byte.self)` into an `InlineArray` | 3.4 / 3.7 |

<!-- src: Bytes/Benchmarks/RESULTS.md "Custom byte-backed types" table (from-memory column not in the new run); in-cache column "2026-11-20, M3 Ultra" (baseline m3-final): BytesBenchmarks rows "IPv4: forEach(IPv4Address.self)" 37,855 ns, "IPv4: read(IPv4Address.self) per value" 38,047, "IPv4: naive, 4 × read(Byte.self) per value" 1,234,943, each 4 MiB -->
A custom type parses at the speed of its raw bytes, and the 4-, 8-, and 16-byte ones at memory speed. <!-- src: Bytes/Benchmarks/RESULTS.md "Custom byte-backed types" last line -->

#### Byte order

**Byte order** (endianness) is whether a multi-byte integer is stored least-significant byte first (little-endian, as on
Apple's CPUs) or most-significant first (big-endian, as in most network protocols). Converting is one byte swap. The
interesting design question is *where the order lives*. Bytes has three answers, in increasing order of commitment:

1. an argument at each call: `read(Byte4.self, .bigEndian)`;
2. a type: `BigEndianBytesReader` reads integers by type with no argument ([section 3](#3-cursors-bytesreader-byteswriter-and-their-modes));
3. a generic parameter: a record parsed by code generic over `Mode: ByteOrderedCursorMode`, specialized once per order
   ([section 5](#5-structure-sections-length-prefixes-leb128-records-text-dates)), for formats such as ELF and PCAPNG that name their byte order in their first bytes.

The order is a constant after specialization in the second and third forms, so the generated code equals the explicit
form. This matters most for a format whose order is chosen at run time. Apple's `swift-binary-parsing` examples pass an
`Endianness` value to every read, which becomes an out-of-line call (52 instructions) with its own throw path per field.
The Bytes port decides once and calls a parser specialized for each order (a section header: 277 instructions with 13
such calls, against 87 or 93). <!-- src: Bytes/OPTIMIZATION.md (old version) §10 "swift-binary-parsing's examples … The main gap is the byte order, chosen at run time"; BinaryParsingComparison/RESULTS.md -->

### 3. Cursors: `BytesReader`, `BytesWriter`, and their modes

A **cursor** is a small value that remembers a position in a span and reads or writes fields in order. Cursors are where
most of the library's attention to the compiler went.

#### One implementation, four kinds

`GenericBytesReader<Mode>` and `GenericBytesWriter<Mode>` are written once and specialized by a *mode*, a type that
conforms to `BytesCursorMode`. The names you normally write are typealiases:

| Name | Mode | What it adds or removes |
|---|---|---|
| `BytesReader`, `BytesWriter` | `BitAddressable` | fields of any bit width at any bit position |
| `AlignedBytesReader`, `AlignedBytesWriter` | `ByteAligned` | whole bytes only; the bit offset is the constant 0; an explicit byte order at each integer |
| `BigEndianBytesReader`/`Writer` | `BigEndianBytes` | whole bytes, integers read and written by type, big-endian |
| `LittleEndianBytesReader`/`Writer` | `LittleEndianBytes` | the same, little-endian |

<!-- src: Bytes/Sources/Bytes/CursorMode.swift; Bytes/Sources/Bytes/BytesReader.swift typealiases -->

Usage looks the same in each:

```swift
var reader = BigEndianBytesReader(packet.span)
try reader.expect(0x504B_0304 as UInt32)                     // a magic number in the cursor's byte order
let version = try reader.read(UInt16.self)                   // 2 bytes, big-endian
let length = try reader.read(Int.self, as: Byte3.self)       // an Int from 3 bytes
let flags = try reader.read(Byte.self)                       // one byte, to be taken apart by name (section 4)
let body = try reader.read(byteCount: Int(length))           // a RawSpan of the same memory
```

<!-- src: Bytes/Sources/Bytes/Bytes.docc/Bytes.md overview example; Bytes/Sources/Bytes/ByteOrderedCursors.swift (read(_:), read(_:as:), expect); Bytes/Sources/Bytes/BytesReader.swift read(byteCount:) -->

#### Why byte-aligned cursors are faster

A bit-addressable cursor carries state a byte-only format never uses: a bit offset (0 to 7) and, in the writer, the
partly written byte. Every byte-level operation has to look at it:

```swift
// BytesWriter.write(_: Byte2), in essence:
if bitOffset == 0 {                        // the fast path: one store
    guard capacity - byteOffset >= 2 else { throw .insufficientCapacity }
    store(value, at: byteOffset)
    byteOffset += 2
} else {                                   // mid-byte: merge 16 bits into the partial byte
    (byteOffset, bitOffset, partial) = writeUnaligned(value, …)
}
```

<!-- src: Bytes/Sources/Bytes/Bytes.docc/UnderstandingTheTypes.md "Why the byte-aligned cursors are faster" -->

The compiler would like to prove `bitOffset` stays 0 and delete the test, the slow path, and the extra term in
`remainingByteCount` (which subtracts a partly read byte). It usually cannot, because the slow path *writes* `bitOffset`,
so its value at the top of each loop iteration depends on the previous one. <!-- src: Bytes/Sources/Bytes/Bytes.docc/UnderstandingTheTypes.md (same section) --> The byte-aligned modes remove the state
from the type instead. The bit offset is an accessor over a stored field, and the accessor consults a static constant of
the mode:

```swift
var _bitOffset: Int {
    @inline(__always) get { Mode.addressesBits ? _bitOffsetStorage : 0 }
    @inline(__always) set { if Mode.addressesBits { _bitOffsetStorage = newValue } }
}
```

<!-- src: Bytes/Sources/Bytes/BytesReader.swift GenericBytesReader._bitOffset -->

Every operation is `@inlinable`, so it is compiled specialized for the cursor you use. For an `AlignedBytesWriter` the
accessor is the literal `0`, `if bitOffset == 0 { … } else { … }` folds to the fast path alone, and the loop contains one
bounds check and one store. For a `BytesWriter` the accessor is the stored field, and the code is the same as that of the
non-generic cursor it replaced (no instruction count changed). <!-- src: Bytes/Sources/Bytes/Bytes.docc/UnderstandingTheTypes.md; Bytes/Benchmarks/RESULTS.md "byte-aligned cursors" ("The refactor alone changes nothing") -->

The ordered modes add one more constant, `Mode.byteOrder`. Reads and writes by integer type test it with a `switch`
rather than `==`, because the standard library's `ByteOrder.==` is not inlinable, and a comparison compiled to a call per
store (71 instructions in a byte-ordered writer probe, 53 with the `switch`). <!-- src: Bytes/Sources/Bytes/ByteOrderedCursors.swift peek comment "A switch, not ==: the synthesized == stayed an out-of-line call"; AGENTS.md Lessons "The standard library's ByteOrder.== is a call … 71 → 53 instructions" -->

Measured (instructions, switching a client from the bit-addressable to the aligned cursor):

| Client | Change |
|---|---|
| MQTT packet encode | −6.1% (5,464 K → 5,132 K) |
| MQTT packet parse | −0.9% to −2.9% |
| Base64 encode, 40–95 bytes | −4.5% to −7.7% |
| DEFLATE decode (every corpus file) | −1.7% to −4% |
| a QOI decoder writing runs one pixel at a time | −22% |

<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-16, byte-aligned cursors" results table -->

**When not to switch.** A QOI decoder that fills runs with `write(repeating:)` ran 54% more instructions (22.2 G → 34.3 G
for 200 decodes) with the aligned reader: LLVM nested the vectorized run-fill loops *inside* the per-pixel loop instead of
beside it, turning an 88-instruction innermost loop into a 287-instruction outer one with spills. Two attempts to steer it
(a `_slowPath` hint, moving the fill out of line) did not help, so that decoder keeps `BytesReader`. <!-- src: Bytes/Benchmarks/RESULTS.md "QOI's run-filling decoder keeps BytesReader" --> Each operation does strictly less in
the aligned mode, but the compiler sees a different loop; measure hot loops when you switch.

Formats with flag bits *inside* a byte are still byte-aligned: read the `Byte` and take it apart by name ([section 4](#4-bit-level-fields-bitflag-bitfield-bitpattern)). Only
formats whose fields cross byte boundaries in the stream, such as DEFLATE's block headers, need the bit-addressable
cursors. Conversion at a byte boundary is `AlignedBytesReader(bytesReader)` (which throws `BytesError.misaligned` partway
through a byte) and `BytesReader(alignedReader)`. <!-- src: Bytes/Sources/Bytes/Bytes.docc/UnderstandingTheTypes.md "Which cursor"; BytesReader.swift init(_ reader: consuming BytesReader) -->

#### The cursor lives in registers

A `BytesReader` is a struct of plain values: a `RawSpan` (pointer and count), a byte offset, a bit offset, and a bit order,
40 bytes in all. There is no class, no buffer, and no existential. <!-- src: Bytes/OPTIMIZATION.md (old version) §3 "A small struct of plain values: … 40 bytes that fit in registers"; Bytes/Benchmarks/RESULTS.md "Allocation checks" ("the 40-byte cursor and a header") --> That helps only if the optimizer keeps its fields in
registers, which it does only while no instruction needs the cursor's *address*. Anything that takes the cursor `inout`
and is not inlined, or a non-inlined `mutating` method, passes a pointer, and from then on the whole struct lives in
memory for the entire function, even on paths that never make the call. (Part I, ["Stores, forwarding, and why
memory-resident values are slow"](#16-stores-forwarding-and-why-memory-resident-values-are-slow), gives the machine-level reason.)

Three habits keep the cursor in registers. The library follows them, and Part III (["Keep hot state in registers"](#1-keep-hot-state-in-registers)) shows
each with its measurements:

1. **Rare paths take values.** The unaligned read is a `static` function (`_unalignedBytes`) rather than a `mutating`
   method: it takes the position as values and returns the new value.
   <!-- src: Bytes/OPTIMIZATION.md (old version) §5 "A slow path that borrows self"; Bytes/Sources/Bytes/BytesReader.swift _unalignedBytes -->
2. **Hot functions are `@inline(__always)`**, and slow paths are out of line and not generic, so specialized code of either
   mode calls them without passing type metadata. <!-- src: Bytes/Sources/Bytes/Bytes.docc/UnderstandingTheTypes.md "No run-time generics" -->
3. **Don't capture a cursor in a closure that won't be inlined.** A closure that is not inlined keeps its captured
   variables in memory (a benchmark writer ran at 0.6 GB/s that way, against 54 GB/s as a local). <!-- src: Bytes/OPTIMIZATION.md (old version) §5 "A cursor captured by a closure"; Bytes/Benchmarks/RESULTS.md "Writing" harness lessons (0.6 GB/s against 54 with a local writer) -->

#### What a read compiles to

A byte-group read (`peek`, then `read` advances) is, in source form:

```swift
_assumeInvariant()
if likely(_bitOffset == 0) {
    guard likely(span.byteCount &- _byteOffset >= T.byteCount) else { throw .insufficientData }
    return unsafe Load.group(T.self, from: span, at: _byteOffset)   // unchecked load; the guard just checked it
}
```

<!-- src: Bytes/Sources/Bytes/BytesReader.swift peek<T: ByteGroup> -->

Three things do the work. `likely` is a wrapper over an LLVM branch-weight hint, so the slow path is laid out of
line. The check uses wrapping subtraction (`&-`): the cursor knows the subtraction cannot overflow, and a trap would be a
second exit. And `_assumeInvariant()` tells the optimizer, with `Builtin.assume`, three facts that always hold:

```swift
unsafe assume(_byteOffset <= span.byteCount)
unsafe assume(_bitOffset >= 0)
unsafe assume(_bitOffset < 8)
```

<!-- src: Bytes/Sources/Bytes/BytesReader.swift _assumeInvariant -->

With them, LLVM knows `span.byteCount - _byteOffset` cannot wrap, so the checks for fields at `offset` and `offset + 2`
merge into comparisons against constants. A fourth assumption, `_byteOffset >= 0`, is equally true and deliberately left
out: alone among the four, it stopped LLVM from vectorizing loops of single reads (14 against 113 GB/s for 4-byte
values), and leaving it out costs 11% more instructions in field-by-field parsing (291 K against 263 K for 2,000 zip
directory entries) at the same speed. <!-- src: Bytes/Sources/Bytes/BytesReader.swift _assumeInvariant doc comment; Bytes/Benchmarks/RESULTS.md "Making loops of single reads vectorize" --> A hint that is true can still hurt; each was tested alone.

#### Reading in bulk: one check, then a loop

The per-field cost is amortized by reading many values at once:

```swift
var sum: UInt64 = 0
reader.forEach(Byte4.self, .bigEndian) { sum &+= UInt64($0) }      // one bounds check, then a counted loop

let offsets = try [UInt32](capacity: count) { (output) throws(BytesError) in   // bulk read into an OutputSpan
    try reader.read(Byte4.self, .bigEndian, into: &output)
}
```

<!-- src: Bytes/Sources/Bytes/BytesReader.swift forEach and read(_:_:into:) doc comments -->

`forEach` does one bounds check up front, then a counted loop of unchecked loads at fixed strides, with your closure
inlined into it, so LLVM can vectorize the loads, the conversion, and the body together. It is `@inline(__always)`
because for its largest body (`Byte16`) the optimizer had outlined the loop into a closure-specialized copy that stored
the captured variables on every iteration. <!-- src: Bytes/Sources/Bytes/BytesReader.swift forEach (comment "Always inlined: if the optimizer outlines a loop that calls a closure …") --> A QOI
decoder took 21% less time (from 9.9 ms to 7.8 ms) from making its cursors locals instead of captured variables. <!-- src: BinaryParsingComparison/RESULTS.md "A Bytes caveat this exposed" (Bytes 9.9 → 7.8 ms); Bytes/OPTIMIZATION.md (old version) §5 -->

Every width's `forEach` loop vectorizes. On one core, reading from memory, the power-of-two widths run at the raw load
rate; with all 32 cores every width but `Bits<5>`–`Bits<7>` gets close to the CPU's ~254 GB/s memory ceiling (`Byte`:
236 GB/s, 93%):

| Width | One core, from memory | All 32 cores |
|---|---|---|
| raw SIMD loads (reference) | 77 GB/s | 237 GB/s |
| `Byte`, `Byte2`, `Byte4`, `Byte8` | 75–77 GB/s | 228–236 GB/s |
| `Byte3` | 19 GB/s | 237 GB/s |
| `Byte16` | 56 GB/s | 235 GB/s |
| `Nibble` | 50 GB/s | 236 GB/s |
| `Bit` | 11 GB/s (88 billion values/s) | 237 GB/s |

<!-- src: Bytes/Benchmarks/RESULTS.md "Read bandwidth: every width, 1 bit to 16 bytes" Results table and bullets; cells updated from "2026-11-20, M3 Ultra" (baseline m3-final), 512 MiB: BytesBenchmarks rows "Raw SIMD read (reference), memory (512 MB), 1 core" 6,942,719 ns (77.3 GB/s) and "32 cores" 2,263,039 (237), "Byte4, memory, 1 core" 7,139,327 (75.2), "Byte, memory, 32 cores" 2,273,279 (236), "Byte16, memory, 1 core" 9,560,063 (56.2), memory ceiling from Tools/probes/results/M3-Ultra-2026-11-20/mem-threads.tsv (254 GB/s); the other cells and the 228 and 75 ends are from the earlier run -->

Rows not in the newest run (`Byte3`, `Nibble`, `Bit` from memory, and the other widths' all-core cells) are the earlier figures.

Getting every width to vectorize took four changes in the library. For the bit widths, widths that divide 8 iterate a
byte at a time (16 lanes) instead of in 64-bit blocks of 8 values (2 lanes per register): `Byte` went from 12 to 77 GB/s,
`Nibble` from 6.0 to 50, `Crumb` from 3.9 to 28, and `Bit` from 2.0 to 11 GB/s. <!-- src: Bytes/Benchmarks/RESULTS.md "Vectorization, checked in the assembly" change table --> The benchmark's own consumer
mattered too. Summing every `UInt16` into a 64-bit total turns one register of eight values into four registers of two,
and that widening limited `Byte2`: it went from 37 to 75 GB/s once summed in the value's own width. <!-- src: Bytes/Benchmarks/RESULTS.md same section ("Byte2 37 → 75 GB/s") -->

Two more forms deliver values as views rather than into a closure:

- `read(_:count:)` returns a typed span of the input, with no copying and no decoding (native byte order), and throws
  `.misaligned` where the memory is not aligned for the type. Types with alignment 1, such as `InlineArray<N, UInt8>`, are
  never misaligned. As [section 1](#1-borrowed-memory-spans-and-inlinearray) noted, it is at memory speed for 4-byte elements and slower for others. <!-- src: Bytes/Sources/Bytes/ConvertibleFromBytes.swift read(_:count:) doc comment -->
- `values(of: Byte3.self, .bigEndian)` returns a view you can `for`-`in` over (the standard library's `Iterable`): its
  iterator decodes 1,024 values at a time into a buffer it owns and hands out a span of them. It is convenient, and costs
  up to 2.5x a `forEach` with a trivial body (4.4x for `Bit`), because decoded values are stored and reloaded where
  `forEach` fuses load, decode, and body. The heavier the body, the less that matters. <!-- src: Bytes/Sources/Bytes/Iteration.swift ByteGroupValues.Iterator doc comments; Bytes/Benchmarks/RESULTS.md "`for`-`in` (Iterable)" -->

  ```swift
  let lengths = reader.values(of: Byte3.self, .bigEndian)      // bind the view to a let first
  for length in lengths { total &+= length }
  ```

  <!-- src: Bytes/Sources/Bytes/Iteration.swift values(of:_:) doc comment -->
  Swift 6.4 rejects `for x in reader.values(...)` over a temporary ("lifetime-dependent variable escapes its scope"), as it
  does for the standard library's own `for x in array.span`. And `for byte in reader` over a `let` reader (a `~Copyable`
  value) heap-allocates the cursor once per loop, a compiler issue (the box is not moved to the stack), so declare it
  `var`. <!-- src: Bytes/Benchmarks/RESULTS.md "Allocation checks" (the AllocBoxToStack explanation; swiftlang/swift#93942 for the related consuming-parameter gap) -->

#### Undoing a read: all or nothing

A read that throws consumes nothing, so a streaming parser can retry when more data arrives. For several reads in a row,
`reader.position` and `reader.rewind(to:)` (two stores) undo a sequence, and `atomically { … }` does the same inside a
closure. The closure form has a cost that depends on how it is written. For the 2,000-entry zip directory, the same
reads cost:

- 300,588 instructions plain;
- 300,588 inside `atomically`, calling an `@inline(__always)` function;
- 452,574 (+51%) with the body written in the closure, which is not inlined, so its copy of the cursor lives in memory;
- 306,591 (+2%, three instructions per entry) between `position` and `rewind(to:)`. <!-- src: Bytes/Benchmarks/RESULTS.md "position/rewind(to:), and cursors at an offset" table; Bytes/Sources/Bytes/BytesReader.swift atomically doc comment -->

Prefer `position`/`rewind` for long bodies.

#### Writers

`BytesWriter` mirrors the reader over a `MutableRawSpan`, or over an output span's uninitialized capacity through the
builders:

```swift
let wire = try [UInt8](alignedByteCapacity: 64) { (writer) throws(BytesError) in      // an AlignedBytesWriter
    try writer.write(0x504B_0304 as Byte4)
    try writer.write(Byte2.self, .bigEndian, count: 3) { UInt16(truncatingIfNeeded: $0 &* 2) }   // a generating write
}
```

<!-- src: Bytes/Sources/Bytes/BytesWriter.swift `[UInt8].init(alignedByteCapacity:writing:)`, write(_:_:count:_:) -->

The builders reserve an empty array and append through `append(addingCapacity:)`. This matters because the standard
library's `[UInt8](capacity:initializingWith:)` and `init(unsafeUninitializedCapacity:)` allocate through an unspecialized
function, about 500 instructions and 27 ns more per array than `reserveCapacity` then `append(addingCapacity:)`, at any
size. The builder made 1,000 38-byte arrays in 1,228 K instructions against 1,696 K (−27.6%). <!-- src: Bytes/Sources/Bytes/BytesWriter.swift `[UInt8].init(byteCapacity:…)` doc comment; AGENTS.md Lessons "The standard library's [UInt8](capacity:initializingWith:)"; Bytes/Benchmarks/RESULTS.md "Array builders" table -->

Annotate the error type of the closure, `{ (writer) throws(BytesError) in … }`: unannotated, it is inferred as `throws(any Error)`, and through some entry points
such a closure was not inlined (+3% instructions). <!-- src: AGENTS.md Lessons "Closures passed to a generic throws(E) parameter" -->

Three write forms deserve a note.

- **Generating writes.** `write(_:_:count:_:)` takes a closure from index to value, the counterpart of `forEach`. It is a
  counted loop of stores that vectorizes together with the closure. Power-of-two widths write at or near one core's ceiling
  (`Byte4` 89 GB/s from memory against 118 for a raw SIMD store). <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final), 512 MiB: BytesBenchmarks rows "Write: Byte4, memory (512 MB), 1 core" 6,062,079 ns (88.6 GB/s) and "Write: Raw SIMD store (reference), memory (512 MB), 1 core" 4,567,039 ns (117.6) -->
- **Writing one bit at a time cannot be fast**: each write merges into the byte the previous write left partly done, a
  dependency chain from write to write. The generating bulk write packs a whole byte (or 8 values) at a time, 110x faster
  for nibbles. <!-- src: Bytes/Benchmarks/RESULTS.md "Write bandwidth" bullets ("110x faster for nibbles") -->
- **Overrunning writes for decoders.** An LZ77 decoder (one that rebuilds data from literal bytes and back-references
  to bytes it has already written) writes a variable number of bytes per step. With
  `write(_:byteCount:allowingOverrun:)` the writer stores all 8 bytes of a word and advances by `byteCount`, overwriting
  the bytes after them with garbage that the next write replaces; there is no branch on how many bytes are meaningful.
  `copy(fromDistance:count:allowingOverrun:)` does the same for a back-reference ("copy `count` bytes from `distance` bytes
  back"): up to 32 bytes is two 16-byte moves (or four 8-byte moves for distances 8 to 15) whatever the length, straight-line
  code with no branch for the CPU to mispredict. It needs `copyOverrun` (32) bytes of room past the longest copy and
  distance at least 8; otherwise it copies exactly. <!-- src: Bytes/Sources/Bytes/BytesWriter.swift write(_:byteCount:allowingOverrun:), copy(fromDistance:count:allowingOverrun:), copyOverrun -->

**Why reading and writing are separate types.** A combined cursor would have to hold the memory exclusively
(`MutableRawSpan`), so any span it hands out could only borrow the cursor, not the memory: reading a field after taking a
span would be an "overlapping accesses" error. Reading through a `MutableRawSpan` would not be faster either. <!-- src: Bytes/Benchmarks/RESULTS.md "Should reading and writing share one type? No." -->

#### Unchecked forms, and when they are justified

The cursor's loads are unchecked *behind its own check*. The standard library's check is
`UInt(offset) <= UInt(count) && size <= count - offset`; its first half needs `offset >= 0`, the one fact the cursor
deliberately does not state, so it does not fold into the cursor's check. Measured against the standard-library accessors:
field-by-field parsing +24% instructions, `Byte3` and `Byte5`–`Byte15` reads 2–8x, writes of odd widths +42–144%, and bulk
loops stopped vectorizing. <!-- src: Bytes/Benchmarks/RESULTS.md "Safe constructs instead of unsafe ones" tables and pattern paragraph -->

Where the checked form *did* fold (a sub-cursor's `extracting`), the safe version was kept, and made fixed-size
records 31% faster (7.3 against 10.6 µs). <!-- src: same section, first table -->
The unsafe forms that are public are named `unsafe…` (`unsafeCommonPrefixLength`, `unsafeFlush`) and each is for a loop
that proves its bounds once per block, with the proof in a comment at the call (sections [6](#6-entropy-coding-building-blocks-bitbuffer-bitwriter-huffmantable) and [7](#7-scanning-and-shuffles-bytelanes-bytematches-groupshuffle-cbytesneon)).

### 4. Bit-level fields: `BitFlag`, `BitField`, `BitPattern`

A byte of flags is read as a `Byte` and taken apart. The naive way is shifts, masks, and bit numbers at every use. The
named form declares each field once, as a **descriptor** (a value that names the field's bit positions), and uses it by
name:

```swift
enum ConnectFlags {
    static var userName: BitFlag { BitFlag(bit: 7) }
    static var willQoS: BitField<QualityOfService> { BitField(bits: 3...4) }   // an enum with UInt8 raw values
    static var reserved: BitFlag { BitFlag(bit: 0) }
}
let flags = try reader.read(Byte.self)
try flags.requireClear(ConnectFlags.reserved)                  // throws .invalidValue if set
let qos = try flags.value(of: ConnectFlags.willQoS)            // throws for a raw value with no case
let hasUserName = flags[ConnectFlags.userName]                 // a Bool
guard flags.matches("01??_??0?") else { throw BytesError.invalidValue }   // a BitPattern literal
```

<!-- src: Bytes/Sources/Bytes/Bytes.docc/UnderstandingTheTypes.md "Named fields"; Bytes/Sources/Bytes/BitFields.swift header comment -->

- `BitFlag(bit:)` is one bit, read and written as a `Bool`. `BitField<Value>(bits:)` is adjacent bits, read and written as an
  `Int`, a `Bits` value, or a `RawRepresentable` type (an enum) with an integer raw value. Positions count from the least
  significant bit; the `…FromMostSignificant` initializers count from the other end, for specifications that draw bit 0
  on the left. <!-- src: Bytes/Sources/Bytes/BitFields.swift BitFlag/BitField initializers -->
- The subscripts and helpers (`flags[flag]`, `flags[field]`, `value(of:)`, `isZero`, `requireZero`, `isClear`,
  `requireClear`, `matches`) are on *any* fixed-width integer and on `Bits`, so a DOS date read as a `UInt16` takes its parts
  as `date[DOSDate.month]`. Setting a field leaves the other bits alone, and `Byte { $0[flag] = true }` builds a value from fields set
  on zero. <!-- src: Bytes/Sources/Bytes/BitFieldAccess.swift -->
- `BitPattern` checks fixed bits at once, written as a specification draws them: `0` and `1` must match, `?` is free,
  `_` separates groups. <!-- src: Bytes/Sources/Bytes/BitFields.swift BitPattern doc comment -->

#### Why they cost nothing

Each use is a shift and a mask whose positions are constants. A field read is `value >> offset & mask`; a field write is
`value & ~(mask << offset) | (new << offset)` (`_setBits(unmasked:of:)`; the general `_setBits` also masks the new
bits). The positions fold, and the range checks (`offset + width <= bitWidth`) fold with them. <!-- src: Bytes/Sources/Bytes/BitFieldAccess.swift `_bits(of:)`, `_setBits` -->

The claim was checked from another module, which is the only place it can be checked, because clients see only what is
inlinable. A throwaway package depended on the library, with `@inline(never)` probe functions beside hand-written
equivalents. LLVM merges functions whose machine code is identical, so two probes that become one symbol prove the code
is the same. Flags, enum fields, and `Int` fields passed; a `Byte { $0[flag] = true … }` builder compiled to 4
instructions against 3. <!-- src: Bytes/OPTIMIZATION.md (old version) §2 "Check a new API's code from another module" and §4 "BitFlag, BitField, BitPattern"; AGENTS.md Lessons "Check a new API's codegen from another module" -->

Adopted across MQTT, the LZ4 frame descriptor, QOI, NativeZip's DOS dates and attributes, the zlib and gzip headers, and
DEFLATE's HLIT/HDIST/HCLEN header fields, the named fields measured neutral, with one gain and one regression. The gain
was in NativeZip's Huffman table entry: read through named fields, it shortened the decode loop from 246 to 236
instructions (inflate −2.5 to −2.8%). The regression came from the setter (below). <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-17, the proposals pass" "Kept, measured neutral" and "Reverted or not done"; Bytes/OPTIMIZATION.md (old version) §4 (same paragraph) -->

Three details came out of that probing:

- **Descriptors are computed `static var`s, not `static let`s.** A `static let` is a lazily initialized global, checked on
  every access; a computed property inlines to the same shift and mask written by hand. <!-- src: Bytes/Sources/Bytes/BitFields.swift header comment -->
- **`BitPattern`'s initializers need `@inline(__always)`.** With both forced, a literal folds to its two masks; without,
  the pattern string was parsed at run time on every call. <!-- src: AGENTS.md Lessons "a BitPattern literal folded to its two masks only with @inline(__always) on both initializers" -->
- **Store a checked value unmasked.** A setter that did `assert(raw <= mask)` and then stored `raw & mask` cost MQTT's
  PUBLISH encoding 0.8% (5,132 K → 5,173 K instructions). The current setter does `precondition(raw <= mask)` and stores
  unmasked: once the precondition has run the mask cannot change the value, and when the enum's raw values are visible to
  the optimizer both fold away. <!-- src: Bytes/Sources/Bytes/BitFieldAccess.swift subscript(field: BitField<R>) setter comment; Bytes/OPTIMIZATION.md (old version) §10 "What tracking caught" -->

#### Bit fields in a stream

Fields that cross byte boundaries in the stream, rather than inside a value already read, use the bit-addressable cursor:
`read(Nibble.self)`, `read(Bits<3>.self)`, `read(Bool.self)`, `read(bitCount:)` (0–64 bits).

Widths that divide 8 take a fast path on writes. A value written after others of its width always fits in the current
byte, so it is merged into the partial byte and that one byte is stored, instead of taking the general
window-and-multi-byte-store path (27 instructions per nibble through `_writeBits`). The per-value `write(_:)` rows fell
30% (`Nibble`), 33.6% (`Bit`), and 36.4% (`Crumb`) in instructions. <!-- src: Bytes/Sources/Bytes/BytesWriter.swift write<Bits> comment; Bytes/Benchmarks/RESULTS.md "Cleanup and improvements (2026-11-19)" table -->
For bulk work, packing a byte at a time (the generating `write(Bits.self, count:)` form) is 110x faster than one write per
nibble. <!-- src: Bytes/Benchmarks/RESULTS.md "Write bandwidth" bullets -->

Reading a value *already in a register* needs no cursor at all: `value[bits: 3..<8]` checks its range, while
`bits(from:upTo:)` is the unchecked form for run-time bounds that the caller knows are valid (a Huffman code's extra
bits). The unchecked form is 5 instructions against 8 for the hand-written mask, and the checked subscript, whose
range checks cannot fold with run-time bounds, 23. <!-- src: Bytes/Sources/Bytes/Bits.swift bits(from:upTo:) doc comment; Bytes/Benchmarks/RESULTS.md "2026-11-10: conveniences …" ("bits(from:upTo:) 5 against 8 (and 23 for the checked subscript)") -->

### 5. Structure: sections, length prefixes, LEB128, records, text, dates

Real formats nest: a length, then that many bytes of something with its own fields. The API exists so that the
compiler can see each boundary.

#### Sections and length prefixes

`readSection(byteCount:)` returns a *cursor of its own* over the next N bytes. Parsing a section with its own cursor bounds
every read in it to the section, and when N is a constant the optimizer can see, the reads inside need no bounds checks at all:

```swift
// Field by field: a check per field.
let signature = try reader.read(Byte4.self)
let version = try reader.read(Byte2.self, .littleEndian)
// … 15 more fields

// One check for the record, none per field.
var record = BytesReader(try reader.read(byteCount: 46))
let signature = try record.read(Byte4.self)
let version = try record.read(Byte2.self, .littleEndian)    // bytes 4..<6 of 46: known in bounds
```

<!-- src: Bytes/OPTIMIZATION.md (old version) §6 "Give the record a known size"; Bytes/Sources/Bytes/Sections.swift readSection doc comment -->

For the 2,000-entry zip central directory, the fixed-size style takes 200 K instructions (8.1 µs) where the same reads field
by field take 286 K (10.8 µs); a hand-written version over `RawSpan.load` at offsets
takes 318 K instructions and 15 µs. <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): BytesBenchmarks rows "Fields: Bytes, fixed-size records" 8,087 ns / 199,807 instructions, "Fields: Bytes" 10,751 ns / 285,695, "Fields: hand-written offsets" 15,335 ns / 317,695 --> The
compiler even loads adjacent 4-byte fields with one instruction (`ldp w7, w19, [x17, #16]`). <!-- src: Bytes/Benchmarks/RESULTS.md "Assembly findings" ("paired loads (ldp w7, w19, [x17, #16])") -->

Related forms:

- `read(sectionPrefixedBy: Byte2.self, .bigEndian)`: a length, then a section, with nothing consumed on failure, not even
  the length.
- `readSectionIfComplete(prefixedBy:_:)`: for a stream, `nil` until the whole section has arrived.
- `read(bytesPrefixedBy:_:)` and `read(utf8PrefixedBy:_:)`: a span or a `UTF8Span` of the counted bytes.
- `forEachRecord(tag:length:_:paddedTo:_:)`: for formats of tag-length-value records, optionally padded to an alignment
  such as PCAPNG's 4.

`forEachRecord` is all or nothing per record and has no closure *inside* its loop, so the cursor stays in
registers. <!-- src: Bytes/Sources/Bytes/Sections.swift; Bytes/Benchmarks/RESULTS.md "2026-11-10: conveniences …" ("forEachRecord … no closure inside, so the cursor stays in registers") -->
`expectEnd()` throws `.trailingData` if a section was not fully consumed.

**Counts from untrusted data throw instead of trapping.** `read(byteCount:)`, `skip(byteCount:)`, and `read(_:count:)`
throw `.invalidValue` for a negative count. The first two check both bounds with one unsigned comparison,
`UInt(bitPattern: n) <= UInt(bitPattern: remaining)`, which turns a negative `n` into a huge unsigned number that fails
the same compare as a count that is too large. Written as `n >= 0 && n <= remaining`, the LZ4 port ran 2% more
instructions. <!-- src: Bytes/Sources/Bytes/BytesReader.swift read(byteCount:) comment; AGENTS.md Lessons "A count check is one unsigned compare" -->

#### LEB128

**LEB128** is the variable-length integer of MQTT ("Variable Byte Integer"), Protocol Buffers, WebAssembly, and DWARF:
7 bits per byte, least significant group first, with the high bit set on every byte but the last. <!-- src: Bytes/Sources/Bytes/Sections.swift LEB128 doc comment -->

`read(LEB128.self, maxByteCount: 4)` has a fast path for the common single byte (value below 128), and sends the multi-byte case to an
out-of-line `static` function (`_readLEB128`) taking values, "like the other slow paths, so callers keep their cursor in
registers". `requiringMinimal: true` rejects padded encodings (MQTT requires minimal ones) at no cost on the fast path. <!-- src: Bytes/Sources/Bytes/Sections.swift read(_:maxByteCount:requiringMinimal:) and _readLEB128 -->

#### Records

A **record** is a fixed run of fields read in one call. `BinaryParsable` is an `init(parsing:)`, `BinaryWritable` is
`write(to:)`, and `FixedSizeBinary` states a constant `byteCount`, which lets a record containing such fields be read
with one bounds check:

```swift
struct Version: BinaryParsable, BinaryWritable {
    var major: UInt8, minor: UInt8
    init(major: UInt8, minor: UInt8) { (self.major, self.minor) = (major, minor) }
    init<Mode: BytesCursorMode>(parsing reader: inout GenericBytesReader<Mode>) throws(BytesError) {
        major = try reader.read(UInt8.self)
        minor = try reader.read(UInt8.self)
    }
    func write<Mode: BytesCursorMode>(to writer: inout GenericBytesWriter<Mode>) throws(BytesError) {
        try writer.write(major); try writer.write(minor)
    }
}
let version = try reader.read(Version.self)
```

<!-- src: Bytes/Sources/Bytes/BinaryRecords.swift BinaryParsable doc comment; Bytes/Sources/Bytes/Bytes.docc/WritingParsers.md "The same format by hand" -->

`Padding<Byte4>` (skipped on read, zeros on write) and `Reserved<Byte2>` (must be zero or the read throws) are field types
for records. `ByteOrderedParsable` and `ByteOrderedWritable` are the same protocols generic over a *byte-ordered* mode, for formats
that name their byte order in their first bytes (ELF, PCAPNG): one declaration, compiled once per order, and a cursor with
no declared order is a compile error rather than a guess. <!-- src: Bytes/Sources/Bytes/BinaryRecords.swift --> The macros of [section 14](#14-macros-bitfields-and-binaryrecord) generate all of this.

Integers of a *run-time* width, as in a binary property list's object references, are
`read(Int64.self, signedByteCount: width)` and its unsigned and writing counterparts; a width outside 1 through 8 throws. The port of that example does one
8-byte load and a shift where the example it was ported from used a generic, out-of-line loop over the bytes. <!-- src: Bytes/Sources/Bytes/IntegerFields.swift read(_:byteCount:_:); BinaryParsingComparison/RESULTS.md "What made the difference" (BPList) -->

#### Terminated strings

`read(bytesTerminatedBy: 0)` and `read(utf8TerminatedBy: 0)` find the terminator 16 bytes at a time with
`RawSpan.firstByteOffset(where:)` ([section 7](#7-scanning-and-shuffles-bytelanes-bytematches-groupshuffle-cbytesneon)), return a view of the bytes before it, and consume the terminator too; the
UTF-8 form validates. Reading an ELF file's 56 section names went from 25 K to 19 K instructions (−24%) with it. <!-- src: Bytes/Sources/Bytes/Sections.swift read(bytesTerminatedBy:); BinaryParsingComparison/RESULTS.md 2026-11-18 table (section names 25 K → 19 K, −24%) -->

#### Numbers written as ASCII digits

A conventional parser reads text inside binary formats (tar headers, dates, HTTP lengths) a digit at a time:
`value = value * 10 + digit` per byte. `read(Int.self, asciiDigits: 4)` instead uses **SWAR**, short for "SIMD within a register": ordinary
64-bit integer operations on eight packed byte fields at once. For up to 8 digits it is one 8-byte load, a check, and
three multiplies. Take the text `2026`:

1. Load 8 bytes. Little-endian, byte 0 is the first character: `32 30 32 36 …` (the ASCII codes of `2`, `0`, `2`, `6`).
2. XOR with `0x3030_3030_3030_3030`: each byte is now its digit's value, `02 00 02 06 …`.
3. Shift left by `64 − 8 × 4` bits. The four digits move to the top four bytes, and the bytes shifted in are zeros, which are
   *leading zeros*: the word is the 8-digit number `00002026`, most significant digit in the lowest byte.
4. **Validate** all eight bytes at once: `((v &+ 0x7676…) | v) & 0x8080… == 0`. Adding `0x76` keeps 0–9 below `0x80` and
   pushes 10 and up to or past it; ORing the original catches bytes already at `0x80` or above.
5. **Combine** in three steps, each one multiply. Multiply by `10 << 8 + 1`, shift right 8, and mask: each even byte
   becomes `10·b₀ + b₁` (pairs). Multiply by `100 << 16 + 1`: 16-bit lanes of `100·pair₀ + pair₁` (fours). Multiply by
   `10000 << 32 + 1`: the result, `2026`.

<!-- src: Bytes/Sources/Bytes/ASCII.swift _readASCIIDigits, _areASCIIDigitValues, _combineASCIIDigits -->

9–16 digits take two loads. Near the end of the data (fewer than 8 bytes left) a slower path runs out of line. Against a
digit-at-a-time loop, 20,000 log lines of 8 fixed-width numbers each ran 5,063 K instructions (151 µs) against 5,722 K
(190 µs): −11.5% in instructions and −20% in time. <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): BytesBenchmarks rows "ASCII: 20,000 log lines, read(_:asciiDigits:)" 151,039 ns / 5,062,655 instructions and ", a digit at a time" 189,695 ns / 5,722,111 -->

The tests caught two bugs before shipping. Only an input that ends exactly where the digits end can reach one of them: the
two-load path was taken for fewer than 9 digits and loaded past the end of the data. <!-- src: same section; AGENTS.md Lessons "Test reads that end exactly at the data's end" -->

`read(_:asciiDigitsUpTo:)` stops before the first non-digit (HTTP's `Content-Length: 1024\r\n`). `read(_:asciiOctalDigits:)`
(1 to 21 digits, one or two 8-byte loads) replaced 74 per-digit branches in NativeAEA's cpio header parse, from 625 to
266 instructions counted statically. <!-- src: Bytes/Benchmarks/RESULTS.md "Cleanup and improvements (2026-11-19)" "Adopted in consumers"; Bytes/Sources/Bytes/ASCII.swift --> `write(_:asciiDigits:)` is the writing side.
In vectors, `ByteLanes.asciiDigits` ([section 7](#7-scanning-and-shuffles-bytelanes-bytematches-groupshuffle-cbytesneon)) counts digits in 620 KB 2.6x faster than a byte loop that LLVM auto-vectorizes (31 µs
against 80 µs). <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): BytesBenchmarks rows "ASCII: digits in 620 KB, ByteLanes.asciiDigits" 30,639 ns and ", isASCIIDigit per byte" 80,255 ns -->

#### Hexadecimal and dates

`[UInt8](hexadecimal:)`, `String(hexadecimal:uppercase:)`, and `write(hexadecimal:)` work eight bytes at a time in a 64-bit
word: each byte's nibbles spread into a byte each and become digits with masks and adds. There is no table and no branch
per digit; decoding checks eight digits at once the same way, then packs the nibbles back into four bytes. <!-- src: Bytes/Sources/Bytes/Hexadecimal.swift header comment; Bytes/Benchmarks/RESULTS.md "Cleanup and improvements" ("eight digits a word, no table") -->

`UTCDateTime` is a checked civil date and time in UTC (X.509 times, XAR's `creation-time`, ISO 8601 stamps), with no time
zones and no Foundation. Its range checks are one unsigned compare each (`UInt(bitPattern: month &- 1) < 12`), and its
day count is Howard Hinnant's `days_from_civil`. <!-- src: Bytes/Sources/Bytes/UTCDateTime.swift header comment and init -->

### 6. Entropy coding building blocks: `BitBuffer`, `BitWriter`, `HuffmanTable`

A cursor reads a bit field with a bounds check and a position update, which is right for headers and wrong for Huffman
codes decoded by the million. **Entropy coding** (Huffman, arithmetic, ANS: asymmetric numeral systems) replaces frequent symbols with short bit
strings; a decoder's inner loop is "peek some bits, look them up, consume the code's length", once per symbol. These three
types are that inner loop.

#### `BitBuffer`: 64 bits in a register

`BitBuffer` holds up to 64 bits of input in one integer and refills 8 bytes at a time:

```swift
var buffer = BitBuffer(reader)                   // takes over the cursor's position
while decoding {
    buffer.refill()                              // at least 56 bits buffered
    let entry = table[Int(buffer.bits & 0x7FF)]  // an 11-bit lookup
    buffer.consume(bitCount: entry.codeLength)
    …
}
reader = try buffer.finish()                     // throws if it read past the end
```

<!-- src: Bytes/Sources/Bytes/BitBuffer.swift doc comment -->

The refill has no loop and no branch on how many bytes fit while 8 bytes remain:

```swift
_bits |= UInt64(littleEndian: raw) &<< shift      // raw: the next 8 bytes; shift: bits already held
_nextByte &+= (63 &- _count) &>> 3                // advance by the whole bytes that fit
_count |= 56                                      // now 56–63 valid bits
```

<!-- src: Bytes/Sources/Bytes/BitBuffer.swift refill() -->

Take `_count == 5`. The 8-byte load is shifted left by 5, so its low 59 bits land above the 5 bits already held.
Only whole bytes are *accounted*: `(63 − 5) >> 3 = 7` bytes advance, and `5 | 56 = 61 = 5 + 56` bits are valid. The top
3 bits hold the start of an eighth byte that has not been consumed; the next refill ORs the same bits in again at the
same positions, which changes nothing. With `_count == 13` it advances `(63 − 13) >> 3 = 6` bytes and `13 | 56 = 61`. ORing
`56` (`0b111000`) works because the count is below 64: it sets bits 3–5 and keeps the low three, giving `56 + count % 8`,
which is the old count plus the whole bytes added. <!-- src: Bytes/Sources/Bytes/BitBuffer.swift `_count` doc comment ("Bits beyond them may hold the next bytes' bits, which the next refill ORs in again at the same positions") -->

Design decisions, each measured:

- **It never throws while decoding.** Past the end the buffer fills with zeros. A bad symbol decoded from zeros is only an
  error at `finish()` (or `isOverrun`), so a decoder checks once per block, not once per code. The trap that follows is
  that truncated input can look like data: DEFLATE's code-length code 16 at index 0 ("repeat the previous length") decoded
  from zeros and threw `invalidValue` when the input ended 8 bytes into a dynamic header. A decoder that rejects a value
  checks `isOverrun` first and asks for more input. <!-- src: Bytes/Sources/Bytes/BitBuffer.swift doc comment; AGENTS.md Lessons "Truncated input looks like data" -->
- **The refill's fast-path load is unchecked.** The checked load measured 10% more instructions in DEFLATE decoding, because
  its check also needs `_nextByte >= 0`, which the optimizer cannot see. <!-- src: Bytes/Sources/Bytes/BitBuffer.swift refill() comment -->
- **The slow refill (within 8 bytes of the end) takes and returns values**, not `inout` fields: passing the fields'
  addresses would keep them in memory on the fast path too. <!-- src: Bytes/Sources/Bytes/BitBuffer.swift refill() comment "Values in and out, not inout" -->
- **The bit order is a stored `let`, not a type parameter.** Hard-coding least-significant-first made DEFLATE decoding run
  0.5–3.6% *more* instructions: where the buffer is inlined, the stored order is a constant anyway. <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-16, matching, bit writing, and searching in core" ("A compile-time bit order isn't worth it") -->

`position` and `rewind(to:)` undo one unit (a code and its extra bits) when the input ran out partway. `withBitBuffer { }` on
a `BytesReader` runs a body with a buffer at the cursor and moves the cursor past what it consumed.

`BitBuffer` checks what it must (its slow refill, its overrun). A decoder whose loop *proves* its bounds once per round
can do without those checks, and DEFLATE's does: its fast loop keeps a private `FastBits`, libdeflate's bit buffer on
two locals. The buffer is a `UInt64`, and the valid-bit count is kept in the low 6 bits of an `Int` whose higher bits are
allowed to hold garbage, so consuming a table entry is two subtractions of the whole raw entry, with no masking of its
count first (bits 6 and up of the entry cannot change the low 6 bits of the difference):

```swift
// DeflateDecoder.swift, FastBits (the loop's own buffer): refill and consume, unchecked.
let word = unsafe input.unsafeLoadUnaligned(fromUncheckedByteOffset: next, as: UInt64.self)
buffer |= UInt64(littleEndian: word) &<< UInt64(truncatingIfNeeded: left)
next &+= 7 &- ((left &>> 3) & 7)
left |= 56
// …
buffer &>>= UInt64(entry.raw)          // shift by the entry's low 6 bits
left &-= Int(entry.raw)                // subtract the whole entry; only the low 6 bits of `left` are read back
```
<!-- src: Bytes/Sources/BytesCompression/DeflateDecoder.swift `FastBits.refill` and `FastBits.consume` (doc comment: "`left`'s low 6 bits count the valid bits in `buffer`, and its higher bits are garbage, because consuming an entry subtracts the whole raw entry rather than masking its count first") -->

It is a struct with mutating methods, not nested functions over captured variables, which can stay in memory behind access
checks (Part III, ["Keep hot state in registers"](#1-keep-hot-state-in-registers)).

**Backward bitstreams.** Zstandard's and LZFSE's entropy-coded streams are written to be read *backward*: from the last
byte, whose highest set bit marks the end, toward the first, most significant bit first (RFC 8878 §4.1). Their readers
hold a 64-bit container loaded from the current position and a count of bits used from its top. Both decoders read a field
the same way, and the one function is shared (it is internal to `BytesCompression`):

```swift
// ZstdEntropy.swift: the next `count` bits (0 through 56) of `container`, whose top `consumed` bits are used.
let value = ((container &<< UInt64(truncatingIfNeeded: consumed)) &>> 1) &>> UInt64(truncatingIfNeeded: 63 &- count)
consumed &+= count
```

The two-step shift is the point. One shift right by `64 − count` would be a shift by 64 when `count` is 0, which Swift's
`&>>` masks to a shift by 0 and returns the whole container. Shifting right by 1 first, then by `63 − count`, makes a
zero-bit read give 0 and read nothing, with no branch.
<!-- src: Bytes/Sources/BytesCompression/ZstdEntropy.swift `BackwardBits.read` and doc comment ("0 reads nothing and gives 0: the value is shifted right by 1, then by `63 − count`, so no shift is by 64"); Bytes/Sources/BytesCompression/LZFSEDecoder.swift line 449 (the LZFSE caller) -->
Zstandard and LZFSE each had their own copy of this reader until the second cleanup pass (2026-11-22, M1 Max); moving both
to one function left the touched rows' instructions unchanged at the table's resolution (LZFSE decode of the 1.6 KB JSON
file: 9,471 to 9,535 instructions, +0.7%).
<!-- src: Bytes/Benchmarks/RESULTS.md "The second cleanup pass (2026-11-22, late, M1 Max; baselines lend-old → lend-new, …)" bullet "One copy each" and the paragraph "Lending and dedups (lend-old → lend-new)": "LZFSE decode: the 1.6 KB JSON +0.7%, 9,471 → 9,535" -->

#### `BitWriter`: the encoder's counterpart

```swift
var bits = BitWriter(output)                       // a MutableRawSpan with 8 bytes of slack
for symbol in symbols {
    bits.add(UInt64(code[symbol]), bitCount: length[symbol])   // OR and shift
    bits.flush()                                   // up to 56 bits between flushes
}
bits.alignToByte()
let written = bits.byteOffset
```

<!-- src: Bytes/Sources/Bytes/BitWriter.swift doc comment -->

`add` is an OR and a shift into a register. `flush` stores all 8 bytes of the register at `byteOffset` and advances past the
*whole* bytes they held, with no branch beyond one capacity check:

```swift
unsafe _span.storeBytes(of: _bits.littleEndian, toUncheckedByteOffset: _byteOffset, as: UInt64.self)
let whole = _count &>> 3
_byteOffset &+= whole
_bits &>>= UInt64(truncatingIfNeeded: whole &<< 3)
_count &= 7
```

<!-- src: Bytes/Sources/Bytes/BitWriter.swift unsafeFlush() -->

If 21 bits are pending, all 8 bytes are stored, `whole` is 2, the offset advances 2, the register shifts right 16, and 5 bits
remain. The 6 stored bytes from the new offset on are provisional (the 5 pending bits, then zeros), and the next flush
overwrites them. That is why a flush needs `BitWriter.slack` (8) bytes of room past the last whole byte, which the encoder reserves per block. <!-- src: Bytes/Sources/Bytes/BitWriter.swift doc comment ("needs slack bytes of room"), unsafeFlush -->

`flush()` checks that room; `unsafeFlush()` does not, for encoders that prove it once per block (a block's worst case plus
`slack`, checked before writing it). The check is two instructions and a branch against about five for the flush; across
the DEFLATE and Brotli encoders it cost 0.2–1.7%, and DEFLATE level 1 and Brotli quality 1, which flush after every few
codes, ran 1.1–1.7% more with it. <!-- src: Bytes/Sources/Bytes/BitWriter.swift unsafeFlush() doc comment; Bytes/Benchmarks/RESULTS.md "2026-11-16, matching, bit writing, and searching in core" (BitWriter.flush()'s capacity check costs 0.2–1.7%) -->

This is the general pattern for the library's two `unsafe` public forms: the checked default, and an opt-in
for a loop that proves its bounds once.

By contrast `GenericBytesWriter.write(_:bitCount:)` checks capacity, merges a partial byte on every write, and tests its
bit order at run time; for codes written by the million, `BitWriter` is the faster form. <!-- src: Bytes/Sources/Bytes/BitWriter.swift doc comment -->

#### `HuffmanTable`: one lookup per code

A **canonical Huffman code** is defined by the *length* of each symbol's code, which a format transmits; the code
assignment follows from the lengths. `HuffmanTable` builds, from the lengths, a table indexed by the next `rootBits` bits of the stream (10 by
default, or the longest code if shorter). A code of up to `rootBits` bits fills every entry that starts with it, so decoding
is one table lookup; a longer code's root entry links to a subtable indexed by the bits after the root, so it takes two.
The 32-bit entry holds the code's length (bits 0–4), a kind (symbol, subtable link, or invalid; bits 5–6), and the symbol or the
subtable's offset (bits 8–31). <!-- src: Bytes/Sources/Bytes/HuffmanTable.swift doc comment and `entries` layout comment -->

```swift
var table = HuffmanTable(symbolCount: 19, maximumCodeLength: 7)
try table.build(codeLengths: lengths.span, bitOrder: .leastSignificantFirst)
buffer.refill()                              // at least `maximumCodeLength` bits
let symbol = try table.decode(&buffer)       // one lookup (two for a long code), then consume
```

<!-- src: Bytes/Sources/Bytes/HuffmanTable.swift doc comment -->

The table allocates once and is rebuilt in place for each block. For the fastest decoders, `HuffmanTable.build` is generic
over the *entry type*: two closures (`symbol:` and `subtable:`) make the entry, so a decoder packs everything the next step
needs (DEFLATE's length bases and extra-bit counts) into the one 32-bit load. <!-- src: Bytes/Sources/Bytes/HuffmanTable.swift doc comment ("pack more into each entry"); Bytes/Sources/BytesCompression/Deflate.swift HuffmanEntry doc comment -->

The builder follows libdeflate's: symbols are visited in canonical order, filling only the first `2^length` entries and doubling
them with a copy at each longer length, so each root entry is written once. <!-- src: Bytes/Sources/Bytes/HuffmanTable.swift build doc comment -->
A second `build` takes the already-sorted used symbols and per-length counts, so Brotli's decoder does work in proportion
to the symbols *used* (a 704-symbol alphabet, of which a small stream uses a few dozen). <!-- src: Bytes/Sources/Bytes/HuffmanTable.swift (build from sorted symbols doc comment) -->

The building of the *lengths* (`HuffmanCodeBuilder`) stays in `BytesCompression`: moving it into Bytes cost 1.6 KB Brotli
streams 1.3–1.7% more instructions (149 K to 151 K) even though everything was inlinable, and
`@inlinable`, `@inline(__always)`, and `@inline(always)` alike left 151 K. <!-- src: Bytes/OPTIMIZATION.md (old version) §10 "What tracking caught"; AGENTS.md Lessons "Moving code to another module can cost instructions even when it's inlined"; Bytes/Benchmarks/RESULTS.md "HuffmanCodeBuilder in the Bytes core" row (+1.3–1.7%) --> Every module move is benchmarked.

### 7. Scanning and shuffles: `ByteLanes`, `ByteMatches`, `GroupShuffle`, `CBytesNEON`

Many binary-format questions are searches: where is the terminator, does this string contain a forbidden byte, where does
the signature start. A scalar loop with an early exit does not vectorize, because LLVM does not vectorize loops with
data-dependent exits. Writing the search with 16-byte vectors by hand does. <!-- src: Bytes/Benchmarks/RESULTS.md "Assembly findings" ("the scalar early-exit loop doesn't vectorize (LLVM doesn't vectorize loops with data-dependent exits here)") -->

#### `ByteLanes` and `ByteMatches`

`ByteLanes` wraps a `SIMD16<UInt8>`: 16 bytes tested together. A test returns a `ByteMatches`: the high bit of each lane
is set where it matched.

```swift
let hasWildcard = topic.containsByte { $0.matching(UInt8(ascii: "+")) | $0.matching(UInt8(ascii: "#")) }
```

<!-- src: Bytes/Sources/Bytes/ByteScan.swift ByteLanes doc comment -->

Writing `vector .== byte` does not work as well as it looks. In Swift 6.4, comparing two vectors (`a .== b`) is one instruction (`cmeq`), but the
overloads that take a *scalar* (`v .== 0`) compile one lane at a time, and `SIMDMask.any()` is inlined in some loops and an
out-of-line call in others. (All are fixed in Swift 6.5-dev.) `ByteLanes` sidesteps the issue by building every test from
wrapping arithmetic and bitwise operations, which always compile to a few NEON instructions:

```swift
func matching(_ byte: UInt8) -> ByteMatches {
    let difference = vector ^ SIMD16(repeating: byte)         // 0 in the lanes that equal `byte`
    return ByteMatches(highBits: (difference &- 1) & ~difference)
}
```

<!-- src: Bytes/Sources/Bytes/ByteScan.swift matching(_:); AGENTS.md Lessons "SIMD16<UInt8> on 6.4: comparisons of two vectors are one instruction, but the overloads taking a scalar compile lane by lane" -->

The high bit of `(d − 1) & ~d` is set exactly when `d == 0`. A lane `d = 0` gives `0xFF & 0xFF`, high bit set. A lane
`d = 1` gives `0x00 & 0xFE`, clear. A lane `d = 0x81` gives `0x80 & 0x7E = 0`, clear (the subtraction does not borrow, but
`~d` cleared the high bit). A lane `d = 0x80` gives `0x7F & 0x7F`, clear. Lanes do not borrow from each other, because vector
subtraction wraps within each lane. <!-- src: Bytes/Sources/Bytes/ByteScan.swift matching(_:) comment ("x &- 1 & ~x has its high bit set exactly when x is 0 … Lanes don't borrow from each other") -->

`matching(in: 0x30...0x39)` is one subtraction and one unsigned vector comparison (`cmhs`); `pointwiseMin`, the obvious way, is
an out-of-line call on `SIMD16<UInt8>`. <!-- src: Bytes/Sources/Bytes/ASCII.swift matching(in:) comment; AGENTS.md Lessons "pointwiseMin/pointwiseMax on SIMD16<UInt8> are calls" -->

Three questions about a `ByteMatches`, in increasing cost:

- `any`: are there any matches? The two 64-bit halves ORed, with no reduction across lanes.
- `firstIndex`: which lane is first? From `nibbleMask`.
- `bitmask`: all matching lanes, one bit each (`UInt16`). (For 64 lanes at once, see [`ByteBlock`](#byteblock-64-bytes-tested-into-one-mask) below.)

The last two are a good place to *read* assembly, because the design changed the instruction count. Here is the shipped
`nibbleMask` getter, from the release object (`objdump -d --symbolize-operands`), with a comment per line:

```asm
nibbleMask:
    cmlt.16b  v0, v0, #0              ; per lane: all ones if the lane's high bit is set (signed < 0), else 0.
                                      ; This spreads the match bit through the whole lane.
    shrn.8b   v0, v0, #4              ; view as 8 16-bit lanes; shift each right 4, keep the low byte: 16 lanes
                                      ; become 8 bytes, 4 bits per original lane (lane i in bits 4i..4i+3)
    fmov      x8, d0                  ; move those 64 bits to a general register
    and       x0, x8, #0x8888888888888888   ; keep only bit 3 of each nibble: lane i's match is at bit 4i+3
    ret                               ; return the mask in x0
```

<!-- src: disassembly of ByteMatches.nibbleMask.getter in Bytes/.build/agent-tools/Bytes.o (objdump -d --no-show-raw-insn --symbolize-operands); Bytes/Sources/Bytes/ByteScan.swift nibbleMask doc comment -->

That is four instructions. The first match is then `trailingZeroBitCount / 4`. Compare `bitmask`, which packs one bit per lane:

```asm
bitmask:
    mov.d  x8, v0[1]                  ; second half of the vector (lanes 8–15) to a general register
    fmov   x9, d0                     ; first half (lanes 0–7)
    lsr    x9, x9, #7                 ; move each lane's high bit to bit 0 of its byte
    and    x9, x9, #0x0101010101010101    ; keep just those bits: one per byte
    mov    x10, #0x4080               ; build the constant 0x0102_0408_1020_4080, 16 bits at a time: bits 0–15
    movk   x10, #0x1020, lsl #16      ; bits 16–31, keeping the rest
    movk   x10, #0x408,  lsl #32      ; bits 32–47
    movk   x10, #0x102,  lsl #48      ; bits 48–63
    mul    x9, x9, x10                ; multiply: gathers the 8 bits into the top byte (byte i's bit lands at bit 56+i)
    lsr    x9, x9, #56                ; bring that byte down: bits 0–7 = lanes 0–7
    lsr    x8, x8, #7                 ; the same for lanes 8–15: high bits to bit 0 of each byte
    and    x8, x8, #0x0101010101010101    ; keep one bit per byte
    mul    x8, x8, x10                ; gather them into the top byte
    lsr    x8, x8, #48                ; shift down only 48, landing in bits 8–15 this time
    and    w8, w8, #0xff00            ; clear everything but bits 8–15
    orr    w0, w8, w9                 ; combine: lane i in bit i
    ret                               ; return the mask in w0
```

<!-- src: disassembly of ByteMatches.bitmask.getter in Bytes/.build/agent-tools/Bytes.o; Bytes/Sources/Bytes/ByteScan.swift bitmask doc comment -->

That is sixteen instructions and two multiplies, against four. When lanes are found by counting zero bits, as `firstIndex`
does, the nibble form is the one to use. It is not always the faster *loop*, though: a Brotli tag filter walking 4-bit
slots ran 2.7% more instructions (2,529 M against 2,463 M for quality 5 on `dickens`, a Silesia corpus file) than with the one-bit gather, and was reverted
with byte-identical output. A cheaper mask is not a cheaper loop. <!-- src: Bytes/OPTIMIZATION.md (old version) §10 Compression item 4 and "What tracking caught"; AGENTS.md Lessons "A cheaper mask isn't a cheaper loop" -->

**A bug in the first version.** The first `nibbleMask` shifted each byte right before narrowing, so the odd lanes reported
bit 3 of the original byte instead of bit 7: a byte like `0x70` (`p`) counted as a match. The tests used one filler byte,
which never has bit 3 set alone. The fix spreads the high bit first (the `cmlt` above), and the test fills around each
match with varied bytes. <!-- src: AGENTS.md Lessons "Lane-mask tricks need varied test data"; Bytes/Sources/Bytes/ByteScan.swift nibbleMask comment -->

#### Scanning a span

`RawSpan.containsByte(where:)`, `firstByteOffset(where:)`, and `bytesEqual(_:)` scan 16 bytes per step. Whole blocks are
tested in a loop; the last block is a 16-byte load that *overlaps* the previous one (bytes seen twice were already known
not to match, so the first match found is still the first in the span), so there is no byte-at-a-time tail. Spans
shorter than 16 bytes fill one block with overlapping loads (the first and last 8 bytes, or 4, or bytes 0, `count / 2`,
and `count − 1`), repeating some bytes and leaving none out, so they too take one test. <!-- src: Bytes/Sources/Bytes/ByteScan.swift containsByte, firstByteOffset doc comments -->

`bytesEqual` XORs each pair of blocks, ORs the differences, and checks once at the end. `UTF8Span(validating:excluding:)`
uses the same scan: ASCII bytes are each a complete, valid UTF-8 character, so text that is all below 0x80 and has no excluded byte
needs no other check, and only non-ASCII text goes to the standard library's out-of-line validation. <!-- src: Bytes/Sources/Bytes/ByteScan.swift UTF8Span(validating:excluding:) -->
MQTT uses it for topic names: a 32-byte topic takes two inlined steps of 9 vector instructions. <!-- src: MQTT/Benchmarks/RESULTS.md "What vectorizes" (Byte scans) -->

A pattern search, `firstByteOffset(of:)` and `lastByteOffset(of:)` on the reader (and `RawSpan.firstByteOffset(of:from:)`),
tests *16 candidate offsets* per step. It compares the pattern's first byte against 16 loaded bytes and its last byte
against the 16 bytes `byteCount − 1` further on, and looks at the full pattern only at offsets where both match (the
"first and last byte" filter of Wojciech Muła's SIMD substring search):

```swift
// Sketch, simplified from lastByteOffset(of:) for a 4-byte pattern (the real loads are unchecked).
let head = SIMD16<UInt8>(repeating: pattern[0])         // the first byte, in every lane
let tail = SIMD16<UInt8>(repeating: pattern[3])         // and the last
while offset >= 0 {
    let starts = span.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)       // offset ..< offset+16
    let ends = span.load(fromByteOffset: offset + 3, as: SIMD16<UInt8>.self)     // 3 bytes later
    let candidates = (starts .== head) .& (ends .== tail)                         // cmeq, cmeq, and
    if any(candidates) { /* compare the full signature at each candidate */ }     // umaxv
    offset -= 16
}
```

<!-- src: Bytes/OPTIMIZATION.md (old version) §8 "Searching 16 positions at once" (simplified from BytesReader.lastByteOffset(of:)); Bytes/Sources/Bytes/BytesReader.swift firstByteOffset(of:) -->

Finding a 4-byte signature 64 KB back (a zip file's end-of-directory record, the worst case) takes 2.3 µs and 51 K
instructions, against 34 µs and 788 K for a `RawSpan.load` at every offset, 15x faster. The loop is about 9 instructions per 16
offsets. <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): BytesBenchmarks rows "Search 64 KB backwards: lastByteOffset(of:)" 2,293 ns / 50,655 instructions and ": RawSpan.load per offset" 33,983 ns / 788,479; "Assembly findings" ("16 candidate offsets per ~9 instructions") -->

#### `ByteBlock`: 64 bytes tested into one mask

A scan that finds the next delimiter, then the next, pays a branch at each exit, and short items make those exits
unpredictable (Part III, [section 12](#12-case-study-httpbytes) measures it: 50% more cycles for 18% fewer instructions).
The alternative is a **structural index**: test a whole block of bytes at once, keep one bit per byte in an integer, and
find delimiters by counting zero bits, as `firstIndex` does for 16 lanes. `ByteBlock` is that for 64 bytes (a cache
line, and four `ByteLanes`).<!-- src: Bytes/Sources/Bytes/ByteBlock.swift doc comment; HTTPBytes/RESULTS.md "The design, from three prototypes" (A 0.93 cycles/B at 2.62 instructions/B, B 0.62 at 3.18) -->

```swift
// An HTTP head: line ends and colons, a block at a time (the example in ByteBlock's doc comment).
let block = head.byteBlock(at: offset)
let lineEnds = block.mask { $0.matching(0x0A) }                 // bit i set where byte offset + i is LF
let colons   = block.mask { $0.matching(UInt8(ascii: ":")) }
var ends = lineEnds
while ends != 0 { let end = ends.trailingZeroBitCount; … ends &= ends &- 1 }   // each delimiter, no per-byte branch
```
<!-- src: Bytes/Sources/Bytes/ByteBlock.swift doc comment (the first three lines); the loop is the standard trailingZeroBitCount walk, shown for the idea -->

`mask(_:)` runs the test on each of the four vectors and gathers the four `ByteMatches` into a `UInt64`, byte `i` in bit
`i`. `ByteBlock.gather(_:_:_:_:)` is the gather alone, for a caller that tests the four vectors itself. On NEON the gather
is `bytes_movemask64` in `CBytesNEON`: each lane (all ones where it matched) ANDed with its weight within its byte (1, 2,
4 … 128, repeated), then three rounds of pairwise adds (`addp`) sum the weights into the bits of one 64-bit
value:<!-- src: Bytes/Sources/CBytesNEON/include/CBytesNEON.h bytes_movemask64 (vandq_u8 with weights, vpaddq_u8 tree, vgetq_lane_u64) -->

```c
uint8x16_t ma = vandq_u8(a, weights), mb = vandq_u8(b, weights), mc = vandq_u8(c, weights), md = vandq_u8(d, weights);
uint8x16_t sum = vpaddq_u8(vpaddq_u8(ma, mb), vpaddq_u8(mc, md));
sum = vpaddq_u8(sum, sum);                 // the low 64 bits are the mask
return vgetq_lane_u64(vreinterpretq_u64_u8(sum), 0);
```
<!-- src: Bytes/Sources/CBytesNEON/include/CBytesNEON.h bytes_movemask64 NEON branch, lines 184-188 (variable names shortened) -->

That is 4 `and`, 4 `addp`, and one `fmov` to a general register: eight vector instructions and a move for 64 lanes,
against the sixteen scalar instructions and two multiplies of one `bitmask` above, four times over.<!-- src: disassembly of the farStop loop (Tools/loops HTTPBytes/.build/agent-tools/HTTP1.o 'farStop' --body: 4 and.16b, 4 addp.16b, 1 fmov); the bitmask listing above in this section -->
It wants lanes that are all ones or all zeros, as a comparison leaves them. `ByteMatches` keeps only each lane's high bit,
so `gather` spreads it with one `sshr`, which LLVM drops when the lanes come from a comparison. Doing the spread in Swift,
where LLVM can see through it, took the gather from 12 vector instructions to 8 and a move.<!-- src: Bytes/Sources/Bytes/ByteBlock.swift `fullLanes` doc comment; HTTPBytes/RESULTS.md "ByteBlock stays in byte order (Bytes): bytes_movemask64 now takes full lanes … 8 vector instructions and a move, instead of 12" -->
Without NEON (the `Portable` and no-C builds, [section 15](#15-builds-and-traits-optimized-portable-and-no-c)), the
gather is four `bitmask`s shifted into place, which is slower but gives the same mask.<!-- src: Bytes/Sources/Bytes/ByteBlock.swift `gather` (the #else branch: UInt64(first.bitmask) | UInt64(second.bitmask) << 16 | …) -->

Two loaders get a block from a span:

- `RawSpan.byteBlock(at:)` checks once that the 64 bytes lie inside the span (`offset >= 0 && offset <= byteCount - 64`),
  then loads them as four unchecked 16-byte vectors.
- `RawSpan.byteBlock(at:padding:)` is for the last, partial block. It copies the bytes that remain into 64 bytes of stack
  filled with `padding`, in 16-, 8-, or 4-byte words (the last overlapping), not by `memcpy`: for a few dozen bytes the call
  cost more than the copy. Choose a padding byte that every test treats as a stop, so a walk over the masks ends at the
  data's end. A span of 64 bytes or more can skip the copy: test the block that ends at the span's end and shift its mask
  into place, setting the bits past the end.<!-- src: Bytes/Sources/Bytes/ByteBlock.swift byteBlock(at:) and byteBlock(at:padding:) doc comments and bodies; HTTPBytes/RESULTS.md "A partial last block is copied inline in 16-, 8-, or 4-byte words (memcpy and a byte loop before)" -->

```swift
// For a span of 64 bytes or more, the block at `block` that runs past the end: the last 64 bytes, shifted into place.
let mask = bytes.byteBlock(at: count - 64).mask(test) >> UInt64(block - (count - 64)) | ~0 << UInt64(count - block)
```
<!-- src: Bytes/Sources/Bytes/ByteBlock.swift byteBlock(at:padding:) doc comment, and HTTPBytes/Sources/HTTP1/HeadScanner.swift blockMask(_:at:_:) (the same expression with `last` and the shifts) -->

**Measured, and when to use it.** On 401 real HTTP request heads (an M1 Max), a parser that walks 64-byte masks with `ctz`
ran 0.62 cycles a byte in its prototype; the same strategy with 16-byte nibble masks in Swift alone, 0.87; scans from each
delimiter to the next, 0.93; picohttpparser, 1.23.<!-- src: HTTPBytes/RESULTS.md "The design, from three prototypes" table and "With 16-byte nibble masks in Swift alone, B fell to 0.87 cycles/B" -->
Use it when a format has short items with several delimiters each, and the walk can use one mask for many items. Do not use
it for one long scan (`firstByteOffset(where:)` stops at the first match without building 64 lanes), and do not classify
blocks ahead of need: masks built for five blocks at a time, or kept in a ring of eight, made 38-byte heads 55 → 86 and
55 → 92 cycles, because short inputs end inside the first block. How a library gets from this API to a competitive parser,
and what else it took, is [section 12 of Part III](#12-case-study-httpbytes).<!-- src: HTTPBytes/RESULTS.md "Tried and not kept (cycles per head)" table rows 1 and 2 (tiny 55 → 86, 55 → 92) -->

#### `commonPrefixLength`: match extension

An LZ77 compressor, after a hash finds a candidate, asks how many bytes agree. `commonPrefixLength(at:and:from:maxLength:)`
compares 8 bytes at a time: XOR two words, and if nonzero the first difference is `trailingZeroBitCount / 8`; then byte by
byte for the last few. <!-- src: Bytes/Sources/Bytes/BytesReader.swift unsafeCommonPrefixLength -->

It checks its bounds once per call (a sign test of the bounds ORed together, about 8 instructions), which is as much as a
short match's comparison costs, so a match finder calling it per candidate ran 3–18% more instructions (DEFLATE level 6
on `dickens`: 1,311 M to 1,401 M; Brotli quality 9: 4,664 M to 5,515 M). `unsafeCommonPrefixLength` omits the check and
restores every row exactly. The compressors' safety argument ("`maxLength` never passes the data's
end") is a comment at their one call site. <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-16, matching, bit writing, and searching in core" Probes -->

#### Table lookups: `tbl`, and why there is a C target

Some instructions do in one step what takes a dozen otherwise, and Swift cannot emit them. NEON's table lookup (`tbl`,
Part I, ["Table lookup: `tbl` and `tbx`"](#24-table-lookup-tbl-and-tbx)) uses each byte of an index vector to pick a byte from a table of 1–4 vectors
(16–64 bytes), all in registers: 16 lookups in one instruction. It is the gather that NEON cannot do from memory. Swift has no intrinsics, `Builtin`
exposes no CPU-specific ones, and `SIMD16`'s dynamic subscript compiles a lane at a time (a byte shuffle written in Swift
ran 0.3 GB/s against 16.7 GB/s for overlapping stores). <!-- src: Bytes/Benchmarks/RESULTS.md "Write bandwidth" bullets; Bytes/OPTIMIZATION.md (old version) §9 -->

The fix is a small C target, `CBytesNEON`, of `static inline` functions over a C vector type that Swift imports as
`SIMD16<UInt8>`. Swift inlines them, so each call becomes the single instruction; Part III (["Reaching instructions Swift
cannot name"](#reaching-instructions-swift-cannot-name)) shows one. <!-- src: Bytes/Sources/CBytesNEON/include/CBytesNEON.h (NEON branch of bytes_table4) -->

On the Swift side that is `ByteLanes.lookup(in:)` in seven forms: a 16-, 48-, 64-, and 128-byte table, and
`keepingOutOfRange:` variants for 16, 48, and 64, which compile to `tbx` (the form that keeps the destination lane when
the index is out of range). Passing the result of one lookup as `fallback` extends the table: a 64-byte lookup, then a
16-byte one with the indices minus 64, is an 80-byte table.

`ByteLanes.deinterleave(_:_:_:)` splits 48 bytes into every third byte, as `ld3` does when loading (three `tbl`s);
`interleave(_:_:_:)` is the inverse, as `st3` does when storing. The four-vector forms, `deinterleave(_:_:_:_:)` (as
`ld4`) and `interleave(_:_:_:_:)` (as `st4`), are eight `uzp`s and eight `zip`s instead of lookups. <!-- src: Bytes/Sources/Bytes/ByteLookup.swift --> Each lookup costs a
micro-op per table register (a 4-register `tbl` is 4 micro-ops, a one-register `tbl` is a quarter of that), and micro-ops,
not instructions, bound a table-driven kernel ([section 13](#13-bytesbase64-and-bytesfoundation)). <!-- src: Bytes/Benchmarks/RESULTS-base64.md "The kernel" ("Counting a tbl/tbx as one micro-op per table register"); Bytes/Benchmarks/RESULTS.md "2026-11-12: the optimized build adopts the portable iterator path" (4-register tbl 4 micro-ops) -->

#### Keeping LLVM from merging your shuffles

LLVM is good at combining neighboring operations, and sometimes that undoes your work. Written with Swift lane
initializers, the two rounds of `zip`s that interleave four vectors were fused into four-source shuffles that ARM64 builds
a lane at a time, and the loads feeding `bytes_deinterleave4` were narrowed to the lanes its first round used. The C
helpers prevent both with an empty inline-assembly statement, which emits nothing but is opaque to the optimizer; Part III
(["The catch: LLVM merges shuffles into ones it cannot build"](#the-catch-llvm-merges-shuffles-into-ones-it-cannot-build)) shows the code and the counts. <!-- src: Bytes/Sources/CBytesNEON/include/CBytesNEON.h bytes_interleave4 and bytes_deinterleave4 doc comment --> Both fixes are
specific to one architecture; the portable alternative is the next topic.

#### Constant shuffles need no C: `GroupShuffle`

A table lookup with *run-time* indices needs `tbl`. With *constant* indices, Swift can express it: build a vector from lanes
of another picked at constant positions, and LLVM recognizes the initializer as one shuffle. Bytes' (internal) `GroupShuffle`
unpacks and packs 3-, 5-, 6-, and 7-byte groups this way, computing the constant picks with
`GroupShuffle.unpacked(_:byteCount:bigEndian:_:)`; Part III (["Constant shuffles do not need C"](#constant-shuffles-do-not-need-c)) shows the code. <!-- src: Bytes/OPTIMIZATION.md (old version) §9 "Constant shuffles don't need C"; Bytes/Sources/Bytes/GroupShuffle.swift (the shuffle is computed from `unpacked(_:byteCount:bigEndian:_:)` with constant arguments) -->

The loop is one load, one *single-register* `tbl`, and one store; on x86-64 macOS the same Swift compiles to `pshufb`. A
one-register `tbl` is a quarter of a 64-byte one's micro-ops, so for iterators (`for`-`in`) it beat the NEON lookups by
22–32% in time (5- to 7-byte groups) and 43–44% (3-byte groups), so the optimized build uses it for iterators. For
`forEach` with a body and for bulk reads and writes, the optimized build keeps the NEON lookups. <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-12: the optimized build adopts the portable iterator path" table -->

LLVM's merging sets two traps here too, and the portable fix is a small stack buffer (`withUnsafeTemporaryAllocation`, no
allocation) that the plain loops vectorize over; [Part III](#part-iii-techniques-by-problem) has the details. Staging (computing values into that buffer
first) pays only for a full buffer (128 values of 3 bytes, 64 of 5–7): runs of 1–62 `Byte3`s took 37% more instructions
staged. <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-12: fast portable builds" bullets; Bytes/Sources/Bytes/GroupShuffle.swift `stages(_:count:)` --> [Section 15](#15-builds-and-traits-optimized-portable-and-no-c) returns to the portable builds.

### 8. Checksums: `CRC32`, `Adler32`, `CRC64`, `XXHash64`, `RunningChecksum`

A **checksum** summarizes many bytes in a few. Archives and network formats compute one per file or per message, so the
checksum often runs over *every byte* of a stream that is otherwise being decoded. It must run close to memory speed, or it
dominates the time.

`CRC32` (zip, gzip, PNG) and `Adler32` (zlib) both conform to `RunningChecksum`. A running checksum can be updated over
pieces, continued from an earlier value, and **combined**: the checksums of two pieces computed separately join into the
checksum of both. Combining is what lets parallel code checksum chunks on different cores and join the results.

```swift
func verify<C: RunningChecksum>(_ chunks: [[UInt8]], as _: C.Type, expecting expected: C.Value) -> Bool {
    var checksum = C()
    for chunk in chunks { checksum.update(chunk.span.bytes) }
    return checksum.value == expected
}
// concrete: CRC32.checksum(data.span.bytes), CRC32.checksum(next, continuing: crc),
//           CRC32.combine(first, second, secondLength: count)
```

<!-- src: Bytes/Sources/Bytes/RunningChecksum.swift doc comment and requirements; Bytes/Sources/Bytes/CRC32.swift -->

`CRC32.combine` multiplies the first piece's CRC by `x^(8·length)` modulo the polynomial, from a table of `x^(2^k)`: about
`log2(length)` multiplications. `Adler32.combine` is zlib's `adler32_combine`. <!-- src: Bytes/Sources/Bytes/CRC32.swift combine doc comment; Adler32.swift combine --> Unlike most of the
library's public API, `CRC32` and `Adler32` are not `@inlinable`. Each call does enough work that the call itself costs
nothing measurable, and keeping their code out of clients keeps the C module and the tables out of the clients' builds. <!-- src: Bytes/Sources/Bytes/CRC32.swift comment "Not @inlinable, unlike most public API here"; Adler32.swift comment above the struct -->

#### CRC-32: three implementations

A **CRC** is the remainder of dividing the data, viewed as a polynomial over bits, by a fixed polynomial. Software computes
it a byte at a time with a 256-entry table, or 8 bytes at a time with 8 tables ("slicing-by-8"). A CPU with a carry-less
multiply (XOR in place of addition; `pmull` on Arm, Part I, ["Carry-less multiply, CRC, AES, and SHA instructions"](#29-carry-less-multiply-crc-aes-and-sha-instructions)) can do
better by *folding*. <!-- src: Bytes/OPTIMIZATION.md (old version) §10 "CRC-32: 1.7–2.3x zlib" -->

**Hardware (Apple silicon).** Eight 16-byte accumulators each hold the CRC state so far for one 16-byte lane of the
stream. Each step takes 128 bytes. Every accumulator is carry-less-multiplied by a constant that carries it 128 bytes
ahead (`pmull` on its low half and `pmull2` on its high half), then XORed with the 16 bytes of data that are now at that
position (`eor3`, a three-way XOR). The eight chains are independent, so the multiplies' latencies overlap. At the end the
lanes fold into one, and the CPU's `crc32x` instruction reduces its last 16 bytes to a 32-bit CRC. <!-- src: Bytes/Sources/Bytes/CRC32.swift _fold doc comment; Bytes/Benchmarks/RESULTS.md "CRC32 (measured in NativeZip's benchmarks…)" "Large inputs" -->

Each 128-byte step is 16 `pmull`, 8 `eor3`, 4 `ldp`, and about 10 bookkeeping instructions; Part I (["Carry-less multiply,
CRC, AES, and SHA instructions"](#29-carry-less-multiply-crc-aes-and-sha-instructions)) walks through the loop's machine code. <!-- src: Bytes/Benchmarks/RESULTS.md "CRC32 …" ("16 pmull, 8 eor3, 4 ldp, ~10 bookkeeping instructions per 128 bytes") -->

The constants are `x^(n ± 32) mod P`, bit-reflected, and a test derives them. Inputs shorter than 256 bytes use `crc32x`
8 bytes at a time instead (a dependency chain, one instruction per 3 cycles) rather than pay to combine eight lanes. <!-- src: Bytes/Sources/Bytes/CRC32.swift foldThreshold comment; Bytes/Benchmarks/RESULTS.md "CRC32" "Below 256 bytes" -->
The fold reaches **72 GB/s** over 32 MB (465 µs), is 1.65x zlib's `crc32_z` at 1 MB (15.3 µs against 25.2), and 2.3x at 64
bytes (108 µs against 249 for 16 K inputs). <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): BytesBenchmarks row "CRC-32 checksum(_:), 256 KB" 465,407 ns for 32 MiB (72.1 GB/s); CompressionBenchmarks rows "CRC-32 1 MB: Bytes" 15,295 ns and ": zlib" 25,215 ns, "CRC-32 64 B (×16 K): Bytes" 108,479 ns and ": zlib" 248,959 ns -->

The first version was **3.5x slower than zlib**. The nested helper that loaded each 16 bytes was not inlined, and as a call
per load it spilled the eight accumulators to the stack every time. `@inline(always)` on it fixed that. <!-- src: Bytes/Benchmarks/RESULTS.md same section ("First version 3.5x slower than zlib") --> Eight live
128-bit values plus constants take a large share of the 32-register file; this is the register-pressure lesson of Part I
(["Registers and the register file"](#13-registers-and-the-register-file)) in one function.

**Tables (other CPUs, and the `Portable` builds).** Slicing-by-8 is a latency chain: each word's eight lookups wait for the
previous word's. Fewer instructions did not help: rewriting the byte shifts and masks with Bytes' APIs halved the
instructions (336 M to 180 M) and ran 27% faster on 64-byte inputs, but no faster on long ones. More *chains* did help.
zlib's **braided** CRC runs five independent CRCs over interleaved 8-byte words. Each jumps 40 bytes per step through
tables that skip over the other four braids' words as if they were zeros, and the five are combined in the last block,
which works because a CRC is linear. The loop became load-bound (126 instructions per 40 bytes, 45 of them loads) instead
of latency-bound, and 3.6x faster at 256 KB (14 ms to 3.8 ms for 32 MB, 8.7 GB/s). That is still 8.3x slower than
folding. <!-- src: Bytes/Benchmarks/RESULTS.md "Group operations …" table and "2026-11-12: fast portable builds" (braided CRC; the 14 ms is that dated before); "2026-11-20, M3 Ultra" (baseline m3-final): BytesBenchmarks row "CRC-32 tables, 256 KB" 3,846,143 ns for 32 MiB (8.72 GB/s) against "CRC-32 checksum(_:), 256 KB" 465,407 ns (8.27x); Bytes/Sources/Bytes/CRC32.swift _tableUpdate doc comment -->

The table code taught two more lessons. First, the byte-indexed lookups had a bounds check each. As 256-entry spans, the
checks vanished in one loop and stayed in the other; stating the counts with a `precondition` fixed that loop but made the
main loop spill and check again (126 to 293 instructions per 40 bytes). The tables became *pointers into the borrowed
array*, with the argument for safety (every index is a byte, below 256) in a comment (`CRC32._Tables`). <!-- src: Bytes/Sources/Bytes/CRC32.swift `_Tables` doc comment; Bytes/Benchmarks/RESULTS.md "2026-11-12: fast portable builds" -->

Second, making the tables compile-time literals (so no `swift_once`) cost 64-byte checksums +10.7% until the inner update
was `@inline(never)`. With the table's address a constant, LLVM rematerialized (recomputed) each of eight table bases
inside the loops instead of keeping them in registers; passing the address as a parameter made it opaque again. With
that, the literal tables saved 3.3% at 64 bytes (150 M to 145 M instructions). <!-- src: AGENTS.md Lessons "A table that becomes a compile-time constant can make LLVM rematerialize its address in the loop"; Bytes/Sources/Bytes/CRC32.swift `_tableUpdate` comment; Bytes/Benchmarks/RESULTS.md "Cleanup and improvements (2026-11-19)" table (CRC-32 tables, 64 B: 150 M → 145 M) -->

#### Adler-32: `udot`

Adler-32 is two sums modulo 65,521: `a`, the sum of the bytes plus one, and `b`, the sum of the successive values of `a`; `b`
weights each byte by how many bytes follow it. <!-- src: Bytes/Sources/Bytes/Adler32.swift doc comment --> `udot` (FEAT_DotProd) adds, into each 32-bit lane, the dot
product of four bytes by four bytes, which computes both sums directly. The byte sum is a dot product against ones; the
position-weighted sum is a dot product against a descending run of weights (`128, 127, …, 1` over a 128-byte step).
Swift's SIMD types have no widening dot product, so, like `pmull`, the instruction is reached through a `static inline` C
wrapper (`bytes_crc_udot`), and the loop is Swift. The first version took 64-byte blocks with four accumulators per sum and
86 blocks per reduction; the current one takes 128-byte steps, described below. <!-- src: Bytes/Sources/CBytesCRC/include/CBytesCRC.h bytes_crc_udot; Bytes/Sources/Bytes/Adler32.swift _updateDotProduct; Bytes/Benchmarks/RESULTS.md "2026-11-20, Adler-32: past `udot`'s latency" -->

On an M1 Max (one core), Adler-32 went from 29.6 to 56.9 GB/s at 1 MB, with instructions −51% and 64-byte inputs −12% in
time, within 10% of libdeflate's 62 GB/s (probe re-run 2026-11-21). That first loop was 16 instructions per 64 bytes (8 `udot.4s`, 4 `add.4s`, 2 `ldp`,
`subs`, `b.ne`), and it was bound by `udot`'s 3-cycle latency: each of the eight accumulators took one `udot` an
iteration, so an iteration couldn't finish in fewer than 3 cycles. The 4 `add.4s` (forming `prefix`, the byte sum before
each block, which the weighted sum needs) and the 8 `udot`s were 12 vector operations on 4 pipes, also 3 cycles: two bounds
at 64 bytes per 3 cycles: 68 GB/s at the M1 Max's 3.21 GHz, of which it reached 83%, and 86 GB/s at 4.02 GHz, where it
measured 76 GB/s at 1 MB on the M3 Ultra. <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-19, M1 Max experiments: Adler-32 with UDOT" (and its 2026-11-20 correction); "2026-11-20, Adler-32: past `udot`'s latency" (the two bounds; 76 GB/s before); Tools/probes/results/M3-Ultra-2026-11-20/insn.tsv (udot latency 3.01 cycles, 4 a cycle with 16 chains) -->

More accumulators would not have helped. Two blocks a step into 16 accumulators (eight per sum) need eight adds a step to
form `prefix`: 24 vector operations per 128 bytes, still 3 cycles per 64 bytes, and it measured 3% faster at 1 MB (78.2
against 76.0 GB/s in an interleaved A/B). The fix removes the dependency instead. Each 128-byte step's byte sum is one chain
of eight `udot`s that starts from zero, so nothing from the previous step feeds it and the chain's latency overlaps the next
steps'. Only two adds carry over (`prefix += sum`, `sum += step`), and the eight weighted accumulators (weights `128…1`,
in a 128-entry table `bytes_adler_weights`) take one `udot` each. A step is 19 vector operations (16 `udot`, 2 `add.4s`,
a `movi` that zeroes the chain), 26 instructions per 128 bytes: 13 per 64 bytes, from 16, with no spills and no calls. The
reduction runs every 512 steps (64 KiB, against 86 blocks before): `prefix`'s lanes reach at most 32,640 · m(m − 1)/2 after
`m` steps, below 2^32 for m ≤ 513, and a limit of 514 failed the all-`0xFF` tests from 131,071 bytes. A last odd 64-byte
block is added alone. <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, Adler-32: past `udot`'s latency" (16 accumulators 24 operations, 78.2 vs 76.0 GB/s; 19 vector operations, 26 instructions per 128 B; 512 steps per reduction, 514 failed); Tools/loops --body on Adler32.checksum (26-instruction loop) -->

Measured in one process, old and new kernels interleaved (GB/s): 64 B 10.1 → 13.4, 1 KB 70.4 → 82.9, 16 KB 76.5 → 105.7, 1 MB
76.0 → 100.9. In the suite (baseline `m3-final`), Adler-32 of 1 MB takes 215 K instructions and 11.0 µs, and 16 K inputs of
64 bytes 1,264 K instructions and 78 µs (libdeflate: 305 K and 15.0 µs for 1 MB; zlib 527 K and 49.9 µs); a single thread
measures 101 GB/s at 1 MB and 99 GB/s from 4 MB to 32 MB. <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, Adler-32: past `udot`'s latency" (A/B table); "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "Adler-32 1 MB: Bytes" 11,047 ns / 215,167 instructions, ": libdeflate" 15,047 / 305,663, ": zlib" 49,887 / 527,359, "Adler-32 64 B (×16 K): Bytes" 78,463 ns / 1,263,615; Tools/probes/results/M3-Ultra-2026-11-20/checksums.tsv (Adler32 1 MB 101.2, 4 MB 99.4, 8 MB 98.7, 32 MB 99.5 GB/s) -->

The earlier change, `udot` itself, cut the instructions for 1 MB from 555 K to 271 K (−51%) and 16 K 64-byte inputs from
2,345 K to 1,755 K (−25%) on the M3 Ultra (baselines `speed-after` → `p3-spot`); the step above took those to 215 K (−21%)
and 1,264 K (−28%). `udot` was the instruction the M3-tuned code had left unused. <!-- src: Bytes/Benchmarks/RESULTS.md "Cleanup and improvements (2026-11-19)" ("Adler-32 (its −25 to −51% against speed-after is the M1 Max work …)"); "2026-11-20, Adler-32" benchmarks paragraph (272 K → 215 K, −21.0%; 1,755 K → 1,264 K, −28.0%) -->

#### CRC-64 and XXH64 (in `BytesCompression`)

`CRC64` (the `.xz` CRC) folds with `pmull` as `CRC32` does: 24–41 GB/s against a table's 2.2. `XXHash64` is Zstandard's
content checksum and a general fast hash. Four 64-bit lanes take 32 bytes per round, and the one-shot form avoids the
streaming state (64-byte inputs −35.5% instructions). <!-- src: AGENTS.md Lessons "CRC-64 by pmull folding: 24–41 GB/s against a table's 2.2"; Bytes/Sources/BytesCompression/XXHash64.swift doc comment; Bytes/Benchmarks/RESULTS.md "Cleanup and improvements (2026-11-19)" (XXH64 64 B −35.5%) -->

### 9. Buffers and moving bytes

The standard library (Swift 6.4) has no safe copy from a `RawSpan` into a `MutableRawSpan` or an `OutputRawSpan`, and no
safe access to an output span's free capacity, so each codec and socket buffer would otherwise need its own
`withUnsafeMutableBytes` and `copyMemory`. `Buffers.swift` does it once, checked. <!-- src: Bytes/Sources/Bytes/Buffers.swift header comment -->

| API | What it does |
|---|---|
| `MutableRawSpan.copyBytes(from:toByteOffset:)` | copy a `RawSpan` in at an offset; up to 64 bytes inline, longer `memmove` |
| `copyBytes(within:toByteOffset:)` | copy within the span; ranges may overlap (moving unread bytes to a buffer's front) |
| `OutputRawSpan.append(copying:)` | append a span's bytes to an output span |
| `OutputRawSpan.withFreeCapacity(byteCount:_:)` | a `MutableRawSpan` over the free capacity; the closure reports how many bytes it wrote at its start |
| `withOutputRawSpan(overwritingFrom:_:)` on `[UInt8]`, `MutableSpan<UInt8>`, `MutableRawSpan` | an empty output span over existing bytes; what it appends overwrites them |
| `[UInt8](copying:)`, `append(copying:)` | a copy of a span into an array |
| `[UInt8](alignedByteCapacity:writing:)`, `String(utf8Capacity:writing:)` | build an array or string with a writer ([section 3](#3-cursors-bytesreader-byteswriter-and-their-modes)) |

<!-- src: Bytes/Sources/Bytes/Buffers.swift; Bytes/Sources/Bytes/BytesReader.swift [UInt8].init(copying:); Bytes/Sources/Bytes/BytesWriter.swift builders -->

```swift
// Sketch: a decoder writing at its own offsets into an output span's free capacity
// (`stream.run` stands for the decoder's internal loop, as in DeflateDecoder.decompressAll).
let consumed = try output.withFreeCapacity { span, written throws(BytesError) in
    let result = try stream.run(input, into: &span, at: 0)
    written = result.end                    // the bytes initialized, counted afterwards
    return result.consumed
}
```

<!-- src: Bytes/Sources/Bytes/Buffers.swift withFreeCapacity doc comment; Bytes/Sources/BytesCompression/DeflateDecoder.swift decompressAll -->

Moving every codec, the TLS records, `Pipeline`, and SocketStream onto these changed no instruction count beyond the
reporting resolution. The counts of `withUnsafe*Bytes`, `copyMemory`, `OutputRawSpan(buffer:)`, and
`MutableRawSpan(mutating:)` fell from 66 to 26 in `BytesCompression`, 10 to 2 in `BytesCrypto`, and 5 to 0 in `Pipeline`. <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-16, buffer and copy API: no change in instructions" (every row unchanged; counts table) --> What remains is
mostly the parallel codecs handing pointers to worker threads.

Typed throws give one more reason to use these. `withOutputRawSpan` keeps the closure's error type, where
`Array.withUnsafeMutableBytes` rethrows `any Error`, and with a `throws(E)` closure Swift 6.4.2 miscompiles that call (the
thrown `BytesError` printed as `()`, swiftlang/swift#90291). <!-- src: Bytes/Sources/Bytes/Buffers.swift [UInt8].withOutputRawSpan doc comment; AGENTS.md Lessons "Never pass a throws(E) closure to an untyped generic rethrows API" -->

Moving code onto these APIs met two ergonomic traps. `[1, 2, 3].span.bytes` is 24 bytes, because the literal is an
`[Int]` (type it `[UInt8]`). And `Array(wire.prefix(send(into: &wire)))` reads `wire` *before* the argument mutates it, so
the mutation copies and `prefix` saw the old, empty array (take the result into a local first). <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-16, buffer and copy API" Ergonomics; AGENTS.md Lessons "a.f(g(&a)) reads a before g mutates it" -->

#### `ByteBuffer`: fill at the end, drain from the front

A **`ByteBuffer`** holds bytes waiting between a producer and a consumer, such as a socket's received bytes waiting to be
parsed, or a pipeline stage's output waiting for the next stage. It fills at its end through an output span and drains
from its front:

```swift
var received = ByteBuffer(capacity: 256 << 10)
while try await received.receive({ output throws(IOError) in try await connection.read(into: &output) }) > 0 {
    received.consume(try parser.parse(received.unread))     // a partial unit at the end stays unread
}
```

<!-- src: Bytes/Sources/Bytes/Buffers.swift ByteBuffer doc comment -->

The design points:

- **One allocation, never moved or grown** (64-byte aligned). A `fill` can then *suspend* (wait in a socket read) with its
  output span in place. No `Array`'s span can stay borrowed across a suspension point (an `await` where the task may give
  up its thread), but a pointer into a fixed allocation can. That is why `ByteBuffer.receive` exists ([section 11](#11-async-bytesasync)). <!-- src: Bytes/Sources/Bytes/Buffers.swift ByteBuffer doc comment and init -->
- **`compact()` moves the unread bytes to the front, but only when needed.** `fill` compacts first when fewer bytes than
  `compactionThreshold` (half the capacity by default) are free at the end, and `consume` resets both ends to 0 when the buffer
  empties (nothing to move). The code it replaced moved a partial packet after every piece; SocketStream's receive
  buffer, as a `ByteBuffer`, moves it only when less than half is free, and unprotecting with Brotli and TLS fell from
  27 M to 26 M instructions (−3.7%). <!-- src: Bytes/Sources/Bytes/Buffers.swift consume, fill; Bytes/Benchmarks/RESULTS.md "2026-11-16, buffer and copy API" (Unprotect, Brotli + TLS: 27 M → 26 M, −3.7%) -->
- **A unit must fit.** A record that is larger than the buffer can't be assembled in it (a 4 KB receive buffer with 16 KB TLS
  records traps), which is why pipeline stages declare unit sizes ([section 10](#10-pipelines-bytetransform-pipeline-and-why-composition-costs-nothing)). <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-16, buffer and copy API" ("A 4 KB receive buffer with TLS records (16 KB) traps") -->
- **It is `~Copyable` and `Sendable`.** It owns its memory, and only one owner can use it at a time (that is what
  non-copyable means), and it can be handed to another thread (Part IV, ["`Sendable` and `sending`"](#14-sendable-and-sending)). A class's
  `ByteBuffer` property cannot lend `unread` for long (the access ends at once); pass the buffer `inout` to a static
  function instead. <!-- src: Bytes/Sources/Bytes/Buffers.swift; Bytes/Benchmarks/RESULTS.md same section Ergonomics -->

#### `LentBytes`: spans for other threads

A span cannot be captured by a task or a `concurrentPerform` closure. Parallel work over a caller's input and output gets
the same memory as a `Sendable` pointer instead. Only scoped functions make one, and they state the one rule that makes it
safe: *the work that uses the pointer must finish before the function returns.*

```swift
let total = input.withLentBytes { bytes in                 // bytes: LentBytes (@unchecked Sendable)
    let sums = Mutex([Int](repeating: 0, count: 8))
    DispatchQueue.concurrentPerform(iterations: 8) { lane in
        let piece = unsafe bytes.span.extracting(…)         // this lane's part
        sums.withLock { $0[lane] = checksum(piece) }
    }
    return sums.withLock { $0.reduce(0, +) }                // concurrentPerform has returned: every lane is done
}
```

<!-- src: Bytes/Sources/Bytes/Lending.swift header comment (adapted) -->

`RawSpan.withLentBytes(_:)` lends read-only input. `OutputRawSpan.withLentFreeCapacity(_:)` lends output capacity,
uninitialized, and counts as initialized only the prefix the body reports writing. The third form,
`MutableRawSpan.withLentBytes(_:)`, lends *initialized* memory to read and write in place, as a `LentMutableSpan`: the
rule is one thread per byte at a time. The `LentBytes`, `LentMutableBytes`, and `LentMutableSpan` types are marked
`@unsafe`. The `BytesAsync` module has `async` forms, in which `await` guarantees that the work finishes. <!-- src: Bytes/Sources/Bytes/Lending.swift; Bytes/Sources/BytesAsync/Lending.swift -->

The third form replaced two hand-written copies of the same job. TLS sealing's `ParallelRecords` (lanes sealing records from the input into their places in the output) and scrypt's `ScryptMemory` (lanes each working in a table of its own in the caller's scratch memory) each wrapped a pointer in
an `@unchecked Sendable` struct; both are gone, and the rows they touched (TLS sealing of 4 MB with both ciphers on 1, 4,
and 8 lanes; scrypt at N = 2¹⁴) kept their instruction counts at the table's resolution (13 M and 36–37 M for the TLS rows,
194–196 M for scrypt, M1 Max).
<!-- src: Bytes/Sources/BytesCrypto/TLSRecord.swift lines 593–594 (`input.withLentBytes`, `output.withLentBytes`; the old `ParallelRecords`, `git show 10c3fda:Bytes/Sources/BytesCrypto/TLSRecord.swift` line 617); Bytes/Sources/BytesCrypto/Scrypt.swift (uses `scratch.withLentBytes`; the old `ScryptMemory` struct, `git show 10c3fda:Bytes/Sources/BytesCrypto/Scrypt.swift`); Bytes/Benchmarks/RESULTS.md "The second cleanup pass (2026-11-22, late, M1 Max; …)" bullet "LentMutableSpan and MutableRawSpan.withLentBytes" and the paragraph "Lending and dedups (lend-old → lend-new)": "TLS seal 4 MB, both ciphers, 1/4/8 lanes: 13 M and 36–37 M; scrypt N=2^14: 194–196 M" -->

#### `RawStorage`: memory made once, pages given back

A span cannot outlive a call, so a buffer that does (a decoder's read buffer, a pool's storage, a writer's scratch), and
that several tasks share by reference, each using its own range, needs an owner. **`RawStorage`** is that owner: one
allocation, page-aligned by default (or 16-byte-aligned for small tables and paths, from malloc's small blocks with no
padding), shared by reference, freed once, in `deinit`. `base` is a pointer and nothing synchronizes its users, which is
by design: the object is immutable, and who writes which bytes is its owner's rule.

```swift
let scratch = RawStorage(byteCount: 16 << 20)
scratch.reuse(count)                                   // take back the pages `giveBack` released
// Unsafe: `count` bytes of the storage, which `scratch` keeps alive.
let read = unsafe pread(descriptor, scratch.base, count, offset)
scratch.giveBack(count)                                // release the pages past the floor
```
<!-- src: Bytes/Sources/Bytes/RawStorage.swift doc comment (the example) -->

A buffer sized for the largest item stays resident at that size: a decoder's 16 MiB read buffer, used mostly for small
blocks, keeps every page it has ever touched. `giveBack(_:)` calls `madvise(MADV_FREE_REUSABLE)` on the pages past a
2 MiB **resident floor** (the footprint drops at once; the kernel takes the pages only when it needs memory), and
`reuse(_:)` calls `MADV_FREE_REUSE` before the next use. Up to the floor neither calls anything: the test is inlined, and
only the `madvise` itself is out of line. On Xcode's archives the floor of 2 MiB took extraction's peak footprint from 1,398
to 1,228 MB for the `.xip` and 1,597 to 1,363 MB for the `.aea`, with system time unchanged; floors of 0 and 1 MiB saved
15–35 MB more and cost 0.1 s of system time, and 4 and 8 MiB saved less.
<!-- src: Bytes/Sources/Bytes/RawStorage.swift `residentFloor` doc comment ("Measured on Xcode's archives: 2 MiB took extraction's peak footprint from 1,398 to 1,228 MB (xip) and 1,597 to 1,363 MB (.aea) with system time unchanged; 0 and 1 MiB saved 15–35 MB more and cost 0.1 s of system time; 4 and 8 MiB saved less"); Bytes/Benchmarks/RESULTS.md "2026-11-21, the waiting primitives and RawStorage" table row `RawStorage` -->
Disk and NativeAEA had each written this class (160 lines, the same word for word) before it moved into Bytes; moving it
changed no client's mallocs or file-system calls ([section 11](#11-async-bytesasync) has the check).
<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-21, the waiting primitives and RawStorage, from Disk, NativeAEA, and NativeZip" first paragraph ("Disk and NativeAEA each had the same Continuation/suspend, WaiterQueue, and RawStorage (160 lines, word for word)") -->


### 10. Pipelines: `ByteTransform`, `Pipeline`, and why composition costs nothing

A **pipeline stage** transforms input spans into an output span, reporting what it consumed and produced, the way zlib's
`deflate` and `inflate` do. That is `ByteTransform`:

```swift
public protocol ByteTransform: ~Copyable {
    associatedtype Failure: Error                           // Never if the stage can't fail
    static var maximumUnitByteCount: Int { get }            // most input a call may need before it can consume any
    static var minimumOutputCapacity: Int { get }           // least free output it needs to make progress
    mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(Failure) -> TransformProgress
}
```

<!-- src: Bytes/Sources/Bytes/Pipeline.swift ByteTransform -->

`TransformFlush` is `.none` (transform as you see fit), `.flush` (end the output on a boundary the next stage can use in
full, such as a message's end), or `.finish` (no more input). `TransformProgress` reports `consumed`, `produced`, and a `TransformStatus`
(`.needsInput`, `.needsOutput`, `.finished`). The codecs and the TLS record sealer and opener are `ByteTransform`s. <!-- src: Bytes/Sources/Bytes/Pipeline.swift; Bytes/Sources/BytesCompression/Transforms.swift -->

#### Composing

`then` builds a pipeline. The stages share one `Failure` type (`Never` for stages that can't fail, which makes a pipeline of
them non-throwing); `promoted(to:)` and `mapError(_:)` adapt stages whose types differ:

```swift
var pipeline = DeflateEncoder(format: .raw).then(TLSRecordSealer(keys: keys))   // compress, then encrypt
let progress = try pipeline.transform(message, into: &output, flush: .flush)

var compressed: [UInt8] = []                                                     // or: drive a whole message
let all = try encoder.transform(message, appending: &compressed, flush: .finish)
precondition(all.status == .finished)
```

<!-- src: Bytes/Sources/Bytes/Pipeline.swift then(_:bufferCapacity:) and transform(_:appending:flush:growth:) doc comments -->

`Pipeline<First, Second>` holds both stages and a `ByteBuffer` between them, allocated once when the pipeline is made;
transforming allocates nothing. A stage that works *in place* (`InPlaceByteTransform`: a stream cipher) is composed with
`then(_:)` into a `FusedPipeline` with no buffer at all, rewriting the previous stage's output where it was written. <!-- src: Bytes/Sources/Bytes/Pipeline.swift Pipeline, FusedPipeline -->

#### Why it costs nothing

`Pipeline.transform` is `@inlinable` and generic all the way down, so a pipeline of concrete stages specializes to *one
function*: the stages' code with the buffer handling between them, and nothing dynamic. A `Pipeline` is `~Copyable` but not
`~Escapable`, so one can live across an `await` in a socket loop. <!-- src: Bytes/Sources/Bytes/Pipeline.swift Pipeline doc comment ("One function, after specialization"); Bytes/OPTIMIZATION.md (old version) §10 "Pipelines: composing stages for free" --> The measurement shows no difference
from running the stages separately, which is the intended result (the one exception in the newest run is the 119 KB send,
where the pipeline read 13% slower with 1.4% more instructions; the morning's run had it 1.5% apart):

| Work (µs) | Pipeline | The same stages, two passes |
|---|---|---|
| deflate 1 + TLS send, JSON 1.6 KB | 9.30 | 9.22 |
| deflate 1 + TLS send, JSON 119 KB | 191 | 169 |
| deflate 1 + TLS send, Main.js | 10,100 | 9,994 |
| TLS + inflate receive, JSON 1.6 KB | 3.46 | 3.42 |
| TLS + inflate receive, Main.js | 3,123 | 3,109 |

<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "Pipeline deflate 1 + TLS send JSON (1.6 KB) / (119.0 KB) / Main.js (3.8 MB): Bytes" 9,295 / 190,719 / 10,100,735 ns against "Two passes deflate 1, then TLS send …" 9,215 / 168,959 / 9,994,239; "Pipeline TLS + inflate receive JSON (1.6 KB) / Main.js (3.8 MB)" 3,459 / 3,123,199 against "Two passes TLS, then inflate receive …" 3,417 / 3,108,863; 119 KB instructions 3,454,975 against 3,407,871; the morning's m3-1120 row: 177,791 against 175,231 -->

A pipeline is not a speed-up. It costs the same as two passes through a buffer, saves the intermediate buffer, and (with
`ResettableByteTransform`) lets a pipeline built once serve stream after stream. The TLS sealer's `reset()` deliberately
does *not* restart its record sequence, because the same keys and sequence would reuse a nonce (the per-record value that
must never repeat under one key); tests that replay records use the opener's `reset(sequence:)`. <!-- src: Bytes/Benchmarks/RESULTS.md same section bullets; AGENTS.md Lessons "Nonce reuse hides in reset()" -->

#### Declared units

Some stages work in whole units: a TLS record cannot be opened from half a record or sealed into less than a record's room.
`maximumUnitByteCount` and `minimumOutputCapacity` default to 1; the TLS opener declares 16,645 bytes (a whole record,
header and body) and 16,624 (a record's body, opened straight into the output). `Pipeline` sizes its buffer from them,
`max(requested, First.minimumOutputCapacity + Second.maximumUnitByteCount)`, and compacts when less than a quarter is
free. Without the declarations, a buffer smaller than a unit made no progress, and the only answer was a precondition
failure. <!-- src: Bytes/Sources/BytesCrypto/TLSRecord.swift TLSRecordOpener maximumUnitByteCount, minimumOutputCapacity; Bytes/Sources/Bytes/Pipeline.swift Pipeline.init and transform; Bytes/Sources/Bytes/Bytes.docc/UnderstandingTheTypes.md "Buffers, copies, and pipelines"; Bytes/OPTIMIZATION.md (old version) §10 "Declared units" -->

#### One end-of-stream rule

At `.finish`, every stage either returns `.finished` once all its output is delivered (`.needsOutput` until then) or throws
because its input ended early. With one rule, a loop that drives a stage needs no knowledge of its kind. It stops at `.finished`,
and `.needsInput` only ever means "more input, please". `transform(_:appending:flush:growth:)` is that loop, written once. <!-- src: Bytes/Sources/Bytes/Pipeline.swift ByteTransform doc comment "The end of a stream" -->

The rule has a consequence for composition: **a pipeline ends when its last stage ends.** That is right when the last stage is the
one that knows where the data stops, and wrong when a stage before it knows. HTTP's chunked coding followed by gzip ended a message body where the gzip stream ended,
which let bytes inside the chunked body after the stream be read as the next message (request smuggling). A framing stage must
not be followed by one that can end first: put both in one stage that ends where the framing does and requires the coded
stream to end exactly there (HTTPBytes' `HTTPBodyDecoder`; [section 12 of Part III](#round-2-bodies-as-pipeline-stages-and-why-a-body-is-one-stage)).<!-- src: AGENTS.md "A pipeline ends when its last stage ends: a framing stage must not be followed by one that can end first"; HTTPBytes/RESULTS.md "round 2, bodies as pipeline stages" -->

### 11. Async: `BytesAsync`

`BytesAsync` is the asynchronous side: the same stages with calls that may suspend, and the parallel codecs' async forms.

#### `AsyncByteTransform`

`AsyncByteTransform` is `ByteTransform` with an `async` requirement, declared `nonisolated(nonsending)`. The call runs on
its caller's executor (whatever runs the caller's code: an actor, or the shared pool of threads) and does not hop to
another. It must, because the call borrows the caller's `inout OutputRawSpan`, which cannot cross to another isolation
domain (another actor, or code outside any actor). <!-- src: Bytes/Sources/BytesAsync/AsyncByteTransform.swift doc comment -->
Part IV (["Isolation, actors, and where a function runs"](#13-isolation-actors-and-where-a-function-runs)) explains these terms. Any `ByteTransform` becomes an
`AsyncByteTransform` in one of three ways:

| Adapter | Where the stage's calls run | When |
|---|---|---|
| `synchronously()` | in place, on the caller's executor, without suspending | composing with async stages |
| `concurrently()` | in a `@concurrent` function: Swift's global concurrent executor, in the calling task | the structured default for heavy stages |
| `offloaded(to: queue)` | on a Dispatch queue | work that must stay off the cooperative pool's threads (one per core, shared by every task), or on a queue of its own |

<!-- src: Bytes/Sources/BytesAsync/AsyncByteTransform.swift adapters -->

`concurrently()` is `@concurrent` work in the caller's task. It inherits the task's priority and task-local values; a
caller that is already off any actor (a nonisolated task) runs the stage *without a thread switch*, and a caller on an
actor hops off and back for each call. The whole mechanism is one function:

```swift
@concurrent
func perform<T: Sendable>(_ work: @Sendable () -> T) async -> T {
    work()
}
```

<!-- src: Bytes/Sources/BytesAsync/Offloading.swift perform(_:) -->

The closure is non-escaping, so it allocates nothing. The Dispatch form (`perform(on:)`) waits with `withUnsafeContinuation`
(a continuation suspends the task until something calls `resume` on it), because a checked continuation allocates its
checker per call; the block resumes it exactly once, after the work returns. <!-- src: Bytes/Sources/BytesAsync/Offloading.swift perform(on:_:) comment --> For DEFLATE level 1 in
64 KiB calls, `concurrently()` took the same time as running in place, and a Dispatch queue hop cost +7%. <!-- src: AGENTS.md Lessons "Offload synchronous work with a @concurrent function taking a non-escaping @Sendable closure" --> Part IV (["Tasks,
executors, and the cooperative pool"](#11-tasks-executors-and-the-cooperative-pool)) covers executors and the hop itself. For the API, the consequence is that a heavy
stage uses `concurrently()` unless it must not occupy a cooperative thread.

The stage and the buffers reach the other executor through lending ([section 9](#9-buffers-and-moving-bytes)). `transformLending` takes a pointer to the
stage (the stage is `inout` for the whole call, so it stays put), lends the input and the output's free capacity, awaits
the work, and returns the progress. Neither form can stop a synchronous stage midway; the caller's loop sees cancellation
between calls. <!-- src: Bytes/Sources/BytesAsync/AsyncByteTransform.swift transformLending; Bytes/Sources/BytesAsync/Offloading.swift header comment -->

#### Receiving into a buffer

`ByteBuffer.receive` is `fill` for a source that suspends (a socket read), and it runs on the caller's executor. It has a
separate name rather than being an `async` overload of `fill`, because with a closure that names its error type, Swift 6.4
finds such a call ambiguous from async code, even when the closure does not suspend. <!-- src: Bytes/Sources/BytesAsync/Buffers.swift doc comment --> `receive` is the reason
`ByteBuffer`'s storage never moves ([section 9](#9-buffers-and-moving-bytes)).

#### The parallel codecs, asynchronously

Each parallel encoder has three entry points (`ParallelDeflateDecoder` has the first two, as `decompressAll`):

- synchronous, `compressAll(_:into:)`: the workers run on Dispatch's `concurrentPerform`, the calling thread among them;
- `compressAll(_:into:on: queue)`: the whole call moves to a queue, and the calling task suspends, leaving its thread free;
- `compressAllConcurrently(_:into:)`: the workers are child tasks of a task group on the cooperative pool.

The task group was up to 10% faster than `concurrentPerform` in the harness and 0–7% faster in the benchmarks, but it
occupies the cooperative pool's threads for the whole call. <!-- src: Bytes/Sources/BytesCompression/ParallelDeflate.swift doc comment; Bytes/Sources/BytesAsync/ParallelCodecs.swift; Bytes/Benchmarks/RESULTS.md "Parallel compression: a chunk scheduler instead of rounds" -->

**Cancellation.** A task cancellation handler stops the call's workers: they take no more chunks or segments (those under way
finish, because a chunk cannot stop midway), and the call throws `BytesError.cancelled`, keeping its typed throws. The output
is incomplete (an encoder writes no trailer, the decoder writes nothing), and the codec can be used again; a call that had
already delivered everything returns normally. The stop flag is an `Atomic<Bool>`, read with relaxed ordering when a
worker claims its next chunk, so the synchronous forms' instruction counts did not change. <!-- src: Bytes/Sources/BytesAsync/ParallelCodecs.swift header comment; Bytes/Benchmarks/RESULTS.md "Cleanup and improvements (2026-11-19)" Merge-time changes -->

#### Waiting primitives: one implementation each

Disk, NativeAEA, and NativeZip each had to make tasks wait: for a free buffer, a job, room in a queue, a file-system
permit. Two of them had written the same 160 lines word for word, and the third had its own hand-rolled version. The
primitives are now in `BytesAsync` once, and all three packages use them:

| Primitive | What it does |
|---|---|
| `Continuation<T>`, `withContinuation(_:)` | a suspended task, resumed exactly once: a `CheckedContinuation` in debug builds, an `UnsafeContinuation` (no allocation per wait) in release |
| `WaiterQueue<Element>` | a first-in, first-out ring for waiters, storage reserved up front, growing (doubling) only past its capacity; unsynchronized, for state inside its owner's lock |
| `AsyncLimiter` | at most *n* tasks in a section; each permit returned goes to the task that has waited longest |
| `AsyncIndexPool` | a fixed set of indexes (slots of a table, buffers of a pool) handed out one at a time; the last released is the first handed out, since its memory is the warmest |
| `AsyncLatch` | a countdown a task waits on |
| `AsyncQueue<Element>` | a bounded queue between tasks; an element pushed while a consumer waits goes straight to it |
| `AsyncHandoff<Element>` | a rendezvous of one producer and one consumer |
<!-- src: Bytes/Sources/BytesAsync/Waiting.swift (Continuation, withContinuation, WaiterQueue doc comments); AsyncLimits.swift (AsyncLimiter, AsyncIndexPool, AsyncLatch doc comments); AsyncQueue.swift (AsyncQueue, AsyncHandoff doc comments); Bytes/Benchmarks/RESULTS.md "2026-11-21, the waiting primitives and RawStorage" table -->

Every one follows the pattern in `Waiting.swift`'s header, which is [Part IV](#16-continuations-checked-and-unsafe)'s
rule for waits made concrete:

1. A synchronous fast path under the lock: take what is there and return without suspending.
2. No lost wake-ups: the slow path stores its continuation in the same critical section that checks again, and the side
   that would wake it looks for a waiter under the same lock.
3. Resume outside the lock, after removing the waiter from its queue under it, exactly once; closing a primitive resumes
   every waiter it holds.

```swift
let fileSystem = AsyncLimiter(6)          // at most 6 tasks in the kernel's file creation at once
await fileSystem.acquire()
defer { fileSystem.release() }

let jobs = AsyncQueue<Job>(capacity: 64, waiters: workers)
for job in work { await jobs.push(job) }              // producer; each worker: while let job = await jobs.pop() { run(job) }
jobs.close()
```
<!-- src: Bytes/Sources/BytesAsync/AsyncLimits.swift AsyncLimiter doc comment; AsyncQueue.swift AsyncQueue doc comment (adapted); Waiting.swift header comment -->

The move cost nothing, because of how the types are declared: each is `@frozen` or keeps `@usableFromInline` state and has
`@inlinable` methods, so each client compiles its own specialized copy. The check is `Tools/calls --target Disk Disk '.*'
--callee 'BytesAsync|swift_getGenericMetadata' --sum`: it finds `specialized WaiterQueue.append` and `AsyncLimiter.acquire()`
emitted inside Disk, and no call into BytesAsync's unspecialized generics. In the clients' benchmarks, mallocs and
file-system calls were identical in every row, and instructions stayed within the rows' spread; the new calls are
`RawStorage`'s metadata accessor (where a buffer is allocated, once per writer or decoder) and its out-of-line `advise`.
Two things stayed where they were, because each has one user or its own layout: Disk's write queue (jobs plus a ring of path
bytes, producers woken at a low-water mark) and NativeAEA's segment buffer pool (carry regions, reference counts).
<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-21, the waiting primitives and RawStorage" bullets "How they stay free across modules" and "Not moved"; Disk/RESULTS.md "2026-11-21: the last cleanup" section 1 (the `Tools/calls` check; "Not moved") -->

Two traps came with the move. SocketStream's PR toolchain warned that the queue's and the handoff's decision enums "cannot be
returned" from `Mutex.withLock` (region isolation), which Xcode's compiler had accepted; the enums are `Sendable` now,
so build new BytesAsync API with the PR toolchain too. And the sync/async overload trap of [Part
IV](#5-limitations-and-compiler-bugs-met-in-concurrency-and-nearby) holds across modules: Disk cannot call BytesAsync's
`RawSpan.withLentBytes` with a closure that names its error type, because Bytes' synchronous method of the same name is then
ambiguous, so its writers keep a two-line helper.
<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-21, the waiting primitives and RawStorage" bullets "A PR-toolchain-only warning" and "Not moved" (Disk's `withUnsafeBytesAsync`); AGENTS.md "Build new Bytes API with SocketStream's PR toolchain as well" -->

#### Counting, time, and priority

Waits need counters, and an `Atomic` cannot be copied, so an array or a closure cannot hold one. **`RelaxedCounter`** is
a class around `Atomic<Int>` with relaxed ordering: statistics (calls made, bytes written, nanoseconds waited) and the next
index of a work queue, `claim(below:)`, which gives each of 0 through *n* − 1 to exactly one caller. Relaxed means it says
nothing about other memory, so a reference count whose last release frees a buffer uses the `atomic` property with the
ordering it needs.

```swift
let next = RelaxedCounter()
// In each worker:
while let index = next.claim(below: items.count) { process(items[index]) }
```
<!-- src: Bytes/Sources/BytesAsync/Counting.swift RelaxedCounter doc comment -->

**`RelaxedCounters`** is *N* of them in one allocation (a `ManagedBuffer` of `Atomic<Int>`, wrapped in an `@unchecked
Sendable` struct, because `ManagedBuffer` is explicitly not `Sendable` and a subclass declaring it warns). Disk's writer
timings (11 kinds) and syscall counters, and NativeAEA's buffer reference counts, had been arrays of `RelaxedCounter`
objects: one allocation for each plus one for the array. As one `RelaxedCounters`, Disk's extractions make 11 fewer mallocs
each (a single writer 83 to 72, 20,000 files 145 to 134), and NativeAEA's, 30 to 36 fewer (M1 Max, two interleaved rounds).
<!-- src: Bytes/Sources/BytesAsync/Counting.swift RelaxedCounters doc comment and `Storage`; Disk/RESULTS.md "2026-11-22, late: access by usage, typed timing keys, one allocation for counters" table row "Mallocs, every extraction row" (single writer 83 → 72, 20,000 files 145 → 134); NativeAEA/RESULTS.md "2026-11-22, late: …" table row "Extract: synthetic" (mallocs 377–486 → 341–454, −30 to −36: the pool's counters and Disk's 11); AGENTS.md "ManagedBuffer is explicitly not Sendable" -->

`MonotonicClock` reads `CLOCK_UPTIME_RAW` in nanoseconds (it does not jump with the wall clock or advance while the machine
sleeps), for timings. And **`withPriority(_:operation:)`** runs work in a child task at a priority of its own, because a
program's main task is not where its work should run: an async `main` runs at priority 21, not user-initiated, and a GUI
app with no frontmost window can have its work scheduled at background quality of service, on the efficiency cores. It is
one task group with one child, so it keeps the caller's cancellation and task-locals and passes the error type through.
The effect in the app is in Part III, ["Nunarchiver"](#nunarchiver-the-app-and-its-two-traps).
<!-- src: Bytes/Sources/BytesAsync/Counting.swift MonotonicClock; Bytes/Sources/BytesAsync/Offloading.swift `withPriority` doc comment ("a command-line tool's main task (which runs at the default priority, not user-initiated) or a GUI app that may be in the background (where its work would run at background QoS, on the efficiency cores)"); NativeAEA/ARCHITECTURE.md §1 and NativeAEA/RESULTS.md "What mattered" ("the async main task is at 21") -->

### 12. Codec and crypto entry points

This section is about the *shape* of the codec and crypto APIs: what you call, what you must provide, and what they promise
not to allocate. How the codecs get their speed is the subject of Part III (["Algorithms and data structures, codec by
codec"](#8-algorithms-and-data-structures-codec-by-codec)).

#### The formats

| Format | Types | Direction |
|---|---|---|
| DEFLATE, zlib, gzip, Deflate64 | `DeflateEncoder(format:level:)`, `DeflateDecoder(format:)` (`DeflateFormat`: `.raw`, `.zlib`, `.gzip`), `DeflateDecoder(variant:)` (`DeflateVariant`: `.deflate`, `.deflate64`, raw only) | both (Deflate64 decode only) |
| Brotli | `BrotliEncoder(quality:windowBits:)`, `BrotliDecoder` | both |
| Zstandard | `ZstdDecoder`, `ZstdFrameHeader`, `XXHash64`; `ZstdEncoder(level:windowLog:checksum:)` (levels 1–4, `ZstdEncoder.Parameters`) | both (encoding at libzstd's levels 1–4) |
| LZ4 | `LZ4Decoder` (`decompressRaw`, `decompressFramed`) | decode |
| LZMA, LZMA2, `.xz` | whole output: `LZMA2Decoder` (`decompressLZMA2`, `decompressLZMA`, `decompressLZMAFile`, `decompressXZ`); streaming: `LZMADecoder` (raw LZMA1), `XZDecoder`; `CRC64` | decode |
| bzip2 | `BZip2Decoder` (`decompressAll`, and streaming `decompress(_:into:)`) | decode |
| Apple's LZFSE, LZVN, LZBITMAP, LZRAVEN | `LZFSEDecoder`/`LZFSEEncoder`, `LZVNDecoder`/`LZVNEncoder`, `LZBitmapDecoder`/`LZBitmapEncoder`, `LZRAVENDecoder` | LZFSE, LZVN, LZBITMAP both; LZRAVEN decode |
| parallel | `ParallelDeflateEncoder`, `ParallelDeflateDecoder`, `ParallelBrotliEncoder` | the parallel forms of the above |
| any of the above that decodes | `Decompressor`, `DecompressionFormat` | decode |

<!-- src: Bytes/Sources/BytesCompression/*.swift public types (grep of `^public struct`); Deflate.swift `DeflateVariant`; DeflateDecoder.swift `init(variant:)`; LZMAStreaming.swift `LZMADecoder`; XZDecoder.swift `XZDecoder`; BZip2Streaming.swift `decompress(_:into:)`; Decompressor.swift `DecompressionFormat`; AGENTS.md Repository table (BytesCompression row) -->

#### One shot, streaming, and parallel

Every codec has the same shapes, borrowed from zlib:

- **One shot.** `compressAll(_:into:)` and `decompressAll(_:into:)` take the whole input and an `inout OutputRawSpan`.
  `decompressAll` decodes *straight into the caller's output*, with no window and no copy (the output is the history),
  which makes it the fastest way to decode. The encoder's `compressAll` searches the caller's input directly.
  `maximumCompressedSize(forByteCount:)` gives a size no stream of that input exceeds (for DEFLATE,
  `byteCount + byteCount / 800 + 64`). <!-- src: Bytes/Sources/BytesCompression/DeflateDecoder.swift doc comment; DeflateEncoder.swift maximumCompressedSize; ZstdDecoder.swift doc comment ("the output is the history, so there's no window and no copy") -->
- **Streaming.** `compress(_:into:flush:)` and `decompress(_:into:)` take input in pieces and return a `TransformProgress`
  (`consumed`, `produced`, a status); input can be split anywhere, and the streaming forms keep a window of their own
  (32 KB of history for DEFLATE, a window that wraps for Zstandard). The DEFLATE and Brotli encoders and decoders are also
  `ByteTransform`s (and `ResettableByteTransform`s), so they drop into a `Pipeline`, and so is `ZstdEncoder`. <!-- src: Bytes/Sources/BytesCompression/DeflateEncoder.swift, DeflateDecoder.swift, Transforms.swift (`extension ZstdEncoder: ByteTransform` and `: ResettableByteTransform`); ZstdDecoder.swift -->
  The LZMA, xz, and bzip2 decoders stream too (below), and so does DEFLATE *into the caller's own buffers*:
  `decompress(_:into:historyCount:)` decodes after `historyCount` bytes of history that the caller keeps at the front of
  its buffer (at least `historySize`: 32 KB, or 64 KB for Deflate64), so the decoder keeps no window of its own and
  copies nothing out of one. A caller with two 1 MB buffers moves the last window's worth of output to the front of the
  next one between calls; in 1 MB chunks it ran within 0.5% of the instructions of one call for the whole stream, and
  the benchmark rows for the history form read the same as `decompressAll`. <!-- src: Bytes/Sources/BytesCompression/DeflateDecoder.swift `decompress(_:into:historyCount:)` doc comment ("In 1 MB chunks … within 0.5% of the instructions of one call for the whole stream"); Bytes/Benchmarks/RESULTS.md "Streaming decoders for NativeZip (2026-11-22, M1 Max; …)" table row "Inflate … history 1 MB (new, dickens, x-ray, Main.css)": "same as `decompressAll`", 0 -->
- **Decoders that streamed by their window, not their loop.** LZMA, xz, and bzip2 decoded only into a whole output buffer
  (the output was their history). Making them streaming kept their decode loops and changed what is around them; see
  [section 8](#8-algorithms-and-data-structures-codec-by-codec).
- **Parallel.** `ParallelDeflateEncoder(format:level:chunkSize:lanes:independentChunks:)` compresses `chunkSize`-byte chunks
  (256 KB by default, at most 512 KB; a one-shot call over a large input cuts up to four chunks per lane, none under 64 KB)
  on `lanes` lanes at once. `lanes` is usually every core (the streaming form, one chunk per lane a round, wants the
  performance cores).
  `ParallelDeflateDecoder(format:lanes:)` decodes in parallel *if the stream allows it*. It guesses block boundaries (a
  `00 00 FF FF` marker, a sync flush that a block header could follow), decodes segments speculatively, and accepts segment
  *j* only if segment *j−1* ended exactly at its start. It cuts up to four segments per lane (`segmentsPerLane`), taken in
  order by whichever lane is free, so a slow lane (a busy or efficiency core) holds up one small segment rather than a whole
  share of the stream. A wrong guess costs only its own segment: a segment that ends inside a block decodes on to the next
  split, and a failed one is decoded again in place.

  Streams from `ParallelDeflateEncoder` with `independentChunks`, from pigz `-i`, and zlib streams with full flushes decode
  in parallel. Streams whose matches cross every split decode their first segment in parallel and the rest sequentially.
  `lastSegmentCount` says which happened. <!-- src: Bytes/Sources/BytesCompression/ParallelDeflate.swift init and doc comment (chunksPerLane, lanes: every core); ParallelInflate.swift doc comment (rules 1–4), lastSegmentCount; Bytes/Benchmarks/RESULTS.md "2026-11-20, parallel DEFLATE: no fallback at any lane count; joins overlap decoding" -->

A complete one-shot encode, using a `ByteBuffer` as the output:

```swift
var encoder = DeflateEncoder(format: .gzip, level: 6)          // allocates tables and buffers (about 1.5 MB) once
var buffer = ByteBuffer(capacity: DeflateEncoder.maximumCompressedSize(forByteCount: body.byteCount, format: .gzip))
try buffer.fill { (output: inout OutputRawSpan) throws(BytesError) in
    try encoder.compressAll(body, into: &output)               // body: RawSpan
}
// buffer.unread is the gzip stream
encoder.reset()                                                // the next stream reuses the allocations
```

<!-- src: Bytes/Sources/BytesCompression/DeflateEncoder.swift doc comment and init; Bytes/Sources/Bytes/Buffers.swift ByteBuffer.fill -->

`ZstdEncoder` has the same shapes, with the parameters libzstd has. `init(level:windowLog:checksum:)` takes libzstd's level (1
through `ZstdEncoder.Parameters.maximumLevel`, 4) and optionally a smaller window; `init(parameters:checksum:)` sets the strategy
(`.fast` or `.doubleFast`), `windowLog` (10 through 27), `hashLog`, `chainLog`, `minimumMatchLength`, and `targetLength` one at a time,
as the `ZSTD_c_*` parameters. `compressAll` makes a whole frame, stating its content size, and
`maximumCompressedSize(forByteCount:)` bounds it. `compress(_:into:flush:)` takes the input in pieces (`.flush` ends a block so everything
so far decodes, `.finish` ends the frame), and `reset(contentSize:)` states the size to a streaming frame. A frame is a single segment
only when its content size is known and fits the window, so no frame needs a larger window than `windowLog`:
`Parameters.httpWindowLog` (19, 512 KB) is the window for HTTP's `zstd` coding, where RFC 9659 caps it at 8 MB.

```swift
var encoder = ZstdEncoder(level: 3, windowLog: ZstdEncoder.Parameters.httpWindowLog)   // allocates its tables once
try encoder.compressAll(body, into: &output)                  // a whole frame: libzstd's, byte for byte, at the same parameters
encoder.reset()                                               // the next frame; the tables are not cleared
var progress = try encoder.compress(chunk, into: &output)     // or in pieces
progress = try encoder.compress(lastChunk, into: &output, flush: .finish)
```
<!-- src: Bytes/Sources/BytesCompression/ZstdEncoder.swift doc comment (the example), `Parameters` (strategy, windowLog 10–27, hashLog, chainLog, minimumMatchLength, targetLength; `maximumLevel` 4; `httpWindowLog` 19), `init(level:windowLog:checksum:)`, `init(parameters:checksum:)`, `maximumCompressedSize(forByteCount:)`, `reset(contentSize:)`, `compressAll`, `compress(_:into:flush:)`; Bytes/Benchmarks/RESULTS-zstd-encoder.md "What it is" (single-segment frames; "RFC 9659 caps `zstd` content coding's window at 8 MB") -->
How it was made, and what it measured against libzstd, is in [Part III section 8](#zstandard-encoding).

#### Reusable state, workspaces, and what allocates

The state of every encoder and decoder is `~Copyable`. It is allocated once at initialization (tables, window, staging
buffers), and `reset()` prepares it for the next stream, keeping the allocations. After that, encoding and decoding
allocate nothing, in any of the three builds ([section 15](#15-builds-and-traits-optimized-portable-and-no-c)). <!-- src: Bytes/OPTIMIZATION.md (old version) §10 "Compression: DEFLATE and Brotli, both directions"; Bytes/Sources/BytesCompression/DeflateEncoder.swift ("Encoding allocates nothing after initialization") -->
The exceptions are documented:

- `ZstdDecoder` allocates its tables and a 160 KB literal buffer at creation. Streaming adds the window (window size +
  128 KB + 64) and a 128 KB input stash on the first frame, growing only for a larger window. Frames needing more than
  `maximumWindowSize`, 128 MB by default, are rejected before anything is allocated.
- `ZstdEncoder` allocates its tables at creation (`memoryUsage`: 1,455,552 bytes at level 3), and a window for `compress(_:into:flush:)`
  as streams need it, up to the window plus a block (2,110,912 bytes in all with the HTTP window, 3,683,776 with level 3's own).
  After that, with the encoder reused, encoding allocates nothing: gates `Allocations:Zstd_encode_L1`, `_L3`, `_L1_streaming`, and `_L3_streaming` are 0.
  <!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md "Memory (bytes)" table (level 3: tables 1,455,552; streaming 2,110,912 with w19, 3,683,776 with w21) and "What it is" "Allocations" bullet -->
- The parallel codecs allocate the thread pool's bookkeeping per call, never in the compression itself:
  `concurrentPerform` measured 11 mallocs on 8 lanes and 27 on 24, plus one more since the scheduler holds its worker as
  a closure; a task group, 34 and 98. <!-- src: Bytes/Benchmarks/RESULTS.md "Zstandard decoding … Allocations"; "Parallel compression: a chunk scheduler instead of rounds" Allocation bullet; "2026-11-17, the proposals pass" ("Sync parallel DEFLATE allocates once more per call (11 → 12)") -->

A repeated parallel decode allocates nothing once the segment buffers have grown to the size of the stream's output. <!-- src: Bytes/Sources/BytesCompression/ParallelInflate.swift doc comment -->

Where an algorithm needs scratch memory that the caller may want to supply, the API takes it as a parameter, a **workspace**.
`Scrypt.deriveKey(password:salt:cost:blockSize:parallelism:lanes:scratch:into:)` takes `scratch` of at least
`Scrypt.scratchByteCount(cost:blockSize:parallelism:lanes:)` bytes (its ROMix table alone is 16 MiB for N = 2¹⁴, r = 8) and
allocates nothing; the other form allocates exactly that one buffer per call. <!-- src: Bytes/Sources/BytesCrypto/Scrypt.swift doc comment -->

The allocation behavior is *gated*. Workloads that should not allocate are also registered as `Allocations:` benchmarks
(one per workload, or one gate for a group of them), which count `malloc` calls against static threshold files. Every
threshold is zero but one: a `for`-`in` over a `let` reader, held at 1. <!-- src: Bytes/Benchmarks/RESULTS.md "Allocation checks"; "Benchmark coverage pass (2026-11-19)" (gates combined into `Allocations:Read_all_workloads` and others; `Read: for-in Bytes (UInt8)` kept alone at threshold 1); AGENTS.md Lessons "Allocations: package-benchmark's malloc counter with a Thresholds/ file at 0 is the gate" -->

#### One decoder over every format: `Decompressor`

A client that chooses its format at run time (an archive reader meeting one method after another, an encrypted archive's
segments in several codecs) should not write a `switch` over twelve formats and keep a decoder of each alive.
**`Decompressor`** is that switch, written once. A `DecompressionFormat` names the stream (`.deflate(.raw)`, `.deflate64`,
`.brotli`, `.zstd`, `.bzip2`, `.lzma(properties, uncompressedSize:, sizeHint:)`, `.xz(sizeHint:)`, `.lzfse`, `.lzvn`,
`.lz4(framed:)`, `.lzbitmap`, `.lzraven`), carrying what the container records about it; `reset(for:)` starts a stream.

```swift
var decompressor = Decompressor()                                      // no state yet
try decompressor.reset(for: .xz(sizeHint: entry.uncompressedSize))     // zip's method 95: this format's state is made now
let progress = try decompressor.decompress(payload, into: &output)     // a ByteTransform-style streaming call

try decompressor.reset(for: .lzfse)                                    // whole buffers only: no streaming form
let consumed = try decompressor.decompressAll(segment, into: &output, decodedSize: rawSize)
```
<!-- src: Bytes/Sources/BytesCompression/Decompressor.swift `DecompressionFormat` and `Decompressor` doc comments (examples adapted) -->

Three properties make it cost nothing beyond a `switch`. Each format's state is made on that format's first stream and
kept, so a client decoding many entries allocates nothing after each format's first (the `Allocations:Decompressor_every_format`
gate reads 0). Each call goes to the format's own decoder, `DeflateDecoder`, `BZip2Decoder`, `XZDecoder`, and so on, so
their loops are the ones the codec sections measure. And the state a format does not need is not built: LZMA and xz state
made on the first *streaming* call means a whole-buffer decode no longer builds two probability models. `isStreamable` says
which formats decode in pieces (DEFLATE, Deflate64, Brotli, Zstandard, bzip2, LZMA, xz) and which only whole (Apple's LZ
formats and LZ4); `historySize` is non-nil for the two DEFLATE variants, whose callers keep the history.
The streaming xz row through `Decompressor` ran 618 M instructions, the same as the `XZDecoder` row it wraps.
<!-- src: Bytes/Sources/BytesCompression/Decompressor.swift (`isStreamable`, `historySize`, "Each call goes to the format's own decoder … after one `switch`: their loops are unchanged"); Bytes/Benchmarks/RESULTS.md "Cleanups after the unification (2026-11-22, M1 Max; …)" bullet "Decompressor/DecompressionFormat" ("`Decompressor xz -6 dickens: 1 MiB out` (618 M, the same as `LZMA stream xz -6 dickens: 1 MiB out`) and `Allocations:Decompressor_every_format` (0)") -->

NativeZipArchive's `ZipDecoder` drives one `Decompressor` for every zip method, and NativeAEA's segments decode through one
(Part III, ["NativeZipArchive"](#nativeziparchive-the-kernel-is-the-limit) and ["NativeAEA"](#nativeaea-a-decode-pipeline-against-a-file-system)).

#### Crypto

`BytesCrypto` has no CryptoKit or CommonCrypto dependency. Its AEADs (authenticated encryption: `seal` encrypts a message
and returns a tag over it and a header, and `open` checks the tag) encrypt and authenticate *in place* and allocate
nothing:

```swift
let aead = ChaCha20Poly1305(key: key)                                         // 32 bytes (AESGCM: 16, 24, or 32)
let tag = aead.seal(&message, nonce: nonce, authenticating: header)           // message: MutableRawSpan, now ciphertext
try aead.open(&message, nonce: nonce, authenticating: header, tag: tag.span.bytes)   // throws .mismatch if forged
```

<!-- src: Bytes/Sources/BytesCrypto/ChaCha20Poly1305.swift doc comment; AESGCM.swift doc comment -->

`seal` returns the tag as `InlineArray<16, UInt8>`. `open` authenticates before releasing plaintext: on a forged message it
throws with the buffer holding the ciphertext it was given. For messages of 128 bytes or more (AES-GCM) and 512 bytes or
more (ChaCha20-Poly1305), it decrypts and authenticates in one pass. During the call the buffer may then briefly hold a
forged message's decryption, which is encrypted back (the same keystream XORed again) before `open` throws, so do not read
the buffer from another thread while `open` runs. <!-- src: Bytes/Sources/BytesCrypto/AESGCM.swift doc comment; ChaCha20Poly1305.swift open() -->
The rest of the surface:

- **Hashes and MACs:** `SHA1`, `SHA256`, `SHA384`, `SHA512` (conforming to `HashFunction`: `update`, `finalize`, `hash`;
  SHA-384/512 run on ARM's SHA-512 instructions under `HardwareCrypto`, 1 MB in 4.01 M instructions against 38 M without
  them, and CryptoKit's 4.34 M <!-- src: Bytes/Benchmarks/RESULTS.md "Crypto cleanup (2026-11-19)" table, SHA-512 1 MB -->),
  `HMAC<H>`, `PBKDF2.deriveKey`, and `HKDF<H>` (`extract`, `expand`, and `HKDF<H>.Expander`, which keys the HMAC once for
  any number of `expand(info:into:)` calls). TLS traffic keys expand the key and IV from one expander, saving two
  compressions per direction. These types share CryptoKit's names, so code importing both qualifies them
  (`CryptoKit.AES.GCM`). <!-- src: Bytes/Sources/BytesCrypto/SHA.swift, KeyDerivation.swift; Bytes/Benchmarks/RESULTS.md "Crypto cleanup (2026-11-19)"; AGENTS.md Lessons "Bytes' crypto types share CryptoKit's names" -->
- **TLS 1.3:** `TLSKeySchedule`, `TLSSecret`, `TLSTrafficKeys`, `TLSTranscript`, `TLSAlert`, and the record layer
  `TLSRecordSealer(keys:)` and `TLSRecordOpener(keys:)` (both `ByteTransform`s). A sealer made from a traffic secret
  updates its keys before the suite's record limit and sends the KeyUpdate message itself. With `sealingLanes` above 1,
  it seals full records in parallel, each straight into its place in the output. <!-- src: Bytes/Sources/BytesCrypto/TLS.swift, TLSRecord.swift; Bytes/Benchmarks/RESULTS.md "crypto in Swift, TLS 1.3, parallel sealing" -->
- **Public-key, no signing:** `P256` and `P384` (ECDSA verification and ECDH, keys and signatures in raw, X9.63, DER, and
  PEM forms; signing is not implemented), `RSA` PKCS #1 v1.5 verification, `HPKE`, `X509Certificate` (a non-escapable
  view over the DER, with `isSigned(by:)`), `PEM`, and `Scrypt`. <!-- src: Bytes/Sources/BytesCrypto/NISTCurves.swift doc comment; X509Certificate.swift; AGENTS.md Repository table (BytesCrypto row) -->

Zero-malloc gates cover the AEADs, TLS, the hashes with HMAC and HKDF, PBKDF2, ECDSA/ECDH P-384, HPKE, and the TLS
pipelines. <!-- src: Bytes/Benchmarks/RESULTS.md "Crypto cleanup (2026-11-19)" ("Zero-malloc gates for …: all still 0") --> For scale, sealing 1 KB messages 1,024 at a time,
AES-128-GCM takes 237 µs against CryptoKit's 956, because CryptoKit's per-call setup and allocation dominate below 16 KB.
For one 1 MB message, CryptoKit's hand-written assembly is faster (109 µs against 116). <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "AES-128-GCM seal 1 KB (x1024): Bytes" 236,799 ns and ": CryptoKit" 956,415, "AES-128-GCM seal 1 MB (x1): Bytes" 116,095 and ": CryptoKit" 108,991; earlier: Bytes/Benchmarks/RESULTS.md "crypto in Swift, TLS 1.3, parallel sealing" table (d2-final); Bytes/OPTIMIZATION.md (old version) "AES-GCM and TLS 1.3 in Swift" (per-call setup and allocation; hand-written assembly) -->

### 13. `BytesBase64` and `BytesFoundation`

#### Base64

`BytesBase64` encodes and decodes RFC 4648 Base64 from an `AlignedBytesReader` into an `AlignedBytesWriter`, with no
allocation:

```swift
var reader = AlignedBytesReader(bytes.span)
var output = [UInt8](repeating: 0, count: Base64.encodedByteCount(of: bytes.count))
var span = output.mutableSpan
var writer = AlignedBytesWriter(&span)
try Base64.encode(&reader, into: &writer)

let text = Base64.encodedString(bytes.span.bytes, alphabet: .urlSafe, padding: false)   // one allocation: the String
let back = try Base64.decodedBytes(text)                                                // throws LocatedBytesError
```

<!-- src: Bytes/Sources/BytesBase64/Base64.swift doc comment, encodedString; Decoding.swift decodedBytes -->

Decoding is strict and all or nothing. Every character must be in the alphabet, the padding must be exact, and the last
character's unused bits must be zero (RFC 4648 section 3.5), so each text has exactly one decoding. On failure the error
is a `LocatedBytesError` (what went wrong and where), the reader has not moved, and the writer is back where it started. `decode(ignoringWhitespaceIn:into:…)` skips
whitespace for PEM. <!-- src: Bytes/Sources/BytesBase64/Decoding.swift doc comment; Bytes/Sources/Bytes/BytesReader.swift LocatedBytesError -->

Base64 is the library's worked example of every technique in this part, so this section shows the encoder kernel as the
compiler built it. The Swift for one 48-byte block is:

```swift
let source = bitCast(block, to: InlineArray<3, SIMD16<UInt8>>.self)
let (first, second, third) = ByteLanes.deinterleave(source[0], source[1], source[2])   // what ld3 does, in registers
let (c0, c1, c2, c3) = ByteLanes.interleave(                                            // zips
    ByteLanes(first &>> 2).lookup(in: table),                                           // tbl: 6-bit value → character
    ByteLanes((first &<< 4 | second &>> 4) & 0b11_1111).lookup(in: table),
    ByteLanes((second &<< 2 | third &>> 6) & 0b11_1111).lookup(in: table),
    ByteLanes(third & 0b11_1111).lookup(in: table))
```

<!-- src: Bytes/Sources/BytesBase64/Base64.swift encodeBlock -->

Three input bytes `aaaaaabb bbbbcccc ccdddddd` become four 6-bit values, `aaaaaa`, `bbbbbb`, `cccccc`, `dddddd`, each
mapped to a character. `deinterleave` puts every third byte in its own vector (so lane *i* of `first` is byte 3*i* of the
block), which makes each of the four values a shift or two of a whole vector, and the table lookup maps 16 values at once.

Part I (["A worked example: the Base64 encoding kernel"](#38-a-worked-example-the-base64-encoding-kernel)) walks through the compiled loop: 32 instructions per block, one
bounds check before the loop and none inside it ([section 1](#1-borrowed-memory-spans-and-inlinearray)'s typed-span loop), no scalar loads or branches, and the
second round of interleaving folded by LLVM into `st2` stores. It runs at about 9.5 cycles per block (3.4 instructions per
cycle). <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): Base64Benchmarks row "Encode 1 MB: Bytes (BytesReader → BytesWriter)", 20.39 GB/s at 4.02 GHz and 32.0 instructions per block; Bytes/Benchmarks/RESULTS-base64.md "Current" bullets ("Per block … 32 per 48-byte block, at about 9 cycles per block"); disassembly of Base64.encodeBlocks in Bytes/.build/agent-tools/BytesBase64.o -->

Encoding throughput on one core, in GB/s of input (the latest M3 Ultra run, baseline `m3-final`):

| Input | `BytesBase64` | Foundation `base64EncodedData()` | scalar table loop |
|---|---|---|---|
| 64 B | 5.49 | 0.64 | 0.87 |
| 1 KB | 17.2 | 2.45 | 0.79 |
| 1 MB | **20.4** | 3.23 | 0.88 |

<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): Base64Benchmarks rows "Encode {64 B, 1 KB, 1 MB}: Bytes (BytesReader → BytesWriter) / Foundation base64EncodedData / Scalar table", 4 MiB per iteration (count × max(1, 4 MiB / count), Fixture); earlier d2-final: 5.04 / 19.1 / 21.5 (instructions identical) -->

The encoder allocates nothing at any size. It is near C of the same design (21.8 GB/s) and a C kernel that uses `ld3` and
`st4` directly (23.1 GB/s), both measured in the earlier `d2-final` run: 93% of the latter then, 88% of it against this run's
20.4. Swift cannot emit those instructions for explicit vectors. The limit is the core's table-lookup rate; Part III
(["Case study: the Base64 encoder's kernel"](#case-study-the-base64-encoders-kernel)) traces each step and its effect. <!-- src: Bytes/Benchmarks/RESULTS-base64.md "The ceiling: a C kernel with ld3 and st4" (23.1; kernel table 21.8) -->

The first working version was a plain loop that computes each character with arithmetic masks (no table, so no gather) and
lets LLVM vectorize it to `ld3`…`st4`. It already ran at 9.0 GB/s, and that kernel is what other CPUs get
(`ByteLanes.isLookupVectorized` is false there). <!-- src: Bytes/Benchmarks/RESULTS-base64.md "How it got here" row 1; Bytes/Sources/BytesBase64/Base64.swift doc comment -->

**Decoding** runs at 12.8 GB/s of decoded bytes at 64 MB (17 GB/s of text), 12.2 at 16 KB, and 11.5 at 1 MB in the latest
run (`m3-final`; 12.9 at 1 MB in the `d2-final` run, same instructions), at the C ceiling (12.9 GB/s, measured then). <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): Base64Benchmarks rows "Decode {64 MB, 16 KB, 1 MB}: Bytes (BytesReader → BytesWriter)" 5,242,879 / 345,087 / 365,055 ns for 64 MiB / 4 MiB / 4 MiB of decoded bytes; C ceiling from Bytes/Benchmarks/RESULTS-base64.md --> Its kernel does five things per 64 characters:

- splits them into four vectors with eight `uzp`s (what `ld4` does);
- maps each character to its 6-bit value through two `tbx` lookups in an 80-character window of the ASCII table (the
  alphabet runs from `+`, 43, to `z`, 122; one 64-byte lookup and one 16-byte lookup);
- ORs invalid characters (0xFF) into an accumulator that is tested once, after the loop;
- shifts and ORs the values into three vectors of bytes;
- puts them in order with three `tbl`s (what `st3` does).

The loop is bound by vector-pipe micro-ops rather than instructions: 61 micro-ops per block is about 15.25 cycles on 4
pipes, and it measured 15.2. Moving from a 128-byte table (`tbl` + `tbx` on 64 bytes each, 69 micro-ops) to the 80-byte
window gained 11%. <!-- src: Bytes/Benchmarks/RESULTS-base64.md "Decoding" "The kernel" and tables -->

The decoder met two compiler traps, both from `SIMD16` and LLVM. `SIMD16` array literals inside inlinable code compiled to
calls to `SIMD.init` (about 1,200 instructions) until they were written as `Byte16` integer literals converted with
`.vector`. And LLVM narrowed the loads to the lanes the first `uzp` round used until an empty `asm` kept them whole. <!-- src: Bytes/OPTIMIZATION.md (old version) §10 "Base64 decoding"; AGENTS.md Lessons ("Constant vectors", "LLVM narrows loads") -->

Against Foundation's `Data(base64Encoded:)`, decoding is 3.8–5.2x from 1,000 bytes up; against a scalar table, 5.5–6.2x
(`m3-final`; the scalar reference decoder no longer reads its table from a lazy global on every call, which made it 8–9x
faster than in `d2-final`, where the ratio was 44–52x). <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): Base64Benchmarks rows "Decode {1000 B, 1 KB, 16 KB, 1 MB, 64 MB}: Bytes (BytesReader → BytesWriter)" against ": Foundation Data(base64Encoded:)" and ": Scalar table" (3.8–5.2x; 5.5–6.2x); Bytes/Benchmarks/RESULTS.md "Improvements against speed-after" (Scalar table rows −56%, 9x: the benchmark's reference decoder, not Bytes) -->

#### `BytesFoundation`

`BytesFoundation` is 29 lines: `Data(copying: RawSpan)` and `Data.append(_ bytes: RawSpan)`. `Data` already has a `bytes`
view but no way to append a span or start from one. The module is separate so that `Bytes` itself does not depend on
Foundation. <!-- src: Bytes/Sources/BytesFoundation/Data.swift -->

### 14. Macros: `@BitFields` and `@BinaryRecord`

A format's fixed records and packed flags are declarations: field, position, width, byte order. The `BytesMacros` product
turns them into the parser and writer a person would write. It is separate from `Bytes` so that code not using macros never
builds swift-syntax (the library that macro plugins are built on). <!-- src: Bytes/Sources/BytesMacros/Macros.swift header comment; Bytes/Sources/Bytes/Bytes.docc/WritingParsers.md "Records and the macros" -->

```swift
@BitFields(Byte.self, reserved: 0...0)                  // bit 0 must be 0
struct ConnectFlags {
    @Flag(bit: 7) var userName: Bool
    @Field(bits: 3...4) var willQoS: QualityOfService   // an enum with UInt8 raw values
    @Flag(bit: 1) var cleanStart: Bool
}

@BinaryRecord(.littleEndian)
struct LocalFileHeader {
    @Field(Byte4.self, expecting: 0x0403_4B50) var signature: UInt32
    @Field(Byte2.self) var versionNeeded: Int
    var flags: GeneralPurposeFlags                      // a @BitFields type, or another record
    @Field(Byte2.self) var method: CompressionMethod    // an enum with integer raw values
}

let header = try reader.read(LocalFileHeader.self)      // throws for a bad signature or an enum with no case
try writer.write(header)
```

<!-- src: Bytes/Sources/BytesMacros/Macros.swift doc comments -->

An **attached macro** adds members and conformances to a type you declare, by generating source code at compile time in a
compiler plugin (`BytesMacrosPlugin`). What it generates is ordinary Swift, so it is exactly as fast as it is inlinable.

- `@BitFields` generates a memberwise initializer, `init(rawValue:) throws(BytesError)` (every field decoded, reserved
  bits checked), `rawValue`, and conformances to `BinaryParsable`, `BinaryWritable`, and `FixedSizeBinary`.
- `@BinaryRecord` generates a memberwise initializer (a field's expected value is its default), `byteCount` (the fields'
  sizes summed, a constant), and the same three conformances.

With no byte order (`@BinaryRecord`, and `@BitFields` over `UInt16`/`UInt32`/`UInt64`), the conformances are the
`ByteOrdered…` ones, read by `BigEndianBytesReader` or `LittleEndianBytesReader` ([section 5](#5-structure-sections-length-prefixes-leb128-records-text-dates)). <!-- src: Bytes/Sources/BytesMacros/Macros.swift doc comments -->

#### What it generates

This is the expansion for a record, abridged from the macro tests' snapshot. (The tests check the exact expansion text, and
the diagnostics point at the offending property rather than the whole struct.)

```swift
// @BinaryRecord(.littleEndian) struct Header { @Field(Byte4.self, expecting: …) var signature … }
@inline(__always) init<Mode: BytesCursorMode>(parsing reader: inout GenericBytesReader<Mode>) throws(BytesError) {
    let start = reader.position
    var record = AlignedBytesReader(try reader.read(byteCount: Self.byteCount))   // ONE bounds check for the record
    do throws(BytesError) {
        let signature = try record.read(UInt32.self, as: Byte4.self, .littleEndian)
        guard signature == 0x0403_4B50 else { throw .mismatch }
        self.signature = signature
        self.version = try record.read(Int.self, as: Byte2.self, .littleEndian)
        …                                                                         // one read per field
    } catch {
        reader.rewind(to: start)                                                  // a failed read consumes nothing
        throw error
    }
}
```

<!-- src: Bytes/Tests/BytesMacrosTests/ExpansionTests.swift `record()` expansion (abridged) -->

This is the known-size technique of [section 5](#5-structure-sections-length-prefixes-leb128-records-text-dates) applied by code generation: the record's bytes are taken with one bounds
check, and every field is read from a cursor whose length the optimizer can see.

#### Generated code must be forced inline

The first expansion left `init(parsing:)` an ordinary function. The optimizer kept it a call, and a 17-field record came
back through memory. The zip central directory benchmark (2,000 entries) took **297 K instructions**. With
`@inline(__always)` on the generated initializer and writer (the plugin emits `@inlinable @inline(__always)` for public
types), it took **199 K**, exactly the hand-written fixed-record parser's count. A record's declaration gives no hint that
a call boundary is the cost, and the field code was fine, so studying it would not have found the problem. <!-- src: Bytes/Sources/BytesMacrosPlugin/BinaryRecordMacro.swift (`inlinable` string); AGENTS.md Lessons "Generated code needs @inline(__always)"; Bytes/OPTIMIZATION.md (old version) §10 "Macros" -->

Measured on the same workload (2,000 zip central-directory entries, instructions, p50):

| Parser | Instructions |
|---|---|
| `@BinaryRecord` (and the hand-written fixed-record parser) | 199 K |
| Bytes, field by field | 285 K |
| `swift-binary-parsing`'s `ParserSpan`, fixed records | 325 K |
| `ParserSpan`, field by field | 461 K |

<!-- src: BinaryParsingComparison/RESULTS.md "2026-11-17: every example, MQTT both ways, macro records" table (Zip directory rows) -->

None of them allocates.

One packaging trap: a `.macro` target in `Package.swift` needs `import CompilerPluginSupport`. Without it, the manifest
fails with "unable to type-check this expression in reasonable time" rather than naming `.macro` (swift-bugs report 27). <!-- src: Bytes/Package.swift comment; AGENTS.md Lessons ".macro targets need import CompilerPluginSupport" -->

### 15. Builds and traits: optimized, `Portable`, and no-C

The library is built for CPUs it was not tuned on, and each build is measured. `Package.swift` declares **package traits**
(optional features a package's users switch on or off, SE-0450):

| Trait | What it enables |
|---|---|
| `NEONShuffle` | the `CBytesNEON` C module: `tbl`/`tbx`/`uzp`/`zip` wrappers ([section 7](#7-scanning-and-shuffles-bytelanes-bytematches-groupshuffle-cbytesneon)) |
| `HardwareCRC` | the `CBytesCRC` C module: `pmull`, `eor3`, `crc32x`, `udot` for `CRC32`, `Adler32`, and `CRC64` |
| `HardwareCrypto` | the `CBytesCrypto` C module: AES, SHA-1, SHA-256, SHA-512, GHASH (AES-GCM's authentication hash) instructions |
| `Portable` | enables the three above *and* compiles their headers' portable fallbacks (`BYTES_PORTABLE`), to measure the fallbacks on Apple silicon |
| default | `NEONShuffle`, `HardwareCRC`, `HardwareCrypto` |

<!-- src: Bytes/Package.swift traits -->

That makes three builds: **optimized** (the default, what Apple silicon gets), **portable** (`--traits Portable`: the C
modules' fallbacks, what other CPUs get), and **portable-no-c** (`--disable-default-traits`: Swift only).
`Bytes/bench optimized|portable|portable-no-c` runs the benchmarks against each in its own build directory, so switching
does not rebuild. <!-- src: Bytes/Package.swift comment; Bytes/bench -->

The package also vends three products that are not library API, for tests and benchmarks across the repository:
`BytesTestSupport` (no Swift Testing dependency, so benchmarks can use it), `BytesTesting` (adds the `.bulk` test trait), and
`BytesReferenceCodecs` (zlib's and Compression's buffer APIs as reference codecs). <!-- src: Bytes/Package.swift supportTargets comment and products; AGENTS.md Tests "Shared helpers are Bytes' support products" -->

Code chooses with compile-time conditions that fold:

```swift
static func _update(_ state: UInt32, _ bytes: RawSpan) -> UInt32 {
    #if HardwareCRC && arch(arm64) && !Portable
    _hardwareUpdate(state, bytes)          // pmull folding
    #else
    _tableUpdate(state, bytes)             // braided tables
    #endif
}

static var isLookupVectorized: Bool {      // ByteLanes: is lookup(in:) a single tbl?
    #if NEONShuffle && arch(arm64) && !Portable
    true
    #else
    false
    #endif
}
```

<!-- src: Bytes/Sources/Bytes/CRC32.swift _update; Bytes/Sources/Bytes/ByteLookup.swift isLookupVectorized -->

One detail took an investigation to find. Swift modules compile a C header's `static inline` functions *themselves*,
including ones inlined from `Bytes` into their own code, so a `BYTES_PORTABLE` define on the C target is not enough.
SwiftPM passes a C target's defines to no other target, so every Swift target in the package also gets
`-Xcc -DBYTES_PORTABLE` under the trait (through `unsafeFlags`), and a client building a portable `Bytes` needs the same
flag. <!-- src: Bytes/Package.swift comments on `portableCSettings` and `portableSwiftSettings`; AGENTS.md Benchmarks section -->

#### Why emulating `tbl` is no fallback

The first measurement of the portable builds showed them far slower. The C header's fallback for other CPUs did each 64-byte
`tbl` a lane at a time: copy the table to the stack, then for each of 16 lanes compare, branch, load, and insert, about 200
instructions where NEON needs one.

```c
for (int lane = 0; lane < 16; lane++) {
    result[lane] = index[lane] < count ? table[index[lane]] : 0;     // bytes_table_portable
}
```

<!-- src: Bytes/Sources/CBytesNEON/include/CBytesNEON.h bytes_table_portable; Bytes/OPTIMIZATION.md (old version) §9 "An emulated instruction is no fallback" (about 200 instructions) -->

The algorithms around it, such as the 3-, 5-, 6-, and 7-byte unpackers, were designed on the assumption that lookups are
nearly free. The portable build ran **37–113x slower** than the NEON build on them, and 15–54x slower than plain Swift
loops that did not shuffle at all. The lesson is general: an algorithm designed around one CPU's instruction belongs behind
a check that the instruction is there (`ByteLanes.isLookupVectorized`), with a *different algorithm* elsewhere instead of
an emulation. <!-- src: AGENTS.md Lessons "Emulating a lookup that's one instruction on one CPU is no portable fallback" -->

Two changes, neither specific to a CPU, closed most of the gap:

1. **Odd widths:** `GroupShuffle`'s constant shuffles ([section 7](#7-scanning-and-shuffles-bytelanes-bytematches-groupshuffle-cbytesneon)) instead of emulated lookups, with a stack buffer for writes and `forEach`.
2. **CRC:** the braided table CRC ([section 8](#8-checksums-crc32-adler32-crc64-xxhash64-runningchecksum)), which took the table path from 30x slower than `pmull` to 8.3x.

For iterators (`for`-`in`), the portable path is faster than the NEON one: a one-register `tbl` per vector of two
values (four for 3 bytes) beat the NEON build's four-register lookups, so the optimized build adopted the portable path
there too.

<!-- src: Bytes/OPTIMIZATION.md (old version) §10 "Three builds: NEON, portable C, Swift only"; Bytes/Benchmarks/RESULTS.md "2026-11-12: fast portable builds" -->

Times in µs (the mean of two alternating rounds), the portable builds before the change and after:

| Workload | Optimized | Portable, before → after | No C, before → after |
|---|---|---|---|
| bulk read `Byte3`, 4 MB | 87 | 8,485 → 88 | 222 → 88 |
| bulk read `Byte5`, 4 MB | 98 | 10,500 → 99 | 202 → 99 |
| `forEach` summing `Byte5`, 4 MB | 193 | 9,535 → 200 | 202 → 194 |
| generating write `Byte3`, 4 MB | 97 | 6,699 → 189 | 204 → 189 |
| CRC-32, 256 KB | 466 (`pmull`) | 14,000 → 3,849 | 14,000 → 3,888 |

<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-12: fast portable builds" table (rows: Bulk read Byte3, Byte5, forEach summing Byte5, Generating write Byte3, CRC-32 256 KB) -->

Over all 337 rows (geometric mean of time against the optimized build), the portable build went from 1.59x to 1.009x and
portable-no-c from 1.055x to 1.016x. After the optimized build adopted the portable iterators, the ratios were 1.020x and
1.023x, with 321 and 319 rows within 10%. The remaining gaps are the odd-width generating writes (1.25–2x: the trip
through memory) and CRC-32 against `pmull` (8.2–8.3x). <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-12: fast portable builds" and "…adopts the portable iterator path" ("Over all 337 rows …") -->

On the M1 Max the three builds stayed within 1.4% of each other in time over a 200-benchmark set (instructions +3.2% for
the portable builds on both chips), so the conclusion is not an M3 artifact. That set, though, is mostly bandwidth and
write rows, with no CRC-32 or SHA, so it says little about the C modules. <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-19, M1 Max against M3 Ultra" "The three builds on M1 Max" -->

The crypto fallbacks make a different trade, because the instruction is also a *security* feature. Without the AES instructions,
substituting bytes through a table would leak the index through the cache, so the portable path computes the S-box (AES's
byte-substitution table) by arithmetic in GF(2⁸). Without `pmull`, GHASH multiplies bit by bit in constant time. The
fallbacks are slower, and correct on any CPU. <!-- src: Bytes/OPTIMIZATION.md (old version) §10 "AES-GCM and TLS 1.3 in Swift" ("Without the instructions … AES substitutes bytes by arithmetic in GF(2⁸) rather than a table, which would leak its index through the cache, and GHASH multiplies bit by bit in constant time"); Bytes/Benchmarks/RESULTS.md "crypto in Swift" ("a constant-time portable path that computes the S-box in GF(2⁸)") -->

## Part III. Techniques, by problem

[Part II](#part-ii-the-bytes-toolkit-bottom-up) describes what each Bytes API does. This part is organized the other way round: by the problem a fast
program has to solve, and the technique that solves it. Each technique is shown where it was measured, in the codecs
(`BytesCompression`), the crypto (`BytesCrypto`), and the projects built on Bytes. Every section follows the same
shape: what goes wrong, why the CPU or the compiler behaves that way, the fix, the measured effect, and when not to
use it. Numbers are from an Apple M3 Ultra unless a section says otherwise.<!-- src: brief; Bytes/Benchmarks/RESULTS.md header "M3 Ultra" -->

Two habits run through every section, so they are stated once here. First, a claim is checked in the machine code, not
only in a timing: the tools in `Tools/` (`loops`, `calls`, `remarks`; see Part I, ["Measuring"](#5-measuring)) say whether a loop is
vectorized, whether a call survived inlining, and why the vectorizer declined.<!-- src: AGENTS.md "Ground rules" "Check the machine code" --> Second, a change that removes instructions
is not automatically faster: several sections below show cases where instruction count fell and time did not move
(the work removed was not on the critical path), and cases where instruction count rose and time fell (the added work
took a dependency off the critical path). Instruction counts are exact and stable between runs; times drift by 5–10%
between runs minutes apart.<!-- src: AGENTS.md "Compare times only within one interleaved run" -->

### 1. Keep hot state in registers

#### The problem

A CPU computes only on values in registers (Part I, ["Registers and the register file"](#13-registers-and-the-register-file)). A value that lives in memory
must be loaded before use and stored after a change, and a load of a value just stored still waits for store-to-load
forwarding, a delay that can sit on the critical path of a loop. A compiler keeps a variable in a register only while it
can see every use of it. Once the variable's *address* is passed to code the compiler cannot see through (a function
that is not inlined, a closure it cannot inline), the optimizer in practice keeps the variable in memory wherever that
address might be used, even on paths that never call the function.<!-- src: OPTIMIZATION-old.md "5. Keep the cursor in registers" first paragraph and item 1 -->

Bytes' central type is the cursor (Part II, ["Cursors: `BytesReader`, `BytesWriter`, and their modes"](#3-cursors-bytesreader-byteswriter-and-their-modes)): a struct holding a view of the bytes, a byte offset, and (for
the bit-addressed `BytesReader`) a bit offset and bit order. A 40-byte cursor does not fit in a handful of registers for
free, but the optimizer breaks a struct into its fields (scalar replacement) and keeps each field in a register, as long
as nothing takes the struct's address. Everything in Bytes that is fast depends on that happening.<!-- src: OPTIMIZATION-old.md "5. Keep the cursor in registers" ("whole 40-byte cursor") -->

#### Three ways the cursor ends up in memory

**A slow path that borrows `self`.** Rare cases, such as a read that is not byte-aligned, went to a non-inlined
`mutating` helper. Calling it passes the cursor's address, so every caller kept the whole cursor in memory, including
the fast path that never calls it. The fix is a static function that takes values and returns a value:<!-- src: OPTIMIZATION-old.md "5." item 1 -->

```swift
// Before (illustrative): the cursor lives in memory in every caller.
mutating func readUnaligned(_ count: Int) -> UInt128 { … }

// After: values in, value out. The fast path keeps the cursor in registers.
static func _unalignedBytes(_ count: Int, in span: RawSpan, atByte byteOffset: Int, bit: Int,
                            bitOrder: BitOrder) -> UInt128 { … }
```
<!-- src: Bytes/Sources/Bytes/BytesReader.swift _unalignedBytes (line 683) -->

**A function that is not inlined.** When `read(byteCount:)` was not inlined, the cursor was spilled around every call.
Inlining it and the slow-path fix above, together with the invariant in [section 2](#2-remove-the-checks-the-compiler-cannot-prove-away), took field parsing from 439 K to
287 K instructions (−35%), and bit-field parsing from 2,378 K to 886 K (−63%).<!-- src: OPTIMIZATION-old.md "5." item 2 -->

**A cursor captured by a closure.** A closure that is not inlined keeps its captured variables in memory. A benchmark
writer that called a closure parameter through a compiler-generated wrapper ran at 0.6 GB/s; with the loop inside the
closure itself, so the writer is a local the optimizer can see, it ran at 54 GB/s:<!-- src: OPTIMIZATION-old.md "5." item 3 -->

```swift
// 0.6 GB/s. `fill` is a closure parameter, (inout BytesWriter) -> Void. The compiler merged the closures
// into one wrapper (a thunk) that called `fill` indirectly, with the writer in memory.
output.withBytesWriter { writer in fill(&writer) }

// 54 GB/s: the loop is in the closure itself, so the writer is a local the optimizer sees.
try output.withBytesWriter { writer in
    for index in 0..<count { try writer.write(value(at: index)) }
}
```
<!-- src: OPTIMIZATION-old.md "5." item 3 -->

`forEach` had the same problem: for its largest closure body the optimizer moved the loop into a separate copy of
`forEach` specialized for the closure, which stored the captured variables every iteration. Marking `forEach`
`@inline(__always)` kept them in registers. A QOI image decoder in BinaryParsingComparison took 21% less time (9.9 to
7.8 ms) once its cursors were locals instead of captured variables, with no other change; the `ParserSpan` port of the same decoder
improved too (10.6 to 7.9 ms).<!-- src: OPTIMIZATION-old.md "5." (QOI 9.9 → 7.8 ms); BinaryParsingComparison/RESULTS.md "A Bytes caveat this exposed" -->

#### The same disease in other code

The pattern recurs wherever a hot loop keeps state in a struct. Each case below was found by looking at the loop's
instructions and seeing stack accesses (`ldr`/`str` with an `sp` base) where registers were expected.

- **A bit reader reloaded by a `mutating` method.** The Zstandard decoder's reload near the start of the input was an
  out-of-line `mutating` method, so the reader's address escaped and the reader lived in memory through the whole
  sequence loop. As a static function taking and returning values, it saved 1–1.5%.<!-- src: Bytes/Benchmarks/RESULTS.md "Zstandard decoding" "How it got there" -->
- **Fewer live values.** The three FSE (finite state entropy) states became absolute indices into one workspace, so one
  table pointer serves all three, and the output and literal positions became pointers: stack accesses per sequence
  fell from 21 to 10, instructions 3–5%, time 10–20%.<!-- src: Bytes/Benchmarks/RESULTS.md "Zstandard decoding" "How it got there" table -->
- **A nested function that captures state.** In the bzip2 decoder a local `func decode()` capturing the decoder's
  variables was boxed on the heap (7 `swift_allocObject` per block, dynamic exclusivity checks): 270 instructions per
  byte on a 1.6 KB input. A struct with `@inline(__always)` mutating methods compiles to registers.<!-- src: Bytes/Benchmarks/RESULTS-bzip2.md "What didn't" last item -->
- **SHA-512 with captured variables.** State and schedule held as variables mutated by `@inline(__always)` nested
  functions stayed in memory behind 12 `swift_beginAccess` calls per block: 638 instructions per block; as structs with
  mutating methods, 519, then 489 once a loop condition was written in whole blocks.<!-- src: Bytes/Benchmarks/RESULTS.md "Crypto cleanup" SHA-512 bullet; AGENTS.md "Values mutated by @inline(__always) nested functions" -->
- **An accumulator copied by a helper.** The first version of the stitched ChaCha20-Poly1305 called `blocks` on the Poly1305
  accumulator, which copied the whole struct; keeping it in locals through the rounds took 64-byte seals from 79 to 74 M
  instructions.<!-- src: OPTIMIZATION-old.md "ChaCha20-Poly1305: 1.0 → 2.50 GB/s" -->
- **Inner loops over repetitions.** In the LZBITMAP decoder an inner loop over a run's repetitions spilled the values
  held across it. One iteration per group, with the repetition count as loop state, kept everything in registers, as did
  returning values from out-of-line helpers instead of passing them `inout`.<!-- src: Bytes/Benchmarks/RESULTS-lzbitmap.md "Lessons for AGENTS.md" last bullet -->
- **A helper used once after the loop.** The LZVN encoder's final literal, inlined or as a `mutating` call, cost the
  search loop 1–3% (the emitter's state spilled); as a static function taking the emitter by value and returning the
  position, nothing.<!-- src: Bytes/Benchmarks/RESULTS-lz4-lzfse.md "Lessons for AGENTS.md" "A helper used once after a hot loop" -->
- **The DEFLATE decoder.** LLVM's inliner declined `@inline(__always)` for the back-reference copy inside a large
  function, so the call took the writer by address and the writer lived in memory for the whole loop. Splitting the
  decoder into small functions that each hold their cursors as locals, with the guaranteed `@inline(always)` ([section
  5](#5-inlining-and-specialization)), was the largest of the changes that took it from 2x slower than zlib to faster.<!-- src: OPTIMIZATION-old.md "5." paragraph on @inline(__always) and "DEFLATE: from 2x slower than zlib to faster" -->
- **An `inout` span's base address.** The second DEFLATE rewrite ([section 2](#2-remove-the-checks-the-compiler-cannot-prove-away))
  takes the output span `inout`, and through that parameter LLVM could not tell that the stores did not change the
  span's base address, so it loaded the base from memory before every store. Rebinding the output to a local
  (`var buffer = output._mutatingExtracting(0..<output.byteCount)`) before the loop puts the base in a register. The same
  loop keeps its bit buffer as a struct with mutating methods (`FastBits`), and calls its rare cases as static functions,
  for the reasons above.<!-- src: Bytes/Sources/BytesCompression/DeflateDecoder.swift `decodeSymbols` ("The output as a local: through the `inout` parameter, its base address was loaded from memory before every store (the stores might change it, as far as LLVM can tell)") and `FastBits` doc comment ("A struct with mutating methods rather than nested functions over captured variables, which can stay in memory behind access checks") -->

#### Cursor design: a constant bit offset

The bit-addressed `BytesReader` has to carry a bit offset (0–7) and test it on byte-granular reads. For formats made
only of whole bytes, `AlignedBytesReader` and `AlignedBytesWriter` are the same type in a mode where the bit offset is
the *constant* 0, so the tests fold away and there is one less field to keep in a register (Part II, ["Why byte-aligned
cursors are faster"](#why-byte-aligned-cursors-are-faster), has the measurements: MQTT encode −6%, DEFLATE decode −1.7% to −4%).<!-- src: AGENTS.md "Byte-only formats use AlignedBytesReader and AlignedBytesWriter" -->
Out-of-line helpers on the cursors belong in the constrained extensions where the type is not generic, so that they do
not take type metadata at each call (`Tools/calls … --callee metadata` finds such calls).<!-- src: AGENTS.md same lesson -->

#### When not to

A cursor that does less is not always a faster loop: QOI's run-filling decoder ran 54% more instructions with the aligned
reader and keeps the bit-addressed `BytesReader` (Part II, ["Why byte-aligned cursors are faster"](#why-byte-aligned-cursors-are-faster)). Measure when switching
a hot loop.<!-- src: AGENTS.md "One exception measured: QOI's run-filling decoder" -->
Also, helpers that take and return values are for paths that run rarely or once per block; a helper called per element must be
inlined, or its call cost dominates ([section 5](#5-inlining-and-specialization)).

### 2. Remove the checks the compiler cannot prove away

#### The cost of a check

Every read of untrusted data must check that enough bytes remain, and ordinary integer arithmetic traps on overflow.
Each check is a compare and a branch that is almost always predicted correctly, so one check is cheap. Three things
make checks expensive in aggregate. They are instructions that compete for issue slots. A failing check is an early
exit, which prevents vectorization ([section 3](#3-let-llvm-vectorize-your-loops)). And the optimizer can merge two checks into one only if it knows a
fact about the values, which it often cannot see.<!-- src: OPTIMIZATION-old.md "6. Make bounds checks disappear" first paragraph -->

#### Tell the optimizer the invariant

The cursor's check is `span.byteCount &- offset >= n`, with the wrapping subtract `&-` because the cursor knows it
cannot overflow. To merge the checks for fields at `offset` and `offset + 2`, LLVM must know that `byteCount - offset`
is not negative, which holds only if `offset <= byteCount`. Bytes states this with `assume`, a wrapper over
`Builtin.assume` that means "treat this as true; do not check it":<!-- src: OPTIMIZATION-old.md "6." "Tell the optimizer the invariant" -->

```swift
@inline(__always) func _assumeInvariant() {
    unsafe assume(_byteOffset <= span.byteCount)
    unsafe assume(_bitOffset >= 0)
    unsafe assume(_bitOffset < 8)
}
```
<!-- src: OPTIMIZATION-old.md "6." ; Bytes/Sources/Bytes/BytesReader.swift _assumeInvariant (line 418) -->

With it, each field's check becomes a compare of its end offset against a constant computed once before the loop: 3
instructions per field instead of 4, the remaining `add` doubling as the load address.<!-- src: OPTIMIZATION-old.md "6." -->

A fourth assumption, `_byteOffset >= 0`, is equally true and deliberately left out. It alone of the four stopped
LLVM from vectorizing loops of single reads (14 against 113 GB/s for 4-byte values). Leaving it out costs 11% more
instructions in field-by-field parsing, at the same speed. A hint can hurt as well as help; each was tested alone.<!-- src: OPTIMIZATION-old.md "6." ; old section 12 table "Builtin.assume(offset >= 0)" -->
The same measurement discipline applied to branch-weight hints: without Bytes' `likely`/`unlikely` wrappers (LLVM
branch weights, reached through `Builtin`), bit-field parsing took 14% more instructions (689 K to 787 K) at the same
time, so they stayed.<!-- src: OPTIMIZATION-old.md "11. Smaller lessons" "Measure hints" -->

#### Give the record a known size

A fixed-size record read as its own cursor has a length the optimizer can see, so reads inside it need no checks.
Parsing 2,000 zip central-directory headers (46 bytes each, 17 fields):<!-- src: OPTIMIZATION-old.md "6." "Give the record a known size"; BinaryParsingComparison/RESULTS.md "Results" -->

```swift
// Field by field: a check per field. 301 K instructions in the first measurement, 11 µs.
let signature = try reader.read(Byte4.self)
let version = try reader.read(Byte2.self, .littleEndian)
// … 15 more fields

// One check for the record, none per field: 199 K instructions (-34%), 7.8 µs.
var record = BytesReader(try reader.read(byteCount: 46))
let signature = try record.read(Byte4.self)
let version = try record.read(Byte2.self, .littleEndian)   // bytes 4..<6 of 46: known in bounds
```
<!-- src: OPTIMIZATION-old.md "6." (301 K → 199 K, 11 µs → 7.8 µs; 285 K in the latest tracked run) -->

The compiler even loads adjacent 4-byte fields with one instruction (`ldp w6, w7, [x16, #16]`: two fields from address
x16 + 16).<!-- src: OPTIMIZATION-old.md "6." -->
`@BinaryRecord` generates this form (Part II, ["Macros: `@BitFields` and `@BinaryRecord`"](#14-macros-bitfields-and-binaryrecord)). Against the same workload the field-by-field Bytes parser costs
285 K instructions, `ParserSpan` fixed records 325 K, and `ParserSpan` field by field 461 K.<!-- src: OPTIMIZATION-old.md "Macros: formats as declarations" table -->

#### Loop over typed spans

Base64's encoder processes 48-byte blocks. Loading three vectors per block at byte offsets from a `RawSpan` and storing
four checked every access: 14 of the loop's 45 instructions. Viewing the input as `Span<InlineArray<48, UInt8>>` and
the output as `MutableSpan<InlineArray<64, UInt8>>` leaves one check per span, before the loop, because each index comes
from `blocks.indices` and one `output.count == blocks.count` test covers every store:<!-- src: OPTIMIZATION-old.md "6." "Loop over typed spans" -->

```swift
// A check per load and store: 5.0 M instructions per 4 MB.
while offset + 48 <= input.byteCount {
    let a = input.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)        // checked
    let b = input.load(fromByteOffset: offset + 16, as: SIMD16<UInt8>.self)   // checked
    // … one more load, the encoding, four checked stores
}

// blocks: the same input viewed as Span<InlineArray<48, UInt8>>; output: MutableSpan<InlineArray<64, UInt8>>.
// One check per span, before the loop: 2.2 M instructions.
precondition(output.count == blocks.count)
for block in blocks.indices {
    output[block] = encodeBlock(blocks[block], table: table)   // 48 bytes in, 64 characters out
}
```
<!-- src: OPTIMIZATION-old.md "6." "Loop over typed spans" -->

Instructions fell 2.3x and throughput did not move: the checks had run in spare issue slots beside the table lookups,
which were the bottleneck. Removing work that is not the bottleneck does not make a loop faster.<!-- src: OPTIMIZATION-old.md "6." ; Bytes/Benchmarks/RESULTS-base64.md "The ceiling" bullet "The bottleneck is table lookups" -->

#### Masked indices, one unsigned compare, unmasked stores

- **Mask an index so its range is visible.** Brotli's decoder indexes with `context & 0x3F` and `types & 0xFF`, so the
  span check folds. Together with state in locals ([section 1](#1-keep-hot-state-in-registers)) and Huffman tables built only from used symbols, Brotli
  decoding got 20–42% faster across the corpus, the 1.6 KB streams most.<!-- src: AGENTS.md "Hot decode loops keep their state in locals" -->
- **A count check is one unsigned compare.** `UInt(bitPattern: n) <= UInt(bitPattern: remaining)` rejects a negative and
  an oversized count at once, because a negative `n` becomes a huge unsigned number. Written as `n >= 0 && n <= remaining`
  it cost the LZ4 port 2% in instructions.<!-- src: AGENTS.md "A count check is one unsigned compare" -->
  Counts from untrusted data throw instead of trapping: `read(byteCount:)`, `skip(byteCount:)`, and `read(_:count:)`
  throw `invalidValue` for a negative count.<!-- src: OPTIMIZATION-old.md "10." "swift-binary-parsing's examples" API list -->
- **Store a checked value unmasked.** An enum field setter did `assert(raw <= mask)` and stored `raw & mask`, which cost
  MQTT's PUBLISH encoding 0.8% (5,132 K to 5,173 K). `precondition(raw <= mask)` and an unmasked store folds both away
  when the enum's raw values are visible: once the precondition has run, the mask cannot change the value, and the
  optimizer knows it.<!-- src: OPTIMIZATION-old.md "11." "Store a checked value unmasked"; "What tracking caught" table row 1 -->

#### A limit per round instead of a check per symbol

A decoder's fast loop reads input and writes output at every symbol, and each checked access (a refill, a store, a match
copy) costs 2–3 instructions: 12 to 20 in a match. The checks cannot fold, because the amount of input a symbol consumes
depends on the data. But a *bound* on it does not: a DEFLATE iteration consumes at most 16 bits for each byte it writes (a
literal is at most 15 bits, a match of 3 or more at most 48; Deflate64's longer matches make it 20). So the input left
after the iteration is at least what it was, less 16 bits per output byte, and a limit on the *output* guarantees the
input. The loop computes that limit in rounds:

```swift
// DeflateDecoder.decodeSymbols (shortened): only `out` is compared in the inner loop.
rounds: while true {
    let inputLeft = inputBits &- bits.position &- fastInputBits
    guard inputLeft >= 0 else { break rounds }
    let limit = min(roomLimit, out &+ (deflate64 ? (inputLeft &* 3) &>> 6 : inputLeft &>> 4))
    guard out <= limit else { break rounds }
    fast: while out <= limit {
        // At least 32 bytes of input and `fastRoom` bytes of output remain at the top of each iteration,
        // so every refill load and every store below is unchecked.
        …
    }
}
```
<!-- src: Bytes/Sources/BytesCompression/DeflateDecoder.swift `decodeSymbols` lines 774–799 (comment and code; "Deflate64: `* 3 / 64`, shifts rather than a division by 20, whose constant took a register"; "checked accesses … cost 2–3 instructions each, 12–20 a match") -->

A round takes a few instructions and a call to the function has a few dozen to a few hundred, so the check moved out of
the loop costs nothing measurable. The price is a proof, and it lives in comments next to each unchecked access: the
iteration's refills load 8 bytes at most 20 bytes past its starting bit (93 bits consumed, then 63 buffered), and it
writes at most three literals, or two and a match of up to 258 bytes plus the copy's 32-byte overrun. Deflate64's
division by 20 became shifts (`* 3 >> 6`) because the divisor's magic constant took a register for the whole loop. A rare
case that could break the bound (Deflate64's length symbol 285, up to 65,538 bytes) is flagged in the table entry so only
that symbol pays for a room check, and a match that does not fit leaves the fast loop for the careful one.

The table entries help in the same way. `HuffmanEntry` is a 32-bit value whose *flags* (literal, exceptional, subtable,
end of block) answer each question with one test-bit-and-branch (`tbnz`), where a `kind` field needs a compare, and its
fields are read as named `BitField`s rather than range subscripts (the range subscripts cost 3–5% more instructions).

Measured on the M1 Max (instructions, exact): the first change, the per-round output limit with named fields and
Deflate64 support, cut 8.3–8.8% from inflating dickens, samba, x-ray, and xml (141, 174, 205, and 24 M to 129, 159, 187,
and 22 M). The rewrite of the loop on locals (libdeflate's design, with its own match copy) cut 35.8–39.5% more (dickens,
samba, x-ray, xml: 129, 159, 187, 22 M to 78, 102, 120, 14 M), with time −5 to −9% (dickens unchanged at 11.0 ms). The
decoder now runs fewer instructions than libdeflate's (dickens 78 M against 94 M, 0.83x; 0.68–0.78x zlib's) and takes the
same time on dickens and samba (11 and 15 ms), 4–6% behind on x-ray, xml, and Main.js. The instruction cut is large and
the time cut small because the loop is bound by load latency and mispredictions (`Tools/counters`), not by instruction
count, which is [section 7](#7-branches-and-data-dependent-work)'s warning again: for a loop like this, judge by cycles.
<!-- src: Bytes/Benchmarks/RESULTS.md "Streaming decoders for NativeZip (2026-11-22, M1 Max; …)" table (rows "Inflate dickens / samba / x-ray / xml: Bytes" 141 / 174 / 205 / 24 M → 129 / 159 / 187 / 22 M, −8.3 to −8.8%) and bullet "The decode loop also got faster for every stream: the per-symbol input check became an output limit worked out in rounds"; "Cleanups after the unification (2026-11-22, M1 Max; …)" table row "Inflate dickens / samba / x-ray / xml" (129 / 159 / 187 / 22 M → 78 / 102 / 120 / 14 M, −35.8 to −39.5%, "dickens 11.0 → 11.0 ms; others −5 to −9%") and the paragraph "Against the references in the same run: DEFLATE now runs fewer instructions than libdeflate (dickens 78 M against 94 M, 0.83x …) and 0.68–0.78x zlib's, and its time matches libdeflate's on dickens and samba (11 and 15 ms), 4–6% behind on x-ray, xml, and Main.js"; Bytes/Sources/BytesCompression/Deflate.swift `HuffmanEntry` comment ("Read with the range subscripts instead, the decode loop ran 3–5% more instructions (2026-11-22)") and flags; "decide with one `tbnz`" from the same RESULTS bullet -->

The other side of this technique is in the same code: a *failed* proof has to fail safely. The fast loop stops where
the proof ends (`.nearEnd`), and the careful loop, which checks everything and is resumable, takes over for the last bytes
of input and the last of the output's room.

#### Overflow checks

Swift's `+` traps on overflow, which costs a flag-setting add and a branch. After a bounds check has proven the add
cannot overflow, the trapping add is pure overhead. BinaryParsingComparison's analysis found that `ParserSpan`, after
the bounds check, advances with `_lowerBound += MemoryLayout<T>.stride`, a trapping add, so each field costs `adds` +
`b.vs` and more. Bytes uses `&+=` there:<!-- src: BinaryParsingComparison/RESULTS.md "Why" item 1 -->

```asm
; Bytes (CentralDirectory.parseWithBytes): two 2-byte fields' checks. x11 = the record's start, x1 = the byte count.
add   x15, x11, #0x8    ; the field's offset: start + 8 (a wrapping add, `&+`); later also the load's address
sub   x14, x1, x15      ; bytes remaining from there
cmp   x14, #0x1         ; at most 1 left?
b.le  <L10>             ; then throw: every field branches to the same throw path
add   x16, x11, #0xa    ; the next field: start + 10, independent of the previous add
sub   x14, x1, x16      ; the same check for this field: bytes remaining,
cmp   x14, #0x1         ;   at most 1 left?
b.le  <L10>             ;   then the same shared throw path

; ParserSpan (CentralDirectory.parseWithParserSpan): the same two checks.
adds  x12, x10, #0x2    ; advance past the previous field, setting the overflow flag (`+=` traps)
b.vs  <L91>             ; overflowed? trap
sub   x8, x22, x12      ; bytes remaining
cmp   x8, #0x1          ; at most 1 left?
b.le  <L32>             ; throw: each field has its own throw path (its error records the offset)
adds  x13, x12, #0x2    ; each offset is the previous one plus 2: a chain
b.vs  <L92>             ; overflowed? trap (a separate trap per field)
sub   x8, x22, x13      ; the same check for this field: bytes remaining,
cmp   x8, #0x1          ;   at most 1 left?
b.le  <L33>             ;   then this field's own throw path
```
<!-- src: objdump of BinaryParsingComparison/.build/release/Workloads.o (Tools/loops … 'CentralDirectory.parseWithBytes\(_:\)' and parseWithParserSpan, --body), excerpts; BinaryParsingComparison/RESULTS.md "Why" items 1 and 2 -->

(Both excerpts are from the release build's object file; the loads come later in the loop.) Use wrapping operators
(`&+`, `&-`, `&>>`) only where an earlier check proves the result; never to hide an overflow that untrusted input could
cause.

#### When the safe accessor is right

Every `unsafe` access in Bytes was tried against its checked standard-library counterpart. Where the library's check
folds into the cursor's own, the checked form stayed: using the checked `extracting` for the fixed-size sub-cursor even
made records 31% faster. Elsewhere it does not fold, because the standard library's check needs `offset >= 0`, which
the cursor deliberately does not assume. Checked cursor reads cost 24% more instructions for field parsing, 2–8x for odd
widths, and stopped bulk loops from vectorizing, so the unchecked accesses stay, confined to a few functions, each
behind the cursor's own check, with a comment on why it is safe.<!-- src: OPTIMIZATION-old.md "6." "When the standard library's safe accessors cost too much" -->

Two more data points on the price of safety, both measured:

- `commonPrefixLength` checks its bounds once per call (one sign test of the bounds ORed together, about eight
  instructions). Called per match candidate, it cost the compressors 3–18%. `BitWriter.flush()`'s capacity check cost
  the encoders 0.2–1.7%. Both have `@unsafe` forms (`unsafeCommonPrefixLength`, `unsafeFlush`) for loops that prove their
  bounds once per block, with the argument in a comment at the call site.<!-- src: AGENTS.md "A safe helper's one check per call can cost more than the work in a hot loop"; Bytes/Sources/Bytes/BitWriter.swift unsafeFlush; BytesReader.swift unsafeCommonPrefixLength -->
- LZ4's decoder had a bounds fix that cost 10–17% instructions (offsets from the buffers' starts, recomputed per
  sequence in the fast-path tests). The replacement kept pointer limits clamped at the buffer's start with strict
  comparisons, so with less room than the 16-byte copy overrun the limits are the start and no copy takes the fast path.
  Counts went back to the earlier ones (−1.7 to +0.2%), and the guard-byte tests also passed under the address
  sanitizer.<!-- src: Bytes/Benchmarks/RESULTS-lz4-lzfse.md "the LZ4 bounds fix cost 10–17% instructions" -->

#### A check folds only while the optimizer knows both sides

The table CRC looks up bytes in 256-entry tables. As `Span`s of exactly 256 entries, a byte index is provably in range,
and in the main loop the checks vanished. In the loop for short inputs they stayed: each table's count sat in a register,
compared before every lookup. Stating the counts with a `precondition` fixed that loop and broke the main one, which
then ran out of registers, spilled, and checked again (126 to 293 instructions per 40 bytes). The tables became pointers
into the borrowed array, with the argument for safety (every index is a byte) in a comment. Whether a safe access is
free can depend on register pressure in code nearby: check the loop, not the function.<!-- src: OPTIMIZATION-old.md "6." last paragraph; AGENTS.md "Table lookups in a Span lose their bounds checks" -->
The same pattern, for the same reason, is the Zstandard decoder's tables in a workspace it owns, indexed through a
pointer ([section 6](#6-allocation-free-code)).<!-- src: AGENTS.md "InlineArray passed borrowing can be copied at every subscript" -->

#### The inverse: a wide load that ends past the data

Removing a check by loading a wider value needs the opposite discipline. `read(_:asciiDigits:)`'s two-load path lacked a
`count > 8` condition, so short reads near the end of the data loaded 8 bytes past it with an unchecked load. Every test
with bytes after the field passed. Every fast path that uses a wide load gets a test whose input ends exactly where the
field does.<!-- src: AGENTS.md "Test reads that end exactly at the data's end" -->

### 3. Let LLVM vectorize your loops

Auto-vectorization (Part I, ["SIMD and NEON"](#2-simd-and-neon)) turns a loop that processes one element per iteration into one
that processes several (for bytes on ARM64, 16) per iteration, with a vector register and one instruction per operation.
It is the largest source of speed in Bytes: most of its bulk loops are ordinary Swift written so that LLVM's loop vectorizer
accepts them.<!-- src: OPTIMIZATION-old.md "7. Let LLVM vectorize your loops" first line; Part I section on SIMD for the definition -->

#### Independent loads, not a moving pointer

A reader that advances a pointer field by field makes each load wait for the previous advance: a dependency chain.
Bytes loads each field of a record from `base + constant offset`, independently. On the same zip directory, Bytes took
two-thirds of the time of a conventional pointer-advancing reader (11 against 17 µs) despite running 10% more
instructions (286 K against 260 K).<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): BytesBenchmarks rows "Fields: Bytes" 10,751 ns / 285,695 instructions and "Fields: original ByteReader" 16,847 ns / 259,711; OPTIMIZATION-old.md "7." "Independent loads, not a moving pointer" -->

#### Odd widths from overlapping loads

There is no 3-byte load instruction. A `Byte3` is read as two overlapping 2-byte loads (bytes 0–1 and 1–2) combined with
a shift, and `Byte5` to `Byte7` as two overlapping 4-byte loads. That never reads past the value, and LLVM vectorizes
it. Runs of 3-byte values are the exception: loading each byte separately lets LLVM use `ld3`, which loads 48 bytes and
deinterleaves them into three registers (bytes 0, 3, 6, … in the first, 1, 4, 7, … in the second): 13 to 19 GB/s
in a loop (+46%). There is no `ld5`: 5-byte groups loaded bytewise ran at 9.2 GB/s, against 22.5 with overlapping
loads.<!-- src: OPTIMIZATION-old.md "7." "Odd widths with overlapping loads" -->

#### Use as many lanes as the register has

A 128-bit vector register holds 16 byte lanes. The first version iterated bit fields in 64-bit blocks of 8 values,
which fills two lanes. For widths that divide 8 (1, 2, 4, 8 bits), iterating a byte at a time gives 16 lanes:<!-- src: OPTIMIZATION-old.md "7." "Use as many lanes as you can" -->

| Width | 64-bit blocks | A byte at a time | Speedup |
|---|---|---|---|
| `Byte` (8 bits) | 12 GB/s | 77 GB/s | 6.4x |
| `Nibble` (4 bits) | 6.0 | 50 | 8.3x |
| `Crumb` (2 bits) | 3.9 | 28 | 7.2x |
| `Bit` | 2.0 | 11 | 5.5x |
<!-- src: OPTIMIZATION-old.md "7." table -->

`Bit` at 11 GB/s is 88 billion values per second, about 22 per cycle.<!-- src: OPTIMIZATION-old.md "7." -->
The benchmark's own consumer had the same problem: summing every `UInt16` into a 64-bit total turns one register of 8
values into four registers of 2, so the widening, not the reading, was the bottleneck. Summing in the value's own width
took `Byte2` from 37 to 75 GB/s.<!-- src: OPTIMIZATION-old.md "7." -->

#### What stops the vectorizer

Each of these was found in the assembly, then confirmed with a benchmark:<!-- src: OPTIMIZATION-old.md "7." "What stops the vectorizer" -->

| Pattern | Why it cannot be vectorized | Fix |
|---|---|---|
| A lookup at a computed index (`table[Int(x)]`) | Each lane needs a different address: a gather, which NEON cannot do from memory | Compute the value instead (below) |
| `if`s or ternaries in the body | LLVM vectorizes an `if` by computing both sides and picking per lane, but only while it is still an `if`; once optimized into real jumps it cannot | Arithmetic masks (below) |
| An early exit (`return` or `throw` in the loop) | The vector loop would already have run the lanes after the exit | Explicit SIMD ([section 4](#4-write-simd-by-hand-and-reach-instructions-swift-cannot-name)), or one check before the loop ([section 2](#2-remove-the-checks-the-compiler-cannot-prove-away)) |
| 128-bit arithmetic | LLVM does not vectorize it | Split into 64-bit halves (`Byte9`–`Byte15`: scalar to vectorized) |
| Two 64-bit lanes | LLVM's cost model judges it not worth it, and Swift has no loop pragma to overrule it | Accept it: `Byte16` reads and `Byte8` writes stay scalar, yet `Byte16` still reads 56 GB/s on one core |
| A variable kept in memory | Each iteration's store must reach the next iteration's load | [Section 1](#1-keep-hot-state-in-registers) |
<!-- src: OPTIMIZATION-old.md "7." table -->

Two more entries from other loops:

- **Loops of `Int16` stores** and `MutableSpan.update(repeating:)` compile to one scalar store per element. A loop
  resetting `Int16` tables was 59% of a small input's time in the Brotli encoder; explicit `SIMD8<Int16>` stores fixed
  it. Likewise `initializeMemory(as:repeating:count:)` stored one `UInt16` at a time over a 262,144-entry table in the
  LZBITMAP encoder: reset large tables with explicit 64-byte vector stores.<!-- src: OPTIMIZATION-old.md "Compression: DEFLATE and Brotli, both directions" item 3; Bytes/Benchmarks/RESULTS-lzbitmap.md "Lessons" `initializeMemory` -->
- **SLP vectorization of a scalar kernel's edges.** The SLP vectorizer (Part I, ["The two vectorizers and their
  remarks"](#410-the-two-vectorizers-and-their-remarks)) turned scrypt's 16 consecutive `UInt32` loads and stores into vector operations with a lane move per word
  on the critical path. Loading and storing `UInt64` pairs (split with a shift) kept the words scalar: −6%.
  Check scalar kernels with `Tools/loops --forbid mov.s,fmov,ins,umov`.<!-- src: Bytes/Benchmarks/RESULTS-scrypt-x509.md "Salsa20/8: scalar beats vector here" last paragraph and Lessons -->

#### Branches become arithmetic masks

Base64 maps 6-bit values (0–63) to characters by range. The natural code stayed scalar in the package build:<!-- src: OPTIMIZATION-old.md "7." example -->

```swift
// Stayed scalar in the package build. The range tests are correlated (a value of at least 62 is at
// least 52), so LLVM merged them into jumps ("jump threading") and then could not vectorize.
func character(_ v: UInt8) -> UInt8 {
    if v < 26 { return v &+ 65 }        // A–Z: 'A' is 65
    if v < 52 { return v &+ 71 }        // a–z: 'a' (97) − 26
    if v < 62 { return v &- 4 }         // 0–9: '0' (48) − 52
    return v == 62 ? 43 : 47            // '+', '/'
}

// Vectorized: masks are arithmetic, so there is nothing to turn into a jump.
// 0xFF if v >= bound, else 0: adding 128 - bound sets the high bit exactly when v >= bound;
// shift it down to 1 or 0, and 0 - 1 wraps to 0xFF.
func mask(_ v: UInt8, atLeast bound: UInt8) -> UInt8 { 0 &- ((v &+ (128 &- bound)) &>> 7) }

// The same mapping as sums of masked offsets: 65 for A–Z; + 6 = 71 for a–z; + 181 wraps to −4 for 0–9.
// `deltas` hold the last two characters' offsets, which differ between the standard and URL-safe alphabets.
func character(_ v: UInt8, _ deltas: (UInt8, UInt8)) -> UInt8 {
    v &+ 65 &+ (mask(v, atLeast: 26) & 6) &+ (mask(v, atLeast: 52) & 181)
        &+ (mask(v, atLeast: 62) & deltas.0) &+ (mask(v, atLeast: 63) & deltas.1)
}
```
<!-- src: OPTIMIZATION-old.md "7." -->

The branching version vectorized in a one-file test but not in the package build: the optimizer's decisions depend on
context, so check the build you ship.<!-- src: OPTIMIZATION-old.md "7." last paragraph -->
In the encoder's history, a scalar table loop at 0.86 GB/s (16 instructions per byte) became 9.0 GB/s when the
character was computed with masks and LLVM vectorized it to `ld3` and `st4`.<!-- src: OPTIMIZATION-old.md "Base64: 0.86 → 21.4 GB/s" table -->

#### Keep the compiler's choices out of the way

- **Constants as integer literals.** `SIMD16<UInt8>` array literals (`[0, 16, 32, …]`) inside inlinable library code
  compiled to calls to `SIMD.init(_:)` in the caller's loop (Base64's decoder: 3 calls per block, then 5 per call for its
  table, about 1,200 instructions), though in other functions the same literals folded. Written as `Byte16` literals
  (bytes in memory order, `0x00_10_20_…`) and converted with `.vector`, integer constants always fold. Check new
  kernels with `Tools/calls … --callee 'SIMD.init'`.<!-- src: AGENTS.md "Constant vectors" -->
- **Shuffles chosen by a `Bool`, and vectors built from an array literal and then mutated per lane,** also become
  per-lane inserts (16 for the literal); `Tools/loops` flags these as `+lane-moves`.<!-- src: OPTIMIZATION-old.md "9." "The catch" last paragraph -->
- **A stack buffer instead of a shuffle** keeps scalar and vector code apart when LLVM would merge them ([section 4](#4-write-simd-by-hand-and-reach-instructions-swift-cannot-name)).

#### Asking the compiler why not

`Tools/remarks` prints the optimization remarks from Swift's own LLVM. Of its messages, two are the most common.
"Cannot vectorize early exit loop" usually means a bounds-check trap in the body, and "loop control flow is not understood" means
branches in the body (usually from `if` or a ternary that survived).<!-- src: AGENTS.md "Tools/remarks FILE.swift" paragraph -->
`Tools/loops` then confirms the result: it reports each loop's verdict (`vector128`; `vector64`, often a vectorizer
epilogue; `scalar`; `+lane-moves`; `+calls`), and `--require`/`--forbid` make it a check:<!-- src: AGENTS.md "Tools/loops" paragraph -->

```sh
Tools/loops --target Bytes BytesBase64 encodeBlocks --require tbl,zip --forbid mov.b,ins
```
<!-- src: AGENTS.md "Static: what the compiler produced" example -->

#### When not to

Vectorize independent work, not a dependent chain ([section 7](#7-branches-and-data-dependent-work)), and not when the loop around the vector code goes
back to scalar per element: unpacking 3-byte values with `tbl` and then calling the loop body once per value was 5x
slower than the plain loop that LLVM had already vectorized, body included, using `ld3`.<!-- src: OPTIMIZATION-old.md "9." "When not to shuffle" -->

### 4. Write SIMD by hand, and reach instructions Swift cannot name

When the vectorizer cannot help (searches that stop at the first match, table lookups, shuffles), the options are
Swift's `SIMD16<UInt8>`, then a small C target of `static inline` wrappers around NEON intrinsics, then (rarely) an
empty inline-assembly statement to stop the compiler from merging what you wrote.

#### Searching 16 positions at once

Finding a zip file's end-of-directory signature means scanning backward for 4 bytes. The scalar loop compares at each
offset and exits on a match, which LLVM will not vectorize. The SIMD version tests 16 candidate offsets per step: it
compares the pattern's first byte against 16 loaded bytes and its last byte against the 16 bytes 3 further on, then
checks only offsets where both match (the "first and last byte" filter from Wojciech Muła's SIMD substring search).<!-- src: OPTIMIZATION-old.md "8. Write SIMD yourself with SIMD16" -->

```swift
// 33 µs to search 64 KB: one load and compare per offset.
for offset in stride(from: last, through: 0, by: -1)
where span.load(fromByteOffset: offset, as: UInt32.self) == signature { return offset }

// 2.0 µs (16x): 16 offsets per 12 instructions. Simplified from BytesReader.lastByteOffset(of:).
let head = SIMD16<UInt8>(repeating: pattern[0])         // the signature's first byte, in every lane
let tail = SIMD16<UInt8>(repeating: pattern[3])         // and its last byte
while offset >= 0 {
    let starts = span.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)       // bytes offset ..< offset+16
    let ends = span.load(fromByteOffset: offset + 3, as: SIMD16<UInt8>.self)     // 3 bytes later
    let candidates = (starts .== head) .& (ends .== tail)                         // cmeq, cmeq, and
    if any(candidates) { /* compare the full signature at each candidate */ }     // umaxv
    offset -= 16
}
```
<!-- src: OPTIMIZATION-old.md "8." -->

#### Pitfalls of `SIMD16` in Swift 6.4

The standard library's SIMD operations are not uniformly one instruction. Measured on Swift 6.4 (the first two are
fixed in 6.5-dev):<!-- src: AGENTS.md "SIMD16<UInt8> on 6.4" -->

- Comparisons of two vectors (`a .== b`, `a .>= b`) are one instruction (`cmeq`, `cmhs`), but the overloads taking a
  scalar (`v .== 0`, `v .>= 0x80`) compile lane by lane. Splat the scalar into a vector (`SIMD16(repeating:)`).<!-- src: AGENTS.md same -->
- `any()` and `all()` are inlined (`umaxv`) in some loops and out-of-line calls in others.<!-- src: AGENTS.md same -->
- The dynamic subscript (indexing a vector with a run-time lane) is per lane on both versions.<!-- src: AGENTS.md same -->
- `pointwiseMin` and `pointwiseMax` on `SIMD16<UInt8>` are calls: use a vector comparison (`a .<= b`, one
  `cmhs`/`cmhi`) and `replacing(with:where:)`.<!-- src: AGENTS.md "pointwiseMin/pointwiseMax on SIMD16<UInt8> are calls" -->
  But `replacing(with:where:)` with a comparison's mask itself compiled a lane at a time in the LZBITMAP decoder (about
  200 instructions a vector, though one `bsl` elsewhere). Build masks arithmetically (`0 &- (x &>> 7)`), or take a
  comparison's mask as lanes with `unsafeBitCast(mask, to: SIMD8<UInt16>.self)` (one `cmhi`).<!-- src: Bytes/Benchmarks/RESULTS-lzbitmap.md "Lessons" `replacing(with:where:)` bullet -->
- Reductions are unreliable: `SIMD16<UInt8>.max()` was an out-of-line call, and `SIMD8<UInt16>.max()` was one `umaxv` in
  one version of a loop and 17 lane moves in the next. Vector reductions through `Builtin` are one instruction each
  (`Builtin.int_vector_reduce_umin_Vec4xInt32` and similar, on `._storage._value`; BytesCompression enables
  `BuiltinModule`).<!-- src: Bytes/Benchmarks/RESULTS-lzbitmap.md "Lessons" "SIMD reductions are unreliable" and "Vector reductions through Builtin" -->
- Per-lane shift amounts on `SIMD8<UInt16>` (`v &>> SIMD8(10, 6, 10, 6, ...)`) compiled to 64-bit halves with lane
  reversals; lane picks from two vectors became byte inserts unless they were one contiguous run (which becomes `ext`).<!-- src: OPTIMIZATION-old.md section 12 table "Per-lane shift amounts" -->
- Generic standard-library SIMD conversions are inlined only while they have few callers (below).

Bytes' `ByteLanes` sidesteps most of this by building its tests from wrapping arithmetic and bitwise operations, which
always compile to a few NEON instructions:<!-- src: OPTIMIZATION-old.md "8." -->

```swift
struct ByteLanes { var vector: SIMD16<UInt8> … }

// The high bit is set in each lane equal to `byte`: (x &- 1) & ~x has its high bit set exactly when x is 0.
func matching(_ byte: UInt8) -> ByteMatches {
    let difference = vector ^ SIMD16(repeating: byte)
    return ByteMatches(highBits: (difference &- 1) & ~difference)
}

// Did any lane match? OR the two 64-bit halves together: no reduction across 16 lanes needed.
var any: Bool {
    let words = bitCast(highBits & 0x80, to: SIMD2<UInt64>.self)
    return words[0] | words[1] != 0
}
```
<!-- src: OPTIMIZATION-old.md "8." -->

(In the trick, `x - 1` borrows into the high bit only when `x` was 0; `& ~x` removes lanes that already had the high bit
set.)

**A client of the trick: MQTT's topic check.** ASCII is already valid UTF-8, so one pass, 16 bytes per step, checks that
every byte is ASCII (each lane's high bit) and that none is a byte MQTT forbids (`0`, `+`, `#`). The last step re-reads
the final 16 bytes, overlapping the previous step, so there is no byte-at-a-time tail. A 32-byte topic takes two inlined
steps of 9 vector instructions; only non-ASCII topics go on to the standard library's UTF-8 validation. Per PUBLISH
(three strings, all ASCII) this was about 13 ns less to parse, +26% packets per second for full parsing.<!-- src: OPTIMIZATION-old.md "8." last paragraph; MQTT/Benchmarks/RESULTS.md "What vectorizes" and "16-byte scans" -->

**Narrowing and masks from bytes.** `ByteMatches.nibbleMask` narrows a 16-lane comparison result to 4 bits per lane with
one `shrn`, which finds the first matching lane in far fewer instructions than a one-bit gather. A bug there (it shifted
before narrowing, so odd lanes reported bit 3) went unnoticed because the tests used one filler byte; lane tricks need
varied test data around each match. And a cheaper mask is not a cheaper loop: Brotli's 16-slot tag filter walking 4-bit
slots ran 2.7% more instructions than the one-bit gather (2,529 M against 2,463 M at quality 5 on `dickens`), so it was
reverted.<!-- src: OPTIMIZATION-old.md "Compression: DEFLATE and Brotli" item 4 and "11." "Lane tricks need varied test data"; AGENTS.md "A cheaper mask isn't a cheaper loop" -->

**Prefix sums across 16 lanes.** A format with sequential cursors, where some elements consume a byte and some do not
(LZBITMAP's bitmap and period areas), can be resolved 16 groups at a time: a prefix sum or a fill-forward across 16 lanes
is four `tbl` shifts (constant indices `iota - k`, where `iota` is the lane numbers 0–15, with 0xFF lanes giving 0),
leaving a per-group loop of loads, one `tbl`, and a store.<!-- src: Bytes/Benchmarks/RESULTS-lzbitmap.md "Lessons" "Prefix sums and fill-forward" -->
Pairwise-add trees count matches for many comparisons at once: 16 candidates' 16-byte `cmeq` masks reduce to each
candidate's two 8-byte counts in 14 `addp.16b`, against 3 `uaddlp` per candidate.<!-- src: Bytes/Benchmarks/RESULTS-lzbitmap.md "Lessons" "Pairwise-add trees" -->

#### Reaching instructions Swift cannot name

Some NEON instructions do in one step what otherwise takes a dozen, and Swift cannot emit them: it has no
intrinsics (Part I, ["Reaching these from Swift"](#210-reaching-these-from-swift)), `Builtin` does not expose CPU-specific ones, and
`SIMD16`'s dynamic subscript compiles a lane at a time. The fix is a small C target of `static inline` functions over C
vector types that Swift imports as `SIMD16<UInt8>`. Swift inlines these, so each call becomes the single instruction:<!-- src: OPTIMIZATION-old.md "9. Reach instructions Swift can't express" -->

```c
// CBytesNEON.h (ARM64 branch; the header also has a portable fallback)
typedef uint8_t bytes_u8x16 __attribute__((ext_vector_type(16)));   // imported as SIMD16<UInt8>
#define BYTES_INLINE static inline __attribute__((always_inline))

// Looks up each lane of `index` in a 64-byte table held in four vectors.
BYTES_INLINE bytes_u8x16 bytes_table4(bytes_u8x16 a, bytes_u8x16 b, bytes_u8x16 c, bytes_u8x16 d,
                                      bytes_u8x16 index) {
    uint8x16x4_t table = { { (uint8x16_t)a, (uint8x16_t)b, (uint8x16_t)c, (uint8x16_t)d } };
    return (bytes_u8x16)vqtbl4q_u8(table, (uint8x16_t)index);       // the intrinsic for one `tbl`
}
```
<!-- src: OPTIMIZATION-old.md "9."; Bytes/Sources/Bytes/ByteLookup.swift bytes_table4 use (line 58) -->

The families worth this treatment:

- **`tbl`: table lookup.** Each lane of an index vector picks one byte from a table of up to 64 bytes in four registers:
  16 lookups in one instruction, with no memory access. It is the gather NEON cannot do from memory, done in registers.
  Uses: moving the bytes of 3-, 5-, 6-, and 7-byte values into whole lanes and back, and Base64's mapping of 6-bit values
  to characters. On the M3 a `tbl` costs one micro-op per table register.<!-- src: OPTIMIZATION-old.md "9." ; AGENTS.md "On M3, NEON ld4/st3" -->
- **`zip`: interleave.** `zip1`/`zip2` interleave two vectors lane by lane (`a0 b0 a1 b1 …`).<!-- src: OPTIMIZATION-old.md "9." -->
- **`pmull`, `eor3`, `crc32x`** for CRCs (sections [7](#7-branches-and-data-dependent-work) and [8](#8-algorithms-and-data-structures-codec-by-codec)), **`udot`** for Adler-32, and the crypto
  instructions `aese`/`aesmc`, `sha256h`, `sha512h` through `CBytesCrypto` ([section 9](#9-crypto)).<!-- src: OPTIMIZATION-old.md "9."; Bytes/Benchmarks/RESULTS.md "Adler-32 with UDOT"; Bytes/Sources/BytesCrypto/AES.swift bytes_aese -->

**`udot` made Adler-32 twice as fast.** Adler-32's two sums are dot products (Part II, ["Adler-32: `udot`"](#adler-32-udot)), so the
instruction is a `static inline` wrapper (`bytes_crc_udot`) and the loop is Swift. The first loop was 16 instructions per
64 bytes and bound by `udot`'s latency (the earlier version, below); the current one is 13 instructions per 64 bytes, in
128-byte steps:<!-- src: Bytes/Benchmarks/RESULTS.md "Adler-32 with UDOT: 2x faster" (and its 2026-11-20 correction); "2026-11-20, Adler-32: past `udot`'s latency" (13 instructions per 64 B, from 16); Bytes/Sources/Bytes/Adler32.swift _updateDotProduct -->

```asm
; The inner loop of Adler32._updateDotProduct: 26 instructions per 128-byte step (13 per 64 bytes).
; v0 = ones; v1–v7 and v16 = the weights 128…113, 112…97, …, 16…1; x5 points 64 bytes into the step.
; v17 = sum; v26 = prefix; v11 = the step's own byte sum; v25, v24, …, v18 = weighted0…weighted7.
L1:
ldp     q27, q28, [x5, #-0x40]  ; bytes 0–31 of the step
ldp     q29, q30, [x5, #-0x20]  ; bytes 32–63
ldp     q31, q8, [x5]           ; bytes 64–95
ldp     q9, q10, [x5, #0x20]    ; bytes 96–127
add.4s  v26, v17, v26           ; prefix += sum: the byte sum of the steps before this one (carried)
movi.2d v11, #0                 ; the step's byte sum starts from zero: nothing carries it
udot.4s v11, v27, v0            ; step += bytes 0–15 · ones: 4 bytes into each 32-bit lane
udot.4s v11, v28, v0            ; …one chain of eight udots, 24 cycles of latency, that no later step waits on
udot.4s v11, v29, v0
udot.4s v11, v30, v0
udot.4s v11, v31, v0
udot.4s v11, v8, v0
udot.4s v11, v9, v0
udot.4s v11, v10, v0
add.4s  v17, v11, v17           ; sum += step (carried)
udot.4s v25, v27, v1            ; weighted0 += bytes 0–15 · (128…113): each accumulator takes one udot a step
udot.4s v24, v28, v2            ; weighted1
udot.4s v23, v29, v3            ; weighted2
udot.4s v22, v30, v4            ; weighted3
udot.4s v21, v31, v5            ; weighted4
udot.4s v20, v8, v6             ; weighted5
udot.4s v19, v9, v7             ; weighted6
udot.4s v18, v10, v16           ; weighted7
add     x5, x5, #0x80           ; x5 += 128
subs    x6, x6, #0x1            ; one step fewer
b.ne    L1                      ; loop while steps remain
```
<!-- src: Bytes/Sources/Bytes/Adler32.swift _updateDotProduct, the package's release build (Tools/loops --target Bytes Bytes 'Adler32.*(checksum|update)' --body: loop 2, 0x2c4–0x328, 26 instructions: 16 udot.4s, 4 ldp, 2 add.4s, add, movi.2d, subs, b.ne); Bytes/Benchmarks/RESULTS.md "2026-11-20, Adler-32: past `udot`'s latency" ("19 vector operations a step (16 udot, 2 add.4s, a movi zeroing the chain), 26 instructions per 128 B") -->

(This is the loop in the package's release build, from `Tools/loops --body`.) Four `ldp`s (eight vectors), sixteen `udot`s,
two adds, a `movi`, and the loop's three bookkeeping instructions. The eight weighted accumulators are independent chains that each
take one `udot` a step. The byte sum is the part that changed: a step's eight `udot`s form one chain started from zero, so
no later step waits on it, and only the two adds (`prefix`, `sum`) carry from step to step. The 19 vector operations are
4.75 cycles on four pipes, and the weighted chains' 3-cycle latency fits inside that. In L1 the loop runs 2.43 cycles per
64 bytes against the 2.375 its 19 operations allow: the `movi` takes a pipe.

**The earlier loop** (the first `udot` version) was 16 instructions per 64 bytes: 8 `udot.4s`, 4 `add.4s`, 2 `ldp`, `subs`,
and `b.ne`. Its eight accumulators were independent chains, so the `udot`s did not wait on each other within an
iteration, but each accumulator waited for its own `udot` from the iteration before: with `udot`'s 3-cycle latency, an
iteration took at least 3 cycles however many the core could issue (the M3 Ultra issues 4 a cycle), and its four adds for
`prefix` and eight `udot`s were 12 vector operations, also 3 cycles. On an M1 Max the result was 29.6 to 56.9 GB/s on 1 MB
in a probe (the benchmark: 36 to 19 µs, against libdeflate's 18), instructions −51%, and 64-byte inputs −12% in time: 64
bytes per 3 cycles is 68 GB/s at 3.21 GHz (83% of it reached, re-measured 2026-11-21), and on an M3 Ultra (4.02 GHz, 86 GB/s by the same bound) it measured 76 GB/s.
That loop took 86 blocks (5,504 bytes) between reductions so no 32-bit lane overflowed. <!-- src: Bytes/Benchmarks/RESULTS.md "Adler-32 with UDOT" and "2026-11-20, Adler-32: past `udot`'s latency" (the two bounds; 2.43 against 2.375 cycles per 64 B) -->

Why not 16 accumulators? Two blocks a step with eight accumulators for the byte sums would have needed eight adds a step to
form `prefix`: 24 vector operations per 128 bytes, still 3 cycles per 64 bytes (+3% measured). Cutting the dependency, not
adding chains, was the fix. On the M3 Ultra (baseline `m3-final`): 101 GB/s at 1 MB against 76 before, 215 K instructions
for 1 MB (from 271 K, −21%) and 1,264 K for 16 K 64-byte inputs (from 1,755 K, −28%); the `udot` change itself had taken
them from 555 K and 2,345 K (−51% and −25%, baselines `speed-after` → `p3-spot`).<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, Adler-32: past `udot`'s latency" (24 operations, +3%; 272 K → 215 K −21.0%; 1,755 K → 1,264 K −28.0%); Tools/probes/results/M3-Ultra-2026-11-20/checksums.tsv (101.2 GB/s at 1 MB); "Cleanup and improvements (2026-11-19)"; baselines CompressionBenchmarks speed-after → p3-spot (M3 Ultra), rows "Adler-32 1 MB: Bytes" and "Adler-32 64 B (×16 K): Bytes" -->

#### The catch: LLVM merges shuffles into ones it cannot build

Interleaving four vectors takes two rounds of `zip`s. Written with Swift's lane initializers, each round alone compiles
to `zip`s, but LLVM's instruction combiner fused the two rounds into four-vector shuffles, which ARM64 can only build one
lane at a time: 1 `zip` and 14 lane inserts per output vector instead of 3 `zip`s. The C helper separates the rounds with
an empty inline-assembly statement, which emits nothing but stops the compiler from seeing through it:<!-- src: OPTIMIZATION-old.md "9." "The catch" -->

```c
uint8x16_t ab0 = vzip1q_u8(a, b), ab1 = vzip2q_u8(a, b);
uint8x16_t cd0 = vzip1q_u8(c, d), cd1 = vzip2q_u8(c, d);
// "+w": the asm may change these vector registers, so the compiler can't merge across it.
__asm__("" : "+w"(ab0), "+w"(ab1), "+w"(cd0), "+w"(cd1));
result.v0 = vzip1q_u16(ab0, cd0);   // second round, on 16-bit lanes (casts omitted)
// …
```
<!-- src: OPTIMIZATION-old.md "9." -->

The same barrier fixes a second merge: LLVM narrows loads to the lanes a shuffle uses. The first round of `uzp1`s needs
only the even bytes, so a 64-byte block feeding `ByteLanes.deinterleave` was loaded as 8-, 4-, 2-, and 1-byte lane loads
(`ld1.b`, `mov.h`, `ext`): 91 instructions per block against 45. An empty `asm` on the vectors before the shuffle keeps
the loads whole.<!-- src: AGENTS.md "LLVM narrows loads to the lanes a shuffle uses"; Bytes/Sources/CBytesNEON/include/CBytesNEON.h -->

#### Constant shuffles do not need C

A lookup with run-time indices needs `tbl`, so C. But if the indices are *constants*, Swift can do it: build a vector from
lanes of another, picked at constant positions, and LLVM recognizes the whole initializer as one shuffle. Bytes'
`GroupShuffle` unpacks 5-byte values this way, two per vector:<!-- src: OPTIMIZATION-old.md "9." "Constant shuffles don't need C" -->

```swift
// 10 bytes in (two 5-byte values, big-endian), two zero-extended 64-bit lanes out.
let v = span.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: SIMD16<UInt8>.self)
let lanes = SIMD16<UInt8>(v[4], v[3], v[2], v[1], v[0], 0, 0, 0,
                          v[9], v[8], v[7], v[6], v[5], 0, 0, 0)
```
<!-- src: OPTIMIZATION-old.md "9." -->

The loop is a load, one single-register `tbl`, and a store; on x86-64 the same Swift compiles to one `pshufb` (an
SSE2-only x86-64 target expands it into a longer sequence). A one-register `tbl` is a quarter of the micro-ops of a
64-byte one, and for iterators it beat the NEON lookups by 22–44% in a trial of the path, so every build uses it there. Against
the previous commit, iterating 3-byte values went from 294 to 160 µs per 4 MB, and 5–7-byte values got 26–28% faster.<!-- src: OPTIMIZATION-old.md "9." and "Three builds: NEON, portable C, Swift only" -->

**The same merge, without `asm`.** For writing, the first version built each vector from four computed values and
then shuffled it, and LLVM merged the two steps into one byte insert per byte (40 per vector for 3-byte values), slower
than not shuffling. `forEach`, handing the caller's body each value straight out of the vector, kept the body scalar:
summing ran 2x slower than the plain loop. An empty `asm` would stop the merging, but it is specific to each
architecture.

The portable fix is to go through memory: a stack buffer (`withUnsafeTemporaryAllocation`, no heap allocation). To
write, a plain loop computes a chunk of values into it (which LLVM vectorizes like any loop) and vectors are loaded back,
shuffled, and stored. For `forEach`, vectors are unpacked into it and the caller's body runs over it as a plain loop,
which vectorizes with the body. A load from memory is opaque enough to stop the merging. Staging only pays for a full
buffer (64 or 128 values): shorter runs took 37% more instructions, so they keep the plain loops.<!-- src: OPTIMIZATION-old.md "9." "The same merging, without asm"; Bytes/Sources/Bytes/GroupShuffle.swift withUnsafeTemporaryAllocation (line 286) -->

#### Generic conversions are inlined only while they have few callers

`SIMD8<UInt16>(truncatingIfNeeded:)` in LZBITMAP's decoder was inlined until the LZFSE and LZVN encoders, in the same
module, used SIMD conversions too; then the generic specialization stayed a call (6 per 16 groups) and decoding ran
12–15% more instructions (dickens 32 to 36 M, mozilla 53 to 61 M; both are Silesia corpus files), with no change to
the decoder's file. Bisecting the module's files in a copy of the package found it.

In hot code, widen with a byte zip (lane picks of two vectors: `zip1`/`zip2`) and narrow with Bytes' `_lowBytes`
(`Builtin.trunc`: one `xtn`, or `shrn` after a shift). Picking even bytes to narrow was merged by LLVM into lane moves.
Recheck hot loops with `Tools/calls --callee 'specialized SIMD'` after adding code to their module.<!-- src: AGENTS.md "Generic standard-library SIMD conversions are inlined only while they have few callers"; Bytes/Benchmarks/RESULTS-lzbitmap.md "a 12–15% regression from code added elsewhere in the module"; Bytes/Sources/Bytes/Builtins.swift _lowBytes -->

#### An emulated instruction is no fallback

Emulating `tbl` a lane at a time made the portable build 37–113x slower than the NEON one (Part II, ["Why emulating `tbl`
is no fallback"](#why-emulating-tbl-is-no-fallback)). An algorithm designed around one CPU's instruction belongs behind a check that the instruction is there
(`ByteLanes.isLookupVectorized`), with a different algorithm elsewhere. LZBITMAP's decoder does this: with `tbl` it
resolves 16 groups at a time, and without it, it decodes a group at a time (31 instructions a group).<!-- src: OPTIMIZATION-old.md "9." "An emulated instruction is no fallback"; AGENTS.md "Emulating a lookup"; Bytes/Sources/BytesCompression/LZBitmapDecoder.swift line 302; Bytes/Benchmarks/RESULTS-lzbitmap.md "The decoder" -->

#### A kernel designed for one ISA is not a kernel for another

Base64 encoders written for x86's SSE and AVX vector instructions reshuffle each 3-byte group into its 4 output bytes
and then extract the 6-bit values with shifts and masks per 32-bit lane, so no interleave is needed. On NEON that was 75 instructions per 48-byte block against
32 for the deinterleaving kernel (143 with per-lane shifts on 16-bit lanes, 243 with lane picks):<!-- src: Bytes/Benchmarks/RESULTS-base64.md "a reshuffling encoder kernel, not kept" -->

| Kernel (per 48-byte block) | Instructions | Vector work |
|---|---|---|
| Deinterleave, compute, interleave (kept) | 32 | 7 `tbl` (25 micro-ops), 10 for the fields, interleave folded into 2 `st2` |
| Reshuffle, 32-bit shifts and masks | 75 | 8 `tbl` (20 micro-ops), 44 for the fields |
| Reshuffle, per-lane shifts on 16-bit lanes | 143 | split into 64-bit halves with `rev32`/`trn2` |
| Reshuffle by lane picks | 243 | byte loads and lane inserts |
<!-- src: Bytes/Benchmarks/RESULTS-base64.md "a reshuffling encoder kernel, not kept" table -->

#### Case study: the Base64 encoder's kernel

The kernel per 48-byte block (its Swift source is in Part II, ["Base64"](#base64); its machine code in Part I, ["A worked example:
the Base64 encoding kernel"](#38-a-worked-example-the-base64-encoding-kernel)) is the section's techniques together: a deinterleave in registers (3 `tbl`s doing what `ld3`
does), shifts and masks to cut out the 6-bit values, `tbl` to map them to characters, `zip`s to interleave.<!-- src: OPTIMIZATION-old.md "10." "Base64" kernel -->

The steps and their effect (1 MB, one run): scalar table loop 0.86 GB/s; characters by masks, LLVM-vectorized, 9.0; 48-byte
blocks with `tbl`, 19.1; blocks as typed-span elements so the checks fold, 18.9; interleave with 8 `zip`s instead of 4
four-register lookups, 21.7; short inputs as one padded block, 21.0 (64-byte inputs 3.2 to 4.4 GB/s). The latest M3 Ultra
run (baseline `m3-final`) measured 20.4 GB/s at 1 MB (21.5 in `d2-final`), with zero allocations at every size, 32 instructions
per 48 bytes in about 9.5 cycles (3.4 instructions per cycle); Foundation's `base64EncodedData()` runs 3.2 GB/s there. A C
kernel using `ld3` and `st4` directly reached 23.1 GB/s in the `d2-final` run, where the Swift kernel was at 93% of it, and
the same-design C kernel 21.8, level with it.<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): Base64Benchmarks rows "Encode 1 MB: Bytes (BytesReader → BytesWriter)" 205,695 ns / 2,799,615 instructions, ": Foundation base64EncodedData" 1,300,479 ns (3.23 GB/s), 0 mallocs; Bytes/Benchmarks/RESULTS-base64.md "How it got here" table, "Encoding (GB/s of input: M3 Ultra → M1 Max)" 1 MB row (21.5, Foundation 3.17), "Current (baseline final)" and "The ceiling" -->

The limit is how many `tbl` micro-ops the core can start per cycle, not instruction count: cutting instructions 2.3x did
not change the speed, but replacing the 4 four-register lookups that interleaved with 8 cheaper `zip`s gained 15% in the
Swift encoder at 1 MB (18.9 to 21.7 GB/s), and 12% in the C kernels of the same design (19.5 to 21.8 GB/s).<!-- src: Bytes/Benchmarks/RESULTS-base64.md "How it got here" table (tbl-spans 18.9 → zip 21.7) and "The ceiling" table (19.5 → 21.8; its "gained 12%"); the "+12%" bullet under "How it got here" does not match its own table -->

The decoder (described in Part II, ["Base64"](#base64)) is the same lesson with `tbx`, a lookup that keeps the lane's old value when
the index is out of range: an 80-entry window of the ASCII table looked up as one 64-byte `tbx` plus one 16-byte `tbx`,
instead of two 64-byte lookups, took 61 micro-ops per block instead of 69, +11%, to 12.8 GB/s, 99% of a C kernel using
`ld4`/`st3` (12.9). Two compiler traps account for the middle of its history: the `SIMD16` array literals that became
calls, and the narrowed loads (91 instructions per block against 45), both above.<!-- src: OPTIMIZATION-old.md "10." "Base64 decoding: 12.8 GB/s, at the C ceiling"; Bytes/Sources/BytesBase64/Decoding.swift values(of:_:) (two keepingOutOfRange lookups = bytes_table4x/vqtbx4q and a 16-byte tbx); AGENTS.md "On M3, NEON ld4/st3 didn't beat uzp and tbl shuffles" -->

#### When not to

Do not hand-write SIMD where the vectorizer already succeeded; check with `Tools/loops` first. Do not shuffle if the code
after the shuffle goes scalar. And register pressure can undo a clever instruction: ChaCha20's rotate by 8 as a `tbl`
byte shuffle (one instruction instead of shift and insert) took the eight-block double round from 264 to 323 instructions,
because the shuffle's table needed a register in a loop that already uses all 32. It was reverted.<!-- src: AGENTS.md "Register pressure beats instruction choice" -->

### 5. Inlining and specialization

#### What the compiler does, and where it declines

Swift is compiled twice over (Part I, ["The pipeline: SIL, then LLVM"](#41-the-pipeline-sil-then-llvm)). The SIL optimizer decides what to inline and
specialize; then LLVM runs its own inliner and loop passes. A generic function is fast only once it is specialized
(Part I, ["Generics, specialization, and metadata"](#43-generics-specialization-and-metadata)); an unspecialized one calls through type metadata and witness tables
and passes values through memory. `@inlinable` makes a function's body visible to other modules so they *can*
inline and specialize it; it does not make them do so. Two attributes force inlining, with different strength:<!-- src: Part I section 4 definitions; AGENTS.md "@inlinable doesn't mean inlined" -->

- `@inline(__always)`: a hint. The SIL inliner declined it for Brotli's match search ("Not profitable to inline ... cost
  = 785" in `Tools/remarks --passes sil-inliner`) once the loop grew, and LLVM then found it too costly: quality 5 ran
  2–8% more instructions.<!-- src: AGENTS.md "@inline(__always) is a hint; @inline(always) is a guarantee" -->
- `@inline(always)` (Swift 6.4, SE-0496): a guarantee. It inlined the same function.<!-- src: AGENTS.md same; OPTIMIZATION-old.md "5." -->

#### Where forcing paid

- **DEFLATE's decoder** ([section 1](#1-keep-hot-state-in-registers)): the guaranteed attribute plus small functions with local cursors was the largest
  of the changes that took it from 2x slower than zlib to faster.<!-- src: OPTIMIZATION-old.md "DEFLATE: from 2x slower than zlib" -->
- **CRC-32's `pmull` version** in its first form ran 3.5x slower than zlib: a nested helper that loaded each 16 bytes
  was not inlined, and each call spilled the eight accumulators. `@inline(always)` fixed it.<!-- src: OPTIMIZATION-old.md "CRC-32: 1.7–2.3x zlib" -->
- **LZ4's length continuation** stayed a call with `@inline(__always)`, keeping the input pointer in memory.
  `@inline(always)` plus lz4's shortcut for short sequences together cut LZ4 decoding 29–39% in instructions (dickens 79
  to 48 M, mozilla 215 to 141 M) and 31–45% in time.<!-- src: Bytes/Benchmarks/RESULTS-lz4-lzfse.md "What worked and what didn't" -->
- **The LZMA range decoder's `length` and `distance` methods** were calls until `@inline(always)`: 7% fewer
  instructions on the seg0 test input (93.5 to 87.3 per byte), though cycles moved only 0–4% (the chain, not the call,
  was the limit; [section 7](#7-branches-and-data-dependent-work)).<!-- src: Bytes/Benchmarks/RESULTS.md "LZMA ... How it got there" step 2 (87.3 vs 93.5 ins/B seg0) -->
- **LZRAVEN's coder** had 10 calls left in the decode loop with `@inline(__always)`; `@inline(always)` inlined them,
  and `start()` had to be inlined too, or its `inout` call kept the coder in memory through the loop.<!-- src: Bytes/Benchmarks/RESULTS-lzraven.md "Lessons" last bullet -->
- **DEFLATE's match copy, in the rewritten fast loop** (2026-11-22). `copyMatch` throws and takes the output span `inout`,
  and as `@inline(__always)` it stayed a call inside the large loop; `@inline(always)` inlined it. The loop's small helpers
  (`store`, `refill`, `consume`) are `@inline(__always)`; the guaranteed form went only to the one that was a call. After
  growing a loop, check it with `Tools/calls … --callee` and the helper's name.<!-- src: Bytes/Sources/BytesCompression/DeflateDecoder.swift `copyMatch` (`@inline(always)`, line 965) beside `store`, `FastBits` methods (`@inline(__always)`); AGENTS.md "Codegen traps met there: an `@inline(__always)` throwing helper taking an `inout MutableRawSpan` stayed a call in a large loop (`@inline(always)` inlined it …)" (AGENTS.md gives a −10% → −35% figure; no RESULTS file records it, so it is not repeated here) -->
- **A new `BytesWriter` initializer**, only `@inlinable`, was called out of line from NativeZip's decode function (789 to
  891 instructions, the writer returned through memory). Anything a hot function calls once per entry, initializers
  included, should be `@inline(__always)`; check with `Tools/calls … --callee init` after adding API.<!-- src: AGENTS.md "`@inlinable` doesn't mean inlined" -->
- **Generated code.** `@BinaryRecord`'s `init(parsing:)` stayed a call and returned its 17-field record through memory:
  297 K instructions against 199 K for the same hand-written parser. Forced inline, equal.<!-- src: AGENTS.md "Generated code needs @inline(__always)" -->
- **Closures with an inferred error type.** An unannotated closure passed to a generic `throws(E)` parameter was not
  inlined into Bytes' array builder (+3% instructions; Part I, ["Typed throws and error boxing"](#48-typed-throws-and-error-boxing)); annotated with its error
  type, it was. An overload taking only `throws(BytesError)` does not fix it: the unannotated closure still infers
  `any Error`.<!-- src: AGENTS.md "Closures passed to a generic throws(E) parameter" -->

#### Rare paths stay out of line

The opposite problem is inlining a path that rarely runs, which enlarges the hot loop. Bytes' faster short-distance back-reference,
inlined, grew DEFLATE's decode loop 15% and cost 12–14% on text, where it never runs. As a static function taking values
(the slow-path pattern from [section 1](#1-keep-hot-state-in-registers)) it kept its gain (−38% on pixel runs) at no cost elsewhere.<!-- src: AGENTS.md "Rare paths stay out of line" -->
The decoders have a fast loop, used while 32 (DEFLATE) or 128 (Brotli) bytes of input remain, and a careful, resumable one
for the rest. With both in one function the inliner gave up on the fast one; split, DEFLATE's went from 1,390 to 667
instructions, and Brotli's decoder got 10–30% faster with its own fast path.<!-- src: OPTIMIZATION-old.md "Compression: DEFLATE and Brotli" item 2 -->
The Zstandard decoder's careful path is out of line for the same reason.<!-- src: OPTIMIZATION-old.md "Zstandard: faster than libzstd" -->
Check a hot loop's size with `Tools/loops` before and after any addition.<!-- src: AGENTS.md "Rare paths stay out of line" last sentence -->

#### Forcing has a ceiling: the inliner's caller limit

`@inline(always)` is a guarantee for each call, but the SIL performance inliner also has a limit on how large a
*caller* may grow. A parse loop with every per-field function forced inline outgrew it, after which the inliner stopped
inlining ordinary functions into the loop, including `RawSpan.byteCount`, a two-instruction getter. It stayed a call,
three times per field, and each call clobbered the vector registers that held the name scan's lookup tables. Moving the
once-per-head target scan (a block-mask loop with its partial-block cases) out of line brought the loop back under the
limit: HTTP request heads went from 335 to 306 cycles, and heads of 1-byte fields from 520 to 429 (instructions on the
request corpus, 1,584 to 1,308).<!-- src: HTTPBytes/RESULTS.md "2026-11-23: HTTP/1 heads against cursed-http" step table rows 3 and 4 (req 335 → 306 (1,584 → 1,308 instructions), f1 520 → 429), and the closing paragraph "The inliner's limit is worth knowing beyond this parser" (whose own prose says −5% and −16%) -->
After forcing inlining into a large function, look at its disassembly for a `bl` to something trivial (or run `Tools/calls`
with `--callee` naming the getter). The remedy is the opposite of the force: take the rare or once-per-call part out of
the loop, as "Rare paths stay out of line" above does. The full case, with the rest of the parser's seven steps, is
[section 12](#12-case-study-httpbytes).

The same limit bites an experiment. Do not give a hot loop a second exit or a new call to try an idea: HTTPBytes' `farStop`
with an "after 3 blocks, try skip windows" exit became nested, duplicated loops (85 instructions with calls against the
original 29), and a call added to it left `RawSpan.byteCount` out of line again. Cap the loop's bound instead (it ran at most 3
blocks, `min(count - 64, block + 128)`), so its shape does not change, and call the new path after it ([section 12's
round 2](#round-2-two-gaps-measured-not-closed)).<!-- src: HTTPBytes/RESULTS.md "round 2, HTTP/1's remaining gaps" (nested duplicated loops, 85 instructions with calls against 29; the capped variant); AGENTS.md "Don't give a hot loop a second exit or a new call to test an idea" (`min(count - 64, block + 128)`) -->

#### Specialize on a constant, as a copy

Brotli quality 1's one-entry table ran through the bucket code's loop, at 7–10% more instructions. Two `@inline(never)`
wrappers over an `@inline(__always)` body taking a constant `Bool` gave each case its own loop:<!-- src: AGENTS.md "Specialize hot loops on a constant, as a copy" -->

```swift
// BrotliEncoder (simplified: the real functions also take the input, tables, and commands).
@inline(never) private mutating func parseSingle(…) -> (end: Int, commandCount: Int) {
    parse(…, single: true)     // qualities 1 and 2: the one-entry table's own copy of the loop
}
@inline(never) private mutating func parseBuckets(…) -> (end: Int, commandCount: Int) {
    parse(…, single: false)    // quality 3 and up
}
@inline(__always) private mutating func parse(…, single: Bool) -> (end: Int, commandCount: Int) { /* the loop */ }
```
<!-- src: AGENTS.md same; Bytes/Sources/BytesCompression/BrotliEncoder.swift parseSingle/parseBuckets/parse (lines 742–768) -->

#### Function merging can undo a specialization

LLVM's function merging (Part I, ["Function merging, and benchmarks that lie"](#49-function-merging-and-benchmarks-that-lie)) folds identical functions into one. For a
benchmark that compares an old and a new variant chosen by a constant `Bool`, merging can fold the two copies back into
one `merged …` function taking the constant as a run-time parameter, so both variants test it in the hot loop. A closure
that captures the flag is specialized once, taking it at run time, with the same effect. Look for `merged` symbols
(`nm --defined-only X.o | xcrun swift-demangle | grep merged`), and pass the constant as a literal at the inlined call
inside the closure. Likewise, do not measure a new path and its reference behind a run-time flag in one function:
changing one path moved the other's register allocation (an unchanged reference went 70 to 102 K instructions). Give
each its own `@inline(never)` function over a shared `@inline(__always)` body.<!-- src: AGENTS.md "Old and new code in one benchmark run" -->

The same merging is useful as a proof: when an `@inline(never)` probe of a new API and a hand-written equivalent merge
into one function, they compile to identical code. Named bit fields (`flags[ConnectFlags.userName]`) matched hand shifts
this way.<!-- src: AGENTS.md "Check a new API's codegen from another module" -->

#### Module boundaries and neighbors

Inlining decisions are not local. Code added elsewhere can change them:

- Moving `HuffmanCodeBuilder` into Bytes instead of BytesCompression cost +2 K instructions per 1.6 KB Brotli stream
  (149 to 151 K) with `@inlinable`, `@inline(__always)`, and `@inline(always)` alike; it went back.<!-- src: AGENTS.md "Moving code to another module can cost instructions even when it's inlined"; OPTIMIZATION-old.md "What tracking caught" -->
- The LZBITMAP regression above came from encoders added to the same module.<!-- src: Bytes/Benchmarks/RESULTS-lzbitmap.md -->
- An empty default closure is not free: MQTT's properties validation with a `visit: { _ in }` parameter cost 2% under
  Xcode's compiler; forced inline it gained 1% there and cost SocketStream (built with a PR toolchain whose inliner
  differs) 10%. Give the plain path its own body, and force inline only the variant that needs it.<!-- src: AGENTS.md "An empty default closure isn't free" -->
- A check added to an `@inline(__always)` helper turned it into a call (12% more instructions on random input in the LZVN
  encoder): recount after touching a hot loop's helpers.<!-- src: Bytes/Benchmarks/RESULTS-lz4-lzfse.md Lessons last bullet -->
- The standard library's own `ByteOrder.==` is an out-of-line call (the derived `==` of any other module's
  `@frozen` enum is too): `switch` over the order instead, 71 to 53 instructions in a byte-ordered writer.<!-- src: AGENTS.md "The standard library's ByteOrder.== is a call" -->

#### A public generic that is not inlinable runs unspecialized

`@inlinable` matters most on the generic public function, because without it nothing specializes it for the caller's types.
HTTPBytes' `HTTPContentCoding.negotiated` took the codings a server offers as `some Sequence`, and was public without
`@inlinable`: every call ran the unspecialized function, which boxed the sequence's iterator (6 mallocs a call) and was written to
parse the `Accept-Encoding` list once per offered coding. Made `@inlinable` and rewritten to read the list in one pass, the
benchmark's 2,599 values went from 24 M instructions and 16,000 mallocs to 3.51 M and none (that row also includes the vector
scans of [section 12](#round-2-field-values-as-views-and-a-vector-scan-pass); the machine was under load, so these are instruction
counts). Look for it with `Tools/calls` on the caller, which says whether the callee is a `specialized` copy, and with a zero-malloc gate.<!-- src: HTTPBytes/RESULTS.md "round 2, dates and field values" ("Accept-Encoding negotiation was generic over `some Sequence` without `@inlinable`: unspecialized, it boxed its iterator (6 mallocs a value), and parsed the list once per offered coding; now inlinable and one pass") and the table row "Accept-Encoding (2,599), br/gzip/identity | 24 M, 16,000 mallocs | 3.51 M, 0"; AGENTS.md "A public generic function over `some Sequence` that isn't `@inlinable` runs unspecialized and boxes its iterator … `Tools/calls` on the caller shows `specialized` when it isn't" -->

#### When not to

Do not force-inline everything: forcing a path inline in one function changed the inliner's choices for its neighbors
(the `visitingProperties` change: +10.4% in SocketStream's checker). Force the minimum, and re-measure every consumer
and both compilers.<!-- src: OPTIMIZATION-old.md "What tracking caught" table row 2; AGENTS.md "Cross-toolchain checks" -->

### 6. Allocation-free code

#### Why allocation matters

A `malloc` call costs tens of nanoseconds, allocations from many threads contend in the allocator, and every allocated
object eventually has to be freed. For small operations it dominates. CryptoKit's `AES.GCM` and ChaCha seals allocate per
call, which shows on short messages (1 KB × 1,024: 919 µs against Bytes' 212 µs for AES-128-GCM), and an MQTT parser
that allocates 3–4 times per packet scales badly on many cores (the conventional parser is 8.6x slower than the views on one
core and 18.6x on all).<!-- src: Bytes/Benchmarks/RESULTS.md "crypto in Swift" table (d2-final); MQTT/Benchmarks/RESULTS.md "The views against the conventional code" (M3, d2-final code) -->
The gate is package-benchmark's malloc counter with a `Thresholds/` file at 0 for each benchmark that claims to allocate
nothing; Part I (["Allocation gates"](#53-allocation-gates)) lists the tools that find a failing gate's source.<!-- src: AGENTS.md "Allocations:" lesson -->

#### Technique 1: workspaces, allocated once

Decoders and encoders are `~Copyable` structs that allocate their tables once in `init` and nothing after. Examples,
with the sizes the sources give: the Zstandard decoder's tables and literal buffer (160 KB), bzip2's workspace (7.8 MB),
LZMA's probability model (28 KB), LZFSE's (48 KB), LZBITMAP's (about 37 KB), LZRAVEN's (two 19 KB models). Output goes
into the caller's buffer (`decompressAll(_:into:)`), which is also the history, so there is no window and no copy. The
benchmark gate for each is a zero-malloc threshold.<!-- src: Bytes/Benchmarks/RESULTS.md "Allocations" (Zstd 160 KB); RESULTS-bzip2.md API; RESULTS.md LZMA section; RESULTS-lz4-lzfse.md "Allocations"; RESULTS-lzbitmap.md "The decoder"; RESULTS-lzraven.md API -->

In crypto, scrypt takes a scratch buffer whose size the caller can ask for (`Scrypt.scratchByteCount`) and allocates nothing;
HKDF's `Expander` keys the HMAC once and expands any number of times; and the P-256/P-384, RSA, HPKE, and X.509 paths
allocate nothing where CryptoKit allocates 2–3 times per ECDSA or ECDH call, 150 times per HPKE context, and Security 14
times per RSA verification.<!-- src: Bytes/Benchmarks/RESULTS-scrypt-x509.md "scrypt"; RESULTS.md "Crypto cleanup" HKDF bullet; RESULTS-ecc.md "Results"; RESULTS-rsa.md "Results" -->

Tables in a workspace also solve a copying problem. An `InlineArray<256, Int16>` passed `borrowing` was copied (512 bytes,
a `memmove`) at every subscript in the Zstandard decoder's FSE spreading loop: 16,000 copies per 4 KB frame, 22% of its
time. Hot tables go in raw memory the decoder owns, indexed through a pointer, with the safety argument in a comment:
18–35% fewer instructions on small inputs, and 10–24% faster than libzstd there. The same trap cost a DEFLATE block writer
a 1.4 KB copy per literal (level 1 on the Silesia file x-ray: 153 ms, against 55 ms once fixed): take `.span` once and index that.<!-- src: AGENTS.md "InlineArray passed borrowing can be copied at every subscript"; OPTIMIZATION-old.md "Compression: DEFLATE and Brotli" item 1; Bytes/Benchmarks/RESULTS.md "Bugs found, and compiler issues" item (4); Bytes/Benchmarks/RESULTS.md "Zstandard decoding ... How it got there" -->

#### Technique 2: build arrays the cheap way

`[UInt8](capacity:initializingWith:)` and `init(unsafeUninitializedCapacity:initializingWith:)` allocate through a function
that is not specialized for the element type: about 500 instructions and 27 ns more per array than `reserveCapacity`
followed by `append(addingCapacity:)`, at 40 bytes and at 1 KB alike. Bytes' array builder switched and made 1,000
38-byte arrays with 27.6% fewer instructions. For small arrays in hot code, use
the latter, or `Array(UnsafeRawBufferPointer)`.<!-- src: AGENTS.md "The standard library's [UInt8](capacity:initializingWith:)"; OPTIMIZATION-old.md "11." "Building arrays" -->

`min(a, b, c, …)` with three or more arguments is the variadic overload, which builds an array (a stack object and a
release in a hot function, or an allocation in Brotli's literal loop): nest two-argument `min`s.<!-- src: OPTIMIZATION-old.md section 12 table "min(a, b, c, …)"; RESULTS-lzbitmap.md Lessons -->

#### Technique 3: closures that capture do not box if they are literals

A local `func` passed as a closure boxed its captured `crc` and `written` variables on the heap: 2 mallocs per entry in
NativeZip's extraction. Closure literals keep them on the stack. After the fix, inflating 2,000 small files went from
4,001 mallocs to 1 (the harness's own); times were unchanged, because allocation was never the bottleneck there, but it
is provably absent.<!-- src: NativeZipArchive/Benchmarks/RESULTS.md "step4" -->
The bzip2 decoder's nested function was the same trap ([section 1](#1-keep-hot-state-in-registers)).

#### Technique 4: typed throws without boxing

A `do { } catch` around a typed-throws call boxes the error (`swift_allocError`) unless it is written `do throws(E)`:<!-- src: AGENTS.md "Typed throws: do { } catch around a typed-throws call boxes the error" -->

```swift
// Illustrative: `decode(into:)` stands for any call that throws(BytesError).
do throws(BytesError) {          // the error stays an unboxed enum
    try block.decode(into: &output)
} catch {                        // `error` is a BytesError here
    …
}
```
<!-- src: AGENTS.md same (example schematic) -->

With this form, LZ4/LZFSE/LZVN's block decode stopped allocating its error; NativeAEA's header parsing went from
66 K to 63 K instructions per 170 headers with no `swift_allocError`.<!-- src: Bytes/Benchmarks/RESULTS-lz4-lzfse.md "Code generation"; NativeAEA/RESULTS.md "Opening" bullet -->
(A typed-throws trap that is not about allocation: never pass a `throws(E)` closure to an untyped generic `rethrows` API
such as `Array.withUnsafeMutableBytes`; Swift 6.4.2 throws the wrong error silently. See Part IV, ["Limitations and
compiler bugs met in concurrency and nearby"](#5-limitations-and-compiler-bugs-met-in-concurrency-and-nearby).)<!-- src: AGENTS.md "Never pass a throws(E) closure to an untyped generic rethrows API" -->

#### Technique 5: make rarely used members on first use

NativeZip's decoder held a 256 KB staging buffer and a streaming DEFLATE decoder for encrypted entries, made with every
decoder: one per core when verifying, so verification allocated 46% more. As `Optional`s made on the first encrypted
entry, it was back to within 5% of before. In NativeAEA, a writer's three `decmpfs` encoders (for APFS compression;
1.9 MB zeroed) and a decoder's inflate window (160 KiB) are made on first use: about −35 MB. Mutation works through `x!.mutate()`, but reading
`x!.property` consumes the optional; borrow it with `switch x { case let .some(y): … }` (SE-0432). A benchmark that makes
its decoder inside the measured closure then counts that setup as per-iteration mallocs.<!-- src: OPTIMIZATION-old.md "11." "Make rarely used ~Copyable members on first use"; NativeAEA/RESULTS.md "Encoders and decoders made on first use"; AGENTS.md "~Copyable members made on first use" -->
`Decompressor` ([Part II](#one-decoder-over-every-format-decompressor)) applies the rule to every format: each decoder is made
on its format's first stream, and raw LZMA's and xz's state on the first *streaming* call, so a whole-buffer decode builds
no streaming window.<!-- src: Bytes/Sources/BytesCompression/Decompressor.swift (each format's state "made on its first stream, then kept"); Bytes/Benchmarks/RESULTS.md "Cleanups after the unification (2026-11-22, M1 Max; …)" bullet "Decompressor/DecompressionFormat" ("LZMA and xz state made on the first streaming call (a whole-buffer decode no longer builds two probability models)") -->

#### Technique 6: no lazy globals on the hot path

A `static let` the compiler cannot evaluate at compile time is a lazily initialized global: every use checks a `swift_once`
flag and loads the value. Literal arrays and `InlineArray`s are statically initialized (no `swift_once`); only computed
initializers (`(0..<n).map`, closures) are lazy. The compile-time evaluator cannot fold a byte swap, so Bytes' first
integer-literal initializer for byte groups cost parsing zip records 41% more instructions (281 K against 199 K) with a
`static let signature: Byte4 = 0x50_4B_01_02`; the current initializer reverses bytes with shifts, which fold:<!-- src: OPTIMIZATION-old.md "11." "Write constants as literals"; AGENTS.md "Literal static let arrays and InlineArrays are statically initialized" -->

```swift
// The literal's digits are the bytes in memory order: 50 4B 01 02.
static let signature: Byte4 = 0x50_4B_01_02              // folded into the code: two instructions
static let signature = Byte4(0x504B_0102, .bigEndian)    // byte swap: swift_once on every use
```
<!-- src: OPTIMIZATION-old.md "11." -->

Two cautions. A table that becomes a compile-time constant can make LLVM rematerialize its address in the loop: CRC-32's
literal tables cost 64-byte checksums +10.7% until the inner update was `@inline(never)` (the address opaque again; then
−3.3% against the lazy tables), and CRC-64's literal table lost outright (+1.0%) against
the lazy table, whose `swift_once` check is one load per call. Measure after removing a lazy global. And in a benchmark, a lazy global read in the loop calls `swift_once` →
`dispatch_once_f` (about 36 instructions) on every check for tens of milliseconds after first use, which made Bytes'
3-byte rows bimodal (78 K and 104 K instructions): capture fixtures as locals ([section 13](#13-measuring-honestly)).<!-- src: AGENTS.md "A table that becomes a compile-time constant can make LLVM rematerialize"; Bytes/Benchmarks/RESULTS.md "Cleanup and improvements" "CRC-64's table as a literal" and table row "CRC-32 tables, 64 B"; AGENTS.md "No lazy globals inside a measured loop" -->

#### Technique 7: waits that do not allocate

A `CheckedContinuation` allocates per wait; `UnsafeContinuation` in release builds (checked in debug) does not. For waits
that happen once per file (NativeAEA's writers wait about once per file) this matters. The waits are `Mutex` state plus a
continuation, taken synchronously under the lock when nothing has to wait (see [section 11](#11-techniques-in-the-projects-built-on-bytes) and Part IV, ["NativeAEA: from threads to structured concurrency"](#3-nativeaea-from-threads-to-structured-concurrency)).<!-- src: AGENTS.md "Waits are Mutex state plus a continuation"; NativeAEA/RESULTS.md "UnsafeContinuation in release builds" -->

#### Technique 8: stack buffers, and allocations per entry

`withUnsafeTemporaryAllocation` gives a buffer on the stack when it is small enough (larger requests fall back to the heap);
Bytes uses it for staging shuffles of 64 or 128 values ([section 4](#4-write-simd-by-hand-and-reach-instructions-swift-cannot-name)), well within that.<!-- src: OPTIMIZATION-old.md "9." -->
Per-entry strings are the other source: NativeAEA's verify without `-l` built 1–2 strings per entry (176,000 mallocs),
3,000 once it did not; a `[UInt8]` path per directory (34,781 mallocs) moved into the walker's arena (4,712). Payload
structs with resilient fields (`Date?`) copy through value witnesses (`swift_cvw_initWithCopyImpl` in profiles): jobs that
are queued, sorted, and handed between tasks are cheaper as final classes.<!-- src: NativeAEA/RESULTS.md "Per-entry allocations"; AGENTS.md "Payload structs with resilient fields" -->

#### Technique 9: a `var` pointer borrowed by spans is heap-boxed

NativeAEA's segment decoder had a local `var stored: UnsafeRawBufferPointer`, assigned in an `if` and an `else` and then
borrowed by the `RawSpan`s the checks and the codec take. The compiler gave the variable a heap box: a 32-byte
`swift_allocObject` for every segment (185 of the 189 in the test archive: one per segment, none per file).
The fix is to make each one a constant set exactly once on every path, which needs no box:

```swift
// NativeAEA/SegmentStream.swift, the fixed form: constants, each set once on every path.
let read: UnsafeRawBufferPointer
if let mapping {
    unsafe read = mapping.buffer(segment.fileOffset..<segment.fileOffset + segment.compressedSize)
} else {
    …
    unsafe read = UnsafeRawBufferPointer(destination)
}
let stored: UnsafeRawBufferPointer
if archive.isEncrypted { …; unsafe stored = UnsafeRawBufferPointer(target) } else { unsafe stored = read }
```
<!-- src: NativeAEA/Sources/NativeAEA/SegmentStream.swift lines 304–341 (the code and its comment: "a `var` here, assigned in branches and borrowed by the spans below, was boxed on the heap (one allocation per segment)"); NativeAEA/RESULTS.md "2026-11-22, evening: allocations in an extraction, traced" "What it found" bullet 1 ("A heap box per segment (185 of 189) in `SegmentStream.decode`: a 32-byte `swift_allocObject`") -->

Instruments did not find it: its callers for allocations that are freed again are missing (Part I, ["Allocation
gates"](#53-allocation-gates)). The LLDB breakpoints did, grouped by the first frame in the program's own code. The same
trace found a second per-piece cost in Disk (two arrays for each large file piece whose first compressed chunk starts in the
piece before; the bridge now holds its first part inline), and removing both took the extraction's malloc count from 822
and 815 (two rounds) to 476 (−42%) with instructions unchanged at 401 G and peak memory the same (1,454 to 1,458 MB; M1
Max, the synthetic archive). Static detection works too: `Tools/calls … --callee swift_allocObject` on the hot function lists the box.
The whole process made 7,364 heap allocations; every one over 1 MB is a buffer made once.

The same box was met again in HTTPBytes' QPACK decoder, in the literal field's decode: a name pointer assigned in
branches and borrowed by a span, one allocation per literal field. The zero-malloc gate failed, and as constants set once on
each path, static-table decoding of 401 requests went from 5.2 M to 2.5 M instructions (5,190 K to 2,505 K, −52%).
Section 12 ([the QPACK part](#qpack-share-the-core-let-the-caller-hold-the-blocked-streams)) has the code.<!-- src: HTTPBytes/RESULTS.md QPACK "What moved the numbers" table (static: first version 5,190 K; "The literal step's name as lets set once per path" 2,505 K) and AGENTS.md "HTTPBytes as a whole" ("A var pointer assigned in branches and borrowed by a span is heap-boxed again (QPACK's literal decode: one allocation per field, 5.2 M → 2.5 M instructions as lets)"); HTTPBytes/Sources/HTTP3/QPACKDecoder.swift literal(...) -->
<!-- src: NativeAEA/RESULTS.md "2026-11-22, evening: allocations in an extraction, traced" "What it found" bullet 2 and the table (row "Extract: archived": "822, 815 → 476 (−42%)", "401 G, unchanged", "1,454 → 1,458 MB"; "7,364 heap allocations in the whole process"; "Every allocation over 1 MB is a buffer, made once"); Disk/RESULTS.md "2026-11-22, evening: bridges without allocations"; AGENTS.md "A local `var` pointer assigned in branches and borrowed by spans was heap-boxed" (the `Tools/calls` check) -->

#### When not to

Zero allocation is a gate rather than a goal in itself. Parallel codecs allocate their thread pool's bookkeeping per call
(`concurrentPerform` 11 mallocs on 8 lanes and 27 on 24, a task group 34 and 98); the compression itself allocates
nothing.<!-- src: OPTIMIZATION-old.md "Compression: DEFLATE and Brotli" (thread pools allocate a few dozen small blocks per call); RESULTS.md "Parallel compression: a chunk scheduler" Allocation bullet -->
And the counting itself has a cost: allocation benchmarks are kept separate from timing ones ([section 13](#13-measuring-honestly)).<!-- src: AGENTS.md "The malloc interposer costs ~10%" and "package-benchmark's malloc interposer traps on thread exit" -->

### 7. Branches and data-dependent work

#### What goes wrong

A CPU runs ahead of the instruction it is certain about: it predicts each branch and starts the predicted side. A
mispredict throws away that work, about a pipeline's worth of cycles (Part I, ["Branches, prediction, and mispredicts"](#15-branches-prediction-and-mispredicts)). A
branch on random-looking data is predicted right half the time. Separately, a dependency chain (each step needs the
previous step's result; Part I, ["Latency, throughput, and dependency chains"](#12-latency-throughput-and-dependency-chains)) runs at the latency of one step per link,
however wide the CPU is. The two together decide the speed of entropy decoders (each decoded symbol decides how the next
is read) and cipher rounds. `Tools/counters`' `bottlenecks` mode shows it: the share of cycles *discarded*
(mispredictions), lost in the front end, or stalled in the back end.<!-- src: AGENTS.md "Tools/counters"; Part I section 1 for definitions -->
For these loops, judge by cycles, not instructions.<!-- src: Bytes/Benchmarks/RESULTS-bzip2.md "What worked" first bullet ("judge this pass by cycles"); RESULTS-lz4-lzfse.md Lessons -->

#### The LZMA range coder: a bit from the borrow

LZMA's range decoder decodes one bit at a time: pick a probability, multiply, compare against the code value, select the
next state. The first Swift version followed the C reference's structure and ran at 0.73–0.88x Apple's Compression.
`Tools/counters` showed why: 52% of its cycles were discarded (mispredictions) and 32% lost in the front end, against
Compression's 34% and 8%, with 67% more branches per byte (13.5 against 8.1). LLVM had turned the tree bits' `one ? 1 : 0`
into a branch, so every literal bit was a coin-flip branch.<!-- src: Bytes/Benchmarks/RESULTS.md "LZMA ... How it got there" last paragraph block -->

```swift
// LZMACore.swift (simplified). `code` and `bound` are 32-bit values; subtracted as 64-bit values, the
// difference borrows into its top bit exactly when code < bound, which is a decoded 0.
let difference = UInt64(code) &- UInt64(bound)
symbol = symbol &<< 1 | (Int(truncatingIfNeeded: difference &>> 63) ^ 1)   // append the bit: 1 when code >= bound
```
<!-- src: AGENTS.md "LZMA decoding (the decoder agent)"; Bytes/Sources/BytesCompression/LZMACore.swift step (line 190) and matchedStep (line 269) -->

The steps and their effect, in cycles per output byte on three Apple segments (seg0 / seg60 / seg255), against Compression
at 44.9 / 11.3 / 30.9:<!-- src: Bytes/Benchmarks/RESULTS.md LZMA table -->

| Step | seg0 / seg60 / seg255 cycles per byte |
|---|---|
| First version (the reference's structure) | 60.8 / 13.3 / 36.7 |
| `@inline(always)` on the range decoder's methods | 60.9 / 12.9 / 35.1 |
| Tree bits computed arithmetically, literal loops of 8 | 48.9 / 12.2 / 33.1 |
| Plain literal: both children loaded while the parent decodes | 41.9 / 11.2 / 31.9 |
| Matched literal: both candidates loaded ahead | 40.4 / 10.7 / 28.8 |
| Normalization threshold in a register (`cmp` instead of `lsr` + `cmp`) | 38.3 / 10.4 / 28.4 |
| Normalization deferred into the next bit | 37.6 / 10.3 / 28.0 |
| Children loaded ahead in every tree | 36.7 / 9.4 / 25.8 |
| Literal and matched-literal trees written out | 36.1 / 9.3 / 25.3 |
<!-- src: Bytes/Benchmarks/RESULTS.md LZMA "How it got there" table -->

Instructions *rose* (93.5 to 99.7 per byte on seg0, with a peak of 119.5 along the way) while cycles fell, because the
added instructions took steps off the chain. The chain from one tree bit to the next (pick the probability, multiply,
compare, select) went from about 11 cycles to about 6. The load is off the chain because both children (adjacent
`UInt16`s, one 32-bit load) are loaded while the parent bit decodes; the normalization compare is one `cmp` against a
register; and the normalization shift is chosen alongside it. Normalization stays a branch: it predicts well, and every
branchless form measured 2–10% slower.<!-- src: Bytes/Benchmarks/RESULTS.md LZMA "How it got there" last paragraph; AGENTS.md "The normalization branch predicts well" -->
The final decoder is faster than both references on every input: 1.11–1.29x Compression and 1.22–1.68x liblzma 5.8.4
(about 200 MB/s on Xcode's segments, which were the use case).<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "LZMA decode -6 {dickens, mozilla, samba, x-ray, xml}" and "LZMA decode Apple seg{0, 60, 255}", Bytes against Compression (1.112 seg60 to 1.290 x-ray) and liblzma (1.218 seg60 to 1.683 xml); the 200 MB/s is from Bytes/Benchmarks/RESULTS.md LZMA "Results" and is not in the new run -->

**Two more steps off the chain (2026-11-22, M1 Max).** The table stopped at "children loaded ahead". Two later changes
went further, and both *add* instructions. First, a matched literal (the byte after a match, whose bits are decoded under
the probabilities of the byte at the match's distance) forms the next step's four candidate probability indexes *two bits
ahead*, for both outcomes of the current bit, and selects among them by the decoded bit, so the next step's loads start
one select after the bit rather than a few operations later:

```swift
// LZMACore.swift matchedStep (shortened): candidates for the bit after the next, formed before this bit is decoded.
let index00 = matched0 & offsetAfter0 &+ node
let index01 = matched0 & offsetAfter1 &+ node &+ 1
let index10 = matched1 & offsetAfter0 &+ node &+ 2
let index11 = matched1 & offsetAfter1 &+ node &+ 3
let (one, difference) = step(p)             // decode this bit
p = one ? p1 : p0                           // p0, p1: loaded last step, both candidates
index0 = one ? index10 : index00            // the next step's two candidates, selected by the bit
index1 = one ? index11 : index01
```
<!-- src: Bytes/Sources/BytesCompression/LZMACore.swift `matchedStep` lines 279–309 and its doc comment ("The candidates for the bit after the next are formed for both outcomes of this bit, before it's decoded, and selected by it: their loads, in the next step, then start one select after this bit, off the chain from one bit to the next") -->

Second, in the plain trees the next node is chosen by the comparison (`node = one ? node1 : node0`), which LLVM turns into
`cset` and `bfi`, rather than built from the borrow in `difference` (`mvn` and `extr`): the source comment records 2–4%
fewer cycles on four of the Silesia files and no change on x-ray, with more instructions, and the mechanism is not known.
Together, measured with the agent's driver (cycles per byte from `proc_pid_rusage` around each decode), the two changes cut
1.8–4.1% of the cycles on every file (x-ray 56.74 to 55.10 cycles per byte, −2.9%) while instructions *rose* 5.0–9.8%:

| Row (M1 Max) | Instructions old → new | Time old → new |
|---|---|---|
| LZMA decode -6 x-ray (8.1 MB) | 1.46 → 1.61 G (+9.8%) | 150 → 144 ms (−4.0%), 148 → 144 ms (−2.7%) |
| LZMA decode -6 mozilla (48.8 MB) | 3.71 → 3.94 G (+6.5%) | 451 → 431 ms, 446 → 431 ms |
| LZMA decode -6 samba (20.6 MB) | 974 M → 1.03 G (+5.4%) | 118 → 111 ms, 116 → 113 ms |
| `Decompressor xz -6 dickens: 1 MiB out` | 618 → 649 M (+5.0%) | −6.9% / −5.6% |
<!-- src: Bytes/Benchmarks/RESULTS.md "The second cleanup pass (2026-11-22, late, M1 Max; baselines lend-old → lend-new, pass2-old-{1,2} → pass2-new-{1,2})" bullet "LZMA's matched literal and tree steps" ("−1.8 to −4.1% on every file (x-ray 56.74 → 55.10, −2.9%)") and its `pass2` table (rows "LZMA decode -6 x-ray (8.1 MB)", "mozilla (48.8 MB)", "samba (20.6 MB)", "Decompressor xz -6 dickens: 1 MiB out"; times p50 round 1 / round 2); Bytes/Sources/BytesCompression/LZMACore.swift `treeStep` comment ("2–4% fewer cycles on Silesia's dickens, mozilla, samba, and xml, no change on x-ray, though more instructions (2026-11-22)") -->

Branchless normalization, tried once more in the same pass, cost +4 to +12% on x-ray and was not kept, as before. Against
the references in the same run, x-ray runs 1.26x liblzma's instructions at 0.74x its time (144 against 195 ms), and mozilla
1.09x its instructions at 0.73x its time. The one row that got slower, x-ray streamed with 64 KiB of input per call
(+1.4% and +2.0%), spends more of its time in the careful path near each input's end, which these changes do not speed up.
The lesson is the section's, a step further: *fewer instructions can be slower*, and an instruction count on a range coder
is not the cost, so decide by cycles. The same day's change of NativeZip's xz from Compression's stream to Bytes' decoder
shows it from the other side: 7.6% more instructions, and 29% less time (32 MB text, M1 Max, instructions 1,257 M to 1,352 M,
207 to 148 ms).
<!-- src: Bytes/Benchmarks/RESULTS.md same "second cleanup pass" section: bullet ("Branchless normalization was tried again and cost +4 to +12% on x-ray; not kept"), paragraphs "Against the references in the same run: x-ray now 1.26x liblzma's instructions at 0.74x its time (144 against 195 ms) …; mozilla 1.09x liblzma's instructions, 0.73x its time" and "The one row that got slower, x-ray streamed with 64 KiB of input per call" (table row +1.4 / +2.0%); NativeZipArchive/Benchmarks/RESULTS.md step17 table row "Inflate + CRC 32 MB text: xz" (instructions 1,257 M → 1,352 M, +7.6%; time 207 → 148 ms, −29%; old was Compression's `COMPRESSION_LZMA` stream, new is `XZDecoder`) and the sentence "xz runs more instructions than Compression's liblzma and is still 29% faster" -->

#### Find what the load is waiting on

LZRAVEN (Apple's undocumented codec) decoded mostly-literal data at half the speed of Compression with *fewer*
instructions. `Tools/counters` showed the back end stalled for 34% of cycles, against Compression's 11%. `Tools/profile`
located the stalled instruction (samples pile up just after the instruction waiting on the long chain).

The cause is that a literal is two symbols, and the next literal's first probability distribution depends on the top two
bits of this byte. Taken from the whole stored byte (even `(high << 4 | low) >> 6`, which LLVM does not simplify), each
literal's two symbols were serial with the next literal's, with a store-to-load forwarding on top. Taken from the high
nibble (`previous = high >> 2`), the next literal's first symbol overlaps this one's second. Mozilla's cycles per byte went
from 18.0 to 12.7 (Compression: 12.5); on mostly-literal data (compressed files, x-ray; mozilla's first MB), from 31.6 to
17.6. A context that needs only part of a value should be computed from the part that is ready first.<!-- src: Bytes/Benchmarks/RESULTS-lzraven.md "What changed between lzraven-v1 and lzraven-v2" and Lessons -->
Also from LZRAVEN: the refill branches of its rANS decoder (a form of ANS entropy coding) stay branches. Selects cost
75–90% more instructions and saved no cycles, because the misprediction is off the critical path when eight states
interleave.<!-- src: Bytes/Benchmarks/RESULTS-lzraven.md Lessons "rANS refill branches stay branches" -->

#### Do not branch on what the data decides: more cases

- **LZVN's candidate extension.** "If 3 or 4 bytes already agree, extend only from 4" mispredicted. Extending from the
  third byte unconditionally (it stops at once where the fourth differs) gives the same result and cut dickens' cycles
  13%, with more instructions.<!-- src: Bytes/Benchmarks/RESULTS-lz4-lzfse.md Lessons "Don't branch on how many bytes a hash candidate already matched" -->
- **A ternary between a loaded byte and a constant** (`c ? p[0] : k`) compiled to a branch, which mispredicted on text.
  Load unconditionally and select with a mask.<!-- src: Bytes/Benchmarks/RESULTS-lzbitmap.md Lessons -->
- **A select that picks an index for a load** (`best = wins ? k : 16`, then `table[best]`): LLVM duplicated the load into
  both arms and branched on `wins`, a coin toss on mixed data (26% of cycles discarded). Fold the choice into a reduction,
  or load in both cases and select the value.<!-- src: Bytes/Benchmarks/RESULTS-lzbitmap.md "Lessons for AGENTS.md" (encoder) -->
- **bzip2's bookkeeping.** RUNA/RUNB (run-length symbols) against indices with selects, a link's first 4 entries written
  without testing its length, then 4-wide stores into padded rows: `discarded` in CPU Counters fell from 40% to 12% on
  dickens, with −10% and −4% in the last two steps.<!-- src: Bytes/Benchmarks/RESULTS-bzip2.md "What worked" "Branch-free bookkeeping" -->
- **When the branch is the best form.** LZMA's normalization (above), rANS refill (above), and the second-symbol decode in
  bzip2: two symbols per refill cost +20% instructions and cycles, twice, because LLVM spilled the state.<!-- src: Bytes/Benchmarks/RESULTS-bzip2.md "What didn't" -->
  And a move-to-front list whose first 64 bytes sit in four registers kept the whole state struct in memory and turned the
  selects back into branches: dickens went from 16 to 22 cycles a byte. Measure each.<!-- src: Bytes/Benchmarks/RESULTS-bzip2.md "What didn't" -->

#### Overlap dependent loads: bzip2's inverse BWT

bzip2's final pass undoes the Burrows-Wheeler transform by following a table: each output byte needs the previous byte's
table entry (a dependent load from a 3.6 MB table, about 30 cycles each, one chain). A probe of k random chains through a
900,000-entry table measured 7.6 ns a step for 1 chain, 2.0 for 8, 1.1 for 16, and 0.8 for 24 and 32.

So the walk is cut into segments of about 1 KB at evenly spaced rows (each start marked in the table), and 24 are walked at
once. Each lane writes to its own pages and takes the next segment when its current one meets a mark; afterwards the
segments are copied out in cycle order. Instructions went *up* (lane bookkeeping) and cycles went down: dickens took 46
cycles a byte for one walk, 37 for two (walking from both ends), and 22 for 16 segment lanes. The decoder reaches 164–526
MB/s on the Silesia files against libbzip2's 50–94, 3.2–5.6x faster (2.1–5.6x with the small JSON inputs), with 0 mallocs.<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "BZip2 decode -9 {dickens, mozilla, samba, x-ray, xml, JSON}: Bytes / libbz2" (MB/s = Silesia file bytes over wallClock; ratios 3.245 x-ray to 5.586 xml; 2.122 for JSON 1.6 KB); the cycles a byte are from Bytes/Benchmarks/RESULTS-bzip2.md "What worked" first bullet, design "The walk", and "Final" table -->

Three more bzip2 changes shortened chains. Loading the refill's 8-byte word one symbol ahead took dickens −15%: the refill
address depends on the bits consumed, so a load per symbol sat in the chain from one code's length to the next code's
lookup, about 15 cycles a symbol. Counting bytes inside the symbol loop, instead of in a separate pass over the runs, took
−6% (it overlaps the Huffman chain). And no calls in the hot loop (the careful group out of line) took −4% instructions,
and −10% on JSON 1.6 KB.<!-- src: Bytes/Benchmarks/RESULTS-bzip2.md "What worked" -->

#### Independent chains: ChaCha20 and Poly1305

ChaCha20's quarter-round steps each depend on the one before. Four blocks in `SIMD4<UInt32>` gave four chains, which kept
Apple silicon's vector pipes half busy; eight blocks in `SIMD8<UInt32>` (two registers per word, all 32 registers) took
sealing 1 MB from 1.00 to 1.34 GB/s. For scalar multiply chains, the fix is fewer, wider products: Poly1305 in radix 2⁶⁴
(as in OpenSSL's 64-bit code) uses four 64×64-to-128 products and two 64-bit ones per 16-byte block (56 to 43
instructions), against nine with 44-bit limbs: +12%. Together, 1.00 to 1.52 GB/s.<!-- src: OPTIMIZATION-old.md "ChaCha20-Poly1305: 1.0 → 2.50 GB/s" items 1 and 2; Bytes/Benchmarks/RESULTS.md "ChaCha20-Poly1305 against CryptoKit" (eight blocks 1.00 → 1.34); AGENTS.md "Vector code needs independent chains, not just lanes" -->

**Stitching: use the units that are idle.** After those two changes, the vector pipes were full of ChaCha20 while the
integer multiplier sat idle through the ChaCha20 pass, and then Poly1305's chain of multiplies ran alone. The two are
independent (Poly1305 reads ciphertext; ChaCha20 does not read the tag state), so the CPU can run both at once if the
instructions are interleaved closely enough for its out-of-order window to see them. Each eight-block batch (512 bytes) is
10 double rounds of vector instructions with 3 Poly1305 blocks of scalar work after each, and 2 at the end: 32 blocks per
batch, exactly the batch's size.<!-- src: OPTIMIZATION-old.md "ChaCha20-Poly1305" item 3; Bytes/Benchmarks/RESULTS.md "ChaCha20-Poly1305, stitched" -->

```swift
// Before: two passes. ChaCha20 over the whole message, then Poly1305 over the ciphertext.
ChaCha20.xor(&message, key: key, counter: 1, nonce: nonce)
mac.blocks(message.bytes)

// After, from one batch (512 bytes) up: one pass. Sealing authenticates the batch before the one
// being encrypted, since a batch's ciphertext exists only when its rounds are done.
ChaCha20.seal(&message, key: key, counter: 1, nonce: nonce, mac: &mac)
```
<!-- src: OPTIMIZATION-old.md "ChaCha20-Poly1305" -->

Stitching saves time and leaves instructions almost unchanged: 1 MB is 8.77 M instructions before and 8.64 M after, and the
time falls 40% (691–764 to 419–421 µs, 1.52 to 2.50 GB/s) because the multiplier works during cycles it otherwise waits
through. Instruction counts alone would have called it a failure. The loop is the old 264-instruction double round plus 127
for the Poly1305 blocks.<!-- src: Bytes/Benchmarks/RESULTS.md "ChaCha20-Poly1305, stitched" and "Results, t0 → final" -->
The gain reaches sockets: SocketStream's in-memory TLS protect went from 1,162 to 715 µs (−38%).<!-- src: Bytes/Benchmarks/RESULTS.md "Results, t0 → final" -->
A NEON Poly1305 was not pursued: it would compete with eight-block ChaCha20 for the vector pipes, while the scalar chain
runs in ChaCha20's shadow for free.<!-- src: OPTIMIZATION-old.md "Why Poly1305 isn't in NEON" -->
Against CryptoKit's `ChaChaPoly` (which allocates per call, which dominates short messages), Bytes seals 1 MB in 420 µs
against 1,240 (2.95x).<!-- src: Bytes/Benchmarks/RESULTS.md "crypto in Swift" table -->

#### And the opposite: a chain that should not be vectorized

scrypt with p = 1 is one dependent chain end to end: every Salsa20/8 starts from the previous one's output, and within it
the 32 quarter-round steps form one chain. A `SIMD4<UInt32>` implementation of Salsa20/8's diagonals compiled to clean
`vector128` code (176 instructions per block, no lane moves) and ran 3x slower than 16 scalar words in general registers
(16.5 ms against 49.2 ms for N = 2¹⁴, r = 8). Each vector step is four dependent instructions of 2–3 cycles; the scalar
step is `add` plus `eor ..., ror #k`, two. Threads supply the independent work when p > 1 (4.1x on four lanes).<!-- src: Bytes/Benchmarks/RESULTS-scrypt-x509.md "Salsa20/8: scalar beats vector here" and "Against OpenSSL" -->

#### Short scans mispredict: fewer instructions, more cycles

A scanner that finds each delimiter by a short scan from the previous one (a 16-byte test at a time) runs fewer
instructions than one that classifies 64-byte blocks into masks and walks them with `ctz`, and it is slower. On 401 real
HTTP request heads (580 bytes each; lines of 15 to 40 bytes) the per-line scans ran 2.62 instructions a byte at 0.93
cycles; the block masks 3.18 at 0.62. A short scan's exit lands somewhere different on every line, so the exit branch
mispredicts, and a mispredict costs more cycles than the instructions it saves; the mask walk replaces those exits with a
`ctz` of a value computed without branching (the structural index, [section 7 of Part II](#byteblock-64-bytes-tested-into-one-mask)).<!-- src: HTTPBytes/RESULTS.md "The design, from three prototypes" table (A 2.62 instr/B, 0.93 cycles/B; B 3.18, 0.62) and "A runs fewer instructions and more cycles: its many short scans (header lines are 15–40 bytes) mispredict" -->

The same shape recurred twice more in that parser. Packing a block's mask with `ld4` and shift-right-inserts (5 instructions,
cursed-http's choice) took 5% fewer instructions than four plain loads and pairwise adds, and 5 to 16% more cycles: the
mask is on the walk's critical path, and `ld4` delivers 64 bytes in 2 cycles against 1.33 for four plain loads
(`Tools/cpu-probe insn ld4`) with more latency. And classifying blocks ahead of need, to avoid a branch when a line crosses
a block, cost the heads that end in their first block (38-byte heads 55 → 86 cycles).<!-- src: HTTPBytes/RESULTS.md "ByteBlock stays in byte order (Bytes)" bullet ("5% fewer instructions and 5–16% more cycles"; "ld4 loads 64 bytes in 2 cycles against 1.33 for four plain loads"), and "Tried and not kept" row 1 (tiny 55 → 86) -->
Judge scanning code by `Tools/counters`' discarded-cycles share, not its instruction count; [section 12](#12-case-study-httpbytes)
has the full account.

#### A validity test LLVM turns into a branch

Zstandard's `fast` and `dfast` match finders keep a hash table of earlier positions, and a table entry can be stale: its index
is below the start of the window, so it must not be used. libzstd's candidate check (`ZSTD_match4Found_cmov`) reads a valid
position when the entry is invalid, compares the four bytes at both places, and branches once, on a match, which is rare. The same
test written in Swift, `a == b && valid`, compiled differently: LLVM moved `valid` ahead of the loads, as a branch, to skip them,
and `valid` is exactly what a CPU cannot predict when many entries are outside the window.
Folding the two into one condition, `(a ^ b) | invalid == 0`, was split back into the same branch. What held the order was a branch weight
on the comparison: `unlikely(a == b) && valid`, which compiles to a `csel`, a `cmp`, a `ccmp`, and one branch. (libzstd keeps the
two conditions apart with an empty `asm`.) On the M3 Ultra, cycles against libzstd's before and after (frames identical):<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md "How it got there" step 5 and "Tried and not kept" first bullet; AGENTS.md "LLVM turns `a == b && valid` into a branch on `valid` ahead of the loads (also from `(a ^ b) | invalid == 0`)"; Bytes/Sources/BytesCompression/ZstdMatchFinder.swift `found` (the comment on `unlikely` and "libzstd keeps them apart with an empty asm") -->

| Input, level | before | after |
|---|---|---|
| dickens 64 KB, level 1 | +30.8% | −0.9% |
| Main.js 64 KB, level 1 | +24.0% | −1.5% |
| dickens 64 KB, level 2 | +18.6% | +1.2% |
| mozilla, level 3, HTTP window | +17.8% | +1.6% |
<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md "How it got there" step 5 effect column (dickens 64 KB L1 +30.8% → −0.9%, Main.js 64 KB L1 +24.0% → −1.5%, dickens 64 KB L2 +18.6% → +1.2%, mozilla L3 w19 +17.8% → +1.6%) -->

Validity is unpredictable where many table entries are outside the window: small adjusted windows (libzstd shrinks the window and
tables to a known content size) and the HTTP window on large files. The rule is the section's first one again: a branch on data the CPU cannot predict costs more than the loads it skips, and the compiler cannot know
which of your conditions is the unpredictable one. Say so with `unlikely` on the other, then read the assembly.

#### CRC braids and folds

Fewer instructions could not shorten the table CRC's chain (slicing-by-8: each lookup feeds the next), but more chains
could. zlib's braided CRC runs five independent CRCs and combines them at the end, which made the loop bound by loads
instead of latency, 3.6x faster at 256 KB. It is what CPUs without `pmull` use: 8.3x slower than folding, down from 30x.
The hardware version's eight independent 16-byte accumulators overlap the multiplies' latencies the same way. Part II
(["CRC-32: three implementations"](#crc-32-three-implementations)) describes all three.<!-- src: OPTIMIZATION-old.md "CRC-32: 1.7–2.3x zlib" second and third bullets -->

#### When not to

Do not remove a branch that predicts well (LZMA's normalization). Do not vectorize a single dependent chain (Salsa20/8).
Do not add instructions to a chain you have not identified as the critical one. To find it, use `Tools/counters` (where
the cycles went) and `Tools/profile --keep` with the samples mapped to addresses.<!-- src: Bytes/Benchmarks/RESULTS-lzraven.md Lessons "Finding the stalled instruction" -->

### 8. Algorithms and data structures, codec by codec

The earlier sections are general; this one covers what each codec needed that was specific to its format. Times are p50 on
the M3 Ultra from the cited baselines; "libdeflate", "zlib", "libzstd", and so on are the reference libraries run in the
same benchmark process.

#### DEFLATE (RFC 1951) and gzip/zlib

**Decoder.** Built on `BitBuffer`, `HuffmanTable`, and `AlignedBytesWriter`, with zero allocations; inflating Main.js
(3.8 MB) takes 1,935 µs against libdeflate's 1,735 and zlib's 2,183 (Apple's Compression: 3,551). In order of payoff:<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "Inflate Main.js (3.8 MB): Bytes / libdeflate / zlib / Apple Compression" 1,935,359 / 1,734,655 / 2,183,167 / 3,551,231 ns; OPTIMIZATION-old.md "DEFLATE: from 2x slower than zlib to faster" -->

1. Inlining and small functions with local state (sections [1](#1-keep-hot-state-in-registers) and [5](#5-inlining-and-specialization)).
2. **A register-only refill.** The slow refill, used near the end of the input, took the buffer's fields `inout`, which
   kept them in memory on the fast path too; it takes and returns values instead. The fast path is loop-free: while 8
   bytes remain, one unaligned 8-byte load and three arithmetic steps, with no branch on how many bytes fit:<!-- src: OPTIMIZATION-old.md DEFLATE item 2 -->

   ```swift
   _bits |= UInt64(littleEndian: raw) &<< shift      // raw: the next 8 bytes; shift: bits already held
   _nextByte &+= (63 &- _count) &>> 3                // advance by the whole bytes that fit
   _count |= 56                                      // now 56–63 valid bits
   ```
   <!-- src: OPTIMIZATION-old.md DEFLATE item 2 -->

   Past the end of the input the buffer fills with zeros, and the overrun is reported once per block instead of checked on
   every read.<!-- src: OPTIMIZATION-old.md same -->
3. **A faster table builder** (libdeflate's): a short code fills many table slots with the same entry, so each entry is
   written once, then doubled with `memcpy`. Table building had been 11% of the time for small files.<!-- src: OPTIMIZATION-old.md DEFLATE item 3 -->
4. **A shorter critical path.** The next symbol's table entry is looked up before the current one is used, so the
   lookup's latency overlaps the work.<!-- src: OPTIMIZATION-old.md DEFLATE item 4 -->
5. **Copies that may overrun.** Back-references copy 16 bytes at a time and may write up to 32 bytes past their end; this
   loop runs only while 32 spare bytes remain in the output. Back-references at distances under 8 overlap their own
   output; they become a run of the last `distance` bytes (one load, then 16-byte stores, as libdeflate does), in a
   separate static function ([section 5](#5-inlining-and-specialization)).<!-- src: OPTIMIZATION-old.md DEFLATE item 5; Bytes/Benchmarks/RESULTS.md "Follow-ups: short-distance back-references"; AGENTS.md "Rare paths stay out of line" -->
6. **Named fields in the table entries.** The decode loop went from 246 to 236 instructions, and NativeZip's inflate plus
   CRC ran 2.5–2.8% fewer instructions.<!-- src: OPTIMIZATION-old.md DEFLATE item 6 -->
7. **A fast loop on locals, bounded once per round** (2026-11-22, M1 Max). libdeflate's decode loop, rewritten in Swift:
   the input and output positions and the bit buffer in locals, unchecked refills, stores, and its own match copy, table
   entries whose flags decide with one `tbnz`, and every bound proven once per round in the comments instead of checked
   per symbol ([Part III, section 2](#a-limit-per-round-instead-of-a-check-per-symbol) has the technique). It cut instructions
   by 36–40% on the Silesia files (dickens 129 M to 78 M), below libdeflate's, but time by only 5–9%.<!-- src: Bytes/Benchmarks/RESULTS.md "Cleanups after the unification (2026-11-22, M1 Max; …)" table row "Inflate dickens / samba / x-ray / xml" (−35.8 to −39.5%; time "dickens 11.0 → 11.0 ms; others −5 to −9%") -->

**Deflate64 and decoding into the caller's buffers.** `DeflateDecoder(variant: .deflate64)` decodes PKWARE's Deflate64
(zip method 9): a 64 KB window, length symbol 285 as base 3 with 16 extra bits (matches of 3 to 65,538 bytes, where
DEFLATE's 285 is exactly 258), and distance codes 30 and 31 with 14 extra bits each. It is the same decoder with its own
`@inline(never)` copy of the symbol loop over one `@inline(__always)` body taking a constant `deflate64`, so DEFLATE's loop
does not carry the longer matches' extra refill and room check (and no `merged` function folded the copies back:
[section 5](#5-inlining-and-specialization)). Deflate64 rows run within 0.2% of DEFLATE's instructions on the same inputs
(the first measurement: 188 M against 187 M on x-ray, 1,971 K against 1,970 K on Main.css), and after the fast loop of item 7
both fell together (120 M and 1,230 K).
<!-- src: Bytes/Benchmarks/RESULTS.md "Streaming decoders for NativeZip (2026-11-22, M1 Max; …)" first bullet (DeflateVariant, "its own `@inline(never)` copy of the symbol loop over one `@inline(__always)` body (no `merged` function)") and table row "Inflate64 x-ray, Main.css (new)" ("188 M, 1,971 K … within 0.2% of Inflate"; Inflate x-ray 187 M, Main.css 1,970 K); "Cleanups after the unification" table row "Inflate64 Main.css, x-ray" (1,970 K, 188 M → 1,230 K, 120 M); Bytes/Sources/BytesCompression/Deflate.swift `DeflateVariant` doc comment -->
A caveat about the NativeZip benchmark of it: its Deflate64 fixture is `text.zip`'s DEFLATE stream marked method 9, which has
no 258-byte match, so it decodes the same either way and proves the method's plumbing, not its long matches.
<!-- src: NativeZipArchive/Benchmarks/RESULTS.md step17 ("the Deflate64 fixture is `text.zip`'s DEFLATE stream marked method 9: it has no 258-byte match, so it decodes the same either way") -->

`decompress(_:into:historyCount:)` decodes after `historyCount` bytes of history in the *caller's* buffer: the decoder keeps
no window of its own, and the caller moves the last window's worth of output to the front of the next buffer between calls
(Part II, ["One shot, streaming, and parallel"](#one-shot-streaming-and-parallel)). NativeZip decodes an entry into two 1 MB
buffers this way (a large entry writes one while the other is decoded into), with no copy out of a window.
<!-- src: NativeZipArchive/Benchmarks/RESULTS.md step17 first bullet ("`DeflateDecoder(variant:)` and its new `decompress(_:into:historyCount:)`, which decodes straight into ZipDecoder's two buffers after the history copied to their front") -->


*Truncated input looks like data.* A bit reader's zeros past the end can decode as a valid but wrong symbol: DEFLATE's
code-length code 16 at index 0 ("repeat the previous length") threw `invalidValue` when the input ended 8 bytes into a
dynamic header. When a decoder rejects a value, check `isOverrun` and ask for more input instead. The way to find such bugs
is to record a stream's calls and replay them cut at every point.<!-- src: AGENTS.md "Truncated input looks like data" -->

**Encoder.** It follows libdeflate's levels (a 2-entry hash table at level 1, hash chains above, lazy parsing from level 5,
block splitting from statistics). Level 1's output is the same size as libdeflate's. Level 1 on Main.js runs 8,954 µs
against libdeflate's 8,241 and zlib's 16,600; level 9 runs 56,200 against 58,900 and 80,900.<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "Deflate 1 Main.js (3.8 MB): Bytes / libdeflate / zlib" 8,953,855 / 8,241,151 / 16,637,951 ns and "Deflate 9 Main.js (3.8 MB): Bytes / libdeflate / zlib" 56,197,119 / 58,916,863 / 80,871,423; OPTIMIZATION-old.md "Compression: DEFLATE and Brotli, both directions" table and prose -->
Level 1 also has an inner loop without the per-position checks, used where they always pass (a full-length match fits
before the data's end and no rebase is due). It takes the same steps and so writes the same output: instructions −17.8%
(135 to 111 M on Main.js), −12.7 to −18.8% across the corpus, and −12.5 to −17.0% per lane in parallel level 1.<!-- src: Bytes/Benchmarks/RESULTS.md "Cleanup and improvements" table; Bytes/Sources/BytesCompression/DeflateCompressor.swift parseFastest -->
Two bugs belong here because they show only as size:

- **A boundary check must be `>=`.** DEFLATE's tables hold 16-bit positions relative to a base that moves forward when a
  position reaches 32 KB past it. The check was `==`. Positions that are never inserted (a flush's last few bytes) can step
  over the boundary, and from then on no position equals it: entries wrap, no match is found, and the output stays correct
  (matches are verified), only bigger. A socket stream went from 14% to 62% of its size after 26 MB. Tests compare long
  streams with flushes against one-shot output size.<!-- src: OPTIMIZATION-old.md "Compression" final paragraphs; AGENTS.md "Compression bugs often show only as size" -->
- **A copy stops at the data's end, not the buffer's.** Brotli's lazy matching computed the longest allowed copy once at
  the first position, and each delayed search took one less; after two delays a copy could run a byte past the data. Alone,
  that was an unchecked read past the input; in a parallel chunk it read the next chunk's first byte, which matched, and
  the stream decoded one byte long. Each search computes its own limit, and a test builds the input that forces two delays
  at a chunk's end, since random and text inputs never reached it.<!-- src: OPTIMIZATION-old.md "Compression" last paragraph; AGENTS.md "Copies stop at the data's end, not the buffer's" -->

*Stale entries after a reset* (in the Brotli encoder). State reused across streams keeps a hash table by moving a position
base, so every old entry is out of range but still scanned. Check the newest entry first (if it is out, all are): a 1.6 KB
stream went from 24 to 18 µs in a harness.
Breaking out of the scan loop at the first dead entry cost large inputs 3–5%, because a second exit changes how the loop
compiles.<!-- src: OPTIMIZATION-old.md "Compression" item 6; AGENTS.md "Reused state carries stale entries"; Bytes/Benchmarks/RESULTS.md "The Brotli encoder's adaptive tag filter" "Stale buckets" -->

#### Brotli (RFC 7932)

Brotli adds a static dictionary, context modeling, and several encoder quality levels. Results (one run): quality 1 on
x-ray, 22,000 µs against Google's 28,000; quality 5 on Main.js, 35,000 against 32,000; quality 9 on dickens, 330,000
against 545,000; decoding quality-11 streams of Main.js, 3,912 against Google's 3,836 and Apple's 3,875. Output is within
3–6% of Google's size at quality 5 (7% at 9, without context modeling).<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "Brotli encode q1 x-ray (8.1 MB): Bytes / Google" 22,315,007 / 28,114,943 ns, "Brotli encode q5 Main.js (3.8 MB)" 34,537,471 / 32,145,407, "Brotli encode q9 dickens (9.7 MB)" 330,301,439 / 544,735,231, "Brotli decode q11 Main.js (3.8 MB): Bytes / Google / Apple Compression" 3,911,679 / 3,835,903 / 3,874,815; the output sizes are from OPTIMIZATION-old.md Compression table and prose -->

- **Decoder state in locals.** Brotli's bit buffer was passed `inout` to a function that was not inlined, so it lived in
  memory for the whole decode loop (and its bit order was tested at run time). Copied into locals, passed by value, and
  stored back once, it made decoding 20–42% faster on every input, 1.6 KB streams the most.<!-- src: AGENTS.md "Hot decode loops keep their state in locals" -->
- **Decoder fast loop.** A fast loop runs while 128 bytes of input remain, split from the careful loop: Brotli's decode got
  10–30% faster ([section 5](#5-inlining-and-specialization)).
- **The adaptive tag filter.** Google's newer hashers keep 8 more bits of each bucket entry's hash (a *tag*) and compare 16
  tags at once, loading only entries whose tag matches. On x-ray this is 35% faster. On text it is 17–30% slower: most
  candidates match there, so the tags are one more load and a branchy loop in front of loads the plain scan issues anyway,
  in parallel.

  Neither the share of bytes copied nor the average match length predicted which path wins (x-ray copies 60–78%; a
  database file averaging 13-byte matches still preferred tags). What predicted it was what the tags *save*: the bucket
  entries they rule out, 3–6 of 16 for text and 10–14 for binaries. The encoder counts them (every search with tags, every
  32nd without) and picks the next meta-block's mode: within 2% of the faster path on every file tried. Storing the tags
  is not free (about 5% on its own).<!-- src: OPTIMIZATION-old.md "Compression" item 4; AGENTS.md "Pick an adaptive path by what the optimization saves" -->
- **Quality 1: do less of what the format does not reward.** Inserting every position of every copy into the table was
  replaced by inserting each copy's last 5: at most 4% in size, 10–22% of the time. A 6-byte hash and minimum match
  instead of 4 took x-ray from 55 to 21 ms (faster than Google's) and made every file smaller.<!-- src: OPTIMIZATION-old.md "Compression" item 8 -->
- **`ShouldCompress`.** Google's check stores a meta-block of almost only literals (over 99%) whose sampled literals carry
  more than 7.92 bits each, without counting them and building codes. Encoding 1 MB of random data at quality 5 went from
  37 to 31 M instructions (−16%). A cheaper last-distance check, four bytes at once, gave −24% on random input but +1.1 to
  +2.0% on text and binary corpora at quality 5 and +6–8% at quality 9, so it was not kept.<!-- src: Bytes/Benchmarks/RESULTS.md "Cleanup and improvements" Brotli rows and "Tried and reverted"; Bytes/Sources/BytesCompression/BrotliEncoder.swift shouldCompress -->

#### Zstandard (RFC 8878)

`ZstdDecoder` decodes every frame and block form: raw, RLE, and compressed blocks; Huffman literals with one or four
streams and single- or double-symbol tables; predefined, RLE, FSE, and repeat sequence tables; skippable and concatenated
frames; and XXH64 content checksums, verified. In one call (`decompressAll`) the output is the history, so there is no
window and no copy.<!-- src: OPTIMIZATION-old.md "Zstandard: faster than libzstd" first paragraph -->
Against libzstd 1.5.7 with a reused context, on one thread (baseline `m3-final`, an idle machine; instructions per byte are exact):<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final) -->

| Silesia file, level | Bytes MB/s | libzstd MB/s | Speed-up | Bytes / libzstd instr per byte |
|---|---|---|---|---|
| dickens, 3 | 1,606 | 1,164 | 1.38x | 13.45 / 14.90 |
| mozilla, 1 | 1,706 | 1,372 | 1.24x | 8.47 / 9.40 |
| x-ray, 1 | 1,496 | 1,327 | 1.13x | 7.84 / 10.02 |
| xml, 19 | 3,872 | 3,150 | 1.23x | 4.09 / 4.50 |
<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "Zstd decode L3 dickens (9.7 MB)", "L1 mozilla (48.8 MB)", "L1 x-ray (8.1 MB)", "L19 xml (5.1 MB)", Bytes against libzstd; MB/s = Silesia file bytes (10,192,446; 51,220,480; 8,474,240; 5,345,280) over wallClock; instructions over the same bytes (rows selected, as in OPTIMIZATION-old.md Zstd table) -->

Every Silesia file at levels 1, 3, and 19 is faster, 1.13–1.50x in one call, with 8–22% fewer instructions per byte; all 20
small inputs in the suite (1–64 KB) are faster, 1.02–1.42x.<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "Zstd decode L{1,3,19} {dickens, mozilla, samba, x-ray, xml}: Bytes / libzstd" (1.127 x-ray L1 to 1.503 x-ray L19; instructions 0.782 to 0.918) and the 20 rows "Zstd decode L3 … 1/4/16/64 KB", "L19 … 4 KB" (1.022 to 1.420) -->
The first complete version followed libzstd's loops: a four-stream Huffman loop with sentinel bits, sequences executed one
at a time with 16- and 32-byte wild copies (copies allowed to write past their end), and the careful path out of line. It
was already 5–28% faster on large inputs but 1–24% slower on 1–4 KB ones.

What closed the rest, each a technique from an earlier section: tables in a workspace instead of `InlineArray`s ([section
6](#6-allocation-free-code)), a cold reload as a static function ([section 1](#1-keep-hot-state-in-registers)), one base pointer for the FSE states (section 1), and double-symbol
Huffman tables chosen by a measured rule. libzstd's own cost model picked double-symbol tables for x-ray's literals, where
they cost 6%; the rule used here (literals compressing below 10/16, at least 8 KB of them) gave dickens −8% and moved
nothing else by more than 0.1%. Prefetching each match's source (as libzstd does on AArch64) added 0.7% instructions and
no speed in an interleaved comparison, so it was removed. (The encoder, below, found libzstd's prefetches worth keeping.)<!-- src: Bytes/Benchmarks/RESULTS.md "Zstandard decoding ... How it got there" and "Kept out" tables -->

#### Zstandard encoding

`ZstdEncoder` encodes Zstandard frames at libzstd 1.5.7's levels 1 through 4: its `fast` strategy (levels 1 and 2) and `dfast`
(double-fast, levels 3 and 4: two hash tables, one for short matches and one for long ones), its block pre-splitter,
and its entropy decisions, **ported decision for decision**. With the same parameters a frame from `compressAll` is libzstd's
frame byte for byte: on all 12 Silesia files and 5 web files at levels 1 to 4 and at level 3 with the HTTP window, on 1 to 64 KB
bodies, at block boundaries, and with and without checksums. The numbers in this subsection are from the M1 Max, measured
while other agents were building (load average 8 to 13): cycles and instructions are the numbers to trust, wall times are
not.<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md header ("2026-11-23, M1 Max … load average 8–13: cycles and instructions are the numbers to trust, wall times are under load") and "What it is" (levels 1–4, fast and dfast, block pre-splitter, entropy decisions, ported decision for decision; "libzstd's frame, byte for byte: every Silesia file, the web assets, 1–64 KB bodies, block boundaries, and the decoder tests' samples, at every level, with and without checksums"); Bytes/Benchmarks/RESULTS.md "2026-11-23, Zstandard encoding" (the whole corpus); Bytes/Sources/BytesCompression/ZstdMatchFinder.swift (dfast's `longMatch` and `shortCandidate` lookups) -->

```swift
var encoder = ZstdEncoder(level: 3, windowLog: ZstdEncoder.Parameters.httpWindowLog, checksum: false)
try encoder.compressAll(body, into: &output)            // one frame, content size stated
encoder.reset()                                         // or reset(contentSize:) to state it when streaming
let progress = try encoder.compress(chunk, into: &output, flush: .none)   // .flush ends a block, .finish the frame
```
<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md "What it is" code block; Bytes/Sources/BytesCompression/ZstdEncoder.swift `init(level:windowLog:checksum:)`, `compressAll`, `reset(contentSize:)`, `compress(_:into:flush:)`; Transforms.swift `ZstdEncoder: ByteTransform, ResettableByteTransform` -->

**Why port rather than design.** An encoder's output is not unique, and a round trip passes for any valid frame, so a
round-trip test cannot tell a good encoder from a poor one: compression bugs show only as size, which a match finder that
loses matches (but verifies the ones it finds) hides completely. Porting libzstd's decisions one at a time (match finder, block
splitter, literal and sequence table selection, repeat offsets, raw and RLE blocks) turns libzstd's output into the oracle: the
test compares whole frames, and every slip shows at its first differing byte. They did: a limit on repeat offsets, and libzstd's
check for an RLE block on blocks it stores raw. One thing the comparison taught that no reading of the format would have: libzstd
shrinks the window and tables to a known content size even when every parameter is set (`ZSTD_adjustCParams_internal`), so a port
must too, or its frames differ for every small input. The comparison gives libzstd `ZSTD_c_strategy`, `windowLog`, `hashLog`,
`chainLog`, `searchLog` (1), `minMatch`, and `targetLength` (and the checksum flag) one by one, so it does not depend on
libzstd's tables for small inputs.<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md "Method" first bullet (the parameters passed one by one; "libzstd still shrinks the window and tables to a known content size; so does ZstdEncoder"); AGENTS.md "Port a reference encoder decision for decision, and its frames become the test oracle … found each porting slip at its first differing byte (a repeat-offset limit, libzstd's RLE check on blocks it stores raw). libzstd shrinks the window and tables to a known content size even with every parameter set (ZSTD_adjustCParams_internal): a port must too"; Bytes/Sources/BytesCompression/ZstdEncoder.swift `Parameters.adjusted(forContentSize:)` -->
Streamed frames are the exception, and a deliberate one: libzstd's circular input buffer turns the window's older part into an
external dictionary searched by separate match finders, and this encoder slides a flat window (the window plus a block, moved once
per block when full). Its streamed frames are within 0.1% of the one-shot frame and 0 to 0.9% smaller than libzstd's streamed ones
(dickens: 3,699,098 bytes against 3,708,272). A body sent at once with `.finish`, or after `reset(contentSize:)`, is the one-shot
frame.<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md "Streamed in 64 KB pieces" table (dickens 3,699,098 against 3,708,272) and the paragraph after it ("Streamed frames aren't libzstd's … within 0.1% of the one-shot frame and 0–0.9% smaller than libzstd's streamed ones … Bodies sent at once with `.finish` (or after `reset(contentSize:)`) are the one-shot frame") -->

**Results against libzstd** (cycles and instructions per input byte, least of 5 interleaved rounds, both contexts reused; frames
identical, so the ratios are libzstd's):

| Input | Level | Cycles/B Bytes | libzstd | Δ | Instr/B Bytes | libzstd | Δ |
|---|---|---|---|---|---|---|---|
| dickens | 1 | 7.990 | 7.581 | +5.4% | 34.83 | 31.29 | +11.3% |
| dickens | 3 | 14.173 | 13.754 | +3.0% | 37.23 | 34.11 | +9.2% |
| mozilla | 1 | 5.679 | 5.458 | +4.0% | 25.14 | 22.83 | +10.1% |
| mozilla | 3 | 8.409 | 8.253 | +1.9% | 30.77 | 28.57 | +7.7% |
| x-ray | 1 | 4.414 | 4.500 | −1.9% | 15.44 | 17.92 | −13.8% |
| x-ray | 3 | 15.624 | 15.178 | +2.9% | 60.55 | 55.70 | +8.7% |
| Main.js | 3 | 7.639 | 7.458 | +2.4% | 21.73 | 20.02 | +8.6% |
| xml, 1 KB body | 1 | 10.58 | 12.22 | −13.4% | | | −14.0% |
| dickens, 4 KB body | 3 | 9.99 | 9.96 | +0.4% | | | +6.9% |
| dickens, 64 KB body | 3 | 12.51 | 12.16 | +2.9% | | | +8.8% |
<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md "Corpus files, one call" table (rows dickens 1 and 3, mozilla 1 and 3, x-ray 1 and 3, Main.js 3) and "HTTP bodies, one call" table (rows xml 1 KB level 1, dickens 4 KB level 3, dickens 64 KB level 3; the instruction columns of those rows are given as a difference only) -->

Over every one-call row the cycles are −14% to +5.4% of libzstd's, within ±3% on most; instructions are 7.5 to 11% higher on large
inputs (x-ray at level 1 the exception, −14%). Below about 2 KB the per-frame work dominates and this encoder is 8 to 14% cheaper:
libzstd re-checks and resets its context's parameters on every `ZSTD_compress2`. Streamed in 64 KB pieces with the size unknown, cycles
are 4 to 10% below libzstd's (dickens −4.3%, mozilla −9.9%, x-ray −9.2%). The row where the encoder is clearly behind is incompressible
input: 1 MB of random bytes at level 3 takes 1,961,000 instructions against libzstd's 1,622,000 (+21%) and 140 µs against 122 (+15%,
under load), because every block is stored raw and copied into a staging buffer and then out, where libzstd copies once into the
destination. Writing blocks straight into the caller's buffer is not done.<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md "Targets" (−14% to +5.4%; instructions +7.5 to +11%), "HTTP bodies" paragraph ("Below about 2 KB the per-frame work dominates, and ours is 8–14% cheaper (libzstd re-checks and resets its context's parameters on every ZSTD_compress2)"), "Streamed" table (dickens −4.3%, mozilla −9.9%, x-ray −9.2%; "−4 to −10%" in Bytes/Benchmarks/RESULTS.md), "In the suite" row "L3 random (1.0 MB): raw blocks" and the paragraph after ("+21% instructions, +15% time"), "Not done" (writing blocks straight into the caller's buffer) -->

**How it got there** (harness; cycles per byte against libzstd's, load 10 to 13):

| Step | Change | Effect |
|---|---|---|
| 1 | The port: libzstd's loops and decisions | Frames identical; cycles +8 to +30% at level 1, +4 to +21% at level 3; 64 KB bodies +18 to +31% |
| 2 | Sequence-code histograms with four interleaved count tables above 1,500 codes, not one | dickens level 3: 15.55 → 14.49 c/B (+10.4% → +3.6%) |
| 3 | libzstd's prefetches | mozilla level 1 +19.9% → +12.1%, dickens level 1 +15.3% → +12.8% |
| 4 | Huffman codes stored top-aligned, added with one shift and one OR; groups per flush, alternate groups in a second container | x-ray level 1 5.95 → 4.43 c/B (+31% → −2%); dickens level 1 +12.8% → +5.1% |
| 5 | Candidate validity checked after the comparison ([section 7](#a-validity-test-llvm-turns-into-a-branch)) | dickens 64 KB level 1 +30.8% → −0.9%; others in section 7's table |
| 6 | dfast's sequence store left in its `inout` parameter | one hash constant no longer rematerialized per position; the loop 61 → 49 instructions with step 5 (libzstd's: 45) |
<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md "How it got there" table (steps 1 to 6, condensed) -->

Step 2 is the dependency-chain lesson of [section 7](#7-branches-and-data-dependent-work) in a histogram. Counting bytes into one table, a run of one
code makes each increment wait for the last (the load, add, and store of one counter, repeated); libzstd's
`HIST_countFast_wksp` counts bytes in turn into four tables and adds them at the end. Above 1,500 symbols the encoder does the same
(`ZstdHistogram.countBytes`), and the histograms fell from 8.4% of dickens' level 3 profile to under 3%.<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md step 2 ("a run of one code made each increment wait for the last"; "Histograms 8.4% → under 3% of dickens' level 3 profile"); Bytes/Sources/BytesCompression/ZstdEncoderEntropy.swift `ZstdHistogram.countBytes` (`guard count >= 1500`, four 256-entry tables in `scratch`) -->

Step 3, **prefetching**, finally paid, in the one place where the decoder's did not (the decoder's, 0.7% more instructions and no speed,
was removed): the match search skips ahead by a growing step, faster than the hardware prefetcher follows, so libzstd asks for the
cache line ahead of the search (`ip1 + 64` and `ip1 + 128` when the step grows, and `ip + 256` at each dfast position in its AArch64
build). The compiler's own prefetch builtin is reachable in a module with the Builtin feature, and emits `prfm`:

```swift
// BytesCompression's ZstdMatchFinder: an address computed, not accessed (a prefetch never faults, even past the buffer).
@inline(__always)
func prefetch(_ position: Int) {
    let address = unsafe source + position
    Builtin.int_prefetch_RawPointer(address._rawValue, Int32(0)._value, Int32(3)._value, Int32(1)._value)   // read, locality 3, data cache
}
```
<!-- src: Bytes/Sources/BytesCompression/ZstdMatchFinder.swift `prefetch(_:)` (lines 54–61; the trailing comment is this document's) and the call sites (`ip1 &+ 64`, `ip1 &+ 128`, `ip &+ 256`); Bytes/Benchmarks/RESULTS-zstd-encoder.md step 3 (libzstd's prefetches, aarch64 build; "`Builtin.int_prefetch_RawPointer` emits `prfm`"); AGENTS.md "`Builtin.int_prefetch_RawPointer(p._rawValue, rw, locality, cache)` emits `prfm` … libzstd's prefetches took 2.5–8% off level 1's cycles (dickens, mozilla); level 3 didn't move" -->
It took 2.5 to 8% off level 1's cycles on dickens and mozilla, and level 3 did not move.

Step 4 is the Huffman writer's layout, the lesson of [Part II section 6](#6-entropy-coding-building-blocks-bitbuffer-bitwriter-huffmantable)
carried further. A code table entry is stored top-aligned: its code value in the high bits and its length in the low 8 (`value << (64 - length) | length`). The
writer's container shifts right, so adding a code is one shift and one OR, and the shift amount is the entry itself (a shift uses its
amount's low 6 bits, which are the length):

```swift
// BytesCompression's ZstdHuffmanWriter (libzstd's HUF_CStream_t): codes are added at the top of a 64-bit container that shifts right.
mutating func add0(_ entry: UInt64, fast: Bool) {
    container0 = (container0 &>> entry) | (fast ? entry : entry & ~0xFF)   // one shift, one OR (fast: no mask)
    position0 &+= entry                                                    // the bit count lives in the low 8 bits
}
```
<!-- src: Bytes/Sources/BytesCompression/ZstdEncoderEntropy.swift `ZstdHuffmanWriter` doc comment and `add0` (lines 74–101); Bytes/Benchmarks/RESULTS-zstd-encoder.md step 4 ("stored top-aligned (`value << (64 − length) | length`), added with one shift and one OR (the shift is the entry itself)") -->
The first version, with a 32-bit entry, a mask, a shift, and an OR per code and 4 codes per flush, ran x-ray level 1 at 5.95 cycles a byte
(+31% over libzstd). Now a flush covers a group of 5 to 9 codes by the table's log (a group must fit beside the 7 bits a flush
leaves), and alternate groups are built in a second container, so one group's shifts do not wait on the previous: 4.43 cycles a
byte (−2%), and dickens level 1 from +12.8% to +5.1%. It is [independent chains](#independent-chains-chacha20-and-poly1305) once
more: two containers are two chains.<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md step 4 ("was a 32-bit entry, mask, shift, and OR per code, 4 per flush", "groups of 5–9 codes per flush by table log, alternate groups in a second container (HUF_CStream_t)", x-ray L1 5.95 → 4.43 c/B (+31% → −2%); dickens L1 +12.8% → +5.1%); ZstdEncoderEntropy.swift `encodeStream` (unroll 4 to 9 by `tableLog`) and the `ZstdHuffmanWriter` doc comment ("Two containers, so a group can be built while the previous one shifts in") -->

Step 6 is [section 1](#1-keep-hot-state-in-registers) again, with a twist. dfast touches its sequence store only per match, and
as a local its six fields took registers the search loop needed; left in its `inout` parameter, one of the loop's two hash constants stopped being
rematerialized per position. The other constant stays rematerialized: LLVM's cost model prefers recomputing it to keeping it
(3 instructions a position that run in parallel with the loads), and a variant that treated rematerialization as register pressure
found nothing more.<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md step 6 ("dfast's sequence store left in its `inout` parameter (it's touched per match; as a local its 6 fields took registers)") and "Treating rematerialized constants as register pressure" under "Tried and not kept" ("the other stays (LLVM's cost model rematerializes rather than keep it), 3 instructions a position that run in parallel with the loads") -->

**The gap that is left.** Instructions stay 7.5 to 11% above libzstd's on large inputs, at the same cycles (±3%). The dfast search loop
is 49 instructions against libzstd's 45: a rematerialized 5-byte-hash prime (3) and two shift amounts reloaded from the stack
per position (libzstd reloads one). The match-length tails are three compare-and-select steps where clang uses branches. The
entropy stages are at parity or below.<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md "The gap that's left" -->

**The window and the memory.** RFC 9659 caps the `zstd` content coding's window at 8 MB, and an encoder's memory is its window. Single-segment
frames (the frame's window is its content) are made only when the content size is known and fits the configured window, so no frame
needs a larger window than `windowLog` says; a 9 MiB body with the HTTP window states a 512 KB window, tested with decoders limited to
512 KB. `ZstdEncoder.Parameters.httpWindowLog` is 19 (512 KB): bodies up to 512 KB lose nothing (their frames are single segments sized to
them), and larger ones lose a little at level 3 (bytes of frame):

| Level 3, frame bytes | w19 (HTTP) | w20 | w21 (level 3's) |
|---|---:|---:|---:|
| dickens (9.7 MB) | 3,699,102 | 3,673,138 | 3,663,504 |
| mozilla (48.8 MB) | 18,399,681 | 18,290,358 | 18,227,296 |
| xml (5.1 MB) | 646,234 | 635,444 | 635,299 |
| samba (20.6 MB) | 5,150,920 | 5,035,802 | 4,955,117 |
| Main.js (3.8 MB) | 800,142 | 792,875 | 787,883 |
<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md "The HTTP window" and its table (columns w19, w20, w21; rows dickens, mozilla, xml, samba, Main.js; the doc's own sentence: "level 3 loses 0–1.7% except samba's tar (+4.0%)"); "What it is" bullet on single-segment frames ("a 9 MiB body with the HTTP window states a 512 KB window (tested with decoders limited to 512 KB)") -->

Level 3 loses 0 to 1.7% except samba's tar (+4.0%). Window log 20 is the alternative when large bodies dominate (+0.0 to 0.6%, samba +1.6%,
2.6 MB streaming). The memory is the encoder's tables, a block's sequences and literals, and a staging buffer, and streaming adds the
window and a block (`memoryUsage`); against libzstd's own estimates (`ZSTD_estimateCStreamSize_usingCParams`) with the same
parameters:

| Level, window | Bytes: tables | Bytes: streaming | libzstd CCtx | libzstd CStream |
|---|---:|---:|---:|---:|
| 1, w19 | 734,656 | 1,390,016 | 582,680 | 1,369,625 |
| 3, w19 (HTTP) | 1,455,552 | 2,110,912 | 1,303,576 | 2,090,521 |
| 3, w21 (level 3's) | 1,455,552 | 3,683,776 | 1,303,576 | 3,663,385 |
<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md "Memory (bytes)" table (rows 1 w19, 3 w19, 3 w21) and the paragraphs before and after ("Window log 20 is the alternative … +0.0–0.6%, samba +1.6%; 2.6 MB streaming"; "The one-shot difference is the staging buffer (a block, 128.5 KB): libzstd writes blocks straight into the caller's buffer") -->

The one-shot difference from libzstd is the staging buffer (a block, 128.5 KB), which libzstd avoids by writing blocks straight into the
caller's buffer; of level 3's 1.46 MB, 768 KB are the two hash tables and 352 KB a block's sequences and their codes. The tables are not
cleared between frames: their indices keep growing from frame to frame, an entry below the frame's start is ignored (which is why
validity is the branch above), and they are moved down near 3.5 GB as libzstd does (`ZSTD_reduceIndex`), tested by starting a frame just
below the limit. With a reused encoder, one call or streamed, level 1 and level 3 allocate nothing (four zero-malloc gates).<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md "Memory" paragraph after the table ("The one-shot difference is the staging buffer (a block, 128.5 KB) … Of level 3's 1.46 MB, 768 KB are the two hash tables and 352 KB a block's sequences and their codes") and "What it is" bullets on reuse ("the tables aren't cleared, their indices keep growing … moved down near 3.5 GB as libzstd's (ZSTD_reduceIndex; tested by starting a frame just below the limit)") and on allocations (gates Allocations:Zstd_encode_L1, _L3, _L1_streaming, _L3_streaming) -->

**What is not done:** levels 5 and above (greedy, lazy, lazy2, the binary-tree and optimal parsers; libzstd 1.5.7 uses its row match finder
for greedy and lazy with windows over 16 KB, so matching its frames means porting that), dictionaries, long-distance matching,
multithreading, `targetCBlockSize`, and negative levels.<!-- src: Bytes/Benchmarks/RESULTS-zstd-encoder.md "Not done" -->

#### LZMA, LZMA2, and `.xz`

The range-coder techniques are in [section 7](#7-branches-and-data-dependent-work). The container work: block headers with CRC-32s, the index checked against the
blocks, and checks (none, CRC-32, CRC-64) verified. CRC-64/XZ by slicing-by-8 tables ran 2.2 GB/s (already twice
liblzma's) but took 18% of xml's decode time. Folded with `pmull`, four 16-byte lanes and 64 bytes per step, it runs 24–41
GB/s, taking 2–13% of instructions off the Silesia rows.<!-- src: Bytes/Benchmarks/RESULTS.md LZMA "lzma-1 → lzma-2 is the CRC-64" paragraph -->
bzip2's CRC (CRC-32's polynomial, most significant bit first) has its own slicing-by-8 tables and reuses CRC-32's `pmull`
folding helper (`bytes_crc_fold`) with non-reflected constants on byte-reversed blocks; it costs 0.2% of the time in
profiles.<!-- src: Bytes/Benchmarks/RESULTS-bzip2.md API -->

**Streaming: a window, not a new loop** (2026-11-22, M1 Max). `LZMA2Decoder` decodes into the caller's whole output, which
is its own dictionary. A zip entry or a stream of unknown size needs output in pieces with bounded memory, and the obvious
way, a circular window, would add a wrap check to every match and every matched literal in the fast loop. Instead
`LZMADecoder` (raw LZMA1) and `XZDecoder` run *the same decode loops* into a flat window the decoder owns, copied out as
the caller has room. When the window is full and everything in it delivered, the last dictionary's worth of bytes slides to
the front, by a multiple of 64 so positions keep their low bits, which `lp` and `pb` select probabilities by. The window is
the dictionary plus *room*: as large as the dictionary up to 4 MiB (`LZMAWindow.defaultRoomLimit`), each slide moving the
dictionary once per room's worth of output, allocated once at its final size when the stream starts, and not zeroed (the
loops read only bytes they wrote), so a large dictionary on a small stream makes resident only the pages the output
reaches. The room limit was measured: with `xz -6`'s 8 MiB dictionary, 4 MiB makes a 12 MiB window instead of 16 for 0.3–0.4%
more instructions on streams longer than the window (samba, 20.6 MB), where 2 MiB cost 0.9–1.0% and 1 MiB 1.8%.
<!-- src: Bytes/Sources/BytesCompression/LZMAStreaming.swift header comment and `LZMAWindow.defaultRoomLimit` doc comment ("4 MiB: for `xz -6`'s 8 MiB dictionary a 12 MiB window instead of 16, for 0.3–0.4% more instructions on streams past the window (samba, 20.6 MB; none below it). 2 MiB cost 0.9–1.0%, 1 MiB 1.8% (2026-11-22, M1 Max)") -->

Input split anywhere is the other half. The fast loop runs while more than a margin of input remains, the careful loop while
more than a smaller margin do (no symbol reads more than 20 bytes), and below that each symbol is first decoded *without effect* (the approach
of `LzmaDec.c`'s `LzmaDec_TryDummy`): if its input is not all there, the decoder stops at the symbol's start and asks for
more, needing at most 20 bytes to progress. An xz stream goes an LZMA2 chunk (up to 65,542 bytes) at a time. All three
streaming decoders are `ResettableByteTransform`s, and errors latch until `reset`.
<!-- src: Bytes/Sources/BytesCompression/LZMAStreaming.swift header comment ("Input split anywhere works for raw LZMA …" and `LZMADecoder.maximumUnitByteCount` 20); XZDecoder.swift `maximumUnitByteCount` (6 + 65,536); Bytes/Benchmarks/RESULTS.md "Streaming decoders for NativeZip (2026-11-22, M1 Max; …)" bullets "LZMADecoder … and XZDecoder" and "All three conform to `ResettableByteTransform`; errors latch until `reset`" -->

The price was small. Whole-buffer LZMA decoding moved −0.1 to −0.2% in instructions (shared helpers); streaming 1 MiB of
output ran within 0.1–0.8% of the whole decode. The cost is memory, and it was cut in a second step: the first version grew
the window by doubling to dictionary plus an equal room, so peak resident memory for a 32 MB entry rose from 26 to 58 MB
(xz) and 35 to 52 MB (LZMA); with the room capped, the window allocated once, and not zeroed, those entries peaked at 30–33
MB, with six fewer mallocs per decode stream (8 to 2). NativeZip's xz extraction went from Compression's decoder to this
one at 7.6% more instructions and 29% less time ([section 7](#7-branches-and-data-dependent-work) has the numbers).
<!-- src: Bytes/Benchmarks/RESULTS.md "Streaming decoders for NativeZip" table rows "LZMA decode -6 (5 Silesia files): Bytes" (−0.1 to −0.2%) and "LZMA stream raw / xz, 1 MiB out (new)" (within 0.1–0.8% of whole); "Cleanups after the unification" bullet "LZMA and xz: one window allocation, made once and not zeroed, its room capped at 4 MiB" and paragraph "The LZMA window's memory shows in NativeZip's rows … 58–60 → 30–33 MB, LZMA 52–54 → 30–33 MB, six fewer mallocs per decode stream (8 → 2 …)"; NativeZipArchive/Benchmarks/RESULTS.md step17 final paragraph ("peak resident memory for the one-entry rows went 26 → 58 MB (xz) and 35 → 52 MB (LZMA)") -->

**bzip2 streams the same way**: only the run expansion is made resumable. A block decodes into the workspace, as before, and
its run expansion then writes straight into the caller's output and can stop anywhere, mid-run included (a block can expand
far past its 900 KB). Symbol decoding pauses within 20 bits of the input's end, and a block's tables are read again if they
run past it, so input can split anywhere with at most a block's tables, 32 KB, left unconsumed. Streaming cost +0.2–0.5% in
instructions against the whole-output decode (+2.4% on a 1.6 KB input). Replacing libbz2 in NativeZip with it cut the 32 MB
text entry's instructions 39.6% and its time from 465 to 111 ms (M1 Max), and a later tightening of the run expansion took
another 1.7–9.7% off four of the Silesia files.
<!-- src: Bytes/Benchmarks/RESULTS.md "Streaming decoders for NativeZip (2026-11-22, M1 Max; …)" bullet "BZip2Decoder.decompress(_:into:)" and table row "BZip2 … streaming 1 MiB (new)" ("+0.2–0.5% of whole (1.6 KB: +2.4%)"); NativeZipArchive/Benchmarks/RESULTS.md step17 table row "Inflate + CRC 32 MB text: bzip2" (2,540 M → 1,534 M, −39.6%; 465 → 111 ms); Bytes/Benchmarks/RESULTS.md "Cleanups after the unification" table row "BZip2 decode -9 mozilla / samba / JSON 119 KB / xml" (−9.7 / −3.5 / −2.8 / −1.7%) -->

The rule these three share: **a whole-output decoder becomes a streaming one by its window, not its loop.** The loops that had been made fast
stayed as they were, and each streaming path wraps them with the minimum that resuming needs.

#### LZ4

LZ4 decoding is mostly copies. The structure follows lz4's own "shortcut": a sequence of at most 14 literals and an
18-byte match, far enough from both ends, is handled as a token, one 16-byte literal move, an offset check, and two
16-byte match moves, in a 30-instruction loop with no calls. Everything else takes the general path (255-continued
lengths, careful copies). Each buffer has two limits, the block's exact end and the buffer's end less the 16-byte overrun;
their `min` is the fast-path bound, so one comparison picks the path.<!-- src: Bytes/Benchmarks/RESULTS-lz4-lzfse.md "Design"; "Code generation" -->
LZ4 runs between 11% fewer and 5% more instructions than Apple's Compression, except on x-ray's long literal runs (+25%),
at 0.74–1.05x its speed.
Compression's LZ4 decoder is the one place it is still clearly ahead (x-ray 10.3 against 7.6 GB/s).<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "LZ4 {raw, framed} decode {dickens, mozilla, samba, x-ray, xml, JSON}: Bytes / Compression" (speed 0.738 raw x-ray to 1.050 raw JSON; instructions on the Silesia files 0.886 dickens to 1.053 xml, x-ray 1.248; "LZ4 raw decode x-ray (8.1 MB)" 1,110 µs against 819 for 8,474,240 bytes); Bytes/Benchmarks/RESULTS-lz4-lzfse.md "Results" summary -->
Tried and reverted: 32-byte steps for long wild copies (the smaller overrun was kept), and chaining shortcut sequences
without the end-of-input check at the loop's top (+2.4–3.3%, because LLVM laid the loop out worse).<!-- src: Bytes/Benchmarks/RESULTS-lz4-lzfse.md "What worked and what didn't" -->

#### LZFSE and LZVN

LZFSE (LZ77 blocks whose literals and literal-length, match-length, distance triples are coded with FSE, a table-based
ANS; a stream may also hold LZVN blocks) follows the open reference's structure. The header is checked (counts, states,
frequency sums), value tables are 8-byte entries (`bits | extra bits | next state base | value base`), and decoding costs
12.48 instructions per byte on dickens and 4.04 on xml, at 0.90–1.03x Compression's speed on the Silesia files and 1.2–1.4x
the reference's.
LZVN matches the reference's instruction counts (±5%) at 1.1–1.35x its speed on Silesia. LZVN opcodes are classified with
a few bit tests (the undefined rows with one shift of the mask 0x2080), and a literal of 0–3 bytes is one 4-byte move that
the match then overwrites.<!-- src: Bytes/Benchmarks/RESULTS-lz4-lzfse.md "Design" and "Results" (the reference ratios, not in the new run); Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "LZFSE decode {dickens, xml, mozilla, samba, x-ray}: Bytes / Compression" (instructions 12.48 and 4.04 per byte for 10,192,446 and 5,345,280 bytes; speed 0.900 xml to 1.026 x-ray); Bytes/Sources/BytesCompression/LZFSEDecoder.swift doc comment -->

#### LZBITMAP

LZBITMAP (Compression's `COMPRESSION_LZBITMAP`, 0x702, which `aa extract` uses for APFS-compressed files) groups literals
and copies by a bitmap. The decoder's history, in instructions per output byte (dickens / mozilla):<!-- src: Bytes/Benchmarks/RESULTS-lzbitmap.md "Benchmarks" "How it got there" table -->

| Version | dickens | mozilla |
|---|---|---|
| v1: a group at a time, a loop over each nibble's repetitions | 8.14 | 7.27 |
| v2: branchless bitmap pick, no spills, runs whose cursors cannot leave the chunk | 4.22 | 4.95 |
| v3: a vector pass: bitmaps and periods for 16 groups at a time; a 15-instruction group loop | 4.12 | 4.11 |
| v4: the period check in real 16-bit comparisons; all-copy blocks | 3.24 | 3.93 |
| v5: nibble expansion copies up to the first repetition mark | 3.14 | 3.16 |
<!-- src: Bytes/Benchmarks/RESULTS-lzbitmap.md same table (columns selected) -->

The unchecked group loop is 15 instructions (a load of the shuffle, one `tbl.16b`, an 8-byte store); the vector pass is
104–116 instructions per 16 groups; the nibble unpack is `st2.16b`. Decoding reaches 5.0–6.6 GB/s on whole streams,
level with Apple's own decoder (Apple ahead on some inputs and Bytes on others), at 3.1–3.4 instructions per byte, where
the open `libzbitmap` reference takes 31–35.<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "LZBITMAP decode {dickens, mozilla, samba, x-ray, xml} (… MB): Bytes" (5.03 mozilla to 6.59 dickens GB/s; 3.11 to 3.39 instructions per byte; Bytes/Compression speed 0.95 to 1.08); Bytes/Benchmarks/RESULTS-lzbitmap.md "The decoder" and Benchmarks final table (the libzbitmap reference) -->

#### bzip2

Decoding happens in five passes over one workspace:

1. Tables: a 10-bit primary Huffman lookup, with one test sending long codes, invalid codes, and the end of the block to
   the slow path.
2. Symbols: per 50-symbol group, a loop with no calls, 41 instructions a symbol, with the move-to-front list's first 16
   bytes in a register (`tbl` to pick the byte, `ext` and a select to move it).
3. Links.
4. The walk ([section 7](#7-branches-and-data-dependent-work)).
5. Run expansion, 16 bytes at a time where no 4 equal bytes end in the window.

Results on Silesia files as `bzip2 -9` writes them: 3.2–5.6x libbz2, at about half the instructions per byte (dickens
62.9 against 105.9).<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "BZip2 decode -9 {dickens, mozilla, samba, x-ray, xml}: Bytes / libbz2" (3.245 to 5.586; instructions 0.523 to 0.594, dickens 0.594 = 62.9 / 105.9); Bytes/Benchmarks/RESULTS-bzip2.md "Design, as it ended" and "Final" table -->

#### Hashes and checksums as codec parts

XXH64's one-shot form (no streaming state) took 16,384 64-byte inputs from 3.79 to 2.44 M instructions (−35.5%).<!-- src: Bytes/Benchmarks/RESULTS.md "Cleanup and improvements" XXH64 row -->
CRC-32 runs at 72 GB/s with `pmull` folding and 8.7 GB/s braided in software; Adler-32 at 101 GB/s with `udot` (1 MB), 58 GB/s
in the first version on the M1 Max ([section 4](#4-write-simd-by-hand-and-reach-instructions-swift-cannot-name)).<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): BytesBenchmarks rows "CRC-32 checksum(_:), 256 KB" 465,407 ns and "CRC-32 tables, 256 KB" 3,846,143 ns, each 32 MiB (72.1 and 8.72 GB/s); Tools/probes/results/M3-Ultra-2026-11-20/checksums.tsv (Adler32 1 MB 101.2 GB/s); OPTIMIZATION-old.md CRC-32; Bytes/Benchmarks/RESULTS.md Adler-32 with UDOT (58 GB/s, M1 Max) -->

#### Matching Apple's bytes exactly

NativeAEA must write what Apple's tools (`aa extract`, `xip --expand`) write, byte for byte, APFS-compressed files
included, so Bytes' encoders reproduce Compression's output. The techniques are reverse engineering as much as
optimization:<!-- src: AGENTS.md "Apple's formats" lessons; NativeAEA/Sources/NativeAEA/DiskCompression.swift -->

- **Read the library, port it to C, compare, then write Swift.** `ipsw dyld extract` pulls libcompression from the shared
  cache; its local symbols (`_rav_decode_buffer`, `RavGetLitLamContext(unsigned char)::lut`) name the functions and
  tables. Binary Ninja's pseudo-C gives the structure, and `objdump` checks constants. A C transcription is verified
  against Compression's output on everything first; the Swift is then a port with the semantics settled.<!-- src: AGENTS.md "Undocumented Apple codecs can be read from libcompression"; RESULTS-lzraven.md Lessons -->
- **Apple's encoders are often the open source with a constant changed.** LZVN 0x900 is the lzfse reference's
  `lzvn_encode` with a Fibonacci hash (`((v & 0xFFFFFF) x 0x9E3779B1) >> 18` against the reference's `x 4161 >> 12`);
  `COMPRESSION_LZFSE` is the reference's with pending literals pushed past 945 instead of 2,520 (a literal backlog of 3 ×
  315 instead of 8 × 315). Bytes' encoders write Compression's streams by default, and the reference's parse stays an
  option.<!-- src: AGENTS.md "Compression's LZVN (0x900) is the open lzvn reference with another hash"; RESULTS-lz4-lzfse.md Lessons -->
- **Room checks are part of an encoder's output.** Compression's LZVN refuses a literal piece unless 10 bytes stay free
  past it (plus 8 kept for the end opcode); its LZFSE wants a whole 752-byte header struct free at each block's start. A
  chunk given exactly its own size can fail, or come out stored, where 64 KiB of room compresses it. `aa extract` gives
  every LZBITMAP chunk 64 KiB (1,604 of Xcode's files were stored differently with each chunk's own size); `xip --expand`
  gives each LZVN chunk only its own size (42 short last chunks stored raw where 64 KiB of room compressed them). Sweep
  every capacity around the stream's and input's sizes against the library, failures included.<!-- src: AGENTS.md "An encoder's output can depend on the room it's given" and "Find an Apple tool's storage rule from every file"; NativeAEA/RESULTS.md "Matching Apple's output" -->
- **An encoder can be reproduced from its machine code.** The LZBITMAP encoder transcribes the order of hash-table loads
  and stores (all 8 buckets read, then inserted in the order 1, 2, 3, 5, 6, 7, 4, 0), the candidates' lane order (ties go
  to the lower lane), and the selection loop's quirks; the failures must match too.<!-- src: Bytes/Benchmarks/RESULTS-lzbitmap.md Lessons "An encoder can be reproduced byte for byte from its machine code" -->
- **Storage rules are found from every file, in the tool's own units.** `xip --expand` compresses files over 16 KiB that
  are not PNGs when the fork saves a fifth of the 4 KiB *blocks* (`ceil(fork/4096) x 5 <= ceil(size/4096) x 4`); measured
  in bytes, ratios from 0.787 to 0.864 went both ways. `aa extract`'s rule is in bytes (93%).<!-- src: AGENTS.md "Find an Apple tool's storage rule from every file, in its units" -->
- **Probe a decoder with crafted streams, and expect two rule sets.** Compression's LZBITMAP decoder has a fast loop and a
  careful one for a chunk's end, and they disagree on corrupt input. Its buffer API also stops once the output is full and
  returns that count, so it reports streams missing their end as decoded; 0 is its only failure.<!-- src: AGENTS.md "Probe a decoder with crafted streams, and expect two rule sets" -->

### 9. Crypto

Swift cannot name the CPU's AES, SHA, and carry-less-multiply instructions, so `CBytesCrypto` wraps each as a `static
inline` function (`bytes_aese`, `bytes_aesmc`, `bytes_sha256h`, `bytes_pmull_low`, `bytes_xor3`, …: section 4's pattern),
and everything else is Swift. Without the instructions (the `Portable` trait, other CPUs), AES substitutes bytes by
arithmetic in GF(2⁸) rather than a table (a table would leak its index through the cache), and GHASH multiplies bit by bit
in constant time.<!-- src: OPTIMIZATION-old.md "AES-GCM and TLS 1.3 in Swift" first paragraph; Bytes/Sources/BytesCrypto/AES.swift bytes_aese -->

#### AES-GCM

- **Counter mode in eight-block batches**: eight independent `aese`/`aesmc` chains, as ChaCha20 needed eight blocks to
  fill the pipes. AES-CTR went from 453 to 80 to 54 µs per MB on the M3 Ultra with unrolled eight-block batches. On an M1
  Max core, AES-128-CTR (12 GB/s) is at the bound for eight chains of fused `aese`+`aesmc` rounds at 3 cycles each (about 4
  bytes a cycle); the units take almost 4 rounds a cycle, so 12 blocks in flight could reach about 1.5x (not tried; 11
  round keys and 12 states fit in the 32 registers).<!-- src: OPTIMIZATION-old.md same; Bytes/Benchmarks/RESULTS.md "crypto in Swift" (453 → 80, the dated steps); "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks row "AES-128-CTR 1 MB: Bytes" 53,727 ns (was 62 µs in the earlier run); RESULTS.md M1 section "What the cores can do" (re-measured 2026-11-21) -->
- **GHASH** multiplies by the hash key with three `pmull`s (Karatsuba), sums eight blocks' products against the key's
  first eight powers before reducing once, and reduces with two more `pmull`s by the field's constant (0xC2 shifted)
  instead of shifts and XORs.<!-- src: OPTIMIZATION-old.md same -->
- **Sealing is stitched**: each batch's GHASH runs over the previous batch's ciphertext among the AES rounds of the next
  ([section 7](#7-branches-and-data-dependent-work)'s idea).<!-- src: OPTIMIZATION-old.md same -->
- **Open is one pass, with a restore.** Each group of eight blocks is hashed from memory (before it is overwritten) while
  its keystream is made. On a tag mismatch, the stitched part is encrypted back with the same counter, so the buffer holds
  the ciphertext it was given when `open` throws, byte for byte. This is tested with forgeries of every kind at 16
  lengths and three key sizes, and with every Wycheproof vector forged. Messages under 128 bytes are checked before
  anything is decrypted. During the call, a forged message's decryption may be in the buffer, which the documentation
  says. Result: AES-128-GCM open of 1 KB × 1,024 went from 4.64 to 4.10 M instructions (−11.7%), 16 KB × 64 from 3.46 to
  3.03 M (−12.5%; CryptoKit 3.67 M), and TLS open of 4 MB from 14 to 12 M (−14%).<!-- src: Bytes/Benchmarks/RESULTS.md "Crypto cleanup" "AES-GCM open in one pass"; AGENTS.md "A stitched decrypt-and-authenticate must restore the buffer on a bad tag" -->

Sealing 1 MB as messages of various sizes (`m3-final`, p50), Bytes' AES-128-GCM against CryptoKit: 1 MB × 1, 116 µs
against 109 (9.0 GB/s; CryptoKit's hand-written assembly keeps 6% for one large message); 16 KB × 64, 126 against 151;
1 KB × 1,024, 237 against 956; 64 B × 16,384, 3,838 against 12,500 (CryptoKit's per-call setup and allocation dominate
below 16 KB).<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "AES-128-GCM seal 1 MB (x1) / 16 KB (x64) / 1 KB (x1024) / 64 B (x16384): Bytes / CryptoKit" 116,095 / 108,991, 126,463 / 150,655, 236,799 / 956,415, 3,837,951 / 12,517,375 ns; earlier: OPTIMIZATION-old.md "AES-GCM and TLS 1.3 in Swift" table (d2-final) -->

#### SHA-2, HMAC, PBKDF2, HKDF

- **SHA-512/384 on the SHA-512 instructions** (`sha512h`/`sha512h2` for two rounds, `sha512su0`/`sha512su1` for two
  schedule words; ARMv8.2): 1 MB went from 38 M to 4.01 M instructions (−89%; CryptoKit's 4.34 M) and from 1.60 ms
  (under load, indicative) to 0.57 ms (CryptoKit 0.57), at 489 instructions a block with no calls. The first
  version's state in captured variables is [section 1](#1-keep-hot-state-in-registers)'s SHA-512 example.<!-- src: Bytes/Benchmarks/RESULTS.md "Crypto cleanup" SHA-512 bullet (the 1.60 ms before); "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "SHA-512 1 MB: Bytes" 567,807 ns / 4,009,983 instructions and ": CryptoKit" 574,463 / 4,341,759 -->
  The portable block function was a rolled 80-round loop with a `round >= 16` test per round; written as five groups of
  sixteen rounds with the schedule in sixteen locals, it is about 2,570 instructions a block against about 4,600.<!-- src: same -->
- **SHA-256** on `sha256h`, `sha256h2`, `sha256su0`, `sha256su1`: 397 µs per MB against CryptoKit's 337, in 6% more
  instructions; where the rest of the time goes was not found. Round constants as vector literals took SHA-256 from 5.5
  to 2.07 M instructions.<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "SHA-256 1 MB: Bytes" 396,799 ns / 2,067,455 instructions and ": CryptoKit" 336,639 / 1,955,839 (+5.7%); OPTIMIZATION-old.md "AES-GCM and TLS 1.3" primitives table and text (5.5 → 2.07 M) -->
- **PBKDF2**: each iteration starts from a copy of the keyed HMAC, whose inner and outer hash states already hold the
  key's pads, so an iteration is two block compressions: 1.4 M instructions for 1,000 iterations against CommonCrypto's
  2.8 M (2.96x faster).<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "PBKDF2-HMAC-SHA1 x1000, 34 bytes: Bytes" 116,927 ns / 1,427,455 instructions and ": CommonCrypto" 346,111 / 2,791,423 -->
- **HKDF's expander** keys the HMAC once; TLS traffic keys expand the key and IV from one expander (two compressions saved
  per direction).<!-- src: Bytes/Benchmarks/RESULTS.md "Crypto cleanup" HKDF bullet -->

#### Elliptic curves: P-256 and P-384

ECDSA verification and ECDH are in Swift, with no C and no assembly. Against CryptoKit (corecrypto): ECDSA verify P-256 49
µs against 81 (819 K instructions against 1,733 K, 0 mallocs against 3), P-384 177 against 226, ECDH P-256 50 against 82,
HPKE open 53 against 97.<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "ECDSA verify P-256: Bytes / CryptoKit" 48,671 ns / 819,199 instructions against 81,279 / 1,732,607, "ECDSA verify P-384" 176,511 against 226,431, "ECDH P-256" 50,399 against 81,727, "HPKE open P-256 AES-256-GCM 32 B" 53,183 against 96,895; mallocs from Bytes/Benchmarks/RESULTS-ecc.md "Results" -->
The optimization log, in P-256 verify instructions:

- Complete projective formulas: 1,422 K.
- Jacobian coordinates with a width-7 NAF (non-adjacent form: a signed-digit representation with fewer additions) of u1
  over a static table of G's odd multiples, and a width-4 NAF of u2: 890 K (−37%).
- Inverting s by binary extended Euclid (variable time, because s is public): 825 K (−8%).
- Final: 819 K.

What the work taught:<!-- src: Bytes/Benchmarks/RESULTS-ecc.md "Optimization log" (the steps above); "2026-11-20, M3 Ultra" (baseline m3-final): row "ECDSA verify P-256: Bytes" 819,199 instructions (the log's last line read 812 K) -->

- **Jacobian coordinates with masked special cases beat complete formulas for constant-time ladders** (−28% ECDH
  instructions). The complete formulas have no special cases, so the first ladder was branch-free by construction, but a
  doubling costs 8M + 3S against Jacobian's 3M + 5S. In a fixed-window ladder only two special cases can occur: the
  accumulator still at the identity during leading zero windows, and a zero window. For k < n the accumulator before
  window j's addition is 16k′P with 16k′ + d ≤ k < n, so 16k′ = ±d (mod n) only when k′ = 0. Compute the addition anyway,
  and choose among sum, entry, and accumulator with masks (compiled to `csel`).<!-- src: Bytes/Benchmarks/RESULTS-ecc.md "What worked, what didn't" first bullet and "Constant time" -->
- **Write out fixed-count loops of multi-limb arithmetic.** LLVM kept Montgomery's row loop rolled even with a constant
  trip count, so the accumulator lived in memory. Calling an `@inline(__always)` row function four or six times by hand
  kept it in registers: P-384 −3 to −4% instructions per step and −13 to −15% time. Check with `Tools/loops`: the point
  formulas should show no loops.<!-- src: Bytes/Benchmarks/RESULTS-ecc.md same -->
- **A microbenchmark of a field multiply does not predict it inlined into the point formulas.** LLVM wide-integer rows
  (`Builtin.Int384`) cut a standalone multiply from 284 to 185 instructions but cost 10–16% inlined into the point
  formulas (register pressure); P-256's special reduction (the shift-and-one-product trick of OpenSSL's assembly) cost 7%
  more. Measure the whole operation.<!-- src: Bytes/Benchmarks/RESULTS-ecc.md same -->
- **Public inputs take variable-time algorithms; constant-time code only where a secret is involved.** Verification is all
  public. ECDH and key derivation are constant-time in the private key: every window does four doublings and one
  addition, and the table entry is read by visiting all 15 entries under masks. `objdump` confirmed that every
  conditional branch tests a loop counter, a public index, or the stack guard.<!-- src: Bytes/Benchmarks/RESULTS-ecc.md "Constant time" -->

#### RSA verification, X.509, scrypt

- **RSA PKCS #1 v1.5 verification** (1024–4096-bit keys; variable time, only public values): 12 µs against Security's 18
  at 2048 bits (295 K instructions against 340 K, 0 mallocs against 14), 41 against 61 at 4096. Parsing a key includes
  computing R² mod n for Montgomery multiplication. Against the first version, verification was −24% in instructions and
  −38% in time, and key parsing −79%.<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "RSA verify 2048 SHA-256: Bytes / Security" 12,335 ns / 295,423 instructions against 17,759 / 340,223 and "RSA verify 4096 SHA-256" 40,959 / 1,019,391 against 61,311; the mallocs and the −24%, −38%, −79% against the first version are from Bytes/Benchmarks/RESULTS-rsa.md "Results" -->
- **X.509 parsing**: 8.1 K instructions (0.37 µs, 0 mallocs) for a 583-byte certificate against Security's 36 K (1.56 µs,
  11 mallocs). The first version took 14 K: it walked the whole structure before parsing, and checked each extension for
  duplicates by parsing every earlier extension again (quadratic). Walking only what the parse does not read, and keeping
  the first 16 extension identifiers' ranges on the stack, gave −42%. Validation passes add up.<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "X.509 parse G3 (x1000): Bytes / Security" 371,455 ns / 8,134,655 instructions against 1,561,599 / 35,586,047 (per certificate 0.37 and 1.56 µs); the mallocs and the 14 K first version are from Bytes/Benchmarks/RESULTS-scrypt-x509.md "Parsing, per certificate" and Lessons -->
- **scrypt** (RFC 7914): 1.50–1.53x OpenSSL's speed (17.0 ms against 25.6 for N = 2¹⁴, r = 8). Salsa20/8 is scalar
  ([section 7](#7-branches-and-data-dependent-work)). The time per Salsa20/8 grows from 29 ns (N ≤ 2¹⁴) to 35–36 ns at 2¹⁶ and above, because ROMix's second
  loop reads V[j] at a data-dependent j. One DRAM and TLB miss per BlockMix is exposed and cannot be prefetched, since j
  is known only when the previous BlockMix ends.<!-- src: Bytes/Benchmarks/RESULTS-scrypt-x509.md "Against OpenSSL" -->

#### TLS 1.3

BytesCrypto implements TLS 1.3's key schedule and record layer (inner type and padding, record-size and record-count
limits, automatic KeyUpdate before the suite's limit, alerts), tested against RFC 8448's handshake traces and Wycheproof
vectors. Two rules matter for performance: a sealer's `reset()` must not restart its record sequence (nonce reuse), and
records are independent once their sequence numbers are fixed (next section).<!-- src: OPTIMIZATION-old.md "AES-GCM and TLS 1.3 in Swift" and "Pipelines"; AGENTS.md "Nonce reuse hides in reset()" -->

### 10. Parallelism

#### Chunks pulled from a queue, not rounds

`ParallelDeflateEncoder` and `ParallelBrotliEncoder` cut the input into chunks (256 KB; DEFLATE chunks carry 32 KB of
history for matches, Brotli's none) and compress them on lanes, each lane a `~Copyable` encoder with its own staging
buffer. The first design ran in rounds: one chunk per lane, a barrier, the round's output copied in order, repeat. A thread
experiment showed each round's last thread starting 124–722 µs after the first. The cost was waking 24 threads, whose
cores had dropped their clocks, every round, plus the serial copy between rounds.<!-- src: Bytes/Benchmarks/RESULTS.md "Parallel compression: a chunk scheduler instead of rounds" -->

`ChunkScheduler` does one `concurrentPerform` (or one discarding task group) per call. Workers take the next chunk index
with an atomic fetch-add, compress it, and hand the output to a slot by swapping their staging buffer with the slot's (no
copy). Whoever finishes the next chunk in order copies it to the output (under a `Mutex`: delivered count, running
checksum combined with `Adler32/CRC32.combine`, failure). A worker more than a slot ring ahead waits, delivering what is
ready. There are lanes + max(2, lanes / 2) slots. The output does not depend on which worker took which chunk.<!-- src: Bytes/Benchmarks/RESULTS.md same; Bytes/Sources/BytesCompression/ParallelScheduler.swift -->

Rounds against the scheduler, interleaved in one process (gzip, 24 lanes, same output; times in µs):<!-- src: Bytes/Benchmarks/RESULTS.md same table -->

| Input (chunks on 24 lanes) | L1 rounds | L1 scheduler | L6 rounds | L6 scheduler |
|---|---|---|---|---|
| samba 20.6 MB (96, 4 rounds) | 5,198 | 3,090 (−41%) | 9,202 | 7,197 (−22%) |
| dickens 9.7 MB (48, 2 rounds) | 2,859 | 2,229 (−22%) | 6,458 | 5,929 (−8%) |
| xml 5.1 MB (24, 1 round) | 972 | 941 | 2,255 | 2,288 |
<!-- src: Bytes/Benchmarks/RESULTS.md same table (µs) -->

The gain is the rounds saved: none with one round, 8–22% with two, 22–41% with four. Speed-up over one core at 24 lanes:
DEFLATE 14–19x (level 6 samba, 135 to 7.2 ms), Brotli quality 1 15x, quality 5 15–17x (1.10% bigger than one stream).<!-- src: Bytes/Benchmarks/RESULTS.md same -->
Later the one-shot encoder also began cutting up to four chunks per lane, none under 64 KB (interleaved, four beat one,
two, three, and six): dickens at level 6 on 28 and 32 lanes went from 7.3 and 6.5 ms to 6.2 and 5.5, samba from 7.1 and 6.6 to
6.6 and 6.25, for 0.03–0.1% more output. A 32 KB floor cost Main.js (3.8 MB, 96 chunks of 40 KB) 28% more instructions at level 1
and was reverted; the streaming path keeps one chunk per lane. On the M3 Ultra now (`Tools/probe bytes lanes`): dickens
level 6 takes 119.9 ms on one lane, 17.0 on 8, 6.3 on 24, and 5.9 on 32; mozilla level 1, 175.4, 25.2, 9.2, and 8.5.<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, parallel DEFLATE: no fallback at any lane count; joins overlap decoding" (encoder paragraph); Tools/probes/results/M3-Ultra-2026-11-20/lanes.tsv (dickens 6 encode 1, 8, 24, 32: 119.9, 17.0, 6.3, 5.9; mozilla 1 encode 175.4, 25.2, 9.2, 8.5 ms) -->
Details that cost real bugs or time:

- **Whole chunks per lane.** Equal chunks, 39 on 24 lanes, take as long as 48.<!-- src: AGENTS.md "Parallel compression: avoid rounds" -->
- **State reused across calls must be reset per call.** A slot still naming chunk 0 from the last call looked ready, which
  gave corrupt output or `insufficientCapacity`.<!-- src: Bytes/Benchmarks/RESULTS.md same last bullets -->
- **Task groups beat `concurrentPerform` by up to 10%** in a harness (0–7% in benchmarks, with more spread).<!-- src: same -->
- **Across benchmark runs these rows swing 10–30%**, so A/B parallel changes in one process.<!-- src: AGENTS.md same -->
- **Cancellation** is a stop flag (`Atomic<Bool>`, read relaxed when a worker claims its next chunk) set from a task
  cancellation handler: chunks under way finish, then the call throws `BytesError.cancelled`. Synchronous calls never
  throw it, and their instruction counts did not move.<!-- src: Bytes/Benchmarks/RESULTS.md "Cleanup and improvements" "Cancellation for the async parallel codecs" -->

#### Parallel inflate: speculate, then prove

A DEFLATE stream has no index, and a block can copy from anywhere in the 32 KB before it, so in general it decodes in
order. But a sync flush (an empty stored block: bytes `00 00 FF FF`, which ends every chunk of `ParallelDeflateEncoder`)
leaves the stream between blocks on a byte boundary, and if no later match reaches back across it, what follows decodes on
its own.

`ParallelDeflateDecoder` speculates, as rapidgzip and pugz do, but accepts a speculation only when it is proven right:

- It cuts the input into windows, up to four segments per lane, so a lane that runs slow holds up one small segment instead
  of a whole share. Each window's split point is just after a `00 00 FF FF` in it that a block header could follow
  (a vectorized scan): a candidate is skipped when the bytes after it can't start a block under DEFLATE's own header
  rules (the reserved block type, a stored block whose length doesn't match its complement, more than 286 literal or 30
  distance codes). The check never rejects a real block.
- The lanes take segments in order, each the next not yet taken, find that window's split point themselves (each depends
  only on its window, so there is no serial scan first), and decode the segment from nothing.
- A segment that reaches its end inside a block, because its next split was a false `00 00 FF FF` (Huffman-coded bits, or
  the data of a stored block), **decodes on past it** to the following split, until it is between blocks.
- The segments are joined in order. Segment *j* is accepted only if segment *j* − 1 ended exactly at its start, between
  blocks, and nothing threw. A segment that fails (a match across its start, corrupt data) is **decoded again in place**:
  the join decodes its region sequentially into the output after the bytes joined so far, so its matches see the real
  history, until it is between blocks at a later split, and the join goes on from there. A bad split costs its own region.
  Only a failed segment 0 (or no split points at all) decodes the whole stream sequentially.
- The lanes copy each accepted segment to the output as soon as every segment before it is, while the others are still
  decoding. (Before, the calling thread copied all 51 MB of mozilla at the end: about 1 ms of a 3.8 ms decode.)
- gzip's CRC-32 and zlib's Adler-32 are computed per segment and combined.

Streams from the parallel encoder (with independent chunks), pigz `-i`, and zlib streams with full flushes decode in
parallel; for streams whose matches cross every split, the first segment still decodes in parallel and the rest
sequentially.<!-- src: Bytes/Sources/BytesCompression/ParallelInflate.swift doc comment; Bytes/Benchmarks/RESULTS.md "2026-11-20, parallel DEFLATE: no fallback at any lane count; joins overlap decoding" (decodes on past a false split; decoded again in place; header rules; workers copy; each worker finds its split points) -->

The fix came from a cliff. The earlier version discarded the whole speculation when any one split proved false, and on
mozilla compressed at level 1 (stored blocks of binary data, then Huffman-coded data) one split was: a `00 00 FF FF`
22,493 output bytes into a chunk, in the middle of a block. At 11, 22, 25, and 28–32 lanes the decode took about 56 ms
instead of 4, 14 times slower, because at those lane counts it was the first marker after a split target. The sweep now (`Tools/probe
bytes segments`, mozilla level 1, 1–32 lanes) finds every lane count parallel: 8.0 ms at 8 lanes, 6.1 at 11, 4.2 at 16, 3.4 at
22, 2.9 at 24, 2.9 at 25, 2.7 at 28, and 2.7 at 32, with about 4 segments per lane. One core takes 52.7 ms, so 32 lanes are
about 19x one core. In the suite (`m3-final`) parallel inflate is 6.6–7.0x the sequential decoder on 8 lanes, 10–17x on 24, and
9–18x on 32 (dickens 11.2 ms sequential, 1.59 ms on 8 lanes, 0.66 on 24, 0.63 on 32). Four segments per lane cost 1.4–1.6%
more instructions than one (more fixed costs, but the lanes finish together). Earlier, with one segment per lane, 8 lanes
were 5.6x faster than sequential decoding on both an M3 Ultra and an M1 Max.<!-- src: Tools/probes/results/M3-Ultra-2026-11-20/segments.tsv (mozilla level 1 lanes 1, 8, 11, 16, 22, 24, 25, 28, 32: 52.8, 8.0, 6.1, 4.2, 3.4, 2.9, 2.9, 2.8, 2.7 ms; 4 segments per lane at 1–24, 98–124 at 25–32) and lanes.tsv (mozilla level 1 decode 1 lane 52.7 ms, 32 lanes 2.6); Bytes/Benchmarks/RESULTS.md "2026-11-20, parallel DEFLATE" (the cliff: 22,493 bytes into chunk 10, 55–60 ms at 11, 22, 25, 28–32 lanes) and "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "Parallel inflate {dickens, samba, Main.js}: Bytes, {sequential, 8, 24, 32 lanes}, sync" (dickens 11,165,695 / 1,590,271 / 660,479 / 629,759 ns); the 1.4–1.6% and 5.6x are from RESULTS.md "Cleanup and improvements (2026-11-19)" and Writeups/M1-Max-vs-M3-Ultra.md "Parallel scaling" -->

#### Static splits and efficiency cores

Apple silicon mixes performance (P) and efficiency (E) cores. Whether more lanes than P cores helps depends on how the work
is handed out. Measured on an M1 Max (8 P and 2 E cores), with 256 KB chunks and 1–16 lanes:<!-- src: Bytes/Benchmarks/RESULTS.md "Parallel lanes: the efficiency cores help both codecs now; one stream falls back to sequential" -->

- The **encoder** scales almost linearly to 8 lanes (7.3x on mozilla level 6), and the two E cores add another 3–9%
  (mozilla level 6: 70.7 to 64.0 ms; dickens 3%). Workers take the next chunk from a queue, so a slow core costs nothing
  at the end.
- The **decoder**, as first measured, split its segments evenly across the lanes, so 9 or 10 lanes put a segment on an E
  core and the call waited for it: 9 lanes were 20% slower on dickens and 35% slower on mozilla level 1 than 8. It now cuts
  up to four segments per lane and lanes take the next segment in order, so a slow core holds up one small segment.
  Re-measured: 10 lanes are now 7–12% *faster* than 8 (dickens 2.6 to 2.3 ms), and 9 are no slower.

So "lanes = performance cores" suits statically divided work; a queue can use every core. The M3 Ultra has 24 P and 8 E
cores; the rule was not measured there.

The re-measurement also found a cost of the finer split. On one stream, Silesia's mozilla at level 1, the decoder rejects
its speculation at 4, 8, 12, 13, 15, and 16 lanes and decodes the whole stream sequentially: 75.7 ms at 8 lanes, against
10.3 ms at 10 and 11.2 ms for the old decoder at 8. Every other corpus file and level decodes in parallel at every lane
count, including the benchmarks' inputs, which is why no benchmark showed it. Falling back for the whole stream, not just
from the bad segment, is what makes one bad split cost 7x.<!-- src: Bytes/Benchmarks/RESULTS.md same; Writeups/M1-Max-vs-M3-Ultra.md "M1 Max-specific optimizations explored"; Bytes/Sources/BytesCompression/ParallelInflate.swift doc comment -->

Both have since changed (2026-11-20). The decoder no longer falls back for the whole stream: the segment before a bad
split decodes on past it, and a failed region is decoded again in place, so no lane count decodes sequentially (not
re-measured on the M1 Max). And the rule was measured on the M3 Ultra, where
both parallel codecs now recommend every core: 32 lanes took up to 23% less time than 24, 8% at the median, over five
Silesia files at levels 1 and 6 (decode of mozilla level 1: 2.9 ms on 24 lanes, 2.7 on 32; encode of dickens at level 6:
6.3 and 5.9 ms). `ParallelDeflateEncoder` and `ParallelDeflateDecoder` document `lanes` that way.<!-- src: Bytes/Benchmarks/RESULTS.md same; "2026-11-20, parallel DEFLATE: no fallback at any lane count; joins overlap decoding" (lanes = every core; 32 lanes up to 23% less than 24, 8% at the median); Tools/probes/results/M3-Ultra-2026-11-20/segments.tsv (mozilla 1: 24 lanes 2.9 ms, 32 lanes 2.7) and lanes.tsv (dickens 6 encode 24: 6.3, 32: 5.9); Writeups/M1-Max-vs-M3-Ultra.md "M1 Max-specific optimizations explored"; Bytes/Sources/BytesCompression/ParallelInflate.swift doc comment -->

#### TLS records sealed in parallel

A TLS record's nonce is the IV XORed with its sequence number, and nothing else ties records together, so once each
record's sequence number is fixed they can be sealed in any order. Full records (16 KB of content less padding) have a
known size, so each one's place in the output is known before any is sealed. `TLSRecordSealer` with `sealingLanes` above 1
seals them on `concurrentPerform` lanes, each lane writing straight into its records' places in the output. There is no
copy and no reordering, and the bytes are the same as with one lane. This is tested, including batches that end at the
key's record limit, where the sealer sends a KeyUpdate; batches never cross one.<!-- src: OPTIMIZATION-old.md "Sealing records in parallel" -->

```swift
// Lanes share raw pointers to the input and output in an `@unchecked Sendable` wrapper. Safe: each lane touches
// only its own records' ranges, disjoint and inside bounds checked before, and `concurrentPerform` returns only
// when every lane is done, inside the closures that lend the pointers.
DispatchQueue.concurrentPerform(iterations: min(lanes, count)) { lane in
    var record = lane
    while record < count {
        var protection = template
        protection.sequence &+= UInt64(record)
        // … seal record `record` from `source + record * content` into `target + record * size`
        record &+= lanes
    }
}
```
<!-- src: OPTIMIZATION-old.md "Sealing records in parallel" -->

| Sealing 4 MB per call (p50) | 1 lane | 4 lanes | 8 lanes |
|---|---|---|---|
| AES-128-GCM | 6.4 GB/s | 20.8 GB/s (3.2x) | 35.9 GB/s (5.6x) |
| ChaCha20-Poly1305 | 2.3 GB/s | 7.8 GB/s (3.4x) | 14.6 GB/s (6.4x) |
<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "TLS seal 4 MB AES-128-GCM (1 / 4 / 8 lanes): Bytes" 652,799 / 201,471 / 116,799 ns and "TLS seal 4 MB ChaCha20-Poly1305 (1 / 4 / 8 lanes): Bytes" 1,831,935 / 536,575 / 287,743 ns, each for 4 MiB; earlier: OPTIMIZATION-old.md same table; Bytes/Benchmarks/RESULTS.md "crypto in Swift" -->

Over loopback (SocketStream, one connection, 16 KB payloads), four sealing lanes took ChaCha20-Poly1305 from 1.35–1.54 to
1.77–1.87 GB/s and AES-128-GCM from 2.79–3.16 to 3.63–3.80, against 4.6–5.8 unencrypted. Eight lanes added nothing: the
receiver opens records one at a time, which makes it the limit. Opening in parallel is harder: a record's plaintext length
(and so its place in the output) is known only after it is decrypted, since the content type and padding are at its end.<!-- src: OPTIMIZATION-old.md same; AGENTS.md "Records are independent once their sequence numbers are fixed" -->
In general, parallelism helps only the stage that is the bottleneck, and the next stage becomes the limit.

#### Other parallelism

scrypt's `p` ROMix calls run on `concurrentPerform` lanes with a table per lane (p = 4, N = 2¹⁴: 58 ms on one lane, 17 ms
on four, 3.4x, with the same 775 M instructions).<!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): CompressionBenchmarks rows "scrypt N=2^14 r=8 p=4: Bytes, 1 lanes / 4 lanes" 58,359,807 / 17,055,743 ns, 774,574,128 / 774,606,459 instructions; Bytes/Benchmarks/RESULTS-scrypt-x509.md "scrypt" and "Against OpenSSL" -->
Many-core memory-bound reads and many-archive extraction are in sections [11](#11-techniques-in-the-projects-built-on-bytes) and [13](#13-measuring-honestly).

#### When not to

Parallelism has a floor per call (pool bookkeeping allocations, waking threads whose cores are at low clocks), so small
inputs stay sequential. Parallel inflate decodes a failed segment's region again in place, and decodes the whole stream
sequentially only when the first segment fails or no split point exists. And file-system work
([section 11](#11-techniques-in-the-projects-built-on-bytes)) stops scaling at a handful of threads, because the kernel, not the CPU, is the limit.<!-- src: Bytes/Benchmarks/RESULTS.md "Parallel compression"; NativeZipArchive/Benchmarks/RESULTS.md step15 -->

### 11. Techniques in the projects built on Bytes

The libraries above are used by four projects whose job is not a codec but a *workload*: packets, archives, extraction.
Each found its own limits. Two more sections cover what the archive projects share: Disk, the file-system layer under both,
and Nunarchiver, the app on top. (SocketStream, the fifth, is about concurrency and sockets: Part IV (["SocketStream: what the PR
toolchain's I/O interfaces made possible"](#2-socketstream-what-the-pr-toolchains-io-interfaces-made-possible)). HTTPBytes,
the sixth, is a whole protocol family written from scratch on Bytes, and has [a section of its own](#12-case-study-httpbytes).)

#### MQTT: views, per-type dispatch, and not decoding twice

`MQTT` implements MQTT 5 packets on Bytes: `MQTTFrame` (a zero-copy fixed header plus body span) and per-type
`init(parsing:)`/`write(to:)`. Its measured throughput is below (baseline `d2-final`, the newest full run on the M3 Ultra;
10,000 PUBLISH packets, every MQTT 5.0 receiver rule checked; the all-core column is 32 threads, each parsing its own
copies from memory):<!-- src: MQTT/Benchmarks/RESULTS.md "2026-11-19: the same suite on an M1 Max" ("One core" and "All cores" tables, M3 Ultra columns) -->

| Workload | 1 core | 32 threads | Mallocs per 10,000 packets |
|---|---|---|---|
| Parse PUBLISH, views, every field and property | 25.5 M packets/s (392 µs) | 567 M packets/s | 0 |
| Parse PUBLISH, conventional (`[UInt8]` indexes, owned values) | 3.0 M packets/s (3,389 µs) | 30 M packets/s | 40,000 |
| Encode PUBLISH, `BytesWriter` | 45.5 M packets/s (220 µs) | 692 M packets/s | 0 |
| Encode PUBLISH, conventional (`[UInt8]` appends) | 3.5 M packets/s (2,826 µs) | 34 M packets/s | 30,000 |
<!-- src: MQTT/Benchmarks/RESULTS.md "2026-11-19: the same suite on an M1 Max", M3 Ultra columns (rows selected) -->

On one core, the views parse 8.6x as fast and the writer encodes 12.8x as fast as the conventional code. On all cores the
gaps grow to 18.6x and 20.5x, which the records attribute to the conventional code's 3–4 allocations per packet contending
in the allocator (the contention itself was not measured).<!-- src: MQTT/Benchmarks/RESULTS.md "The views against the conventional code" and its Observations; "Current" "Against the conventional code" -->
The techniques, in the order they mattered:

**Zero-copy views.** Parsing copies nothing: payloads and strings are spans of the input (`~Escapable` view types; Part II,
["`~Escapable`: the compiler checks the lifetime"](#escapable-the-compiler-checks-the-lifetime)). Copying the topic, payload, and strings out of the views (2 allocations
per packet) takes one core from 25.5 M to 7.2 M packets per second.<!-- src: MQTT/Benchmarks/RESULTS.md "What vectorizes" Copies; "2026-11-19" "One core" table (M3 Ultra) -->
Views have a price in Swift 6.4: `~Escapable` structs with more than 6 leaf fields are destroyed at `-O` even when every
field is trivial, and from another module the destroy is an indirect call to a no-op through the type's value witness
table. That is 2.5–3% of MQTT's per-packet time. The workaround is at most 6 leaf fields or inlining, which is impractical
for packet views.<!-- src: OPTIMIZATION-old.md section 12 table "~Escapable structs with more than 6 leaf fields"; MQTT/Benchmarks/RESULTS.md "MQTTPacket out of the hot paths" last bullet -->

**Aligned cursors.** Every MQTT field is whole bytes, so parsing moved to `AlignedBytesReader` and writing to
`AlignedBytesWriter` ([section 1](#1-keep-hot-state-in-registers)): PUBLISH encode −6.1% (5,464 K to 5,132 K instructions), parse −0.9 to −2.9%, mixed
stream −1.8%. Flag bits are read from a `Byte`, not from the stream. MQTT uses `BigEndianBytesReader` and
`BigEndianBytesWriter`, the same byte-aligned cursors with big-endian integers by default, at identical instruction
counts.<!-- src: MQTT/Benchmarks/RESULTS.md "2026-11-16: byte-aligned cursors" and "2026-11-17" BigEndianBytesReader bullet; MQTT/Sources/MQTT/Framing.swift MQTTFrame.read(from:); Bytes/Sources/Bytes/CursorMode.swift -->

**Per-type parse and write instead of a big enum switch.** `MQTTPacket` is 153 bytes (CONNECT, with its optional will, is
the largest case), too big for registers, so it is built and returned through memory, and each test of its case is a call
to an outlined "get tag" function. Writing a packet tested its case five times (`validateFields()`, `remainingLength`,
`flags`, `type`, then the body). The fix gives each packet type its own `init(parsing:)` and `write(to:)`, with
`MQTTFrame.read(from:)` as separate framing, so a caller dispatches on the frame's `type` before building anything:<!-- src: MQTT/Benchmarks/RESULTS.md "MQTTPacket out of the hot paths"; OPTIMIZATION-old.md "11." "Big enums are expensive to pass around" -->

```swift
// Before: build the enum, then test its case.
if case .publish(let publish) = try MQTTPacket.read(from: &reader) { … }

// After: read the fixed header, dispatch, build only what's needed.
guard let frame = try MQTTFrame.read(from: &reader, maximumPacketSize: limit) else { return }
if frame.type == .publish { let publish = try MQTTPublish(parsing: frame) … }
```
<!-- src: OPTIMIZATION-old.md "11." same -->

One core, p50: encoding through `MQTTPacket.write(to:)` went from 20.9 M to 35.2 M packets per second (+68%, 9.5 M to 6.7
M instructions); parsing through frames reached 30.0 M (+58% against the 19.0 M before), against 23.7 M through the enum;
a mixed stream gained 23%. Writing through the enum costs nothing (one case test, then the same code). Parsing through the
enum still costs 26% against frames (building the enum in memory, returning it, testing its case: about 9 ns per packet).

What did not help: inlining `MQTTPacket(parsing:)` into the caller (4–9% slower), declaring the types `BitwiseCopyable` or
`@frozen` (identical code), and wrapping each case in an immediately called closure. The last does not compile: a
closure's result cannot depend on a lifetime, so it cannot return `~Escapable` values.<!-- src: MQTT/Benchmarks/RESULTS.md "MQTTPacket out of the hot paths" table and bullets -->

**16-byte string scans** ([section 4](#4-write-simd-by-hand-and-reach-instructions-swift-cannot-name)): a string's UTF-8 and forbidden bytes are checked in one NEON pass, replacing the
standard library's out-of-line validation followed by a SWAR scan. Parsing PUBLISH went from 15.1 to 19.0 M packets per
second (+26%, 14 M to 11 M instructions), and with properties not iterated, +40%.<!-- src: MQTT/Benchmarks/RESULTS.md "16-byte scans" table -->

**Parse values once.** MQTT's properties (a variable-length list of typed values) were decoded twice whenever a caller
iterated them: once to validate the packet at parse time, then again when `forEach` handed them out.
`MQTTPublish(parsing:visitingProperties:)` takes a closure that sees each property as it is validated. 10,000 PUBLISH
frames with both properties used take 7,365 K instructions against 8,831 K (−16.6%), with no allocations.

The first version of this cost something elsewhere. The visiting initializer, forced inline, changed what the PR
toolchain's inliner did to the plain path (SocketStream's check +10.4%), and the plain path through an empty `{ _ in }`
closure cost MQTT's parse 2% under Xcode's compiler. The plain and visiting paths have separate bodies.<!-- src: MQTT/Benchmarks/RESULTS.md "2026-11-17: named flags... properties parsed once"; OPTIMIZATION-old.md "Parsing values once" -->
An audit for values read twice in the swift-binary-parsing ports found one more: a binary property list's `0xF`-escaped
dictionary count was read once for the keys and again for the values; the tests caught it.<!-- src: OPTIMIZATION-old.md "Parsing values once" last paragraph -->

**Validation has a price, and it is quantified.** Rejecting everything MQTT 5.0 requires of a receiver costs PUBLISH
encoding about 19 ns per packet (mostly scanning the topic, about 8 ns), and parsing with unread properties about 7 ns.
Reading properties does not re-validate them, which pays for the new checks when properties are read.<!-- src: MQTT/Benchmarks/RESULTS.md "What validation costs" -->

**Where it vectorizes and where it cannot.** A packet is a chain of dependent fields (lengths decide where the next field
starts), so it parses with scalar loads and branches. The parallelism is across packets and cores: 32 threads do 22–24x
one core's work when parsing and 15x when encoding, compute-bound (in the older `validated` run, 45 GB/s was about a fifth
of the CPU's memory bandwidth). One core takes about 39 ns to parse a PUBLISH with every property and 22 ns to encode one.<!-- src: MQTT/Benchmarks/RESULTS.md "2026-11-19" "All cores" speed-up column and Observations (22.0 ns per packet); "One core" table (392 µs per 10,000); "Current" "All 32 cores reach about 20x" -->

#### NativeZipArchive: the kernel is the limit

`NativeZipArchive` reads zip archives (stored, DEFLATE, Deflate64, bzip2, LZMA, xz, Zstandard; ZipCrypto and WinZip AES),
and `nunzip` extracts them with Info-ZIP unzip's options. Its record of what mattered is mostly about the file system.

**Decode once, without allocating; the width of file creation is the cost.** With a zlib-based decoder using a reusable
inflate state and one output buffer, extracting 2,000 small files with 32 workers used 1.75 s of CPU for 333 ms of wall
time: workers creating files in the same directories contend in the kernel. In the width experiment (run on that early version of the extractor), CPU time rises with
the worker count while wall time falls and then rises:<!-- src: NativeZipArchive/Benchmarks/RESULTS.md "step1" and "Width experiment" -->

| Workers | 1 | 2 | 4 | 8 | 32 |
|---|---|---|---|---|---|
| Wall | 215 ms | 152 ms | 113 ms | 106 ms | 311 ms |
| CPU | 215 ms | 263 ms | 327 ms | 490 ms | 1,637 ms |
<!-- src: NativeZipArchive/Benchmarks/RESULTS.md "Width experiment (2,000 small files, step1 code)" -->

The floor (raw `open`/`write`/`close`, no decoding, one thread) is 167 ms, about 1 M kernel instructions per file. Capping
file creation at 8 (plus one worker per entry of 1 MB or more beyond that) took the extraction to 102 ms (−67% against the
baseline). Claiming contiguous archive-order batches, so workers stay in different directories, changed nothing: the
contention is file-system-wide, not per directory. `openat` relative to cached directory descriptors saved 6% of the floor
and was not adopted. Measured again with 20,000 files of 1–8 KB (4 workers 708 ms, 8 728, 12 891, 16 1,386, 24 2,192; CPU
time 2.3 s to 12.9 s), file creation still caps out at about 8.<!-- src: NativeZipArchive/Benchmarks/RESULTS.md "step2", "step1" floor text, "step3"-"Experiments that didn't pay off", step15 "Parallelism" -->

**Where the time goes.** Time Profiler on the worker threads, small files: `open` 45%, `write` 19%, `close` 13%, `futimens`
11%, `fchmod` 7%, decoding about 2%. Setting times and mode in one `fsetattrlist` call: −6% CPU, wall time within noise.<!-- src: NativeZipArchive/Benchmarks/RESULTS.md step15 "Where small-file time goes" -->

**Pipeline the planning with the writes.** Planning (opening archives, selecting entries, resolving name collisions) was
serial and ahead of every write: 60–73 ms for 20,000 entries. Three changes brought it to 46–57 ms: `FileJob` as a class
(copies of the struct, holding resilient `Date?`s, went through value witnesses), collision keys from the short relative
path, and a directory cache remembering the last directory. Then the workers start first, and the planning closure runs
while they write. Each planned file is queued at once (large ones largest first, small ones in order); eight workers take
anything, and the rest take only large files.<!-- src: NativeZipArchive/Benchmarks/RESULTS.md step15 "Parallelism" -->

**Work in cache-sized pieces.** For one large stored file (1 GB), checksumming it whole and then writing it whole read it
from memory twice (253 ms). In 8 MB pieces, each checksummed and then written while in cache, it took 180 ms. Writing the
pieces in parallel gained nothing (1, 4, and 24 writers all took 178–180 ms, because the kernel serializes writes to one
file), and copying into a shared mapping of the destination was slower (4 threads 246 ms, 24 threads 571 ms).<!-- src: NativeZipArchive/Benchmarks/RESULTS.md step15 "One large stored file" -->

**One pool for several archives.** Eight archives of one 64 MB text file each took 339 ms processed one after another and
73 ms with one worker pool across all of them (4.6x). Sixteen archives of 1,000 files: 953 to 731 ms. End to end against
Info-ZIP's `unzip`: 20,000 files in 542 ms against 2,170 ms; 1 GB stored in 209 against 3,990. What stays serial: one
DEFLATE stream decodes on one core (about 2 GB/s).<!-- src: NativeZipArchive/Benchmarks/RESULTS.md step15 table and "What stays serial" -->

**Allocation-free decode.** [Section 6](#6-allocation-free-code)'s closure-capture fix took inflating 2,000 small files from 4,001 mallocs to 1, with
`sending` instead of `@unchecked Sendable` for the pipelined chunk.<!-- src: NativeZipArchive/Benchmarks/RESULTS.md step4 -->
Directory parsing also recovered the cost of richer entries. `ZipEntry` stores the DOS time as a `Double` (NaN for none)
and permissions as a `UInt16`, with `modificationDate` and `posixPermissions` computed and the time conversion out of
line: parsing 2,000 entries went from 6,062 K to 4,297 K instructions (−29%), 342 to 189 µs.<!-- src: NativeZipArchive/Benchmarks/RESULTS.md step16 "Parsing" -->

**Every method in Swift** (2026-11-22, M1 Max). The first versions decoded DEFLATE and Deflate64 with the package's own
`Inflater`, bzip2 with libbz2, LZMA with its own decoder, and xz with Compression's stream. All of them are gone: every
method now decodes with Bytes' streaming decoders, driven by one `Decompressor`, and neither the library nor `nunzip`
links zlib, Compression, or libbz2 (the tests and benchmarks keep them as references). Entries up to 1 MiB decode whole;
DEFLATE and Deflate64 decode into the two 1 MB buffers after the history copied to their front
(`decompress(_:into:historyCount:)`); the rest stream. Measured with the old and new code interleaved on the M1 Max (32 MB
text entry, instructions and time):

| Method | Instructions old → new | Time old → new |
|---|---|---|
| bzip2 (libbz2 → `BZip2Decoder`) | 2,540 M → 1,534 M (−39.6%) | 465 → 111 ms (−76%) |
| LZMA (own decoder → `LZMADecoder`) | 1,481 M → 1,334 M (−9.9%) | 178 → 146 ms (−18%) |
| xz (Compression → `XZDecoder`) | 1,257 M → 1,352 M (+7.6%) | 207 → 148 ms (−29%) |
| Deflate64 (`Inflater` → `DeflateDecoder`) | 240 M → 237 M (−1.2%) | 19 → 19 ms |
<!-- src: NativeZipArchive/Benchmarks/RESULTS.md "step17 (2026-11-22): every method in Swift (baselines zipnative-old-{1,2} → zipnative-new-{1,2}, M1 Max)" table rows "Inflate + CRC 32 MB text: bzip2 / LZMA / xz / Deflate64" (instructions, change, time, two rounds averaged) and the bullets above it -->

The next step, the DEFLATE fast loop of [section 8](#8-algorithms-and-data-structures-codec-by-codec), took the 32 MB text
entry from 236 M to 147 M instructions (−37.7%), the 2,000 small files' inflate from 232 M to 162 M (−30.2%), and extracting
eight 64 MB archives with one pool from 4.14–4.23 G to 2.78–2.80 G instructions (−33%; 141 to 91 ms, a parallel row, ±20%).
DEFLATE in NativeZip now runs fewer instructions than zlib in the same harness on text (147 M against 218 M) and more on
raster (116 M against 91 M, where zlib's long-run path is cheaper), and is faster on both (16 against 18 ms, and 11 against
13 ms).
<!-- src: NativeZipArchive/Benchmarks/RESULTS.md "step18 (2026-11-22): one `Decompressor`, the cleanups" table rows "Inflate + CRC 32 MB text: Bytes" (236 M → 147 M, −37.7%), "Inflate + CRC 2,000 small files: Bytes" (232 M → 162 M, −30.2%), "Extract 8 archives of 64 MB text (one pool)" (4,140–4,230 M → 2,780–2,800 M, −32.9 / −33.8%; "141 → 91 / 94 → 89 ms (parallel: ±20%)") and the paragraph "DEFLATE in NativeZip now runs fewer instructions than zlib …" -->

**Streamed decryption.** Encrypted entries of every method now decrypt in 256 KB pieces into a staging buffer as the decoder
takes its input (Deflate64 and LZMA used to be decrypted whole first): every decoder takes input split anywhere, which is
what made it possible. AES checks the whole payload's MAC before any output (WinZip's specification requires it). The
staging buffer and decoder are made on the first encrypted entry ([section 6](#6-allocation-free-code)). ZipCrypto's cipher
updates its key registers through `CRC32.updateRegister`, one byte step of CRC-32 that is the CPU's `crc32b` instruction
on ARM64 and a table lookup elsewhere (ZipCrypto's key schedule is a byte-at-a-time CRC): against the old cipher in one round during the work, instructions fell 40.6% on a stored entry and
16.9% on a deflated one.
<!-- src: NativeZipArchive/Benchmarks/RESULTS.md step17 bullet "Encrypted entries of every method now stream through the 256 KB staging buffer (Deflate64 and LZMA used to be decrypted whole first): every decoder takes input split anywhere"; step18 paragraph "Against a run of the old cipher during the work (instructions, one round), `CRC32.updateRegister` cut ZipCrypto stored 40.6% and deflated 16.9%" and "ZipCrypto's cipher updates through `CRC32.updateRegister`"; Bytes/Sources/Bytes/CRC32.swift `updateRegister` (`Builtin.int_aarch64_crc32b` under `HardwareCRC`); NativeZipArchive/Benchmarks/RESULTS.md step16 "Streamed decryption" (the MAC rule) -->

**One decoder per method makes the memory a number.** The streaming LZMA window is the cost of the method (Part III,
["LZMA, LZMA2, and `.xz`"](#lzma-lzma2-and-xz)): the 32 MB xz entry's peak resident memory went from 26 to 58 MB with the
first streaming decoder, and to 30–33 MB with the capped window (an extraction of many large xz entries holds about one
window per writer decoding one).
<!-- src: NativeZipArchive/Benchmarks/RESULTS.md step17 last paragraph ("peak resident memory for the one-entry rows went 26 → 58 MB (xz) … Per writer, so an extraction of many large xz entries holds about 16 MiB per writer decoding one") and step18 "Memory:" paragraph ("52–60 MB to 30–33 MB") -->

#### NativeAEA: a decode pipeline against a file system

`NativeAEA` reads Apple Encrypted Archives (`.aea`), Apple Archives (`.aar`), and Xcode's `.xip`, and extracts them. The
pipeline (ARCHITECTURE.md) has five stages:<!-- src: NativeAEA/RESULTS.md "The pipeline"; NativeAEA/ARCHITECTURE.md "The shape of the pipeline" -->

1. **Open**: the signature, certificate chain, and header MACs are checked, giving a table of segments with their
   checksums, MACs, and keys.
2. **Decode**: one task per core takes a free buffer from a fixed pool, then the next segment (in *that order*). It reads
   the segment, checks its MAC, decrypts, decodes (LZMA2, LZFSE, LZVN, LZBITMAP, LZ4, LZRAVEN, zlib, all through one
   `Decompressor`), checks its checksum (SHA-256 or Murmur64, whichever the archive names), and publishes it.
3. **Walk**: one task takes segments in order and parses headers *in place*.
4. **Write**: writer tasks compress (64 KiB chunks: LZBITMAP for `.aea`, LZVN for `.xip`) outside a limiter, then make the
   file inside it, at most 6 at once.
5. **Finish**: hard links, then symbolic links (so nothing is written through one), deferred metadata (extended attributes,
   ACLs), and directories' modes, times, and flags, deepest first.

**Buffer-then-segment order prevents a deadlock.** A decoder takes a free buffer *first* and only then claims the next
segment index. A decoder holding a segment number therefore always has somewhere to put it, and the segment the walker
waits for can never be starved by decoders that took later numbers and are waiting for buffers.<!-- src: NativeAEA/ARCHITECTURE.md "SegmentStream" "The order of those two steps prevents a deadlock" -->

**One buffer pool, reference-counted, with a carry region.** The pool is a single page-aligned allocation divided into
buffers, each laid out as `[ carry region: 64 KiB ][ chunk ][ 64 bytes slack ]`. For Xcode that is 32 + 8 + 24 + 1 = 65
buffers of 16 MiB, about 1.1 GB. Each buffer has a reference count: the walker holds one while it reads the chunk, each
job pointing into it holds one, and the last release hands the buffer to the longest waiter.

A header split across two chunks is made contiguous by copying its first bytes (at most 64 KiB) into the carry region
before the next chunk; file contents are never copied. The slack lets decoders be asked for one byte more than expected
(to detect a segment that decodes long) and leaves room for 16-byte copy loops. A buffer stays out of the pool until the
walker has moved past it and every job pointing into it has been written. That is what bounds memory: decoders suspend
when the pool is empty, and the walker when decoders have not caught up.<!-- src: NativeAEA/ARCHITECTURE.md "The buffer pool and its references" -->

**Parsing in place.** The walkers parse headers directly in the buffer, recording *offsets* (path, link target, blobs)
instead of copies; sinks are called with pointers into the buffers. The cpio walker translates each header into the Apple
Archive model, so the extractor never learns an entry came from a xip: adding xip support needed no change to the
writers.<!-- src: NativeAEA/ARCHITECTURE.md "Walkers: parsing in place" -->

**Compression outside the file-system limit.** APFS file creation contends beyond a few threads. A microbenchmark (60,000
files: create, write or set the `decmpfs` attribute and flag, close) showed it peaking at 4 threads, the same in one
directory or one per thread:<!-- src: NativeAEA/RESULTS.md "The file system is the limit" -->

| Threads | 1 | 4 | 8 | 16 |
|---|---|---|---|---|
| Files a second, one directory | 14,282 | 45,998 | 36,690 | 32,571 |
| One directory per thread | 20,381 | 49,818 | 36,466 | 15,407 |
<!-- src: NativeAEA/RESULTS.md same table -->

So compression, CPU work that scales with cores, runs on 24 writers, and the file-system calls on at most 6. The writers'
summed time on Xcode's xip: 33.8 s waiting for admission to the file system, 14.9 s compressing, 9.2 s in `open`, 3.9 s
writing data, 3.3 s on forks, 3.1 s on times and flags, 1.6 s in `close`. Apple's `aa extract`, which allows 32 threads in
the kernel, spent 340 s of system time extracting Xcode's `.aea`, against 41 s for NativeAEA. The width that measured best
on the xip was 6 (4: 11.2 s; 6: 9.8–10.1 s; 8: 10.45 s; 12: 11.2–11.4 s).

The first (threaded) version's progression for Xcode's `.aea` with compressed output: 11.36 s (12 writers doing
everything), 9.0–9.4 (compression outside a file-system semaphore), 8.5 (large files' pieces compressed in parallel),
7.75–7.92 (BytesCompression's LZMA decoder). Matching `aa extract` byte for byte, quarantine included, puts it at 8.93 s
(median; 7.93 s without the quarantine attribute).<!-- src: NativeAEA/ARCHITECTURE.md "Why compression is outside the file-system limit"; NativeAEA/RESULTS.md "How it got here", xip "Where the time goes" and "The AEA defaults", and "The timing pass" table -->

**Large files must not hold slots for the queue's latency.** With 4 slots for files across segments, the walker waited
6.0 s of 9.0 s. A file's pieces were compressed one after another (each needs the fork offset where the last ended), each
holding its 16 MiB buffer, behind 16,000 queued small files. In the current design a piece compresses as soon as it
arrives, chunk by chunk, *moving each chunk's output back over its own consumed input* in the segment buffer. No other job
reads those bytes, and a piece's output stays behind its unread input; if it would catch up, the rest is compressed after
its turn. Its turn is only the writes. With 128 slots the wait is gone (9.0 to 8.5 s).<!-- src: NativeAEA/RESULTS.md "Large files waited on each other"; AGENTS.md "A pool of slots that jobs hold until they finish" and "Overwrite consumed input in place" -->

**APFS compression (`decmpfs`) is three calls after `open`:** the resource fork (`fsetxattr("com.apple.ResourceFork",
position)`), `com.apple.decmpfs` (a 16-byte header, data inline when small), then `fchflags(UF_COMPRESSED)`. Chunks are 64
KiB, stored as 0xFF plus the raw bytes when they do not compress. `clonefile` keeps all of it but ran at 23,000 a second on
4 threads, slower than creating files. Two traps: `fsetxattr` checks the file's *mode*, not the descriptor's, so a file
created 0444 fails with `EACCES` (create it owner-writable, and `fchmod` at the end); and `fchflags(UF_COMPRESSED)` sets
the modification time to now (set times after the flags).<!-- src: AGENTS.md "APFS compression (decmpfs) is three calls after open" and "Setting an extended attribute checks the file's mode"; "fchflags(UF_COMPRESSED) sets the file's modification time to now" -->

**Hard links cost kernel time.** APFS spends about 280 µs of kernel CPU on every `linkat`: Xcode's 26,062 later names take
2.6 s on 6 threads, the largest serial phase after the walk. Links made during the writes slowed the writers by as much
(11% slower, 30% more system time), so links are made after the writers.<!-- src: AGENTS.md "APFS spends ~280 µs of kernel CPU on every linkat"; NativeAEA/RESULTS.md xip "Hard links during the writes" -->
Creating entries relative to an open parent descriptor was 3% slower (the name cache makes path lookups cheap, and opening
each directory is one more call).<!-- src: NativeAEA/RESULTS.md "What didn't work" -->

**Give pages back.** Each decoder's 16 MiB read buffer stayed resident up to the largest stored segment it had seen.
`madvise(MADV_FREE_REUSABLE)` past a 2 MiB floor after each use, and `MADV_FREE_REUSE` before, took xip extraction from
1,398 to 1,228 MB, with system time unchanged. Making encoders and decoders on first use saved about 35 MB more.<!-- src: NativeAEA/RESULTS.md "Read buffers give their pages back" and "Encoders and decoders made on first use"; AGENTS.md "A buffer sized for the largest item stays resident" -->

**Do not let shared state decide a handoff.** A writer cleared a large file's fork type while the walker used it to decide
whether to pass a buffer reference on; the reference leaked, and `DispatchSemaphore` trapped at deinit. The decider keeps
its own copy.<!-- src: AGENTS.md "Shared mutable state the walker reads to decide reference handoffs is a leak" -->

**Results.** Xcode's `.xip` (2.05 GB; 10.35 GB of cpio; 167,193 items) expands in 9.9 s against Apple's `xip --expand` at
47.8 s (4.8x), with identical output, and 2.2x faster than `unxip`, in less than a third of its memory. Xcode's `.aea`
extracts 5.2x faster than `aa extract` (8x less system time). Every one of the 167,542 items `aa extract` writes from the `.aea` matches
byte for byte, compressed bytes included, which depends on the encoder techniques in [section 8](#8-algorithms-and-data-structures-codec-by-codec). Moving the stages from threads
to structured concurrency kept wall time within a few percent (10.30 to 10.01 s for the xip, 9.39 to 9.64 s for the aea;
Part IV, ["NativeAEA: from threads to structured concurrency"](#3-nativeaea-from-threads-to-structured-concurrency)).<!-- src: NativeAEA/RESULTS.md xip section and APFS compression section "Timing" tables; "structured Swift concurrency" table -->

**Every format in Swift, every read through Disk** (2026-11-22, M1 Max). The first versions could decode segments with
Compression as well as with Bytes. The system decoders are gone (`import Compression`, the backend option, and the
`--decoder` flag with them): every segment codec decodes with BytesCompression, WKMS's authentication-data JSON is read by a
strict reader on Bytes (an object of string members, every escape, surrogate pairs) instead of `JSONDecoder`, and an audit
found no other system parser (XAR and xip metadata use the package's XML scanner, PEM and DER BytesCrypto, Base64
BytesBase64). Every file read goes through Disk's `InputFile` (below), replacing the readers' own descriptor loops. Nothing
measurable changed, which was the point, since Bytes had been the default decoder: listing the synthetic archive 260 G
instructions before and after, extraction 401.5 G to 401 G, `Decode segment 0` 1,132 M instructions before and after.
<!-- src: NativeAEA/RESULTS.md "2026-11-22: every format in Swift, every file through Disk (baselines aeanative-old-{1,2} → aeanative-new-{1,2}, M1 Max)" bullets and table (rows "List (decode, verify, parse): synthetic" 260 G → 260 G; "Extract: synthetic: archived" 401.5 G → 401 G; "Decode segment 0" 1,132 M / 929 M unchanged) and "Nothing measurable changed, which is the point: the formats were already decoded by Bytes by default" -->

**Read or map the archive?** The decoders read segments with `pread` by default (`--input read`) rather than from a
mapping, because a mapping turns a file truncated while it is being read into `SIGBUS` for the whole process (the app
expands several archives at once), and the mapping gains no time: five alternating rounds extracting the synthetic archive
took 5.59–5.82 s reading and 5.67–5.88 s mapped (means 5.71 and 5.74). The footprint differs, 541–544 MB reading against
488–489 MB mapped, because each decoder's read buffer stays resident up to `RawStorage`'s 2 MiB floor, where mapped pages
are clean and file-backed and outside the footprint.
<!-- src: NativeAEA/RESULTS.md "2026-11-22, late: Disk's settings inside the options, `ArchiveKind`, input by reads (…)" paragraph "`--input read` against `mapped`" (five alternating rounds, `/usr/bin/time -l`; "read 5.59–5.82 s, mapped 5.67–5.88 s (means 5.71 and 5.74); peak memory footprint read 541–544 MB, mapped 488–489 MB (−53 MB). The default stays `read`: no time to gain, and a mapping turns a file truncated while it's read into SIGBUS for the whole process") -->

#### Disk: the file system's limits, in one place

NativeZip and NativeAEA each wrote extracted trees to disk, and each learned the same things about APFS. **Disk** is
where they now live once: `Extraction.run(into:source:settings:_:)` takes a *planner* (the serial part: names, parents,
collisions, links) and a *content source* (the bytes of each file, or pieces of a large one), and runs *writers* that
create files outside a limiter on file-system calls. A client supplies the decoding; Disk supplies everything below the
`open`. (Measured on the M3 Ultra under load, so times are indicative and call counts firm, except where a section says M1
Max.)
<!-- src: AGENTS.md "Repository" table, Disk row; Disk/RESULTS.md header ("Every time below was taken under load … instruction, call, and allocation counts are the firm numbers") -->

**Count the calls per entry, and make each one necessary.** A plain file with times costs 4 calls: `openat`, `pwrite`,
`fsetattrlist`, `close` (2,000 files: 8,029 calls, which is 4 × 2,000 plus 20 directories plus 9). One `fsetattrlist` sets
the mode, the times, and the flags together and *keeps* the times even with `UF_COMPRESSED`, where a separate
`fchflags(UF_COMPRESSED)` sets the modification time to now. On a probe over 2,000 files, `fchmod` + `fchflags` +
`fsetattrlist` took 173 ms, 12,000 syscalls, and 2.48 G instructions; one `fsetattrlist` took 159 ms (−8%), 8,005
syscalls, and 2.14 G (−14%). A call is skipped when nothing differs from what `open` made, and `fchflags` alone is used
when flags are all there is. Disk counts its
own calls under a `SyscallCounting` trait, and the count per entry is the number to watch for a regression: the framework's
`.syscalls` metric also counts the allocator and the runtime (113,000 against Disk's 80,000 for 20,000 files).
<!-- src: Disk/RESULTS.md "2026-11-20: the package" "Calls per entry" table, the paragraph "The raw-call probe (single thread, 2,000 files, mode + flags + times)" and "package-benchmark's `.syscalls` …"; the "Kernel semantics checked first" table row on one `fsetattrlist` with `UF_COMPRESSED`; "2026-11-20 (follow-ups)" §3 "`fchflags` for flags alone" (the `.aea` row: 125,890 `fsetattrlist` calls became 112,922 `fchflags` and 12,968 `fsetattrlist`, −12 G instructions, −1.3%) -->

**Contained creation is nearly free.** Every path-taking call carries `O_NOFOLLOW_ANY` and `O_RESOLVE_BENEATH` (or the `AT_`,
`FSOPT_`, and `RENAME_` forms), so an entry cannot escape the destination through a symbolic link or `..`. Measured on
20,000 small files, the default and a build without `O_RESOLVE_BENEATH` read the same (508 and 486 ms against 489 and
489 ms, 21 G instructions each); keeping a descriptor for each directory instead of paths cost nothing at 200 directories
and 3% on Xcode's 30,000 (NativeAEA). What does cost is the quarantine attribute, one `fsetxattr` per entry: 13–17%.
<!-- src: Disk/RESULTS.md "2026-11-20: the package" "Kernel semantics checked first" (the flags) and "Options, interleaved (`ab-1`, `ab-2` …)" table and bullets ("`O_RESOLVE_BENEATH` is free within noise", "Directory descriptors cost nothing measurable here (200 directories); NativeAEA measured +3% on Xcode's 30,000", "The quarantine costs 13–17%") -->

**Width is a measurement, and it is not the core count.** With 24 writers and 20,000 files of 1–8 KB, wall time falls
from 1,491 ms at width 1 to 499 ms at width 6, then rises to 618 ms at 12, while CPU time keeps growing from 1.55 s to
5.47 s: past the peak the extra threads only add contention inside APFS. Disk's defaults are writers equal to the
performance cores and a file-system width of the performance cores divided by 4, clamped to 2 through 6. CPU work
(compressing) runs outside the limiter, which is why more writers than the width help at all (Part III, ["NativeAEA"](#nativeaea-a-decode-pipeline-against-a-file-system)).
<!-- src: Disk/RESULTS.md "Writers and the file-system width" tables (20,000 files, 24 writers: wall 1,491 / 848 / 526 / 499 / 522 / 618 / 612 ms at widths 1 / 2 / 4 / 6 / 8 / 12 / 16, CPU 1.55 to 5.47 s) and "**Chosen:** writers = performance cores (24 here), width = performance cores / 4, from 2 to 6" -->

**Lazy at the right grain.** A one-file extraction made 963 mallocs and took 510 µs, because each of 24 writers allocated
its scratch (output, table, chunk, and staging buffers, encoders) at its first job. Making each buffer when it is first
*used* (a writer of plain files makes none) cut it to 193 mallocs, 2.7 M instructions (from 11 M), and about 190 µs. The
first attempt, lazy only for the writer's core, made the 2,000-file row slower (57, 56, 53 ms against 49, 48, 48 ms
interleaved): 24 writers each mapping 2.3 MB at the start of a 48 ms extraction. The job ring is allocated uninitialized,
slots initialized by `push` and moved out by `pop`, because initializing its 16,384 slots had been 8 M instructions.
<!-- src: Disk/RESULTS.md "2026-11-20 (follow-ups)" §4 "Nothing made that isn't used" (table: "One file: 32 KB | 11 M → 2.7 M | 963 → 193"; "The one-file extraction's wall time went from 510 to about 190 µs"; the paragraph "First, only the core was lazy … 57/56/53 ms against 49/48/48 ms … 24 writers each allocating 2.3 MB"; "initializing 16,384 slots was the 8 M instructions") -->

**Wake the planner at a low-water mark.** A planner waiting for room in the job queue was resumed by every pop, so a full
queue meant a wake-up per file. Now it resumes when the queue is down to half its jobs and half its path bytes and refills
it in one run: with 24 writers and 20,000 files its waits fell from 1,990 to 1, and with one writer the process's context
switches from 4,103 to 96 (and 7,000 fewer syscalls). A small queue then costs the same as the default one.
<!-- src: Disk/RESULTS.md "2026-11-20 (follow-ups)" §5 "The planner woken at a low-water mark" tables ("24 writers (default queue, 16,384 jobs) | 1,990 → 1"; "1 writer … | 4,103 → 96 | 87 K → 80 K") and "so a small queue now costs the same as the default one" -->

**Large files: `pwrite`, in pieces.** For one 1 GB file from memory, a single `pwrite`, 8 MiB `pwrite`s, with `F_PREALLOCATE`, with
`F_NOCACHE`, and `DispatchIO` all took 118–145 ms at best and 156 ms at the median (about 6.9 GB/s into the page cache);
`mmap` plus a copy took 210 and 280 ms and 3.0 G instructions against 0.5 G. `F_NOCACHE` saved 38% of the CPU at no gain in time but
leaves the file out of the cache, which the next reader pays for. A large *compressed* file written whole is compressed
by one writer (1 GB of LZBITMAP: 2.6 s, about 400 MB/s); in pieces, writers compress them in parallel.
<!-- src: Disk/RESULTS.md "macOS APIs for large files (probes: one 1 GB file from memory, p0 / p50 of 3)" table and the paragraphs after it ("All bound by the same rate (about 6.9 GB/s at p50, into the page cache)"; "`F_NOCACHE` saves 38% of the CPU at no gain in time but leaves the file out of the cache"; "1 GB of LZBITMAP 2.6 s (16,384 chunks at about 400 MB/s)") -->

**Progress that costs nothing.** `ExtractionProgress` is polled by a client's timer. Each worker counts in a slot of its own,
one relaxed add per entry (and per piece of a large file), the slot padded to 128 bytes so no two share a cache line, and
reading sums the slots. For 2,000 small files on one writer, 1.912 and 1.966 G instructions without it and 1.939 and
1.907 G with it: no difference beyond the spread. A progress *fraction* has its own trap. By bytes alone, a `.xip`'s hard
links, symbolic links, and directories write no bytes, so the bar sits full while a third of the expansion remains; by
entries alone it stalls on a large file. `read(entryWeight:)` counts each entry as 64 KiB beside the bytes, roughly what
one costs (Xcode's archives: about 30,000 entries a second where contents are written at 1.5 to 2.5 GB a second), and
never returns less than an earlier reading. An app's throughput readout is the counter's gain over the last few ticks of
its poll timer: no clock reads, a sample every tick even when nothing changed (so a stalled rate falls to zero), and a
statement of what the bytes are (here: file contents written, before APFS compression).
<!-- src: Disk/RESULTS.md "Progress (`ExtractionProgress`)" (2,000 files, single writer: "without 1.912 G / 1.966 G instructions … with 1.939 G / 1.907 G"); Disk/Sources/Disk/Progress.swift doc comments (slots padded to 128 bytes; `defaultEntryWeight` 65_536 "Roughly what making one costs (Xcode's archives on an M3 Ultra: about 30,000 entries a second where contents are written at 1.5 to 2.5 GB a second)"; "Bytes alone leave out the work that writes none: a `.xip`'s hard links (a third of Xcode's expansion, during which a bar by bytes sat full)"; "never going back"; AGENTS.md "Throughput in a polled UI is the counter's gain over the last n ticks of the poll timer" for the readout) -->

**One type for each way of touching a file.** `MappedFile` (the archive being read), `InputFile` (reads at offsets, and small
whole files such as keys), and `OutputFile` (one file at the caller's path) replaced three private copies of the same
descriptor loops: NativeZip's `MappedFile` and NativeAEA's `RawMapping` were one type twice, and NativeAEA's decryption to a
file looped over `pwrite` as Disk's `OutputFile` does. `InputFile` opens with `O_CLOEXEC`, takes its size from `fstat`,
`pread`s in a loop with `EINTR` retried and a short read at the end reported as `.endOfFile`, and reads a small file with
`read(2)` to the end so FIFOs and `/dev/stdin` work (a key file given as `/dev/stdin`). Moving the readers changed the data
path's `pread`s not at all; verifying a `pbz` archive went from 23 to 24 `pread`s (the magic-number sniff, once a `read`),
from 2 `lseek`s to none, and from 8 `open`s to 6.
<!-- src: Disk/RESULTS.md "2026-11-22: `InputFile`, the read side" and "2026-11-21: the last cleanup" §2 ("NativeZip's `MappedFile` and NativeAEA's `RawMapping` were one type twice; NativeAEA's decryption to a file opened its output and looped over `pwrite`"); NativeAEA/RESULTS.md "2026-11-22: every format in Swift, every file through Disk" bullet "Every read through Disk" ("`pread` 23 → 24 (the magic sniff, was a `read`), `lseek` 2 → 0, `open` 8 → 6; the data path's reads unchanged") -->

**Matching Archive Utility, item by item.** Nunarchiver has to leave on disk what Archive Utility would, so the comparison
was made with the real tool. Each archive was copied into a directory of its own and given a download's quarantine; Archive
Utility expanded one copy (`open -W -a "Archive Utility"`) and Nunarchiver the other; both trees went through one manifest
tool (path, type, mode, flags, owner, size, modification time to the nanosecond, hard-link group, link target, SHA-256 of the
contents, every extended attribute with its size and SHA-256, and the ACL as text), and `diff` read the difference. What it
showed, none of it written down anywhere before:

- One top-level item is moved out under its own name, several go in a folder named after the archive; the folder is mode
  0700 unless the archive has an entry for its root.
- AppleDouble entries are *merged* into their items, `._NAME` beside the item or under `__MACOSX`: extended attributes
  (directories too), Finder info, the resource fork, and the ACL. Symbolic links get their archived times; ZIP names are
  written decomposed (`Ü` as `U` and U+0308); a ZIP's setuid bit is dropped; everything is quarantined, the folder too,
  except a `.xip`'s contents.
- **An output can be an accident of a tool's pass order, and the decision is whether to copy it.** Archive Utility restores a
  `.xip`'s directory times *before* it writes the files, so writing into a directory resets its time and only directories
  holding nothing but directories keep theirs: 1,877 of Xcode's 30,068. Nunarchiver restores all of them, a documented
  option, and that is the one deliberate difference (28,191 directory times).
- A directory cannot have a resource fork (`fsetxattr("com.apple.ResourceFork")` on one fails with `EPERM`): `ditto` warns
  and goes on, Archive Utility refuses the archive, and Disk leaves it out and sets the entry's other attributes.

Every ZIP, `.aar`, and the Xcode `.aea` then matched in every item. The method has a rule that cost nothing to learn once:
**a GUI tool's failures are dialogs on the user's screen.** Archive Utility's alerts block `open -W` until someone clicks,
nothing in a session without Screen Recording or Accessibility can dismiss them, and its reason is in the log (`log show
--predicate 'process == "ArchiveService"'`: "Main key derivation failed", "Couldn't read the header of the entry"). So run it
only on archives it should accept, add one feature at a time to a known-good one, and never bisect a failing archive by running it
again. Two archives it did refuse (an `.aea` signed without a certificate chain; ZIPs with `._` files that are not AppleDouble) Nunarchiver
expands.
<!-- src: Disk/RESULTS.md "2026-11-21 (later): publishing as Archive Utility does, measured against it" "The comparison" (the method paragraph; "What Archive Utility does, as measured" bullets; "A `.xip`'s directory times are set before the files are written, so only directories holding nothing but directories keep them: 1,877 of Xcode's 30,068 … Nunarchiver restores all 30,068 … the 28,191 where Archive Utility has the extraction's time are the one deliberate difference"; the table "What Archive Utility couldn't expand (each a dialog on the user's screen; none rerun)"); NativeZipArchive/Benchmarks/RESULTS.md "2026-11-21 (later)" last paragraph before the table ("A resource fork for a directory is left out (`setxattr` refuses it with `EPERM` …) Archive Utility refuses an archive with such entries outright"; AGENTS.md "A GUI tool's failures are dialogs on the user's screen" for the log predicate) -->

Merging AppleDouble in NativeZip is done *in the planner*, not in a walk afterwards. One scan of the entry names finds
candidates (a last component starting `._`, 26 bytes to 64 MB), and an archive with none pays only that scan; with
candidates, a table of the archive's files and directories by name pairs each with its item, the entry is decoded, parsed,
and kept as extended-attribute and ACL blobs, and the item is planned with the blobs attached, to be set by Disk's deferred
pass in the file-system lanes. On 2,000 small files each with one attribute (4,001 entries, 2,000 of them AppleDouble),
`nunzip` took 57 ms without the AppleDouble entries and 84 ms with them merged, where `ditto -x -k` took 1,100 ms (hyperfine,
five runs, loaded machine). The same lesson holds for the quarantine: one `fsetxattr` on the open file in the writers beat
a second traversal of the tree on one thread, which had added 0.7 s to an expansion of 0.65 s.
<!-- src: NativeZipArchive/Benchmarks/RESULTS.md "2026-11-21 (later): AppleDouble merged, links' times, decomposed names" "How AppleDouble entries are merged" and the table after "Merging itself, outside the suite (`nunzip`, hyperfine, 5 runs, loaded machine)" (57 ms, 84 ms, 1,100 ms); "2026-11-21: a quarantine option …" paragraph ("walked the tree afterwards on one thread (+0.7 s on an 8,060-entry archive that expanded in 0.65 s)") -->

**Access follows usage.** No package here is stable, so a public symbol is only what another package or the app uses.
Disk's public surface was narrowed by listing its symbols from a symbol graph (`swift build --target Disk -Xswiftc
-emit-symbol-graph …`, then `jq` on `accessLevel`), looking for each name in NativeAEA's, NativeZip's, and the app's
sources, and then letting the compiler judge what a name search could not (initializers, enum cases, and types used only
implicitly: `settings.permissions = .exact` names no type). 26 symbols became `package` (what Disk's own tests and benchmarks
use), 12 `internal`, and one dead method was removed; six types a search marked unused stayed public because clients use
them without naming them. Nothing about the speed changed (the rows moved within their spread), which is the point of doing
it with the compiler as the arbiter.
<!-- src: Disk/RESULTS.md "2026-11-22, late: access by usage, typed timings, one allocation for counters" first bullet ("26 symbols to `package` …, 12 to `internal`, and `Destination.setExtendedAttributes` removed … Six types a name search marked unused stayed public") and its table; AGENTS.md "Access control follows usage, not API stability" and "Narrowing a module's public surface by usage" -->

#### Nunarchiver: the app and its two traps

Nunarchiver replaces Archive Utility for `.zip`, `.aea`, `.aar`, and `.xip`, expanding next to the archive through Disk's
staging and showing a progress window that polls `ExtractionProgress`. Most of its record is interface; two traps are
performance ones, and both made the same code in the app minutes slow where the command-line tool took seconds.

- **A GUI app with no frontmost window runs its work at background quality of service.** Every thread sat at priority 4, on
  the efficiency cores only: Xcode's `.xip` took minutes where `nunarchiver` took 10 s. The fix is two lines: start the work
  in a child task at `.userInitiated` (`withPriority(.userInitiated)`, in [Part II](#counting-time-and-priority)), and hold
  `ProcessInfo.beginActivity([.userInitiated, .idleSystemSleepDisabled], …)` while any expansion runs, which opts out of
  App Nap and idle sleep. `ps -M -p PID` shows the thread priorities.
- **Xcode's autogenerated scheme can instrument Release builds for code coverage, packages included.** The result is a
  counter increment (`adrp`, `ldr`, `add`, `str`) in the codecs' loops, three times as long, and 24 threads sharing the
  counters. `-enableCodeCoverage NO` applies only to `test`, so the project commits a shared scheme with coverage off and its
  build script fails if any built binary has a `__llvm_prf_cnts` section (`otool -l APP | grep __llvm_prf_cnts`). When an
  app is slower than its command-line tool, compare the hot loops with `Tools/loops` on both binaries.
<!-- src: Nunarchiver/Nunarchiver/LiveArchiveExpander.swift comments (the `withPriority(.userInitiated)` call: "a GUI app in the background (no window yet, not frontmost) otherwise ran its writers at background QoS, every thread at priority 4 on the efficiency cores (Xcode's xip: minutes instead of 10 s)"; `beginActivity` with `[.userInitiated, .idleSystemSleepDisabled]`); Nunarchiver/build.sh header comment ("Xcode 27's autogenerated scheme instrumented every target, packages included, in Release too (the codecs' loops 3x longer, Xcode's xip minutes instead of seconds)"; the `__llvm_prf_cnts` check) and Nunarchiver.xcodeproj/xcshareddata/xcschemes/Nunarchiver.xcscheme (`codeCoverageEnabled = "NO"`); AGENTS.md "The Disk package and the Nunarchiver app" bullets (the `counter` instruction sequence; 24 threads sharing counters; `ps -M -p PID`) -->

A new Xcode project's templates set `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which makes every type in the target
main-actor-isolated unless it says otherwise; the project sets it to `nonisolated` (Xcode 27's project file is JSON, so check
each target in the file for one still set to `MainActor`).
<!-- src: Nunarchiver/Nunarchiver.xcodeproj/project.xcproj lines 117, 164, 234 (`"SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated"`); AGENTS.md "New Xcode projects (and targets added to them) turn off the MainActor default" -->

#### BinaryParsingComparison: what porting swift-binary-parsing taught

BinaryParsingComparison ports Apple's `swift-binary-parsing` examples (ELF, PNG, PCAPNG, binary property lists, QOI, LZ4,
an MQTT parser) to Bytes, unchanged in what they build, checks them against the example on every test file, and benchmarks
instruction and malloc counts.<!-- src: OPTIMIZATION-old.md "swift-binary-parsing's examples, ported to Bytes"; BinaryParsingComparison/RESULTS.md -->
The generated code shows why Bytes' field-by-field parsing is about 2x faster than `ParserSpan` (11 against 23 µs for the
zip directory):<!-- src: BinaryParsingComparison/RESULTS.md "Why" -->

1. **Overflow-checked advance** after the bounds check (`adds` + `b.vs` per field): [section 2](#2-remove-the-checks-the-compiler-cannot-prove-away).
2. **Error locations.** Every throw builds a `ParsingError` carrying that site's byte offset, so each failing read has its
   own throw path. The function is 2.6x larger (568 against 220 instructions), and register pressure spills the cursor's
   position to the stack. Bytes' failing reads branch to one shared throw; because a throwing read consumes nothing,
   `reader.byteOffset` after the `catch` is where the failing read started.
3. **Out-of-line slicing.** `sliceSpan(byteCount:)` is generic over `some FixedWidthInteger` and was not inlined: three
   calls per entry, hiding the slice's length from the optimizer. That is why reading the fixed 46-byte header as a slice
   saves `ParserSpan` 29% of instructions and Bytes' sub-cursor 34%.<!-- src: BinaryParsingComparison/RESULTS.md "Why" -->

Other findings. Standard-width integers are identical (both one check and one load; both vectorize). Odd widths (24-bit)
are 2.9x faster in Bytes, 3.3x with `forEach`: `ParserSpan` slices 3 bytes and folds them one at a time (about 17
instructions per value), `Byte3` is two overlapping loads (5.4 per value), and `forEach` turns them into `ld3` (2.9 per
value). Decoders (QOI, LZ4) are about equal for the same algorithm, because the work is the decoding, not the reads. The
published examples are 4–42x slower, for reasons outside the parsing library (a `Data` append per pixel, 706 K allocations
for 10 MB of LZ4).<!-- src: BinaryParsingComparison/RESULTS.md "Why" -->

**The main gap is the byte order, chosen at run time.** ELF and PCAPNG name their byte order in the data, so the example
passes an `Endianness` value to every read. Each field then calls an out-of-line `MultiByteInteger.init(parsing:endianness:)`
(52 instructions: bounds check, load, a swap test on the run-time value) with its own throw path; a section header's
initializer is 277 instructions with 13 such calls. The Bytes port decides once, from the identification record, and calls
a parser generic over the cursor's byte order (`parse<Mode: ByteOrderedCursorMode>`), specialized for each order: a 64-bit
section header is then 87 or 93 instructions.

The cost is per field, so the gap grows with the headers: ratios of the example's instructions to Bytes' were 1.93 for a
352-byte ELF file with 5 headers and 3.24 for swift-help's 65. This is why byte-ordered cursors are types: the order is a
constant by the time the reads compile.<!-- src: OPTIMIZATION-old.md "swift-binary-parsing's examples" "The main gap is the byte order" and table (baseline d2-api2) -->

| Workload | Example (`ParserSpan`) | Bytes | Ratio |
|---|---|---|---|
| ELF, helloworld (352 B, 5 headers), instructions | 7,667 | 3,977 | 1.93 |
| ELF, swift-help (65 headers) | 28 K | 8,647 | 3.24 |
| PNG, antelope.png (4.6 MB, 288 chunks) | 1,410 K | 1,388 K | 1.02 |
| PCAPNG, 1,000 packets | 4,850 K | 4,082 K | 1.19 |
| Property list, 1,000 records | 30.0 M | 25.0 M | 1.20 |
| MQTT PUBLISH, 10,000 packets | 4,198 K | 3,265 K | 1.29 |
<!-- src: OPTIMIZATION-old.md same table (rows selected) -->

The ratio shrinks as the work moves from parsing to allocating and copying (antelope.png is 281 copies of 16 KB). The
smaller differences come from the same kind of out-of-line, per-site code. PNG tracked chunk order in a `Set` (a hash table
allocated and hashed per ancillary chunk) where the port uses a bit mask; BPList read every runtime-width integer through
a byte-at-a-time generic `reduce` where the port does one 8-byte load and a shift.<!-- src: OPTIMIZATION-old.md same -->

**What it turned into API.** Records in the cursor's byte order (`@BinaryRecord()` with no order), `Padding<Byte4>` and
`Reserved<Byte2>` fields, `read(Int64.self, signedByteCount: width)`, `read(utf8TerminatedBy: 0)` (a 16-byte scan),
`forEachRecord(tag:length:paddedTo:)`, throwing counts, `atomically { }` (all-or-nothing reads), and sign-extended odd
widths. Measured with them: ELF's section names −24% (25 to 19 K, the 16-byte scan), swift-help −4.9%.<!-- src: OPTIMIZATION-old.md "What the ports taught about Bytes"; BinaryParsingComparison/RESULTS.md "Adopted into Bytes" -->
It also exposed a caveat of Bytes' own: a QOI port that captured its cursors in closures passed to `[UInt8](capacity:)`
slowed both libraries, and Bytes more, because its bit offset and bit order, in memory, were re-checked by every byte read
([section 1](#1-keep-hot-state-in-registers)).<!-- src: BinaryParsingComparison/RESULTS.md "A Bytes caveat this exposed" -->
What swift-binary-parsing could take from Bytes, per the comparison: advance with `&+=` after the bounds check, make
`sliceSpan(byteCount: Int)` non-generic so slices inline, read odd widths from overlapping loads, and share a throw path.<!-- src: BinaryParsingComparison/RESULTS.md "What swift-binary-parsing could take from Bytes" -->

### 12. Case study: HTTPBytes

The sections so far take a technique and show where it paid. This one runs the other way: a new protocol family, from
nothing, using only what Bytes already offers, and what each step of that work taught. `HTTPBytes` is HTTP/1.1, HTTP/2,
and HTTP/3 framing, HPACK and QPACK field compression, Structured Field Values, and content codings (gzip, deflate,
Brotli, Zstandard), in six library products of about 16,900 lines, with 264 tests in about 8,600 more (round 1 ended at 13,300
lines and 207 tests; the second round is described after the first). It has no NIO, no C, and no Foundation, and every
per-message path allocates nothing after setup.<!-- src: HTTPBytes/WRITEUP.md "What's in the package" (after round 2: about 16,900 lines, 264 tests in about 8,600 lines; "round 1 ended at 13,300 lines and 207 tests"; no NIO, no C, no Foundation in the library); HTTPBytes/Benchmarks baseline final-1, every `Allocations:` row: Malloc (total) 0 except Body_chunked_gzip (see "Content codings" below) -->

**Every number in this section is from an Apple M1 Max** (8 performance and 2 efficiency cores, macOS 27.2, Swift 6.4
from Xcode 27.3), not the M3 Ultra of the rest of the document: the work was done on that machine. Its one core runs
about 1.3x slower than an M3 Ultra core ([section 13](#13-measuring-honestly) gives the comparison), so compare the
ratios against the references, which were measured on the same machine in the same run, not the absolute times.
Benchmarks are in their own package (`HTTPBytes/Benchmarks`), so the library never builds the C references. The saved
baseline is `final-1`; the step-by-step record is `HTTPBytes/RESULTS.md`. Round 2's baselines are `r2-qpack-before` and
`r2-qpack-after`, `r2-fields-1` and `r2-fields-3`, and `r2-payload-1`. The one set of numbers in this section from the other
machine is the Zstandard encoder's comparison with libzstd, which was measured on the M3 Ultra and is in
[section 8](#zstandard-encoding).<!-- src: HTTPBytes/RESULTS.md round 2 sections (baselines r2-qpack-before, r2-qpack-after, r2-fields-1, r2-fields-3, r2-payload-1); Bytes/Benchmarks/RESULTS-zstd-encoder.md header (M3 Ultra); HTTPBytes/RESULTS.md header (M1 Max, 8 performance and 2 efficiency cores, macOS 27.2, Swift 6.4 / Xcode 27.3; "Benchmarks are in their own package"); HTTPBytes/WRITEUP.md header (baseline final-1); Bytes/OPTIMIZATION.md "The second machine" (M1 Max core 1.31x as long as an M3 Ultra core) -->

The references are the C parsers and compressors people actually use, built the same way as the Swift code (`-O3`,
`NDEBUG`, from pinned sources): **picohttpparser** and **llhttp** for HTTP/1, **cursed-http** (a C library that uses the
design below and claims to beat picohttpparser everywhere), **ls-hpack** and **ls-qpack** for field compression, and, in
Swift, **NIOHPACK**, **swift-http-types**, and **swift-http-structured-headers**. The corpora are real: 401 request
heads (580 bytes on average) and 383 response heads (953 bytes) taken from HTTP/3 traffic, and cursed-http's 3,533
requests and 2,054 responses from a browser loading the top 1,000 sites.<!-- src: HTTPBytes/RESULTS.md header (corpus: 401 requests, 580 B average; 383 responses, 953 B average) and "2026-11-23: HTTP/1 heads against cursed-http" (top-1k: 3,533 requests, 2,054 response heads); HTTPBytes/WRITEUP.md "How it was measured" (references built the same way) -->

#### Prototype the scanning strategy before the API

A parser's speed is decided by how it finds delimiters, and that decision is expensive to reverse once an API sits on
it. So three throwaway parsers ran on the 401 real request heads first, measured with the processor's own instruction
and cycle counters (`proc_pid_rusage`):<!-- src: HTTPBytes/RESULTS.md "The design, from three prototypes (PLAN.md, phase 0.5)" -->

| Strategy | ns per head | instructions per byte | cycles per byte |
|---|---|---|---|
| A. Scan each line for its delimiters (16-byte `firstByteOffset` tests) | 168 | **2.62** | 0.93 |
| B. **Structural index**: classify 64-byte blocks into bitmasks once, walk them with `ctz` | **112** | 3.18 | **0.62** |
| picohttpparser (scalar on ARM: its fast path is SSE4.2) | 225 | 7.81 | 1.23 |
| llhttp (a generated state machine) | 220 | 6.55 | 1.20 |
<!-- src: HTTPBytes/RESULTS.md "The design, from three prototypes" table (rows A, B, picohttpparser, llhttp); same numbers in HTTPBytes/PLAN.md "Phase 0.5" Result -->

A ran 18% fewer instructions than B (2.62 against 3.18) and 50% more cycles (0.93 against 0.62). The reason is
[branch misprediction](#15-branches-prediction-and-mispredicts). Header lines are 15 to 40 bytes, and a scan of that
length exits at a different place on each line, so the scan's exit branch mispredicts. B turns "where
does this line end" into a bit scan of a mask that was built without any data-dependent branch, so the work that
varies, finding the next set bit, is a `ctz`, not a loop. A judge that counted instructions would have picked the
wrong design; this is [section 7](#7-branches-and-data-dependent-work)'s rule (judge by cycles) applied before there was
any code to regret.<!-- src: HTTPBytes/RESULTS.md "The design, from three prototypes" ("A runs fewer instructions and more cycles: its many short scans (header lines are 15–40 bytes) mispredict"); the 18% and 50% are 2.62/3.18 and 0.93/0.62 from the table above -->

The prototype also settled something that was not a speed question: B keeps only the current block's masks, because the
walk only moves forward. A parser that holds offsets and one 64-byte mask needs no memory per message, and can stop
anywhere and resume, which made the streaming API (events for the request line, each field, and the head's end)
free.<!-- src: HTTPBytes/RESULTS.md "A field line is then…" ("The walk only moves forward, so the parser keeps the current block's masks, not an index: no memory per head"); HTTPBytes/WRITEUP.md "API shape" (streaming events) -->

#### The structural index, walked with `ctz`

A **structural index** (simdjson's idea) is a set of bitmasks, one bit per input byte, marking the bytes that matter: the
delimiters. Classify 64 bytes at once into a 64-bit mask, and every question about those bytes becomes integer
arithmetic on one register. For an HTTP head two masks suffice:

- **stops**: control characters (a tab included) and DEL. A field value ends at the first stop, which must be CR then LF.
- **non-token bytes**: the first one in a field name must be the colon, so the name needs no other check.

A field line is then two bit scans. Here is the walk's core, simplified from `HeadScanner.nextStop(_:from:)`; the mask is
shifted so that bit 0 is the line's first byte, and the first set bit is the line's end:

```swift
// Simplified from HTTPBytes' HeadScanner.nextStop. `stops` is the current 64-byte block's mask: bit i = byte blockStart + i.
let bits = stops &>> UInt64(start & 63)                       // the line starts at bit 0
if bits != 0 { return start &+ bits.trailingZeroBitCount }     // the line's end: no loop, no per-byte branch
// A line that runs past its block takes a loop of its own, out of line (farStop).
```
<!-- src: HTTPBytes/Sources/HTTP1/HeadScanner.swift nextStop(_:from:) (simplified: the block bookkeeping and the clamp to the byte count are left out) -->

Swift's SIMD cannot express the 64-byte movemask this needs: NEON has no `pmovmskb`, and the equivalent is a reduction
tree. So Bytes gained [`ByteBlock`](#byteblock-64-bytes-tested-into-one-mask) (Part II, section 7), with the reduction
in the `CBytesNEON` C module and a portable fallback. Here is the loop that finds the end of a line crossing block
boundaries (`farStop`), from the release object, with a comment on each group of lines:

```asm
farStop loop:                         ; one 64-byte block per iteration; 29 instructions
    tbnz   x2, #0x3f, <L8>            ; the `byteBlock` precondition (offset >= 0): never taken here
    add    x8, x0, x2                 ; the block's address
    ldp    q3, q4, [x8]               ; bytes 0-31 (two 16-byte loads in one instruction)
    ldp    q5, q6, [x8, #0x20]        ; bytes 32-63
    cmhi.16b v7, v0, v3               ; the test: byte < 0x20 (v0 holds 0x20 in every lane) ...
    cmeq.16b v3, v3, v1               ; ... or byte == 0x7F (v1 holds 0x7F) ...
    orr.16b  v3, v7, v3               ; ... three instructions per 16 bytes, twelve in all
    ...                               ; the same three for q4, q5, q6
    and.16b  v3, v3, v2               ; AND each lane with its bit weight (1, 2, 4 ... 128, twice per vector)
    ...                               ; four of these, one per vector
    addp.16b v3, v3, v4               ; pairwise adds sum the weighted lanes: three rounds
    addp.16b v4, v5, v6               ;   (a lane's bit lands in its byte position)
    addp.16b v3, v3, v4
    addp.16b v3, v3, v3
    fmov   x8, d3                     ; the 64-bit mask, in a general register
    cbnz   x8, <L3>                   ; any stop in the block? then done
    add    x2, x2, #0x40              ; next block
    cmp    x9, x2
    b.ge   <L0>
```
<!-- src: Tools/loops HTTPBytes/.build/agent-tools/HTTP1.o 'farStop' --body (release object, 2026-11-23; 29 instructions, depth 0, vector128: 4 addp.16b, 4 and.16b, 4 cmeq.16b, 4 cmhi.16b, 4 orr.16b, 2 add, 2 ldp, 1 b.ge, 1 cbnz, 1 cmp, 1 fmov, 1 tbnz; listing abbreviated by repeating-groups); the test's 12 vector operations per 64 bytes: HTTPBytes/Sources/HTTPBytes/Method.swift controlOrDelete doc ("On 64-byte blocks, 12 vector operations instead of 20") -->

Sixty-four bytes of classification take 12 vector instructions, the reduction 8 more and a move: 21 instructions, a third of
an instruction per byte, with no branch until the answer is known.<!-- src: the farStop listing above: 4 cmhi + 4 cmeq + 4 orr = 12, 4 and + 4 addp = 8, 1 fmov; 21 divided by 64 bytes = 0.33 -->

#### From the prototype to a library: inlining, memory, unchecked loads

The first library version, with events and a field-name lookup per field, ran 1.12 cycles a byte against the
prototype's 0.62. The algorithm was the same; the gap was the compiler's treatment of the code, which is
[section 1](#1-keep-hot-state-in-registers) and [section 5](#5-inlining-and-specialization) again:

| Change | ns per head | instructions per byte | cycles per byte |
|---|---|---|---|
| First library version (events, name lookup per field) | 202 | 6.69 | 1.12 |
| Scanner `next` and `fieldLine` `@inline(always)` (they were calls) | 202 | 5.78 | 1.09 |
| *(lookup switched off, to measure it)* | 187 | 4.73 | 1.00 |
| `next(in:)` `@inline(always)` into the caller's loop | 180 | 3.88 | 0.96 |
| Mask building a **static function returning values** | 153 | 3.71 | 0.84 |
| Unchecked byte loads where the offset is proven in range | 150 | 3.43 | 0.80 |
| *(lookup back on)* | 165 | 4.51 | 0.88 |
| Field-name hash on two 8-byte words | 157 | 4.17 | 0.84 |
<!-- src: HTTPBytes/RESULTS.md "Getting the library to the prototype's speed" table (all eight rows, in order; rows 3 to 6 were measured with the name lookup off, so the 1.12 and 0.84 endpoints are the two with it on) -->

The largest single step is the mask builder. As an out-of-line `mutating` method it made the whole scanner (its block
offset, mask, and limits) live in memory for the entire parse loop. As a `static` function taking the bytes and returning
the mask, the scanner stays in registers: 0.96 to 0.84 cycles a byte. Forcing that function itself inline made it worse
(0.98), because the `mutating` wrapper around it was then what stayed out of line. This is the lesson of
[section 1](#1-keep-hot-state-in-registers) again: a call that can mutate a struct's state makes the compiler keep that struct in memory.<!-- src: HTTPBytes/RESULTS.md same table rows 4 and 5, and "Forcing the mask builder itself inline made it worse (0.98): the mutating wrapper around it was then left out of line" -->

#### Seven steps past cursed-http

With the library at 0.84 cycles a byte (picohttpparser: 1.23), the target became cursed-http, a C
parser on the same design. Its README claims it beats picohttpparser everywhere. It parsed the request corpus in 275
cycles a head; HTTPBytes was at 491. Seven steps, measured in cycles per head with instruction counts beside the ones
that matter (`req`: 401 requests; `resp`: 383 responses; `tiny`: 38-byte requests; `f1` and `f128`: 20 fields of 1 or
128 bytes):<!-- src: HTTPBytes/RESULTS.md "2026-11-23: HTTP/1 heads against cursed-http (baseline http1-opt)" step table: Start row (req 491), cursed-http row (req 275); cursed-http's README claim: same section, first paragraph -->

| Step | req | resp | tiny | f1 | f128 |
|---|---|---|---|---|---|
| Start | 491 (2,407 instr.) | 807 | 107 | 774 | 1,714 |
| 1. Walk reorganized: find a line's end first; the name from one 16-byte nibble mask; methods and `HTTP/1.x` as word compares | 367 | 643 | 68 | 563 | 1,355 |
| 2. Exact (slow) paths take and return values; the walk inlined | 333 | 590 | 61 | 495 | 1,221 |
| 3. Known names looked up only when asked | 335 | 529 | 62 | 520 | 1,363 |
| 4. The target scan moved out of line | 306 | – | 55 | 429 | – |
| 5. Line stops are just controls or DEL | 279 | 447 | 55 | 406 | 913 |
| 6. The target scan also builds the first block's stop mask | 274 | 448 | 50 | 366 | 912 |
| 7. Masks from four plain loads, not `ld4` | **258** | **426** | **52** | **365** | **788** |
| cursed-http | 275 | 366 | 47 | 353 | 1,028 |
| picohttpparser | 711 | 1,055 | 62 | 651 | 2,590 |
<!-- src: HTTPBytes/RESULTS.md "2026-11-23: HTTP/1 heads against cursed-http" step table, rows Start, 1 to 7, cursed-http, picohttpparser (columns req, resp, tiny, f1, f128; the instruction count in the Start row is the table's (2,407)); step descriptions condensed from the same rows -->

What each step was, in terms the earlier sections taught:

1. **Reorder the work so lines overlap.** Find the line's end first, from the stop mask, then parse the name and value
   inside it. The next line's start then depends only on the masks, not on this line's name and value, so
   consecutive lines overlap in the out-of-order window ([section 7](#7-branches-and-data-dependent-work)'s "break the
   chain"). The common cases are single compares: `GET `, `PUT `, `POST`, `HEAD`, and `HTTP/1.x` CR LF are 4- and 8-byte
   word compares; anything unusual goes to an exact, stateless function out of line.
2. **Slow paths take and return values.** Every piece left out of line as a `mutating` method had kept the parser in
   memory (the same trap, again).
5. **A line stop is a control or DEL**: two compares and an OR (12 vector operations for 64 bytes, instead of 20 for
   "controls except tab"). A tab, which a value may contain, is rare, so it is checked where the walk stops, not
   classified.
7. **Pack the masks with plain loads and pairwise adds.** cursed-http loads 64 bytes with `ld4` and packs the mask with
   shift-right-inserts: 5 instructions, 5% fewer than the `addp` tree. Here it ran 5 to 16% more cycles. The mask is on the
   walk's critical path (each block's mask gates the next line), and `ld4` delivers 64 bytes in 2 cycles against 1.33 for
   four plain loads (`Tools/cpu-probe insn ld4`), with more latency. Fewer instructions, slower: the same shape as
   the per-line scans.<!-- src: HTTPBytes/RESULTS.md "What was kept and why" bullet "ByteBlock stays in byte order (Bytes)" ("5% fewer instructions and 5–16% more cycles"; "ld4 loads 64 bytes in 2 cycles against 1.33 for four plain loads (Tools/cpu-probe insn ld4, new rows)") and step 5's description in the step table -->

Where it ended, in cycles per head, with the same inputs for every parser:

| Corpus | HTTPBytes | cursed-http | picohttpparser | llhttp |
|---|---|---|---|---|
| 401 requests (580 B) | **258** | 275 | 711 | 698 |
| 383 responses (953 B) | 426 | **366** | 1,055 | 1,058 |
| top-1k requests (1,162 B) | **665** | 724 | 1,579 | 1,566 |
| top-1k responses (2,004 B) | 1,028 | **912** | 2,447 | 2,128 |
| 20 fields of 128 B | **788** | 1,028 | 2,590 | 1,525 |
| tiny requests (38 B) | 52 | **47** | 62 | 158 |
<!-- src: HTTPBytes/RESULTS.md "2026-11-23: HTTP/1 heads against cursed-http" "Final, per head (ns, cycles)" table, cycle halves of rows 401 requests, 383 responses, top-1k requests, top-1k responses, 20 fields of 128 B, tiny requests (38 B) -->

HTTPBytes is 2.1 to 2.8x as fast as picohttpparser and llhttp on every real corpus, and ahead of cursed-http on requests
(6% on the 401 requests, 8% on top-1k) and on long fields (23% at 128 bytes). It is behind on responses (13 to 16% more cycles; 16 to 18% more time).
CPU Counters say why: 42% of HTTPBytes' cycles on top-1k responses are discarded work against cursed-http's 33%, and
57% of those heads' bytes sit in lines of 256 bytes or more. cursed-http's response parser classifies four blocks ahead,
so a line that crosses blocks takes no branch. HTTPBytes built two batched versions of its own, and both cost more than they
saved, as the next table shows.<!-- src: HTTPBytes/RESULTS.md same section, paragraph after "The benchmark package" table ("HTTPBytes is 2.1–2.8x as fast as picohttpparser and llhttp on every real corpus … ahead of cursed-http on requests (6% on http-corpus, 8% on top-1k) and long fields (23% at 128 B) … behind it on responses (14–17%)"; this section uses the recomputed figures: cycles 426/366 and 1,028/912 (+16%, +13%), final-1 times 53/45 and 682/587 (+18%, +16%); "42% of HTTPBytes' cycles on top-1k responses in discarded work against cursed-http's 33%"; "57% of those heads' bytes are in lines of 256 bytes or more") -->

**Measured and rejected** (cycles per head; each was built, measured, and removed):

| Idea | Effect |
|---|---|
| Stop masks for 5 blocks at a time, a 64-bit window across two (cursed-http's response idea) | req 279 → 312; tiny 55 → 86; f128 913 → 1,382 |
| A ring of 8 blocks' masks, 4 tested ahead | req 279 → 350; f128 913 → 1,414 |
| The first 32 bytes of a name without a branch on which half ends it | f1 365 → 388; f128 788 → 913 |
| The stop-mask builder inlined into the walk | req 333 → 347 (the loop's size again) |
<!-- src: HTTPBytes/RESULTS.md "Tried and not kept (cycles per head)" table, rows 1, 2, 3, 4 -->

The batched versions classify blocks past a short head's end and test long lines again: cost paid by every head, benefit
only for long lines. A technique from a library that wins on its own corpus is a hypothesis about yours.

#### The inliner's caller limit

Step 4 deserves its own paragraph, because the cause generalizes. With every per-field function `@inline(always)`, the
parse loop grew past the **SIL performance inliner's caller limit**: once a function is large enough, the inliner stops
inlining anything into it, including functions that are trivially cheap. `RawSpan.byteCount`, a two-instruction getter,
stayed a call, three times per field, and each call clobbered the vector registers that held the name scan's tables. Moving
the once-per-head target scan (a block-mask loop and its partial-block cases) out of line brought the loop back under the
limit: request heads 335 to 306 cycles, 1-byte fields 520 to 429.<!-- src: HTTPBytes/RESULTS.md step table rows 3 and 4 (req 335 → 306, f1 520 → 429; instruction counts 1,584 → 1,308 for req), and "The inliner's limit is worth knowing beyond this parser" paragraph; note the prose there says −5% and −16%, the table's own rows give −9% and −18% -->
After forcing inlining into a hot function, look at its disassembly for a `bl` to a trivial getter (or `Tools/calls` with
`--callee` for the getter's name). The fix is the opposite of the force: take the rare or once-per-call part out of the loop.

#### Field names: look up lazily, hash two words

About 120 field names are well known (every name in the HPACK and QPACK static tables, the pseudo-headers, and the
common others), and a parser that knows which one it has can compare an index instead of bytes. The first design looked
every name up while parsing. That cost 300 to 400 instructions per request head, a fifth of the parse, for callers
that never ask. Now the parsed view carries the name's bytes and a "not looked up" marker, and `knownName` does the lookup when
read. A caller who reads it for every field pays 44 cycles a head (258 to 302 cycles on the request corpus); one who does
not pays nothing.<!-- src: HTTPBytes/RESULTS.md "What was kept and why" first bullet ("Looking every name up while parsing cost 300–400 instructions a request head, a fifth of the parse"; "reading knownName for every field now costs 44 cycles a head (http-corpus requests; 162 on top-1k requests)") and "Final, per head" table (401 requests: 258 and known names 302); HTTPBytes/Benchmarks final-1 rows "HTTP/1 request heads (401 requests, 232 KB)": HTTPBytes 492 K instr., known names 650 K -->

The lookup is a **perfect hash**: a hash function chosen, by a generator, so that no two of the known names share a slot,
and a lookup is one hash, one table load, and a comparison, with no probing. The key is the name's length and two
8-byte words taken from fixed offsets (the first and last 8 bytes, overlapping below 16; the first and last 4 for names
of 4 to 7 bytes), each ORed with `0x20` to fold case. Case folding by `| 0x20` is exact for token characters (letters
change case; digits, `-`, and the rest already have the bit set), which a parsed name always is. The slot holds the
name's two words precomputed, so the comparison is two XORs and an OR, and the length is checked in the same test.<!-- src: HTTPBytes/Sources/HTTPBytes/FieldName.swift init?(caseInsensitive:) doc comment and `words(_:)`, `lookUp(_:)` -->

Two details cost real cycles. First, the loads. A first version chose the load pattern with a branch on the length class
(1 to 3, 4 to 7, 8 and more bytes), and `Host`, `Accept`, and `Connection` alternate between the classes, so the branch
mispredicted whenever consecutive names changed class: 38 cycles a head. Four 4-byte loads at selected offsets, paired by a
select, are branch-free ([section 7](#7-branches-and-data-dependent-work)'s "do not branch on what the data decides").
Second, the tables are generated Swift literals (so they are statically initialized, with no `swift_once`), and the
names' bytes that spans must reference forever are `StaticString` literals. A `static let` `InlineArray` looked
equivalent, but reading it may produce a temporary copy, and a span overridden to be immortal then points at dead stack:
the last names read as garbage until a test caught it.<!-- src: HTTPBytes/RESULTS.md "The lookup's words without branches" bullet (38 cycles a head: 367 against 329 without); HTTPBytes/Sources/HTTPBytes/FieldName.swift `words(_:)` doc comment; AGENTS.md "HTTPBytes as a whole" bullet "A static let InlineArray can't back an immortal span" -->

An owned `HTTPFieldStore` keeps each field's known-name index next to its offsets, so finding a header by name is a scan of
one-byte indexes, 16 lanes at a time. Three thousand lookups take 8.1 µs, 172 K instructions, against 634 µs and 10 M
for swift-http-types' `HTTPFields`.<!-- src: HTTPBytes/Benchmarks baseline final-1 rows "Fields: 3,000 lookups by name: HTTPBytes HTTPFieldStore" (Time 8.127 µs, Instructions 172,000) and ": swift-http-types HTTPFields" (634 µs, 10,000,000) -->

#### HPACK: a multi-symbol Huffman table, contiguous tables, cached validation

HPACK (RFC 7541) compresses HTTP/2 fields with a static table, a dynamic table of recently seen fields, and a Huffman
code for strings. Two thirds of decoding is the Huffman loop.<!-- src: HTTPBytes/RESULTS.md "2026-11-23: HPACK" "Profile of the decoder (requests): the Huffman loop 66% of samples" -->

- **A 14-bit multi-symbol table.** A second prototype race (nghttp2's 4-bit state machine, ls-hpack's 16-bit
  multi-symbol table, a 10- to 12-bit table with a second level) chose a 16,384-entry table of 32-bit entries, where an
  entry decodes one or two symbols; a code longer than 14 bits is decoded canonically, out of line. The input is read as if it continued with ones forever:
  EOS's prefix is ones, so the last symbols need no separate path and the loop has no end-of-input test. NUL, CR, and LF
  are flagged in bit 24 of an entry and ORed as the loop runs, so the decoded value needs no second scan for the bytes
  HTTP forbids.<!-- src: HTTPBytes/Sources/HTTPBytes/Huffman/HPACKHuffman.swift header comment (14-bit multi-symbol table, 16,384 UInt32 entries, up to 2 symbols an entry, input read as ones, codes longer than 14 bits decoded canonically out of line) and forbiddenFlag; HTTPBytes/PLAN.md "Phase 0.5" item 2 (the three candidates); HTTPBytes/RESULTS.md HPACK section ("NUL, LF, CR flagged by the Huffman table (bit 24 of an entry, ORed per lookup: cursed-http's idea)") -->
- **Contiguous, insertion-numbered tables.** The dynamic table keeps its entries in a byte store twice its size; an entry
  that would straddle the end goes to the start, so every entry is one span. Entries are numbered by insertion, so
  nothing is renumbered when the oldest is evicted. The encoder finds entries through two hash chains (name and value;
  name alone) linked by insertion number: a chain ends at the first number older than the oldest live entry, so an
  eviction costs nothing and nothing walks a stale chain.<!-- src: HTTPBytes/RESULTS.md HPACK section "Design notes" (dynamic tables keep entries contiguous in a byte store twice the table's size … entries numbered by insertion … two hash chains … a chain ends at the first number older than the oldest entry) -->
- **Static entries by address, in the coder's own memory.** Reaching the generated static tables and `lowercaseBytes`
  from another module had been a call per field (`Tools/calls` showed it): the coder now holds pointers. Decoding 1,124 K
  to 992 K instructions for the 401 requests (−12%), encoding 1,980 K to 1,615 K (−18%).<!-- src: HTTPBytes/RESULTS.md HPACK "What it took" table rows "First version" (decode 1,124 K, encode 1,980 K) and "Static table entries as addresses in coder-owned memory" (992 K, 1,615 K) -->
- **Validation is cached, not repeated.** Checking a field's characters once per literal and storing the verdict with the
  dynamic entry took validation's cost from 43% of decoding to 8% (decoding and validating the responses, 2,408 K to
  1,974 K).<!-- src: HTTPBytes/RESULTS.md HPACK "What it took" table row 3 ("decoding and validating the responses: 1,974 K, against 2,408 K before, when validation added 43% to decoding; now 8%") -->

Against the others on the 401 requests (`final-1`: HTTPBytes 1,113 K instructions to decode and 1,708 K to encode, cursed-http 1,558 K and 2,978 K, ls-hpack 2,150 K and 3,281 K, NIOHPACK 5,796 K and 19 M), decoding runs 28 to 30% fewer instructions than cursed-http; encoding is 2.5 to 2.7x as fast as cursed-http and 14 to
16x as fast as NIOHPACK. ls-hpack allocates 139 to 2,933 times per row and NIOHPACK 1,102 to 2,416 per decoding row;
HTTPBytes allocates nothing. Part of the encoder's lead is policy, which the table hides: it follows nghttp2's (leave
`:path`, `content-length`, and date-like fields out of the table; never index short cookies and credentials), so its
requests come out 15% smaller than ls-hpack's and NIOHPACK's, which index everything.<!-- src: HTTPBytes/WRITEUP.md "HPACK" and "Results at a glance" bullets (28–30% fewer instructions; 2.5–2.7x cursed-http, 14–16x NIOHPACK), checked against HTTPBytes/Benchmarks baseline final-1 rows "HPACK decode (401 requests)", "HPACK decode (383 responses)", "HPACK encode (401 requests)", "HPACK encode (383 responses)" for HTTPBytes, cursed-http, ls-hpack, NIOHPACK (Instructions and Time (wall clock); e.g. encode 401: 244/89 = 2.7, 1,422/89 = 16); HTTPBytes/RESULTS.md HPACK table (ls-hpack 937–2,933 and 139–1,565 mallocs per row, NIOHPACK 1,102–2,416) and "The encoders' indexing policies differ" paragraph (51,813 B against 61,097 B for the requests) -->

#### QPACK: share the core, let the caller hold the blocked streams

QPACK (RFC 9204) is HPACK redesigned for HTTP/3, where streams can arrive out of order: a field section can reference a
table entry that has not arrived yet, so the decoder can have a stream **blocked**. Three decisions mattered.

**One table design for both.** HPACK's dynamic table, static entries, hash chains, and validator moved into the core
module and serve QPACK too; QPACK's absolute index is the insertion number, which HPACK's table already was. HPACK
measured within 0.4% after the move on every row but one.<!-- src: HTTPBytes/RESULTS.md QPACK "Design notes" first bullet ("Shared with HPACK, moved to the core … QPACK's absolute index is the insertion number … within ±0.4% on every row but decode-and-validate of the requests, +2.0%") -->

**Blocked streams are held by the caller, not copied.** `begin(_:stream:)` returns `false` for a section whose Required
Insert Count is past the inserts received, and records the stream (two words each, up to the blocked-streams setting).
`nextUnblockedStream()` names it once the encoder stream catches up. RFC 9204 forbids releasing a blocked request stream's
flow control, so its bytes are still in the caller's receive buffer, and a pool of held sections would be a second
copy of them. Design the API around who already owns the bytes.<!-- src: HTTPBytes/RESULTS.md QPACK "Blocked streams are held by the caller, not copied" bullet; HTTPBytes/Sources/HTTP3/QPACKDecoder.swift doc comment (begin(_:stream:), nextUnblockedStream()) -->

**Insert on the second sighting.** In HPACK an insertion is free: the literal carries the value once either way. In
QPACK the value also goes on the encoder stream, so inserting a one-off response value costs bytes and can evict an entry
that would have been used. Inserting a field only the second time it is seen (ls-qpack's idea, a direct-mapped history of
field hashes) made 383 responses 16% smaller (74,097 to 62,241 bytes) at the cost of 4% on requests (52,874 to
55,074), where the first sighting of a repeated field is now a literal.<!-- src: HTTPBytes/RESULTS.md QPACK "The encoder's automatic policy is HPACK's … plus one rule" paragraph (383 responses 74,097 → 62,241 B (−16%), 401 requests 52,874 → 55,074 B (+4%)) -->

**A heap box found by a zero-malloc gate.** The QPACK malloc gate failed: one allocation per literal field. The code in
question named a field's name pointer in one of several branches and borrowed it with a span afterwards:

```swift
// The shape that was boxed (illustrative): a `var` assigned in branches, then borrowed by a span.
var name: UnsafeRawPointer
if nameReference == 3 { name = decodedString.address } else { name = entry.name }
let span = RawSpan(_unsafeStart: name, byteCount: nameCount)     // the borrow makes `name` a heap box
```

Written as constants set once on every path (the real code, after the fix), the box disappeared:

```swift
// HTTPBytes QPACKDecoder.literal: "Constants set once on every path: a `var` assigned in branches and borrowed by a span
// was heap-boxed (a `swift_allocObject` per literal)".
let name: UnsafeRawPointer
let nameCount: Int
if nameReference == 3 { unsafe name = address; nameCount = string.count /* … */ } else { /* … */ unsafe name = entry.name }
```

Static-table decoding of the 401 requests went from 5,190 K to 2,505 K instructions (−52%), and with the literal step
forced inline, 2,333 K. NativeAEA had met the same box in `SegmentStream` ([Technique 9](#technique-9-a-var-pointer-borrowed-by-spans-is-heap-boxed) of section 6, one per segment), and the lesson was already
in AGENTS.md; it was met again because the gate, not memory, is what catches it.
Before the box was found, a head-to-head of the Huffman decoders on the corpus' 9,502 strings had HTTPBytes at 282 µs a
pass against cursed-http's 454, which told the author the gap was elsewhere: measure the parts before blaming the
obvious one.<!-- src: HTTPBytes/RESULTS.md QPACK "What moved the numbers" table (static: first version 5,190 K; literal step as lets 2,505 K; @inline(always) 2,333 K) and the paragraph "Before the box was found, a head-to-head of the Huffman decoders on the corpus' 9,502 strings (a throwaway driver) showed HTTPBytes' at 282 µs a pass against cursed-http's hh_decode_f at 454"; HTTPBytes/Sources/HTTP3/QPACKDecoder.swift literal(...) lines 660–668 (the real constants); AGENTS.md "HTTPBytes as a whole" bullet "A var pointer assigned in branches and borrowed by a span is heap-boxed again"; NativeAEA/RESULTS.md SegmentStream box -->

Encoding with a table is 7.0 to 8.3x as fast as ls-qpack (401 requests: 107 µs, 2,089 K instructions against 751 µs, 9,273 K), and decoding 1.4x as fast as cursed-http in time (120 µs against 171). At `final-1` ls-qpack still compressed responses 15% better (it uses Duplicate
instructions and a draining index, which this encoder lacked then; [round 2](#round-2-qpack-at-ls-qpacks-size) added them).<!-- src: HTTPBytes/Benchmarks baseline final-1 rows "QPACK encode (401 requests, 4,096 table)" (HTTPBytes 107 µs, 2,089 K; ls-qpack 751 µs, 9,273 K), "QPACK encode (383 responses, 4,096 table)" (142 µs; ls-qpack 1,180), "QPACK decode (401 requests, 4,096 table)" (120 µs; cursed-http 171); ratios 751/107 = 7.0, 1,180/142 = 8.3, 171/120 = 1.4; HTTPBytes/RESULTS.md QPACK "ls-qpack still compresses responses 15% better" -->

#### Structured Fields as iterators

RFC 9651's Structured Field Values (the format of `Priority`, `Cache-Status`, and many new headers) are normally parsed
into a value tree: a dictionary of items, parameters, and inner lists, each a Swift value with its own storage. HTTPBytes
walks the bytes instead. `HTTPStructuredDictionary` and `HTTPStructuredList` are `~Escapable` iterators whose `next()`
parses and validates one member and returns it as a view: strings and byte sequences as spans (unescaped or
Base64-decoded on request), integers and decimals as values. Nothing is built, so nothing is allocated, and a caller who
wants only one key reads to it and stops (`lastValue(forKey:)`).<!-- src: HTTPBytes/Sources/HTTPBytes/StructuredFields.swift HTTPStructuredDictionary (next(), lastValue(forKey:), ~Escapable) and HTTPStructuredList; HTTPBytes/WRITEUP.md "Structured Fields and Priority" -->

```swift
var dictionary = HTTPStructuredDictionary(fieldValue)
while let member = try dictionary.next() { … member.key, member.value … }   // views of fieldValue's bytes
```

Parsing 1,000 seven-member dictionaries takes 196 µs and 3.7 M instructions, against swift-http-structured-headers'
22,000 µs and 368 M (112x, with 208,000 mallocs); 1,000 five-member lists 137 µs against 14,000; 1,000 `Priority`
fields 23 µs against 3,011 (131x). All 1,607 parse cases and 553 serialization cases of the httpwg suite pass. The
general lesson is [section 11](#11-techniques-in-the-projects-built-on-bytes)'s MQTT result again: a parser whose
output is views of its input beats one whose output is values, by the cost of building those values.<!-- src: HTTPBytes/Benchmarks baseline final-1 rows "Structured Fields: 1,000 dictionaries (7 members)" (HTTPBytes 196 µs, 3,664,000 instr.; swift-http-structured-headers 22,000 µs, 368,000,000, 208,000 mallocs), "1,000 lists (5 members)" (137 vs 14,000 µs), "1,000 Priority fields" (23 vs 3,011 µs); ratios 22,000/196 = 112, 3,011/23 = 131; HTTPBytes/WRITEUP.md "Structured Fields and Priority" (1,607 parse cases and 553 serialization cases) -->

#### Content codings: chunk slices straight in, a carry buffer, reset per body

`HTTPContentDecoder` undoes `Content-Encoding` (gzip, deflate, br, zstd; two stacked at most) on BytesCompression's streaming
decoders. Three design points:

- **Input in any pieces, each passed once.** A chunked body's data is not contiguous: size lines sit between the
  chunks. HTTPBytes' chunked cursor hands out slices of the input (data is never copied), and each slice goes straight
  into the decoder. When a codec stops short at a slice's end (a Huffman symbol cut in half), the unconsumed tail is
  kept in a carry buffer (132 KiB, made the first time it is needed) and the next slice continues from it. The common case,
  a slice decoded to its end, copies nothing. A 1 MB gzip body arriving as 4 KB chunks decodes in 530 µs against 526 µs
  whole: the framing and the carry add 0.8%. System zlib decodes the same body whole in 627 µs.<!-- src: HTTPBytes/Sources/HTTPPayload/ContentCoding.swift HTTPContentDecoder doc comment and `carryCapacity` (132 << 10); HTTPBytes/Benchmarks baseline final-1 rows "Body 1 MB text, gzip, chunked in 4 KB" (530 µs), ", whole: HTTPBytes content decoder" (526 µs), ", whole: zlib (system)" (627 µs); HTTPBytes/RESULTS.md final-1 section ("The chunked path adds 0.8% to decoding the body") -->
- **Stacked codings through one middle buffer**, 64 KiB, made once. `finish()` checks every stage, because an outer stream can
  be cut short after the inner one happened to end.
- **Reset per body, not made per body.** A connection keeps one decoder and calls `reset(contentEncoding:)` for each
  body, which keeps each codec's state (DEFLATE's window and tables) and the buffers. The `final-1` gate read 6 mallocs per body because the benchmark made a new
  decoder for each; the decoder's state is made with it. After adding `reset`, a reused decoder allocates nothing after the first body of each
  coding, and a fresh decoder per body costs 5 allocations against 1 MB of output. This is the
  [workspace](#6-allocation-free-code) pattern of section 6, applied to a per-connection object: allocate at connection
  start, reset at message start.<!-- src: HTTPBytes/Benchmarks baseline final-1 row "Allocations:Body_chunked_gzip" (Malloc 6); HTTPBytes/RESULTS.md final-1 section "Allocations" paragraph ("A fresh decoder per body costs 5 allocations against 1 MB of output"; "a connection's decoder reset per body allocates nothing after the first body of each coding (gate 0 …)"); the post-reset gate of 0 is in HTTPBytes/RESULTS.md and WRITEUP.md, not in the final-1 baseline -->

#### Correctness: other implementations' suites, exactly accounted for

Protocol code fails on inputs nobody wrote a test for. Three things found most of what testing did not.

**Import other implementations' test suites as differential tests, with an exact table of differences.** llhttp's markdown suite
(258 cases), Go's `net/http` tables, h11, httparse (305 cases), http-parser (101), picohttpparser (94), cursed-http's
(300), HTTP Garden and PortSwigger's request-smuggling permutations, and h2o's fuzz corpus (1,972 inputs) are generated
into `TestData` by checked-in scripts and run through HTTPBytes' parsers; the outcome is compared with each suite's
verdict. Every deliberate disagreement is a row in a `differences` table with its reason (extension methods are tokens,
RTSP and HTTP/0.9 are not HTTP/1.1, a transfer coding other than `chunked` gets 501, obsolete line folding is rejected).
The tables are exact: an entry that stops differing fails the test, and so does a `withKnownIssue` that stops recording,
so a difference cannot silently become a bug or a fix. The suites found 11 real gaps (raw UTF-8 request targets, an empty
`Transfer-Encoding`, the chunk-extension grammar and its limits, CONNECT with a body, `100-continue` in HTTP/1.0, and
others).<!-- src: HTTPBytes/WRITEUP.md "Correctness" "Other implementations' test suites" table and prose (258, 305, 101, 94, 300, 1,972; "The suites found 11 real gaps"); AGENTS.md "HTTPBytes as a whole" bullet "Import other implementations' test suites as differential tests, with a table of deliberate differences" -->

**An old-versus-new differential during optimization.** For the seven steps above, the previous parser was compiled as a
second module in the measuring harness, and both were run on 1.6 million inputs: corpus heads and their mutations, whole
and fed 1, 7, and 64 bytes at a time, under four option sets, comparing every event and error. It ran in 9 seconds, and it caught a scan that skipped a block on
its first run, something no corpus test noticed. An optimization pass over parsing code that does not carry its
predecessor along is flying blind.<!-- src: HTTPBytes/RESULTS.md "2026-11-23: HTTP/1 heads against cursed-http" intro ("an old-versus-new differential (the previous HTTP1 sources as a second module: events and errors equal on 1.6 million inputs, corpus heads and their mutations, whole and fed 1, 7, and 64 bytes at a time, under four option sets)"); AGENTS.md "HTTP/1 heads against cursed-http" bullet ("1.6 M inputs in 9 s … found a scan that skipped a block on its first run") -->

**Adversarial review by an agent given the code, not the conclusions.** Two review passes found 15 confirmed defects, each of
which became a probe package reproducing it and then a regression test: an HTTP/2 field converted to HTTP/1 through an
unchecked store append (CR LF injection); `Content-Length: ,` slipping past the CL+TE smuggling check; trailers, leading empty
lines, and CONTINUATION frames with no limits; a QPACK Section Acknowledgment that could be dropped and would freeze the
peer's table; and quadratic re-scans when input arrives a byte at a time, in four places (HTTP/1 partial lines, chunk
trailers, QPACK encoder-stream literals, and a stacked content decoder's stalled buffer, which looped forever). Every
incremental parser now has a test fed one byte at a time with a time limit.<!-- src: HTTPBytes/WRITEUP.md "Adversarial reviews" (15 confirmed defects; the four quadratic re-scans; "Every incremental parser now has a test fed a byte at a time with a time limit"); AGENTS.md "HTTPBytes as a whole" bullets "An adversarial review agent given the code, not the conclusions" and "Every incremental parser needs a 'fed a byte at a time' test with a time limit" -->

A lesson of a different kind came from strictness. Validating request targets against RFC 3986 rejected 52 of the 401
real browser requests (Facebook's `?filter[0]=` has raw brackets in the query) and cost 15% to 69% in cycles, so it is
an option and off by default. Measure a validator against real traffic before making it the default.<!-- src: HTTPBytes/RESULTS.md "Request-target validation is an option, off by default" bullet (http-corpus requests 236 → 272 cycles (+15%), top-1k requests 657 → 1,113 (+69%); "it rejects real traffic: 52 of http-corpus's 401 requests") -->

#### The whole result

Per iteration, p50, from the `final-1` baseline. References are the same machine in the same run.

| Workload | HTTPBytes | Fastest other | Others |
|---|---|---|---|
| HTTP/1: 401 real request heads (232 KB) | **35 µs** | cursed-http 38 µs | picohttpparser 92, llhttp 89 |
| HTTP/1: top-1k, 3,533 request heads (4.1 MB) | **761 µs** | cursed-http 806 | picohttpparser 1,773, llhttp 1,744 |
| HTTP/1: 383 real response heads (365 KB) | 53 µs | **cursed-http 45** | picohttpparser 127, llhttp 131 |
| HTTP/1: 20 fields of 128 B, 1,000 heads | **254 µs** | cursed-http 322 | llhttp 485, picohttpparser 806 |
| HTTP/1 heads into owned fields (401) | **111 µs, 0 mallocs** | | swift-http-types `HTTPFields` 604 µs, 3,669 mallocs |
| 3,000 field lookups by name | **8.1 µs** | | `HTTPFields` 634 µs |
| HPACK decode, 401 requests | **132 µs** | cursed-http 162 | ls-hpack 228, NIOHPACK 552 |
| HPACK encode, 401 requests | **89 µs** | ls-hpack 239 | cursed-http 244, NIOHPACK 1,422 |
| QPACK decode, 401 requests, 4 KB table | **120 µs** | cursed-http 171 | ls-qpack 235 |
| QPACK encode, 401 requests, 4 KB table | **107 µs** | cursed-http 238 | ls-qpack 751 |
| Structured Fields, 1,000 dictionaries | **196 µs** | | swift-http-structured-headers 22,000 µs |
| 1 MB gzip body, chunked in 4 KB, decoded | **530 µs** | | system zlib, whole body, 627 µs |
<!-- src: HTTPBytes/Benchmarks baseline final-1 (final-1.tsv), "Time (wall clock)" rows: "HTTP/1 request heads (401 requests, 232 KB)" (HTTPBytes 35, cursed-http 38, picohttpparser 92, llhttp 89), "(top-1k, 3,533 requests, 4.1 MB)" (761, 806, 1,773, 1,744), "HTTP/1 response heads (383 responses, 365 KB)" (53, 45, 127, 131), "(1,000 × 20 fields of 128 B)" (254, 322, 485 llhttp, 806 picohttpparser), "HTTP/1 requests into owned fields (401 requests)" (111 µs, 0 mallocs; HTTPFields 604 µs, 3,669 mallocs), "Fields: 3,000 lookups by name" (8.127, 634), "HPACK decode (401 requests)" (132, 162, 228, 552), "HPACK encode (401 requests)" (89, 239 ls-hpack, 244 cursed-http, 1,422), "QPACK decode (401 requests, 4,096 table)" (120, 171, 235), "QPACK encode (401 requests, 4,096 table)" (107, 238, 751), "Structured Fields: 1,000 dictionaries (7 members)" (196, 22,000), "Body 1 MB text, gzip, chunked in 4 KB" (530) and "gzip, whole: zlib (system)" (627) -->

Where HTTPBytes is behind: HTTP/1 responses (13 to 16% more cycles than cursed-http, from the mispredictions above) and
tiny heads given only their own bytes (10 to 55% behind at `final-1`, where cursed-http's contract lets it read 64 bytes past
the end of its input and HTTPBytes copies the partial last block: a safe API against an unsafe one). [Round 2](#round-2-two-gaps-measured-not-closed)
measured both gaps again: the responses stay open, and the tiny heads are 8 to 11 cycles behind, which is not the copy.<!-- src: HTTPBytes/WRITEUP.md "Open items" (responses 13–16% more cycles than cursed-http; tiny heads 10–55% behind, cursed-http reads 64 bytes past the input; HTTPBytes copies the partial block) and "Round 2" ("8–11 cycles, … not the copied partial block"); HTTPBytes/RESULTS.md "round 2, HTTP/1's remaining gaps"; HTTPBytes/RESULTS.md final table rows "tiny requests (38 B)" and "… alone" (23.9 ns, 73 cycles against 15.5, 47) -->

#### Round 2: two gaps measured, not closed

The second round took round 1's open items (all but a connection layer: HTTP/2's stream states and HTTP/3's stream rules as
state machines over the codecs) and the field parsers the plan had left out. As in round 1, the plan was reviewed
adversarially before any code, and each part's code after it.<!-- src: HTTPBytes/WRITEUP.md "Round 2: the open items, dates, and field values" first paragraph ("took this document's open items (all but the connection layer) and the field parsers the plan had left out"; "reviewed adversarially as round 1 was: the plan before any code, then each part's code") -->
The first two items were the HTTP/1 gaps, and neither closed. They were measured with round 1's cycle harness
(`proc_pid_rusage` around each parser, the previous `HTTP1` as a second module in the same binary, best of 3, cycles per
head). Before, in that run: 401 requests 240, 383 responses 433, top-1k requests 662, top-1k responses 1,038, tiny requests 48 (given
the next head's bytes too) and 59 (given only their own), 1-byte fields 365, 16-byte 481, 128-byte 785; cursed-http, on
responses 367, on top-1k responses 897, on tiny heads given only their bytes 47.<!-- src: HTTPBytes/RESULTS.md "2026-11-23: round 2, HTTP/1's remaining gaps (measured, not kept)" first paragraph (req 240, resp 433, treq 662, tresp 1,038, tiny 48, tiny alone 59, f1 365, f16 481, f128 785; cursed-http resp 367, tresp 897, tiny alone 47) -->

**Skip windows for long lines.** cursed-http's `fb_ctany_simd` asks "is there a control byte in the next 256 bytes, then
the next 512?" with an add and a signed minimum per 16 bytes, skipping the exact mask. The long lines are there to skip:
44% of the response heads' bytes in the 383-response corpus are in 231 lines of 512 to 1,023 bytes, and 38% of the top-1k
responses' in 531 lines of 1 KB or more, none with a byte at or above 0x80. No setting of the windows gained
(cycles per head):<!-- src: HTTPBytes/RESULTS.md "Skip windows for long lines" (44% of http-corpus responses' bytes in 231 lines of 512–1,023 bytes; 38% of top-1k responses' in 531 lines of 1 KB or more, none with bytes ≥ 0x80) -->

| Variant | resp | tresp | treq | f128 |
|---|---|---|---|---|
| Before | 433 | 1,038 | 662 | 785 |
| Windows inside `farStop` after 3 exact blocks | 449 | 1,109 | 690 | 908 |
| Windows in an out-of-line function `farStop` calls | 443 | 1,070 | 674 | 947 |
| `farStop`'s loop kept in shape (its bound capped at 3 blocks), windows after it | 444 | 1,057 | 664 | 792 |
| … windows after 1 or 0 exact blocks | 445 | 1,059–1,078 | 669–688 | |
<!-- src: HTTPBytes/RESULTS.md "Skip windows for long lines" table (rows 1 to 4; the Before row is the harness's "Before" line in the section's first paragraph: resp 433, tresp 1,038, treq 662, f128 785) -->

Instructions rose 5 to 8%. The exact masks are cheap here (29 instructions per 64 bytes: the `farStop` listing above), so a
window is wasted on a line of 256 to 1,023 bytes, and the windows cost more than they skip. And the idea's source does not use it where it would matter: cursed-http's response parser classifies four blocks ahead
into a per-head array, the design round 1 had measured in a ring of 8 blocks at +25% on requests and +67% on tiny
heads, so the response gap stays open.<!-- src: HTTPBytes/RESULTS.md "Skip windows for long lines" paragraph after the table ("Instructions rose 5–8%: our exact masks are cheap (29 instructions per 64 bytes …)"; "cursed-http's response parser itself doesn't use windows (an adversarial review of this round's plan pointed out): it classifies 4 blocks ahead into a per-head array, which round 1 measured in our design (a ring of 8 blocks) at +25% on requests and +67% on tiny heads"); the +25% and +67% are 279 → 350 and 55 → 92 in the "Measured and rejected" table above -->

Two code generation lessons came out of the attempts. Adding a call to `farStop` left `RawSpan.byteCount` an out-of-line call
inside it, the caller limit again. And giving the loop a second exit, "after 3 blocks, try the windows", made LLVM build nested,
duplicated loops: 85 instructions with calls where the original loop was 29. Do not give a hot loop a second exit or a new call to try an
idea. Cap its bound instead (here `min(count - 64, block + 128)`, three blocks) so its shape does not change, and call the
new path after the loop; that variant kept the loop's cost (792 on 128-byte fields against 785) and the idea's cost
showed on its own.<!-- src: HTTPBytes/RESULTS.md "Two codegen lessons on the way: adding a call to `farStop` left `RawSpan.byteCount` an out-of-line call in it, and a loop with a second exit for '3 blocks done' became nested duplicated loops (85 instructions with calls against 29)"; AGENTS.md "Don't give a hot loop a second exit or a new call to test an idea" (the cap `min(count - 64, block + 128)`); table above, third variant f128 792 against 785 -->

**Tiny heads given only their bytes.** At the end of round 1 the gap to cursed-http on 38-byte requests was put at 21
cycles. Measured properly it is 8 to 11: 56 to 59 cycles alone, against 48 when the next head's bytes are readable. The
partial last block is not the cost. Building it from overlapping 16-byte loads clamped to the end of the bytes, with the
mask moved into place, in place of copying it to the stack, gave 58 cycles against 56 and made 128-byte fields 895 against
787, because the inlined block mask grew the parse loop again. A padded-input API (the caller promising readable bytes past
the message) could recover at most those 8 cycles, on heads under 64 bytes only, so it was not built.<!-- src: HTTPBytes/RESULTS.md "Tiny heads given only their bytes" ("the gap is now 8–11 cycles (tiny alone 56–59 against 48 with the next head's bytes readable), not round 1's 21"; clamped overlapping 16-byte loads: tiny alone 58 against 56, and f128 895 against 787; "could recover at most those 8 cycles, on heads under 64 bytes only. Not built"); HTTPBytes/WRITEUP.md "What didn't work, measured" -->

#### Round 2: bodies as pipeline stages, and why a body is one stage

Chunked transfer coding and the content codings are the same kind of thing as the codecs under them: a stream in, a stream
out, with state between calls. Round 2 made them [`ByteTransform`](#10-pipelines-bytetransform-pipeline-and-why-composition-costs-nothing)
stages: `HTTP1Dechunker` and `HTTP1Chunker` (HTTP1), and `HTTPContentDecoder` and `HTTPContentEncoder` (HTTPPayload), the
decoder also a `ResettableByteTransform`, keeping its codecs between bodies. The first version of the whole-body path simply composed them:

```swift
// The trap (illustrative): the pipeline is finished when its last stage is.
var body = dechunker.then(gzipDecoder)
```

A pipeline finishes when its last stage does (Part II's [one end-of-stream rule](#one-end-of-stream-rule)). For a body that is
the wrong stage to decide. The gzip stream ends before the chunked body does: a body whose last chunk never arrived read as
finished, and bytes inside the chunked body after the gzip stream (an attacker's second request, say) were left in the
connection to be read as the next message. That is request smuggling, found by the review of this first version.<!-- src: HTTPBytes/RESULTS.md "round 2, bodies as pipeline stages" ("composing the stages with Bytes' then(_:) finishes the pipeline when its last stage finishes, so dechunker.then(gzipDecoder) ended a body at the gzip stream's end. A body missing its last chunk read as finished, and bytes inside the chunked body after the stream (an attacker's request) were left to be read as the next message: request smuggling"); AGENTS.md "A pipeline ends when its last stage ends: a framing stage must not be followed by one that can end first" -->
A body is therefore one stage, `HTTPBodyDecoder`, whose framing (`Content-Length`, chunked, or until the connection closes)
alone decides where the body ends. It finishes only at the framing's end, and it requires the coded stream to end exactly
there: bytes after the stream, or a stream cut short, are `malformed`. Chunk slices go straight from the chunked decoder into
the content decoder, with no buffer between them:

```swift
// HTTPPayload's BodyDecoder.swift doc comment.
var body = try HTTPBodyDecoder(framing: try framing.requestBody(version: line.version), contentEncoding: encoding)
let progress = try body.transform(unread, into: &output, flush: .none)
```
<!-- src: HTTPBytes/Sources/HTTPPayload/BodyDecoder.swift doc comment (the example is its own) and HTTPBytes/RESULTS.md "HTTPBodyDecoder … finishes only at the framing's end, requires the coded stream to end exactly there (`malformed` for bytes after it or a stream cut short), and hands chunk slices straight to the content decoder (no buffer)" -->

It costs nothing over the hand-written loop (p50, 1 MB of text, gzip, chunked in 4 KB): the loop that hands chunk slices to the
content decoder 4,887 K instructions and 536 µs, `HTTPBodyDecoder` 4,891 K and 535 µs, and the first version's pipeline (dechunker,
a 16 KiB buffer, decoder) 4,813 K and 527 µs: 1.6% fewer instructions and 1.5% less time than the stage that is correct. `Allocations:Body_decoder_chunked_gzip`,
one decoder reset per body, is 0.<!-- src: HTTPBytes/RESULTS.md "round 2, bodies as pipeline stages" last paragraph (4,887 K, 536 µs; 4,891 K, 535 µs; 4,813 K, 527 µs; Allocations:Body_decoder_chunked_gzip 0) -->

The review found more in the stages, all fixed: trailers were left for the next reader by default (they are skipped by default now,
and `.leave` reads them through `nextTrailer`); a stacked coding's outer stream cut short passed `.finish`; the options were
mutable after `init` and out of step with an internal flag; a decoder's raised limits let a peer trip `Pipeline`'s unit
precondition (the limits are clamped to the stage's unit); and the chunker lost a byte at chunk-size digit boundaries (now
exact, tested for every room from 5 to 300 bytes). Writing the tests found one more: at the framing's end the content decoder
can still hold output, when it took all its input and the output was full the last time, so it is drained before the end is
checked.<!-- src: HTTPBytes/RESULTS.md "round 2, bodies as pipeline stages" second paragraph ("The review's other findings, all fixed: …"; "Writing the tests found one more: at the framing's end the content decoder can still hold output … drained before the end is checked") -->

#### Round 2: QPACK at ls-qpack's size

The `final-1` QPACK encoder was 7 to 8x as fast as ls-qpack and compressed worse: on the 383 responses with a 4,096-byte table
it wrote 62,241 bytes (sections plus encoder stream) against ls-qpack's 53,087, 15% more. ls-qpack (`lsqpack.c`) does three things
it did not, and the encoder now does all of them:<!-- src: HTTPBytes/RESULTS.md "2026-11-23: QPACK encoder: draining, Duplicate, names alone" first paragraph (ls-qpack compressed http-corpus' responses 15% better: 53,087 B against 62,241 with a 4,096-byte table; `qenc_entry_is_draining`, `qenc_duplicable_entry`, `EEA_INS_LIT_NAME`) -->

- **A draining index** (RFC 9204 §2.1.1.1). A table evicts its oldest entries first, so an entry near the front of a full
  table is about to go, and a field section that refers to it keeps it from going. The encoder tracks each entry's start among
  all insertions' bytes (one number per ring slot, memory made with the encoder) and calls an entry **draining** once three
  quarters of the capacity has been inserted after it: a quarter of the capacity's insertions or less will evict it. A
  boundary number moves forward as entries are inserted, each entry passed once, so the per-field cost is one compare
  against it. Draining entries are not used as name references.
- **Duplicate** (§4.3.4). A field whose newest copy is draining is copied to the table's front, when room can be made
  without evicting an entry still referred to. A section that may block refers to the copy (the old entry can go); one that
  cannot refers to the old entry, which is acknowledged, referred to first so that making room cannot evict it, and later
  sections use the copy. When no copy can be made, the old entry is still referred to if it may be.
- **Names alone.** A name the static table lacks, seen recently in a literal with another value, is inserted with an empty
  value and referred to (post-base if the section may block). The responses' lines with literal names went from 157 (9,960 B)
  to 14 (485 B).

A fourth change was a shorter memory: the history of fields seen (insertion on the second sighting, round 1's rule) has one slot
per 64 bytes of capacity instead of one per 8, sized by the peer's capacity rather than the encoder's.<!-- src: HTTPBytes/RESULTS.md same section, the four bullets ("A draining index", "Duplicate", "Names alone", "A shorter memory"); HTTPBytes/Sources/HTTP3/QPACKEncoder.swift doc comment ("Draining (RFC 9204 §2.1.1.1)") and `drainingDistance = capacity - capacity >> 2`, `drainingBelow` -->
The responses, step by step: 62,241 bytes; the draining index and Duplicate, 58,031; the shorter memory, 55,386; names alone and
no name references to draining entries, 53,137, against ls-qpack's 53,087. The encoder stream shows where the bytes went:
16,071 B before, 6,264 B after, ls-qpack's 2,831 B (154 Duplicates against its 202); literals with a literal name 157, 14, and 13.<!-- src: HTTPBytes/RESULTS.md same section, "Step by step" ("Step by step (383 responses, 4,096 bytes, acknowledged at once): 62,241 B; draining and Duplicate 58,031; the shorter memory 55,386; names alone, and no name references to draining entries, 53,137 (ls-qpack 53,087)") and "Where the bytes went" (encoder stream 16,071 B, 6,264 B, 2,831 B; 154 Duplicates against ls-qpack's 202; literal name 157, 14, 13) -->

How it was measured matters here, because compression depends on what the peer has acknowledged. A scratch driver runs each
corpus as a connection: after section *i* the peer's decoder has taken everything through section *i − k* in order, and its
decoder stream (Section Acknowledgments, Insert Count Increments) reaches the encoder; HTTPBytes' decoder for HTTPBytes'
encoder, ls-qpack's for ls-qpack's, bytes counted as sections plus encoder stream. The same model is in the benchmarks as
`QPACKFlight`, which records the decoder stream once in setup and replays it, so an iteration times the encoder alone; each
setup checks that the output decodes exactly by HTTPBytes' decoder and by ls-qpack's (an FNV digest of every field), and that
ls-qpack's output decodes by HTTPBytes'.

| Corpus, capacity, sections in flight, blocked | before | after | ls-qpack | after / ls-qpack |
|---|---|---|---|---|
| 383 responses, 4,096, at once, 100 | 62,241 | **53,137** | 53,087 | 1.001 |
| 383 responses, 4,096, at once, 0 | 78,764 | **60,688** | 59,850 | 1.014 |
| 383 responses, 4,096, 4, 100 | 59,677 | **53,396** | 59,918 | 0.891 |
| 383 responses, 4,096, 16, 100 | 62,356 | **53,631** | 66,216 | 0.810 |
| 383 responses, 4,096, 16, 0 | 82,276 | 84,389 | 129,724 | 0.651 |
| 401 requests, 4,096, at once, 100 | 55,074 | **53,392** | 53,439 | 0.999 |
| 401 requests, 4,096, 16, 0 | 70,882 | 73,896 | 73,535 | 1.005 |
| 401 requests, 16,384, at once, 100 | 53,210 | 53,210 | 52,137 | 1.021 |
<!-- src: HTTPBytes/RESULTS.md "QPACK encoder: draining, Duplicate, names alone" table (a selection of its 17 rows: the columns before, after, ls-qpack, after / ls-qpack) -->

Bytes went up only with no blocking and acknowledgments 4 to 16 sections late (the shorter memory inserts fewer fields
there), where the encoder still matches or beats ls-qpack. With the table never full (requests, 16,384) nothing drains, and
ls-qpack is 2% smaller by inserting `:path` and the other fields HPACK's policy leaves out (inserting them too: 47,452 B there,
but +1% to +22% on the 4,096-byte request rows, not kept). The cost in time is small, and the encoder stays 7 to 15 times as fast as
ls-qpack on these rows (p50 per corpus; wall times under load):

| Row | before | after | ls-qpack |
|---|---|---|---|
| encode 383 responses, 4,096 table | 2,593 K, 149 µs | 2,478 K, 138 µs | 14,000 K, 1,192 µs |
| … 16 in flight, 0 blocked | 2,882 K, 151 µs | 2,902 K, 155 µs | 26,000 K, 2,343 µs |
| encode 401 requests, 4,096 table | 2,089 K, 112 µs | 2,083 K, 111 µs | 9,273 K, 780 µs |
<!-- src: HTTPBytes/RESULTS.md same section's benchmark-rows table (rows "encode 383 responses, 4,096 table", "… 16 in flight, 0 blocked", "encode 401 requests, 4,096 table"); the ratios 1,192/138 = 8.6, 2,343/155 = 15, 780/111 = 7.0 give "7 to 15 times" -->

Every `Allocations:QPACK_encode_*` gate is still 0, two new ones (16 sections in flight, blocking and not) included.<!-- src: HTTPBytes/RESULTS.md same section ("Every `Allocations:QPACK_encode_*` gate is 0, two new ones included") -->

The variants that did not pay are the useful part (383 responses, 4,096 bytes; bytes at once, and with 16 sections in flight and 100
blocked):

| Variant | at once | 16 in flight |
|---|---|---|
| Kept: draining zone a quarter, Duplicate on use, names alone | 53,137 | 53,631 |
| A literal for a draining entry no copy can be made of (the strict reading of "not referenced") | 53,137 | 69,736 |
| Second chance: Duplicate, at each section's end, the entries that became draining and were referred to | 54,994 | 69,332 |
| Draining zone 3/16 / 5/16 of the capacity | 52,350 / 53,412 | 53,419 / 54,391 |
| History with one slot per 32 bytes / per 8 (as before) | 55,110 / 56,300 | 55,783 / 57,659 |
| The draining index without Duplicate | 64,443 | 81,179 |
<!-- src: HTTPBytes/RESULTS.md same section "Tried and not kept" table (all six rows; the second-chance row is shortened) -->

The second chance cost the 4,096-byte rows 0.5 to 29%: copies of fields used once crowded out fields used again. The 3/16 zone won
the immediate row by 1.5% and lost 7.6% with no blocking (65,333 bytes against 60,688). One slot per 8 bytes was better only with 4
sections in flight and no blocking (73,451 bytes) and worse everywhere else.<!-- src: HTTPBytes/RESULTS.md same section, paragraph after the "Tried and not kept" table ("Second chance cost the 4,096-byte rows 0.5–29% …"; "Zone 3⁄16 won the immediate row by 1.5% and lost 7.6% with no blocking (65,333 against 60,688). One slot per 8 bytes was better with 4 sections in flight and no blocking (73,451) and worse everywhere else") -->

**A simulated peer must be consistent with itself.** The test harness that checks an encoder against a decoder delivers the
encoder stream and the sections late, as a network does, and its first version failed the new encoder when acknowledgments
arrived 4 sections late, because it decoded each section after 16 sections' encoder stream. The harness was right and the
model was wrong: an acknowledgment says the peer has decoded a section, so the encoder may evict that section's entries after
it, and a peer that decodes later than it acknowledged is not a peer the encoder can be expected to work with. Deliver late only
as far as the feedback says. The harness (encoder stream and sections each delivered 0 to 16 sections late, Stream Cancellations,
Insert Count Increments, the decoder stream fed back whole or a byte at a time, every section decoded exactly, the decoder never
holding more blocked streams than the setting) then had to fail on purpose-broken encoders, and does: ignoring unacknowledged
sections' references when evicting gives `invalidIndex`, one blocked stream too many gives `tooManyBlockedStreams`. A
check that has never failed has not been shown to check.<!-- src: AGENTS.md "A simulated peer must be consistent with itself" bullet ("a check that decoded each section after 16 sections' encoder stream failed an encoder whose acknowledgments arrived 4 sections late, and rightly … Deliver late only as far as the feedback says. And break the code on purpose once …"); HTTPBytes/RESULTS.md same section "Tests (`QPACKDrainingTests`)" (the harness's coverage; `invalidIndex`, `tooManyBlockedStreams`) -->

#### Round 2: dates in four words

`HTTPDate` (RFC 9110 §5.6.7) parses the three formats a recipient must accept and writes the one senders should use,
IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`: always 29 bytes, so every field has its place). A fixed-width format with fixed
characters is a **SWAR** problem: ordinary 64-bit integer operations on eight packed bytes, as in Part II's
[numbers written as ASCII digits](#numbers-written-as-ascii-digits). The date is read as four overlapping 8-byte words, at offsets 0, 8, 16, and 21:
the fixed bytes (the commas, spaces, colons, and ` GMT`) are checked by masks and XORs against their expected bytes, and the 14
digits by one test:<!-- src: HTTPBytes/Sources/HTTPBytes/HTTPDate.swift doc comment ("IMF-fixdate, 29 bytes, is read as four 8-byte words: the fixed bytes checked with masks, the 14 digits with one SWAR test, the month by a perfect hash of its three letters, and the date turned into days without branches (Howard Hinnant's days_from_civil); the day name is checked against the one the date has") and `imfFixdate` (loads at 0, 8, 16, 21) -->

```swift
// HTTPBytes' HTTPDate.nonDigits: the lanes of `word` in `lanes` that aren't ASCII digits (nonzero if any).
// A digit XOR 0x30 is 0-9: its high nibble 0, and adding 6 leaves it 0 too. A carry out of a lane that
// isn't a digit can only make its neighbour fail.
static func nonDigits(_ word: UInt64, _ lanes: UInt64) -> UInt64 {
    let x = word ^ 0x3030_3030_3030_3030
    return (x | (x &+ 0x0606_0606_0606_0606)) & 0xF0F0_F0F0_F0F0_F0F0 & lanes
}
// imfFixdate ORs the fixed-byte differences with nonDigits of each word and tests the whole at once:
guard fixed | digits == 0 else { return nil }
```
<!-- src: HTTPBytes/Sources/HTTPBytes/HTTPDate.swift `nonDigits` (verbatim, comments shortened) and `imfFixdate` (`let digits = nonDigits(first, …) | nonDigits(second, …) | nonDigits(third, …) | nonDigits(fourth, …)`; `guard fixed | digits == 0`) -->

The month is found by a **perfect hash** of its three letters (the same device as the field names): the letters as a
little-endian 24-bit number, times 26,596 in 32 bits, shifted right by 28, index a 16-slot table whose entries are
`letters << 8 | month`, and the entry's letters are compared with the input's. The date then becomes a day count with Howard
Hinnant's `days_from_civil`, which has no branches, and the weekday computed from that count must equal the day name read: a date with a wrong day name is refused.
Writing is the reverse (three words and five bytes), and `HTTPDateCache` keeps the 29 bytes of the current second and
reformats them only when the second changes. The old forms (RFC 850 with a two-digit year read as at most 50 years past a
reference date, and asctime) are parsed a byte at a time; they are rare.<!-- src: HTTPBytes/Sources/HTTPBytes/HTTPDate.swift `monthSlots` doc comment ("slot `(letters × 26596) >> 28` … holds `letters << 8 | month`"), `month(_:)`, `days(year:month:day:)`, `weekday(days:)`, `imfFixdate`'s day-name check, `obsoleteDate` ("The rare forms: a byte at a time"); HTTPBytes/RESULTS.md "round 2, dates and field values" first paragraph (three words and five bytes; HTTPDateCache: 29 bytes reformatted when the second changes; RFC 850 two-digit years at most 50 years past a reference date) -->

Per date, over the 3,375 `Date` and `Last-Modified` values of the two corpora: 228 instructions and 13 ns to parse (771 K
instructions, 44 µs in all), against Foundation's `Date.HTTPFormatStyle` at 8,000 instructions and 457 ns each with 3,807
mallocs in all (27 M, 1,544 µs). Writing 1,000 dates takes 319 K instructions and 20 µs against Foundation's 4.4 M and 272 µs
with 1,000 mallocs; 1,000 `Date` fields from the cache take 13 K instructions and 1.5 µs. The tests are the RFC's and Rust's
`httpdate` vectors, 39 refusals, Foundation agreeing on every day from 1970 to 2200 in both directions, and every day from year
0 to 9999 round-tripping through all three formats (a bulk test, 0.3 s in release). The deliberate differences from Foundation
are stated: the parser is case-sensitive (Foundation's and Python's are not), a mismatched weekday is refused, and second 60 is
accepted as the next minute's first.<!-- src: HTTPBytes/RESULTS.md "round 2, dates and field values" table rows "Date, Last-Modified (3,375): parse" (771 K, 44 µs; 228 instructions, 13 ns per value), "… Foundation Date.HTTPFormatStyle" (27 M, 1,544 µs, 3,807 mallocs; 8,000, 457 ns), "1,000 dates written" (319 K, 20 µs; Foundation 4.4 M, 272 µs, 1,000 mallocs), "1,000 Date fields from HTTPDateCache" (13 K, 1.5 µs); the paragraph on tests and "Deliberate differences: case-sensitive …, a mismatched weekday refused, second 60 accepted as the next minute's first (Go refuses it)" -->

Bytes' own `UTCDateTime` ([Part II](#hexadecimal-and-dates)) uses the same day count.

#### Round 2: field values as views, and a vector-scan pass

The field values a server or client reads are a long list of small grammars: lists and parameters, quoted strings, media types
and `Accept` negotiation, byte ranges, entity tags and RFC 9110 §13.2.2's precondition order, `Cache-Control`, hosts (IPv6 and
IPvFuture literals), `Forwarded`, credentials and challenge lists, `Content-Disposition` with RFC 8187 file names, cookies, and
request-target components. All of them follow the Structured Fields iterators' shape: a value is a view of the field's bytes,
and a parse hands out views and numbers, so nothing is allocated. Quoted strings keep their escapes in place: they are removed
only when the text is written or compared. A set of ranges is resolved into the caller's storage.<!-- src: HTTPBytes/RESULTS.md "round 2, dates and field values" second paragraph (the list of field values: "all views or plain values, no allocations"; "HTTPQuotedString with escapes removed only when written or compared"; HTTPRangeSet "resolved into the caller's storage, sorted and merged, with a count limit") -->

The first version scanned a byte at a time. The second moved the scans over tokens, quoted strings, entity tags, and hosts onto the 16-byte tests HTTP/1
already had, through one Bytes function, `firstByteOffset(where:)` (which also handles values shorter than a vector in one
overlapping block):

```swift
// HTTPBytes' FieldGrammar.tokenEnd: the first byte that isn't a token character, 16 bytes at a time.
let rest = bytes.extracting(droppingFirst: start)
return start &+ (rest.firstByteOffset(where: HTTPCharacters.nonToken) ?? rest.byteCount)
// ... and quotedStringEnd: the next quote, backslash, or byte that can't be in a quoted string.
guard let found = rest.firstByteOffset(where: quotedTextStop) else { break }
```
<!-- src: HTTPBytes/Sources/HTTPBytes/FieldGrammar.swift `tokenEnd(_:from:)` and `quotedStringEnd(_:from:)` (lines 43–48 and 66–70, condensed); HTTPBytes/RESULTS.md "Vector scans" paragraph ("tokens by HTTPCharacters.nonToken's nibble lookups, quoted strings and entity tags by a search for the next quote, backslash, or byte that can't be there, a host's registered name by one test of 16 bytes at a time … all through Bytes' firstByteOffset(where:) (short values in one overlapping block)") -->

Tokens use `HTTPCharacters.nonToken`'s nibble lookups (two one-register table lookups on a byte's halves), quoted strings and
entity tags search for the next quote, backslash, or byte that cannot be there, and a host's registered name tests 16 bytes at a
time (`HTTPRequestTarget.nonURIByte` and the six delimiters). The table is every value of each field in the two corpora, p50 per
iteration, the first version against the vector scans:

| Field (values) | First version | Vector scans | Per value |
|---|---|---|---|
| ETag (591) | 372 K | 89 K | 150 instructions, 8 ns |
| Host (3,935) | 2.1 M | 1.49 M | 378, 27 ns |
| Content-Type (2,332) | 2.1 M | 1.42 M | 608 |
| Cache-Control (1,942) | 2.6 M | 2.13 M | 1,100 |
| Accept (2,600), weight of text/html | 7.5 M | 5.68 M | 2,180 |
| Accept-Encoding (2,599), br/gzip/identity | 24 M, 16,000 mallocs | 3.51 M, 0 | 1,350 |
| Accept-Language (344), weight of en-US | 333 K | 313 K | 910 |
<!-- src: HTTPBytes/RESULTS.md "round 2, dates and field values" table (the rows ETag, Host, Content-Type, Cache-Control, Accept, Accept-Encoding, Accept-Language; columns First version, Vector scans, Per value; p50 per iteration over all values, under load: "judge by instructions") -->

The gain is largest where the value is mostly one run of text (an entity tag: −76%) and smallest where the work is the grammar
around short tokens (Accept-Language: −6%). Wall times were taken under load, so the instruction counts are the claim.
The `Allocations:` gates for the field values (`FieldValues_dates`, `_cache_control`, `_accept`, `_cookies_targets`) are 0.<!-- src: HTTPBytes/RESULTS.md same table (ETag 372 K → 89 K = −76%; Accept-Language 333 K → 313 K = −6%) and "Allocation gates at 0: FieldValues_dates, _cache_control, _accept, _cookies_targets" -->

**One row is not a scan.** `Accept-Encoding` fell from 24 M instructions and 16,000 mallocs to 3.51 M and none, and the vector scans
were not most of it. `HTTPContentCoding.negotiated` was a public function generic over `some Sequence` (the codings a server
offers) without `@inlinable`, so it ran **unspecialized**: it boxed its iterator (6 mallocs a value) and, written to ask the
header once per offered coding, parsed the list again each time. Now it is inlinable and parses the list in one pass.
The general rule is in [section 5](#a-public-generic-that-is-not-inlinable-runs-unspecialized).<!-- src: HTTPBytes/RESULTS.md "Accept-Encoding negotiation was generic over `some Sequence` without `@inlinable`: unspecialized, it boxed its iterator (6 mallocs a value), and parsed the list once per offered coding; now inlinable and one pass"; AGENTS.md "A public generic function over `some Sequence` that isn't `@inlinable` runs unspecialized and boxes its iterator" -->

**An API trap in case folding.** `isScheme("Basic")` on a credentials value never matched a `Basic` header. The helper compared the
header's bytes against a `StaticString` literal with `HTTPToken.equalsIgnoringCase`, which folds only the bytes it is given,
one side, so the literal had to be lowercase, and a capitalized literal could never match. Public helpers that take a
caller's literal now fold both sides (`isScheme` does), and the one-sided overload asserts that its literal is lowercase. A
literal parameter that must be in a particular case is a trap for every caller who has not read its documentation: make the
function fold, or check, rather than document.<!-- src: AGENTS.md "A case-insensitive comparison against a StaticString that folds only one side is a trap for callers: isScheme("Basic") never matched (the literal must be lowercase). Public helpers taking a caller's literal fold both sides; the one-sided overload asserts its literal is lowercase"; HTTPBytes/Sources/HTTPBytes/Credentials.swift `isScheme` doc comment ("ignoring case (on both sides…)") and FieldValues.swift `HTTPToken.equalsIgnoringCase(_:_: StaticString)` doc comment ("`token` must be lowercase: only `bytes` are folded (the overload taking two spans folds both)") -->

#### Round 2: what the field-value review found

An adversarial review (2.6 million fuzzed inputs through every parser, `HTTPDate` against Foundation on 200,000 dates, IPv6
literals against `inet_pton` on 300,000: no trap, no allocation) confirmed six defects, each fixed with a regression test.
Two of them generalize.<!-- src: HTTPBytes/RESULTS.md "round 2, dates and field values" paragraph "An adversarial review (2.6 M fuzzed inputs through every parser, `HTTPDate` against Foundation on 200 K dates, IPv6 against `inet_pton` on 300 K: no traps, no allocations) confirmed six defects, all fixed with regression tests" -->

**Merging into bounded storage: sweep, do not insert in arrival order.** `HTTPRangeSet.resolve` writes the union of a `Range`
field's byte ranges, sorted and merged, into storage the caller provides, which bounds what a hostile field can make a server
hold. It refused sets whose union fit the storage. It merged each new range only with the one before it, and inserting in
arrival order can need more slots on the way than the answer has: in `3-5, 25-41, 4-` the first two ranges are separate until
the third joins them, so a set whose answer is one range needed more slots than one. The fix reads the set again for each range written: the lowest range not yet covered, grown while any range
overlaps or touches it, then written, so the storage only ever holds the answer:

```swift
// HTTPBytes' HTTPRangeSet.resolve (the sweep, condensed): `cursor` is the end of the last range written; every range
// of the set lies wholly before it or wholly after it.
while true {
    var start = Int.max, end = Int.min
    var pass = try! HTTPRangeSet(parsing: value)          // the first pass already read the set without an error
    while let range = try! pass.next() {                  // the lowest range not yet covered
        guard let bytes = range.resolved(length: length), cursor == .min || bytes.lowerBound > cursor else { continue }
        if bytes.lowerBound < start || bytes.lowerBound == start && bytes.upperBound > end { (start, end) = (bytes.lowerBound, bytes.upperBound) }
    }
    guard start != .max else { return .ranges(count) }
    // ... grow `end` while any range overlaps or touches [start, end], re-reading the set each time ...
    guard count < ranges.count else { return .ignore }
    ranges[count] = start..<end; count += 1; cursor = end
}
```
<!-- src: HTTPBytes/Sources/HTTPBytes/Ranges.swift `resolve(_:length:into:)` (condensed; the grow loop elided) and its doc comment ("The union is found by sweeping the set rather than by inserting its ranges in order, so the storage only has to hold the answer"); HTTPBytes/RESULTS.md defect 1 (`3-5, 25-41, 4-`) -->
The set is re-read for each range written and no copy of it is kept, which spends time for storage; sets of more than
256 ranges are ignored (RFC 9110 §14.2 allows it). It was checked against an unbounded sort-and-merge on 20,000 random sets at every
storage size from 0 to 4: test a bounded algorithm against the plain unbounded one at every bound.<!-- src: HTTPBytes/RESULTS.md defect 1 ("It now sweeps the set … so the storage holds only the answer; checked against an unbounded sort-and-merge on 20,000 random sets at every storage size 0–4. Sets of more than 256 ranges are ignored (RFC 9110 §14.2)"); AGENTS.md "Merging into bounded storage: sweep, don't insert in arrival order" -->

**A parser that throws on one bad element loses the good ones.** One malformed element of a `Cache-Control` field threw the whole
field away, `no-store` with it, and a cache that loses a `no-store` stores what it must not. The parser no longer throws: bad
elements are skipped and an unclosed quote ends the field there. Whatever the grammar says about the malformed part, a field of independent
directives should be read as far as it can be.<!-- src: HTTPBytes/RESULTS.md defect 3 ("One malformed Cache-Control element threw the whole field away, no-store with it: parsing no longer throws; bad elements are skipped, an unclosed quote ends the field there"); HTTPBytes/WRITEUP.md "a Cache-Control with a malformed max-age lost its no-store, which a cache must not" -->

The other four: a `Retry-After` with a huge delay wrapped around to the past (the sum saturates); `HTTPTargetComponents` and
`HTTPRequestTarget.validate` disagreed on the forms `http:foo` and `example.com:443` without CONNECT (components now take the method and
split as `validate` decides); `Content-Disposition` took the first of two `filename` parameters, where RFC 6266 §4.1 calls the field invalid and a
recipient taking the last would see another name (repeated parameter names are refused); and `filename*` decoded to control
bytes and invalid UTF-8 (`%00%2F..%2Fx%0D%0A`; decoded names, and plain ones, must now be well-formed UTF-8 without C0, DEL, or C1
controls). The lesser fixes include `HTTPEntityTag.write` checking its characters (a quote or CR LF would inject) and
`Set-Cookie`'s `Path` and `Domain` refusing bytes past ASCII. Several decisions were deliberately left: `HTTPHost` accepts what RFC
3986's registered name does (`a,b`, `%00`), because a `Host` caller applies its own policy.<!-- src: HTTPBytes/RESULTS.md defects 2, 4, 5, 6 and "Lesser ones fixed" and "Not changed" paragraphs -->

#### Round 2: Zstandard bodies

`HTTPContentEncoder(.zstd)` encodes with BytesCompression's new `ZstdEncoder` ([section 8](#zstandard-encoding)), at level 3 with a
512 KiB window (`ZstdEncoder.Parameters.httpWindowLog`). RFC 9659 caps the window of the `zstd` content coding at 8 MB; against level
3's own 2 MB window, 512 KiB costs 0 to 4% in size on large bodies and nothing on bodies that fit in it, and takes the encoder's
streaming memory from 3.7 to 2.1 MB. `reset()` starts another body and keeps the encoder's memory. One MB of text, the encoder
reused, p50:<!-- src: HTTPBytes/RESULTS.md "round 2, Zstandard bodies" first paragraph ("level 3 with a 512 KiB window (`ZstdEncoder.Parameters.httpWindowLog`: RFC 9659 caps the window at 8 MB; against level 3's own 2 MB window it costs 0–4% in size, and the encoder's memory falls from 3.7 to 2.1 MB streaming). `reset()` starts another body keeping the encoder's memory") -->

| Coding | Instructions | Time | Mallocs |
|---|---|---|---|
| gzip, level 6 | 138 M | 11.0 ms | 0 |
| br, quality 5 | 183 M | 12.0 ms | 0 |
| zstd, level 3, 512 KiB window | 26 M | 1.7 ms | 0 |
<!-- src: HTTPBytes/RESULTS.md "round 2, Zstandard bodies" table (under load) -->

`Allocations:Body_encode_zstd` is 0. Zstandard bodies are tested decoded whole, fed 7 and 1,000 bytes at a time, and through the
coding-then-chunking pipeline and `HTTPBodyDecoder`.<!-- src: HTTPBytes/RESULTS.md same section ("`Allocations:Body_encode_zstd`: 0. Tests: zstd bodies decoded whole and fed 7 and 1,000 bytes at a time, and through the coding-then-chunking pipeline and `HTTPBodyDecoder`") -->

#### Round 2: the new rows

Beside the table above (`final-1`), round 2 added these, on the same machine:

| Workload | HTTPBytes | Others |
|---|---|---|
| 1 MB body encoded, zstd level 3 | **1.7 ms, 0 mallocs** | gzip level 6: 11 ms |
| 3,375 `Date`/`Last-Modified` values parsed | **44 µs** (13 ns each) | Foundation `Date.HTTPFormatStyle` 1,544 µs |
| 1,000 IMF-fixdates written | **20 µs** | Foundation 272 µs |
| QPACK encode, 383 responses, 4,096 table | 2,478 K instructions, **138 µs**; 53,137 B | ls-qpack 1,192 µs; 53,087 B |
<!-- src: HTTPBytes/WRITEUP.md "Results at a glance" (rows "1 MB body encoded, zstd level 3 (round 2)", "3,375 Date/Last-Modified values parsed (round 2)", "1,000 IMF-fixdates written (round 2)") and HTTPBytes/RESULTS.md "QPACK encoder: draining, Duplicate, names alone" (benchmark rows and byte counts) -->

#### What generalizes

- **Prototype the strategy on the real corpus, and judge by cycles.** An hour of three throwaway parsers chose the design
  that every later step built on, and the winner ran more instructions than the loser.<!-- src: AGENTS.md "HTTPBytes as a whole" bullet "Prototype the scanning strategy before the API" ("decided the design in an hour"); table above -->
- **A mask per block is a general parser shape**, not an HTTP one: classify 64 bytes into one register, then use
  integer arithmetic. `ByteBlock` is the Bytes API for it.
- **The gap between a prototype and a library is the compiler.** Inlining, a static function instead of a `mutating` one, and
  unchecked loads where the offset is proven were 1.12 to 0.84 cycles a byte.
- **Past a certain size, force-inlining stops working.** Take the rare part out of the loop, then check the loop for `bl`.
- **Fewer instructions on the critical path can lose.** `ld4` packing, batched masks, and per-line scans each ran fewer
  instructions and more cycles.
- **Make the expensive lookup lazy** when most callers do not need it, and make it branch-free when they do.
- **A zero-malloc gate finds the heap box.** It also forces the structure (workspaces, `reset`) that keeps the
  per-message path clean.
- **Let the owner of the bytes keep them** (QPACK's blocked streams), and let a parser's output be views of them.
- **Other implementations' tests, a differential against your own previous code, and an adversarial reader** found what the
  author's tests did not, and an exact table of differences keeps the first of these honest.

From round 2:

- **A technique from another library is a hypothesis about your corpus, and so is its absence.** Skip windows were the idea
  to copy, cursed-http's own response parser does not use them, and they made HTTP/1 responses slower at every setting tried.
- **Do not give a hot loop a second exit or a new call to try an idea.** Cap its bound and call the new path after it.
- **A framing stage must not be followed by one that can end first.** A body is one stage whose framing decides where it ends.
- **A simulated peer must be consistent with itself, and the harness must be shown to fail:** break the code on purpose once.
- **Fixed-width formats are SWAR problems.** A date is four words, one digit test, a perfect hash of the month, and Hinnant's
  arithmetic; 13 ns, where Foundation takes 457.
- **Vector scans are for runs of text; the grammar between them stays scalar.** Tokens, quoted strings, entity tags, and hosts moved
  to `firstByteOffset(where:)`, and an entity tag fell 76% in instructions.
- **A public generic must be `@inlinable`, or it boxes** ([section 5](#a-public-generic-that-is-not-inlinable-runs-unspecialized)):
  `Accept-Encoding` negotiation went from 24 M instructions and 16,000 mallocs to 3.51 M and none.
- **A literal that must be lowercase is an API trap**: fold both sides, or assert.
- **Bound the storage by the answer, not by the order of arrival** (the range sweep), and **do not let one bad element discard
  the good ones** (`Cache-Control`'s `no-store`).
- **Port a reference decision for decision, and its output is your test oracle**: the Zstandard encoder's frames are libzstd's,
  byte for byte ([section 8](#zstandard-encoding)).<!-- src: the sections above and AGENTS.md "HTTPBytes round 2" and "Zstandard encoding" lesson groups -->

**When not to follow it.** The index classifies a whole 64-byte block before it knows how much of it will be used, so work past a
short head's end is wasted: the batched variants (masks for 5 blocks at a time; a ring of 8) made 38-byte heads 55 → 86 and 55 → 92
cycles. Tiny heads are also where HTTPBytes is slowest against C parsers that may read past the end of their input; round 2
found that the gap is 8 to 11 cycles and that the partial-block copy is not its cause. And a technique tuned on
one corpus is tuned to it: measure on your own inputs.<!-- src: HTTPBytes/RESULTS.md "Tried and not kept" table (tiny 55 → 86 and 55 → 92); "round 2, HTTP/1's remaining gaps" (the copy isn't the cost); HTTPBytes/WRITEUP.md "Open items" (tiny heads) -->

### 13. Measuring honestly

Every number in this document comes from a benchmark, and every benchmark can lie. These are the ways the measurements here
nearly did, and the rules that came out of each.

#### Count instructions, then ask the CPU

Instruction counts are stable between runs, and times drift (Part I, ["Instructions, cycles, and time"](#51-instructions-cycles-and-time)). So judge a change
by instruction counts, allocation counts, and codegen, and compare *times* only within one interleaved run (Part I,
["Interleaved A/B runs"](#54-interleaved-ab-runs)).<!-- src: AGENTS.md "Compare times only within one interleaved run" -->
But instructions can mislead in both directions. Stitching cut time 40% while instructions barely moved ([section 7](#7-branches-and-data-dependent-work)); the
LZMA decoder's instructions rose while cycles fell; the Base64 encoder's instructions fell 2.3x with no change in speed
([section 2](#2-remove-the-checks-the-compiler-cannot-prove-away)). Where instruction counts and time disagree, `Tools/counters` says why (useful, discarded, front-end, and
back-end cycles).<!-- src: Bytes/Benchmarks/RESULTS.md "ChaCha20-Poly1305, stitched"; RESULTS.md LZMA; OPTIMIZATION-old.md "6." -->
Counts have their own noise too, under about 100 K instructions per iteration and in file-system benchmarks (Part I,
["Instructions, cycles, and time"](#51-instructions-cycles-and-time), gives the ranges).<!-- src: AGENTS.md "What one run can't tell" -->

#### One process per benchmark, so fixtures are lazy

package-benchmark starts the benchmark executable once to list the benchmarks and again for *each* benchmark, and every
start runs the whole `benchmarks` closure. That closure must only register: fixtures are made lazily in a benchmark's
`setup:` (which runs only in that process, unmeasured), and so are result checks. Base64's eager fixtures cost 3 s per
start: 340 s a suite, against 53 s lazy. Bytes' CompressionBenchmarks took 20 s per start (RSA key generation, every
codec's checks) over 830 starts: 5.6 hours, against 6.6 minutes lazy.

Keep registration in milliseconds (`time .build/release/TARGET --filter NOTHING`); cache slow or random fixtures (RSA keys,
compressed corpora); and put no data-derived counts in names (they need the data in every process).<!-- src: AGENTS.md "A benchmark costs a few seconds at most, and one run is enough" -->
A related trap: a slow reference in a fixture check (libzbitmap's encoder, 1 MB/s) cost a minute per process.<!-- src: Bytes/Benchmarks/RESULTS-lzbitmap.md Lessons last bullet -->

#### Only the work goes inside the measured loop

Code before `startMeasurement()` runs for every sample and counts toward `maxDuration`: a 32 MB random buffer made per
sample left NativeZip's CRC benchmarks with 2 samples. Inside `for _ in benchmark.scaledIterations` go no clocks, no fixture
lookups, and no result checks. Use the framework's `.throughput` times the work per iteration, not a custom timer.<!-- src: AGENTS.md "Code in the benchmark closure before startMeasurement()" and "Only the work goes inside" -->
Size iterations by the work: about 100 iterations or 0.5–1 s for work up to a millisecond, 20 for 5–50 ms, 1–3 for whole
archives and socket transfers. Instruction p50s match a 1,000-iteration run (within 0.3% for single-threaded work).<!-- src: AGENTS.md same -->

#### No lazy globals inside a measured loop

A global or `static let` read in the loop checks its `swift_once` token every iteration. For tens of milliseconds after
first use, libdispatch has not marked it done (it stores a generation until the quiescent counter moves), so each check
calls `swift_once` → `dispatch_once_f` (about 36 instructions). Bytes' "Runs: … 3-byte" rows were bimodal for this reason
(78 K and 104 K instructions; the p50 floated with load and looked like a regression). Capture fixtures as locals or
parameters. A row whose p0 and p50 differ by a constant per element is the sign.<!-- src: AGENTS.md "No lazy globals inside a measured loop" -->

#### Malloc counting biases comparisons with libraries

The malloc interposer costs about 10% on large transfers, and because it adds a cost to every allocation, it biased
comparisons with libraries that allocate per call. With it off, Google's Brotli decode of 1.6 KB went from 7 to 3.6 µs
p50, and CryptoKit's ChaCha20 at 64 B from 19 to 18 ms; Bytes' array-builder rows moved −4.5% in instructions, and bulk
reads into new arrays −16%. So timed configurations do not count mallocs, and allocation gates are separate benchmarks
(zero thresholds) run single-threaded, since the interposer traps on thread exit. Use names without spaces: thresholds
for names with spaces break (ordo-one/package-benchmark#373).<!-- src: Bytes/Benchmarks/RESULTS.md "Benchmark coverage pass" "Other changes"; AGENTS.md "package-benchmark's malloc interposer traps on thread exit" and "Allocations:" -->

#### Old and new in one run, and the references as controls

An unchanged reference row (zlib, libdeflate, CryptoKit) next to the changed one is the control: the Adler-32 work
reported zlib's and libdeflate's 1 MB rows unchanged (64 to 63 and 18 µs, on the M1 Max) beside Bytes' 36 to 19 µs. Do not
put the new path and its reference in one function behind a run-time flag, and check for function merging ([section 5](#5-inlining-and-specialization)).
Compare instruction counts across two builds of a harness with care: identical code differed by a constant of about 1.3 K
instructions per iteration between them.<!-- src: Bytes/Benchmarks/RESULTS.md "Adler-32 with UDOT" table; AGENTS.md "Old and new code in one benchmark run" -->
Benchmark sizes that are all multiples of a kernel's block size hide its remainder path: include odd sizes (Base64's
16-byte-remainder sizes hid a 42% short-input improvement).<!-- src: AGENTS.md "Benchmark sizes that are all multiples of a kernel's block size" -->

#### The machine's state is part of the measurement

Rows that go through the kernel read the *machine*, and three of this period's regressions that were not regressions came
from it.

- **A nearly full volume.** With the disk at 98% full, and `mediaanalysisd` and `corespotlightd` each using a core, every 32 MB
  extraction read 7–8 M more instructions (the kernel's allocation, on every codec: the writing side), and the eight-archive
  row ran 3–5x slower. It looked like the regression of the change under test. An interleaved control, the current tree with
  only that change reverted, read 174–177 M against 174–175 M for the current tree; after freeing 20 GB (39 GiB free) the rows
  were as before. Check `df` before believing a file-system row, and remove scratch trees (copies of the repository with their
  `.build`s are 2–5 GB each) once merged.
- **Probes that move with the kernel's state.** Disk's 1 GB single-file rows read −8% to +27% in instructions and 0.3x to 2.4x in
  time between two trees, *including the probes*, which are raw `pwrite` and `DispatchIO` calls in the benchmark itself,
  unchanged between the trees. The rows measure the page cache and APFS allocation after a gigabyte written per sample, with
  the new side always running after the old. Judge them within one process only.
- **Row names are shared with the repository.** `ab-old-*` and `ab-new-*` are tracked baselines in several packages, and
  `baseline update` overwrites them silently. Name a session's baselines after the work (`zipnative-old-1`), and check
  `git status` for modified `results.json` files after a run. And `Tools/bench-table` prints three significant digits, too
  coarse for a change of 0.3%: read exact p50s from an unslimmed `results.json` before slimming, or compare the codegen
  (identical object code settles it).
<!-- src: NativeAEA/RESULTS.md "2026-11-22, evening: allocations in an extraction, traced" paragraph "A full disk looks like a regression" ("NativeZip's rows run right after read +7–8 M instructions per 32 MB extraction (every codec, so the writing side) and the 8-archive row 3–5x slower. The volume was 98% full, with `mediaanalysisd` and `corespotlightd` each using a core. With 20 GB of this session's scratch trees removed (39 GiB free), an interleaved control … read 174–177 M against 174–175 M"); Disk/RESULTS.md "2026-11-22, later: the cleanups" bullet "1 GB single files" ("instructions −8 to +27% and times 0.3x–2.4x in either direction, in the probes too, which are raw `pwrite`/DispatchIO calls in the benchmark itself, unchanged between the trees … Judge them only within one process"); AGENTS.md "Baseline names are shared with the repository" and "`bench-table` prints 3 significant digits" (lessons; no RESULTS file) -->

#### A benchmark that sums results measures failures

HTTPBytes' first HTTP/1 baseline read 3.4x picohttpparser, which was too good. The request line's limit check compared the
whole remaining buffer against the 64 KiB head limit, and the corpus (232 KB) always had more than that after a head, so
every parse threw `headTooLarge` at once. The benchmark summed its results and never looked at them. Now every
benchmark's `setup:` checks that every item succeeded (the parsers' exact lengths, each field byte for byte against the
encoder's input), never a sum or a count. A speedup that is too large is a suspect: look at what was computed.<!-- src: HTTPBytes/RESULTS.md "A bad first baseline" (http1-1: "the request line checked the whole remaining buffer against the 64 KiB head limit … the benchmark summed results without checking them"; "every benchmark's setup now checks that every head parses"); HTTPBytes/WRITEUP.md "How it was measured" ("The first HTTP/1 baseline read 3.4x picohttpparser") -->

#### Compare against your previous code, as a differential

For an optimization pass over a parser, compile the previous sources as a second module in the measuring harness and compare
every output, not just the final state. HTTPBytes' seven steps past cursed-http ran against its predecessor on 1.6 million
inputs (corpus heads and their mutations, whole and fed 1, 7, and 64 bytes at a time, under four option sets), comparing
every event and error: 9 seconds, and the first run caught a scan that skipped a block, which no corpus test noticed.<!-- src: HTTPBytes/RESULTS.md "2026-11-23: HTTP/1 heads against cursed-http" intro (the old-versus-new differential; events and errors equal on 1.6 million inputs); AGENTS.md "HTTP/1 heads against cursed-http" last bullet ("1.6 M inputs in 9 s … found a scan that skipped a block on its first run") -->

#### Import other implementations' test suites, with an exact table of differences

The test cases of llhttp (258), Go's `net/http`, h11, httparse (305), http-parser (101), picohttpparser (94), cursed-http
(300), HTTP Garden, PortSwigger's request-smuggling permutations, and h2o's fuzz corpus (1,972 inputs) are run through the
library, and each outcome is compared with the suite's verdict. Every deliberate disagreement is an entry in a `differences`
table with its reason, and an entry that stops differing fails the test (as does a `withKnownIssue` that stops
recording), so the table stays exact and a difference cannot turn into a bug unseen. The suites found 11 real gaps that the
library's own tests had not, among them raw UTF-8 request targets, an empty `Transfer-Encoding`, the chunk-extension
grammar, and CONNECT with a body.<!-- src: HTTPBytes/WRITEUP.md "Correctness" "Other implementations' test suites" table (258, 305, 101, 94, 300, 1,972) and "The suites found 11 real gaps"; AGENTS.md "HTTPBytes as a whole" bullet "Import other implementations' test suites as differential tests, with a table of deliberate differences" -->
An adversarial review by an agent given the code and not the conclusions found 15 more, among them CR LF injection
through an unchecked append and a smuggling check that `Content-Length: ,` slipped past; each became a probe package, then a
regression test.<!-- src: HTTPBytes/WRITEUP.md "Adversarial reviews" (15 confirmed defects) -->

#### A simulated peer must be consistent with itself, and the check must be shown to fail

A test that stands in for the other end of a protocol has to obey the protocol's own promises. The QPACK encoder's harness
decoded each section only after 16 sections' worth of encoder stream had arrived, and it failed an encoder whose
acknowledgments came 4 sections late. The encoder was right: an acknowledgment says the peer has decoded the section, so the
encoder may evict its entries afterwards. Deliver late only as far as the feedback says. Then break the encoder on purpose once
(here: evicting without regard to unacknowledged sections, and allowing one blocked stream too many) and confirm the harness
fails; [section 12](#round-2-qpack-at-ls-qpacks-size) has the case.<!-- src: AGENTS.md "A simulated peer must be consistent with itself (QPACK, 2026-11-23; HTTPBytes/RESULTS.md)"; HTTPBytes/RESULTS.md "QPACK encoder: draining, Duplicate, names alone" Tests paragraph -->

#### Several agents at once

Several people (or agents) building and benchmarking at once load the machine: unchanged code measured 5–15% slower. Judge
by instruction counts, allocation counts, and codegen during the work, and re-run timed benchmarks one package at a time on
an idle machine afterwards. Five agents benchmarking under one lock spent an hour of a three-hour task waiting in the
queue, and each run still met the others' builds, so a lock is only for a final timing.<!-- src: AGENTS.md "Parallel agents"; "Five agents benchmarking under one lock" -->

#### Fresh machines and indexers

After moving to new hardware, re-run something unchanged on an idle machine first. Spotlight and `mediaanalysisd` were
indexing the new files during the first M1 Max runs; one memory-bound row (CRC-32 over 32 MB) read 2.2x slow, which was
caught because a standalone probe disagreed with it. A `.metadata_never_index` marker keeps `TestData/` out of the index,
and benchmark output goes in a `*.noindex` directory.<!-- src: AGENTS.md "After moving to new hardware" and "Extracting files: the kernel is the limit" last sentence -->

#### The second machine: M1 Max against M3 Ultra

The same compiler (Swift 6.4.4) and code were run again on an Apple M1 Max, the cheapest way to separate what the code
does from what the chip does.<!-- src: Writeups/M1-Max-vs-M3-Ultra.md intro; OPTIMIZATION-old.md "15." -->

| | M3 Ultra | M1 Max |
|---|---|---|
| Cores | 24 P + 8 E | 8 P + 2 E |
| P-core clock | about 4.05 GHz | about 3.23 GHz |
| Memory bandwidth | 819 GB/s | 400 GB/s |
| Instruction-set features used | NEON, AES, PMULL, SHA, CRC32, DotProd | the same (no I8MM/BF16) |
<!-- src: Writeups/M1-Max-vs-M3-Ultra.md "The machines" -->

**One core is 1.3x slower, which is the clock.** Over 773 Bytes benchmarks whose instruction counts are the same on both
machines, an M1 Max core takes 1.31x as long as an M3 Ultra core (geometric mean of the time ratio). The clock ratio is
1.25 (4.05 against 3.23 GHz), so the M3 gets about 4% more done per clock. Other packages: Base64 (then its own package)
1.27, MQTT 1.34, NativeZip 1.33, BinaryParsingComparison 1.30, SocketStream 1.32. The three builds (NEON, portable C, Swift
only) stay within 1.4% of each other on both chips, so the portable builds' near-zero cost (Part II, ["Builds and traits:
optimized, `Portable`, and no-C"](#15-builds-and-traits-optimized-portable-and-no-c)) is not an M3 artifact.

Bytes' standings against the references hold. Zstandard's lead over libzstd shrinks from 1.29x to 1.09x on large inputs,
and one flip (LZ4 swift-help, Bytes 0.93x to 1.05x of `ParserSpan`'s, same instructions) was not investigated.<!-- src: OPTIMIZATION-old.md "15." paragraph 1; Writeups/M1-Max-vs-M3-Ultra.md "The short version" and "Per package" -->
The ratio is not one number: about 1.06 at 1 KB, about 1.5 for 100–400 KB inputs (an L2-sized working set; cause not
found), and 1.3 for multi-MB inputs.<!-- src: OPTIMIZATION-old.md "15." -->
Where the chips differ beyond the clock: raw SIMD stores run at 114 GB/s against 62 on one core (1.85x; reads 78 against
61); back-references at distances 1–7 are 1.6–1.85x slower at identical instructions (a guess: partial-width loads that
cannot forward from recent stores; not probed); and latency-bound code keeps up (hashes 1.14–1.21, hardware CRC-32
1.08–1.15, small-input Zstandard 0.97–1.04).<!-- src: Writeups/M1-Max-vs-M3-Ultra.md "Where the two chips differ beyond the clock"; the M3 store rate from Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra" (baseline m3-final): BytesBenchmarks row "Write: Raw SIMD store (reference), in cache (4 MB)" 36,639 ns, and the 78 GB/s read from Tools/probes/results/M3-Ultra-2026-11-20/mem-threads.tsv (1 thread 78.5) -->

**Many cores: the core count is the difference.** With the lane count following the chip (24 lanes against 8), the
parallel codecs are 2.4x apart (geometric mean over 60 pairs), and memory-bound reads on all cores 1.9x (bandwidth ratio
2.05). File-system work shows what the extra cores are for: extracting a 2,000-file archive with the current code is fastest with 4 workers on
the M3 Ultra (64 ms) and with 8 on the M1 Max (81 ms; 4 workers: 106 ms). A worker count found on one chip has a different knee on the
other: derive worker counts from the machine.<!-- src: OPTIMIZATION-old.md "15." paragraph "Many cores"; Writeups/M1-Max-vs-M3-Ultra.md "File-system work" -->

**What one M1 Max core measured** (`Tools/cpu-probe`, 2026-11-21; cycles from a 3.21 GHz clock measured in the same run):<!-- src: Writeups/M1-Max-vs-M3-Ultra.md "What the M1 Max can do" -->

| Instruction | Latency (cycles) | Per cycle |
|---|---|---|
| `add`, `eor`, `eor3`, `zip`, `uzp`, `ext`, `tbl` and `tbx` with 1 register, `tbl` with 2 | 2 | 4 |
| `udot`, `pmull`, `aese`, `mul`, `usra` | 3 | 4 |
| `aese`+`aesmc` (fused) | 3 per pair | 3.9 pairs |
| `fmla.4s` | 4 | 4 |
| `tbl` with 3 / 4 registers | 4 | 2 / 1.3 |
| `tbx` with 2 / 3 / 4 registers | 4 / 6 / 8 | 2 / 1.3 / 0.95 |
| `sha256h`, `sha512h` | 4, 2 | 0.5 |
<!-- src: Writeups/M1-Max-vs-M3-Ultra.md same table (rows selected) -->

Memory: L1 3 cycles, L2 17.6 cycles, 16–32 MB 40–70 ns (system-level cache with page walks), DRAM about 123 ns; one core
reads 60 GB/s, two 112 GB/s, and all ten only 125 GB/s.<!-- src: Writeups/M1-Max-vs-M3-Ultra.md same section; Bytes/Benchmarks/RESULTS.md "What the cores can do" read bandwidth -->

The same rows beside the M3 Ultra; the M1 Max columns here are the first probe's, which the table above supersedes.
**What one core of each measured** (probes; the M1 Max's cycles scaled from a calibration that read 2.82 GHz, ±15%; the
M3 Ultra's read 4.05 GHz, its clock. "Per cycle" from eight independent chains, the M3's also from 16). The M3 Ultra's
numbers come from `Tools/probe`, which runs the same measurements on any Apple silicon Mac so two machines compare row by
row; its method point is that a throughput probe needs latency × width independent chains (12 for a 3-cycle instruction on
four pipes), so it measures 8, 16, and 24:<!-- src: Writeups/M1-Max-vs-M3-Ultra.md "What each core can do"; Bytes/Benchmarks/RESULTS.md "2026-11-20, M3 Ultra"; Tools/probes/README.md, Tools/probes/results/M3-Ultra-2026-11-20/insn.tsv and insn-clock.tsv (clock median 4.050 GHz before, 4.056 after) -->

| Instruction | M1 Max latency (cycles) | M1 Max per cycle | M3 Ultra latency | M3 Ultra per cycle (8 / 16 chains) |
|---|---|---|---|---|
| `add`, `eor`, `eor3`, `zip`, `uzp`, `ext`, `tbl` with 1–2 registers | 2 | 4 | 2 | 4 / 4 |
| `udot`, `pmull`, `aese`, `mul`, `usra` | 3 | 2.7 | 3 | 2.7 / 4 |
| `tbl` with 3 registers | 4 | 1.9 | 4.0 | 1.6 / 2.0 |
| `tbl` with 4 registers | 4 | 1.3 | 4.9 | 1.1–1.4 (varies between runs) |
| `tbx` with 4 registers (chained through the index) | 8 | 1.0 | 6 | 0.8–1.0 (varies between runs) |
| `sha256h`, `sha512h` | 5, 3 | 0.5 | 4, 2 | 0.5 / 0.5 |
<!-- src: Writeups/M1-Max-vs-M3-Ultra.md same table (rows selected, M1 Max columns); Tools/probes/results/M3-Ultra-2026-11-20/insn.tsv (add, zip1, uzp1, ext, tbl 1 and 2 regs: 2 cycles, 4 a cycle; udot.4s, pmull, aese, mul.4s, usra: 3.01, 2.65–2.69 at 8 chains, 4.00 at 16; tbl 3 regs 3.99 cycles, 1.59 / 2.05; tbl 4 regs 4.90, 0.91 / 1.08; "tbx 4 regs via index" 6.05, 0.86 / 0.76; sha256h 4.01, sha512h 2.00, 0.50); the earlier probe in RESULTS.md "2026-11-20, M3 Ultra" read tbl 4 regs 1.35 a cycle and tbx 4 regs 0.85 / 0.95 -->

The 2.7 per cycle is the eight-chain method's limit for a 3-cycle instruction, not the M1 Max's: with 16 chains the M3
Ultra issues these at 4. Memory on the M1 Max: L1 3 cycles, L2 17–18 cycles, system-level cache 35–52 ns, DRAM about
122 ns; one core reads 61 GB/s, two 115 GB/s, and all ten only 126 GB/s. On the M3 Ultra: L1 4 cycles (1.0 ns), L2 18–24
cycles, system-level cache 25–64 ns (16–64 MB), DRAM about 127 ns; one core reads 78 GB/s from DRAM and stores 118–125, and
reads level off at about 254 GB/s from 16 threads.<!-- src: Writeups/M1-Max-vs-M3-Ultra.md same section (M1 Max); Tools/probes/results/M3-Ultra-2026-11-20/mem-latency.tsv (L1 0.99–1.00 ns, 3.9–4.0 cycles; L2 4.41–6.03 ns, 17.9–24.4 cycles; 16, 24, 32, 48, 64 MB: 24.6, 30.7, 40.8, 54.2, 64.1 ns; 256 MB 127.0 ns), mem-bandwidth.tsv (reads 78.3 GB/s and stores 118.0 at 256 MB, stores 124.4–125.5 at 32–128 MB), mem-threads.tsv (1 thread 78.5, 16 threads 252.2, 24 254.8, 32 253.3) -->
Read as cost per lookup, this core's `tbl` with one or two table registers takes one vector slot, with four about three,
and a four-register `tbx` four, with 8 cycles of latency ([section 4](#4-write-simd-by-hand-and-reach-instructions-swift-cannot-name)).<!-- src: Bytes/Benchmarks/RESULTS.md "What the cores can do" paragraph after the table; AGENTS.md "Measure a core's instructions rather than assuming" -->

**What changed in the code for the M1 Max.** One instruction nobody had used (`udot`; [section 4](#4-write-simd-by-hand-and-reach-instructions-swift-cannot-name): Adler-32 from 29.6 to
56.9 GB/s) and the efficiency cores ([section 10](#10-parallelism)). **What did not help:** software prefetch on CRC-32 (the fold already runs
at the memory rate; a distance of 8 KB lost 10–49%), interleaving two halves, and buffer alignment. Candidates not tried:
AES counter mode with 12 blocks in flight instead of 8 (it is at the bound of eight 3-cycle round chains, and the units
allow about 1.5x more), store-heavy and short-copy code, and Base64's decoder lookups (tuned around the M3's micro-op
counts for `tbl` and `tbx`).<!-- src: Writeups/M1-Max-vs-M3-Ultra.md "M1 Max-specific optimizations explored"; OPTIMIZATION-old.md "15." "What did not help" -->

**The method, in three rules.** Keep Instructions beside times when comparing machines: they show whether the same code
ran (771 of 773 matched). Where benchmarks name the chip's lane count, pair them by hand. And when a standalone probe (a C
copy of the kernel, or a plain Swift loop over the API) disagrees with a benchmark row, believe neither until you know why.<!-- src: Writeups/M1-Max-vs-M3-Ultra.md "How the comparison was made"; AGENTS.md "A second machine" lessons -->

## Part IV. Concurrency and further reading

Parts I to III made one thread fast. This part is about the thread count, and about the cost of the machinery that
moves work between threads. Swift's concurrency model is built from a few pieces (tasks, executors, suspension points,
isolation), and each has a runtime cost that is invisible in source code and visible in a profile. The part starts
from first principles, then follows three real programs that use the machinery: SocketStream (the one that pushes
hardest, on a toolchain that is not yet released), NativeAEA (which replaced its own threads with structured
concurrency), and NativeZipArchive plus BytesAsync (worker pools and offloading). It ends with the limitations these
projects met and a reading list.

### 1. Swift concurrency for performance, from first principles

#### 1.1 Tasks, executors, and the cooperative pool

A **task** is a unit of asynchronous work: an `async` function call tree with its own priority, cancellation flag, and
task-local values. A task is not a thread. It is a heap object that the runtime schedules onto threads in pieces.
<!-- src: language semantics, SE-0304 structured-concurrency; NativeAEA/ARCHITECTURE.md §9 "everything runs on Swift concurrency's cooperative pool ... as child tasks" -->

An **executor** is the thing that runs those pieces. Each piece of a task between two suspension points is a **job**,
and an executor runs jobs one after another (a serial executor) or several at a time (a concurrent one). The default
concurrent executor is the **cooperative pool**: a fixed set of threads, one per core, shared by every task in the
process that has no other executor. "Cooperative" means a task is expected to return its thread quickly, by
finishing or by suspending, so that the other tasks waiting for a thread get one.
<!-- src: NativeAEA/ARCHITECTURE.md §9 "Executors and priorities": "The cooperative pool has one thread per core" -->

The word that matters for performance is **suspension point**: an `await` where the task may give up its thread. A
task suspends when what it waits for is not ready (a socket with no data, a lock held by someone else, a continuation
that nobody has resumed). The runtime then stores the task's state in its heap-allocated frame, the thread picks up
another job, and when the awaited thing happens, some thread resumes the task. An `await` of something that is
already ready does not suspend, and costs only a call.
<!-- src: language semantics; SocketStream/RESULTS.md "Measured with Instruments": "Suspensions follow socket waits, not packets" -->

The cooperative pool has one property that the rest of this part keeps meeting. A job that does not suspend holds its
thread for as long as it runs. NativeAEA's decoder tasks decode a 16 MiB xz block in about 100 ms without a single
suspension, so 32 of them can occupy every thread of the pool while a just-resumed writer waits for one.
<!-- src: NativeAEA/ARCHITECTURE.md §9 "Executors and priorities" -->
[Section 3](#3-nativeaea-from-threads-to-structured-concurrency) shows what was measured to find out whether this matters, and that here it did not.

#### 1.2 Executor checks and real hops: `swift_task_switch`

Every `async` function starts on some executor, and the compiler must guarantee that code runs where its isolation says
it should. It does so with a runtime call, `swift_task_switch`, at the entry of an `async` function and after each
call it makes that might have changed executors. The call has two outcomes:

- **The check.** The task is already on the executor the function needs. `swift_task_switch` returns immediately and
  the function continues on the same thread. It is a runtime call, so it costs instructions, but nothing moves.
- **The hop.** The task is on the wrong executor. The runtime usually enqueues a job on the right executor and the
  current thread goes back to the pool; the task continues later, usually on another thread, with cold caches. (When
  the switch is between the generic executor and an idle default actor, the runtime can instead take the actor on the
  current thread and keep going.)

SocketStream's measurements separate the two: its 55–113 `swift_task_switch` calls per transfer are all checks that
leave the task where it is, and Instruments recorded no state change for any of them.
<!-- src: SocketStream/RESULTS.md "Measured with Instruments (2026-11-09)": "the 55–113 swift_task_switch calls per transfer are fast-path checks that leave the task where it is" -->
Counting calls tells you how many checks ran. Only a task-state trace (Instruments' Swift Concurrency template, via
`Tools/tasks`) tells you whether any of them moved a task.
<!-- src: SocketStream/RESULTS.md "The breakpoint counts above can't tell a check from a move"; AGENTS.md "Tools" section on tasks and runtime-count -->

#### 1.3 Isolation, actors, and where a function runs

**Isolation** is the compiler's record of which actor (if any) may touch a piece of state. An **actor** is a type whose
mutable state is isolated to it: only code running on the actor's serial executor touches the state, so no lock is
needed. Code outside an actor is **`nonisolated`**. A function can also be isolated to a **global actor** such as
`@MainActor`.
<!-- src: language semantics, SE-0306 actors -->

What a `nonisolated async` function does about executors is the question that matters for cost. Under SE-0338's rules
(Swift 5.7 onward, unless the newer behavior below is turned on), a `nonisolated async` function always runs on the
**generic executor** (the cooperative pool), whatever actor called it, switching there on entry, after each call
returns, and after each suspension. A caller on an actor therefore hops off the actor on every call and back on
afterwards. (Before SE-0338, such a function stayed on the caller's actor until it suspended.) SE-0461 adds two
spellings that make the choice explicit:
<!-- src: SE-0338 "Proposed solution" (status: Implemented (Swift 5.7); describes the earlier "sticky" behavior) -->

```swift
// Runs on the caller's executor. No switch on entry, none after calls to other nonsending code.
nonisolated(nonsending) func parse(_ buffer: inout ByteBuffer) async throws -> Int { … }

// Always runs off any actor: on the global concurrent executor (or the task's preferred executor, section 1.7).
@concurrent func compressAll(_ input: [UInt8]) async -> [UInt8] { … }
```
<!-- src: SE-0461 async-function-isolation (incl. "A task executor preference can still be used to configure where a nonisolated async function runs"); usage in SocketStream/Sources/SocketStream/Transfer.swift (`nonisolated(nonsending)`) and Bytes/Sources/BytesAsync/Offloading.swift (`@concurrent func perform`) -->

- **`nonisolated(nonsending)`** means "run on whatever executor my caller is on". The function adds no switch on entry,
  and calls from it to other `nonisolated(nonsending)` code need no check when they return (a call to an actor-isolated
  or `@concurrent` function still moves there and back). It is the right choice for code that is already where it wants
  to be and only calls other code that is too. Because the body runs in the caller's isolation, what it receives does
  not cross an isolation boundary and need not be `Sendable`. This is why it can take `inout` parameters and borrowed
  spans at all. The price is that heavy synchronous work in it runs on the caller's actor, if the caller is on one.
  <!-- src: Bytes/Sources/BytesAsync/AsyncByteTransform.swift doc "The requirement is nonisolated(nonsending): it borrows the caller's spans (inout OutputRawSpan)"; AGENTS.md "async APIs that take inout storage are nonisolated(nonsending) (otherwise @concurrent, and callers must send self)" -->
- **`@concurrent`** means "run on the global concurrent executor (or the task's preferred task executor), never on the
  caller's actor". It is the right choice for heavy synchronous work that should stay off an actor. Its parameters and
  result cross an isolation boundary, so they must be `Sendable` (or `sending`).

Two Package.swift settings in this repository show the direction. Bytes enables the upcoming feature
`NonisolatedNonsendingByDefault`, which makes a plain `nonisolated async` function mean `nonisolated(nonsending)`;
SocketStream's notes say swift-platform-executors builds with it too, which is why its own async APIs run on their
caller's executor.
<!-- src: Bytes/Package.swift line 17 `.enableUpcomingFeature("NonisolatedNonsendingByDefault")`; SocketStream/RESULTS.md "Concurrency: no hops": "like swift-platform-executors' own (it builds with NonisolatedNonsendingByDefault)" -->
SocketStream's package settings do not enable the feature, so its source spells `nonisolated(nonsending)` on every async
function.
<!-- src: SocketStream/Package.swift `settings` lists swiftLanguageMode, strictMemorySafety, Lifetimes, ExistentialAny, MemberImportVisibility (no NonisolatedNonsendingByDefault) -->

NativeAEA's rule is the same idea in two layers: the public entry points are `@concurrent` (they start their own task
tree off the caller's actor), and every internal async function is `nonisolated(nonsending)`, so work inside the tree
makes no hops.
<!-- src: NativeAEA/ARCHITECTURE.md §9 "The public functions are @concurrent; everything inside is nonisolated(nonsending)"; AGENTS.md Lessons "Threads to structured concurrency" -->

#### 1.4 `Sendable` and `sending`

A type is **`Sendable`** when its values are safe to use from several concurrency domains at once: immutable, or
protected by a lock. **`sending`** (SE-0430) is a per-value guarantee instead: the value is not shared with anything the
caller keeps using, so it can move to another domain even though its type is not `Sendable`. Values passed into a
`@concurrent` function cross a boundary, so they must be one or the other. The task-creation APIs take their closures as
`sending` rather than `@Sendable` (`TaskGroup.addTask`'s `operation` is `sending @escaping @isolated(any)`), so a
child task's closure may capture non-`Sendable` values the parent no longer uses. The repository's rule is `sending`
over `@Sendable` where it fits.
<!-- src: AGENTS.md "Ground rules": "`sending` over `@Sendable` where it fits"; SE-0430 "The `Task` creation APIs" adopt sending; MacOSX.sdk _Concurrency.swiftinterface `addTask(name:executorPreference:priority:operation: sending @escaping @isolated(any) …)` -->
One trap met in these projects is that a `sending` closure cannot append to a local array that the caller reads
afterwards, while a plain (non-escaping, non-`sending`) closure parameter can.
<!-- src: AGENTS.md Lessons "`sending` closures can't append to a caller's local that's read afterwards; a plain closure parameter can" -->

NativeAEA's concurrency primitives, which only hold `Mutex` and `Atomic` state, are checked `Sendable`; classes whose
fields only one task touches are `@unchecked Sendable`, with the reason stated beside the field.
<!-- src: NativeAEA/ARCHITECTURE.md §9 "Sendable" -->

#### 1.5 Structured and unstructured tasks, priorities, cancellation

**Structured concurrency** (SE-0304) means a child task cannot outlive the scope that created it. A
`withTaskGroup`, `withDiscardingTaskGroup` (SE-0381, for children whose results you do not collect), or `async let` makes
children that the parent waits for. The runtime knows the whole tree, so it propagates cancellation, and priority
escalation, down it. **Unstructured** tasks (`Task { }`, `Task.detached`) are outside the tree: nothing waits for them,
and cancelling the code that created them does not cancel them. NativeAEA has no `Task.detached` and no threads of
its own: each operation is one task tree.
<!-- src: SE-0304, SE-0381; NativeAEA/RESULTS.md "2026-11-19 (concurrency)": "threads, NSConditions, ... concurrentPerform loops, and Task.detached are gone: each operation is one task tree" -->

A task has a **priority**, which a child task inherits from its parent. An `async` `main` task runs at priority 21 (`.medium`, the default), which is not `.userInitiated` (25); a command that wants its work at a specific
priority starts a child task with that priority and does the work there.
<!-- src: AGENTS.md Lessons "An async main task runs at priority 21, not user-initiated: start the work in a child task with a priority"; NativeAEA/ARCHITECTURE.md §1 "Its async main task runs at the default priority"; TaskPriority raw values (medium 21, userInitiated 25) -->

**Cancellation** is cooperative: cancelling a task sets a flag, and code must look at it (`Task.isCancelled`,
`try Task.checkCancellation()`) or register a handler. `withTaskCancellationHandler` runs a closure, synchronously, in
whoever cancels. NativeAEA uses one handler per operation, around its whole task group, which fails the extraction
context and closes the pools and queues so every waiter wakes. That one handler beats a handler per `await`.
<!-- src: NativeAEA/ARCHITECTURE.md §11 "Cancellation has one handler per operation"; AGENTS.md Lessons "One withTaskCancellationHandler per operation ... beats a handler per await" -->

#### 1.6 Continuations: checked and unsafe

An `async` function can wait for something that is not itself `async` (a callback, a lock release, another thread's
signal) with a **continuation**: `withCheckedContinuation` or `withUnsafeContinuation` suspends the task and hands you a
value to call `resume` on exactly once. The **checked** form verifies that, at the price of an allocation per wait;
the **unsafe** form does not check and does not allocate. In code that waits about once per file, that allocation is
worth avoiding. BytesAsync's primitives (which began as NativeAEA's) use `UnsafeContinuation` in release builds (inside a
`@safe` wrapper, `Continuation`) and `CheckedContinuation` in debug builds, where the check is worth the allocation.
<!-- src: NativeAEA/ARCHITECTURE.md §9 "The primitives": "Release builds use UnsafeContinuation ... debug builds use CheckedContinuation ... (it allocates a canary per wait, so release builds don't use it: writers wait for the file system about once per file)"; AGENTS.md Lessons "A CheckedContinuation allocates per wait" -->
BytesAsync's Dispatch hop does the same, with a comment stating why it is safe: "resumed exactly once, by the block,
after `work` returns".
<!-- src: Bytes/Sources/BytesAsync/Offloading.swift `perform(on:_:)` comment -->

A wait built this way follows a fixed recipe:

1. Take the lock and check whether the thing is already ready. If so, return **without suspending**.
2. If not, suspend, and inside the continuation's body check again under the lock, then store the continuation there,
   so a wake-up cannot slip between the check and the store (no lost wake-ups).
3. The waker takes a waiter out under the lock and resumes it **after releasing** the lock.
<!-- src: AGENTS.md Lessons "Waits are Mutex state plus a continuation, taken synchronously under the lock when nothing has to wait; check again under the lock inside the continuation's body, remove a waiter under the lock, resume it outside"; NativeAEA/ARCHITECTURE.md §9 "The primitives" -->

#### 1.7 Task executors and executor preference

A **task executor** (SE-0417) is an executor that a task, and its child tasks, can prefer. The preference does not put
the task on that executor's thread by decree; it says that nonisolated async code in the task, and in children it
creates, runs there rather than on the global pool. Two APIs matter in this repository:

```swift
group.addTask(executorPreference: someExecutor) { … }   // a child that prefers someExecutor
```
<!-- src: SocketStream/Sources/SocketStream/Transfer.swift run(), runPair() `group.addTask(executorPreference:)`; SE-0417 task-executor-preference -->

and `TaskExecutor` itself, a protocol a type conforms to in order to run jobs on threads it owns. SocketStream's
`PThreadTaskExecutor` (from swift-platform-executors) conforms to it.
<!-- src: SocketStream/.build/checkouts/swift-platform-executors/Sources/PlatformExecutors/PThread/PThreadTaskExecutor.swift line 43 `public final class PThreadTaskExecutor: TaskExecutor` -->
The reasons to want one:

- **Placement.** A socket's event loop, the task reading it, and its buffers can all stay on one thread and one core's
  caches.
- **Isolation from the pool.** A task that blocks or burns CPU on its own executor does not hold a cooperative thread.
- **Fewer wake-ups.** If the I/O layer can resume a suspended task directly on the thread that is already running the
  event loop (the loop that waits for sockets to become ready), a read that completes needs no hop at all. [Section 2](#2-socketstream-what-the-pr-toolchains-io-interfaces-made-possible)
  shows exactly that.

### 2. SocketStream: what the PR toolchain's I/O interfaces made possible

#### 2.1 What it is

SocketStream (formerly MQTTSocketStream) asks how fast structured data can travel through a local socket. MQTT 5 PUBLISH
packets are encoded with `AlignedBytesWriter` on one end of a loopback TCP connection, then read and parsed with
`AlignedBytesReader` on the other, and every packet is checked: its identifier is the next in sequence, its topic matches
byte for byte, its payload is the size sent. Optionally the stream is compressed (Bytes' DEFLATE or Brotli) and
encrypted (TLS 1.3 records, ChaCha20-Poly1305) through Bytes pipelines, and undone at the other end.
<!-- src: SocketStream/README.md first paragraph -->
It is both a benchmark of Bytes and MQTT in a real transfer, and the vehicle for trying out unreleased concurrency
interfaces. Its sources are 993 lines in six files: 899 in the library's five, 94 in the command-line tool.
<!-- src: wc -l SocketStream/Sources/SocketStream/*.swift (23+270+186+73+347 = 899) plus Sources/socket-stream/TransferCommand.swift (94) = 993 -->

#### 2.2 Which interfaces, from which toolchain

Three different things are unreleased or experimental, and it helps to keep them apart.

1. **A compiler pull request.** swift-platform-executors' I/O is behind its `ExperimentalIO` trait and needs a toolchain
   with swiftlang/swift#91981, "the split continuation". That PR is not merged, so no release or `main` snapshot has
   it, and swiftly cannot install it. SocketStream is built and measured with the PR's macOS toolchain build 2511
   (Swift 6.5-dev, October 25). The package names it in its `.swift-toolchain` file as `pr-91981`.
   <!-- src: SocketStream/README.md "Requirements"; SocketStream/.swift-toolchain contents "pr-91981" -->
2. **A package.** [swift-platform-executors](https://github.com/swiftlang/swift-platform-executors) provides
   `TCPListener`, `TCPConnection`, and `PThreadTaskExecutor` (a task executor that owns its threads; SocketStream picks
   its I/O backend built on kqueue, the macOS kernel's event-notification interface). SocketStream pins it to one revision, `bd74d56cde5767a8bf43f803379b00790a7e9798`, with
   `traits: ["ExperimentalIO"]`, because "the package changes quickly, along with the toolchain it requires".
   <!-- src: SocketStream/Package.swift dependencies and comment; SocketStream/README.md first paragraph; swift-platform-executors PThreadTaskExecutor.swift `withExecutor(name:poolSize:stackSize:ioBackend:blockingPoolSize:body:)` -->
3. **The PR's runtime.** The package "calls `Continuation.resumeSynchronously` and a newer `withContinuation` form",
   and a process must load the toolchain's Concurrency runtime, not the OS's. With the OS's, "the first socket
   operation crashes (a null access in `withContinuation`), or the process exits silently". Package.swift therefore embeds the runtime path in each
   executable with `ld -dyld_env`, because `swift test` and the benchmark plugin replace `DYLD_LIBRARY_PATH` for the
   processes they start.
   <!-- src: SocketStream/RESULTS.md "Notes on swift-platform-executors" ("The runtime"; "Which toolchain"); SocketStream/Package.swift `useToolchainRuntime` -->

The interfaces SocketStream's sources call are these:

| Interface | Use in SocketStream |
|---|---|
| `TCPListener.bind(to:)`, `.localAddress`, `.accept()`, `.close()` | Each sender/receiver pair binds a listener to loopback port 0 and accepts one connection |
| `TCPConnection.connect(to:)`, `.write(from:)`, `.read(into:)`, `.close()` | The sender writes a batch from a span; the receiver reads into an output span |
| `PThreadTaskExecutor.withExecutor(name:poolSize:ioBackend:)` (as SocketStream calls it) with `ioBackend: .kqueue` | Starts a named executor of `poolSize` threads for the duration of a closure |
| `group.addTask(executorPreference:)` | Starts each task on the executor it should run on |
| `IOError` (typed throws from `read`) | `ByteBuffer.read(from:)` is `throws(IOError)` |
<!-- src: SocketStream/Sources/SocketStream/Transfer.swift (runPair, withExecutors, sendPackets, receivePackets) and ReceiveBuffer.swift -->

Two rules of the package shaped the design:

- **A connection keeps the scheduler it was created on.** Accepting every connection in one task would put every
  receiver's I/O on that task's executor. So each pair binds its own listener on its receiver's executor, and the
  receiver starts the sender as a child task that prefers the sender's executor.
  <!-- src: SocketStream/RESULTS.md "Notes on swift-platform-executors"; Transfer.swift doc comment on `run` -->
- **Leased buffers are not implemented on `PThreadTaskExecutor`** (`fatalError("Leasing buffers is not implemented
  yet")`), so `TCPConnection`'s closure-based `read { }` and `write { }`, which would let `BytesWriter` encode straight
  into a platform buffer, cannot run there. The sender therefore encodes into its own batch and writes that.
  <!-- src: SocketStream/RESULTS.md "Leased buffers" -->

#### 2.3 The structure of a transfer

For `connections` pairs, `Transfer.run` starts executors, then a task group, one child per pair:

```swift
let (sent, received, packets, wire) = try await withThrowingTaskGroup(of: PairResult.self) { group in
    for pair in 0..<workload.connections {
        let sender = senderExecutor(pair)
        group.addTask(executorPreference: receiverExecutor(pair)) {
            try await runPair(workload, mode: mode, protection: protection, senderExecutor: sender)
        }
    }
    …
}
```
<!-- src: SocketStream/Sources/SocketStream/Transfer.swift `run` (abridged) -->

`runPair` is the receiver. It binds the listener, starts the sender as a child with `addTask(executorPreference:
senderExecutor)`, accepts the connection, and receives. The timing runs from the first listener to the last receiver's
end of stream, so starting executor threads is not counted.
<!-- src: Transfer.swift `runPair`; SocketStream/RESULTS.md "frames" section "The socket transfers still record the transfer's own timing, from the first listener to the last end of stream, so starting executor threads isn't counted" -->

Executors are nested with a recursive `nonisolated(nonsending)` function, because `PThreadTaskExecutor.withExecutor` is
scoped (the executor exists only inside the closure). `withExecutors(count:poolSize:_:)` opens one per level of
recursion and calls `body` with all of them.
<!-- src: Transfer.swift `withExecutors` -->

There are two **placements**, chosen by `--placement`:

- **`threadPerTask`** (the default): a single-thread `PThreadTaskExecutor` for every sender and every receiver. A task,
  its socket's kqueue, and its buffers stay on one thread. For `n` connections that is `2 * n` executors.
- **`sharedPool`**: one `PThreadTaskExecutor` pool (`Workload.poolSize` threads, one per core by default) for every task.
  The pool hands each job to its next thread in turn, "so a task resumes on a different thread after most reads and
  writes", the source says. [Section 2.4](#24-nonisolatednonsending-all-the-way-55-to-113-switches-that-were-zero-hops) shows that this is not what happens once tasks are running.
<!-- src: Transfer.swift `Placement` doc comments and `run` (`executorCount = placement == .sharedPool ? 1 : 2 * workload.connections`); README.md "Placement" -->

#### 2.4 `nonisolated(nonsending)` all the way: 55 to 113 switches that were zero hops

The first concurrency question for SocketStream is whether the send and receive loops hop between threads. Answering
it takes two measurements, because each answers a different question.

**Counting calls (LLDB breakpoints on `swift_task_switch`).** Over one transfer of 64 B packets:

| Per transfer | 20,000 packets | 80,000 packets | Per socket read or write |
|---|---|---|---|
| Socket reads + writes | 22 | 88 | |
| `swift_task_switch`, plain `nonisolated` async functions | 85 | 201 | 2.5 |
| `swift_task_switch`, `nonisolated(nonsending)` | 55 | 113 | 0.9 |
| Jobs run by the executors (`swift_job_run`) | 14–16 | 14–24 | 0 |
<!-- src: SocketStream/RESULTS.md "Concurrency: no hops, and no executor checks on the I/O path" table -->

A plain `nonisolated` async function calls `swift_task_switch` "on entry and after each call it makes, to make sure it's
on the generic executor". In the transfer, each check found the task already on its preferred executor, but each is a
runtime call: 2.5 per socket operation, from `sendPackets`, `receivePackets`, and `ByteBuffer.read(from:)`.
Marking them `nonisolated(nonsending)` leaves "no `swift_task_switch` left in their code, only in the closures that start
tasks". The 0.9 per operation that remain are in the standard library's `ContinuationWaiter.wait()` (the PR's split
continuation), once each time a socket operation suspends, and are also a fast-path check.
<!-- src: SocketStream/RESULTS.md "But there were executor checks" and "The 0.9 that remain" -->

**Looking at task states (Instruments).** Breakpoint counts cannot tell a check from a move. Instruments' Swift
Concurrency template records every state change with the thread and actor it ran on. For one 64 B connection of 20,000
packets: 5 tasks, 62 runs, 6 thread switches, 6 actor switches, 50 continuation waits; for 80,000 packets: 179 runs, the
same 6 switches, 167 waits.
<!-- src: SocketStream/RESULTS.md "Measured with Instruments" table rows 1 and 2 -->

What those numbers mean:

- **The sender and receiver tasks never hop.** In every run each ran on exactly one thread, including 8 tasks sharing a
  2-thread pool. A suspended socket operation resumes on the thread it suspended on, because the package resumes it with
  `resumeSynchronously` from the event loop, so the pool's round robin "never comes into play once a task is running".
  <!-- src: SocketStream/RESULTS.md "The sender and receiver tasks never hop" -->
- **Every switch was `main` setting up.** The 6 switches (18 for 4 connections with an executor each; 4 with one shared
  pool) are `main` moving between the main thread and the global executor while it creates executors and starts tasks. They
  are a fixed cost per transfer, the same for 20,000 and 80,000 packets.
  <!-- src: SocketStream/RESULTS.md "Every switch is main setting up" -->
- **Suspensions follow socket waits, not packets.** Continuation waits grew from 50 to 167 for 4 times the packets,
  each one a socket that was not ready. The wait from runnable to running had a median of 4–8 µs.
  <!-- src: SocketStream/RESULTS.md "Suspensions follow socket waits, not packets" -->

What `nonsending` bought is small, and it was not measured alone. The README puts it this way: "the async functions are `nonisolated(nonsending)`, so the send and receive loops run on their task's executor with no
executor checks around the socket calls." The results file says that 64 B on one connection went from 13.6 to 14.6 M
packets/s with the scans, the checker, and `nonisolated(nonsending)` together, "not measured apart: the checks are a few
per 256 KB read, so most of it is the scans".
<!-- src: SocketStream/README.md "How it works" Concurrency bullet; SocketStream/RESULTS.md "Effect: 64 B on one connection went from 13.6 to 14.6 M packets/s" -->
The value of the exercise lies in the verification rather than in a speedup. Knowing that the 113 calls are checks
and not hops is what let the design stay on the simple path.

**Do it from the callee side too.** swift-platform-executors' own async APIs run on their caller's executor, and calling
them from a plain `nonisolated` async function "adds executor checks around every call". So the code that calls socket
operations must be `nonsending` as well.
<!-- src: SocketStream/RESULTS.md "Call it from nonisolated(nonsending) code" -->

#### 2.5 Placement: thread per task against a shared pool

Pinning each task to its own thread is the intuitive way to keep caches warm. The measurements show that it barely
matters here, and why. With 4 connections of 1 KB packets, the first measurements put thread per task 6% ahead (4.45
against 4.20 GB/s), but repeated runs overlapped (4.3–4.7 against 4.2–4.8 GB/s): "at the 4-connection TCP ceiling,
the difference is within run-to-run noise". On the M1 Max the same two placements gave 5,543 against 5,295 MB/s.
<!-- src: SocketStream/RESULTS.md "Placement" section; "Transfers, several connections" table (1 KB, 4, thread per task / shared pool: 5,543 / 5,295 on M1 Max) -->
The Instruments result explains why: tasks stay on one pool thread for a whole transfer anyway, because suspended socket
operations resume where they suspended. In this workload, then, pinning guarantees what the pool already does in
practice and buys no measurable speed, and it costs `2 * connections` threads where a shared pool uses a fixed
number. It might matter more if tasks migrated, or if something else competed for the pool's threads (not measured).
<!-- src: SocketStream/RESULTS.md "Placement": "In practice the pool barely matters once tasks are running: Instruments shows each task staying on one pool thread for the whole transfer"; thread counts from Transfer.swift `run` (`2 * workload.connections` executors of 1 thread, or 1 of `poolSize`); the "guarantees what the pool already does" reading and the last sentence are interpretation -->

#### 2.6 `ByteBuffer.receive`: suspending with a span in place

The receiver reads into a Bytes `ByteBuffer`: reads append at the end, parsing consumes from the start, and a partial
packet left at the end moves to the front once less than half the buffer is free. The buffer's one allocation never
moves, which is the property an `await` needs, because a read can suspend with its output span still pointing into the
buffer:
<!-- src: SocketStream/Sources/SocketStream/ReceiveBuffer.swift doc comment; Bytes/Sources/BytesAsync/Buffers.swift `receive` -->

```swift
public extension ByteBuffer {
    @inlinable
    nonisolated(nonsending) mutating func receive<R, E: Error>(
        _ body: nonisolated(nonsending) (inout OutputRawSpan) async throws(E) -> R
    ) async throws(E) -> R
}

// SocketStream's use:
return try await receive { output throws(IOError) in try await connection.read(into: &output) }
```
<!-- src: Bytes/Sources/BytesAsync/Buffers.swift lines 22-24; SocketStream/Sources/SocketStream/ReceiveBuffer.swift `read(from:)` -->

It is not an `async` overload of the synchronous `fill`, because "with a closure that names its error type, Swift 6.4
finds such a call ambiguous, from async code even when the closure doesn't suspend". Moving the transfer onto
`ByteBuffer` (and the pipeline's output onto `[UInt8].withOutputRawSpan`) took unsafe sites in SocketStream's sources from
9 to 1. It also took unprotecting Brotli plus TLS packets from 27 M to 26 M instructions (−3.7%), because the buffer
moves a partial packet only when less than half of it is free, where the old code moved it after every piece.
<!-- src: SocketStream/RESULTS.md "2026-11-16: receive buffers are Bytes' ByteBuffer"; Bytes/Sources/BytesAsync/Buffers.swift doc comment -->

#### 2.7 Per packet: no allocations, no reference counts

The concurrency design only pays if the work between awaits is cheap. Per packet, neither end allocates or touches a
reference count, and a transfer makes 120–122 allocations (executors, sockets, buffers, tasks) in total, the same for
100,000 packets as for 1,000,000 (132 in the M1 Max run, with code changed since the 120–122 count). Zero-malloc `Allocations:`
benchmarks with thresholds of 0 gate it.
<!-- src: SocketStream/README.md "Per packet, neither end allocates or touches a reference count"; SocketStream/RESULTS.md "Allocations: none per packet" (120–122); "2026-11-19: M1 Max against M3 Ultra" (132 for both 100,000 and 1,000,000; code changed since); 325 in `protected-1` is a protected transfer's setup -->
Two fixes mattered. The topic is a view into one table of every topic's bytes rather than a `String.utf8Span` (which is not inlinable, so even a borrowed `String` is retained and released around the
call). And the receiver checks packets against that same table instead of a global array of arrays (no allocation, but a
retain and release per read).
<!-- src: SocketStream/RESULTS.md "Allocations: none per packet" bullets "Receiving" and "Sending"; Transfer.swift `encode` doc comment -->

The packet code itself skips the 153-byte `MQTTPacket` enum on both ends (`MQTTFrame` and per-type `init(parsing:)`/
`write(to:)`; see Part III, ["MQTT: views, per-type dispatch, and not decoding twice"](#mqtt-views-per-type-dispatch-and-not-decoding-twice)). In memory that took checking
from 21.2 to 36.4 M packets/s (+72%) and encoding from 26.2 to 43.4 M packets/s (+65%), and 64 B on one connection
from 16.1 to 22.4 M packets/s (+39%).
<!-- src: SocketStream/RESULTS.md "Skipping the MQTTPacket enum (nonsending-scan16 → frames)" -->

#### 2.8 Compression and TLS over sockets: pipelines on the I/O task

With `--compression` and `--encrypted`, the sender runs each encoded batch through a Bytes pipeline with a flush at the
batch's end, so that the receiver can decode every packet in it:

```swift
// Sender: DEFLATE (raw, level 1) then TLS record sealing
DeflateEncoder(format: .raw, level: 1).then(protection.sealer(keys))
// Receiver: the reverse
TLSRecordOpener(keys: keys).then(DeflateDecoder(format: .raw))
```
<!-- src: SocketStream/Sources/SocketStream/Protection.swift lines 132 and 154 (sendProtected / receiveProtected pipelines); README.md "Compression and encryption" -->

Keys come from an X25519 exchange (CryptoKit) and TLS 1.3's key schedule; the pipelines are built once per connection and
allocate nothing per packet.
<!-- src: SocketStream/README.md "Compression and encryption" -->
The important design fact is that the pipeline runs synchronously on the connection's I/O task, so one connection is one
core per end, with the stages running one after another.
<!-- src: SocketStream/RESULTS.md "One connection is one core per end, and the stages run one after another on it" -->

Each stage alone, on one core (GB/s of MQTT bytes, 64 B / 1 KB / 16 KB payloads):

| Stage | 64 B | 1 KB | 16 KB |
|---|---|---|---|
| MQTT encode | 7.07 | 33.0 | 87.6 |
| DEFLATE level 1, Bytes (flushed per batch) | 0.55 | 0.69 | 1.19 |
| Brotli quality 1, Bytes | 0.41 | 0.53 | 1.72 |
| TLS seal / open (ChaCha20-Poly1305) | 1.41 / 1.39 | 1.39 / 1.39 | 1.39 / 1.37 |
| memcpy | 61.5 | 59.2 | 60.2 |
<!-- src: SocketStream/RESULTS.md "2026-11-15: where protected transfers spend their time" first table (rows selected) -->

Adding the per-end stage costs predicts what the transfers measure: for TLS at 64 B, sender encode 0.14 plus seal 0.71 plus
`sendto` about 0.17 ns/B, receiver about 0.37 plus open 0.72, so about 0.9 GB/s predicted against 0.84–0.89 measured.
<!-- src: SocketStream/RESULTS.md "The stages, not the pipeline, set the rate" -->
This is the concurrency lesson in numbers. A single task running its stages in sequence runs at one over the sum of
its stage costs, and no executor setting changes that. To go faster, one connection has to use more than one core.

Across connections (64 B payloads, command-line runs with `--packets 3000000`, one run each; a different method from the benchmark baselines in [section 2.9](#29-measured-throughput-against-the-kernels-ceiling), so its plain figures for several connections differ from that table's), GB/s:

| Connections | plain | TLS | deflate + TLS |
|---|---|---|---|
| 1 | 2.81 | 0.89 | 0.46 |
| 4 | 3.61 | 3.18 | 1.69 |
| 8 | 3.20 | 4.57 | 3.17 |
| 16 | 3.18 | 2.82 | 6.27 |
<!-- src: SocketStream/RESULTS.md "2026-11-15: where protected transfers spend their time" second table -->

DEFLATE plus TLS scales almost linearly (13.6x at 16 connections), because its limit is the compressor, per core. Plain
and TLS reach the loopback ceiling at about 3–4.5 GB/s on the wire for this write pattern.
<!-- src: SocketStream/RESULTS.md same section, "DEFLATE + TLS scales almost linearly (13.6x at 16)" -->

**Parallel sealing inside one connection.** TLS records are independent once their sequence numbers are fixed, so
`TLSRecordSealer.sealingLanes` seals a batch's full records on several cores, each straight into its place in the output
(same bytes as one lane, tested). `Protection` has `sealingLanes` and `compressionLanes`. In memory (4 MB seals):
ChaCha20-Poly1305 2.0 GB/s on one lane, 7.6 on 4 (3.8x), 13.9 on 8 (6.9x); AES-128-GCM 5.7, 20.3 (3.6x), 32.7 (5.8x).
<!-- src: SocketStream/RESULTS.md "2026-11-18: TLS records sealed in parallel" table; Protection.swift `sealingLanes`/`compressionLanes` properties -->
Over loopback, one connection, 16 KB payloads, interleaved runs: ChaCha20-Poly1305 went from 1.35–1.54 GB/s on one lane to
1.77–1.87 on four (+25%) and gained nothing further at eight (1.57–1.85); AES-128-GCM from 2.79–3.16 to 3.63–3.80 GB/s (+22%).
<!-- src: SocketStream/RESULTS.md "Loopback, one connection, 16 KB payloads, interleaved runs" table -->
Past four lanes the receiver is the limit. It opens records one after another, at about 2 GB/s for ChaCha20-Poly1305 on
one core. Opening cannot be parallelized as easily as sealing: a record's plaintext length (and so its place in the
output) is known only after it is decrypted, because the inner content type and padding sit at its end.
<!-- src: SocketStream/RESULTS.md "The receiver is now the limit ... Opening in parallel is harder than sealing" -->

#### 2.9 Measured throughput against the kernel's ceiling

`Tools/socket-ceiling` measures the kernel with blocking C sockets on plain threads, with no Swift in the way:

| Blocking C sockets, 1 MB writes | 1 pair | 2 | 4 | 8 | 16 |
|---|---|---|---|---|---|
| Loopback TCP, default buffers | 7.0 GB/s | 5.3 | 3.7 | 3.4 | 3.1 |
| Unix-domain socketpair | 29.5 GB/s | 33.8 | 39.9 | 47.0 | 40.8 |
<!-- src: SocketStream/RESULTS.md "The ceiling: loopback TCP, not the executors or the parsing" table (4 MB buffers row omitted) -->

Two conclusions follow. Loopback TCP tops out around 7.5 GB/s for the whole machine, and the total drops as connections
are added "with or without Swift: the kernel's loopback path serializes them", and bigger socket buffers do not move it.
And the package costs nothing at the ceiling. Its kqueue executors reach 7.5 GB/s raw on one connection, faster than the
blocking C probe with 256 KB writes (5.6 GB/s). Unix-domain sockets carry 4–6x more, but swift-platform-executors'
sockets are TCP and UDP over IPv4 and IPv6 only (`SocketAddress` has `v4` and `v6`).
<!-- src: SocketStream/RESULTS.md "The ceiling" bullets -->

Plain transfers, M3 Ultra, baseline `frames`:

| Workload | Bandwidth | Packets/s |
|---|---|---|
| 64 B payloads, 1 connection | 2.81 GB/s | 22.4 M |
| 1 KB payloads, 1 connection | 6.35 GB/s | 5.8 M |
| 16 KB payloads, 1 connection | 7.3 GB/s | 444 K |
| Raw (no MQTT), 1 connection | 7.4–7.5 GB/s | |
| 64 B payloads, 2 / 4 / 8 connections | 4.3 / 4.4–4.9 / 3.7 GB/s | 34.3 / 34–39 / 29.7 M |
<!-- src: SocketStream/RESULTS.md "Results" table, `frames` column -->

From 16 KB payloads up, MQTT encoding and parsing run as fast as the raw stream, because the payload is copied once into
the sender's batch and parsed in place (a `RawSpan` view) on the other side. Small packets are bound by per-packet work:
45 ns per packet (down from 73) with each end on its own core, against 23–27 ns per packet for each end alone in memory; the rest is the kernel copying each packet in and out and the system calls.
<!-- src: SocketStream/RESULTS.md "Large packets saturate the socket" and "Small packets are bound by per-packet work" -->

On the M1 Max (8 P + 2 E cores) the plain transfers were faster than on the M3 Ultra (24 P + 8 E): 64 B equal (3,387
against 3,411 MB/s, the M3 figure from an older baseline than the table above), 1 KB +17%, 16 KB +23%, raw +55%. The compressors' transfers were slower by the compute ratio, 1.32
(geometric mean over 8 in-memory rows, a hardware ratio because instruction counts were identical). The M3 transfer
figures come from older baselines, so these comparisons are indicative only, and why the smaller chip moves more bytes
through loopback was not investigated.
<!-- src: SocketStream/RESULTS.md "2026-11-19: M1 Max against M3 Ultra", "Measured" first bullet and headline; "Interpretation, not measured" (older M3 baselines; "Why a 10-core chip gets more than a 32-core one through it ... wasn't investigated") -->

#### 2.10 What each prototype contributed

| Prototype or interface | What it did | Measured contribution |
|---|---|---|
| PR toolchain's split continuation and `resumeSynchronously` | A suspended read or write resumes directly on the thread running the event loop | Tasks never hop after they start: 6 thread switches per transfer, all from `main`'s setup, whatever the packet count |
| `PThreadTaskExecutor` with kqueue, `executorPreference:` | Each sender or receiver on its own thread, or all on a pool | Equal within noise at the TCP ceiling (4.3–4.7 against 4.2–4.8 GB/s) |
| `nonisolated(nonsending)` on every async function | No executor checks around socket calls | 2.5 to 0.9 `swift_task_switch` per socket operation; part of 13.6 to 14.6 M packets/s with the scans and checker |
| `ByteBuffer.receive` | A read suspends with its output span in place | 9 to 1 unsafe sites; Brotli+TLS unprotect −3.7% instructions |
| Pipelines on the I/O task | Compress and seal inline, no task per stage | A transfer's rate equals the sum of its stages' costs; allocation-free per packet |
| `sealingLanes` | A connection uses several cores to seal | +25% (ChaCha20) and +22% (AES-GCM) at 16 KB over loopback; nothing past 4 lanes |
<!-- src: rows from SocketStream/RESULTS.md sections cited in 2.4 through 2.8; "2.5 to 0.9" is the per-operation column of the table in "Concurrency: no hops" -->

Across these rows, the throughput does not come from the concurrency interfaces. It comes from making per-packet work
cheap and allocation-free, from the stages' own speed, and from using more cores where a stage is the limit. What the
new interfaces contribute is a runtime in which the loops stay on their threads without extra work, and measurements
that prove it.

### 3. NativeAEA: from threads to structured concurrency

NativeAEA extracts Xcode's archives: a walker parses the archive in place, 32 decoders decode segments in parallel,
24 writers create files, and one producer reads block headers. The first version used threads, `NSCondition`s,
`DispatchGroup`s, `DispatchSemaphore`s, and `concurrentPerform` loops. In the current one each operation is one task
tree, with the walker in the calling task and everything else a child task. During a xip extraction there are 59
tasks: the calling task, 32 decoders, 1 block producer, 24 writers, and 1 content checker (an `async let`).
<!-- src: NativeAEA/RESULTS.md "2026-11-19 (concurrency)"; NativeAEA/ARCHITECTURE.md §9 first paragraph -->

#### 3.1 Primitives: `Mutex` plus a continuation

Every wait that blocked a thread in the threaded version is `Mutex` state plus a continuation (a free buffer, a job,
room in a queue, a file system permit, a large-file slot, a fork's turn, a decoded chunk). The rules from [section 1.6](#16-continuations-checked-and-unsafe) apply to all of them:
a synchronous fast path under the lock, no lost wake-ups, one waiter per event resumed outside the lock, waiter storage
reserved up front (so the steady state allocates nothing), and closing resumes everyone.
<!-- src: NativeAEA/ARCHITECTURE.md §9 "The primitives" -->
`Synchronization`'s `Mutex` (SE-0433) and `Atomic` (SE-0410) hold the state. These primitives began as NativeAEA's own
(and Disk's, nearly word for word); since 2026-11-21 they are `BytesAsync`'s `Continuation`, `WaiterQueue`, `AsyncLimiter`,
`AsyncIndexPool`, `AsyncLatch`, `AsyncQueue`, and `AsyncHandoff`, one implementation shared by NativeAEA, Disk, and
NativeZip (Part II, ["Waiting primitives: one implementation each"](#waiting-primitives-one-implementation-each)). NativeAEA's
`JobQueue` became `AsyncQueue` with its unused wait-time counter dropped; the per-buffer reference counts, once an array of
`AtomicCounter` objects (a class around `Atomic`, so that arrays could hold one), are one `RelaxedCounters`, which saved the
pool 30–36 mallocs an extraction.
<!-- src: NativeAEA/ARCHITECTURE.md §9 primitive table (Mutex, Atomic<Int>); SE-0433 mutex, SE-0410 atomics; Bytes/Benchmarks/RESULTS.md "2026-11-21, the waiting primitives and RawStorage" table (JobQueue → AsyncQueue "its unused wait-time counter dropped"); NativeAEA/RESULTS.md "2026-11-22, late: …" ("The segment pool's reference counts are one `RelaxedCounters` instead of one `RelaxedCounter` object per buffer"; mallocs −30 to −36: "the pool's counters and Disk's 11") -->

In concrete terms, a released buffer, permit, or slot index "goes straight to the task that has waited longest"; a pushed job goes to a waiting consumer; a publish resumes the consumer only if it waits for that
index. Waking everyone happens only on close or failure.
<!-- src: NativeAEA/ARCHITECTURE.md §9 "One waiter per event, resumed outside the lock" -->

#### 3.2 `@concurrent` entry points and `nonsending` internals

`extract`, `forEachEntry`, `decrypt`, and `verify` are `@concurrent async throws(AEAError)`; everything inside is
`nonisolated(nonsending)`. The count that justified the second rule, on a 1,001-file archive with LLDB:

| Operation | `swift_task_switch` before | after |
|---|---|---|
| Extraction | 21,374 | 1,467–1,481 |
| Listing | 6,222 | 312 |
<!-- src: NativeAEA/RESULTS.md "What mattered" (21,374 → 1,481); NativeAEA/ARCHITECTURE.md §9 "Executors and priorities" (listing 312, 6,222 before; extracting 1,467 (21,374)). Both files describe the same measurement (1,001-file archive, LLDB, extraction, after the change) and neither says which run it was; both are uncommitted, so git can't tell which is later. Shown as the range of the two records. -->

The two records of the extraction count differ (1,467 in ARCHITECTURE.md, 1,481 in RESULTS.md) but describe the same
1,001-file extraction; either way it is about 14x fewer.

Without `nonsending`, the walker made about 4 checks per entry; with it, about one per real suspension, which is a writer
waiting for one of the 6 file system permits. The Swift Concurrency instrument shows no thread switches inside the
pipeline.
<!-- src: NativeAEA/RESULTS.md "nonisolated(nonsending) on every internal async function"; ARCHITECTURE.md §9 -->

Here, unlike in SocketStream, the change was measured against the old design on the whole job. Old (threads) against
new, interleaved on an idle machine, 3 rounds, medians:

| | Wall (s) | Peak footprint (MB) |
|---|---|---|
| xip, verify | 2.11 → 2.11 | 950 → 815 |
| xip, extract | 10.30 → 10.01 | 1,449 → 1,213 |
| aea, verify | 2.67 → 2.74 | 1,095 → 1,077 |
| aea, extract | 9.39 → 9.64 | 1,627 → 1,359 |
<!-- src: NativeAEA/RESULTS.md "Old (threads) against new, interleaved on an idle machine" table (columns selected) -->

Instructions are identical to within about 0.2%, and wall time moved little (the aea extraction 0.08–0.25 s higher in
every round, with CPU time equal or lower; the xip 0.2–0.5 s lower). Peak memory fell by 236 and 268 MB in the two
extractions (the section's heading says "190–270 MB less memory"). That came mostly from a memory pass made in the same
change (read buffers that give their pages back, encoders made on first use; [section 3.5](#35-two-smaller-lessons-from-the-same-rewrite)) rather than from the task
structure. The rewrite was for structure (cancellation that releases every buffer, no threads of the library's own)
rather than speed, and the table shows it cost little or nothing.
<!-- src: NativeAEA/RESULTS.md "2026-11-19 (concurrency)" heading, table (1449 → 1213, 1627 → 1359 MB: −236, −268, derived), the note on wall times, and "Memory and allocations" bullets (madvise: xip extraction 1398 → 1228 MB, aea 1597 → 1363 MB; encoders and decoders on first use about −35 MB) -->

#### 3.3 Did 32 CPU-bound decoders starve the pool?

The concern from [section 1.1](#11-tasks-executors-and-the-cooperative-pool) is real on paper. Traced on the synthetic archive, the writers' first wakes waited up to
250 ms (median 25 µs). Three remedies were tried, each interleaved against the threaded build: decoders yielding
(`Task.yield()`) after every segment, decoders yielding only after resuming the consumer, and decoders one priority
below the walker and writers. None made a difference beyond run-to-run noise (xip extraction 10.1–11.1 s across all
variants). So decoders inherit the caller's priority and do not yield, and no custom executor is needed. In the steady
state the decoders are suspended on a full buffer pool, so they are not competing.
<!-- src: NativeAEA/ARCHITECTURE.md §9 "Executors and priorities"; NativeAEA/RESULTS.md "32 CPU-bound decoder tasks didn't starve the walker" -->
The general lesson, from AGENTS.md: "Measure before adding an executor."
<!-- src: AGENTS.md Lessons "CPU-bound tasks filling the cooperative pool didn't starve the others ... Measure before adding an executor" -->

The entry points are the one place priority is set: an async `main` task is at priority 21, so `run()` starts one child at
`.userInitiated`, the quality of service the old threads had. That is now `BytesAsync`'s `withPriority(_:operation:)`, which
the app uses too (Part III, ["Nunarchiver"](#nunarchiver-the-app-and-its-two-traps)).
<!-- src: NativeAEA/ARCHITECTURE.md §1; NativeAEA/RESULTS.md "What mattered" ("the async main task is at 21, the old threads were user-initiated") -->

#### 3.4 One cancellation handler, and cancellation that releases everything

There is one `withTaskCancellationHandler` per operation, in `ChunkSource.withDecoding`, around the task group. It runs
synchronously in whoever cancels and (a) fails the extraction context with `.cancelled`, so writers skip what is left,
releasing their references, and (b) stops the source, so the consumer's wait ends and the pools and queues close and every
decoder and the producer end. The write queue is not closed early: writers drain it, skipping the work, so the walker's
pushes land and every reference is released. Tests check that `buffersInUse` is 0 after successful, failed, and cancelled
operations.
<!-- src: NativeAEA/ARCHITECTURE.md §11 "Failure and cancellation" -->
Failure follows the same path: the first error wins, is stored under the stream's lock, and closes the pools and queues.
<!-- src: NativeAEA/ARCHITECTURE.md §11 "The first error wins" -->

#### 3.5 Two smaller lessons from the same rewrite

- **A pool of slots sized for the wrong latency.** Pools that jobs hold until they finish wait on the queue's latency,
  not on the work: four large-file slots made the walker wait 6.0 s of 9.0 s (Part III, ["NativeAEA: a decode pipeline
  against a file system"](#nativeaea-a-decode-pipeline-against-a-file-system), has the case and the fix).
  <!-- src: AGENTS.md Lessons "A pool of slots that jobs hold until they finish waits on the queue's latency" -->
- **Resident memory from a buffer sized for the largest item.** Giving read buffers' pages back after each use
  (`madvise`, described in the same Part III section) saved 170–230 MB across 32 read buffers of 16 MiB, with no
  system time.
  <!-- src: AGENTS.md Lessons "A buffer sized for the largest item stays resident at that size" -->

### 4. NativeZipArchive's worker pools and BytesAsync's offload

#### 4.1 NativeZipArchive: pools, queues, and the kernel's limit

NativeZipArchive's concurrency is a worker pool. `forEachConcurrently` starts up to `maxConcurrency` child tasks of a
`withThrowingDiscardingTaskGroup`, each with its own decoder, and a `RelaxedCounter` hands out indexes with an atomic
increment (`claim(below:)`: relaxed ordering, no lock; it replaced a `WorkQueue` type of NativeZip's own). Items are sorted largest first (longest-processing-time scheduling), so
a big entry does not start last and leave the other workers idle. With one worker or one item, everything runs inline,
in order, with no task overhead. If the body throws, the group cancels the others, which stop claiming; items already
started finish. Cancelling the caller does the same.
<!-- src: NativeZipArchive/Sources/NativeZip/Concurrency.swift `forEachConcurrently` doc comment and body (`let next = RelaxedCounter()`, `next.claim(below:)`); NativeZipArchive/Benchmarks/RESULTS.md step18 ("`RelaxedCounter`") -->
The function is `nonisolated(nonsending)`, so the inline path runs on the caller's executor, and the body is a
`@concurrent @Sendable` closure.
<!-- src: Concurrency.swift doc comment and signature -->

**The right width is set by the kernel, not the cores.** Workers creating files contend in the kernel, file-system-wide,
so file creation is capped at 8 workers, with one worker per entry of 1 MB or more beyond that (Part III,
["NativeZipArchive: the kernel is the limit"](#nativeziparchive-the-kernel-is-the-limit), has the width experiments). `ZipExtractor` expresses the same rule without
knowing the counts in advance: "Eight workers take anything; the rest (up to `--jobs`, default all cores) take only
large files".
<!-- src: NativeZipArchive/Benchmarks/RESULTS.md "step2 — cap file-creation width at 8" and step15 "Parallelism" -->

**Queue discipline.** `ZipExtractor.extract(maxConcurrency:stopOnFirstError:_:)` starts the workers first and then runs
the planning closure (open archives, select entries, prompt, create directories, resolve collisions). Each planned file
is queued at once: large ones (1 MB or more) largest first, small ones in order. Overlapping the planning with the writes
takes it off the wall clock (Part III, ["NativeZipArchive: the kernel is the limit"](#nativeziparchive-the-kernel-is-the-limit), has the numbers). A file replacing
one that is already being written waits until the pool is done; symbolic links follow every file, then directory
metadata, deepest level first, each level in parallel.
<!-- src: NativeZipArchive/Benchmarks/RESULTS.md step15 "Parallelism" bullets -->

**A pipelined write for large entries.** `ZipDecoder.decodePipelined` keeps two 1 MB buffers: chunk N is written in a
child task while chunk N+1 inflates, for deflated entries of 4 MB or more. The decoder and the writing task meet in an
`AsyncHandoff<ZipDecoder.Chunk>`: the decoder's `send` returns once the consumer has finished the previous chunk and taken
the new one, so the two buffers alternate with nothing allocated per chunk. (NativeZip's own `ChunkHandoff`, 137 lines
on raw `UnsafeContinuation`s, became that type, and the 8-archive row's instructions did not move: 4.17 G before and after.)
<!-- src: NativeZipArchive/Benchmarks/RESULTS.md "step3" bullet on inflatePipelined (the function is now `decodePipelined`: NativeZipArchive/Sources/NativeZip/ZipDecoder.swift); ZipDecoder.swift lines 507–510 (`typealias ChunkHandoff = AsyncHandoff<ZipDecoder.Chunk>` and its doc comment); NativeZipArchive/Benchmarks/RESULTS.md "2026-11-21: a quarantine option; the mapping and the handoff shared" table row "`ChunkHandoff` (137 lines on raw `UnsafeContinuation`s)" (Extract 8 archives of 64 MB 4.17 → 4.17 G) -->
Parallel writes to one file gain nothing, because the kernel serializes them (Part III, ["NativeZipArchive: the kernel
is the limit"](#nativeziparchive-the-kernel-is-the-limit)).
<!-- src: NativeZipArchive/Benchmarks/RESULTS.md step15 "One large stored file (1 GB)" bullet -->

#### 4.2 BytesAsync: offloading synchronous work

BytesAsync's question is how to run a synchronous codec stage without blocking an actor. It has two answers, and
the choice between them is a measurement:

- **`concurrently()`** wraps a stage so each call runs in a `@concurrent` function on the global concurrent executor, in
  the calling task. It inherits the task's priority and task-locals, and a caller already on the global executor (any
  `nonisolated` task) does not change threads at all. This is the default.
- **`offloaded(to:)`** suspends the calling task and runs the work on a Dispatch queue: two thread switches per call,
  whatever the caller.
<!-- src: Bytes/Sources/BytesAsync/Offloading.swift header comment -->

The helper behind the first is a one-line `@concurrent` function, `perform(_:)`, taking a non-escaping closure (Part II,
["Async: `BytesAsync`"](#11-async-bytesasync), shows it), so no closure context is allocated.
<!-- src: Bytes/Sources/BytesAsync/Offloading.swift lines 20-23 -->
DEFLATE level 1 in 64 KiB calls took the same time with `concurrently()` as in place, and a Dispatch queue hop cost
+7%.
<!-- src: AGENTS.md Lessons "Offload synchronous work with a @concurrent function taking a non-escaping @Sendable closure ... DEFLATE level 1 in 64 KiB calls: same time as in place, a Dispatch queue hop +7%" -->
The Dispatch form is for callers that must keep long work off the cooperative pool's threads, or on a queue with its
own quality of service.
<!-- src: Offloading.swift header comment -->

Two limits are stated in the source and in AGENTS.md. First, a generic `@concurrent` function called on a type parameter
warns that its conformance "may be isolated" under `InferIsolatedConformances`, even with `SendableMetatype`; the closure
form does not. Second, APIs that borrow caller storage (`inout`, spans) are not `@concurrent`, since the borrowed
storage "can't cross isolation domains" (as `@concurrent` functions, their callers would have to send it); they stay
`nonisolated(nonsending)` and move only their workers off the caller.
<!-- src: AGENTS.md Lessons "Bytes cleanup" offload bullet and "async APIs that take inout storage are nonisolated(nonsending) (otherwise @concurrent, and callers must send self)"; Bytes/Sources/BytesAsync/ParallelCodecs.swift header ("which can't cross isolation domains"); Bytes/Package.swift line 18 InferIsolatedConformances -->

The parallel codecs use the same pattern. Their async entry points are `nonisolated(nonsending)` rather than
`@concurrent`, "because they borrow the caller's `inout` output span", and run their workers as child tasks of a
discarding task group (`runConcurrently`) or on a Dispatch queue (`run(on:)`).
<!-- src: Bytes/Sources/BytesAsync/ParallelCodecs.swift header comment and lines 20-48 -->
Cancellation is cooperative inside them: a task cancellation handler sets `ChunkScheduler`'s stop flag, chunks under way
finish, and the call throws `BytesError.cancelled` (Part III, ["Chunks pulled from a queue, not rounds"](#chunks-pulled-from-a-queue-not-rounds)).
<!-- src: Bytes/Benchmarks/RESULTS.md "Cancellation for the async parallel codecs" -->

As for how the parallel forms compare, a task group was up to 10% faster than `concurrentPerform` in the harness
(dickens L1 2.01 against 2.19 ms) and 0–7% faster in the benchmarks, with more spread, but allocates more per call (34 and 98 mallocs at 8 and 24
lanes, against 11 and 27; Part III, ["Allocation-free code"](#6-allocation-free-code)).
<!-- src: Bytes/Benchmarks/RESULTS.md "A task group was up to 10% faster than concurrentPerform" and "Allocation: the sequential paths allocate nothing" -->

Lending memory across an await is the last piece. `RawSpan.withLentBytes` and `OutputRawSpan.withLentFreeCapacity` hand
a `Sendable` lent value to child tasks that must finish before the call returns, which awaiting them ensures, so spans can
feed task groups without copying.
<!-- src: Bytes/Sources/BytesAsync/Lending.swift header comment and doc comments -->

### 5. Limitations and compiler bugs met in concurrency and nearby

The table lists the bugs and limitations in Swift 6.4.x and the PR toolchain that these projects hit. Reports are cited
by number only; the reproducers are kept outside the repository.
<!-- src: AGENTS.md "Repository" paragraph on ~/Scratch/swift-bugs; Bytes/OPTIMIZATION.md (old) §12 intro -->

| Issue | Effect | Workaround |
|---|---|---|
| **Processes must load the PR toolchain's Concurrency runtime**, not the OS's | The first socket operation crashes (null access in `withContinuation`), or the process exits silently | Embed the runtime path with `ld -dyld_env` (SocketStream's Package.swift); run tests with `Tools/toolchain NAME test` |
| **`swift test` and the benchmark plugin replace `DYLD_LIBRARY_PATH`** for the processes they start | The embedded environment is the only one that survives | As above |
| **PR toolchain builds expire**, and the package tracks the compiler closely | The PR build swift-platform-executors' manifest names (2475) no longer compiled its I/O; build 2511 did | Pin the package revision; `Tools/toolchain` records the installed build (and newer build numbers of the PR can be probed when a URL expires) |
| **`TCPConnection` and listeners must be closed before they are destroyed** | The executors trap ("A TCPConnection was destroyed without being closed"), hiding the original error | `try? await listener.close()` and `connection.close()` on every error path |
| **A connection keeps the scheduler it was created on** | Accepting all connections in one task puts every receiver's I/O on that task's executor | One listener per pair, bound and accepted on the receiver's executor |
| **Leased buffers are unimplemented on `PThreadTaskExecutor`** | The closure-based `read { }`/`write { }` that would encode into a platform buffer cannot run | Encode into your own batch and write it |
| **A plain `nonisolated` async function checks the executor on entry and after each call** | 2.5 `swift_task_switch` per socket operation | `nonisolated(nonsending)` |
| **A `throws(E)` closure passed to an untyped generic `rethrows` API** (`Array.withUnsafeMutableBytes`) throws the wrong error, silently; with a `Void` or tuple result the compiler crashes. Report 25, swiftlang/swift#90291 | A `BytesError` printed `()` | `array.withOutputRawSpan { }` or `array.mutableSpan.withUnsafeMutableBytes` |
| **A sync method and an `async` overload of one name taking a `throws(E)` closure are ambiguous** from async code, across modules too (Disk against BytesAsync's `withLentBytes`) | Does not compile | Different names (`fill`, `receive`), or a two-line helper in the client |
| **`ManagedBuffer` is explicitly not `Sendable`** | A subclass declaring `@unchecked Sendable` warns ("inherits an unavailable Sendable conformance") | Keep the subclass internal and wrap it in an `@unchecked Sendable` struct (`RelaxedCounters`) |
| **An enum returned from `Mutex.withLock` that is not `Sendable`** | Region-isolation warning ("result … cannot be returned") from the PR toolchain, none from Xcode's compiler | Make the type `Sendable`; build new BytesAsync API with both compilers |
| **Swift Testing's `#expect` cannot read a `~Copyable` value's property**, nor take a `~Escapable` value | Does not compile | Bind the property (or the span's result) to a `let` first |
| **`do { } catch` around a typed-throws call boxes the error** (`swift_allocError`) | An allocation per thrown error | `do throws(E) { }` |
| **A span of a global `let` from another file** is rejected ("lifetime-dependent value escapes its scope") when files compile separately, as in debug builds; accepted with whole-module optimization | Debug builds fail, release builds pass | Bind the global to a local first |
| **Spans cannot be captured through two closures**, nor borrowed from a property while another property is mutated in a closure | Does not compile | Pass both as parameters to a `static` function |
| **`package-benchmark`'s malloc interposer traps on thread exit** (`count_free` calling `calloc` in `_pthread_tsd_cleanup`) | Benchmarks that start threads cannot count mallocs | Count mallocs in single-threaded benchmarks |
| **The malloc interposer costs about 10% on large transfers** | Transfer bandwidth skewed | Keep allocation and timing benchmarks separate |
| **Shared mutable state the walker reads to decide reference handoffs** (a writer cleared a large file's fork type) | A buffer reference leaked, and `DispatchSemaphore` trapped at deinit | Keep the decider's own copy |
<!-- src: SocketStream/RESULTS.md "Notes on swift-platform-executors" and "Receiver fix" (close on error paths; the trap text is quoted there); Bytes/Benchmarks/RESULTS.md "2026-11-21, the waiting primitives and RawStorage" bullets "Not moved" (Disk's `withUnsafeBytesAsync`) and "A PR-toolchain-only warning"; Bytes/Sources/BytesAsync/Counting.swift (`RelaxedCounters` comment on `ManagedBuffer`); AGENTS.md "`ManagedBuffer` is explicitly not `Sendable`", "Spans and Swift Testing" and "`#expect` can't read a `~Copyable` value's property" (lessons, no RESULTS file); AGENTS.md Lessons (rethrows bug #90291 report 25; "do throws(E)"; sync/async overload ambiguity "hence fill and receive"; span-of-global; two-closure spans; malloc interposer thread-exit trap; "Shared mutable state the walker reads to decide reference handoffs is a leak"); SocketStream/RESULTS.md "The transfers themselves aren't measured with the malloc interposer ... cost large-packet transfers about 10%" -->

Two process-level traps are not compiler bugs but still cost time. The first `URLSession` request to a new domain, and
any `open` on a file in `~/Downloads`, `Desktop`, or `Documents`, wait on a macOS privacy prompt that the user may not
see, and the program hangs at 0% CPU. Tell the user to look for the prompt rather than retrying.
<!-- src: AGENTS.md Lessons "The first URLSession request to a new domain waits on a security prompt" and "A program blocked in open ... waits on a privacy prompt" -->

### 6. Further reading

All of these are stable, widely linked pages. Swift Evolution links use the proposal file names in
`swiftlang/swift-evolution`, and each number and title was checked against the proposal's own header.

#### 6.1 Swift Evolution: memory and lifetimes

- [SE-0390 Noncopyable structs and enums](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md):
  `~Copyable`, the basis of `ByteBuffer` and the cursors.
- [SE-0427 Noncopyable generics](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0427-noncopyable-generics.md):
  how generic code accepts `~Copyable` types.
- [SE-0446 Nonescapable types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md):
  `~Escapable`, the rule that makes spans safe without a lock or a copy.
- [SE-0447 `Span`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md):
  `Span` and `RawSpan`, the borrowed views [Part II](#part-ii-the-bytes-toolkit-bottom-up) is built on.
- [SE-0467 `MutableSpan`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0467-MutableSpan.md):
  the writable counterpart.
- [SE-0485 `OutputSpan`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0485-outputspan.md):
  appending into uninitialized storage, behind `OutputRawSpan`.
- [SE-0453 `InlineArray`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md):
  fixed-size inline storage, whose count is an integer generic parameter
  ([SE-0452](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0452-integer-generic-parameters.md)).
- [SE-0377 `borrowing` and `consuming` parameter modifiers](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0377-parameter-ownership-modifiers.md):
  how to say "borrow this" in a signature.
- [SE-0458 Strict memory safety](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0458-strict-memory-safety.md):
  the `unsafe` expression and `.strictMemorySafety()` these packages build with.
<!-- src: each link returns 200; titles checked against raw.githubusercontent.com/swiftlang/swift-evolution/main/proposals/NNNN-….md headers (0390 "Noncopyable structs and enums", 0427 "Noncopyable Generics", 0446 "Nonescapable Types", 0447 "Span: Safe Access to Contiguous Storage", 0467 "MutableSpan and MutableRawSpan", 0485 "OutputSpan", 0453 "InlineArray, a fixed-size array", 0452 "Integer Generic Parameters", 0377 "`borrowing` and `consuming` parameter ownership modifiers", 0458 "Opt-in Strict Memory Safety Checking", which also defines SwiftPM's `strictMemorySafety()`); Bytes/Package.swift line 21 `.strictMemorySafety()`; Lifetimes experimental feature in Bytes/Package.swift line 11; ByteBuffer, GenericBytesReader/Writer are `~Copyable` (Bytes/Sources/Bytes/Buffers.swift 287, BytesReader.swift 92, BytesWriter.swift 50) -->

#### 6.2 Swift Evolution: errors, inlining, and packages

- [SE-0413 Typed throws](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md):
  `throws(BytesError)` and why it avoids boxing.
- [SE-0496 `@inline(always)`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0496-inline-always.md):
  the guaranteed form, as against the `@inline(__always)` hint.
- [SE-0450 Package traits](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md):
  how Bytes' optimized, portable, and no-C builds are selected.
<!-- src: titles checked against the raw proposal headers (0413 "Typed throws", 0496 "`@inline(always)` attribute", 0450 "Package traits"); also as used in Bytes/OPTIMIZATION.md (old) §14 -->

#### 6.3 Swift Evolution: concurrency

- [SE-0304 Structured concurrency](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md):
  tasks, task groups, cancellation.
- [SE-0306 Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md):
  isolation and the actor model.
- [SE-0302 `Sendable` and `@Sendable` closures](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md):
  what may cross a concurrency boundary.
- [SE-0338 Clarify the execution of non-actor-isolated async functions](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md):
  why plain `nonisolated async` functions run on the generic executor (the origin of the checks in [section 2](#2-socketstream-what-the-pr-toolchains-io-interfaces-made-possible)).
- [SE-0381 `DiscardingTaskGroup`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0381-task-group-discard-results.md):
  the task group NativeAEA and NativeZip use for long-lived workers.
- [SE-0392 Custom actor executors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md):
  the executor protocols.
- [SE-0417 Task executor preference](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md):
  `TaskExecutor` and `addTask(executorPreference:)`, which SocketStream is built on.
- [SE-0414 Region-based isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md):
  why non-`Sendable` values can still move between tasks.
- [SE-0430 `sending` parameters and results](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md):
  the ownership-transfer form used in place of `@Sendable`.
- [SE-0461 `nonisolated(nonsending)` and `@concurrent`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md):
  the two spellings this part turns on.
- [SE-0433 `Mutex`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0433-mutex.md) and
  [SE-0410 `Atomic`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0410-atomics.md):
  the `Synchronization` module's primitives.
- [SE-0470 Global-actor isolated conformances](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0470-isolated-conformances.md):
  the proposal behind the `InferIsolatedConformances` upcoming feature, and so behind the warning met in BytesAsync.
<!-- src: titles checked against the raw proposal headers (0304, 0306, 0302 "`Sendable` and `@Sendable` closures", 0338 "Clarify the Execution of Non-Actor-Isolated Async Functions", 0381 "DiscardingTaskGroups", 0392 "Custom Actor Executors", 0417 "Task Executor Preference", 0414 "Region based Isolation", 0430 "`sending` parameter and result values", 0461 "Run nonisolated async functions on the caller's actor by default", 0433 "Synchronous Mutual Exclusion Lock", 0410 "Low-Level Atomic Operations", 0470 "Global-actor isolated conformances", whose header names the upcoming feature flag `InferIsolatedConformances`) -->

#### 6.4 Swift performance and compiler docs

- [Swift's `OptimizationTips.rst`](https://github.com/swiftlang/swift/blob/main/docs/OptimizationTips.rst):
  the compiler team's own advice on `final`, access control and whole-module optimization, copy-on-write, and generic
  specialization.
- [swift-platform-executors](https://github.com/swiftlang/swift-platform-executors):
  `TCPConnection`, `PThreadTaskExecutor`, and the executor implementations SocketStream uses.
- [package-benchmark (ordo-one/benchmark)](https://github.com/ordo-one/benchmark):
  the benchmark harness, with its malloc and instruction counters.
- [swift-argument-parser](https://github.com/apple/swift-argument-parser):
  used by every executable here.
<!-- src: OptimizationTips.rst (its "Advice:" headings: final, private/internal with WMO, copy-on-write, generic declarations in the module where used); swift-platform-executors URL in SocketStream/README.md; ordo-one/benchmark in SocketStream/Package.swift (GitHub's repository name is `benchmark`); swift-argument-parser in Package.swift and AGENTS.md "Ground rules" -->

#### 6.5 Arm and CPU documentation

- [Arm Neon intrinsics reference](https://developer.arm.com/architectures/instruction-sets/intrinsics/):
  each NEON intrinsic, the instruction it compiles to, and what it does; covers the instructions in [Part I](#part-i-foundations) and [Part III](#part-iii-techniques-by-problem).
- [Arm Neoverse and Cortex software optimization guides](https://developer.arm.com/documentation/):
  latency and throughput tables, and the meaning of each pipeline's units, for the Arm cores closest to Apple's.
- [Arm Architecture Reference Manual for A-profile](https://developer.arm.com/documentation/ddi0487/latest):
  the authoritative definition of each instruction and of the memory model.
- [Apple Silicon CPU Optimization Guide](https://developer.apple.com/documentation/apple-silicon/cpu-optimization-guide):
  Apple's description of its cores and caches (cited by the earlier version of Bytes' optimization notes; a developer account may be needed).
- [Dougall Johnson's Apple M1 microarchitecture notes](https://dougallj.github.io/applecpu/firestorm.html):
  per-instruction latency and throughput measured on the M1's performance cores (Firestorm).
- [What Every Programmer Should Know About Memory](https://people.freebsd.org/~lstewart/articles/cpumemory.pdf)
  (Ulrich Drepper): caches, memory, and prefetching in depth.
- [Agner Fog's optimization manuals](https://www.agner.org/optimize/):
  x86 first, but the chapters on dependency chains, branch prediction, and throughput versus latency apply everywhere.
<!-- src: Apple guide, NEON intrinsics, Dougall Johnson, Drepper links from Bytes/OPTIMIZATION.md (old) §14; Arm docs and Agner Fog URLs standard, not from the repository. Link check: intrinsics page 200; developer.arm.com/documentation/ and …/ddi0487/latest answer 301 to support.arm.com, which returns 403 to every automated request (its root too), so those two could not be fetched; Agner Fog 200 on GET (406 on HEAD); the rest 200 -->

#### 6.6 SIMD parsing and text

- [Daniel Lemire's blog](https://lemire.me/blog/): years of posts on SIMD parsing, number formatting, and measuring
  with performance counters.
- [Faster Base64 Encoding and Decoding Using AVX2 Instructions](https://arxiv.org/abs/1704.00605) (Muła, Lemire):
  the SIMD techniques (lookups by byte shuffle, range classification) behind fast Base64.
- [Validating UTF-8 In Less Than One Instruction Per Byte](https://arxiv.org/abs/2010.03090) (Keiser, Lemire):
  table-driven SIMD validation of UTF-8 text.
<!-- src: Bytes/OPTIMIZATION.md (old) §14 (Muła/Lemire, Keiser/Lemire, links); lemire.me/blog is Lemire's well-known blog -->

#### 6.7 Compilers and the vectorizer

- [LLVM's auto-vectorizers](https://llvm.org/docs/Vectorizers.html):
  what the loop and SLP vectorizers handle, and the remarks they print.
- [LLVM Language Reference](https://llvm.org/docs/LangRef.html):
  the IR that `-emit-ir` prints.
- [llvm-mca](https://llvm.org/docs/CommandGuide/llvm-mca.html):
  the throughput estimator `Tools/mca` wraps.
<!-- src: Vectorizers.html link from Bytes/OPTIMIZATION.md (old) §14; Tools/mca described in AGENTS.md; LangRef and llvm-mca pages standard LLVM docs, not from the repository -->

#### 6.8 Formats and algorithms

- [RFC 1951, DEFLATE](https://www.rfc-editor.org/rfc/rfc1951): the format of Bytes' first codec.
- [RFC 1950, zlib](https://www.rfc-editor.org/rfc/rfc1950) and [RFC 1952, gzip](https://www.rfc-editor.org/rfc/rfc1952):
  the wrappers and checksums (Adler-32, CRC-32).
- [RFC 7932, Brotli](https://www.rfc-editor.org/rfc/rfc7932): the format, its dictionary, and context modeling.
- [RFC 8878, Zstandard](https://www.rfc-editor.org/rfc/rfc8878): FSE, Huffman literals, and the frame format.
- [libdeflate](https://github.com/ebiggers/libdeflate): the fast DEFLATE library the benchmarks compare Bytes' DEFLATE
  and Adler-32 with.
- [zstd](https://github.com/facebook/zstd) and [Brotli](https://github.com/google/brotli): the reference implementations.
- [The xz file format](https://tukaani.org/xz/xz-file-format.txt) and the LZMA specification in the
  [LZMA SDK](https://www.7-zip.org/sdk.html): the range coder and the `.xz` container.
- [RFC 8439, ChaCha20-Poly1305](https://www.rfc-editor.org/rfc/rfc8439): the AEAD whose stitched kernel is in [Part III](#part-iii-techniques-by-problem).
- [NIST SP 800-38D, GCM](https://csrc.nist.gov/pubs/sp/800/38/d/final): AES-GCM and GHASH.
- [RFC 8446, TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446): the key schedule and record layer SocketStream's TLS follows.
- [RFC 8448, TLS 1.3 example handshake traces](https://www.rfc-editor.org/rfc/rfc8448): the vectors the tests replay.
- [RFC 9180, HPKE](https://www.rfc-editor.org/rfc/rfc9180): the hybrid public-key encryption used for IPSW keys.
<!-- src: DEFLATE, Brotli, zstd, LZMA, xz, ChaCha20-Poly1305, GCM, TLS 1.3 named in AGENTS.md Repository table and Lessons; RFC 8448 and RFC 9180 named in AGENTS.md `Tools/test-data` (rfc8448, rfc9180 sets); libdeflate in SocketStream/RESULTS.md and Bytes/Benchmarks/RESULTS.md (Inflate/Deflate dickens, Adler-32 rows); URLs standard, not from the repository; all return 200 -->

## Glossary

Each term is bold where the text first defines it; this list collects the terms of all four parts alphabetically.

- **Actor**: a type whose mutable state is isolated to it; only code running on the actor's serial executor touches the
  state, so no lock is needed.
- **AEAD (authenticated encryption with associated data) in place, seal, open**: Bytes' ciphers that encrypt and
  authenticate (`ChaCha20Poly1305`, `AESGCM`) work on the caller's `MutableRawSpan` and allocate nothing.
  `seal` turns the message into ciphertext and returns a tag; `open` checks the tag and decrypts, throwing `.mismatch` for a forgery
  (AES-GCM's open restores the ciphertext when it throws).
- **All or nothing (read semantics)**: a read that throws consumes nothing, so a streaming parser can retry when more data
  arrives; `position` and `rewind(to:)`, or `atomically { … }`, undo a sequence of reads.
- **`any` (existential)**: a box holding a value of unknown type plus its witness table; calls through it are dynamic.
- **AppleDouble**: the format macOS uses to carry a file's extended attributes, Finder info, resource fork, and ACL in a
  separate `._NAME` entry (beside the item or under `__MACOSX`) in archives that cannot hold them; Archive Utility and
  NativeZip *merge* such an entry into its item when extracting.
- **ARC (automatic reference counting)**: Swift's retain/release counting for class instances, closures, and array storage.
- **ASCII tag**: a byte group built from text, such as `Byte4(ascii: "IHDR")`; inlined, it folds to the same hex constant
  as writing the bytes by hand.
- **`assume`, `likely`, `unlikely` (branch weight hints)**: Bytes' internal wrappers over compiler builtins. `assume`
  (`Builtin.assume`) tells the optimizer a condition holds without checking it, so it can merge or drop checks; `likely`
  and `unlikely` set branch weights (`Builtin.int_expect_Int1`) so the slow path is laid out of line. A true assumption can
  still hurt: `_byteOffset >= 0` stopped LLVM from vectorizing loops of single reads.
- **`Atomic`**: the `Synchronization` module's atomic value (SE-0410), such as the `Atomic<Int>` index a lock-free work
  queue increments with relaxed ordering, or an `Atomic<Bool>` stop flag.
- **Attached macro**: a macro that adds members and conformances to a type you declare by generating ordinary Swift at
  compile time in a compiler plugin (`@BitFields`, `@BinaryRecord`); the generated code is as fast as hand-written code
  when it is inlined.
- **Backward bitstream (`BackwardBits`)**: Zstandard's and LZFSE's bit order, read from the last byte toward the first,
  most significant bit first, through a 64-bit container and a count of bits used from its top; one shared field read
  shifts right by 1, then by `63 − count`, so a zero-bit read needs no branch.
- **Bit buffer (`BitBuffer`)**: up to 64 bits of input held in one integer and refilled 8 bytes at a time, for entropy
  decoders. It never throws while decoding: past the end it fills with zeros, and the error surfaces at `finish()` or
  through `isOverrun`.
- **Bit-addressable cursor**: a cursor in the `BitAddressable` mode (`BytesReader`, `BytesWriter`) that reads and writes
  fields of any bit width at any bit position, carrying a bit offset (and, in the writer, the partly written byte).
- **Bit-field extract and insert (`ubfx`, `bfi`)**: take a run of bits out of a register, or put one into a register,
  in one instruction.
- **Block mask (`ByteBlock`)**: 64 bytes tested into one 64-bit integer, byte `i` in bit `i`, made from four `ByteLanes` tests;
  on NEON, `bytes_movemask64` (four `and`, four `addp`, one move). The building block of a structural index.
- **Bounds check**: a test that an index or offset is within a buffer, with a trap or throw if not.
- **Braided CRC**: zlib's table-driven CRC that runs five independent CRCs over interleaved 8-byte words and combines them
  in the last block, which works because a CRC is linear; it turns a latency chain into load-bound work.
- **Branch, branch prediction, mispredict**: an instruction that may change control flow; the core's guess of its
  direction; the cost (about 15 cycles, a pipeline's worth of work thrown away) of a wrong guess. A branch on
  random-looking data is predicted right half the time.
- **Branchless selection**: choosing between values with a select or a mask (`csel`, arithmetic masks) in place of a
  branch, so data-dependent choices cannot mispredict. Where a branch predicts well (LZMA's normalization, rANS refills),
  the branchless forms measured slower.
- **`brk`**: ARM64's trap instruction; where Swift's failed checks land.
- **Byte group (`ByteGroup`, `Byte2`…`Byte16`)**: N consecutive bytes with no byte order applied, stored in the narrowest
  unsigned integer that holds them as a little-endian number; a read is one load (two overlapping loads for odd widths).
- **Byte order (endianness)**: whether a multi-byte integer is stored least-significant byte first (little-endian) or
  most-significant first (big-endian); converting is one byte swap (`rev`).
- **Byte-aligned cursor**: a cursor in the `ByteAligned` mode (`AlignedBytesReader`, `AlignedBytesWriter`) whose bit offset
  is the constant 0, so the bit-level paths fold away and a write is one bounds check and one store.
- **Byte-ordered cursor**: a byte-aligned cursor with a fixed byte order (`BigEndianBytesReader`/`Writer`,
  `LittleEndianBytesReader`/`Writer`) that reads and writes integers by type with no order argument.
- **`ByteBuffer`**: a `~Copyable` buffer for bytes waiting between a producer and a consumer: one allocation, never moved
  or grown, filled at its end through an output span and drained from its front.
- **`ByteLanes`, `ByteMatches`**: `ByteLanes` wraps a `SIMD16<UInt8>` and builds byte tests from wrapping arithmetic and
  bitwise operations, so each compiles to a few NEON instructions; a test returns a `ByteMatches`, with the high bit of each
  matching lane set.
- **Cache, cache line**: small fast memories between the core and main memory; filled in fixed blocks (128 bytes on Apple
  silicon).
- **Caller limit (the SIL inliner's)**: the size past which the SIL performance inliner stops inlining into a function, even
  trivial callees; a loop of `@inline(always)` code can reach it, after which small getters stay calls. The remedy is to take
  a rare part out of the loop.
- **Cancellation handler**: `withTaskCancellationHandler` runs a closure, synchronously, in whoever cancels the task.
  NativeAEA uses one per operation, which closes its pools and queues so every waiter wakes.
- **Canonical Huffman code**: a Huffman code defined by the length of each symbol's code, which the format transmits; the
  code assignment follows from the lengths.
- **Carry region**: the 64 KiB at the front of each NativeAEA buffer, where the first bytes of a header split across two
  chunks are copied so the header is contiguous; file contents are never copied.
- **Carry-less multiplication (`pmull`), folding**: multiplying bit strings with XOR in place of addition; the core of fast
  CRCs. Folding multiplies each running CRC accumulator by a constant that carries it ahead by a block and XORs in the data
  now at that position, with several independent accumulators.
- **Ceiling (loopback TCP)**: the kernel's local-socket throughput, measured with blocking C sockets on plain threads
  (`Tools/socket-ceiling`) to compare networking benchmarks against; loopback TCP tops out around 7.5 GB/s for the whole
  machine.
- **Checksum**: a few bytes that summarize many; archives and network formats compute one per file or message, so it must
  run near memory speed.
- **`cmeq`, `cmhs`**: vector compares that produce all-ones or all-zeros per lane.
- **Combine (of checksums)**: computing the checksum of two pieces joined from the pieces' separate checksums
  (`CRC32.combine`, `Adler32.combine`), which lets parallel code checksum chunks on different cores.
- **Compaction**: `ByteBuffer.compact()` moves the unread bytes to the front; `fill` compacts only when fewer than
  `compactionThreshold` bytes (half the capacity by default) are free at the end.
- **Compute-bound, memory-bound**: limited by the core's arithmetic or by memory delivery.
- **`@concurrent`**: a function that always runs on the global concurrent executor (or the task's preferred task executor),
  never on the caller's actor (SE-0461). Its parameters and result cross an isolation boundary, so they must be `Sendable`
  or `sending`. It suits heavy synchronous work that should stay off an actor.
- **Conditional select (`csel`)**: pick one of two registers by the condition flags, with no branch.
- **Content coding**: how an HTTP message body is compressed (`Content-Encoding`: gzip, deflate, br, zstd). HTTPBytes'
  decoder takes a chunked body's data slice by slice, keeping a codec's unconsumed tail in a carry buffer, and is reset for
  each body instead of made. The encoder codes with `ZstdEncoder` at level 3 and a 512 KiB window.
- **Continuation, checked continuation, unsafe continuation**: a value an `async` function gets from
  `withCheckedContinuation` or `withUnsafeContinuation` to wait for something that is not `async`; it must be resumed
  exactly once. The checked form verifies that at the price of an allocation per wait; the unsafe form neither checks nor
  allocates.
- **Cooperative pool**: the default concurrent executor, a fixed set of threads (one per core) shared by every task with
  no other executor; tasks are expected to give their thread back quickly by finishing or suspending.
- **Cost model**: a compiler's estimate of whether an inlining or vectorization pays.
- **CRC**: the remainder of dividing the data, viewed as a polynomial over bits, by a fixed polynomial; computed with tables,
  by carry-less folding, or with `crc32x`.
- **`crc32x`, `crc32b`**: ARM64 instructions that compute the CRC-32 (IEEE) of 8 or 1 bytes.
- **Critical path**: the longest dependency chain in a loop; sets its minimum time per iteration.
- **Cross-module optimization**: inlining and specializing code from another module, which `@inlinable` makes possible.
  Inlining decisions depend on a module's contents, so moving code between modules changed instruction counts even when
  it stayed inlined (Part III, ["Inlining and specialization"](#5-inlining-and-specialization)).
- **Cursor**: a small value that remembers a position in a span and reads or writes fields in order (`BytesReader`,
  `BytesWriter`); fast only while its fields stay in registers.
- **Cursor mode (`BytesCursorMode`)**: the type that specializes `GenericBytesReader` and `GenericBytesWriter`:
  `BitAddressable`, `ByteAligned`, `BigEndianBytes`, or `LittleEndianBytes`.
- **Cycle**: one tick of the core's clock, about 0.25 ns at about 4 GHz.
- **Declared unit size**: a pipeline stage's `maximumUnitByteCount` (most input a call may need before it can consume any)
  and `minimumOutputCapacity` (least free output it needs); `Pipeline` sizes its buffer from them.
- **`decmpfs`**: APFS's transparent file compression: a resource fork, a `com.apple.decmpfs` extended attribute (a 16-byte
  header, data inline when small), and the `UF_COMPRESSED` flag, in chunks of 64 KiB.
- **`Decompressor`, `DecompressionFormat`**: one decoder over every format Bytes decodes, with each format's state made on
  its first stream and kept; `reset(for:)` names the format (carrying what its container records), and `decompress` or
  `decompressAll` decodes.
- **Deflate64**: PKWARE's variant of DEFLATE (zip method 9) with a 64 KB window, matches of up to 65,538 bytes, and two more
  distance codes; `DeflateDecoder(variant: .deflate64)`.
- **Dependency chain**: instructions that each need the previous one's result, so they cannot overlap; it runs at one
  step's latency per link however wide the CPU is.
- **Descriptor (`BitFlag`, `BitField`, `BitPattern`)**: a bit-level field declared once and used by name: one bit as a
  `Bool`, adjacent bits as a value, or fixed bits checked at once (`0`, `1`, `?` free, `_` between groups).
- **Differential test**: running two implementations on the same inputs and comparing every output: another library's
  test suite (with a table of deliberate differences), or the previous version of the code as a second module. A difference
  that stops occurring fails the test, so the table stays exact.
- **Discarded cycles**: the share of cycles whose work was thrown away after mispredictions, as `Tools/counters`'
  `bottlenecks` mode reports it beside useful, front-end, and back-end cycles.
- **Discarding task group**: a task group made with `withDiscardingTaskGroup` (SE-0381) for child tasks whose results are
  not collected.
- **Double-fast (`dfast`), fast (Zstandard match-finding strategies)**: libzstd's strategies for levels 1 and 2 (`fast`: one hash
  table of earlier positions, a step that grows while nothing matches) and 3 and 4 (`dfast`: a second table for long matches
  beside the short ones). `ZstdEncoder` implements both and no others.
- **Draining (QPACK)**: an entry of the dynamic table that a quarter of the capacity's insertions or less will evict
  (RFC 9204 §2.1.1.1). An encoder does not refer to it as a name, and copies a field it holds to the table's front with a
  **Duplicate** instruction (§4.3.4). HTTPBytes' encoder keeps each entry's place among all insertions' bytes and a boundary
  number that moves forward as entries are inserted.
- **Early exit**: a `return`, `throw`, or failing check inside a loop; it prevents vectorization, because the vector loop
  would already have run the lanes after the exit.
- **Efficiency core (E core), performance core (P core)**: the slower and the faster core types on Apple silicon.
  Queue-fed work gains from E cores; work split statically across lanes waits for the lane that lands on one.
- **Entropy coding**: replacing frequent symbols with short bit strings (Huffman, arithmetic, ANS); a decoder's inner loop
  peeks some bits, looks them up, and consumes the code's length, once per symbol.
- **`~Escapable` (non-escapable)**: a type whose values cannot be stored in a class or a global, captured by an escaping
  closure, or returned unless the function declares whose lifetime they borrow; the span family is non-escapable, which
  is how the compiler guarantees a span never outlives its memory.
- **Event loop**: the loop on a `PThreadTaskExecutor` thread that drives socket I/O (SocketStream's kqueue backend) and
  resumes suspended reads and writes with `resumeSynchronously`.
- **Exclusivity enforcement**: the run-time check (`swift_beginAccess`) that a class property is not accessed in
  conflicting ways.
- **Executor**: what runs a task's jobs, one after another (a serial executor) or several at a time (a concurrent one).
- **`ext`**: extract a 16-byte window from two concatenated vectors at a byte offset.
- **First-and-last-byte filter**: a pattern search that compares the pattern's first byte against 16 loaded bytes and its
  last byte against the 16 bytes `byteCount − 1` further on, checking the full pattern only where both match.
- **Flush (`TransformFlush`)**: what a pipeline stage is asked to do with its input: `.none` (transform as it sees fit),
  `.flush` (end the output on a boundary the next stage can use in full), or `.finish` (no more input).
- **FSE (finite state entropy)**: a table-based ANS entropy coder, used by Zstandard's sequence tables and by LZFSE.
- **Full mode (malloc stack logging)**: `MallocStackLoggingNoCompact`, which records every allocation and free with its
  stack (the default, lite mode, keeps only live allocations); `Tools/allocations --history` reads it with
  `malloc_history -allEvents` to find allocations that were freed again. It makes libobjc allocate a page per autorelease
  pool push, which the tool leaves out and counts.
- **Function merging**: LLVM folding identical functions into one, and, in Swift's pipeline, functions that differ only in
  constants into one `merged …` function that takes them as a parameter. It can undo a specialization; it also proves two
  forms compile to identical code.
- **Fused pipeline (`FusedPipeline`)**: a pipeline whose second stage works in place (`InPlaceByteTransform`, a stream
  cipher), so it rewrites the first stage's output where it was written, with no buffer between them.
- **Gate (allocation gate), zero-malloc threshold**: a benchmark threshold at zero `malloc` calls (a `Thresholds/` file at
  0) that fails when anything allocates.
- **Gather**: loading each lane from a different, computed address; NEON cannot gather from memory, `tbl` gathers from
  registers. A lookup at a computed index in a loop is a gather and blocks the vectorizer.
- **Generating write**: `write(_:_:count:_:)`, which takes a closure from index to value; a counted loop of stores that
  vectorizes together with the closure.
- **Generic executor**: the cooperative pool, where a `nonisolated async` function runs under SE-0338's rules, switching
  there on entry, after each call returns, and after each suspension.
- **Geometric mean**: the average of ratios used to summarize many benchmark rows at once (time against a reference build,
  or one machine's time against another's).
- **GHASH**: AES-GCM's hash, a multiplication by the hash key per block; Bytes computes it with `pmull` (three per multiply,
  eight blocks summed before one reduction), and without `pmull` bit by bit in constant time.
- **Global actor**: an actor a function can be isolated to by attribute, such as `@MainActor`.
- **`GroupShuffle`**: Bytes' internal helper that builds a byte shuffle from lanes of a vector picked at constant
  positions, which LLVM compiles to one shuffle (a single-register `tbl`), to pack and unpack 3- to 7-byte groups with no C.
- **Hop**: a `swift_task_switch` that finds the task on the wrong executor: the runtime enqueues a job on the right one, the
  thread goes back to the pool, and the task continues later, usually on another thread with cold caches.
- **HPACK**: HTTP/2's field compression (RFC 7541): a 61-entry static table, a dynamic table of recent fields, and a Huffman
  code for strings. HTTPBytes decodes Huffman with a 14-bit table whose entries decode one or two symbols, keeps dynamic
  entries contiguous and numbered by insertion, and caches each entry's validation.
- **IMF-fixdate**: HTTP's preferred date format (RFC 9110 §5.6.7): `Sun, 06 Nov 1994 08:49:37 GMT`, always 29 bytes. `HTTPDate`
  reads it as four 8-byte words (masks for the fixed bytes, one SWAR test for the 14 digits, a perfect hash for the month) and
  turns the date into days with Hinnant's `days_from_civil`, without branches.
- **Independent chains**: separate dependency chains interleaved in one loop so their latencies overlap: eight ChaCha20
  blocks at once in place of four, eight CRC fold accumulators, eight `udot` accumulators for Adler-32's weighted sum, and a
  byte sum started from zero in each step so that no step waits on the one before.
- **`InferIsolatedConformances`**: an upcoming-feature flag (from SE-0470, global-actor isolated conformances) under which
  a generic `@concurrent` function called on a type parameter warns that its conformance "may be isolated".
- **`@inlinable`**: makes a function's body visible to other modules so it can be inlined and specialized; does not by
  itself cause inlining.
- **`@inline(always)`, `@inline(__always)`**: the guaranteed and the hint-only inlining attributes. The SIL inliner
  declined an `@inline(__always)` function once its caller's loop grew; `@inline(always)` (Swift 6.4, SE-0496) inlined it
  (Part I, ["Inlining and its cost model"](#42-inlining-and-its-cost-model)).
- **`InlineArray`**: `InlineArray<N, T>` stores exactly `N` elements in the value that holds it, with no allocation and no
  reference count. Indexing one that is a stored property or a `borrowing` parameter can copy the whole array per access;
  take its `span` once and index that.
- **Inlining, outlining**: replacing a call with the callee's body; moving code into a separate function.
- **Instruction, micro-op**: what the program is made of; the smaller operations an instruction splits into inside the
  core.
- **Interleaved A/B run**: verifying a timing change by building the old and new code and alternating their runs
  (`ab-old-1`, `ab-new-1`, `ab-old-2`, …), comparing round by round, because times drift between runs.
- **Intrinsic**: a function the compiler maps to one specific instruction. Swift has none for NEON; Bytes reaches those
  instructions through `static inline` C functions.
- **Invariant assumption (`_assumeInvariant`)**: the cursor's statement to the optimizer, with `Builtin.assume`, of three
  facts that always hold (`_byteOffset <= span.byteCount`, `0 <= _bitOffset < 8`), which lets it merge bounds checks.
- **Inverse BWT**: bzip2's final pass, undoing the Burrows-Wheeler transform by following a table where each output byte
  needs the previous byte's entry; Bytes walks 24 segments at once so the dependent loads overlap.
- **Isolation**: the compiler's record of which actor, if any, may touch a piece of state.
- **Jacobian coordinates**: the point representation Bytes' P-256 and P-384 code uses; with the two special cases a
  fixed-window ladder can meet chosen by masks, it beat complete projective formulas in constant-time ladders (a doubling
  costs 3M + 5S against 8M + 3S).
- **Job**: the piece of a task between two suspension points; the unit an executor runs.
- **Jump threading**: an LLVM pass that, when one branch's outcome decides a later one's, routes control straight to the
  known target; it can turn correlated `if`s into real branches that stop a loop vectorizing.
- **Karatsuba multiplication**: the method by which GHASH multiplies by the hash key with three `pmull`s.
- **kqueue**: the I/O backend SocketStream picks for `PThreadTaskExecutor`; with one executor per task, a task, its socket's
  kqueue, and its buffers stay on one thread.
- **Lane, lane insert**: one element slot of a vector register; moving one value into one lane.
- **Latency, throughput**: cycles until an instruction's result is ready; instructions of that kind the core can start per
  cycle.
- **Lazy initialization**: running a global's or `static let`'s initializer on first use, guarded by a once-token.
- **`ld1`, `ld3`, `ld4`, `st3`, `st4` (structure loads and stores)**: `ld1` loads consecutive bytes into vectors; the
  others deinterleave or interleave 3–4 registers as they move (`ld2`/`st2` do 2).
- **LEB128**: the variable-length integer of MQTT, Protocol Buffers, WebAssembly, and DWARF: 7 bits per byte, least
  significant group first, with the high bit set on every byte but the last.
- **Lending (`LentBytes`, `LentMutableBytes`, `LentMutableSpan`)**: handing a span's memory to other threads or child tasks
  as a `Sendable` pointer (`withLentBytes`, `withLentFreeCapacity`; initialized memory to read and write in place with
  `MutableRawSpan.withLentBytes`), through scoped functions whose rule is that the work using it must finish
  before the function returns; the async forms guarantee that with `await`.
- **Lifetime annotation (`@_lifetime`)**: the declaration of what a returned non-escapable value depends on, which lets a
  function return a span. `@_lifetime(copy data)`: the result inherits the lifetime of `data`, itself non-escapable (a
  span parameter), so it lives as long as the memory `data` views. `@_lifetime(borrow x)`: the result borrows `x` itself
  (an array, a buffer that owns its memory) and is valid only while `x` is. "Copy" refers to the dependence, never to
  bytes.
- **Limit per round (output limit)**: a decode loop's way to check bounds once per round instead of once per symbol: when each
  iteration consumes at most *k* bits of input per byte of output it writes, a limit on the output (recomputed each round
  from the input left) guarantees the input, so the loop's loads and stores are unchecked.
- **LLVM IR**: the lower-level representation SIL is turned into, where LLVM's general passes run.
- **Longest-processing-time scheduling**: sorting work items largest first, so a big item does not start last and leave
  the other workers idle (NativeZipArchive's worker pool).
- **Loop vectorizer, SLP vectorizer**: LLVM passes that vectorize a loop across iterations, or straight-line scalar
  operations on neighboring data (superword-level parallelism).
- **Lost wake-up**: a wake-up that slips between a waiter's check and its storing of the continuation. Checking again under
  the lock inside the continuation's body prevents it.
- **Malloc interposer**: package-benchmark's allocation counter. It costs about 10% on large transfers, biases comparisons
  with libraries that allocate per call, and traps on thread exit, so allocation gates are separate single-threaded
  benchmarks.
- **Mask**: a value with all bits set (`0xFF`) or clear in each lane, used to select or zero values without a branch.
- **Match extension (`commonPrefixLength`)**: counting how many bytes agree at a candidate match, 8 at a time (XOR two
  words; the first difference is `trailingZeroBitCount / 8`). `unsafeCommonPrefixLength` drops the per-call bounds check
  for match finders that prove their bounds.
- **Montgomery multiplication**: the modular multiplication of Bytes' elliptic-curve and RSA code, computed row by row;
  parsing an RSA key computes R² mod n for it.
- **Multi-symbol Huffman table**: a decoding table indexed by the next *k* bits whose entries hold up to two decoded symbols and
  the bits they used, so one lookup can emit two symbols; codes longer than *k* bits go to a slower path. HPACK's decoder
  uses 14 bits (16,384 four-byte entries).
- **`Mutex`**: the `Synchronization` module's lock (SE-0433); NativeAEA's waits are `Mutex` state plus a continuation.
- **NAF (non-adjacent form)**: a signed-digit representation of a scalar that needs fewer additions, used for ECDSA
  verification's multiplications.
- **NEON**: Arm's 128-bit SIMD instruction set.
- **Nibble mask**: `ByteMatches.nibbleMask`, which packs the 16 lanes' matches into 64 bits, four bits per lane, in four
  instructions; the first match is `trailingZeroBitCount / 4`.
- **`nonisolated`**: code outside any actor.
- **`nonisolated(nonsending)`**: a function that runs on whatever executor its caller is on (SE-0461): no switch on entry
  and none after calls to other such code. What it receives does not cross an isolation boundary, so it can take `inout`
  parameters and borrowed spans; heavy work in it runs on the caller's actor, if the caller is on one.
- **`NonisolatedNonsendingByDefault`**: an upcoming feature, enabled in Bytes, that makes a plain `nonisolated async`
  function mean `nonisolated(nonsending)`.
- **One shot, streaming, parallel (entry points)**: the three shapes of every codec. One shot takes the whole input and
  output (`compressAll`, `decompressAll`, which decodes straight into the caller's output); streaming takes input in pieces
  and keeps a window; parallel works on chunks or segments across lanes.
- **Optimized, portable, portable-no-c (builds)**: Bytes' three builds, chosen by package traits: the default with the C
  modules' NEON, CRC, and crypto instructions; `--traits Portable`, the C modules' fallbacks for other CPUs; and
  `--disable-default-traits`, Swift only.
- **Out-of-order execution**: running later instructions while earlier ones wait for inputs.
- **Output span (`OutputSpan`, `OutputRawSpan`)**: a view of memory that may hold garbage, plus a count of the bytes written
  so far; appending moves the count, so a new array can be filled without zeroing it first.
- **Overrunning write (overrun)**: a write that stores a whole word (or 16-byte moves) and advances by fewer bytes,
  overwriting the bytes after the value with garbage the next write replaces, so it needs no branch on the length; it
  needs room past the end (`copyOverrun`, 32 bytes, for back-reference copies).
- **Package trait**: an optional feature a package's users switch on or off (SE-0450); Bytes uses them to choose its C
  modules and builds.
- **Perfect hash**: a hash function chosen, by a generator, so that no two keys of a fixed set share a slot: a lookup is one
  hash, one load, and one comparison, with no probing. HTTPBytes' known field names (about 120) are looked up from the name's
  length and two 8-byte words, and `HTTPDate`'s month from its three letters (times 26,596, shifted right by 28, into 16 slots).
- **Pipeline stage (`ByteTransform`)**: a transform from input spans into an output span that reports what it consumed and
  produced, as zlib's `deflate` and `inflate` do; stages compose with `then` into a `Pipeline` that specializes to one
  function.
- **Pipeline, superscalar**: overlapping instruction stages; starting several instructions per cycle.
- **Placement**: how SocketStream assigns executors: `threadPerTask` (a single-thread `PThreadTaskExecutor` for every
  sender and receiver) or `sharedPool` (one pool of threads for every task).
- **Prefetching**: loading cache lines before they are asked for, when a pattern is detected, or on request: the compiler's
  `Builtin.int_prefetch_RawPointer` emits `prfm` (`ZstdEncoder`'s match search, where libzstd's prefetches took 2.5 to 8% off level 1).
- **Process model (package-benchmark)**: one process to list the benchmarks, then one per benchmark, each running the
  whole registration closure.
- **`PThreadTaskExecutor`**: swift-platform-executors' task executor that owns its threads, with an I/O backend; SocketStream
  runs its senders and receivers on it.
- **Quarantine (`com.apple.quarantine`)**: the extended attribute macOS puts on downloaded files, which Archive Utility copies
  from the archive onto everything it extracts; Disk sets it on each file while it is open, one `fsetxattr` per entry
  (13–17% more instructions on small files).
  <!-- src: Disk/RESULTS.md "2026-11-20: the package" "Options, interleaved" bullet "The quarantine costs 13–17%" -->
- **`RawStorage`, resident floor**: memory allocated once and shared by reference (a decoder's read buffer, a pool's
  storage); `giveBack` returns the pages past a 2 MiB resident floor to the kernel (`MADV_FREE_REUSABLE`) after each use and
  `reuse` takes them back before the next.
- **QPACK**: HTTP/3's field compression (RFC 9204): HPACK redesigned for streams that arrive out of order. A field section can
  name a table entry that has not arrived (a **blocked stream**); HTTPBytes' decoder records the stream and the caller, which
  already holds its bytes, decodes it when `nextUnblockedStream()` names it. The encoder inserts a field on its second
  sighting, refers to a **draining** entry's **Duplicate** instead, and inserts a recurring name alone.
- **rANS**: the ANS entropy coder of LZRAVEN's literals; its decoder interleaves eight states, and its refill branches stay
  branches because their mispredictions are off the critical path.
- **Record (`BinaryParsable`, `BinaryWritable`, `FixedSizeBinary`)**: a fixed run of fields read or written in one call;
  `FixedSizeBinary` states a constant `byteCount`, so a record of such fields is read with one bounds check.
- **Reduction**: combining all lanes of a vector into one value (`umaxv`, `addv`).
- **Reference-counted buffer pool**: NativeAEA's single page-aligned allocation divided into buffers, each counting the
  walker and the jobs that point into it; the last release hands it to the longest waiter, which bounds memory.
- **Refill**: loading the next 8 bytes into a bit buffer so at least 56 bits are buffered; the fast path's load is
  unchecked, and the slow refill near the end takes and returns values.
- **Register, register file**: a storage slot inside the core, the only place it computes; ARM64 has 31 general-purpose and
  32 vector registers.
- **`RelaxedCounter`, `RelaxedCounters`**: `BytesAsync`'s counters with relaxed atomic ordering, for statistics and for
  claiming the next index of a work queue (`claim(below:)`); `RelaxedCounters` holds *N* of them in one allocation.
- **Request smuggling**: attacking a chain of HTTP servers that disagree about where a message ends (Content-Length against
  chunked, obsolete line folding, a comma in a length). A parser's framing rules are tested against other implementations'
  smuggling suites, with every deliberate difference listed. Composing a chunked decoder before a gzip decoder with `then` invites it: the
  pipeline ends at the gzip stream, so `HTTPBodyDecoder` makes a body one stage that ends where its framing does.
- **`resumeSynchronously`**: the PR toolchain's continuation call that swift-platform-executors uses to resume a suspended
  socket operation directly from the event loop, on the thread where it suspended.
- **Root table, subtable**: `HuffmanTable`'s layout: a table indexed by the next `rootBits` bits (10 by default), in which
  a short code fills every entry starting with it and a longer code's entry links to a subtable, so a decode takes one or
  two lookups.
- **Rounds, queue (`ChunkScheduler`)**: two ways to run parallel chunks. Rounds give one chunk per lane with a barrier
  after each; `ChunkScheduler` runs one `concurrentPerform` or task group per call, with workers taking the next chunk and
  handing output to slots. The queue was 8–22% faster than two rounds and 22–41% faster than four.
- **Scalar**: one value at a time, as opposed to SIMD.
- **Scalar replacement**: the optimizer breaking a struct into its fields and keeping each in a register, which it does
  only if nothing takes the struct's address.
- **Sealing lanes**: `TLSRecordSealer`'s `sealingLanes`, which seals full TLS records on several `concurrentPerform` lanes,
  each writing straight into its records' places in the output.
- **Section (sub-cursor)**: a cursor of its own over the next N bytes (`readSection(byteCount:)`); every read in it is
  bounded by the section, and with N a constant the reads inside need no bounds checks.
- **`Sendable`**: a type whose values are safe to use from several concurrency domains at once: immutable, or protected by
  a lock.
- **`SendableMetatype`**: a constraint a generic function can place on its type parameter; with it, a generic
  `@concurrent` function in BytesAsync still drew the `InferIsolatedConformances` warning.
- **`sending`**: a per-value guarantee (SE-0430) that the value is not shared with anything the caller keeps using, so it
  can move to another domain even though its type is not `Sendable`.
- **SIL (Swift Intermediate Language)**: the compiler's Swift-aware IR where inlining, specialization, and ARC passes run.
- **SIMD, vector instruction**: Single Instruction, Multiple Data: one instruction operating on several values at once.
- **Single-segment frame (Zstandard)**: a frame whose window is its content, so a decoder needs no window beyond the frame's
  size. `ZstdEncoder` makes one only when the content size is known and fits the configured window.
- **Skip window**: cursed-http's test "is there a control byte in the next 256, then 512 bytes?" (an add and a signed minimum per
  16 bytes) in place of an exact mask, for long lines. HTTPBytes tried it and did not keep it.
- **Slack (`BitWriter.slack`)**: the 8 bytes of room past the last whole byte that a bit writer's flush needs, because it
  stores all 8 bytes of its register and advances only past the whole ones.
- **Span**: a view of contiguous memory, conceptually a pointer and a count, with the compiler's promise that the memory
  stays valid while the view is used (`Span`, `RawSpan`, `MutableSpan`, `MutableRawSpan`).
- **Specialization**: a copy of a generic function for concrete types, removing the metadata calls.
- **Speculative parallel decoding**: `ParallelDeflateDecoder` splits a DEFLATE stream after sync-flush markers, decodes
  the segments at once, and accepts segment *j* only if segment *j* − 1 ended exactly at its start; a segment that fails
  is decoded again in place, and the whole stream is decoded sequentially only if the first segment fails.
- **Spill**: storing a register's value to the stack because the compiler ran out of registers or needed its address.
- **Split continuation**: the unmerged Swift pull request (swiftlang/swift#91981) whose toolchain swift-platform-executors'
  I/O needs; with it, a suspended read or write resumes on the thread running the event loop.
- **Statically initialized global**: a global or `static let` whose initializer the compiler evaluates at compile time
  (literal arrays and `InlineArray`s), so it is stored statically with no `swift_once` check.
- **Stitching**: interleaving two independent computations that use different units, closely enough for the out-of-order
  window to run both, such as Poly1305's multiplies among ChaCha20's vector rounds; it saves time with about the same
  instructions.
- **Store-to-load forwarding**: passing a stored value directly to a load of the same address, without waiting for the
  cache; still several cycles, which can sit on a loop's critical path.
- **Streaming window**: the buffer a streaming LZMA or xz decoder owns (a flat window of the dictionary plus room, slid to
  its front when full), so the decode loops run unchanged into it and the caller receives output as it has room.
- **Strict memory safety**: the Swift mode requiring `unsafe` on every use of an unsafe construct.
- **Structural index**: one bit per input byte marking the bytes that matter (delimiters), built a block at a time with SIMD
  tests and walked with `trailingZeroBitCount` instead of a scan from delimiter to delimiter (simdjson's idea). HTTPBytes
  keeps only the current 64-byte block's mask, so a head parser needs no memory per message.
- **Structured concurrency**: child tasks that cannot outlive the scope that created them (SE-0304: task groups, `async
  let`); the runtime knows the tree and propagates cancellation and priority escalation down it.
- **Structured Field Values**: HTTP's typed header syntax (RFC 9651): items, lists, dictionaries, parameters. HTTPBytes parses
  them with `~Escapable` iterators whose members are views of the field's bytes, so nothing is built or allocated.
- **Suspension point**: an `await` where the task may give up its thread; an `await` of something already ready does not
  suspend and costs only a call.
- **SWAR (SIMD within a register)**: ordinary 64-bit integer operations on eight packed byte fields at once, as in reading
  up to 8 ASCII digits with one load, one check, and three multiplies, or an HTTP date's 14 digits tested with an XOR, an add,
  and a mask per 8-byte word.
- **Sweep (merging into bounded storage)**: producing a union of ranges by repeatedly finding the lowest range not yet covered and
  growing it while anything touches it, re-reading the input each time, so the storage holds only the answer
  (`HTTPRangeSet.resolve`); inserting in arrival order can need more slots on the way than the answer has.
- **`swift_once`**: the runtime call behind lazily initialized globals and `static let`s.
- **`swift_task_switch`, executor check**: the runtime call at the entry of an `async` function, and after each call that
  might have changed executors. When the task is already where it must be, it returns at once (a check) and nothing moves.
- **Sync flush**: an empty stored block (bytes `00 00 FF FF`) that leaves a DEFLATE stream between blocks on a byte
  boundary; every chunk of `ParallelDeflateEncoder` ends with one, which is where the parallel decoder splits.
- **Table lookup (`tbl`, `tbx`)**: NEON's lookup of each byte of an index vector in a table of 1–4 registers (16–64
  bytes); `tbx` leaves out-of-range lanes unchanged. Each costs a micro-op per table register on the M3, which bounds
  table-driven kernels.
- **Task**: a unit of asynchronous work, an `async` call tree with its own priority, cancellation flag, and task-local
  values; a heap object the runtime schedules onto threads in pieces.
- **Task executor, executor preference**: an executor a task and its children can prefer (SE-0417), so nonisolated async
  code in them runs there; set per child with `addTask(executorPreference:)`.
- **Task priority**: a task's scheduling priority, which a child inherits from its parent; an `async` `main` runs at 21
  (`.medium`).
- **Test oracle**: a trusted implementation whose output a new one is compared with, byte for byte. `ZstdEncoder` was ported
  decision for decision from libzstd, so libzstd's frame is the oracle: a slip shows at the first differing byte, where a round
  trip would pass.
- **Thunk**: a compiler-generated wrapper function; merged closures called through one kept a writer in memory.
- **Top-aligned code (Huffman writer)**: a code table entry with its code value in the high bits and its length in the low 8
  (`value << (64 - length) | length`), so adding a code to a right-shifting container is one shift and one OR, the shift
  amount being the entry itself.
- **Type metadata, witness table, value witness table**: the run-time descriptions generic code uses for types it cannot
  see.
- **Typed span of blocks**: a `Span` whose elements are fixed-size blocks (`Span<InlineArray<48, UInt8>>`); loop indices
  come from `indices`, so one comparison of the counts covers every access and the loop can vectorize.
- **Typed throws (boxing)**: `throws(E)`, a function that throws one named error type, traveling as a plain value with no
  box. A `do { } catch` around such a call boxes the error (`swift_allocError`) unless written `do throws(E)`.
- **`udot`**: the dot-product instruction (`FEAT_DotProd`): four byte products summed into each 32-bit lane.
- **`umaxv`**: reduction to the largest lane.
- **Unsigned compare (count check)**: `UInt(bitPattern: n) <= UInt(bitPattern: remaining)`, which rejects a negative and an
  oversized count in one comparison, because a negative `n` becomes a huge unsigned number.
- **Unstructured task**: a task made with `Task { }` or `Task.detached`, outside the task tree; nothing waits for it, and
  cancelling the code that created it does not cancel it.
- **`usra`, `ushr`, `shl`**: vector shifts; `usra` shifts right and accumulates.
- **Vectorization, auto-vectorization**: turning a loop that handles one element per iteration into one that handles
  several (16 bytes on ARM64) with vector instructions; auto-vectorization is the compiler doing it.
- **Waiting primitives**: `BytesAsync`'s `Continuation`, `WaiterQueue`, `AsyncLimiter`, `AsyncIndexPool`, `AsyncLatch`,
  `AsyncQueue`, and `AsyncHandoff`: `Mutex` state plus continuations, with a synchronous fast path, no lost wake-ups, and
  resumption outside the lock.
- **Worker pool**: a fixed number of child tasks that each take the next item from a shared queue
  (NativeZipArchive's `forEachConcurrently`).
- **Workspace (caller-supplied scratch)**: scratch memory an algorithm needs, allocated once by the codec or passed in by
  the caller (`Scrypt.deriveKey(…scratch:…)`), so the operation itself allocates nothing.
- **Wrapping arithmetic (`&+`, `&-`, `&*`)**: Swift's operators that wrap on overflow instead of trapping; one bare
  instruction each.
- **`xtn`, `shrn`**: narrowing: keep the low half of each lane, optionally after a right shift.
- **`zip1`, `zip2`, `uzp1`, `uzp2`**: interleave two vectors lane by lane; take the even or odd lanes.

<!-- src: definitions adapted from Bytes/OPTIMIZATION.md (old) §13 Glossary and the sections of this document where each term is defined -->
