# Fast Swift for binary data: what a week of Bytes taught us

Bytes is a Swift library for parsing and writing binary formats: reading and writing cursors
(`BytesReader`, `BytesWriter`) over borrowed memory, with fields from 1 bit to 16 bytes. This week it went
from a first version to one that reads at memory speed, and three projects were built on it: an MQTT 5
codec, a DEFLATE decoder that beats zlib, and a Base64 encoder and decoder at 93% and 99% of hand-written
C. It builds three ways (with NEON, with portable C fallbacks, and in Swift alone), and the portable
builds average within about 2% of the NEON one.

This document covers the design and optimization techniques that got it there, with before-and-after code
and the measurements behind each. It's for experienced Swift programmers who know CPUs only at the
surface: section 1 covers the hardware basics, terms are glossed where they first appear, and the
[glossary](#13-glossary) collects them. Full records are in
[Benchmarks/RESULTS.md](Benchmarks/RESULTS.md) and each project's RESULTS.md.

All numbers are from one machine: an Apple M3 Ultra (24 performance and 8 efficiency cores), macOS 27.2,
Swift 6.4.2 (Xcode 27.3), release builds, medians from the [ordo-one benchmark
package](https://github.com/ordo-one/benchmark). "GB/s" is bytes processed per second. "x% faster" means
x% less time unless it says "throughput".

## Contents

1. [How the CPU sees your loop](#1-how-the-cpu-sees-your-loop)
2. [How to measure](#2-how-to-measure)
3. [The cursor: a design that lets the compiler help](#3-the-cursor-a-design-that-lets-the-compiler-help)
4. [The types, and how each keeps code fast](#4-the-types-and-how-each-keeps-code-fast)
5. [Keep the cursor in registers](#5-keep-the-cursor-in-registers)
6. [Make bounds checks disappear](#6-make-bounds-checks-disappear)
7. [Let LLVM vectorize your loops](#7-let-llvm-vectorize-your-loops)
8. [Write SIMD yourself with `SIMD16`](#8-write-simd-yourself-with-simd16)
9. [Reach instructions Swift can't express](#9-reach-instructions-swift-cant-express)
10. [Case studies: Base64, CRC-32, DEFLATE, three builds](#10-case-studies)
11. [Smaller lessons](#11-smaller-lessons)
12. [Limitations and bugs found in Swift and LLVM](#12-limitations-and-bugs-found-in-swift-and-llvm)
13. [Glossary](#13-glossary)
14. [Further reading](#14-further-reading)

## 1. How the CPU sees your loop

A few facts explain almost every result below.

- **Instructions are cheap; waiting is expensive.** An M3 performance core can start about 8 instructions
  per cycle (a cycle is ~0.25 ns at ~4 GHz), but only if they don't wait on each other. A *dependency
  chain*, where each instruction needs the previous one's result, is limited by its links' *latency* (how
  long an instruction takes to produce its result), however wide the core is. A loop's longest chain is
  its *critical path*. So two loops with the same instruction count can differ 2x in time.
- **Registers are free; memory costs.** A core has 31 general-purpose and 32 128-bit vector registers. A
  value in a register costs nothing to access; a value in memory is loaded and stored around every use. A
  value must be in memory whenever its *address* is needed: passing it `inout`, or calling a non-inlined
  `mutating` method, passes a pointer to it, so it lives in memory for the whole function, even on paths
  that never make the call. Moving a register's value to the stack is a *spill*.
- **Memory arrives in cache lines.** The CPU moves memory in 128-byte blocks (*cache lines* on Apple
  silicon; 64 bytes on most x86 chips) through small, fast caches: L1 (128 KB of data per core, a few
  cycles away), L2 (16 MB shared by a cluster of 6 cores), then main memory (~100 ns away). Sequential
  reads are fast because the hardware *prefetches* lines before you ask. Here, one core can read about
  72–77 GB/s from memory; all cores together, about 245–250 GB/s.
- **SIMD does 16 things at once.** A 128-bit vector register holds 16 bytes, or 8 16-bit, 4 32-bit, or 2
  64-bit values; each slot is a *lane*. One SIMD (Single Instruction, Multiple Data) instruction operates
  on every lane at once: one `add` adds 16 pairs of bytes. Arm's SIMD instruction set is *NEON*. Swift's
  `SIMD16<UInt8>` is one such register.
- **A vector instruction does the same thing in every lane, in lockstep.** Anything that could differ per
  lane has no single vector instruction: which way a branch goes, whether to leave the loop, which address
  to load from, what an opaque function call does. This rule explains every vectorizer limit in section 7.
- **The compiler vectorizes for you, sometimes.** LLVM, Swift's optimizer, rewrites simple loops to
  process 16 or 64 bytes per iteration with SIMD instructions (*auto-vectorization*). When it can't, the
  loop runs one element at a time (*scalar* code), 3–10x slower, and nothing tells you.
- **Branches are guesses.** The CPU predicts which way each branch goes and runs ahead; a wrong guess
  throws away ~15 cycles of work. Predictable branches, like a bounds check that always passes, are nearly
  free.

## 2. How to measure

Four habits replaced guessing with knowing:

1. **Benchmark everything, including allocations.** Every workload that shouldn't allocate also has an
   `Allocations:<name>` benchmark that counts only `malloc` calls against a static threshold: zero for all
   but one, a compiler-caused allocation (section 12), which is how that compiler bug was found.
2. **Count instructions, not just time.** Instruction counts are deterministic; times vary ±10% between
   runs. A change that saves 20% of instructions but no time shows the loop is bound by something else
   (latency, memory, one busy execution unit), which is also worth knowing.
3. **Read the assembly.** The machine code answers "did it vectorize?" `Tools/loops` in this repository
   finds a compiled function's loops and labels each `vector128` (uses 128-bit vectors), `scalar`, or
   `+lane-moves` (moves values into vector lanes one at a time: a vector built the slow way).
4. **Ask the CPU.** Performance counters (Instruments' CPU Counters, or `Tools/counters`) count SIMD
   instructions executed, cache misses, and cycles where nothing could start (*stalls*). A scalar Base64
   build executes zero SIMD instructions; the vectorized one, 18.5 billion per run.

> **Enough Arm64 assembly for this document.** `x0`–`x30` are 64-bit integer registers (`w0` is
> the low 32 bits of `x0`); `v0`–`v31` (or `q0`) are 128-bit vector registers. `ldr`/`str` load and store
> one value, `ldp`/`stp` a pair. A suffix gives the lanes: `add.16b` adds 16 byte lanes, `rev32.16b`
> reverses the bytes within each 32-bit lane (a byte swap). `[x17, #16]` is the address x17 + 16.
> Others used here: `tbl` (table lookup, section 9), `zip1`/`zip2` (interleave two vectors),
> `ld3`/`st4` (load and split / interleave and store several vectors), `cmeq` (compare lanes for equality),
> `umaxv` (largest lane: a *reduction* across the vector).

One harness lesson recurred: **measure the code, not the benchmark.** The first field-parsing benchmark
folded each field into `checksum = checksum * 31 + value`: 13 dependent multiplies per record, each
waiting about 3 cycles for the last. That took longer than the parsing, so all four parsers measured
19 µs. A plain sum revealed the real differences (10 to 17 µs).

Three more came later:

- **Only the work goes inside the measured loop.** Early benchmarks read a clock, looked up fixtures in a
  dictionary, or checked results inside package-benchmark's `scaledIterations` loop. Now fixtures (inputs
  and output buffers) are made before a benchmark is registered, results are checked once beforehand, and
  bytes per second come from the framework's own throughput metric (iterations per second, measured
  outside the loop) times the bytes per iteration.
- **Compare times only within one interleaved run.** Single-core times drift 5–10% between runs minutes
  apart, unchanged code included, so a timing claim compares the old code (extracted with `git archive`)
  and the new in alternating runs, round by round. Memory-bound runs were worse: they switched between two
  levels about 20% apart (about 2,250 and 2,760 µs), unchanged code and `memset` included. A regression
  that showed in both rounds of one comparison vanished in three more alternating runs. Instruction counts
  don't drift; use them to judge, and times to confirm.
- **Measure every build you ship.** Bytes builds three ways (NEON, portable C fallbacks, Swift only;
  section 10). The portable fallback had never been benchmarked; when it was, it ran up to 113x slower
  than the NEON build (section 9).

## 3. The cursor: a design that lets the compiler help

```swift
var reader = BytesReader(data.span)
try reader.expect(0x50_4B_03_04 as Byte4)                  // zip signature (4 bytes), or throws
let version = try reader.read(Byte2.self, .littleEndian)   // 2 bytes, interpreted as a UInt16
let kind = try reader.read(Bits<3>.self)                   // 3 bits
let name = try reader.read(byteCount: 12)                  // a RawSpan of the same memory: no copy
```

The design decisions that matter for speed:

- **`~Copyable` and `~Escapable` (SE-0390, SE-0446).** The cursor can't be copied or outlive the memory
  it reads, so it can hand out `RawSpan`s of that memory without copying, reference counting, or
  allocating. Parsed values are *views* of the input: MQTT's PUBLISH packet holds its topic as a
  `UTF8Span` and its payload as a `RawSpan`. Views parse 5.5x faster than conventional parsing into
  `[UInt8]` and `String` on one core, and 11x on 32 cores, where the conventional code's allocations
  contend for the allocator.
- **A small struct of plain values.** A `RawSpan` (pointer and count), a byte offset, a bit offset, and a
  bit order: 40 bytes that fit in registers. No class, no buffer, no existential.
- **Typed throws (`throws(BytesError)`).** No `any Error` boxing on the error path.
- **All-or-nothing reads.** A read that throws consumes nothing, so a streaming parser can retry when more
  data arrives.
- **Separate reader and writer types.** A combined type would need exclusive access to the memory
  (`MutableRawSpan`), and anything borrowed from an exclusive owner keeps the owner borrowed, so a span it
  handed out would lock the cursor: reading a field after taking a span would be an "overlapping access"
  error. Nor would the loads be faster.
- **Widths as types.** Each field width is its own type, so every read compiles to code specialized for
  its width (section 4).

## 4. The types, and how each keeps code fast

Each type exists to give the compiler something it can turn into a few instructions.

- **`BytesReader`**: everything in section 3. Reads are `@inlinable`, so the compiler sees the cursor's
  fields in the caller and keeps them in registers (section 5), and generic over the width type.
- **`BytesWriter`**: the mirror image. It writes into a `MutableRawSpan` or into an `OutputSpan`'s
  uninitialized capacity (`output.withBytesWriter { … }`), so new buffers aren't zero-filled first and
  exactly what's written is committed. Odd widths use two overlapping stores within the bytes being
  written. A partly written byte stays in a register instead of being reloaded before each bit write.
- **`Bits<let width: Int>`** (1–8 bits; aliases `Bit`, `Crumb` (2), `Nibble` (4), `Byte` (8)): one `UInt8`.
  The width is an integer generic parameter (SE-0452), a compile-time constant, so masks and shifts fold
  into immediates and the range checks of `value[bit: 3]` fold away. Setting a nibble is an `and`
  and an `orr`; toggling a bit is one `eor`.
- **`Byte2` … `Byte16`** (`ByteGroup`): N bytes as they appear in memory, stored in the narrowest unsigned
  integer that holds them (`Byte3` in a `UInt32`, `Byte9`–`Byte16` in a `UInt128`). On a little-endian CPU
  that integer is just the loaded bytes, so a read is one load (two overlapping loads for odd widths).
  `.bigEndian` is a byte swap and a shift: two instructions. For `Byte9`–`Byte16` it's computed on two
  64-bit halves, because LLVM won't vectorize 128-bit arithmetic. Byte-wise `^`, `&`, `|` need no byte
  order. Constants are hex literals of the bytes in memory order (`0x50_4B_03_04` is `50 4B 03 04`),
  which fold into the code (section 11).
- **`ByteRepresentable`**: your own fixed-size types, such as an `IPv4Address` stored as
  `InlineArray<4, UInt8>`. Bytes loads the bytes as a same-size integer and reinterprets them with
  `bitCast`, at no cost, so reading an address is one `ldr`, and a loop of reads runs at memory speed
  (113 GB/s in cache). Four single-byte reads per address ran at 3.7 GB/s.
- **Loops: `forEach`, bulk reads, `values(of:)`.** `reader.forEach(Byte4.self, .bigEndian) { … }` does one
  bounds check up front, then a counted loop of loads, conversion, and your closure, all inlined, which
  LLVM vectorizes together. Bulk reads into an `OutputSpan` do the same without a closure.
  `reader.values(of: Byte3.self, .bigEndian)` returns a view you can `for`-`in` over: it decodes 1,024
  values at a time into its own buffer and hands out spans of it. It's convenient, but storing and
  reloading the decoded values makes it up to 2.5x slower than `forEach` with a trivial loop body.
- **Sections**: `readSection(byteCount:)` returns a cursor bounded to the next N bytes. When N is constant,
  the optimizer sees the section's length, so reads inside need no bounds checks (section 6).
- **`ByteLanes` and `ByteMatches`**: a `SIMD16<UInt8>` wrapper whose every operation compiles to a few NEON
  instructions on every Swift version, for scanning 16 bytes at a time (section 8), plus table lookups and
  shuffles through a small C module (section 9).
- **`BitBuffer`**: 64 bits of input in one register, for decoders that read many small codes (DEFLATE,
  JPEG). Its refill has no loop, and it doesn't check for the end of input per read (section 10).
- **`HuffmanTable`**: decoding a code is one table lookup (two for long codes), and the entry type is
  yours, so an entry can carry everything the next step needs (section 10).
- **`CRC32`**: the zip/PNG checksum, at 63 GB/s with the CPU's carry-less multiply (section 10).

## 5. Keep the cursor in registers

The biggest single factor: Bytes' loops vectorize, and its fields compile to one or two instructions,
only while the optimizer can hold the cursor's fields in registers (section 1). Three ways to lose that:

**1. A slow path that borrows `self`.** Rare cases, such as a read that isn't byte-aligned, went to a
non-inlined `mutating` helper. Calling it passes the cursor's address, so every caller kept the whole
40-byte cursor in memory, even on the fast path that never calls it.

```swift
// Before (illustrative): the cursor lives in memory in every caller.
mutating func readUnaligned(_ count: Int) -> UInt128 { … }

// After: values in, value out. The fast path keeps the cursor in registers.
static func _unalignedBytes(_ count: Int, in span: RawSpan, atByte byteOffset: Int, bit: Int,
                            bitOrder: BitOrder) -> UInt128 { … }
```

**2. A function that isn't inlined.** At first `read(byteCount:)` wasn't inlined, so the cursor was
spilled around every call. These two fixes plus the invariant in section 6 took field parsing from 439 K
to 287 K instructions (−35%), and bit-field parsing from 2,378 K to 886 K (−63%).

`@inline(__always)`, the older underscored attribute, is only a hint. In the DEFLATE decoder, LLVM's
inliner declined it ("not profitable") for the back-reference copy (copying an earlier run of output)
inside a large function, so the call took the writer by address, keeping it in memory for the whole
decoding loop. SE-0496's `@inline(always)` is a guarantee. Adopting it and splitting the decoder into
small functions that each hold their cursors as locals was the largest of the five changes that took the
decoder from 2x slower than zlib to faster.

**3. A cursor captured by a closure.** A closure that isn't inlined keeps its captured variables in
memory.

```swift
// 0.6 GB/s. `fill` is a closure parameter, (inout BytesWriter) -> Void. The compiler merged the closures
// into one compiler-generated wrapper (a thunk) that called `fill` indirectly, with the writer in memory.
output.withBytesWriter { writer in fill(&writer) }

// 54 GB/s: the loop is in the closure itself, so the writer is a local the optimizer sees.
try output.withBytesWriter { writer in
    for index in 0..<count { try writer.write(value(at: index)) }
}
```

`forEach` had the same problem: for its largest closure body, the optimizer moved the loop into a separate
copy of `forEach` specialized for that closure, which stored the captured variables every iteration.
Marking `forEach` `@inline(__always)` kept them in registers. A QOI image decoder took 21% less time
(9.9 → 7.8 ms) just by making its cursors locals instead of captured variables.

**The rule for users:** in hot loops, keep cursors as locals of small functions or in inlinable code, and
don't pass them `inout` to calls that won't be inlined.

## 6. Make bounds checks disappear

Every read checks that enough bytes remain. A check is just a compare and a well-predicted branch, but a
failing check is an early exit, which blocks vectorization (section 1), and checks the optimizer can't
merge add up.

**Tell the optimizer the invariant.** The check is `span.byteCount &- offset >= n`, with wrapping
arithmetic (`&-`) because the cursor knows it can't overflow and doesn't want a trap. To merge the checks
for fields at `offset` and `offset + 2`, LLVM must know `byteCount - offset` isn't negative, which holds
only if `offset <= byteCount`. Bytes states that with `assume`, its wrapper over
`Builtin.assume` ("treat this as true; don't check it"; `Builtin` is the internal module the standard
library uses to reach LLVM directly):

```swift
@inline(__always) func _assumeInvariant() {
    unsafe assume(_byteOffset <= span.byteCount)
    unsafe assume(_bitOffset >= 0)
    unsafe assume(_bitOffset < 8)
}
```

With it, each field's check becomes a compare of its end offset against a constant computed once before
the loop: 3 instructions per field instead of 4, the remaining `add` doubling as the load address.

A fourth assumption, `_byteOffset >= 0`, is just as true but deliberately left out: it alone of the four
stopped LLVM vectorizing loops of single reads (14 against 113 GB/s for 4-byte values). Leaving it out
costs 11% more instructions in field-by-field parsing, at the same speed. Optimizer hints can hurt as well
as help; each was tested alone.

**Give the record a known size.** A fixed-size record read as its own cursor has a length the optimizer
can see, so reads inside it need no checks:

```swift
// Field by field: a check per field. 301 K instructions, 11 µs for 2,000 zip headers.
let signature = try reader.read(Byte4.self)
let version = try reader.read(Byte2.self, .littleEndian)
// … 15 more fields

// One check for the record, none per field: 199 K instructions (−34%), 7.8 µs.
var record = BytesReader(try reader.read(byteCount: 46))
let signature = try record.read(Byte4.self)
let version = try record.read(Byte2.self, .littleEndian)   // bytes 4..<6 of 46: known in bounds
```

The compiler even loads adjacent 4-byte fields with one instruction (`ldp w6, w7, [x16, #16]`: two
fields from address x16 + 16).

**Loop over typed spans.** Base64's encoder (section 10) processes 48-byte blocks. Loading three vectors
per block at byte offsets from a `RawSpan`, and storing four, checked every access: 14 of the loop's 45
instructions. Viewing the input as `Span<InlineArray<48, UInt8>>` and the output as
`MutableSpan<InlineArray<64, UInt8>>` leaves one check per span, before the loop: each index comes from
`blocks.indices`, so it's in range, and one `output.count == blocks.count` test covers every store.

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

Instructions fell 2.3x; throughput didn't move. The checks had run in spare slots beside the table
lookups, which were the bottleneck (section 10). Removing work that isn't the bottleneck doesn't make a
loop faster.

**When the standard library's safe accessors cost too much.** Every `unsafe` access in Bytes was tried
against its checked standard-library counterpart. Where the library's check folds into the cursor's own,
the safe version was kept: switching the sub-cursor above to the checked `extracting` even made
fixed-size records 31% faster. Elsewhere it doesn't fold, because it needs `offset >= 0`, which the
cursor deliberately doesn't assume, so it remains a second check. Checked cursor reads cost 24% more
instructions for field parsing and 2–8x for odd widths, and stopped bulk loops vectorizing. So the
unchecked accesses stay, confined to a few functions, each behind the cursor's own check with a comment
on why it's safe.

**A check folds only while the optimizer knows both sides.** The table CRC (section 10) looks up bytes in
256-entry tables. As `Span`s of exactly 256 entries, a byte index is provably in range, and in the main
loop the checks vanished. In the loop for short inputs they stayed: each table's count sat in a register,
compared before every lookup. Stating the counts with a `precondition` fixed that loop and broke the main
one, which now ran out of registers, spilled, and checked again (126 → 293 instructions per 40 bytes).
The tables became pointers into the borrowed array, with the argument for safety (every index is a byte)
in a comment. Whether a safe access is free can depend on register pressure in code nearby; check the
loop, not the function.

## 7. Let LLVM vectorize your loops

Most of Bytes' speed comes from loops written so LLVM vectorizes them on its own:

**Independent loads, not a moving pointer.** A reader that advances a pointer field by field makes each
load wait for the previous advance (a dependency chain). Bytes loads each field in a record from `base +
constant offset`, independently. On the same zip directory, Bytes took two-thirds of the time of a
conventional pointer-advancing reader (11 against 17 µs) despite running 16% more instructions (301 K
against 259 K).

**Odd widths with overlapping loads.** There's no 3-byte load instruction, so a `Byte3` is read as two
overlapping 2-byte loads, bytes 0–1 and 1–2, combined with a shift; `Byte5`–`Byte7` as two overlapping
4-byte loads. That never reads past the value, and LLVM vectorizes it. The exception: for runs of 3-byte
values, loading each byte separately lets LLVM use `ld3`, which loads 48 bytes and *deinterleaves* them
into three registers (bytes 0, 3, 6 … in the first, 1, 4, 7 … in the second): 46% more throughput in a
loop (13 → 19 GB/s). There's no `ld5`: 5-byte groups loaded bytewise ran at 9.2 GB/s, against 22.5 with
overlapping loads.

**Use as many lanes as you can.** Bit fields first iterated in 64-bit blocks of 8 values: two lanes per
vector register. For widths that divide 8 (1, 2, 4, 8 bits), iterating a byte at a time gives 16 lanes:

| Width | 64-bit blocks | A byte at a time | Speedup |
|---|---|---|---|
| `Byte` (8 bits) | 12 GB/s | 77 GB/s | 6.4x |
| `Nibble` (4 bits) | 6.0 | 50 | 8.3x |
| `Crumb` (2 bits) | 3.9 | 28 | 7.2x |
| `Bit` | 2.0 | 11 | 5.5x |

`Bit` at 11 GB/s is 88 billion values per second, about 22 per cycle.

The benchmark's own consumer had the same problem: summing every `UInt16` into a 64-bit total turns one
register of 8 values into four registers of 2, so the widening, not the reading, was the bottleneck.
Summing in the value's own width took `Byte2` from 37 to 75 GB/s.

**What stops the vectorizer** (each found in the assembly, then confirmed with a benchmark):

| Pattern | Why it can't be vectorized | Fix |
|---|---|---|
| A lookup at a computed index (`table[Int(x)]`) | Each lane needs a different address: a *gather*, which NEON can't do from memory | Compute the value instead (below) |
| `if`s or ternaries in the body | LLVM vectorizes an `if` by computing both sides and picking per lane, but only while it's still an `if`; once optimized into real jumps, it can't | Arithmetic masks (below) |
| An early exit (`return` or `throw` inside the loop) | The vector loop would already have run the lanes after the exit | Explicit SIMD (section 8), or one check before the loop (section 6) |
| 128-bit arithmetic | LLVM doesn't vectorize it | Split into 64-bit halves (`Byte9`–`Byte15`: scalar → vectorized) |
| Two 64-bit lanes | LLVM's *cost model* (its estimate of whether a vector version pays) judges it not worth it, and Swift has no loop pragma to overrule it | Accept it: `Byte16` reads and `Byte8` writes stay scalar, yet `Byte16` still reads 56 GB/s on one core and the memory ceiling on all cores |
| A variable kept in memory | Each iteration's store must reach the next iteration's load, so iterations can't run side by side | Section 5 |

An example of the branch case: Base64 maps 6-bit values (0–63) to characters by range:

```swift
// Stayed scalar in the package build. The range tests are correlated (a value of at least 62 is at
// least 52), so LLVM merged them into jumps ("jump threading") and then couldn't vectorize.
func character(_ v: UInt8) -> UInt8 {
    if v < 26 { return v &+ 65 }        // A–Z: 'A' is 65
    if v < 52 { return v &+ 71 }        // a–z: 'a' (97) − 26
    if v < 62 { return v &- 4 }         // 0–9: '0' (48) − 52
    return v == 62 ? 43 : 47            // '+', '/'
}

// Vectorized: masks are arithmetic, so there's nothing to turn into a jump.
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

The branching version vectorized in a one-file test but not in the package build: the optimizer's decisions
depend on context, so check the build you ship.

## 8. Write SIMD yourself with `SIMD16`

When the vectorizer can't help, as with searches that stop at the first match, write NEON directly with
Swift's `SIMD16<UInt8>`.

**Searching 16 positions at once.** Finding a zip file's end-of-directory signature means scanning
backward for 4 bytes. The scalar loop compares at each offset and exits on a match, which LLVM won't
vectorize. The SIMD version tests 16 candidate offsets per step: it compares the pattern's first byte
against 16 loaded bytes and its last byte against the 16 bytes 3 further on, then checks only offsets
where both match: the "first and last byte" filter from [Wojciech Muła's SIMD substring
search](http://0x80.pl/notesen/2016-11-28-simd-strfind.html).

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

**Which `SIMD16` operations are safe on Swift 6.4.** Comparing two vectors (`starts .== head`, `a .>= b`)
compiles to one instruction (`cmeq`, `cmhs`). Overloads that compare against a scalar (`v .== 0`,
`v .>= 0x80`) compile one lane at a time, and `any()` is inlined in some loops (like the one above) but a
real function call in others. Swift 6.5-dev fixes both. Bytes' `ByteLanes` sidesteps this by building its
tests from wrapping arithmetic and bitwise operations, which always compile to a few NEON instructions:

```swift
struct ByteLanes { var vector: SIMD16<UInt8> … }

// The high bit is set in each lane equal to `byte`: x &- 1 & ~x has its high bit set exactly when x is 0.
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

MQTT uses this to check topic names. ASCII is already valid UTF-8, so one pass, 16 bytes per step, checks
that every byte is ASCII (`nonASCII` is just each lane's high bit) and that none is a byte MQTT forbids
(`0`, `+`, `#`). The last step re-reads the final 16 bytes, overlapping the previous one, so there's no
byte-at-a-time tail. A 32-byte topic takes two inlined steps of 9 vector instructions. Only non-ASCII
topics go on to the standard library's full UTF-8 validation.

## 9. Reach instructions Swift can't express

Some NEON instructions do in one step what otherwise takes a dozen, and Swift can't emit them: it has no
intrinsics (functions that map to one specific instruction), `Builtin` doesn't expose CPU-specific ones,
and `SIMD16`'s dynamic subscript (indexing a vector with another vector) compiles a lane at a time
(shuffles by *constant* positions are the exception; see below). The fix is a small C target of
`static inline` functions over C vector types that Swift imports as `SIMD16<UInt8>`. Swift inlines these,
so each call becomes the single instruction:

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

Three instruction families were worth this:

- **`tbl`: table lookup.** Each lane of an index vector picks one byte from a table of up to 64 bytes in
  four registers: 16 lookups in one instruction, with no memory access. It's the gather NEON can't do from
  memory, done in registers. Bytes uses it to move the bytes of 3-, 5-, 6-, and 7-byte values into whole
  4- or 8-byte lanes and back (bulk reads 1.8–2.5x faster, writes 1.3–2.4x), and Base64 to map 6-bit
  values to characters. It sits behind the `NEONShuffle` package trait (SE-0450: an option declared in
  Package.swift); other CPUs use the portable shuffles below.
- **`zip`: interleave.** `zip1` and `zip2` interleave two vectors lane by lane (a0 b0 a1 b1 …), giving
  the first and second halves of the result.
- **`pmull`, `eor3`, `crc32x`: CRC.** `pmull` is a carry-less multiply (`pmull2` the same on the upper
  halves), `eor3` XORs three registers, and `crc32x` computes the CRC of 8 bytes, each in one instruction.
  Section 10 shows how they combine.

**The catch: LLVM merges shuffles into ones it can't build.** Interleaving four vectors takes two rounds of
`zip`s. Written with Swift's lane initializers, each round alone compiles to `zip`s, but LLVM's
instruction combiner (the pass that merges neighboring operations) fused the two rounds into four-vector
shuffles, which ARM64 can only build one lane at a time: 1 `zip` and 14 lane inserts per output vector
instead of 3 `zip`s. The C helper separates the rounds with an empty inline-assembly statement, which
emits nothing but stops the compiler from seeing through it:

```c
uint8x16_t ab0 = vzip1q_u8(a, b), ab1 = vzip2q_u8(a, b);
uint8x16_t cd0 = vzip1q_u8(c, d), cd1 = vzip2q_u8(c, d);
// "+w": the asm may change these vector registers, so the compiler can't merge across it.
__asm__("" : "+w"(ab0), "+w"(ab1), "+w"(cd0), "+w"(cd1));
result.v0 = vzip1q_u16(ab0, cd0);   // second round, on 16-bit lanes (casts omitted)
// …
```

Two other Swift patterns produced lane-by-lane inserts: choosing a zip pattern with a `Bool` parameter,
and building a constant vector from an array literal, then changing lanes (16 inserts). `Tools/loops`
flags all of these as `+lane-moves`.

**When not to shuffle.** Unpacking 3-byte values with `tbl`, then calling the loop body once per value,
was 5x *slower* than the plain loop, which LLVM had already vectorized, body included, using `ld3`:
calling the body per value pulled each lane back out to scalar code. A specialized instruction helps only
if the code around it stays vectorized. (Below: for 5–7-byte values, unpacking into a small buffer and
running the body over it does keep the body vectorized.)

**Constant shuffles don't need C.** A lookup with run-time indices needs `tbl`, so the C target. But if the
indices are constants, Swift can do it: build a vector from lanes of another, picked at constant
positions, and LLVM recognizes the whole initializer as one shuffle. Bytes' `GroupShuffle` unpacks 5-byte
values this way, two per vector:

```swift
// 10 bytes in (two 5-byte values, big-endian), two zero-extended 64-bit lanes out.
let v = span.unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: SIMD16<UInt8>.self)
let lanes = SIMD16<UInt8>(v[4], v[3], v[2], v[1], v[0], 0, 0, 0,
                          v[9], v[8], v[7], v[6], v[5], 0, 0, 0)
```

In Bytes the positions come from a function of the width and byte order, which folds to constants once
the generic code is specialized. The loop is a load, one single-register `tbl`, and a store; on x86-64 the
same Swift compiles to one `pshufb` (only a generic x86-64 target without SSSE3 expands it into a longer
sequence). It's portable, and cheaper than the 64-byte lookups it replaces: a
`tbl` costs a micro-op per table register, so one over a single register is a quarter of one over four.
Iterating 3-, 5-, 6-, and 7-byte values with it is 22–44% faster than with the NEON lookups, so every build
uses it there (section 10); the portable builds use it for everything else too.

**The same merging, without `asm`.** Writing with it, each vector was built from four computed values
and then shuffled, and LLVM merged the two steps into one byte insert per byte (40 per vector for 3-byte
values), slower than not shuffling. `forEach`, handing the caller's body each value straight out of the
vector, kept the body scalar: summing ran 2x slower than the plain loop. An empty `asm` would stop the
merging, but it's specific to each architecture. The portable fix is to go through memory: a 512-byte
stack buffer (`withUnsafeTemporaryAllocation`, no heap allocation). To write, a plain loop computes a chunk
of values into it, which LLVM vectorizes like any loop, and vectors are loaded back, shuffled, and stored.
For `forEach`, vectors are unpacked into it and the caller's body runs over it as a plain loop, which
vectorizes with the body. A load from memory is opaque enough. Staging only pays for a full buffer (64 or
128 values): shorter runs took 37% more instructions that way, so they keep the plain loops.

**An emulated instruction is no fallback.** The C header's fallback for other CPUs did each 64-byte `tbl`
a lane at a time: copy the table to the stack, then compare, branch, load, and insert for each of 16
lanes, about 200 instructions where NEON needs one. The shuffle algorithm around it assumed lookups were
nearly free, so the portable build ran 37–113x slower than the NEON one, and 15–54x slower than plain
Swift loops that didn't shuffle at all. An algorithm designed around one CPU's instruction belongs behind
a check that the instruction is there (`ByteLanes.isLookupVectorized`), with a different algorithm
elsewhere.

## 10. Case studies

### Base64: 0.86 → 21.4 GB/s

Encoding splits each 3 input bytes into four 6-bit values and maps each to a character:

```
input bytes   aaaaaabb bbbbcccc ccdddddd
6-bit values  aaaaaa   bbbbbb   cccccc   dddddd
```

One run, 1 MB inputs:

| Step | GB/s | Instructions per 4 MB |
|---|---|---|
| Scalar table loop (the usual implementation: one lookup per character) | 0.86 | ≈ 67 M (16 per byte) |
| Character computed with masks (section 7); LLVM vectorizes with `ld3` … `st4` | 9.0 | 6.9 M |
| 48-byte blocks with `tbl`: 3 lookups to split bytes into 6-bit values, 4 to map them, 4 to interleave | 19.1 | 5.0 M |
| Blocks as typed-span elements: bounds checks fold (section 6) | 18.9 | 2.2 M |
| Interleave with 8 `zip`s instead of 4 lookups | 21.7 | 2.8 M |
| Short inputs as one padded block; table built with one initializer | 21.0 | 2.8 M |

The last step was for short inputs (64-byte inputs went from 3.2 to 4.4 GB/s); the final run measured
21.4 GB/s at 1 MB. The kernel, per 48-byte block:

```swift
let source = bitCast(block, to: InlineArray<3, SIMD16<UInt8>>.self)
let (first, second, third) = ByteLanes.deinterleave(source[0], source[1], source[2])   // what ld3 does, in registers
let (c0, c1, c2, c3) = ByteLanes.interleave(                                            // zips
    ByteLanes(first &>> 2).lookup(in: table),                                           // tbl: 6-bit value → character
    ByteLanes((first &<< 4 | second &>> 4) & 0b11_1111).lookup(in: table),
    ByteLanes((second &<< 2 | third &>> 6) & 0b11_1111).lookup(in: table),
    ByteLanes(third & 0b11_1111).lookup(in: table))
```

It runs 32 instructions per 48 bytes in about 9 cycles (3.5 instructions per cycle), 6.5x the speed of
Foundation's `base64EncodedData()`, with zero allocations at every size. A C kernel using `ld3` and `st4`
directly (they split and interleave inside the load and store units; Swift can't emit them for explicit
vectors) reaches 23.1 GB/s. The Swift version is at 93% of that, and level with C of the same design. The
limit is how many `tbl`s the core can start per cycle, not instruction count: cutting instructions 2.3x
didn't change the speed, but replacing 4 four-register lookups with 8 cheaper `zip`s gained 15%.

### Base64 decoding: 12.8 GB/s, at the C ceiling

Decoding reverses it: 64 characters to 48 bytes, rejecting anything outside the alphabet. The kernel
splits the characters into four vectors (8 `uzp`s, what `ld4` does on loading), maps each to its 6-bit value
with table lookups, shifts and ORs the values into three vectors of bytes, and interleaves them (3 `tbl`s,
what `st3` does on storing). Invalid characters map to 0xFF, ORed into an accumulator tested once after
the loop, so there's no branch inside it. The steps, 1 MB:

| Step | Kernel loop | Throughput |
|---|---|---|
| Prototype: lookups for the split and interleave, a 128-byte table | 52 instructions | 12.2 GB/s of text (≈ 9.2 of bytes) |
| `uzp`s for the split, the table as two 64-byte lookups | 131 instructions, 3 calls | — |
| Interleave indices as `Byte16` literals, not `SIMD16` array literals | 91, with byte-wise loads | — |
| An empty `asm` on the loaded vectors, before the `uzp`s | 45 (69 micro-ops) | 11.5 GB/s of bytes |
| An 80-byte window of the table instead of 128 bytes | 49 (61 micro-ops) | **12.8 GB/s** |

Throughput counts decoded bytes except in the first row. Two compiler traps account for the middle rows
(both in section 12). `SIMD16` array literals inside the library's inlinable code became calls to
`SIMD.init` in the caller, three per block, and five more per call for the table: written as `Byte16`
integer literals (bytes in memory order) and converted with `.vector`, they fold to constants. And LLVM
*narrowed* the loads: the first round of `uzp`s only needs every other byte, so it loaded each 16-byte
vector as single bytes, halves, and pieces (91 instructions per block); an empty `asm` on the vectors
keeps the loads whole.

The last row is the encoder's lesson again: the loop was bound by the vector pipes, not by instruction
count, and each `tbl` or `tbx` costs one micro-op per table register. The alphabet runs from
`+` (43) to `z` (122), so subtracting `+` leaves an 80-entry window: one 64-byte lookup and one 16-byte
lookup (`tbx`, which keeps the lane's old value when the index is out of range, here 0xFF) instead of two
64-byte ones, 61 micro-ops per block instead of 69, +11%. A C kernel with `vld4q`, the same window, and
`vst3q` reaches 12.9 GB/s, so the Swift kernel is at 99% of it: `ld4`/`st3` save instructions but use the
same pipes. Result: 4.2x Foundation's `Data(base64Encoded:)`, 50x a scalar table, and no allocations
decoding into a buffer.

### CRC-32: 1.7–2.3x zlib

A CRC is the remainder of dividing the data, as a polynomial over bits, by a fixed polynomial. Software
computes it a byte at a time with a 256-entry table, or 8 bytes at a time with 8 tables ("slicing-by-8").
Three lessons:

- **The table version, rewritten with Bytes' own APIs** (byte-wise `^` on a `Byte8`, a byte subscript
  instead of shifts and masks), halved its instructions (336 M → 180 M) and ran 27% faster on 64-byte
  inputs, but no faster on long ones: those are bound by the latency of each lookup feeding the next, a
  critical path that fewer instructions don't shorten.
- **The hardware version** keeps eight 16-byte accumulators and *folds* 128 bytes per step: each
  accumulator is carry-less-multiplied by a constant that shifts it 128 bytes ahead (`pmull`, `pmull2`),
  then XORed with the data there (`eor3`). The eight chains are independent, so the multiplies' latencies
  overlap. Below 256 bytes it uses `crc32x`, 8 bytes at a time. Result: 63 GB/s on large inputs, 1.7x
  zlib's `crc32_z`, and 2.3x on 64-byte inputs. The first version was 3.5x *slower* than zlib: a nested
  helper that loaded each 16 bytes wasn't inlined, and each call spilled the eight accumulators.
  `@inline(always)` fixed it.
- **The table version, braided.** Fewer instructions couldn't shorten slicing-by-8's chain, but more
  chains could. zlib's *braided* CRC runs five independent CRCs over interleaved 8-byte words: each takes
  every fifth word and jumps 40 bytes per step, with tables that advance a byte past the other four
  braids' words (as if they were zeros), and the five are combined in the last block, which works because
  a CRC is linear. The loop became bound by loads (45 per 40 bytes) instead of latency: 3.6x faster at
  256 KB (14 ms → 3.9 ms for 32 MB, 8.3 GB/s), and 12–14% faster at 64 bytes after the short-input path
  lost its bounds checks (section 6). This is what CPUs without `pmull` use: 8.3x slower than folding, down
  from 30x.

Intel's [Fast CRC Computation for Generic Polynomials Using PCLMULQDQ
Instruction](http://web.archive.org/web/20230315165408/https://www.intel.com/content/dam/www/public/us/en/documents/white-papers/fast-crc-computation-generic-polynomials-pclmulqdq-paper.pdf)
explains the folding math.

### DEFLATE: from 2x slower than zlib to faster

The zip decoder's DEFLATE implementation, built on Bytes' `BitBuffer`, `HuffmanTable`, and `BytesWriter`,
decodes 32 MB of text in 13 ms against zlib's 14, with zero allocations. In order of payoff:

1. **Inlining** (section 5): the guaranteed `@inline(always)`, and small functions with their own local
   bit buffer and writer.
2. **A register-only refill.** The slow refill, used near the end of the input, took the buffer's fields
   `inout`, keeping them in memory on the fast path too; it now takes and returns values. The fast path is
   loop-free: while 8 bytes remain, one unaligned 8-byte load and three arithmetic steps, with no branch on
   how many bytes fit:

   ```swift
   _bits |= UInt64(littleEndian: raw) &<< shift      // raw: the next 8 bytes; shift: bits already held
   _nextByte &+= (63 &- _count) &>> 3                // advance by the whole bytes that fit
   _count |= 56                                      // now 56–63 valid bits
   ```

   Past the end of the input the buffer fills with zeros, and the overrun is reported once per block
   instead of checked on every read.
3. **A faster table builder** ([libdeflate](https://github.com/ebiggers/libdeflate)'s): a short code fills
   many table slots with the same entry, so each is written once, then doubled with `memcpy`. Building
   tables had been 11% of the time for small files.
4. **A shorter critical path.** The next symbol's table entry is looked up before the current one is used,
   so the lookup's latency overlaps the work.
5. **Copies that may overrun.** Instead of an exact byte loop, back-references copy 16 bytes at a time and
   may write up to 32 bytes past their end; this loop runs only while 32 spare bytes remain in the output.

### Three builds: NEON, portable C, Swift only

Bytes' C targets are optional, chosen with package traits: `NEONShuffle` (the `tbl` wrappers) and
`HardwareCRC` (`pmull` and `crc32`) are on by default, and `Portable` keeps both but compiles their
headers' fallbacks for other CPUs (it defines `BYTES_PORTABLE`). `Bytes/bench optimized|portable|portable-no-c`
benchmarks each in its own build directory. Swift modules compile a C header's `static inline` functions
themselves, including ones inlined from Bytes into their own code, so a define on the C target isn't
enough: each Swift target gets it too (`-Xcc -DBYTES_PORTABLE`).

The first measurement of the portable builds was the "emulated instruction" lesson (section 9): odd-width
reads 37–113x slower than NEON in the portable build, and the table CRC 30x slower in both. Three changes,
none specific to a CPU, closed most of it:

1. **Odd widths:** `GroupShuffle`'s constant shuffles (section 9) instead of the emulated lookups, with a
   stack buffer for writes and `forEach`, only where `tbl` isn't one instruction.
2. **CRC:** the braided table CRC (above).
3. **Iterators, everywhere:** an iterator's body only stores each value into its buffer, so a one-register
   `tbl` per two values beat the NEON build's four-register `tbl`s, and the optimized build adopted it:
   `for`-`in` over 3-byte values 294 → 160 µs per 4 MB, 5–7 bytes 26–28% faster. The same path lost to
   NEON for `forEach` with a body, and tied for bulk reads, so those stayed.

Times in µs, two alternating rounds:

| Workload | Before (NEON) | Optimized | Portable, before → now | Swift only, before → now |
|---|---|---|---|---|
| `for`-`in` `Byte3`, 4 MB | 294 | 160 | 284 → 163 | 290 → 158 |
| `for`-`in` `Byte6`, 4 MB | 213 | 157 | 7,809 → 155 | 235 → 157 |
| Bulk read `Byte5`, 4 MB | 99 | 99 | 10,500 → 92 | 202 → 100 |
| `forEach` summing `Byte6`, 4 MB | 159 | 161 | 7,742 → 162 | 171 → 161 |
| Generating write `Byte6`, 4 MB | 147 | 146 | 5,982 → 200 | 227 → 198 |
| CRC-32, 256 KB | 471 | 470 | 14,000 → 3,874 | 14,000 → 3,900 |

Across all 337 benchmarks, the portable builds now average 2% slower than the optimized one (from 1.59x
for the portable build), and 319–321 of them are within 10%. The optimized build averages 1.2% faster
than before. What's left: odd-width writes (1.25–2x: the trip through memory, and a value computation
LLVM vectorizes less tightly than the NEON path's), and CRC without `pmull` (8.3x).

## 11. Smaller lessons

**Write constants as literals.** A `static let` the compiler can't evaluate at compile time is a lazily
initialized global: every use checks a `swift_once` flag (which runs the initializer the first time) and
loads the value. The compile-time evaluator can't fold a byte swap, and Bytes' first integer-literal
initializer for byte groups used one, so parsing zip records with a `static let signature: Byte4 =
0x50_4B_01_02` cost 41% more instructions (281 K against 199 K). The initializer now reverses the bytes
with shifts, which fold:

```swift
// The literal's digits are the bytes in memory order: 50 4B 01 02.
static let signature: Byte4 = 0x50_4B_01_02              // folded into the code: two instructions
static let signature = Byte4(0x504B_0102, .bigEndian)    // byte swap: swift_once on every use
```

**Big enums are expensive to pass around.** MQTT's `MQTTPacket` enum is 153 bytes, too big for registers,
so it's returned through a pointer, and each test of its case calls an outlined (moved out of line) "get
tag" function that reads which case it holds. Writing a packet tested its case five times. Giving each
packet type its own `init(parsing:)` and `write(to:)`, and dispatching on the frame's type before building
anything, raised encoding throughput 68% (even through the enum) and parsing throughput 58% with frames
(25% through the enum):

```swift
// Before: build the enum, then test its case.
if case .publish(let publish) = try MQTTPacket.read(from: &reader) { … }

// After: read the fixed header, dispatch, build only what's needed.
guard let frame = try MQTTFrame.read(from: &reader, maximumPacketSize: limit) else { return }
if frame.type == .publish { let publish = try MQTTPublish(parsing: frame) … }
```

**Concurrency: `nonisolated(nonsending)` (SE-0461).** A plain `nonisolated` async function calls into the
runtime (`swift_task_switch`) on entry and after each call it makes, to ensure it's on the generic
executor, even when it already is. In a socket transfer, that came to 2.5 runtime calls per socket
operation. As `nonisolated(nonsending)`, the functions run on their caller's executor and make none (0.9
remained, in the standard library's continuation).

**Pack bits before writing them.** Each single-bit write merges into the byte the previous write left
partly done, a dependency chain from write to write. The bulk writer packs a byte (or 8 values) at
a time: 110x faster for 4-bit values.

**Zero-copy typed spans are only as fast as their element loads.** `read(InlineArray<4, UInt8>.self,
count:)` returns a typed view of the input without copying, and for 4-byte elements iterating it runs at
memory speed. For 6-byte elements it's about 2x slower than `forEach`, and up to 3.7x for 16-byte ones:
`Span`'s subscript loads an `InlineArray` element byte by byte, and LLVM merges those loads only for 4
bytes. Bytes' own loads use a same-size integer load and `bitCast` instead (section 4).

**Building arrays: avoid the standard library's uninitialized-capacity initializers in hot code.**
`[UInt8](capacity:initializingWith:)` and `init(unsafeUninitializedCapacity:initializingWith:)` allocate
through a function that isn't specialized for the element type: about 500 instructions and 27 ns more per
array than `reserveCapacity` followed by `append(addingCapacity:)`, at 40 bytes and at 1 KB alike. Bytes'
array builder switched and made 1,000 38-byte arrays with 27.6% fewer instructions; MQTT's copying
benchmark had run 17.5% more instructions (about 590 per packet) when `[UInt8](copying:)` went through the
slow path.

**Annotate the error type of closures passed to `throws(E)` parameters.** Without the `FullTypedThrows`
feature, `{ writer in try writer.write(…) }` is inferred as `throws(any Error)`, and such a closure
wasn't inlined into the array builder: the writer went through memory, +3% instructions. Written
`{ (writer) throws(BytesError) in … }`, it was. An overload taking only `throws(BytesError)` doesn't help:
the unannotated closure still infers `any Error`, then fails to match.

**Measure each convenience against what it replaces.** New helpers were checked as `@inline(never)` pairs
against hand-written code, counting instructions per function; most compiled to identical code or
shorter. Three didn't, in context: `Bits(rawBitsOf:)` cost MQTT 3 instructions per packet over the
explicit conversion; a throwing `String(utf8Capacity:writing:)` called with `try!` cost 10 instructions
per call (hence a non-throwing overload); and `keepingLowBits` in place of an explicit mask grew a loop of
`write(_:bitCount:)` calls from 146 to 169 instructions, because LLVM split the function differently. Each
call site kept its old form, with a comment saying why.

**A loop's start matters on short runs.** The generating write's plain loop finishes whatever the shuffle
path leaves, so it started at a run-time index. For runs of 1–62 values that cost about 20 instructions
per call over a loop starting at a constant 0. Giving the long-run path its own loops fixed it.

**Mind Swift's precedence for shifts.** Shifts bind tighter than multiplication, so `count &* 3 &>> 2` is
`count &* (3 &>> 2)`, which is 0. Base64's decoder briefly computed an output size of zero that way.

**Measure hints.** Without its `likely`/`unlikely` hints (Bytes' wrappers for LLVM's branch weights,
through `Builtin`), bit-field parsing took 14% more instructions (689 K → 787 K) in the same time; the
hints were kept. `@frozen` changed nothing outside a binary framework, so it was removed. Spacing the CRC
tables apart in memory, in case they evicted each other from the cache, changed nothing.

## 12. Limitations and bugs found in Swift and LLVM

A summary; most of it is covered above. Swift 6.4.2 (Xcode 27.2–27.3) unless noted. Two compiler bugs
have reports with reproducers written but not yet filed.

| Issue | Effect | Workaround |
|---|---|---|
| **`for x in reader` over a `~Copyable` `let`** keeps it in a heap box: the iterator depends on the `let`, and `AllocBoxToStack` (the pass that moves boxed locals to the stack) treats that dependence as an escape. Related: swiftlang/swift#93942 | One allocation per loop | Declare the cursor `var`, or take it `borrowing` |
| **`~Escapable` structs with more than 6 leaf fields** are destroyed at `-O` even when every field is trivial. From another module, the destroy is an indirect call to a no-op through the type's value witness table | 2.5–3% of MQTT's per-packet time; a third of a tight loop | At most 6 leaf fields, or inlining: impractical for packet views |
| **`SIMD16` comparisons against a scalar** (`v .== 0`) compile one lane at a time, and `any()` is sometimes out of line (section 8). Fixed in 6.5-dev | Scalar "vector" code | Compare against splatted vectors, or wrapping arithmetic |
| **No CPU intrinsics in Swift**: no `tbl` with run-time indices, `ld3`/`st4` on explicit vectors, `pmull`, `crc32`; `SIMD16`'s dynamic subscript and swizzles compile a lane at a time (shuffles by constant positions compile to one instruction) | A byte shuffle written in Swift: 0.3 GB/s, against 16.7 for overlapping stores | A C target of `static inline` wrappers |
| **LLVM merges consecutive shuffles** into ones ARM64 builds lane by lane, and a vector built from computed values into the shuffle that follows. Separately, shuffles chosen by a `Bool` and vector literals changed per lane also become lane inserts | 14–40 inserts per vector | Empty `asm` between rounds, in C; or, portably, through a small stack buffer; one initializer per vector |
| **`SIMD16` array literals in inlinable code** compiled to calls to `SIMD.init` in the caller (in other functions the same literals folded) | ~1,000 instructions per call in Base64's decoder | `Byte16` integer literals, then `.vector` |
| **LLVM narrows loads to the lanes a shuffle uses** (`ld1.b`, `mov.h`, `ext` instead of `ldr q`) | 91 instead of 45 instructions per Base64 block | An empty `asm` on the loaded vectors, in C |
| **The standard library's `[UInt8](capacity:initializingWith:)` and `init(unsafeUninitializedCapacity:)`** allocate through an unspecialized function | ~500 instructions, ~27 ns per array | `reserveCapacity`, then `append(addingCapacity:)` |
| **LLVM threads correlated conditions into jumps**, then won't vectorize | Scalar loop | Arithmetic masks |
| **Two-lane 64-bit loops and 128-bit arithmetic** aren't vectorized, and Swift has no loop pragmas | `Byte16` reads, `Byte8` writes scalar | Split 128-bit values into halves |
| **`Builtin.assume(offset >= 0)`** stops loops of reads vectorizing | 14 against 113 GB/s | Leave that assumption out |
| **`@inline(__always)` is a hint**; LLVM's inliner refused it in a large function | DEFLATE 2x slower than zlib | `@inline(always)` (SE-0496) |
| **Compile-time evaluation can't fold a byte swap**, so a `static let` built with one stays lazily initialized | `swift_once` per use, +41% instructions | Literals that shift instead of swap |
| **The standard library's span bounds check** needs `offset >= 0`, so it doesn't fold into a cursor's own check | Checked loads 24% more instructions to 8x | Unchecked loads behind the cursor's check |
| **`Span` element loads** of `InlineArray<N, UInt8>` go byte by byte except for N = 4 | Typed spans 2–3.7x slower for 6 and 16 bytes | `forEach` with integer loads and `bitCast` |
| **`for x in reader.values(...)`** with a temporary, like the standard library's own `for x in array.span`, is rejected: "lifetime-dependent variable escapes its scope" | Doesn't compile | Bind the view to a `let` first |
| **Closures can't return lifetime-dependent values**, so a `switch` can't wrap each case in a closure to move it out of line | Doesn't compile | Per-case functions |
| **User types can't conform to `ConvertibleFromBytes`** (the standard library's "any bit pattern is valid" protocol) | No direct loads of custom types | `ByteRepresentable` over `InlineArray` storage |
| **Swift Testing's `#expect`** can't inspect a `~Copyable`, `~Escapable` value | Doesn't compile | Copy the property to a local |
| **A span of a global `let` declared in another file** is rejected ("lifetime-dependent value escapes its scope") when files compile separately, as in SwiftPM debug builds, and accepted with whole-module compilation (release). Also on 6.5-dev | Debug builds fail, release builds pass | Bind the global to a local first |
| **`atomically { }` around a large body** isn't inlined, so the cursor lives in memory | +50% instructions for a whole zip entry | Keep atomic bodies small |
| **Typed-throw sites check OS availability** (`_stdlib_isOSVersionAtLeast…` before `swift_willThrowTypedImpl`) even when the deployment target is macOS 27 | Code size on every throw path | None |
| **package-benchmark's thresholds** for names with spaces or `/` are written under one name and looked up under another ([ordo-one/benchmark#301](https://github.com/ordo-one/benchmark/issues/301), [#373](https://github.com/ordo-one/benchmark/issues/373)) | A check that silently doesn't run | Names without spaces |

## 13. Glossary

- **Auto-vectorization**: the compiler rewriting a loop to use SIMD instructions on several elements per
  iteration.
- **Back-reference**: in LZ77 compression (DEFLATE), "copy N bytes from D bytes back in the output".
- **Bounds check**: a test that an index or offset is within a buffer, with a trap or throw if not.
- **Branch prediction**: the CPU guessing a branch's direction to keep working; a wrong guess costs ~15
  cycles.
- **Byte order (endianness)**: whether a multi-byte integer is stored least significant byte first
  (little-endian, Apple's CPUs) or most significant first (big-endian, most network formats). Converting is
  a byte swap (`rev` on Arm), one instruction.
- **Cache, cache line**: small fast memories between the core and main memory (L1, L2), filled in fixed
  blocks called cache lines: 128 bytes on Apple silicon.
- **Carry-less multiplication**: multiplying bit strings with XOR in place of addition; the core of fast
  CRCs (`pmull` on Arm, `pclmulqdq` on x86).
- **Compute-bound, memory-bound**: limited by how fast the core computes, or by how fast memory delivers
  data. A loop that runs as fast in cache as from memory is compute-bound.
- **Cost model**: the vectorizer's estimate of whether a vector version of a loop would be faster.
- **Critical path**: the longest dependency chain in a loop; it sets the minimum time per iteration.
- **Cycle**: one tick of the CPU's clock, ~0.25 ns here.
- **Dependency chain**: instructions that each need the previous one's result, so they can't overlap.
- **Gather**: loading each lane from a different, computed address. NEON can't gather from memory; `tbl`
  gathers from registers.
- **Hoisting**: moving a computation out of a loop so it's done once.
- **Inlining**: replacing a call with the called function's body, letting the optimizer see through it.
  **Outlining** is the reverse: moving code into a separate function.
- **Instructions per cycle (IPC)**: how many instructions a core completes per cycle; up to ~8 here when
  they're independent.
- **Intrinsic**: a function the compiler maps to one specific instruction, such as C's `vqtbl4q_u8` for
  `tbl`.
- **Jump threading**: an optimization that merges related branches into direct jumps; it can turn
  vectorizable `if`s into control flow the vectorizer can't handle.
- **Lane**: one element slot of a vector register: 16 byte lanes, 8 16-bit lanes, and so on. A **lane
  insert** moves one value into one lane: building a vector that way is slow.
- **Latency vs throughput**: latency is how long one instruction takes to produce its result; throughput
  is how many of that instruction the core can start per cycle. A dependency chain is latency-bound.
- **Loop pragma**: a source annotation that overrides the compiler's loop decisions, such as C's
  `#pragma clang loop vectorize(enable)`. Swift has none.
- **Mask**: a value with all bits set (0xFF) or clear (0), used to select or zero values without a branch.
- **Memory bandwidth**: bytes per second from main memory: ~72–77 GB/s for one core here, ~245–250 GB/s
  for all.
- **NEON**: Arm's 128-bit SIMD instruction set.
- **Package trait**: an optional feature of a Swift package, declared in Package.swift and turned on or off
  by its users (SE-0450).
- **Prefetching**: the CPU loading cache lines before they're asked for, when it detects a pattern.
- **Reduction**: combining all lanes of a vector into one value (`umaxv`: the largest lane).
- **Register**: a storage slot inside the core; the only place instructions operate on directly.
- **Scalar**: one value at a time, as opposed to SIMD.
- **SIMD**: Single Instruction, Multiple Data: one instruction operating on every lane of a vector.
- **Shuffle (permute)**: rearranging the lanes of one or more vectors: `tbl`, `zip`, `ld3`/`st4`.
- **Spill**: storing a register's value to the stack because the compiler ran out of registers or needed
  its address.
- **Stall**: a cycle in which the core can't start any instruction, usually waiting for memory or a result.
- **Structure loads and stores (`ld3`, `st4`)**: Arm instructions that load or store several registers
  interleaved: `ld3` puts bytes 0, 3, 6 … in one register, 1, 4, 7 … in the next, 2, 5, 8 … in the third.
- **`swift_once`**: the runtime call behind lazily initialized globals and `static let`s: it runs the
  initializer once, and every use checks it.
- **Thunk**: a small compiler-generated function that adapts one calling convention to another.
- **Value witness table**: a per-type table of functions (copy, destroy, …) Swift uses to handle values
  whose type's layout it doesn't know at compile time, such as a type from another module.

## 14. Further reading

- Swift Evolution: [SE-0390 noncopyable types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md),
  [SE-0446 nonescapable types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md),
  [SE-0447 `Span`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md),
  [SE-0450 package traits](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md),
  [SE-0452 integer generic parameters](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0452-integer-generic-parameters.md),
  [SE-0453 `InlineArray`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md),
  [SE-0461 `nonisolated(nonsending)`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md),
  [SE-0496 `@inline(always)`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0496-inline-always.md).
- [Apple Silicon CPU Optimization Guide](https://developer.apple.com/documentation/apple-silicon/cpu-optimization-guide):
  Apple's description of its cores and caches, and what code they like (developer account required).
- [Arm NEON intrinsics reference](https://developer.arm.com/architectures/instruction-sets/intrinsics/):
  every instruction used here, with diagrams.
- [LLVM's auto-vectorizers](https://llvm.org/docs/Vectorizers.html): what the loop vectorizer handles.
- [What Every Programmer Should Know About Memory](https://people.freebsd.org/~lstewart/articles/cpumemory.pdf)
  (Ulrich Drepper): caches and memory, in depth.
- [Faster Base64 Encoding and Decoding Using AVX2 Instructions](https://arxiv.org/abs/1704.00605)
  (Muła, Lemire) and [Validating UTF-8 In Less Than One Instruction Per Byte](https://arxiv.org/abs/2010.03090)
  (Keiser, Lemire): the SIMD techniques behind fast Base64 and text validation.
- [Dougall Johnson's Apple M1 instruction tables](https://dougallj.github.io/applecpu/firestorm.html):
  latency and throughput of each instruction on Apple's cores.
