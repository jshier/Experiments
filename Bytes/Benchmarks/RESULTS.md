# Bytes performance log

Medians (p50) from `swift package --disable-sandbox benchmark`, M3 Ultra, macOS 27.2, Swift 6.4.2.
Baselines are in `.benchmarkBaselines/` (the latest full run is `reviewed`); compare any two with
`swift package --disable-sandbox benchmark baseline compare <a> <b> | python3 -I ../NativeZipArchive/Benchmarks/summarize.py`.

## Current: Bytes against the alternatives (same harness, same run; baseline `reviewed`)

| Workload | Bytes | Comparator | |
|---|---|---|---|
| Zip central directory, 2,000 entries (~170 KB) | **9.3 µs**, 291 K instr | original `ByteReader`: 19 µs, 259 K instr | 2x faster |
| | fixed-size-record style: 11 µs, 253 K instr | hand-written `RawSpan.load` offsets: 16 µs, 317 K instr | 1.5x faster |
| Bit fields, 8 fields of 1–32 bits per record, 128 KB | **37 µs**, 706 K instr | 64-bit refill-buffer reader: 300 µs, 8,180 K instr | 8x faster |
| Find a 4-byte signature 64 KB back (zip EOCD worst case) | **2.3 µs**, 50 K instr | `RawSpan.load` per offset: 33 µs, 787 K instr | 15x faster |
| 256 K big-endian `UInt32`s | 18 µs | `RawSpan.load` per value: 18 µs | equal (all vectorize) |
| 349 K big-endian 24-bit values (`Byte3`) | 54 µs | — | vectorized (`ld3`) |

Field-by-field parsing uses more instructions than at v3 (291 against 263 K) because one `assume` was
dropped so that loops of reads vectorize (see "Making loops of single reads vectorize"); wall time is
unchanged.

No benchmark allocates, apart from the output array in the bulk ones.

## Writing (`BytesWriter`)

`BytesWriter` mirrors `Bytes`: `write` for `Bits`, byte groups with a byte order, `ByteRepresentable` types,
raw-value types, and spans, `store` for standard library types (native order), and bulk writes from spans
or from a closure (`write(Byte4.self, .bigEndian, count: n) { index in … }`, the counterpart of `forEach`).
It writes into a `MutableRawSpan`, or into uninitialized memory with `output.withBytesWriter { … }` on
`OutputSpan<UInt8>` / `OutputRawSpan`. Every store stays within the bytes being written (odd widths use
two overlapping stores of the next size down, mirroring the loads), so it never touches memory past its
cursor; a throwing write writes nothing.

### Should reading and writing share one type? No.

A combined reader/writer has to hold the memory exclusively (`MutableRawSpan`), so any span it hands out
can only borrow the cursor itself, not the memory. That breaks the fixed-size-record idiom: with a
prototype, `let header = cursor.read(byteCount: 4)` followed by another read from `cursor` is a compile
error ("overlapping accesses to 'cursor'"), while the same code with `Bytes` compiles. Reading through a
`MutableRawSpan` would be no faster either: the loads are identical. So `Bytes` reads shared memory and
hands out spans that outlive it; `BytesWriter` writes exclusive or uninitialized memory. Patching data in
place is a `Bytes` pass and a `BytesWriter` pass over the same memory, one after the other.

### Write bandwidth (GB/s, p50; baseline `writes4`)

Values are generated from their index (a cheap hash), so no memory is read. The ceiling is `memset`.

| Width | In cache | Memory, 1 core | Memory, 32 cores |
|---|---|---|---|
| `memset` (reference) | 125 | 120 | 241 |
| Raw SIMD store (reference) | 116 | 116 | 239 |
| `IPv4Address` (custom, 4 bytes) | 108 | 104 | 239 |
| `Byte2`, `Byte4` | 89 | 85–88 | 239–241 |
| `Byte` / `Nibble` / `Crumb` / `Bit` | 74 / 45 / 18 / 10 | 75 / 44 / 18 / 11 | 231–241 |
| `Byte16` | 73 | 73 | 239 |
| `Byte8` | 36 | 37 | 239 |
| `Byte10`, `Byte12`, `Byte14` | 34–47 | 34–45 | 210–219 |
| `Byte3`, `Byte5`–`Byte7`, `Byte9`, odd `Byte11`–`Byte15` | 16–30 | 15–29 | 213–238 |
| `Bits<3>`, `Bits<5>`–`Bits<7>` | 2.7–3.8 | 2.8–3.9 | 65–87 |
| Per-value loops: `Byte4` / `IPv4Address` / `Byte16` / `Byte` | 87 / 104 / 75 / 55 | 87 / 107 / 69 / 54 | — |
| Per-value loop: `Nibble` (bits one at a time) | 0.4 | 0.4 | — |

