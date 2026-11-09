# Fast Swift for binary data: what a week of Bytes taught us

Bytes is a Swift library for parsing and writing binary formats: a reading cursor (`BytesReader`) and a
writing cursor (`BytesWriter`) over borrowed memory, with fields from 1 bit to 16 bytes. This week it went
from a first version to one that reads at memory speed, and three projects were built on it: an MQTT 5
codec, a DEFLATE decoder that beats zlib, and a Base64 encoder at 93% of hand-written C.

This document summarizes the design and optimization techniques that got it there, with before-and-after
code and the measurements behind each. It's written for experienced Swift programmers who know CPUs only
at the surface: the terms are defined as they come up, and gathered in a glossary at the end. The full
records are in [Benchmarks/RESULTS.md](Benchmarks/RESULTS.md) and in each project's RESULTS.md.

All numbers are from one machine: an Apple M3 Ultra (24 performance and 8 efficiency cores), macOS 27.2,
Swift 6.4.2 (Xcode 27.3), release builds, medians of the [ordo-one benchmark
package](https://github.com/ordo-one/package-benchmark). "GB/s" is bytes processed per second.

## Contents

1. [How the CPU sees your loop](#1-how-the-cpu-sees-your-loop)
2. [How to measure](#2-how-to-measure)
3. [The cursor: a design that lets the compiler help](#3-the-cursor-a-design-that-lets-the-compiler-help)
4. [Keep the cursor in registers](#4-keep-the-cursor-in-registers)
5. [Make bounds checks disappear](#5-make-bounds-checks-disappear)
6. [Let LLVM vectorize your loops](#6-let-llvm-vectorize-your-loops)
7. [Write SIMD yourself with `SIMD16`](#7-write-simd-yourself-with-simd16)
8. [Reach instructions Swift can't express](#8-reach-instructions-swift-cant-express)
9. [Case studies: Base64, CRC-32, DEFLATE](#9-case-studies)
10. [Smaller lessons](#10-smaller-lessons)
11. [Limitations and bugs found in Swift and LLVM](#11-limitations-and-bugs-found-in-swift-and-llvm)
12. [Glossary](#12-glossary)
13. [Further reading](#13-further-reading)

## 1. How the CPU sees your loop

A few facts explain almost every result below.

- **Instructions are cheap; waiting is expensive.** An M3 core can start about 8 instructions per cycle
  (a cycle is ~0.25 ns at 4 GHz), but only if they don't wait on each other. A chain of instructions where
  each needs the previous one's result (a *dependency chain*) runs at the speed of its slowest link, its
  *latency*, however wide the core is. So two loops with the same instruction count can differ 2x in time.
- **Registers are free; memory costs.** A core has 31 general-purpose registers and 32 128-bit vector
  registers. A value the compiler can keep in a register costs nothing to access. A value it must keep in
  memory (because its address was taken, or it was passed `inout` to a function that wasn't inlined) is
  loaded and stored around every use. Moving a register's value to the stack is a *spill*.
- **Memory arrives in cache lines.** The CPU moves memory in 128-byte blocks (*cache lines* on Apple
  silicon; 64 on most x86 chips) into small, fast caches: L1 (~128 KB per core, a few cycles away), L2
  (16 MB shared by a cluster), then main memory (~100 ns away). Reading sequentially is fast because the
  hardware *prefetches* the next lines before you ask. On this machine one core can pull about 77 GB/s from
  memory; all cores together about 245 GB/s.
- **SIMD does 16 things at once.** A 128-bit vector register holds 16 bytes, 8 16-bit, 4 32-bit, or 2
  64-bit values. Each slot is a *lane*. One SIMD instruction (Single Instruction, Multiple Data) operates on
  every lane at once: one `add` adds 16 pairs of bytes. Arm's SIMD instruction set is called *NEON*.
  Swift's `SIMD16<UInt8>` is one such register.
- **The compiler vectorizes for you, sometimes.** LLVM, the optimizer behind Swift, rewrites simple loops
  to process 16 or 64 bytes per iteration with SIMD instructions (*auto-vectorization*). Small things stop
  it: a branch in the loop body, a function call, a lookup at a computed index, a value kept in memory.
  When it gives up, a loop runs 3–10x slower, and nothing tells you.
- **Branches are guesses.** The CPU predicts which way each branch goes and runs ahead. A wrong guess
  throws away ~15 cycles of work. Predictable branches (a bounds check that always passes) are nearly
  free; data-dependent ones are not.

## 2. How to measure

Four habits made the difference between guessing and knowing:

1. **Benchmark everything, including allocations.** Every workload in Bytes also runs as an
   `Allocations:<name>` benchmark that counts only `malloc` calls, checked against a static threshold of
   zero. A compiler bug was found this way (section 11).
2. **Count instructions, not just time.** Instruction counts are deterministic; times vary ±10% between
   runs. A change that saves 20% of instructions but no time tells you the loop is latency-bound or
   memory-bound, which is itself worth knowing.
3. **Read the assembly.** "Did it vectorize?" has a definite answer in the machine code: look for vector
   instructions (`ld1`, `add.16b`, `tbl`) in the loop. `Tools/loops` in this repository finds the loops in
   a compiled function and prints a verdict (`vector128`, `scalar`, `+lane-moves`).
4. **Ask the CPU.** Performance counters (Instruments' CPU Counters, or `Tools/counters`) count SIMD
   instructions executed, cache misses, and where cycles stall. A scalar build of Base64 executes zero SIMD
   instructions; the vectorized one, 18.5 billion per run.

One harness lesson recurred: **make sure you're measuring the code, not the benchmark.** The first
field-parsing benchmark folded each field into `checksum = checksum * 31 + value`, a chain of 13
dependent multiplies per record that took longer than the parsing; every parser measured 19 µs. With a
plain sum, the real differences appeared (9 to 19 µs).

## 3. The cursor: a design that lets the compiler help

```swift
var reader = BytesReader(data.span)
try reader.expect(0x50_4B_03_04 as Byte4)                  // zip signature, or throws
let version = try reader.read(Byte2.self, .littleEndian)   // UInt16
let kind = try reader.read(Bits<3>.self)                   // 3 bits
let name = try reader.read(byteCount: 12)                  // a RawSpan of the same memory: no copy
```

The design decisions that matter for speed:

- **`~Copyable` and `~Escapable` (SE-0390, SE-0446).** The cursor can't be copied and can't outlive the
  memory it reads, so it can hand out `RawSpan`s of that memory (zero-copy) without reference counting or
  allocation. Parsed values are *views*: MQTT's PUBLISH packet holds its topic as a `UTF8Span` and its
  payload as a `RawSpan` into the input. Against conventional parsing into `[UInt8]` and `String`, views
  parse 5.5x faster on one core and 11x on 32 cores, where allocations contend.
- **A small struct of plain values.** A `RawSpan` (pointer + count), a byte offset, a bit offset, a bit
  order: 40 bytes that fit in registers. No class, no buffer, no protocol existential.
- **Typed throws (`throws(BytesError)`).** No `any Error` boxing on the error path.
- **Reads are atomic.** A read that throws consumes nothing, so a streaming parser can retry when more
  data arrives.
- **Separate reader and writer types.** A combined one would need exclusive access to the memory
  (`MutableRawSpan`), and then the spans it hands out could only borrow the cursor, not the memory: reading
  a field after taking a span would be an "overlapping access" error. The loads would be no faster anyway.
- **Widths as types.** `Bits<let width: Int>` (an integer generic parameter, SE-0452) for 1–8 bits, and
  `Byte2` … `Byte16` for byte groups, so each read compiles to code specialized for its width.

## 4. Keep the cursor in registers

The single biggest factor. Bytes' loops vectorize, and its fields compile to one or two instructions, only
while the optimizer can hold the cursor's fields in registers. Four ways to lose that:

**A slow path that borrows `self`.** Rare cases (a read that isn't byte-aligned) went to a `mutating`
helper. Passing `self` by reference to a function that isn't inlined forces every caller to keep the whole
40-byte cursor in memory, even on the fast path that never calls it.

```swift
// Before: the cursor lives in memory in every caller.
mutating func _readUnaligned(_ byteCount: Int) -> UInt64 { … }

// After: values in, value out. The fast path keeps the cursor in registers.
static func _unalignedBytes(_ byteCount: Int, in span: RawSpan, atByte: Int, bit: Int,
                            bitOrder: BitOrder) -> UInt64 { … }
```

**A function that isn't inlined.** `read(byteCount:)` wasn't inlined at first, so the cursor was spilled
around every call. With these two fixes and the invariant in section 5, field parsing went from 439 K to
287 K instructions (−35%), and bit-field parsing from 2,378 K to 886 K (−63%).

`@inline(__always)` is only a hint: in the DEFLATE decoder, LLVM's inliner declined it for the match copy
in a large function ("not profitable"), took the writer by address, and the decoder ran 2x slower than
zlib. `@inline(always)` (SE-0496) is guaranteed, and fixed it.

**A cursor captured by a closure.** A closure that isn't inlined holds its captures in memory.

```swift
// 0.6 GB/s: the writer passed inout to an inner closure; the compiler merged the closures into one
// thunk that called the inner one indirectly, with the writer in memory.
try output.withBytesWriter { writer in fill(&writer) }

// 54 GB/s: the writer is a local of the loop's own function.
try output.withBytesWriter { writer in
    for value in values { try writer.write(value) }
}
```

The same effect hit `forEach`: for its largest body the optimizer outlined it into a
closure-specialized function, which stored the captured variables on every iteration. Marking `forEach`
`@inline(__always)` kept them in registers. A QOI image decoder ran 27% faster just by making its cursors
locals instead of captured variables.

**The rule for users:** keep cursors as locals of small functions, or in inlinable code. Don't pass them
`inout` across calls that won't be inlined in a hot loop.

## 5. Make bounds checks disappear

Every read checks that enough bytes remain. A check is a compare and a branch (cheap), but checks in a
loop also block vectorization, and consecutive checks the optimizer can't merge add up.

**Tell the optimizer the invariant.** The check is `span.byteCount - offset >= n`. With wrapping
arithmetic, LLVM can't prove that doesn't wrap, so it can't combine the checks of consecutive fields.
Bytes states the cursor's invariant with the compiler's `Builtin.assume` at each entry point:

```swift
@inline(__always) func _assumeInvariant() {
    unsafe assume(_byteOffset <= span.byteCount)
    unsafe assume(_bitOffset >= 0)
    unsafe assume(_bitOffset < 8)
}
```

With it, each field's check becomes a compare of its end offset against a constant hoisted out of the
loop: 4 instructions per field down to 3, with the remaining `add` doubling as the load address.

One assumption that's equally true, `_byteOffset >= 0`, is deliberately left out: with it, LLVM stopped
vectorizing loops of single reads (14 against 113 GB/s for 4-byte values). It was the only one of the four
that did. Dropping it costs 11% more instructions in field-by-field parsing, at the same speed. Hints to
the optimizer can hurt as well as help; each was tested alone.

**Give the record a known size.** A fixed-size record read as its own cursor has a length the optimizer
can see, so the reads inside it need no checks at all:

```swift
// Field by field: a check per field. 291 K instructions for 2,000 zip headers.
let signature = try reader.read(Byte4.self)
let version = try reader.read(Byte2.self, .littleEndian)
// … 15 more fields

// One check for the record, none per field: 199 K instructions, 31% faster.
var record = BytesReader(try reader.read(byteCount: 46))
let signature = try record.read(Byte4.self)
let version = try record.read(Byte2.self, .littleEndian)   // offset 4 + 2 <= 46: known
```

The compiler even pairs adjacent fields into one load (`ldp w7, w19, [x17, #16]`).

**Loop over typed spans.** In Base64, loading three vectors per block at byte offsets from a `RawSpan` and
storing four checked every access: 14 of the loop's 45 instructions. Viewing the input as
`Span<InlineArray<48, UInt8>>` (48-byte blocks) and the output as `MutableSpan<InlineArray<64, UInt8>>`
leaves one check per span, before the loop:

```swift
// One bounds check per access: 5.0 M instructions per 4 MB.
while offset + 48 <= input.byteCount {
    let a = input.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)        // checked
    let b = input.load(fromByteOffset: offset + 16, as: SIMD16<UInt8>.self)   // checked
    // …
}

// One check per span, hoisted: 2.2 M instructions.
for block in blocks.indices {                              // blocks: Span<InlineArray<48, UInt8>>
    output[block] = encodeBlock(blocks[block], table: table)
}
```

Instructions fell 2.3x and throughput didn't move: that loop was bound by something else (section 9).
Removing work that isn't on the critical path doesn't make a loop faster.

**When the standard library's safe accessors cost too much.** Every `unsafe` access in Bytes was tried
with its checked standard-library counterpart. Where the check folds into the cursor's own (a sub-cursor's
checked `extracting`), safe was kept, and was even 31% faster. Where it didn't, unsafe stayed, with a
comment: the standard library's check needs `offset >= 0`, which the cursor deliberately doesn't assume (see
above), so it stays as a second check. Checked cursor reads cost 24% more instructions for field parsing,
2–8x for odd widths, and stopped bulk loops vectorizing. The unchecked accesses are confined to a few
funnels, each behind the cursor's own check.

## 6. Let LLVM vectorize your loops

Most of Bytes' speed comes from loops LLVM vectorized on its own. They're written so it can:

**Independent loads, not a moving pointer.** A cursor that advances field by field makes each load depend
on the previous advance (a dependency chain). Bytes' field loads within a record are `base + constant
offset`, independent of each other. At equal instruction counts, Bytes was 2x faster than the original
`ByteReader` on the same zip directory (9.3 against 19 µs).

**Odd widths with overlapping loads.** There's no 3-byte load instruction. A `Byte3` is read as two
overlapping 2-byte loads (bytes 0–1 and 1–2), a `Byte5`–`Byte7` as two overlapping 4-byte loads. That never
reads past the value, and LLVM vectorizes it. Exception: for runs of 3-byte values, loading each byte
separately lets LLVM use `ld3`, an Arm instruction that loads 48 bytes and *deinterleaves* them into three
registers (every third byte into each): 40% faster in a loop. There is no `ld5`; 5-byte groups loaded
bytewise were 2.4x slower than overlapping loads.

**Process values in the widest lanes you can.** Bit fields first iterated in 64-bit blocks of 8 values:
two values per vector register. Iterating widths that divide 8 per byte instead gives 16 lanes:

| Width | 64-bit blocks | Per byte | |
|---|---|---|---|
| `Byte` (8 bits) | 12 GB/s | 77 GB/s | 6.4x |
| `Nibble` (4) | 6.0 | 50 | 8.3x |
| `Crumb` (2) | 3.9 | 28 | 7.2x |
| `Bit` | 2.0 | 11 | 5.5x |

`Bit` at 11 GB/s is 88 billion values per second, about 22 per cycle.

The benchmark's own consumer had the same problem: summing every `UInt16` into a 64-bit total made the
widening, not the reading, the bottleneck. Summing in the value's own width took `Byte2` from 37 to
75 GB/s.

**What stops the vectorizer** (each found by reading the assembly, then confirmed with a benchmark):

| Pattern | Why | Fix |
|---|---|---|
| A lookup at a computed index (`table[Int(x)]`) | Each lane needs a different address: a *gather*, which NEON can't do | Compute the value instead (section 9, Base64) |
| `if`s or ternaries in the body | LLVM may turn them into branches | Arithmetic masks |
| An early exit (`return` inside the loop) | LLVM doesn't vectorize loops with data-dependent exits | Explicit SIMD (section 7) |
| 128-bit arithmetic | Not vectorized | Split into two 64-bit halves (`Byte9`–`Byte15`: scalar → vectorized) |
| Two 64-bit lanes | LLVM's cost model judges it not worth it, and Swift has no loop pragmas to override it | Accept it: `Byte8` and `Byte16` stay scalar, yet `Byte8` still reaches 75 GB/s |
| A value kept in memory | Every iteration stores and reloads it | Section 4 |

The branch case deserves its own example. Base64 maps 6-bit values to characters by range:

```swift
// Stayed scalar in the package build: LLVM saw that the range tests are correlated (a value of
// at least 62 is at least 52) and threaded them into branches.
func character(_ v: UInt8) -> UInt8 {
    if v < 26 { return v &+ 65 }        // A–Z
    if v < 52 { return v &+ 71 }        // a–z
    if v < 62 { return v &- 4 }         // 0–9
    return v == 62 ? 43 : 47            // + /
}

// Vectorized: masks can't become branches. 0xFF where v >= bound, else 0.
func mask(_ v: UInt8, atLeast bound: UInt8) -> UInt8 { 0 &- ((v &+ (128 &- bound)) &>> 7) }
func character(_ v: UInt8, _ deltas: (UInt8, UInt8)) -> UInt8 {
    v &+ 65 &+ (mask(v, atLeast: 26) & 6) &+ (mask(v, atLeast: 52) & 181)
        &+ (mask(v, atLeast: 62) & deltas.0) &+ (mask(v, atLeast: 63) & deltas.1)
}
```

The branching version vectorized in a one-file test and not in the package build: the optimizer's
decisions depend on context, so check the build you ship.

## 7. Write SIMD yourself with `SIMD16`

When the vectorizer can't help (searches, early exits), Swift's `SIMD16<UInt8>` writes NEON directly.
Two patterns from Bytes:

**Searching 16 positions at once.** Finding a zip file's end-of-directory signature means scanning
backwards for 4 bytes. The scalar loop compares at each offset and exits on a match, which LLVM won't
vectorize. The SIMD version tests 16 candidate offsets per step by comparing the pattern's first byte
against 16 loaded bytes, and its last byte against 16 bytes loaded 3 later, then checks only offsets where
both match:

```swift
// 33 µs to search 64 KB: one load and compare per offset.
for offset in stride(from: last, through: 0, by: -1)
where span.load(fromByteOffset: offset, as: UInt32.self) == signature { return offset }

// 2.3 µs (15x): 16 offsets per ~9 instructions.
let head = SIMD16<UInt8>(repeating: pattern[0]), tail = SIMD16<UInt8>(repeating: pattern[3])
let starts = loadUnaligned(at: offset, as: SIMD16<UInt8>.self)
let ends = loadUnaligned(at: offset + 3, as: SIMD16<UInt8>.self)
let candidates = (starts .== head) .& (ends .== tail)
if any(candidates) { /* check each candidate */ }
```

This is the "first and last byte" filter from [Wojciech Muła's SIMD string
search](http://0x80.pl/articles/simd-strfind.html).

**Lane tests from arithmetic.** With Swift 6.4, the standard library's lane comparisons (`.==`, `.>=`)
can compile one lane at a time, and `any()` is an out-of-line call (Swift 6.5 fixes both). Bytes'
`ByteLanes` builds its tests from wrapping arithmetic and bitwise operations instead, which always compile
to a few NEON instructions:

```swift
// High bit set in each lane equal to `byte`: x - 1 & ~x has its high bit set exactly when x is 0.
func matching(_ byte: UInt8) -> ByteMatches {
    let difference = vector ^ SIMD16(repeating: byte)
    return ByteMatches(highBits: (difference &- 1) & ~difference)
}
// Any lane matched: OR the two 64-bit halves, instead of a reduction across lanes.
var any: Bool {
    let words = bitCast(highBits & 0x80, to: SIMD2<UInt64>.self)
    return words[0] | words[1] != 0
}
```

MQTT uses this to validate topic names in one pass: UTF-8 validity (ASCII is valid UTF-8 as it is, so
`nonASCII` is the high bit of each lane) plus the bytes MQTT forbids (`0`, `+`, `#`), 16 bytes per step with
an overlapping last block. A 32-byte topic takes two steps of 9 vector instructions, inlined, instead of an
out-of-line standard-library validation call plus a second scan.

## 8. Reach instructions Swift can't express

Some NEON instructions do in one step what takes a dozen otherwise, and Swift has no way to emit them:
there are no intrinsics, the compiler's `Builtin` module doesn't expose CPU-specific ones, and
`SIMD16`'s dynamic subscript (`v[i]` with `i` a vector) compiles a lane at a time. The fix is a small C
target of `static inline` functions over vector types that Swift imports as `SIMD16<UInt8>`. Swift
inlines C `static inline` functions, so each call becomes the single instruction:

```c
// CBytesNEON.h
typedef uint8_t bytes_u8x16 __attribute__((ext_vector_type(16)));   // imported as SIMD16<UInt8>
static inline __attribute__((always_inline))
bytes_u8x16 bytes_lookup4(bytes_u8x16 indices, bytes_u8x16x4 table) {
    return (bytes_u8x16)vqtbl4q_u8(table, (uint8x16_t)indices);       // one `tbl`
}
```

Three instruction families were worth this:

- **`tbl`: table lookup.** Each lane of an index vector selects a byte from a table of up to 64 bytes (four
  registers). It's a gather within registers: 16 lookups in one instruction. Bytes uses it to pack and
  unpack 3-, 5-, 6-, and 7-byte values (bulk reads 1.8–2.5x faster, writes 1.3–2.4x), and Base64 to map
  6-bit values to characters. Behind the `NEONShuffle` package trait (SE-0450), with a portable fallback.
- **`zip`: interleave.** `zip1`/`zip2` merge two vectors lane by lane (a0 b0 a1 b1 …). Swift's lane
  initializers for zip patterns do compile to `zip`, but see the catch below.
- **`pmull`, `eor3`, `crc32x`: CRC.** Carry-less multiplication and three-way XOR fold 128 bytes of CRC
  per step (section 9).

**The catch: LLVM merges shuffles it can't then build.** Interleaving four vectors takes two rounds of
`zip`s. LLVM's instruction combiner merged the two rounds into four-vector shuffles, which ARM64 can only
build one lane at a time: 1 `zip` and 14 lane inserts per vector instead of 2 `zip`s. Even in C. An empty
inline-assembly statement between the rounds hides the first round's results from the combiner:

```c
uint8x16_t ab0 = vzip1q_u8(a, b), ab1 = vzip2q_u8(a, b);
uint8x16_t cd0 = vzip1q_u8(c, d), cd1 = vzip2q_u8(c, d);
__asm__("" : "+w"(ab0), "+w"(ab1), "+w"(cd0), "+w"(cd1));   // emits nothing; blocks the merge
result.v0 = vzip1q_u16(ab0, cd0);  // …
```

Two other Swift patterns produced the same lane-by-lane inserts: choosing a zip pattern with a `Bool`
parameter, and building a constant vector from an array literal and then changing lanes. `Tools/loops`
flags all of these as `+lane-moves`.

**When not to shuffle.** Unpacking 3-byte values with `tbl` and then calling the loop body once per lane
was 5x *slower* than the plain loop, which LLVM had already vectorized together with the body using `ld3`.
A specialized instruction only helps if the code around it stays vectorized.

## 9. Case studies

### Base64: 0.86 → 21.4 GB/s

Encoding takes 3 input bytes, splits them into four 6-bit values, and maps each to a character.

| Step | 1 MB | Instructions per 4 MB |
|---|---|---|
| Scalar table loop (the usual implementation) | 0.86 GB/s | 16 per byte |
| Character computed with masks; LLVM vectorizes with `ld3` … `st4` | 9.0 | 6.9 M |
| 48-byte blocks with 11 `tbl` lookups each | 19.1 | 5.0 M |
| Blocks as typed-span elements: bounds checks fold | 18.9 | 2.2 M |
| Interleave with `zip`s instead of 4 lookups | 21.7 | 2.8 M |
| Short inputs as one padded block; table built with one initializer | 21.0 | 2.8 M |

The final kernel, per 48-byte block:

```swift
let source = bitCast(block, to: InlineArray<3, SIMD16<UInt8>>.self)
let (first, second, third) = ByteLanes.deinterleave(source[0], source[1], source[2])   // as `ld3`
let (c0, c1, c2, c3) = ByteLanes.interleave(                                            // `zip`s
    ByteLanes(first &>> 2).lookup(in: table),                                           // `tbl`
    ByteLanes((first &<< 4 | second &>> 4) & 0b11_1111).lookup(in: table),
    ByteLanes((second &<< 2 | third &>> 6) & 0b11_1111).lookup(in: table),
    ByteLanes(third & 0b11_1111).lookup(in: table))
```

It runs 32 instructions per 48 bytes at about 9 cycles per block, 6.5x Foundation's
`base64EncodedData()`, with zero allocations at every size. A C kernel using `ld3` and `st4` directly (load
and store instructions that deinterleave and interleave in the memory units, which Swift can't emit for
explicit vectors) reaches 23.1 GB/s; the Swift version is at 93% of it, and level with C of the same design.
The limit is `tbl` throughput: cutting instructions 2.3x didn't change the speed; replacing 4 lookups with
8 `zip`s gained 12%.

### CRC-32: 1.7–2.3x zlib

A CRC is a remainder of polynomial division, computed byte by byte with a table, or 8 bytes at a time with
8 tables ("slicing-by-8"). Two lessons:

- **The table version, rewritten with Bytes' own APIs** (byte-wise `^` on a `Byte8`, a byte subscript
  instead of shifts and masks), halved its instructions (336 M → 180 M) and ran 27% faster on 64-byte
  inputs, but equal on long ones: those are bound by the latency of each lookup feeding the next, not by
  instruction count.
- **The hardware version** keeps eight 16-byte accumulators and folds 128 bytes per step with carry-less
  multiplies (`pmull`, `pmull2`) and three-way XORs (`eor3`): eight independent dependency chains, so the
  multiplies' latency overlaps. Below 256 bytes it uses the CPU's `crc32x` instruction, 8 bytes at a time.
  Result: 63 GB/s on large inputs, 1.7x zlib's `crc32`, and 2.3x on 64-byte inputs. The first version was
  3.5x *slower* than zlib, because a nested helper that loaded each 16 bytes wasn't inlined, and each call
  spilled the eight accumulators; `@inline(always)` fixed it.

See Intel's [Fast CRC Computation Using
PCLMULQDQ](https://www.intel.com/content/dam/www/public/us/en/documents/white-papers/fast-crc-computation-generic-polynomials-pclmulqdq-paper.pdf)
for the folding math.

### DEFLATE: from 2x slower than zlib to faster

The zip decoder's DEFLATE implementation, on Bytes' `BitBuffer`, `HuffmanTable`, and `BytesWriter`, decodes
32 MB of text in 13 ms against zlib's 14, with zero allocations. In order of payoff:

1. **Inlining** (section 4): the guaranteed `@inline(always)`, and small functions with their own local bit
   buffer and writer.
2. **A branch-free refill.** The bit buffer holds 64 bits in a register. Refilling is one unaligned 8-byte
   load and a few arithmetic instructions, no loop and no branch on how many bytes fit; past the end it
   reads zeros, and the overrun is reported once per block instead of checked per symbol.

   ```swift
   _bits |= UInt64(littleEndian: raw) &<< shift      // raw: the next 8 bytes, one load
   _nextByte &+= (63 &- _count) &>> 3                // advance by the whole bytes that fit
   _count |= 56                                      // now 56 + count % 8 bits
   ```
3. **A better table builder** ([libdeflate](https://github.com/ebiggers/libdeflate)'s): each entry written
   once, then doubled with `memcpy`. Building tables had been 11% of small-file time.
4. **A shorter critical path.** The next symbol's table entry is looked up before the current one is used,
   so the lookup's latency overlaps the work.
5. **Copies that may overrun.** Back-references copy 16 bytes at a time and may write up to 32 bytes past
   the end, kept free by the loop condition, instead of an exact byte loop.

## 10. Smaller lessons

**Constants: write them as literals.** `static let signature = Byte4(0x504B_0102, .bigEndian)` compiles to a
lazily initialized global: a `swift_once` check and a load on every use. The compiler's compile-time
evaluator can't fold a byte swap. The integer-literal initializer reverses the bytes with shifts instead,
which it can fold:

```swift
static let signature = Byte4(0x504B_0102, .bigEndian)   // swift_once on every use: +41% instructions
static let signature: Byte4 = 0x50_4B_01_02             // folded to a constant (mov/movk)
```

**Big enums are expensive to pass around.** MQTT's `MQTTPacket` enum is 153 bytes, so it's returned in
memory, and each test of its case is a call to an outlined "get tag" function; writing a packet tested
its case five times. Giving each packet type its own `init(parsing:)` and `write(to:)`, and dispatching on
the frame's type before building anything, made encoding 68% faster and parsing 58% faster:

```swift
// Before: build the enum, then switch on it.
if case .publish(let publish) = try MQTTPacket.read(from: &reader) { … }

// After: read the fixed header, dispatch, build only what's needed.
guard let frame = try MQTTFrame.read(from: &reader, maximumPacketSize: limit) else { return }
if frame.type == .publish { let publish = try MQTTPublish(parsing: frame) … }
```

**Concurrency: `nonisolated(nonsending)` (SE-0461).** A plain `nonisolated` async function calls into the
runtime (`swift_task_switch`) on entry and after each call it makes, to make sure it runs on the generic
executor, even when it already does. Over a socket transfer that was 2.5 runtime calls per socket
operation. As `nonisolated(nonsending)`, the functions run on their caller's executor and make none (0.9
remained, in the standard library's continuation).

**Many small writes of bits can't be fast; pack first.** Each bit write merges with the partly written
byte before it, a dependency chain through memory. The bulk writer packs a byte (or 8 values) at a time:
110x faster for 4-bit values.

**Zero-copy typed spans are only as fast as their element loads.** `read(InlineArray<4, UInt8>.self, count:)`
returns a typed view of the input with no copy, and iterating it runs at memory speed. For 6- or 16-byte
elements it's 3–4x slower than `forEach`, because `Span`'s subscript loads an `InlineArray` element byte by
byte and LLVM only merges those for 4 bytes. Bytes' own loads reinterpret a same-size integer load with
`bitCast` instead.

**Hints help less than you'd think, and measure them.** `likely`/`unlikely` branch hints saved 14% of
instructions in bit-field parsing at no change in time; kept. `@frozen` changed nothing outside a binary
framework; removed. Padding CRC tables apart to avoid cache conflicts changed nothing.

## 11. Limitations and bugs found in Swift and LLVM

Found with Swift 6.4.2 (Xcode 27.3) unless noted. Two were written up as bug reports with reproducers.

| Issue | Effect | Workaround |
|---|---|---|
| **`for x in letReader`** over a `~Copyable` `let` keeps it in a heap box: the iterator's lifetime dependence is placed on the box, and `AllocBoxToStack` treats that as an escape (report 22; related: swiftlang/swift#93942) | One allocation per loop | Declare the cursor `var`, or take it `borrowing` |
| **`~Escapable` structs with more than 6 fields** are destroyed at `-O` even when every field is trivial; from another module, through an indirect call to a no-op in the type's value witness table (report 24) | 2.5–3% of MQTT's per-packet time; a third of a tight loop | None from the library side |
| **`SIMD16` lane comparisons and `any()`** compile a lane at a time, and `any()` out of line (fixed in 6.5) | Scalar "vector" code | Wrapping arithmetic (section 7) |
| **No CPU intrinsics** in Swift: no `tbl`, `ld3`/`st4` on explicit vectors, `pmull`, `crc32`; `SIMD16`'s dynamic subscript and swizzles compile a lane at a time | Byte shuffles 0.3 GB/s in Swift against 16.7 with overlapping stores | A C target of `static inline` wrappers |
| **LLVM merges consecutive shuffles** into ones ARM64 builds lane by lane (also from a `Bool`-selected pattern, or a literal mutated per lane) | 14 inserts per vector | Empty `asm` between rounds, in C |
| **LLVM threads correlated conditions into branches**, then won't vectorize | Scalar loop | Arithmetic masks |
| **Two-lane 64-bit loops and 128-bit arithmetic** aren't vectorized, and Swift has no loop pragmas | `Byte8`, `Byte16` scalar | Split 128-bit values into halves |
| **`Builtin.assume(offset >= 0)`** stops loops vectorizing | 14 against 113 GB/s | Leave that assumption out |
| **`@inline(__always)` is a hint**; LLVM's inliner refused it in a large function | 2x slower DEFLATE | `@inline(always)` (SE-0496) |
| **Compile-time evaluation can't fold a byte swap**, so a `static let` built with one stays lazily initialized | `swift_once` per use, +41% instructions | Literals that shift instead of swap |
| **The standard library's span bounds check** needs `offset >= 0`, so it doesn't fold into a cursor's own check; no safe in-place copy, no safe view of an `OutputSpan`'s capacity | Checked loads 24% to 8x slower | Unchecked loads behind the cursor's check |
| **`Span` element loads** of `InlineArray<N, UInt8>` go byte by byte except for N = 4 | Typed spans 3–4x slower for 6 and 16 bytes | `forEach` with integer loads and `bitCast` |
| **`for x in reader.values(...)`** with a temporary, like the standard library's own `for x in array.span`, is rejected: "lifetime-dependent variable escapes its scope" | Doesn't compile | Bind the view to a `let` first |
| **Closures can't return lifetime-dependent values**, so a `switch` can't wrap its cases in closures to outline them | Doesn't compile | Per-case functions |
| **User types can't conform to `ConvertibleFromBytes`** | No direct loads of custom types | `ByteRepresentable` over `InlineArray` storage |
| **Swift Testing's `#expect`** can't inspect a `~Copyable`, `~Escapable` value | Doesn't compile | Copy the property to a local |
| **package-benchmark thresholds for names with spaces** are written under one name and looked up under another (ordo-one/package-benchmark#373) | A check that silently doesn't run | Names without spaces |

## 12. Glossary

- **Auto-vectorization**: the compiler rewriting a loop to use SIMD instructions on several elements per
  iteration.
- **Bounds check**: a test that an index or offset is within a buffer, with a trap or throw if not.
- **Branch prediction**: the CPU guessing a branch's direction to keep working; a wrong guess costs ~15
  cycles.
- **Byte order (endianness)**: whether a multi-byte integer is stored least significant byte first
  (little-endian, Apple's CPUs) or most significant first (big-endian, most network formats). Converting is
  a byte swap (`rev` on Arm), one instruction.
- **Cache, cache line**: small fast memories between the core and main memory (L1, L2), filled in fixed
  blocks called cache lines: 128 bytes on Apple silicon.
- **Carry-less multiplication**: multiplication of bit strings with XOR instead of addition; the core of
  fast CRCs and some hashes (`pmull` on Arm, `pclmulqdq` on x86).
- **Critical path**: the longest dependency chain in a loop; it sets the minimum time per iteration.
- **Cycle**: one tick of the CPU's clock, ~0.25 ns here.
- **Dependency chain**: instructions that each need the previous one's result, so they can't overlap.
- **Gather**: loading each lane from a different, computed address. NEON has no gather instruction for
  memory; `tbl` is a gather from registers.
- **Inlining**: replacing a call with the called function's body, which lets the optimizer see through
  it. **Outlining** is the reverse: moving code into a separate function, often to save size.
- **Instruction-level parallelism, IPC**: how many instructions a core completes per cycle; up to ~8 here
  when instructions are independent.
- **Lane**: one element slot of a vector register: 16 byte lanes, 8 16-bit lanes, and so on.
- **Latency vs throughput**: latency is how long one instruction takes to produce its result; throughput
  is how many of it the core can start per cycle. A dependency chain is latency-bound.
- **Memory bandwidth**: bytes per second from main memory: ~77 GB/s for one core here, ~245 GB/s for all.
- **NEON**: Arm's 128-bit SIMD instruction set.
- **Prefetching**: the CPU loading cache lines before they're asked for, when it detects a pattern.
- **Register**: a storage slot inside the core; the only place instructions operate on directly.
- **SIMD**: Single Instruction, Multiple Data: one instruction operating on every lane of a vector.
- **Shuffle (permute)**: rearranging the lanes of one or more vectors: `tbl`, `zip`, `ld3`/`st4`.
- **Spill**: storing a register's value to the stack because the compiler ran out of registers or needed
  its address.
- **Store-to-load forwarding**: the CPU handing a just-stored value to a following load from the same
  address; faster than memory, slower than a register.
- **Structure loads and stores (`ld3`, `st4`)**: Arm instructions that load or store several registers
  interleaved: `ld3` puts bytes 0, 3, 6 … in one register, 1, 4, 7 … in the next.
- **SWAR**: SIMD Within A Register: treating a 64-bit integer as 8 byte lanes with ordinary arithmetic.
- **Value witness table**: per-type table of functions (copy, destroy, …) Swift uses to handle values of
  a type it doesn't know statically, such as from another module without inlining.

## 13. Further reading

- Swift: [SE-0446 Nonescapable types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md),
  [SE-0447 `Span`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md),
  [SE-0453 `InlineArray`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md),
  [SE-0461 `nonisolated(nonsending)`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md),
  [SE-0496 `@inline(always)`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0496-inline-always.md).
- [Apple Silicon CPU Optimization Guide](https://developer.apple.com/documentation/apple-silicon/cpu-optimization-guide):
  Apple's own description of its cores, caches, and what code they like.
- [Arm NEON intrinsics reference](https://developer.arm.com/architectures/instruction-sets/intrinsics/):
  every instruction used here, with diagrams.
- [LLVM's auto-vectorizers](https://llvm.org/docs/Vectorizers.html): what the loop vectorizer handles.
- [What Every Programmer Should Know About Memory](https://people.freebsd.org/~lstewart/articles/cpumemory.pdf)
  (Ulrich Drepper): caches and memory, in depth.
- [Faster Base64 Encoding and Decoding Using AVX2 Instructions](https://arxiv.org/abs/1704.00605)
  (Muła, Lemire) and [Validating UTF-8 In Less Than One Instruction Per Byte](https://arxiv.org/abs/2010.03090)
  (Keiser, Lemire): the SIMD techniques behind Base64 and fast text validation.
- [Dougall Johnson's Apple M1 instruction tables](https://dougallj.github.io/applecpu/firestorm.html):
  latency and throughput of each instruction on Apple's cores.
