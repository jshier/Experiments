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
| NativeZipArchive | ZIP (stored, DEFLATE, Deflate64, bzip2, LZMA, xz, Zstandard; ZipCrypto and WinZip AES), `nunzip` | File-system limits, parallel extraction, DEFLATE |
| NativeAEA | Apple Encrypted Archives, Apple Archives, Xcode's `.xip` | Decode pipelines, crypto, APFS behavior |
| SocketStream | MQTT over sockets, optionally compressed and encrypted | Concurrency, executors, buffers |
| BinaryParsingComparison | Bytes against swift-binary-parsing on the same formats | Honest comparison of two designs |

<!-- src: AGENTS.md "Repository" table, rows MQTT, SocketStream, NativeZipArchive, NativeAEA, BinaryParsingComparison -->

**Headline results.** Every figure is on the machine described below, release builds, medians:

- Base64 encoding reaches 21.5 GB/s at 1 MB, level with C of the same design and 93% of a C kernel that uses `ld3` and
  `st4` (ARM's deinterleaving load and interleaving store, [Part I](#part-i-foundations)) directly.
  <!-- src: Bytes/Benchmarks/RESULTS-base64.md "Encoding" table (M3 Ultra column, d2-final: 21.5 GB/s at 1 MB) and "The ceiling: a C kernel with ld3 and st4" (23.1 GB/s; same-design C 21.8); Bytes/OPTIMIZATION.md (old) §10 (93%) -->
- CRC-32 uses ARM's carry-less multiply and CRC instructions: 32 MB in 532 µs (63 GB/s) against zlib's 888 µs, and
  2.3x zlib at 64 bytes.
  <!-- src: Bytes/IMPROVEMENTS.md headline table row "CRC-32, hardware path" -->
- The Zstandard decoder is faster than libzstd on every Silesia input and level: 1.12–1.45x for one call, with 7–22%
  fewer instructions.
  <!-- src: Bytes/Benchmarks/RESULTS.md line 671 "Faster on every Silesia input and level: one call 1.12–1.45x" -->
- ChaCha20-Poly1305 seals 1 MB at 2.50 GB/s (Poly1305's work interleaved into ChaCha20's rounds, −40% time), 2.95x
  CryptoKit's `ChaChaPoly` in the `d2-final` run. AES-128-GCM seals 1 MB at 7.9 GB/s (CryptoKit, on the same run, 9.4).
  <!-- src: Bytes/Benchmarks/RESULTS.md line 762 (1.52 → 2.50 GB/s, −40%); line 596 (2.95x CryptoKit); line 98 (AES-128-GCM seal 1 MB 7.9 GB/s) -->
- TLS 1.3 records sealed on several cores: AES-128-GCM 5.7 / 20.3 / 32.7 GB/s on 1 / 4 / 8 lanes (parallel workers).
  <!-- src: Bytes/Benchmarks/RESULTS.md line 609 "Parallel sealing" -->
- Parsing MQTT PUBLISH packets as views of the input, not copies, is 8.6x faster on one core than conventional parsing
  into `[UInt8]` and `String`, and 18.6x on all cores.
  <!-- src: MQTT/Benchmarks/RESULTS.md 2026-11-19 "The views against the conventional code" (M3, d2-final's code: 8.6x one core, 18.6x all cores; supersedes the older 5.5x) -->

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
performance and 8 efficiency cores, about 4.05 GHz maximum performance-core clock, 256 GB of LPDDR5-6400), macOS 27.2,
Xcode 27.3, Swift 6.4.2 and, for the later measurements, 6.4.4, release builds. A second machine, an Apple M1 Max
(8 performance and 2 efficiency cores, about 3.23 GHz), is used where a section says so.
<!-- src: Bytes/Benchmarks/RESULTS.md lines 14-26 (machine table; "Xcode 27.3's Swift 6.4.4"); Bytes/OPTIMIZATION.md (old) intro ("Swift 6.4.2 (Xcode 27.3; 6.4.4 for the 2026-11-17 and later measurements)") -->
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
  - [12. Measuring honestly](#12-measuring-honestly)
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
single register. On an M1 Max core, measured with probes (small test programs), a `tbl` ([section 2.4](#24-table-lookup-tbl-and-tbx)) with one or two table registers runs 4 per cycle, with
three registers 1.9 per cycle, with four registers 1.3 per cycle, and a four-register `tbx` 1.0 per cycle.
<!-- src: Bytes/Benchmarks/RESULTS.md "What the cores can do: instruction and memory measurements (one P core)" table (tbl 1-2 regs: 4/cycle; 3: 1.9; 4: 1.3; tbx 4: 1.0) -->

The core also runs instructions **out of order**: while an earlier instruction waits for its inputs, later ones that do
not depend on it can run, within a window of a few hundred instructions. This is what lets two independent chains of
work overlap.
<!-- src: Bytes/OPTIMIZATION.md (old) §13 glossary "Out-of-order execution" -->

#### 1.2 Latency, throughput, and dependency chains

Two numbers describe an instruction. Its **latency** is how many cycles pass before its result can be used. Its
**throughput** is how many of that instruction the core can start per cycle. On the M1 Max, a vector `add` (an add on
several values at once, [section 2](#2-simd-and-neon)) has 2 cycles of latency and a throughput of 4 per cycle. There are four 128-bit vector
pipes (the units that execute vector instructions); the probe took these two values as its calibration, so the others are
good to about ±15%. `udot` and `pmull` have 3 cycles of latency and run at 2.7 per cycle; `aese` has 3 cycles of latency
at 2.7 per cycle, and `aesmc` 2 cycles at 4 per cycle. Sections [2.8](#28-dot-products-udot) and [2.9](#29-carry-less-multiply-crc-aes-and-sha-instructions) describe these instructions.
<!-- src: Bytes/Benchmarks/RESULTS.md "What the cores can do" (calibration assumption: add 2 cycles, 4 a cycle; "treat cycles as ±15%"; table: udot, pmull: 3 / 2.7; aese/aesmc: 3, 2 / 2.7, 4) -->

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
load's address comes from the previous load), one pointer per 128-byte line:

| Working set | Load-to-use latency |
|---|---|
| 16–128 KB (L1 data) | 0.93–1.2 ns (about 3 cycles) |
| 256 KB–2 MB (L2) | 5.3–5.6 ns (17–18 cycles) |
| 16 / 32 MB | 35 / 52 ns (system-level cache) |
| 128–256 MB (DRAM) | 121–124 ns |

<!-- src: Bytes/Benchmarks/RESULTS.md "What the cores can do" memory table (M1 Max) -->

The M3 Ultra's performance-core clusters have 16 MB of L2 shared by 6 cores; the M1 Max's have 12 MB.
<!-- src: Writeups/M1-Max-vs-M3-Ultra.md "The machines" table, "P-cluster L2" row -->

Sequential reads are fast because the hardware **prefetches**: it detects the pattern and loads lines before the
program asks. On the M3 Ultra one core reads about 72–77 GB/s from memory, and all cores together about 245–250 GB/s;
the 819 GB/s on the spec sheet is shared with the GPU and Neural Engine, and the CPU clusters' links cap at about 30% of
it.
<!-- src: Bytes/Benchmarks/RESULTS.md "The ceiling" (72 GB/s one thread; 245–250 GB/s 16–32 threads; ~72–77 GB/s per core; 30% of spec) -->
On the M1 Max one core reads 61 GB/s, two already reach 115 GB/s, and all ten reach 126 GB/s, so beyond two, more cores
add little for a pure read.
<!-- src: Bytes/Benchmarks/RESULTS.md "What the cores can do" read bandwidth paragraph -->

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
decompressor copying bytes it wrote 1–7 positions earlier) are 1.6–1.85x slower than on the M3 at identical instruction counts, and plain stores are 1.8x slower (113
against 62 GB/s). Partial-width loads that cannot forward from recent stores are a guess at the cause, not a measurement.
<!-- src: Bytes/OPTIMIZATION.md (old) §15 "What did not help" (1.6–1.85x, stores 1.8x); Bytes/Benchmarks/RESULTS.md "Not done" ("Raw SIMD stores run 62 GB/s on the M1 Max against 113 on the M3"; forwarding "consistent with ... but no probe was run"); Writeups/M1-Max-vs-M3-Ultra.md "Short copies" ("A guess ... not probed") -->

#### 1.7 Performance cores, efficiency cores, and clocks

Apple's chips have two kinds of cores. **Performance cores (P cores)** are fast and wide; **efficiency cores (E cores)**
are slower. The M3 Ultra has 24 P and 8 E cores; the M1 Max has 8 P and 2 E. Over 773 Bytes benchmarks whose instruction
counts are identical on both machines, one M1 Max core takes 1.31x as long as one M3 Ultra core; the clock ratio is 1.25
(4.05 against 3.23 GHz), so the M3 does about 4% more per clock. Work spread over many cores follows the core count
instead: the parallel codecs are 2.4x apart.
<!-- src: Writeups/M1-Max-vs-M3-Ultra.md "The short version" items 1-2 (1.31; clock 1.25; 4%; 2.4x for parallel codecs) -->

E cores change how work should be split. On the M1 Max, the two E cores added 10–13% to the parallel DEFLATE encoder,
whose workers take the next chunk from a queue. They cost the parallel decoder 20–35%, because its segments were split
evenly across lanes (parallel workers; the word also names a SIMD register's slots, [section 2.1](#21-what-simd-is)). Part III (["Static splits and efficiency cores"](#static-splits-and-efficiency-cores)) has the measurements.
<!-- src: Bytes/Benchmarks/RESULTS.md "Parallel lanes: the efficiency cores help the encoder, hurt the decoder"; AGENTS.md "Efficiency cores" lesson -->

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
all-ones and a dot product against `64, 63, …, 1`. Moving Adler-32 onto `udot` made it 2x faster on the M1 Max (29.8 to
58.0 GB/s at 1 MB, in a probe), about libdeflate's speed, and on the M3 Ultra it cut the instructions for 1 MB from
555 K to 271 K (−51%).
<!-- src: Bytes/Sources/CBytesCRC/include/CBytesCRC.h bytes_crc_udot comment; Bytes/Benchmarks/RESULTS.md "Adler-32 with UDOT: 2x faster" (29 → 55 GB/s in the table; probe 29.8 → 58.0 GB/s at 1 MB); Bytes/Benchmarks/RESULTS.md "Cleanup and improvements (2026-11-19)" (baselines speed-after → p3-spot, M3 Ultra) -->

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
MixColumns), then an XOR with the last round key. On an M1 Max the core fuses the pair, which runs 2.6 per cycle with 6
cycles of latency per pair, so a 10-round block is at best 3.9 cycles per 16 bytes. Bytes' AES-128-CTR (12 GB/s) runs
at about 90% of that bound.
<!-- src: Bytes/Benchmarks/RESULTS.md "What the cores can do" (aese+aesmc fused: 6 per pair, 2.6 pairs/cycle; 3.9 cycles per 16 bytes; measured 12 GB/s at about 90%) -->

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
cursor beats field-by-field reading: 199 K against 285 K instructions for 2,000 zip directory entries.
<!-- src: Bytes/Benchmarks/RESULTS.md 2026-11-17 "Results, t0 → final" ("Zip directory with @BinaryRecord vs field by field / ParserSpan | 285 / 461 K | 199 K"); Bytes/OPTIMIZATION.md (old) §6 "Give the record a known size" (301 K first measurement, 285 K latest, 199 K) -->

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
- **It runs 32 instructions in about 9 cycles**, 3.5 instructions per cycle, at 21.5 GB/s at 1 MB. The C kernel using
  `ld3`/`st4` directly reaches 23.1 GB/s, so the Swift version is at 93% of it.
  <!-- src: Bytes/OPTIMIZATION.md (old) §10 "Base64: 0.86 → 21.4 GB/s" ("32 instructions per 48 bytes in about 9 cycles (3.5 instructions per cycle)"; 23.1 GB/s; 93%); Bytes/Benchmarks/RESULTS-base64.md "Encoding" table (M3 Ultra, d2-final: 21.5 GB/s at 1 MB) -->
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
`GroupShuffle`, `CBytesNEON`"](#7-scanning-and-shuffles-bytelanes-bytematches-groupshuffle-cbytesneon)), and the zip signature search that uses it is 16x faster (33 µs to 2.0 µs for 64 KB).
<!-- src: Bytes/OPTIMIZATION.md (old) §8 "Searching 16 positions at once" (33 µs to 2.0 µs, 16x) -->

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
Part III (["Measuring honestly"](#12-measuring-honestly)) gives what eager fixtures cost and the other rules for the measured loop.
<!-- src: AGENTS.md "A benchmark costs a few seconds at most" bullet (process model) -->

Two practical rules: every plugin invocation costs about 25 s of build, so batch filters into one invocation, and
`--filter` must match the whole benchmark name.
<!-- src: AGENTS.md "Benchmarks" bullets "Every plugin invocation costs about 25 s", "--filter must match the whole benchmark name" -->

#### 5.3 Allocation gates

A workload that should not allocate gets a benchmark counting only `malloc` calls against a **threshold** file at 0: a
**gate** that fails if anything allocates. To find a source when one fails: `Tools/calls … --callee
'swift_allocObject|swift_slowAlloc|malloc'` statically, `Tools/runtime-count --break swift_allocObject` dynamically, and
`Tools/allocations` for responsible callers. The malloc interposer (the framework's replacement `malloc` that counts
calls) costs about 10% on large transfers and biases comparisons with libraries that allocate per call (Part III,
["Malloc counting biases comparisons with libraries"](#malloc-counting-biases-comparisons-with-libraries)), so allocation and timing benchmarks are kept separate. It also traps on thread exit, so benchmarks that start threads cannot
count mallocs; count them in single-threaded ones.
<!-- src: AGENTS.md "Allocations: package-benchmark's malloc counter with a Thresholds/ file at 0 is the gate"; "The malloc interposer costs ~10%" bullet; "package-benchmark's malloc interposer traps on thread exit"; Bytes/Benchmarks/RESULTS.md "Benchmark coverage pass (2026-11-19)" ("the timed configurations no longer count mallocs (the interposer biased comparisons with libraries that allocate per call") -->

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
  threshold fails.
  <!-- src: AGENTS.md "Tools/allocations" -->
- **`Tools/bench-table`** puts baselines side by side with change, units normalized (counts unscaled, times in µs).
  <!-- src: AGENTS.md "Tools/bench-table" -->
- **`Tools/socket-ceiling`** measures the kernel's local-socket throughput with blocking C sockets on plain threads, the
  ceiling for networking benchmarks (SocketStream's transfers reach most of it).
  <!-- src: AGENTS.md "Tools/socket-ceiling" -->

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
where nothing else changed. Neither shows up if only the edited code is benchmarked. Part III (["Measuring honestly"](#12-measuring-honestly)) returns
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
speed (113 GB/s in cache, 76 GB/s from memory); for 6-byte elements it reached 17 GB/s against 33 GB/s for `forEach`,
and for 16-byte elements 30 GB/s against 112 GB/s. <!-- src: Bytes/Benchmarks/RESULTS.md "The standard library's ConvertibleFromBytes" table (InlineArray<4,UInt8> 113/76; <6> 17/17 vs forEach 33/31; <16> 30/32 vs 112/73) --> Bytes loads its own groups as a same-size integer
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
| `forEach(IPv4Address.self)` | 114 / 78 |
| a loop of `read(IPv4Address.self)` | 113 / 78 |
| naive: four `read(Byte.self)` into an `InlineArray` | 3.7 / 3.7 |

<!-- src: Bytes/Benchmarks/RESULTS.md "Custom byte-backed types" table -->
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
rate; with all 32 cores every width but `Bits<5>`–`Bits<7>` reaches 92–96% of the CPU's ~249 GB/s memory ceiling:

| Width | One core, from memory | All 32 cores |
|---|---|---|
| raw SIMD loads (reference) | 77 GB/s | 229 GB/s |
| `Byte`, `Byte2`, `Byte4`, `Byte8` | 75–77 GB/s | 228–235 GB/s |
| `Byte3` | 19 GB/s | 237 GB/s |
| `Byte16` | 56 GB/s | 235 GB/s |
| `Nibble` | 50 GB/s | 236 GB/s |
| `Bit` | 11 GB/s (88 billion values/s) | 237 GB/s |

<!-- src: Bytes/Benchmarks/RESULTS.md "Read bandwidth: every width, 1 bit to 16 bytes" Results table and bullets -->

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
  (`Byte4` 85–88 GB/s from memory against 116 for a raw SIMD store). <!-- src: Bytes/Benchmarks/RESULTS.md "Write bandwidth" table -->
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

For the 2,000-entry zip central directory, the fixed-size style takes 199 K instructions (7.8 µs) where the same reads field
by field took 301 K (11 µs; 285 K in the latest measurement); a hand-written version over `RawSpan.load` at offsets
took 317 K instructions and 16 µs. <!-- src: Bytes/Benchmarks/RESULTS.md "Current: Bytes against the alternatives" table (11 µs/301 K; 7.8 µs/199 K; hand-written RawSpan.load offsets 16 µs/317 K) --> The
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
(177 µs): −11.5% and −15%. <!-- src: Bytes/Benchmarks/RESULTS.md "ASCII without tricks" table -->

The tests caught two bugs before shipping. Only an input that ends exactly where the digits end can reach one of them: the
two-load path was taken for fewer than 9 digits and loaded past the end of the data. <!-- src: same section; AGENTS.md Lessons "Test reads that end exactly at the data's end" -->

`read(_:asciiDigitsUpTo:)` stops before the first non-digit (HTTP's `Content-Length: 1024\r\n`). `read(_:asciiOctalDigits:)`
(1 to 21 digits, one or two 8-byte loads) replaced 74 per-digit branches in NativeAEA's cpio header parse, from 625 to
266 instructions counted statically. <!-- src: Bytes/Benchmarks/RESULTS.md "Cleanup and improvements (2026-11-19)" "Adopted in consumers"; Bytes/Sources/Bytes/ASCII.swift --> `write(_:asciiDigits:)` is the writing side.
In vectors, `ByteLanes.asciiDigits` ([section 7](#7-scanning-and-shuffles-bytelanes-bytematches-groupshuffle-cbytesneon)) counts digits in 620 KB 2.7x faster than a byte loop that LLVM auto-vectorizes (29 µs
against 78 µs). <!-- src: Bytes/Benchmarks/RESULTS.md "ASCII without tricks" table row 3 -->

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
- `bitmask`: all matching lanes, one bit each (`UInt16`).

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

Finding a 4-byte signature 64 KB back (a zip file's end-of-directory record, the worst case) takes 2.0 µs and 50 K
instructions, against 33 µs and 787 K for a `RawSpan.load` at every offset, 16x faster. The loop is about 9 instructions per 16
offsets. <!-- src: Bytes/Benchmarks/RESULTS.md "Current: Bytes against the alternatives" table row 4; "Assembly findings" ("16 candidate offsets per ~9 instructions") -->

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
The fold reaches **63 GB/s** over 32 MB (1.7x zlib's `crc32_z`, 532 µs against 888), 1.9x zlib at 1 KB, and 2.3x at 64
bytes. <!-- src: Bytes/Benchmarks/RESULTS.md "CRC32 (measured in NativeZip's benchmarks…)" table -->

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
of latency-bound, and 3.6x faster at 256 KB (14 ms to 3.9 ms for 32 MB, 8.3 GB/s). That is still 8.3x slower than
folding. <!-- src: Bytes/Benchmarks/RESULTS.md "Group operations …" table and "2026-11-12: fast portable builds" (braided CRC); Bytes/Sources/Bytes/CRC32.swift _tableUpdate doc comment -->

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
position-weighted sum is a dot product against `64, 63, …, 1`. Swift's SIMD types have no widening dot product, so, like
`pmull`, the instruction is reached through a `static inline` C wrapper (`bytes_crc_udot`), and the loop is Swift: 64-byte
blocks, four independent accumulators per sum, and 86 blocks per reduction so that no 32-bit lane overflows. <!-- src: Bytes/Sources/CBytesCRC/include/CBytesCRC.h bytes_crc_udot; Bytes/Sources/Bytes/Adler32.swift _updateDotProduct -->

On an M1 Max (one core), Adler-32 went from 29.8 to 58.0 GB/s at 1 MB, with instructions −51% and 64-byte inputs −12% in
time, reaching libdeflate's rate. The loop is 16 instructions per 64 bytes (8 `udot.4s`, 4 `add.4s`, 2 `ldp`, `subs`,
`b.ne`), bound by `udot` throughput (about 2.7 a cycle there). <!-- src: Bytes/Benchmarks/RESULTS.md "2026-11-19, M1 Max experiments: Adler-32 with UDOT" -->

On the M3 Ultra the same change cut Adler-32 of 1 MB from 555 K to 271 K instructions (−51%) and 16 K 64-byte inputs from
2,345 K to 1,755 K (−25%); the 1 MB time went from 31 to 16 µs, measured under load. <!-- src: Bytes/Benchmarks/RESULTS.md "Cleanup and improvements (2026-11-19)" ("Adler-32 (its −25 to −51% against speed-after is the M1 Max work …)"); baselines CompressionBenchmarks speed-after → p3-spot (M3 Ultra), rows "Adler-32 1 MB: Bytes" and "Adler-32 64 B (×16 K): Bytes" --> `udot` was the instruction the
M3-tuned code had left unused.

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
uninitialized, and counts as initialized only the prefix the body reports writing. The `LentBytes` and `LentMutableBytes`
types are marked `@unsafe`. The `BytesAsync` module has `async` forms, in which `await` guarantees that the work finishes. <!-- src: Bytes/Sources/Bytes/Lending.swift; Bytes/Sources/BytesAsync/Lending.swift -->

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
from running the stages separately, which is the intended result:

| Work (µs) | Pipeline | The same stages, two passes |
|---|---|---|
| deflate 1 + TLS send, JSON 1.6 KB | 9.58 | 9.34 |
| deflate 1 + TLS send, JSON 119 KB | 187 | 184 |
| deflate 1 + TLS send, Main.js | 11,000 | 11,000 |
| TLS + inflate receive, JSON 1.6 KB | 3.38 | 3.34 |
| TLS + inflate receive, Main.js | 3,297 | 3,297 |

<!-- src: Bytes/Benchmarks/RESULTS.md "Pipelines against two passes (final-1, µs)" -->

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

### 12. Codec and crypto entry points

This section is about the *shape* of the codec and crypto APIs: what you call, what you must provide, and what they promise
not to allocate. How the codecs get their speed is the subject of Part III (["Algorithms and data structures, codec by
codec"](#8-algorithms-and-data-structures-codec-by-codec)).

#### The formats

| Format | Types | Direction |
|---|---|---|
| DEFLATE, zlib, gzip | `DeflateEncoder(format:level:)`, `DeflateDecoder(format:)` (`DeflateFormat`: `.raw`, `.zlib`, `.gzip`) | both |
| Brotli | `BrotliEncoder(quality:windowBits:)`, `BrotliDecoder` | both |
| Zstandard | `ZstdDecoder`, `ZstdFrameHeader`, `XXHash64` | decode |
| LZ4 | `LZ4Decoder` (`decompressRaw`, `decompressFramed`) | decode |
| LZMA, LZMA2, `.xz` | `LZMA2Decoder` (`decompressLZMA2`, `decompressLZMA`, `decompressLZMAFile`, `decompressXZ`), `CRC64` | decode |
| bzip2 | `BZip2Decoder` | decode |
| Apple's LZFSE, LZVN, LZBITMAP, LZRAVEN | `LZFSEDecoder`/`LZFSEEncoder`, `LZVNDecoder`/`LZVNEncoder`, `LZBitmapDecoder`/`LZBitmapEncoder`, `LZRAVENDecoder` | LZFSE, LZVN, LZBITMAP both; LZRAVEN decode |
| parallel | `ParallelDeflateEncoder`, `ParallelDeflateDecoder`, `ParallelBrotliEncoder` | the parallel forms of the above |

<!-- src: Bytes/Sources/BytesCompression/*.swift public types (grep of `^public struct`); AGENTS.md Repository table (BytesCompression row) -->

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
  `ByteTransform`s (and `ResettableByteTransform`s), so they drop into a `Pipeline`. <!-- src: Bytes/Sources/BytesCompression/DeflateEncoder.swift, DeflateDecoder.swift, Transforms.swift; ZstdDecoder.swift -->
- **Parallel.** `ParallelDeflateEncoder(format:level:chunkSize:lanes:independentChunks:)` compresses `chunkSize`-byte chunks
  (256 KB by default, at most 512 KB) on `lanes` lanes at once. `lanes` is usually the number of performance cores.
  `ParallelDeflateDecoder(format:lanes:)` decodes in parallel *if the stream allows it*. It guesses block boundaries (a
  `00 00 FF FF` marker, a sync flush), decodes segments speculatively, and accepts segment *j* only if segment *j−1* ended
  exactly at its start. It cuts up to four segments per lane (`segmentsPerLane`), taken in order by whichever lane is
  free, so a slow lane (a busy or efficiency core) holds up one small segment rather than a whole share of the stream.

  Streams from `ParallelDeflateEncoder` with `independentChunks`, from pigz `-i`, and zlib streams with full flushes decode
  in parallel. Anything else decodes sequentially, and the time spent speculating is lost. `lastSegmentCount` says which
  happened. <!-- src: Bytes/Sources/BytesCompression/ParallelDeflate.swift init and doc comment; ParallelInflate.swift doc comment (rules 3–4), lastSegmentCount; Bytes/Benchmarks/RESULTS.md "Parallel lanes: the efficiency cores help the encoder, hurt the decoder" -->

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

#### Reusable state, workspaces, and what allocates

The state of every encoder and decoder is `~Copyable`. It is allocated once at initialization (tables, window, staging
buffers), and `reset()` prepares it for the next stream, keeping the allocations. After that, encoding and decoding
allocate nothing, in any of the three builds ([section 15](#15-builds-and-traits-optimized-portable-and-no-c)). <!-- src: Bytes/OPTIMIZATION.md (old version) §10 "Compression: DEFLATE and Brotli, both directions"; Bytes/Sources/BytesCompression/DeflateEncoder.swift ("Encoding allocates nothing after initialization") -->
The exceptions are documented:

- `ZstdDecoder` allocates its tables and a 160 KB literal buffer at creation. Streaming adds the window (window size +
  128 KB + 64) and a 128 KB input stash on the first frame, growing only for a larger window. Frames needing more than
  `maximumWindowSize`, 128 MB by default, are rejected before anything is allocated.
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
AES-128-GCM took 212 µs against CryptoKit's 919, because CryptoKit's per-call setup and allocation dominate below 16 KB.
For one 1 MB message, CryptoKit's hand-written assembly was faster (111 µs against 133). <!-- src: Bytes/Benchmarks/RESULTS.md "crypto in Swift, TLS 1.3, parallel sealing" table (d2-final); Bytes/OPTIMIZATION.md (old version) "AES-GCM and TLS 1.3 in Swift" (per-call setup and allocation; hand-written assembly) -->

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
second round of interleaving folded by LLVM into `st2` stores. It runs at about 9 cycles per block (3.5 instructions per
cycle). <!-- src: Bytes/Benchmarks/RESULTS-base64.md "Current" bullets ("Per block … 32 per 48-byte block, at about 9 cycles per block"); disassembly of Base64.encodeBlocks in Bytes/.build/agent-tools/BytesBase64.o -->

Encoding throughput on one core, in GB/s of input (the latest M3 Ultra run, baseline `d2-final`):

| Input | `BytesBase64` | Foundation `base64EncodedData()` | scalar table loop |
|---|---|---|---|
| 64 B | 5.04 | 0.64 | 0.86 |
| 1 KB | 19.1 | 2.54 | 0.88 |
| 1 MB | **21.5** | 3.17 | 0.85 |

<!-- src: Bytes/Benchmarks/RESULTS-base64.md "2026-11-19: the same suite on an M1 Max" "Encoding" table (M3 Ultra column, d2-final); earlier "Current (baseline final)": 4.4 / 18.1 / 21.4 -->

The encoder allocates nothing at any size. It is level with C of the same design, and 93% of a C kernel that uses `ld3` and
`st4` directly (23.1 GB/s), which Swift cannot emit for explicit vectors. The limit is the core's table-lookup rate; Part III
(["Case study: the Base64 encoder's kernel"](#case-study-the-base64-encoders-kernel)) traces each step and its effect. <!-- src: Bytes/Benchmarks/RESULTS-base64.md "The ceiling: a C kernel with ld3 and st4" (23.1; kernel table 21.8) -->

The first working version was a plain loop that computes each character with arithmetic masks (no table, so no gather) and
lets LLVM vectorize it to `ld3`…`st4`. It already ran at 9.0 GB/s, and that kernel is what other CPUs get
(`ByteLanes.isLookupVectorized` is false there). <!-- src: Bytes/Benchmarks/RESULTS-base64.md "How it got here" row 1; Bytes/Sources/BytesBase64/Base64.swift doc comment -->

**Decoding** runs at 12.8 GB/s of decoded bytes at 1 MB (17 GB/s of text; 12.9 in the latest run), at the C ceiling
(12.9 GB/s). Its kernel does five things per 64 characters:

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

Against Foundation's `Data(base64Encoded:)`, decoding is 3.9–5.3x from 1,000 bytes up; against a scalar table, 44–52x
(`d2-final`). <!-- src: Bytes/Benchmarks/RESULTS-base64.md "The Bytes codec against its references" (M3 column, inputs ≥ 1000 B); earlier "Decoding" bullets: 4.2x from 16 KB, 4.9x at 1 KB, 50x -->

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
two-thirds of the time of a conventional pointer-advancing reader (11 against 17 µs) despite running 16% more
instructions (301 K against 259 K).<!-- src: OPTIMIZATION-old.md "7." "Independent loads, not a moving pointer" -->

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
instruction is a `static inline` wrapper (`bytes_crc_udot`) and the loop is Swift. The inner loop is 16 instructions per
64 bytes and is bound by `udot` throughput:<!-- src: Bytes/Benchmarks/RESULTS.md "Adler-32 with UDOT: 2x faster"; Bytes/Sources/Bytes/Adler32.swift line 200 -->

```asm
; The inner loop of Adler32._updateDotProduct: 16 instructions per 64-byte block.
; v0 = ones; v1–v4 = the weights 64…49, 48…33, 32…17, 16…1; x16 points 32 bytes into the block.
L1:
ldp     q22, q23, [x16, #-0x20] ; bytes 0–31 of the block
add.4s  v24, v6, v5             ; prefix += (sum0 + sum1) + (sum2 + sum3): the byte sum of the
add.4s  v25, v7, v16            ;   blocks before this one, which the weighted sum needs
add.4s  v24, v24, v25           ;   (three adds to total the four accumulators,
add.4s  v21, v24, v21           ;   one into prefix)
udot.4s v16, v22, v0            ; sum0 += bytes 0–15 · ones: 4 bytes into each 32-bit lane
udot.4s v7, v23, v0             ; sum1 += bytes 16–31 · ones
ldp     q24, q25, [x16], #0x40  ; bytes 32–63; then x16 += 64
udot.4s v6, v24, v0             ; sum2
udot.4s v5, v25, v0             ; sum3
udot.4s v20, v22, v1            ; weighted0 += bytes 0–15 · (64…49)
udot.4s v19, v23, v2            ; weighted1
udot.4s v18, v24, v3            ; weighted2
udot.4s v17, v25, v4            ; weighted3
subs    x17, x17, #0x1          ; one block fewer
b.ne    L1                      ; loop while blocks remain
```
<!-- src: Bytes/Sources/Bytes/Adler32.swift _updateDotProduct, copied with CBytesCRC.h and compiled with Xcode's swiftc -O (Tools/loops --body); the same mix as Bytes/Benchmarks/RESULTS.md "Adler-32 with UDOT" ("16 instructions per 64 bytes (8 udot.4s, 4 add.4s, 2 ldp, subs, b.ne)") -->

(This is the function's source compiled on its own with `swiftc -O`; `Tools/loops` reports the same mix for the package
build.) The eight accumulators are independent chains, so the `udot`s do not wait on each other.

On an M1 Max, the result was 29.8 to 58.0 GB/s on 1 MB in a probe (the benchmark: 36 to 19 µs, against libdeflate's 18),
instructions −51%, and 64-byte inputs −12% in time; at about 2.7 `udot` per cycle, 8 of them take 3 cycles for 64 bytes.
86 blocks (5,504 bytes) go between reductions so no 32-bit lane overflows.<!-- src: Bytes/Benchmarks/RESULTS.md "Adler-32 with UDOT" -->
On the M3 Ultra the instructions fell from 555 K to 271 K for 1 MB (−51%) and from 2,345 K to 1,755 K for 16 K 64-byte
inputs (−25%), baselines `speed-after` → `p3-spot`; its times were taken only under load.<!-- src: Bytes/Benchmarks/RESULTS.md "Cleanup and improvements (2026-11-19)"; baselines CompressionBenchmarks speed-after → p3-spot (M3 Ultra), rows "Adler-32 1 MB: Bytes" and "Adler-32 64 B (×16 K): Bytes" -->

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
run (baseline `d2-final`) measured 21.5 GB/s at 1 MB, with zero allocations at every size, 32 instructions per 48 bytes in
about 9 cycles (3.5 instructions per cycle); Foundation's `base64EncodedData()` runs 3.2 GB/s there. A C kernel using `ld3`
and `st4` directly reaches 23.1 GB/s, so the Swift kernel is at 93% of it, and level with C of the same design (21.8).<!-- src: Bytes/Benchmarks/RESULTS-base64.md "How it got here" table, "Encoding (GB/s of input: M3 Ultra → M1 Max)" 1 MB row (21.5, Foundation 3.17), "Current (baseline final)" and "The ceiling" -->

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
3-byte rows bimodal (78 K and 104 K instructions): capture fixtures as locals ([section 12](#12-measuring-honestly)).<!-- src: AGENTS.md "A table that becomes a compile-time constant can make LLVM rematerialize"; Bytes/Benchmarks/RESULTS.md "Cleanup and improvements" "CRC-64's table as a literal" and table row "CRC-32 tables, 64 B"; AGENTS.md "No lazy globals inside a measured loop" -->

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

#### When not to

Zero allocation is a gate rather than a goal in itself. Parallel codecs allocate their thread pool's bookkeeping per call
(`concurrentPerform` 11 mallocs on 8 lanes and 27 on 24, a task group 34 and 98); the compression itself allocates
nothing.<!-- src: OPTIMIZATION-old.md "Compression: DEFLATE and Brotli" (thread pools allocate a few dozen small blocks per call); RESULTS.md "Parallel compression: a chunk scheduler" Allocation bullet -->
And the counting itself has a cost: allocation benchmarks are kept separate from timing ones ([section 12](#12-measuring-honestly)).<!-- src: AGENTS.md "The malloc interposer costs ~10%" and "package-benchmark's malloc interposer traps on thread exit" -->

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
The final decoder is faster than both references on every input: 1.09–1.28x Compression and 1.18–1.70x liblzma 5.8.4
(about 200 MB/s on Xcode's segments, which were the use case).<!-- src: Bytes/Benchmarks/RESULTS.md LZMA "Results" -->

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
cycles a byte for one walk, 37 for two (walking from both ends), and 22 for 16 segment lanes. The decoder reaches 160–487
MB/s against libbzip2's 49–126, 2.1–5.3x faster, with 0 mallocs.<!-- src: Bytes/Benchmarks/RESULTS-bzip2.md "What worked" first bullet, design "The walk", and "Final" table -->

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
(3.8 MB) takes 1,864 µs against libdeflate's 1,674 and zlib's 2,058 (Apple's Compression: 3,600). In order of payoff:<!-- src: OPTIMIZATION-old.md "DEFLATE: from 2x slower than zlib to faster" and Compression table (d2-final) -->

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

*Truncated input looks like data.* A bit reader's zeros past the end can decode as a valid but wrong symbol: DEFLATE's
code-length code 16 at index 0 ("repeat the previous length") threw `invalidValue` when the input ended 8 bytes into a
dynamic header. When a decoder rejects a value, check `isOverrun` and ask for more input instead. The way to find such bugs
is to record a stream's calls and replay them cut at every point.<!-- src: AGENTS.md "Truncated input looks like data" -->

**Encoder.** It follows libdeflate's levels (a 2-entry hash table at level 1, hash chains above, lazy parsing from level 5,
block splitting from statistics). Level 1's output is the same size as libdeflate's. Level 1 on Main.js runs 9,011 µs
against libdeflate's 8,057 and zlib's 17,000; level 9 runs 56,000 against 59,000 and 83,000.<!-- src: OPTIMIZATION-old.md "Compression: DEFLATE and Brotli, both directions" table and prose -->
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
x-ray, 21,000 µs against Google's 28,000; quality 5 on Main.js, 33,000 against 32,000; quality 9 on dickens, 323,000
against 522,000; decoding quality-11 streams of Main.js, 3,799 against Google's 4,104 and Apple's 3,568. Output is within
3–6% of Google's size at quality 5 (7% at 9, without context modeling).<!-- src: OPTIMIZATION-old.md Compression table and prose -->

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
Against libzstd 1.5.7 with a reused context, on one thread (instructions per byte are exact; times are ±10% under load):<!-- src: OPTIMIZATION-old.md Zstd table -->

| Silesia file, level | Bytes MB/s | libzstd MB/s | Speed-up | Bytes / libzstd instr per byte |
|---|---|---|---|---|
| dickens, 3 | 1,536 | 1,092 | 1.41x | 13.44 / 14.91 |
| mozilla, 1 | 1,707 | 1,384 | 1.23x | 8.47 / 9.39 |
| x-ray, 1 | 1,497 | 1,328 | 1.13x | 7.79 / 10.03 |
| xml, 19 | 3,916 | 3,101 | 1.26x | 4.12 / 4.49 |
<!-- src: OPTIMIZATION-old.md Zstd table (rows selected) -->

Every Silesia file at levels 1, 3, and 19 is faster, 1.12–1.45x in one call, with 7–22% fewer instructions per byte; of 32
small inputs, 31 are faster.<!-- src: OPTIMIZATION-old.md Zstd "Every Silesia file" paragraph -->
The first complete version followed libzstd's loops: a four-stream Huffman loop with sentinel bits, sequences executed one
at a time with 16- and 32-byte wild copies (copies allowed to write past their end), and the careful path out of line. It
was already 5–28% faster on large inputs but 1–24% slower on 1–4 KB ones.

What closed the rest, each a technique from an earlier section: tables in a workspace instead of `InlineArray`s ([section
6](#6-allocation-free-code)), a cold reload as a static function ([section 1](#1-keep-hot-state-in-registers)), one base pointer for the FSE states (section 1), and double-symbol
Huffman tables chosen by a measured rule. libzstd's own cost model picked double-symbol tables for x-ray's literals, where
they cost 6%; the rule used here (literals compressing below 10/16, at least 8 KB of them) gave dickens −8% and moved
nothing else by more than 0.1%. Prefetching each match's source (as libzstd does on AArch64) added 0.7% instructions and
no speed in an interleaved comparison, so it was removed.<!-- src: Bytes/Benchmarks/RESULTS.md "Zstandard decoding ... How it got there" and "Kept out" tables -->

#### LZMA, LZMA2, and `.xz`

The range-coder techniques are in [section 7](#7-branches-and-data-dependent-work). The container work: block headers with CRC-32s, the index checked against the
blocks, and checks (none, CRC-32, CRC-64) verified. CRC-64/XZ by slicing-by-8 tables ran 2.2 GB/s (already twice
liblzma's) but took 18% of xml's decode time. Folded with `pmull`, four 16-byte lanes and 64 bytes per step, it runs 24–41
GB/s, taking 2–13% of instructions off the Silesia rows.<!-- src: Bytes/Benchmarks/RESULTS.md LZMA "lzma-1 → lzma-2 is the CRC-64" paragraph -->
bzip2's CRC (CRC-32's polynomial, most significant bit first) has its own slicing-by-8 tables and reuses CRC-32's `pmull`
folding helper (`bytes_crc_fold`) with non-reflected constants on byte-reversed blocks; it costs 0.2% of the time in
profiles.<!-- src: Bytes/Benchmarks/RESULTS-bzip2.md API -->

#### LZ4

LZ4 decoding is mostly copies. The structure follows lz4's own "shortcut": a sequence of at most 14 literals and an
18-byte match, far enough from both ends, is handled as a token, one 16-byte literal move, an offset check, and two
16-byte match moves, in a 30-instruction loop with no calls. Everything else takes the general path (255-continued
lengths, careful copies). Each buffer has two limits, the block's exact end and the buffer's end less the 16-byte overrun;
their `min` is the fast-path bound, so one comparison picks the path.<!-- src: Bytes/Benchmarks/RESULTS-lz4-lzfse.md "Design"; "Code generation" -->
LZ4 runs between 11% fewer and 8% more instructions than Apple's Compression, except on x-ray's long literal runs (+20%),
at 0.72–1.03x its speed.
Compression's LZ4 decoder is the one place it is still clearly ahead (x-ray 9.9 against 7.2 GB/s).<!-- src: Bytes/Benchmarks/RESULTS-lz4-lzfse.md "Results" summary -->
Tried and reverted: 32-byte steps for long wild copies (the smaller overrun was kept), and chaining shortcut sequences
without the end-of-input check at the loop's top (+2.4–3.3%, because LLVM laid the loop out worse).<!-- src: Bytes/Benchmarks/RESULTS-lz4-lzfse.md "What worked and what didn't" -->

#### LZFSE and LZVN

LZFSE (LZ77 blocks whose literals and literal-length, match-length, distance triples are coded with FSE, a table-based
ANS; a stream may also hold LZVN blocks) follows the open reference's structure. The header is checked (counts, states,
frequency sums), value tables are 8-byte entries (`bits | extra bits | next state base | value base`), and decoding costs
12.46 instructions per byte on dickens and 4.12 on xml, at 0.90–1.16x Compression's speed and 1.2–1.4x the reference's.
LZVN matches the reference's instruction counts (±5%) at 1.1–1.35x its speed on Silesia. LZVN opcodes are classified with
a few bit tests (the undefined rows with one shift of the mask 0x2080), and a literal of 0–3 bytes is one 4-byte move that
the match then overwrites.<!-- src: Bytes/Benchmarks/RESULTS-lz4-lzfse.md "Design" and "Results"; Bytes/Sources/BytesCompression/LZFSEDecoder.swift doc comment -->

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
104–116 instructions per 16 groups; the nibble unpack is `st2.16b`. Decoding reaches 4.4–5.9 GB/s on whole streams,
level with Apple's own decoder (Apple ahead on some inputs and Bytes on others), at 3.1–3.4 instructions per byte, where
the open `libzbitmap` reference takes 31–35.<!-- src: Bytes/Benchmarks/RESULTS-lzbitmap.md "The decoder" and Benchmarks final table -->

#### bzip2

Decoding happens in five passes over one workspace:

1. Tables: a 10-bit primary Huffman lookup, with one test sending long codes, invalid codes, and the end of the block to
   the slow path.
2. Symbols: per 50-symbol group, a loop with no calls, 41 instructions a symbol, with the move-to-front list's first 16
   bytes in a register (`tbl` to pick the byte, `ext` and a select to move it).
3. Links.
4. The walk ([section 7](#7-branches-and-data-dependent-work)).
5. Run expansion, 16 bytes at a time where no 4 equal bytes end in the window.

Results on Silesia files as `bzip2 -9` writes them: 2.1–5.3x libbz2, at about half the instructions per byte (dickens
62.9 against 105.9).<!-- src: Bytes/Benchmarks/RESULTS-bzip2.md "Design, as it ended" and "Final" table -->

#### Hashes and checksums as codec parts

XXH64's one-shot form (no streaming state) took 16,384 64-byte inputs from 3.79 to 2.44 M instructions (−35.5%).<!-- src: Bytes/Benchmarks/RESULTS.md "Cleanup and improvements" XXH64 row -->
CRC-32 runs at 63 GB/s with `pmull` folding and 8.3 GB/s braided in software; Adler-32 at 58 GB/s with `udot` on the M1
Max ([section 4](#4-write-simd-by-hand-and-reach-instructions-swift-cannot-name)).<!-- src: OPTIMIZATION-old.md CRC-32; Bytes/Benchmarks/RESULTS.md Adler-32 with UDOT -->

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
  fill the pipes. AES-CTR went from 453 to 80 to 62 µs per MB on the M3 Ultra with unrolled eight-block batches, and AES-128-CTR runs at
  about 90% of the `aese`+`aesmc` bound on an M1 Max core.<!-- src: OPTIMIZATION-old.md same; Bytes/Benchmarks/RESULTS.md "crypto in Swift" (453 → 80 → 62); RESULTS.md M1 section -->
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

Sealing 1 MB as messages of various sizes (`d2-final`, p50), Bytes' AES-128-GCM against CryptoKit: 1 MB × 1, 133 µs
against 111 (7.9 GB/s; CryptoKit's hand-written assembly keeps 17% for one large message); 16 KB × 64, 124 against 154;
1 KB × 1,024, 212 against 919; 64 B × 16,384, 3,686 against 13,000 (CryptoKit's per-call setup and allocation dominate
below 16 KB).<!-- src: OPTIMIZATION-old.md "AES-GCM and TLS 1.3 in Swift" table (d2-final) -->

#### SHA-2, HMAC, PBKDF2, HKDF

- **SHA-512/384 on the SHA-512 instructions** (`sha512h`/`sha512h2` for two rounds, `sha512su0`/`sha512su1` for two
  schedule words; ARMv8.2): 1 MB went from 38 M to 4.01 M instructions (−89%; CryptoKit's 4.34 M) and from 1.60 ms to
  0.64 ms (CryptoKit 0.64; times taken under load, indicative), at 489 instructions a block with no calls. The first
  version's state in captured variables is [section 1](#1-keep-hot-state-in-registers)'s SHA-512 example.<!-- src: Bytes/Benchmarks/RESULTS.md "Crypto cleanup" SHA-512 bullet -->
  The portable block function was a rolled 80-round loop with a `round >= 16` test per round; written as five groups of
  sixteen rounds with the schedule in sixteen locals, it is about 2,570 instructions a block against about 4,600.<!-- src: same -->
- **SHA-256** on `sha256h`, `sha256h2`, `sha256su0`, `sha256su1`: 400 µs per MB against CryptoKit's 337, in 6% more
  instructions; where the rest of the time goes was not found. Round constants as vector literals took SHA-256 from 5.5
  to 2.07 M instructions.<!-- src: OPTIMIZATION-old.md "AES-GCM and TLS 1.3" primitives table and text; Bytes/Benchmarks/RESULTS.md "crypto in Swift" -->
- **PBKDF2**: each iteration starts from a copy of the keyed HMAC, whose inner and outer hash states already hold the
  key's pads, so an iteration is two block compressions: 1.4 M instructions for 1,000 iterations against CommonCrypto's
  2.8 M (2.91x faster).<!-- src: OPTIMIZATION-old.md same -->
- **HKDF's expander** keys the HMAC once; TLS traffic keys expand the key and IV from one expander (two compressions saved
  per direction).<!-- src: Bytes/Benchmarks/RESULTS.md "Crypto cleanup" HKDF bullet -->

#### Elliptic curves: P-256 and P-384

ECDSA verification and ECDH are in Swift, with no C and no assembly. Against CryptoKit (corecrypto): ECDSA verify P-256 54
µs against 91 (812 K instructions against 1,757 K, 0 mallocs against 3), P-384 206 against 227, ECDH P-256 52 against 89,
HPKE open 61 against 105.<!-- src: Bytes/Benchmarks/RESULTS-ecc.md "Results" -->
The optimization log, in P-256 verify instructions:

- Complete projective formulas: 1,422 K.
- Jacobian coordinates with a width-7 NAF (non-adjacent form: a signed-digit representation with fewer additions) of u1
  over a static table of G's odd multiples, and a width-4 NAF of u2: 890 K (−37%).
- Inverting s by binary extended Euclid (variable time, because s is public): 825 K (−8%).
- Final: 812 K.

What the work taught:<!-- src: Bytes/Benchmarks/RESULTS-ecc.md "Optimization log" -->

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

- **RSA PKCS #1 v1.5 verification** (1024–4096-bit keys; variable time, only public values): 13 µs against Security's 19
  at 2048 bits (294 K instructions against 338 K, 0 mallocs against 14), 42 against 65 at 4096. Parsing a key includes
  computing R² mod n for Montgomery multiplication. Against the first version, verification was −24% in instructions and
  −38% in time, and key parsing −79%.<!-- src: Bytes/Benchmarks/RESULTS-rsa.md "Results" -->
- **X.509 parsing**: 8.1 K instructions (0.40 µs, 0 mallocs) for a 583-byte certificate against Security's 36 K (1.76 µs,
  11 mallocs). The first version took 14 K: it walked the whole structure before parsing, and checked each extension for
  duplicates by parsing every earlier extension again (quadratic). Walking only what the parse does not read, and keeping
  the first 16 extension identifiers' ranges on the stack, gave −42%. Validation passes add up.<!-- src: Bytes/Benchmarks/RESULTS-scrypt-x509.md "Parsing, per certificate" and Lessons -->
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

- It picks split points just after a `00 00 FF FF`, spread evenly (a vectorized scan from each target), up to four
  segments per lane, so a lane that runs slow holds up one small segment instead of a whole share.
- The lanes take segments in order and decode each from nothing.
- Segment *j* is accepted only if segment *j* − 1 ended exactly at its start, between blocks, and nothing threw; otherwise
  the whole stream is decoded sequentially.
- gzip's CRC-32 and zlib's Adler-32 are computed per segment and combined.

Streams from the parallel encoder (with independent chunks), pigz `-i`, and zlib streams with full flushes decode in
parallel; others decode sequentially.<!-- src: Bytes/Sources/BytesCompression/ParallelInflate.swift doc comment -->
Measured with one segment per lane, parallel inflate of such a stream was 5–10x one core at 24 lanes, and 8 lanes were
5.6x faster than sequential decoding on both an M3 Ultra and an M1 Max. Up to four segments per lane cost 1.4–1.6% more
instructions (more fixed costs, but the lanes finish together); its time gain, 50–80% under load, has not yet been
re-measured on an idle machine.<!-- src: Bytes/Benchmarks/RESULTS.md "Parallel compression" Speed-up bullet and "Cleanup and improvements (2026-11-19)" Parallel inflate row; Writeups/M1-Max-vs-M3-Ultra.md "Parallel scaling"; Bytes/Sources/BytesCompression/ParallelInflate.swift segmentsPerLane -->

#### Static splits and efficiency cores

Apple silicon mixes performance (P) and efficiency (E) cores. Whether more lanes than P cores helps depends on how the work
is handed out. Measured on an M1 Max (8 P and 2 E cores), with 256 KB chunks and 1–16 lanes:<!-- src: Bytes/Benchmarks/RESULTS.md "Parallel lanes: the efficiency cores help the encoder, hurt the decoder" -->

- The **encoder** scales almost linearly to 8 lanes (7.3x on mozilla level 6), and the two E cores add another 10–13%
  (70.1 to 63.3 ms). Workers take the next chunk from a queue, so a slow core costs nothing at the end.
- The **decoder**, as measured, split its segments evenly across the lanes, so 9 or 10 lanes put a segment on an E core
  and the call waited for it: 9 lanes were 20% slower on dickens and 35% slower on mozilla level 1 than 8. 16 lanes,
  which split the work finer, were 4–12% faster than 8.

So "lanes = performance cores" suits statically divided work; a queue can use every core. The decoder's current design
moves toward the queue: it cuts up to four segments per lane, and lanes take the next segment in order, so a slow core
holds up one small segment (not re-measured on the M1 Max). The M3 Ultra has 24 P and 8 E cores; the rule was not measured
there.<!-- src: Bytes/Benchmarks/RESULTS.md same; Writeups/M1-Max-vs-M3-Ultra.md "M1 Max-specific optimizations explored"; Bytes/Sources/BytesCompression/ParallelInflate.swift doc comment -->

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
| AES-128-GCM | 5.7 GB/s | 20.3 GB/s (3.6x) | 32.7 GB/s (5.8x) |
| ChaCha20-Poly1305 | 2.0 GB/s | 7.6 GB/s (3.8x) | 13.9 GB/s (6.9x) |
<!-- src: OPTIMIZATION-old.md same table; Bytes/Benchmarks/RESULTS.md "crypto in Swift" -->

Over loopback (SocketStream, one connection, 16 KB payloads), four sealing lanes took ChaCha20-Poly1305 from 1.35–1.54 to
1.77–1.87 GB/s and AES-128-GCM from 2.79–3.16 to 3.63–3.80, against 4.6–5.8 unencrypted. Eight lanes added nothing: the
receiver opens records one at a time, which makes it the limit. Opening in parallel is harder: a record's plaintext length
(and so its place in the output) is known only after it is decrypted, since the content type and padding are at its end.<!-- src: OPTIMIZATION-old.md same; AGENTS.md "Records are independent once their sequence numbers are fixed" -->
In general, parallelism helps only the stage that is the bottleneck, and the next stage becomes the limit.

#### Other parallelism

scrypt's `p` ROMix calls run on `concurrentPerform` lanes with a table per lane (p = 4, N = 2¹⁴: 70 ms on one lane, 17 ms
on four, 4.1x, with the same 775 M instructions).<!-- src: Bytes/Benchmarks/RESULTS-scrypt-x509.md "scrypt" and "Against OpenSSL" -->
Many-core memory-bound reads and many-archive extraction are in sections [11](#11-techniques-in-the-projects-built-on-bytes) and [12](#12-measuring-honestly).

#### When not to

Parallelism has a floor per call (pool bookkeeping allocations, waking threads whose cores are at low clocks), so small
inputs stay sequential. Parallel inflate falls back to sequential decoding when its speculation fails. And file-system work
([section 11](#11-techniques-in-the-projects-built-on-bytes)) stops scaling at a handful of threads, because the kernel, not the CPU, is the limit.<!-- src: Bytes/Benchmarks/RESULTS.md "Parallel compression"; NativeZipArchive/Benchmarks/RESULTS.md step15 -->

### 11. Techniques in the projects built on Bytes

The libraries above are used by four projects whose job is not a codec but a *workload*: packets, archives, extraction.
Each found its own limits. (SocketStream, the fifth, is about concurrency and sockets: Part IV (["SocketStream: what the PR
toolchain's I/O interfaces made possible"](#2-socketstream-what-the-pr-toolchains-io-interfaces-made-possible)).)

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

**Deflate64** is the same `Inflater` in a second mode (a 64 KB window, length symbol 285 with 16 extra bits, distance codes
30 and 31), with its own `@inline(never)` copy of the symbol loop, which refills between the length and the distance, so
DEFLATE's fast loop is untouched.<!-- src: NativeZipArchive/Benchmarks/RESULTS.md step15 "Formats" Deflate64 bullet -->

**Streamed decryption.** Encrypted entries decrypt in 256 KB pieces into a staging buffer as the decompressor takes input
(except Deflate64 and LZMA, whose decoders read their whole input and still decrypt into one buffer). AES checks the whole
payload's MAC before any output (WinZip's specification requires it). The staging buffer and decoder are made on the first
encrypted entry ([section 6](#6-allocation-free-code)).<!-- src: NativeZipArchive/Benchmarks/RESULTS.md step16 "Streamed decryption"; OPTIMIZATION-old.md "AES-GCM and TLS 1.3 in Swift" last paragraph -->

#### NativeAEA: a decode pipeline against a file system

`NativeAEA` reads Apple Encrypted Archives (`.aea`), Apple Archives (`.aar`), and Xcode's `.xip`, and extracts them. The
pipeline (ARCHITECTURE.md) has five stages:<!-- src: NativeAEA/RESULTS.md "The pipeline"; NativeAEA/ARCHITECTURE.md "The shape of the pipeline" -->

1. **Open**: the signature, certificate chain, and header MACs are checked, giving a table of segments with their
   checksums, MACs, and keys.
2. **Decode**: one task per core takes a free buffer from a fixed pool, then the next segment (in *that order*). It reads
   the segment, checks its MAC, decrypts, decodes (LZMA2, LZFSE, LZBITMAP, LZ4, LZRAVEN, zlib), checks its checksum (SHA-256
   or Murmur64, whichever the archive names), and publishes it.
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

### 12. Measuring honestly

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
Where the chips differ beyond the clock: raw SIMD stores run at 113 GB/s against 62 on one core (1.81x; reads 78 against
61); back-references at distances 1–7 are 1.6–1.85x slower at identical instructions (a guess: partial-width loads that
cannot forward from recent stores; not probed); and latency-bound code keeps up (hashes 1.14–1.21, hardware CRC-32
1.08–1.15, small-input Zstandard 0.97–1.04).<!-- src: Writeups/M1-Max-vs-M3-Ultra.md "Where the two chips differ beyond the clock" -->

**Many cores: the core count is the difference.** With the lane count following the chip (24 lanes against 8), the
parallel codecs are 2.4x apart (geometric mean over 60 pairs), and memory-bound reads on all cores 1.9x (bandwidth ratio
2.05). File-system work shows what the extra cores are for: extracting a 2,000-file archive with the current code is fastest with 4 workers on
the M3 Ultra (64 ms) and with 8 on the M1 Max (81 ms; 4 workers: 106 ms). A worker count found on one chip has a different knee on the
other: derive worker counts from the machine.<!-- src: OPTIMIZATION-old.md "15." paragraph "Many cores"; Writeups/M1-Max-vs-M3-Ultra.md "File-system work" -->

**What one M1 Max core measured** (probes; cycles scaled from a calibration that read 2.82 GHz, ±15%):<!-- src: Writeups/M1-Max-vs-M3-Ultra.md "What the M1 Max can do" -->

| Instruction | Latency (cycles) | Per cycle |
|---|---|---|
| `add`, `eor`, `eor3`, `zip`, `uzp`, `ext`, `tbl` with 1–2 registers | 2 | 4 |
| `udot`, `pmull`, `aese`, `mul`, `usra` | 3 | 2.7 |
| `tbl` with 3 / 4 registers | 4 | 1.9 / 1.3 |
| `tbx` with 4 registers | 8 | 1.0 |
| `sha256h`, `sha512h` | 5, 3 | 0.5 |
<!-- src: Writeups/M1-Max-vs-M3-Ultra.md same table (rows selected) -->

Memory: L1 3 cycles, L2 17–18 cycles, system-level cache 35–52 ns, DRAM about 122 ns; one core reads 61 GB/s, two 115
GB/s, and all ten only 126 GB/s.<!-- src: Writeups/M1-Max-vs-M3-Ultra.md same section; Bytes/Benchmarks/RESULTS.md "What the cores can do" read bandwidth -->
Read as cost per lookup, this core's `tbl` with one or two table registers takes one vector slot, with four about three,
and a four-register `tbx` four, with 8 cycles of latency ([section 4](#4-write-simd-by-hand-and-reach-instructions-swift-cannot-name)).<!-- src: Bytes/Benchmarks/RESULTS.md "What the cores can do" paragraph after the table; AGENTS.md "Measure a core's instructions rather than assuming" -->

**What changed in the code for the M1 Max.** One instruction nobody had used (`udot`; [section 4](#4-write-simd-by-hand-and-reach-instructions-swift-cannot-name): Adler-32 from 29.8 to
58.0 GB/s) and the efficiency cores ([section 10](#10-parallelism)). **What did not help:** software prefetch on CRC-32 (the fold already runs
at the memory rate; a distance of 8 KB lost 7–50%), interleaving two halves, and buffer alignment; the AES kernels are
already at about 90% of the `aese` bound. Candidates not tried: store-heavy and short-copy code, and Base64's decoder
lookups (tuned around the M3's micro-op counts for `tbl` and `tbx`).<!-- src: Writeups/M1-Max-vs-M3-Ultra.md "M1 Max-specific optimizations explored"; OPTIMIZATION-old.md "15." "What did not help" -->

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
worth avoiding. NativeAEA's primitives use `UnsafeContinuation` in release builds (inside a `@safe` wrapper,
`Continuation`) and `CheckedContinuation` in debug builds, where the check is worth the allocation.
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
`Synchronization`'s `Mutex` (SE-0433) and `Atomic` (SE-0410) hold the state; `AtomicCounter`, a class around `Atomic`,
exists so that arrays can hold one reference count per buffer.
<!-- src: NativeAEA/ARCHITECTURE.md §9 primitive table (Mutex, Atomic<Int>, AtomicCounter); SE-0433 mutex, SE-0410 atomics -->

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

The CLI is the one place priority is set: its async `main` task is at priority 21, so `run()` starts one child at
`.userInitiated`, the quality of service the old threads had.
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
`withThrowingDiscardingTaskGroup`, each with its own decoder, and a lock-free `WorkQueue` hands out indexes with an atomic
increment (`Atomic<Int>`, relaxed ordering). Items are sorted largest first (longest-processing-time scheduling), so
a big entry does not start last and leave the other workers idle. With one worker or one item, everything runs inline,
in order, with no task overhead. If the body throws, the group cancels the others, which stop claiming; items already
started finish. Cancelling the caller does the same.
<!-- src: NativeZipArchive/Sources/NativeZip/Concurrency.swift `WorkQueue` and `forEachConcurrently` doc comment -->
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
child task while chunk N+1 inflates, for deflated entries of 4 MB or more.
<!-- src: NativeZipArchive/Benchmarks/RESULTS.md "step3" bullet on inflatePipelined (the function is now `decodePipelined`: NativeZipArchive/Sources/NativeZip/ZipDecoder.swift) -->
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
| **A sync method and an `async` overload of one name taking a `throws(E)` closure are ambiguous** from async code | Does not compile | Different names (`fill`, `receive`) |
| **`do { } catch` around a typed-throws call boxes the error** (`swift_allocError`) | An allocation per thrown error | `do throws(E) { }` |
| **A span of a global `let` from another file** is rejected ("lifetime-dependent value escapes its scope") when files compile separately, as in debug builds; accepted with whole-module optimization | Debug builds fail, release builds pass | Bind the global to a local first |
| **Spans cannot be captured through two closures**, nor borrowed from a property while another property is mutated in a closure | Does not compile | Pass both as parameters to a `static` function |
| **`package-benchmark`'s malloc interposer traps on thread exit** (`count_free` calling `calloc` in `_pthread_tsd_cleanup`) | Benchmarks that start threads cannot count mallocs | Count mallocs in single-threaded benchmarks |
| **The malloc interposer costs about 10% on large transfers** | Transfer bandwidth skewed | Keep allocation and timing benchmarks separate |
| **Shared mutable state the walker reads to decide reference handoffs** (a writer cleared a large file's fork type) | A buffer reference leaked, and `DispatchSemaphore` trapped at deinit | Keep the decider's own copy |
<!-- src: SocketStream/RESULTS.md "Notes on swift-platform-executors" and "Receiver fix" (close on error paths; the trap text is quoted there); AGENTS.md Lessons (rethrows bug #90291 report 25; "do throws(E)"; sync/async overload ambiguity "hence fill and receive"; span-of-global; two-closure spans; malloc interposer thread-exit trap; "Shared mutable state the walker reads to decide reference handoffs is a leak"); SocketStream/RESULTS.md "The transfers themselves aren't measured with the malloc interposer ... cost large-packet transfers about 10%" -->

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
- **Bit buffer (`BitBuffer`)**: up to 64 bits of input held in one integer and refilled 8 bytes at a time, for entropy
  decoders. It never throws while decoding: past the end it fills with zeros, and the error surfaces at `finish()` or
  through `isOverrun`.
- **Bit-addressable cursor**: a cursor in the `BitAddressable` mode (`BytesReader`, `BytesWriter`) that reads and writes
  fields of any bit width at any bit position, carrying a bit offset (and, in the writer, the partly written byte).
- **Bit-field extract and insert (`ubfx`, `bfi`)**: take a run of bits out of a register, or put one into a register,
  in one instruction.
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
- **Dependency chain**: instructions that each need the previous one's result, so they cannot overlap; it runs at one
  step's latency per link however wide the CPU is.
- **Descriptor (`BitFlag`, `BitField`, `BitPattern`)**: a bit-level field declared once and used by name: one bit as a
  `Bool`, adjacent bits as a value, or fixed bits checked at once (`0`, `1`, `?` free, `_` between groups).
- **Discarded cycles**: the share of cycles whose work was thrown away after mispredictions, as `Tools/counters`'
  `bottlenecks` mode reports it beside useful, front-end, and back-end cycles.
- **Discarding task group**: a task group made with `withDiscardingTaskGroup` (SE-0381) for child tasks whose results are
  not collected.
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
- **Independent chains**: separate dependency chains interleaved in one loop so their latencies overlap: eight ChaCha20
  blocks at once in place of four, eight CRC fold accumulators, four `udot` accumulators per sum.
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
- **Lending (`LentBytes`)**: handing a span's memory to other threads or child tasks as a `Sendable` pointer
  (`withLentBytes`, `withLentFreeCapacity`), through scoped functions whose rule is that the work using it must finish
  before the function returns; the async forms guarantee that with `await`.
- **Lifetime annotation (`@_lifetime`)**: the declaration of what a returned non-escapable value depends on, which lets a
  function return a span. `@_lifetime(copy data)`: the result inherits the lifetime of `data`, itself non-escapable (a
  span parameter), so it lives as long as the memory `data` views. `@_lifetime(borrow x)`: the result borrows `x` itself
  (an array, a buffer that owns its memory) and is valid only while `x` is. "Copy" refers to the dependence, never to
  bytes.
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
- **Pipeline stage (`ByteTransform`)**: a transform from input spans into an output span that reports what it consumed and
  produced, as zlib's `deflate` and `inflate` do; stages compose with `then` into a `Pipeline` that specializes to one
  function.
- **Pipeline, superscalar**: overlapping instruction stages; starting several instructions per cycle.
- **Placement**: how SocketStream assigns executors: `threadPerTask` (a single-thread `PThreadTaskExecutor` for every
  sender and receiver) or `sharedPool` (one pool of threads for every task).
- **Prefetching**: loading cache lines before they are asked for, when a pattern is detected.
- **Process model (package-benchmark)**: one process to list the benchmarks, then one per benchmark, each running the
  whole registration closure.
- **`PThreadTaskExecutor`**: swift-platform-executors' task executor that owns its threads, with an I/O backend; SocketStream
  runs its senders and receivers on it.
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
- **Slack (`BitWriter.slack`)**: the 8 bytes of room past the last whole byte that a bit writer's flush needs, because it
  stores all 8 bytes of its register and advances only past the whole ones.
- **Span**: a view of contiguous memory, conceptually a pointer and a count, with the compiler's promise that the memory
  stays valid while the view is used (`Span`, `RawSpan`, `MutableSpan`, `MutableRawSpan`).
- **Specialization**: a copy of a generic function for concrete types, removing the metadata calls.
- **Speculative parallel decoding**: `ParallelDeflateDecoder` splits a DEFLATE stream after sync-flush markers, decodes
  the segments at once, and accepts segment *j* only if segment *j* − 1 ended exactly at its start; otherwise the stream
  is decoded sequentially.
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
- **Strict memory safety**: the Swift mode requiring `unsafe` on every use of an unsafe construct.
- **Structured concurrency**: child tasks that cannot outlive the scope that created them (SE-0304: task groups, `async
  let`); the runtime knows the tree and propagates cancellation and priority escalation down it.
- **Suspension point**: an `await` where the task may give up its thread; an `await` of something already ready does not
  suspend and costs only a call.
- **SWAR (SIMD within a register)**: ordinary 64-bit integer operations on eight packed byte fields at once, as in reading
  up to 8 ASCII digits with one load, one check, and three multiplies.
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
- **Thunk**: a compiler-generated wrapper function; merged closures called through one kept a writer in memory.
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
- **Worker pool**: a fixed number of child tasks that each take the next item from a shared queue
  (NativeZipArchive's `forEachConcurrently`).
- **Workspace (caller-supplied scratch)**: scratch memory an algorithm needs, allocated once by the codec or passed in by
  the caller (`Scrypt.deriveKey(…scratch:…)`), so the operation itself allocates nothing.
- **Wrapping arithmetic (`&+`, `&-`, `&*`)**: Swift's operators that wrap on overflow instead of trapping; one bare
  instruction each.
- **`xtn`, `shrn`**: narrowing: keep the low half of each lane, optionally after a right shift.
- **`zip1`, `zip2`, `uzp1`, `uzp2`**: interleave two vectors lane by lane; take the even or odd lanes.

<!-- src: definitions adapted from Bytes/OPTIMIZATION.md (old) §13 Glossary and the sections of this document where each term is defined -->