- Power-of-two widths and 4-byte custom types write at or near one core's ceiling, and all byte groups
  plus `Bit`/`Crumb`/`Nibble`/`Byte` reach the all-core ceiling (210–241 GB/s).
- Plain loops of single writes vectorize when the writer is a local, like reads.
- Writing bits one at a time can't be fast: each write merges with the byte the previous one left partly
  written. The generating bulk write packs a byte (or 8-value block) at a time instead: 110x faster for
  nibbles.
- Odd widths are compute-bound on one core, like reads. Making them memory-bound needs byte shuffles
  (NEON `tbl`), which Swift can't express: the standard library's SIMD swizzle compiled to a scalar loop
  (0.3 GB/s in a test, against 16.7 for overlapping stores), and `Builtin` doesn't expose target-specific
  intrinsics. A C module with NEON intrinsics in `static inline` functions would.
- `Byte8` is scalar for the same cost-model reason as `Byte16` reads (two 64-bit lanes).

Fixes found while measuring (all in `BytesWriter`):
- The unaligned slow path was a `mutating` method; like the reader's early version, that kept the writer
  in memory in every caller and blocked vectorization. Now `static`, taking and returning the position.
- Bit writes reloaded the partly written byte from memory (store-to-load forwarding on every write); the
  writer now keeps it in a register.

Harness lessons: the first runs measured the benchmark, not the writer. Index-derived values folded into
repeating patterns (`Bit` writes became a constant fill), a 64-bit multiply in the value generator doesn't
vectorize, and passing the writer `inout` to an inner closure let the compiler merge the outer closures into
one thunk that called the inner one indirectly (0.6 GB/s for byte writes, against 54 with a local writer).

## Convenience APIs

`Bits` values have `value[bit: i]` (get and set, bit 0 the least significant), `toggleBit(at:)`,
`nonzeroBitCount`, shifts, compound bitwise operators, and conversions between widths. `Byte`, `Nibble`,
and `Crumb` have `highHalf`/`lowHalf` (get and set) and `init(highHalf:lowHalf:)`; even-width byte groups
have `lowHalf`/`highHalf` in memory order (like SIMD) and settable bytes. Enums and other `RawRepresentable`
types with integer raw values read from and write to bit fields or byte groups
(`reader.read(QualityOfService.self, as: Crumb.self)`), throwing `.invalidValue` for undefined values.
They compile to what you'd write by hand: setting a nibble half is `and` + `orr`, setting or toggling a bit
one `orr`/`eor`, a `Byte4` half one `lsr`.

## NEON byte shuffles (`NEONShuffle` trait, CBytesNEON C module)

3-, 5-, 6-, and 7-byte groups can't use contiguous vector loads and stores: each value straddles lanes.
NEON's table lookup (`tbl`, up to 64 bytes of table per instruction) packs and unpacks them, but Swift
can't reach it: the standard library's SIMD swizzle compiled to a scalar loop, and `Builtin` doesn't expose
CPU-specific intrinsics. So a small C target, CBytesNEON, wraps `vqtbl1q_u8`–`vqtbl4q_u8` in `static
inline` functions over a vector type Swift imports as `SIMD16<UInt8>`; Swift inlines each to a single
`tbl.16b` instruction. Other CPUs get a portable fallback with the same results. It's behind the
`NEONShuffle` package trait, on by default (`--disable-default-traits` turns it off; the 36 tests pass
both ways).

Values travel in 32-bit lanes (3-byte groups, 16 per step) or 64-bit lanes (5–7 bytes, 8 per step), so a
step is always 64 bytes of lanes: one 4-register table. Packing turns them into the step's 48, 40, 48, or
56 bytes with 3–4 lookups; unpacking does the reverse, and the index vectors apply the byte order, so
big-endian is free. Reads take the shuffle path only while 64 bytes remain (each step loads 64 bytes), and
the existing loops finish the tail.

Trait on against off, same session (GB/s, one core, from memory; baselines `neon-on`, `neon-off`):

| Workload | Off | On |
|---|---|---|
| Bulk read `read(_:_:into:)`, big-endian `Byte3` | 19 | **47** (2.5x) |
| … `Byte5` / `Byte6` / `Byte7` | 21 / 26 / 29 | **42 / 50 / 51** (1.8–2x) |
| Generating write, big-endian `Byte3` | 19 | **46** (2.4x) |
| … `Byte5` / `Byte6` / `Byte7` | 16 / 19 / 21 | **23 / 29 / 28** (1.3–1.5x) |
| `forEach` / `for`-`in` over `Byte5`–`Byte7` | — | −41 to −49% instructions, up to 12% faster |

With all cores, the 5–7-byte writes now reach the memory ceiling (2.25 ms per 512 MB, from 2.5).

Where it isn't used:
- `forEach` over `Byte3`. Its plain loop already vectorizes with `ld3` together with the caller's body;
  unpacking first and calling the body once per lane kept the body scalar: 5x slower, measured. For 5–7
  bytes, whose plain loop barely vectorizes, unpacking still wins, but the per-lane body calls cap it.
- 9–15 bytes: a step's lanes span more than 64 bytes, so each output would need two lookups and a merge.
- Writes of 5–7 bytes are limited by building 64-bit lanes from the generated values (two per vector),
  not by the lookups.

## Review (baseline `reviewed`)

An independent review brute-forced the bit paths (every `read(bitCount:)` count 0–64 at every bit offset on
1–40-byte spans, every `write(_:bitCount:)` round trip, `Byte16` search from every start, exact-capacity
writes) with no mismatches, and checked each `Builtin.assume` against every path that moves the offsets.
It found, and these are fixed with regression tests:

- Force-unwrapped base addresses of empty spans with no memory: writing `Data().span` and bulk reads into
  an empty `OutputSpan()` trapped. (Also `Span(viewing:)` checks alignment even for an empty span, so a
  zero-count typed view now returns `Span()`.)
- A zero-size `RawBytes` divided by zero (now a precondition that folds away).
- The 9–15-byte custom-type load assumed a little-endian host (now `#if _endian(little)`).
- Bit iteration starting mid-byte never returned to the block path; it now reads single values until a
  byte boundary. Doing that for whole bytes (which never realign) cost `for`-`in` over `Byte` 30% just by
  being in the code, so it's compiled out for width 8.
- Policy: values too large for the field they're written as now assert in debug builds and truncate in
  release (bulk writes truncate without the check, which would stop their loops vectorizing).
- A stale comment, missing invariant hints on a few entry points, the writer's 56- vs reader's 57-bit split.

Kept as is, deliberately: `forEach` consumes while `for`-`in` doesn't (now documented on both: the cursor
must be a `var` to call it, so the mutation is visible), and `read(_:count:) -> Span<T>` keeps the `read`
verb, matching `read(byteCount:) -> RawSpan`.

Instruction counts are identical before and after across every read, field-parsing, and bandwidth
benchmark; wall times are within run-to-run noise.

## Custom byte-backed types (`ByteRepresentable`)

Types like an IPv4 address backed by `InlineArray<4, UInt8>` conform by exposing `rawBytes` and
`init(rawBytes:)`. Swift 6.4 doesn't let user types conform to `ConvertibleFromBytes`, so they can't be
loaded from raw memory directly; their `RawBytes` (`InlineArray<N, UInt8>`) can. Reading one is a bounds
check, one load, and `init(rawBytes:)`, which compiles away when it only stores its argument.

The loads matter, measured case by case (baselines `ipv4`, `vectorized`, `final3`):

- Loading `InlineArray<4, UInt8>` as itself compiles to four `ldrb`s plus repacking. Sizes 1, 2, 4, 8,
  and 16 are now loaded as the same-size integer and reinterpreted with the standard library's `bitCast`
  (free: a size precondition that folds, then `Builtin.reinterpretCast`): one `ldr`, the same instructions
  as reading a raw `Byte4`.
- 9–15 bytes: two overlapping 64-bit loads into a `UInt128`, reinterpreted through memory. 62 GB/s, against
  24 for a direct load of a 12-byte type.
- 3 and 5–7 bytes: a direct load. The same trick through a narrower integer measured slower (14 against
  31 GB/s for 6 bytes): its stack slot stayed in the loop. Vector-instruction counts said otherwise;
  benchmarks decided.

| Custom type (1 core, GB/s: in cache / memory) | Custom | Same bytes as a raw `ByteGroup` |
|---|---|---|
| IPv4, 4 bytes, `forEach` | 114 / 78 | 99–113 / 78 |
| IPv4, a loop of `read(IPv4Address.self)` | 113 / 78 | 113 / 78 |
| IPv4, naive: four `read(Byte.self)` into an `InlineArray` | 3.7 / 3.7 | — |
| IPv6, 16 bytes, `forEach` | 111 / 74 | 112 / 74 |
| MAC, 6 bytes, `forEach` | 31 / 31 | 28 / 29 |
| 12 bytes, `forEach` | 61 / 58 | 59 / 58 |
| 3 bytes, `forEach` | 11 / 11 | 11 / 11 |

Every custom size parses at the speed of its raw bytes, and the 4-, 8-, and 16-byte ones at memory speed.

### Making loops of single reads vectorize

A plain loop of `read` calls (`while reader.remainingByteCount >= 4 { … try reader.read(…) … }`) was
scalar, 14 GB/s, for raw `Byte4` and `IPv4Address` alike. Cause: one of the four `Builtin.assume`
invariants, `_byteOffset >= 0`, stops LLVM from vectorizing such loops (tested one at a time; the other
three don't). Dropping it: those loops vectorize (14 → 113 GB/s in cache), at the cost of 11% more
instructions in the zip-header field parser (263 → 291 K; wall time within noise; the fixed-size-record
style unchanged at 253 K).

Also from the assembly review:
- `forEach` is now `@inline(__always)`. For `Byte16` (the largest body) the optimizer had outlined it into a
  closure-specialized function, which keeps the closure's captured variables in memory (a store every
  iteration) and blocks vectorization. Force-inlining keeps them in registers.
- `Byte16` keeps a single 128-bit load. Building it from 64-bit halves, as for 9–15, made big-endian
  `Byte16` loops fully scalar (32 against 56 GB/s). Its loop stays scalar either way, because LLVM's cost
  model declines two-lane 64-bit vectors when the scalar loop (`ldp`, two `rev`, two `add`) is that
  short, and Swift has no loop pragmas to override it. It reaches 56 GB/s on one core and the memory
  ceiling with all cores.

## The standard library's `ConvertibleFromBytes`

Only standard library types can conform (integers, `Float16`/`Float`/`Double`, `Duration`, `SIMD2`–`SIMD64`,
and `InlineArray`s of them), but `Bytes` can read those (baseline `zerocopy`):

- `load(_:)`: one value in native byte order (little-endian on Apple), from any offset, e.g.
  `Float`, `SIMD4<UInt8>`, `InlineArray<4, UInt8>`. Same loads as `ByteRepresentable` (integer-sized values
  through `bitCast`). A loop of `load(Float.self)` vectorizes: 99 GB/s in cache, 77 from memory.
- `read(_:count:) -> Span<T>`: a typed view of the input, no copying, via `Span(viewing:)`. It throws
  `.misaligned` where the memory isn't aligned for `T` (a misaligned view traps in the standard library);
  alignment-1 types such as `InlineArray<N, UInt8>` work at any offset.

| 1 core, GB/s (in cache / memory) | Zero-copy span, `for`-`in` | `forEach` | Decoding view, `for`-`in` |
|---|---|---|---|
| `InlineArray<4, UInt8>` | 113 / 76 | 113 / 77 | 42 / 42 |
| … building `IPv4Address(rawBytes:)` per element | 111 / 76 | 113 / 77 | — |
| `UInt32`, aligned | 113 / 77 | 110 / 77 | 42 / 42 |
| `InlineArray<6, UInt8>` | 17 / 17 | 33 / 31 | — |
| `InlineArray<16, UInt8>` | 30 / 32 | 112 / 73 | 33 / 32 |

So a zero-copy span closes the `for`-`in` gap for 4-byte elements (2.7x the decoding view, equal to
`forEach`), but not for 6 or 16: the loop loads each element through `Span`'s subscript as a byte
aggregate, the same problem `Load.rawBytes` solves with `bitCast`, and LLVM only merges those byte loads
for 4 bytes. `Bytes` can't change how `Span` loads its elements; `forEach` stays the path that's at raw
speed for every size.

## `for`-`in` (`Iterable`)

`Bytes` conforms to the standard library's `Iterable` (macOS 27): `for byte in reader` iterates the unread
bytes as one zero-copy `Span<UInt8>`, at 111–113 GB/s in cache and 77–78 from memory, the same as the raw
SIMD read. `reader.values(of: Byte4.self, .bigEndian)` and `reader.values(of: Nibble.self)` return typed
`Iterable` views. Their iterators decode 1,024 (groups) or 4,096 (bits) values at a time into a buffer
they own and hand out a span of it, with the same vectorized decode loop as `forEach`; the loop over
each span vectorizes too.

| 1 core, from memory (GB/s) | `forEach` | `for`-`in` |
|---|---|---|
| `Byte`, `Byte2`, `Byte4`, `Byte8` | 72–77 | 39–54 |
| `Byte3`, `Byte5`–`Byte7` | 19–30 | 15–21 |
| `Byte9`–`Byte16` | 34–56 | 17–31 |
| `Nibble` / `Crumb` / `Bit` | 50 / 27 / 12 | 26 / 12 / 2.7 |

Typed `for`-`in` costs up to 2.5x (4.4x for `Bit`) with a trivial loop body: `Iterable` hands out spans of
elements in memory, so decoded values are stored and reloaded (a 16-byte store per cycle limits it to
roughly 45–60 GB/s), where `forEach` fuses load, decode, and body. The heavier the body, the less it
matters. Raising the span size from 256 values helped the narrow widths (`Byte` 40 → 55, `Nibble` 17 → 25).

Swift 6.4 rejects `for x in reader.values(...)` with a temporary: "lifetime-dependent variable escapes its
scope". The standard library's own `for x in array.span` fails the same way. Bind the view to a `let` first.

## `@frozen`

Removed from every type: it only matters with library evolution (binary frameworks), which SwiftPM
doesn't enable. Instruction counts were identical with and without it; leaving types unfrozen keeps their
layouts free to change until there's an ABI to keep.

## Read bandwidth: every width, 1 bit to 16 bytes

`forEach(_:_:)` iterates every value of a width; `Benchmarks/BytesBenchmarks/Bandwidth.swift` runs it over
4 MB (resident in L2: the code's own ceiling), 512 MB from one core, and 512 MB from all 32 cores (16 chunks
per core, each with its own cursor). Each value is added into a wrapping sum of its own width (two 64-bit
halves for 128-bit values), and byte groups are read as `.bigEndian`, so every value costs a byte swap
and an add. The `Bandwidth (MB/s)` column in the benchmark output is bytes read per second, per iteration.
Baselines: `bandwidth` (first run), `bandwidth2` (final).

### The ceiling

| | Read bandwidth |
|---|---|
| Advertised (M3 Ultra, LPDDR5-6400, 1,024-bit) | 819 GB/s, shared by CPU, GPU, and Neural Engine |
| CPU, measured: 128-byte SIMD loads, 4 GB, 1 thread | 72 GB/s |
| CPU, measured: same, 16–32 threads (saturates at 16) | **245–250 GB/s** |

The CPU clusters' links to the memory fabric cap them at about 30% of the spec-sheet figure (the rest is
there for the GPU), so ~249 GB/s is the "system maximum" a CPU reader can reach, and ~72–77 GB/s is one
core's. Scaling: 1 thread 72, 2 → 133, 4 → 195, 8 → 205, 16 → 245, 32 → 244 GB/s.

### Results (GB/s, p50)

| Width | In cache, 1 core | Memory, 1 core | % of 1-core raw (77) | Memory, 32 cores | % of CPU ceiling (249) |
|---|---|---|---|---|---|
| Raw SIMD read (reference) | 112 | 77 | 100% | 229 | 92% |
| `Bit` | 12 | 11 | 14% | 237 | 95% |
| `Crumb` | 28 | 28 | 36% | 236 | 95% |
| `Bits<3>` | 12 | 12 | 16% | 237 | 95% |
| `Nibble` | 49 | 50 | 65% | 236 | 95% |
| `Bits<5>` | 7.0 | 6.7 | 9% | 157 | 63% |
| `Bits<6>` | 8.4 | 8.3 | 11% | 184 | 74% |
| `Bits<7>` | 9.1 | 9.7 | 13% | 212 | 85% |
| `Byte` | 113 | **77** | **100%** | 235 | 94% |
| `Byte2` | 108 | **75** | **97%** | 235 | 94% |
| `Byte3` | 19 | 19 | 25% | 237 | 95% |
| `Byte4` | 106 | **75** | **97%** | 231 | 93% |
| `Byte5` | 21 | 21 | 27% | 235 | 94% |
| `Byte6` | 26 | 26 | 34% | 236 | 95% |
| `Byte7` | 30 | 30 | 39% | 237 | 95% |
| `Byte8` | 106 | **75** | **97%** | 228 | 92% |
| `Byte9` | 36 | 37 | 48% | 236 | 95% |
| `Byte10` | 34 | 35 | 45% | 238 | 96% |
| `Byte11` | 39 | 39 | 51% | 230 | 92% |
| `Byte12` | 38 | 42 | 55% | 235 | 94% |
| `Byte13` | 44 | 45 | 58% | 238 | 96% |
| `Byte14` | 48 | 48 | 62% | 237 | 95% |
| `Byte15` | 53 | 52 | 68% | 232 | 93% |
| `Byte16` | 54 | 56 | 73% | 235 | 94% |

- **With every core, every width but `Bits<5>`–`Bits<7>` reads at 92–96% of the CPU's memory ceiling**, the
  same as the raw SIMD reference: memory, not decoding, is the limit.
- **On one core, the power-of-two widths (`Byte`, `Byte2`, `Byte4`, `Byte8`) read as fast as raw loads.**
  Everything else is compute-bound on one core (its in-cache speed is no faster than its memory speed):
  odd strides can't use contiguous vector loads, and the bit widths do several operations per value. In
  values per second the bit widths are fast (`Bit` at 11 GB/s is 88 billion values/s, ~22 per cycle), but
  a byte holds 8 of them, so they need ~7 cores to saturate memory.
- `Bits<5>`–`Bits<7>` are the slowest: values straddle bytes irregularly, so they're extracted from 64-bit
  blocks with only two lanes per vector register.

### Vectorization, checked in the assembly

Every width's `forEach` loop vectorizes (probe functions compiled with `swiftc -O -S`, both bit orders).
Getting there took four changes, all in the library:

| Change | Effect (1 core, from memory) |
|---|---|
| `Byte9`–`Byte15` built from two independent 64-bit halves, and a `.bigEndian` for 128-bit groups computed on the halves (now a protocol requirement, so generic code uses it) | were scalar (LLVM doesn't vectorize 128-bit arithmetic); now vectorized with `rev64.16b`/`usra.2d` |
| Bit widths that divide 8 iterate per byte instead of per 8-value 64-bit block: 16 lanes instead of 2 | `Byte` 12 → 77, `Nibble` 6.0 → 50, `Crumb` 3.9 → 28, `Bit` 2.0 → 11 |
| `Bits<3>` blocks as 3 bytes in 32-bit lanes, loaded bytewise: NEON `ld3` de-interleaves 48 bytes at once | 2.6 → 12 |
| Stride-3 groups (`Byte3`) loaded bytewise in streaming loops (`forEach`, `read(_:_:into:)`), also `ld3` | `Byte3` 13 → 19; bulk `Byte3` decode −53% instructions |

Separately, the benchmark's consumer changed from a 64-bit sum to a sum in each type's own width: widening
every `UInt16` to 64 bits made the consumer, not the reader, the bottleneck (`Byte2` 37 → 75 GB/s).

Tried and rejected: loading 5-byte groups bytewise (9.2 GB/s, against 22.5 with overlapping loads: there's
no `ld5`), and 6-byte groups as three 16-bit loads (22 against 27).

## v1: first complete implementation

| Workload | Bytes | Comparator |
|---|---|---|
| Zip fields | 22 µs, 439 K instr | `ByteReader` 19 µs, 283 K |
| Bit fields | 127 µs, 2,378 K instr | buffer reader 317 µs, 8,245 K |
| Search | 2.0 µs | 33 µs |

Assembly review (see "Assembly findings" below) found the two problems behind the field-parsing gap.

## v2: inlining, value-taking slow paths, `Builtin.assume`

- Slow paths (`_unalignedBytes`, `_partialWindow`) take plain values instead of borrowing `self`. Borrowing
  forced every caller to spill the whole 40-byte cursor to the stack to pass its address, even on the
  aligned fast path.
- `read(byteCount:)`, `skip`, and the bit reads are `@inline(__always)`: `read(byteCount:)` wasn't inlined,
  which spilled the cursor around each call.
- `Builtin.assume(0 <= byteOffset <= span.byteCount && bitOffset < 8)` at each entry point. Bounds checks are
  `span.byteCount &- byteOffset >= n`, and with wrapping arithmetic LLVM couldn't simplify consecutive ones;
  with the invariant it compares each field's end offset against a hoisted constant (4 instructions per
  field down to 3, the remaining `add` doubling as the load address).
- `Range(uncheckedBounds:)` for `read(byteCount:)`, dropping `Range`'s own precondition.

| Workload | v1 | v2 |
|---|---|---|
| Zip fields | 439 K instr | 287 K (−35%), now equal to `ByteReader`'s 283 K |
| Bit fields | 2,378 K instr, 127 µs | 886 K (−63%), 111 µs |

## v3: harness fix

Every parser folded its fields into `checksum = checksum * 31 + value`: 13 dependent multiplies per record,
which took longer than the parsing and made all three field parsers 19 µs. A plain sum removes the chain;
the instruction counts barely move, but the time differences appear (table above). `Bytes` wins on time at
equal instruction count because every field load is `base + constant offset`, independent of the others,
while `ByteReader` advances a pointer field by field (`csel`, then post-increment `ldrh`), a serial dependency.

## Experiment: are the branch-weight hints worth it? (`no-expect`)

`likely`/`unlikely` (`Builtin.int_expect_Int1`) replaced with the bare condition: bit-field parsing used
14% more instructions (689 K → 787 K), with time within noise; field parsing within noise. Kept.

## Assembly findings (Apple clang/LLVM via `swiftc -O -S`)

- Byte-aligned `read(Byte4.self, .littleEndian)`: two `ldp`s of the cursor, a branch on the bit offset, the
  bounds compare, one `ldr`, and the offset store.
- `Nibble` read: fully inlined and branch-free; both bit orders computed and selected with `csel`.
- Fixed-size record (`Bytes(try reader.read(byteCount: 46))`, then fields): no per-field checks at all,
  including paired loads (`ldp w7, w19, [x17, #16]`) for adjacent 4-byte fields.
- Bulk decode, `read(_:_:into:)`: autovectorized for every width tried. `Byte2` big-endian uses `rev16.16b`,
  `Byte4` `rev32.16b` (64 bytes per iteration with `ldp q0, q1`), and the odd-width `Byte3` still vectorizes
  its two overlapping loads with `ushll`/`orr`/`rev32`/`ushr`. The per-value `read(_:_:)` loop and a plain
  `RawSpan.load` loop vectorize identically, so the bulk API is for convenience and a guaranteed single
  bounds check, not speed.
- Search: the scalar early-exit loop doesn't vectorize (LLVM doesn't vectorize loops with data-dependent
  exits here). The SIMD version, written with `SIMD16<UInt8>`, lowers directly to `ldr q`/`ldur q`,
  two `cmeq.16b`, `and.16b`, `umaxv.16b`: 16 candidate offsets per ~9 instructions. No builtins needed.
- Constants such as `[0x50, 0x4B, 0x05, 0x06] as Byte4` fold to a single `mov`/`movk` pair at the use site.
