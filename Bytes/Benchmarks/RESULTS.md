# Bytes performance log

Medians (p50) from `swift package --disable-sandbox benchmark`, M3 Ultra, macOS 27.2, Swift 6.4.2.
Baselines are in `.benchmarkBaselines/`. The table below is baseline `modern` (re-run on 2026-11-09 with no
other benchmarks running); the 2026-11-12 sections have newer full runs. Compare any two with
`../Tools/bench-table . --metric 'Time \(wall clock\)|Instructions|Malloc' <a> <b>`.

## Current: Bytes against the alternatives (same harness, same run; baseline `modern`)

The times below were first taken on a loaded machine (see the 2026-11-09 section). Re-run alone, `modern`
against `safe-final`: instruction counts identical (268 rows, none beyond −0.8%), wall times a median
change of 0.0% (single rows ±18%, run-to-run noise), allocation thresholds pass.

| Workload | Bytes | Comparator | |
|---|---|---|---|
| Zip central directory, 2,000 entries (~170 KB) | **11 µs**, 301 K instr | original `ByteReader`: 17 µs, 259 K instr | 1.5x faster |
| | fixed-size-record style: **7.8 µs**, 199 K instr | hand-written `RawSpan.load` offsets: 16 µs, 317 K instr | 2x faster |
| Bit fields, 8 fields of 1–32 bits per record, 128 KB | **40 µs**, 706 K instr | 64-bit refill-buffer reader: 332 µs, 8,180 K instr | 8x faster |
| Find a 4-byte signature 64 KB back (zip EOCD worst case) | **2.0 µs**, 50 K instr | `RawSpan.load` per offset: 33 µs, 787 K instr | 16x faster |
| 256 K big-endian `UInt32`s | 21 µs, 200 K instr | `RawSpan.load` per value: 21 µs, 201 K instr | equal (all vectorize) |
| 349 K big-endian 24-bit values (`Byte3`), `read(_:_:into:)` | 22 µs, 267 K instr | — | NEON `tbl` unpacking |

Field-by-field parsing uses more instructions than at v3 (301 against 263 K) because one `assume` was
dropped so that loops of reads vectorize (see "Making loops of single reads vectorize"), and the checked
`extracting` added 3% (see "Safe constructs"); wall time is unchanged.

No benchmark allocates, apart from the output array in the bulk ones and one `for`-`in` shape (below).

## 2026-11-12: the optimized build adopts the portable iterator path; all four builds (baselines `cmp-old-*`, `cmp-optimized-*`, `cmp-portable-*`, `cmp-portable-no-c-*`)

Each of `GroupShuffle`'s paths was tried in the optimized build against the NEON `Shuffle`, in alternating
runs of a copy of the code with each (three rounds, against the working code just before the change; the
four-build table below compares with the last commit, so its percentages differ a little):

| Path | With `GroupShuffle` instead of NEON | Verdict |
|---|---|---|
| Iterators (`for`-`in` over `values(of:)`; `_forEach(…, staged: false)`), `Byte5`–`Byte7` | −22 to −32% time, both in cache and from memory (+21–25% instructions) | **Adopted** |
| … `Byte3` (NEON had used the plain `ld3` loop) | −43 to −44% time, −18% instructions | **Adopted** |
| `forEach` with a body (staged), `Byte5`–`Byte7` | +0 to +12% time, +60–100% instructions | NEON kept |
| Bulk reads `read(_:_:into:)` | level (previous section) | NEON kept |
| Generating writes | 1.25–2x slower (previous section) | NEON kept |

An iterator's body only stores each value into its buffer, so there's nothing for the vector to be
pulled apart for: a vector of two values (four for 3 bytes) per load, one single-register `tbl`, against a
64-byte step of four-register `tbl`s (4 micro-ops each). `GroupShuffle.isPreferredForIteration(staged:)`
makes the choice; `staged` is a constant at each call site, so it folds.

Then all four builds, two alternating rounds of the full suite (old code from the last commit, the
optimized build, `portable`, `portable-no-c`); times in µs, the mean of the rounds:

| Workload | Old | Optimized | Portable | Portable, no C |
|---|---|---|---|---|
| `for`-`in` `Byte3`, 4 MB (portable builds before: 284, 290) | 294 | **160** | 163 | 158 |
| `for`-`in` `Byte5` / `Byte6` / `Byte7` | 258 / 213 / 185 | **186 / 157 / 136** | 186 / 155 / 135 | 186 / 157 / 135 |
| Bulk read `Byte3` / `Byte5` / `Byte7` | 83 / 99 / 81 | 88 / 99 / 81 | 89 / 92 / 82 | 88 / 100 / 81 |
| `forEach` summing `Byte5` / `Byte6` / `Byte7` | 192 / 159 / 137 | 196 / 161 / 137 | 193 / 162 / 135 | 190 / 161 / 136 |
| Generating write `Byte3` / `Byte6` | 96 / 147 | 97 / 146 | 189 / 200 | 189 / 198 |
| CRC-32, 256 KB (`checksum`) | 471 | 470 | 3,874 | 3,900 |
| CRC-32 tables, 256 KB / 64 B | 14,000 / 9,564 | **3,864 / 8,272** | 3,879 / 8,333 | 3,856 / 8,393 |

Over all 337 rows (geometric mean of time): optimized against old **0.988**; portable against optimized
1.020, portable-no-c 1.023; within 10% of the optimized build: 321 and 319 rows. The rest are the
odd-width generating writes (1.25–2x), CRC-32 against `pmull` (8.2–8.3x), the MAC reference `forEach`
(1.12–1.14x), and 32-core memory rows within the machine's two timing levels.

The optimized build's instruction counts match the old code's except the CRC tables (−41% at 256 KB,
−31.5% at 64 B), `for`-`in` over `Byte3` (−18%), and `for`-`in` over `Byte5`–`Byte7` (+21–25%, and 26–28%
faster in the table above). Rows slower in both rounds were rerun three more times, alternating: most were
noise, but "Runs: 3-/4-byte elements, per-element writes" (+11–15%) and the 3–32-byte back-references at
distance 2 and 4 (+1–2 µs) stayed slower with identical instruction counts. The per-element writes'
function is the same 132 instructions of machine code in both benchmark binaries, but starts 196 bytes
earlier in the new one (the inlined code laid out before it changed size), so its loops sit at different
offsets within 64-byte blocks: a layout effect in the benchmark executable, not a change in the code Bytes
generates. Tests (129, 128 in the portable builds), warnings (none), and the zero-allocation thresholds
pass in all three builds.

## 2026-11-12: fast portable builds (baselines `final-old-*`, `final-optimized-*`, `final-portable-*`, `final-portable-no-c-*`)

The `portable` and `portable-no-c` builds (previous section) made as fast as possible without CPU-specific
code: no NEON, no `asm`, nothing that checks the architecture. Two changes cover nearly all of the gap.

**Odd-width groups (3, 5, 6, 7 bytes): `GroupShuffle`**, portable Swift, used wherever `tbl` isn't a
single instruction (the NEON `Shuffle` stays for the optimized build). A 16-byte vector holds whole
values in lanes (four 32-bit lanes for 3 bytes, two 64-bit lanes for 5–7); unpacking loads the 12, 10, 12,
or 14 bytes they take and builds the lanes with `SIMD16(v[k], …)` picks at constant `k`, which LLVM turns
into one shuffle: a single-register `tbl` on ARM64 (1 micro-op against the NEON path's 4-register `tbl`'s
4), `pshufb` on x86-64 macOS. Reads are 1 load, 1 shuffle, 1 store per 16 lane bytes. Two traps (LLVM
seeing too much) and a threshold:

- Writes that built each vector from the caller's computed values and then shuffled got merged into one
  byte insert per byte (40 per `Byte3` vector), slower than the plain loop. Values now go through a
  512-byte stack buffer (`withUnsafeTemporaryAllocation`, no allocation): a plain loop computes them (it
  vectorizes the caller's closure), then lanes are loaded back, shuffled, and stored 16 bytes at a time
  (each store overwrites the previous one's spare bytes, and the last stays within the run).
- `forEach` that handed the caller's body each value from the vector kept the body scalar: 2x slower than
  the plain loop when summing. It now unpacks a chunk into the same kind of buffer and runs the body over
  it, so the body vectorizes. Iterators (`for`-`in`), whose body only stores values into their own buffer,
  keep the direct form (`_forEach(…, staged: false)`).
- Staging only pays for a full buffer (128 values of 3 bytes, 64 of 5–7): runs of 1–62 `Byte3`s took 37%
  more instructions staged, and stay on the plain loops, which have code of their own (sharing it with a
  run-time start cost 20 instructions per call).

**CRC-32 tables: braided (zlib's method).** Slicing-by-8 is a latency chain: each word's 8 lookups wait for
the previous word's. Five CRCs now run over interleaved 8-byte words, each jumping 40 bytes per step with
tables that advance over the others' words, combined in the last block (126 instructions per 40 bytes,
45 of them loads). The lookups had a bounds check each; 256-entry spans lost them in one loop and not the
other, and stating the counts made the braided loop spill and check again (126 to 293 instructions), so
the tables are pointers into the borrowed array, with that reasoning in `CRC32._Tables`. This is also the
`CRC-32 tables` benchmark of the optimized build.

Times in µs, two interleaved rounds (old code, new optimized, portable, portable-no-c, twice):

| Workload | Optimized | Portable, before → now | No C, before → now |
|---|---|---|---|
| Bulk read `read(_:_:into:)`, `Byte3`, 4 MB | 87 | 8,485 → **88** | 222 → **88** |
| … `Byte5` / `Byte6` / `Byte7` | 98 / 84 / 82 | 10,500 / 8,371 / 7,291 → **99 / 88 / 81** | 202 / 165 / 139 → **99 / 88 / 81** |
| Bulk BE24 | 22.5 | 2,090 → **22** | 54.5 → **23** |
| `forEach(Byte6.self, .bigEndian)`, 4 MB | 154 | 7,570 → **160** | 169 → **162** |
| `forEach` summing `Byte5` / `Byte6` / `Byte7`, 4 MB | 193 / 161 / 137 | 9,535 / 7,742 / 6,931 → **200 / 165 / 139** | 202 / 171 / 146 → **194 / 162 / 139** |
| `for`-`in` `Byte5` / `Byte6` / `Byte7`, 4 MB | 255 / 205 / 185 | 9,536 / 7,809 / 6,718 → **188 / 155 / 137** | 282 / 235 / 203 → **186 / 157 / 135** |
| Generating write, `Byte3`, 4 MB | 97 | 6,699 → **189** | 204 → **189** |
| … `Byte5` / `Byte6` / `Byte7` | 177 / 148 / 136 | 7,072 / 5,982 / 7,209 → **247 / 208 / 174** | 272 / 227 / 197 → **252 / 208 / 170** |
| CRC-32, 256 KB | 466 (`pmull`) | 14,000 → **3,849** | 14,000 → **3,888** |
| CRC-32 tables, 64 B (×524 K) | 8,342 | 9,417 → **8,315** | 9,532 → **8,254** |

Over all 337 rows (geometric mean of the time against the new optimized build): portable 1.59 → **1.009**,
portable-no-c 1.055 → **1.016**; within 10% of optimized: 292 → **323** and 307 → **322** rows. The rest:
odd-width generating writes (1.25–2x: the stage through memory, and the vectorized loop building values
from 64-bit indices, against the NEON path's lanes), CRC-32 against `pmull` (8.3x, from 30x), and a few
32-core rows within the machine's bimodal memory timing (below). `for`-`in` over 5–7 bytes is now faster
than the optimized build's, and summing `forEach` matches it. (The section above then adopted the portable
path for the optimized build's iterators; staged `forEach` stayed on NEON.)

Not regressed: the optimized build's instruction counts match the old code's in every row but the CRC
tables (−41% at 256 KB, −31% at 64 B); its times average 1.005x the old code's. Five rows were slower in
both rounds; the large ones were 32-core and single-core memory writes that switch between two levels
(~2,250 and ~2,760 µs, also in unchanged code like `memset`), and three more alternating runs of each put
old and new within 1%. All three builds pass their tests (new ones: runs written between guard bytes,
`forEach` stopped mid-chunk), build without warnings, and pass the zero-allocation thresholds.

## 2026-11-12: the three builds (baselines `optimized-*`, `portable-*`, `portable-no-c-*`)

Bytes builds three ways, selected by package traits and run with `./bench BUILD [benchmark args]` (each
build has its own build directory):

- `optimized` (default traits `NEONShuffle`, `HardwareCRC`): CBytesNEON's `tbl` lookups and CBytesCRC's
  `pmull`/`crc32` instructions.
- `portable` (`--traits Portable`): both C modules, with `BYTES_PORTABLE` defined so their headers compile
  the fallbacks other CPUs get, and `CRC32` uses its table path. The Swift targets get `-Xcc
  -DBYTES_PORTABLE` too: a module inlining Bytes' code compiles the headers' `static inline` functions
  itself.
- `portable-no-c` (`--disable-default-traits`): no C modules, so the Swift fallbacks are used throughout.

Checked: the benchmark plugin honors the traits (`pmull` and `crc32` counts 32 and 4 in the optimized
benchmark binary, 0 in the others); tests pass in all three (126 in the portable builds: the folding
constants test is hardware-only); no warnings.

Two interleaved rounds (optimized, portable, no-C, twice), 179 benchmarks without the allocation-only
ones. Times are the mean of the two rounds' medians, in µs. 291 of 337 rows are within 10% of optimized for
`portable`, 301 for `portable-no-c`. The rest:

| Workload | Optimized | Portable | Portable, no C |
|---|---|---|---|
| Bulk read `read(_:_:into:)`, `Byte3`, 4 MB in cache | 77 | 8,485 (110x) | 222 (2.9x) |
| … `Byte5` | 93 | 10,500 (113x) | 202 (2.2x) |
| … `Byte5`, 512 MB from memory | 13,000 | 1,318,500 (101x) | 26,000 (2.0x) |
| Bulk BE24 (`read(_:_:into:)`) | 21 | 2,090 (100x) | 55 (2.6x) |
| Generating write, `Byte3`, 4 MB | 97 | 6,699 (69x) | 204 (2.1x) |
| … `Byte5` / `Byte7`, 4 MB | 178 / 136 | 7,072 / 7,209 (40x / 53x) | 272 / 197 (1.5x) |
| `forEach`/`for`-`in` over `Byte5`–`Byte7`, 4 MB | 155–248 | 6,700–9,500 (37–51x) | 168–282 (1.1x) |
| `Byte5`–`Byte7` reads, 512 MB, 32 cores | 2,323–2,333 | 35,000–49,000 (15–21x) | 2,309–2,322 (1.0x) |
| CRC-32, 256 KB | 466 | 14,000 (30x) | 14,000 (30x) |
| Runs: 3- and 4-byte elements, per-element writes | 5.9 / 8.1 | 6.9 / 9.2 (1.17x / 1.14x) | 7.1 / 9.5 (1.20x / 1.18x) |

Instruction counts agree (bulk BE24: 267 K, 42 M, 900 K), so these aren't timing noise.

What it shows:
- Without the C modules, the odd-width group paths lose 1.1–2.9x on one core and nothing when memory-bound
  on all cores: that is what the `NEONShuffle` trait buys.
- The C modules' portable fallback is a disaster: 37–113x slower than optimized on one core (15–21x on all
  cores, from memory), and 15–54x slower than not having the C module at all. Each lookup copies its 48- or
  64-byte table to the stack and gathers lane by lane (`bytes_table_portable`), and the pack/unpack steps do
  3–4 lookups per 64 bytes: the bulk `Byte3` read loop in the portable binary is 868 instructions per
  64-byte step (64 lane extracts, 81 byte loads, 60 lane inserts, 77 stores, 63 branches), about 200 per
  lookup, where NEON uses one `tbl`. On other CPUs with default traits, Bytes would take the shuffle paths with these
  fallbacks. They should be taken only where lookups are single instructions (as
  `ByteLanes.isLookupVectorized` already reports), and the plain Swift loops used elsewhere. Fixed in the
  next section, which also replaces the plain loops with portable shuffles.
- The table CRC is 30x slower than the folded hardware one at 256 KB, matching the `CRC-32 tables`
  benchmark (14 ms in all three builds).

## 2026-11-10: conveniences, lane shuffles for a decoder, cheaper array builders (baselines `conv-old-*` → `conv-new-*`, `builder-ab`)

New API (proposals 10–14 and parts of 16–17; `Tests/BytesTests/FieldHelperTests.swift`,
`LaneShuffleTests.swift`):

- **Flags and fields:** `read(Bool.self)`, `peek(Bool.self)`, `write(_: Bool)`, `BitBuffer.read(Bool.self)`;
  `readSigned(_:_:as:)`, `readSigned(bitCount:)` (and on `BitBuffer`), `signedBits(_:as:)`,
  `Bits.signedValue`; `bits(from:upTo:)` (unchecked), `keepingLowBits(_:)`, `lowBitMask(_:)`;
  `matches(_:mask:)` on integers, `Bits`, and groups, and `expect(_:mask:)`; `Bits(rawBitsOf:)`.
- **Records and errors:** `forEachRecord(tag:length:_:_:)` (all or nothing per record, no closure inside, so
  the cursor stays in registers); `located(_:)` and `LocatedBytesError`.
- **Small ones:** `readRemainingBytes()`, `CRC32.checksum(_:continuing:)`, `RawSpan.hasPrefix(_:)`,
  `Byte16.vector`/`Byte16(_: SIMD16)`, `[UInt8].append(copying:)`, `String(utf8Capacity:writing:)` (a
  non-throwing overload too: 10 instructions per call cheaper for bodies that can't fail).
- **Lanes, for Base64's decoder:** `ByteLanes.deinterleave` of four vectors (8 `uzp`s, as `ld4`),
  `interleave` of three (3 `tbl`s, as `st3`), `lookup(in:keepingOutOfRange:)` (`tbx`) for 16-, 48-, and
  64-byte tables, a 16-byte `lookup(in:)`, and a 128-byte one.
- **`BytesWriter.position` and `rewind(to:)`**, for all-or-nothing writes (the decoder's failures).
- **Docs:** "Fields that fill a byte: read the `Byte`, then take it apart" (`WritingParsers.md`), and the
  examples use the new forms.

Every new helper was checked against the code it replaces (`@inline(never)` pairs in a probe package,
instructions per function): the pairs merged into one function (`read(Bool.self)`, both signed reads,
`signedValue`, `readRemainingBytes`, `Byte16.vector`, `append(copying:)`) or the new form was shorter:
`keepingLowBits` 6 against 8, `bits(from:upTo:)` 5 against 8 (and 23 for the checked subscript),
`CRC32.checksum(_:continuing:)` 6 against 12, `matches` 8 against 10, `hasPrefix` 14 against 34,
`forEachRecord` 64 against 80. `located` in a `catch` adds 13 instructions to the function, all on the
error path.

Inside Bytes, the masks in `write(repeating:byteCount:count:)`, the run pattern, and `LEB128.maxValue` use
`keepingLowBits`/`lowBitMask` (runs of 3- and 4-byte elements −2.0 to −2.6% instructions; the rest
unchanged), and HuffmanTable's root lookup uses `bits(from:upTo:)` (same 138 instructions). Not
`write(_:bitCount:)`: with a run-time bit count, a loop of those writes grew from 146 to 169 instructions
(LLVM split the function's paths differently), so it keeps the explicit mask.

The comparators now use the new API where Bytes code would (`readSection`, `forEachRecord`,
`readSigned`, `[bit: 0]`):

| Benchmark | Instructions | Time (rounds 1 / 2) |
|---|---|---|
| Fields: Bytes | 300.6 → 284.6 K (−5.3%) | −5.2% / −6.0% |
| Fields: Bytes, position and rewind / in `atomically` | −5.2% / −5.3% | −3 to −8% |
| Fields: fixed-size records | unchanged (198.6 K) | within noise |
| Runs, back-references, other fields rows | within ±0.3% | within noise |

**Array builders.** The standard library's `[UInt8](capacity:initializingWith:)` (and
`init(unsafeUninitializedCapacity:)`) allocate through an unspecialized function: about 500 instructions
and 27 ns more per array than `reserveCapacity` then `append(addingCapacity:)`, at 40 bytes and at 1 KB
alike (a standalone driver). `[UInt8](byteCapacity:writing:)` now reserves and appends, and
`[UInt8](copying:)` uses `Array(UnsafeRawBufferPointer)`:

| Benchmark (`builder-ab`, `old5` against now) | Instructions |
|---|---|
| Array builder: 1,000 38-byte arrays, `[UInt8](byteCapacity:writing:)` | 1,696 → 1,228 K (−27.6%) |
| …closure not annotated | 1,748 → 1,228 K (−29.8%): annotating no longer matters |
| …`[UInt8](capacity:)` + `withBytesWriter` (the old form, unchanged) | 1,696 K |

`[UInt8](copying:)` had been copying through `init(unsafeUninitializedCapacity:)`: once MQTT's copying
benchmark used it, it ran 17.5% more instructions (about 590 per packet) until the change above.

**Harness.** The bandwidth and write benchmarks no longer time inside `scaledIterations`: they report the
framework's throughput (iterations per second); bandwidth is that times the bytes per iteration in the
name.

## 2026-11-09: runs, copies from a reader, short copies, minimal LEB128 (baseline `runs-copies-1`)

The four highest-value proposals from `Proposals/INDEX.md` (1, 2, 3, 5), implemented:

- `write(_: RawSpan)` copies 33–64 bytes inline (four overlapping 16-byte moves) instead of calling
  `memmove`.
- `write(repeating:count:)` for a `Byte` or any `ByteGroup`, and `write(repeating:byteCount:count:)` for a
  1–8-byte element whose size is known only at run time. Capacity is checked once; the element is repeated
  across 16 bytes in whole copies and stored 16 bytes at a time (`stp`); byte runs over 256 call `memset`.
- `write(from: &reader, byteCount:allowingOverrun:)`: LZ4's literal copy. With room in both cursors, 16-byte
  steps (one `ldr q`/`str q` for up to 16 bytes, a 5-instruction loop) that may overwrite up to 15 bytes
  after the copy; otherwise exact.
- `requiringMinimal:` on `read(LEB128.self…)`, `read(bytesPrefixedBy: LEB128.self…)`, and
  `read(sectionPrefixedBy: LEB128.self…)`: one compare in the out-of-line multi-byte loop (a last byte of
  zero after others is padding).

Measured by `Benchmarks/BytesBenchmarks/RunsAndCopies.swift`: each new form next to the code it replaces,
in the same run, filling or reading 64 KB (values below are per 64 KB; widths and sizes are run-time
values). All allocate nothing (thresholds recorded).

| Workload (64 KB) | New | Before (same run) | Change |
|---|---|---|---|
| Runs of 3-byte elements, 1–62 each (QOI RGB) | 129 K instr, 6.3 µs | one 8-byte overrun store per element: 174 K, 8.6 µs | −26% instr, −28% time |
| Runs of 4-byte elements, 1–62 each (QOI RGBA) | 89 K, 4.2 µs | 150 K, 7.5 µs | −41%, −44% |
| Runs of `Byte3`, 1–62 each (width known) | 93 K, 4.6 µs | generating `write(Byte3.self, count:)`: 100 K, 5.3 µs | −7%, −14% |
| Byte runs, 8 / 40 / 1,000 each | 304 K, 10 µs / 71 K, 2.7 µs / 8.6 K, 1.3 µs | generating write: 304 K, 17 µs / 81 K, 6.3 µs / 8.1 K, 1.3 µs | time −41% / −57% / equal (both `memset`) |
| Literals of 0–15 bytes (~8,700 copies) | 257 K, 10 µs (30 instr each) | `write(reader.read(byteCount:))`: 474 K, 18 µs (54 each) | −46%, −44% |
| Literals of 16–64 bytes (~1,600) | 67 K, 4.1 µs | 101 K, 5.2 µs | −34%, −21% |
| 40-byte span copies (1,638) | 110 K, 2.8 ns each | `memmove`: 127 K, 4.3 ns; two writes ≤ 32: 173 K, 4.1 ns | −13% instr, −34% time |
| 48-byte | 92 K, 2.9 ns | `memmove`: 111 K, 4.7 ns; split: 144 K, 4.2 ns | −17%, −38% |
| 63-byte | 70 K, 3.1 ns | `memmove`: 118 K, 7.3 ns; split: 111 K, 4.0 ns | −41%, −57% |
| 64-byte | 69 K, 3.1 ns | `memmove`: 76 K, 3.0 ns | equal (an aligned size `memmove` handles well) |
| LEB128, 1–4 bytes (~35 K values), `requiringMinimal: true` | 2,273 K, 103 µs | read, then compare with `byteCount(of:)` (MQTT's check): 2,396 K, 111 µs | −5%; +4% over an unchecked read (2,185 K) |

In the consumers (interleaved runs of the old and new trees, baselines `ab-old-*`/`ab-new-*` in each):
LZ4 −26% instructions and −42% time (`swift-help.lz4`), QOI `tricolor.qoi` −77% and −70%, Base64's 40–47-byte
inputs −18% and −18% (after its `writeShort` workaround, now removed), MQTT's PUBLISH encoding −10% and −13%
(its 64-byte payloads were `memmove`d), MQTT parsing −1.6 to −2.6% instructions. See each package's RESULTS.md.

### Follow-ups: short-distance back-references, a cheaper pattern (baselines `fu3-old-*` → `fu3-new-*`)

- **`copy(fromDistance:count:)` for distances 2–7** is now a run of the last `distance` bytes: one load,
  then the run fill's 16-byte stores (libdeflate does the same). It copied a byte at a time, each byte
  waiting on one just stored. The overrun form falls back to it for distances under 8, so DEFLATE and LZ4
  matches use it too.
- **The pattern** for a 1–8-byte element is two multiplies: the element times a constant with a 1 at
  each copy's first bit gives the low 8 bytes, and the element rotated by `8 % period` bytes gives the
  high 8 bytes. One `switch` gives the constant, rotation, and step. It compiles to a branch tree, not a
  table, which is still cheaper than doubling a 128-bit value (16 instructions per doubling).

Interleaved runs of the tree before these changes and after, two rounds; instructions are exact minimums,
times from round 2:

| Workload | Instructions | Time |
|---|---|---|
| Back-references 2–7 bytes back, 3–258 bytes each (~490 per 64 KB) | −69 to −77% | −80 to −94% |
| …3–32 bytes each (~3,600) | −2 to −21% | −36 to −59% |
| Back-references 1 back (`memset`, unchanged) and 8 back (control) | +1 to +21%: a constant ~1.3 K difference between the two benchmark binaries, plus noise on 34 K | ±3% |
| Runs of 3- / 4-byte elements, 1–62 each | −20% / −15% | within noise: the fill is store-bound |
| NativeZip: inflate 32 MB of pixel runs (new fixture) | −38% (227 → 141 M) | 18 → 9.2 ms (−49%), level with zlib (9.8 ms) |
| NativeZip: inflate 32 MB text, 2,000 small files | +0.0%, +0.1% | unchanged |
| QOI `tricolor.qoi` (run fills of 3-byte pixels) | 1.52 → 1.32 M (−13%) | within the run's drift |
| LZ4 | ±0.7% | noise |

Two things that went wrong first, both fixed:

- **Inlined, the short-distance fill slowed the common case.** It made NativeZip's `decodeSymbols` loop
  743 → 853 instructions and its text and small-file inflates +12–14% instructions, where almost every
  match is 8 or more bytes back. Now it's out of line (`_copyRepeating`, static, taking values, like the
  other slow paths), and the loop is 722 instructions (743 before any of this): the old byte loop moved
  out too.
- **Distance 1 through that function** (`memset` for more than 64 bytes, the fill below) cost 21% more
  on long runs through the extra call, and short runs gained nothing. It's back to the inline `memset` it
  was.

The run benchmarks first measured the new path and its reference in one function behind a run-time flag.
Changing the new path moved the reference's register allocation (the `Byte3` generating write 70 → 102 K
instructions, unchanged source), so each is now its own `@inline(never)` function. Allocation thresholds
for the back-reference workloads: 0.

## 2026-11-09: inline span writes, array builders, one-check prefixed sections (baselines `bcd2-old-*` → `bcd2-new-*`)

- **`write(_: RawSpan)` is `@inline(__always)`**, with copies over 64 bytes in an out-of-line `_copyLong`
  (`memmove`). It was `@inlinable` and stayed a call: MQTT's encoder made three per packet, Base64 two
  per input, and both LZ4 ports one per literal run.
- **`[UInt8](byteCapacity:writing:)` and `append(byteCapacity:writing:)`**: one closure instead of
  `[UInt8](capacity:)` plus `withBytesWriter`. Generic over the error type. **Annotate the closure in hot
  code** (`{ (writer) throws(BytesError) in … }`): unannotated, Swift 6.4 infers `throws(any Error)`, and
  that closure wasn't inlined. The writer went to it through memory with its unaligned slow paths, for
  +3% here. A `BytesError`-only overload doesn't help: the unannotated closure still infers `any Error`,
  which then doesn't convert.
- **`read(bytesPrefixedBy:)` checks the length once** and builds the span unchecked. Before, it checked
  in `peek`, in its own guard, and again in `read(byteCount:)`'s checked `extracting`. The LEB128 form
  likewise. New: **`readSectionIfComplete(prefixedBy:_:)`**, which returns `nil` without consuming when
  the section isn't all there, for tolerant parsers (zip extra fields) without `try?`.

Same-run comparisons in Bytes' benchmarks (`BuildersAndSections.swift`; exact instruction counts, times from
round 2):

| Workload | Instructions | Time |
|---|---|---|
| 1,000 38-byte arrays: builder, closure annotated | 1,695,567 (same as the nested form, 1,695,589) | 66 µs (nested: 64) |
| …closure not annotated | 1,747,460 (+3%) | 72 µs |
| 64 KB of prefixed sections: `read(sectionPrefixedBy:)` | 96,559 → 74,207 (−23%); now below the hand-written form (81,585) | within noise |
| …`readSectionIfComplete` | 70,362 (−14% against hand-written) | within noise |
| Span copies of 24–64 bytes (`write(_: RawSpan)`) | −33 to −36% | −20 to −34% |
| Literal copies of 0–15 bytes, overrun form | −3% | −12 to −14% |

In the packages (old and new trees interleaved, two rounds): MQTT encoding −3.0% instructions and −8 to
−11% time, parsing −2.2 to −3.2% instructions. Base64 40–47 B: −13% instructions, −14 to −18% time. LZ4
(Bytes): −4.4%, and its exact-copy variant −21%. The `ParserSpan` LZ4 port: −15.6% instructions, −7 to
−11% time, from its output side (Bytes' writer) alone. Zip directory (Bytes): −0.7%. NativeZip's central
directory with `readSectionIfComplete`: +0.2% instructions, +1.7% time, against −14% in the micro-benchmark,
so it's neutral there at best. Code size: `MQTTPublish.write(to:)` 364 → 427 instructions, `writeBody`
127 → 294, NativeZip's `decodeSymbols` unchanged (769).

## 2026-11-09: `position`/`rewind(to:)`, and cursors at an offset (baselines `pos-fields-*`)

Proposals 7 and 8:

- `reader.position` (a `BytesReader.Position`: byte and bit offset) and `rewind(to:)`, which can't fail
  and doesn't throw: two stores and a precondition that the position isn't ahead of the cursor (which keeps
  the invariant `_assumeInvariant` states). It replaces `let start = byteOffset … try! seek(toByteOffset:
  start)` rollbacks, and `atomically { }` where its closure isn't inlined or can't return the result.
- `BytesReader(span, atByteOffset:)` (any integer type: zip's `UInt64` offsets without `Int(clamping:)`),
  `BytesReader(span, atBitPosition:)`, `BitBuffer(span, atBitPosition:bitOrder:)`, and
  `BytesWriter(&bytes, atByteOffset:)` for a buffer passed `inout` with a prefix already written (no
  `_mutatingExtracting(...)` plus `skip` at the call site). All `@inline(__always)`: the writer's
  initializer, only `@inlinable` at first, was called out of line from NativeZip's `decodeSymbols` and grew
  it from 789 to 891 instructions; inlined, it's 769.

All-or-nothing entries in the 2,000-entry zip directory (field by field, same run; exact instruction counts):

| Each entry… | Instructions | Time |
|---|---|---|
| not all or nothing (`Fields: Bytes`) | 300,588 | 10–11 µs |
| in `atomically`, calling an `@inline(__always)` function with the body | 300,588 (free: the closure is inlined) | 10–11 µs |
| in `atomically`, the body written in the closure | 452,574 (+51%) | 16–17 µs |
| between `position` and `rewind(to:)` | 306,591 (+2%: 3 per entry) | 11 µs |

So `atomically` costs nothing or half again depending on how the closure is written, and `rewind` costs a
steady 3 instructions per entry. Its documentation now says so. In the packages (interleaved runs,
`pos-old-*` → `pos-new-*`): MQTT's 5 rollbacks lose their out-of-line `seek` calls and
`swift_unexpectedError` paths (parsing −0.4 to −1.1% instructions); NativeZip's 5 seek-after-create sites
and 3 inflater cursors (raster inflate −1.2% instructions and time, the rest within ±0.3%). Details in
their RESULTS.md files.

## Verification, 2026-11-09 (baseline `modern`)

A full run after the renames, the formatting pass, and the `ByteLanes` additions. Other agents were
building and benchmarking on the machine at the time (load average ~10), so times are not comparable.
Instruction counts are, and they're what this check uses. (The `modern` baseline was later re-run alone:
see the top.)

- **Instructions are unchanged from `safe-final` in every benchmark.** Of 280 rows, none differs by 1% or
  more, except two 32-core rows at +1.3% and +1.5%, which are scheduling noise. Wall times are 5–15%
  slower across the board, including the references (raw SIMD read and store, `RawSpan.load`), and with
  equal instruction counts. That's the load, not the code.
- **The `literals3` numbers don't reproduce at HEAD, but the parser didn't change.** That baseline
  recorded 292 K for "Fields: Bytes", 197 K for the fixed-size records, and 48 K for the search, against
  301, 199, and 50 K now. The comparators that don't use Bytes moved by the same 1–2 K (315 → 317,
  257 → 259).
  - Commit `fa86687`, the literal fix, built from a clean export and run back to back with HEAD, gives
    292 / 197 / 315 / 257 / 48 K again, so both measurements are deterministic.
  - Yet `parseWithBytes` is byte-for-byte the same machine code in both binaries (`objdump`, addresses
    normalized). The signature is still the folded `mov`/`movk` constant with no `swift_once`, so the
    literal fix holds.
  - The difference is outside the measured function: the benchmark binary around it, or the process-wide
    instruction counter. It isn't a library regression.
  - The "−3% against `safe-final`" in "Integer literals" is therefore a property of that build of the
    benchmark binary, not something the literal change does to the parser.
- **Allocations:** `thresholds check --filter 'Allocations:.*'` passes (EQUAL) with the `NEONShuffle`
  trait on, and with it off (`--disable-default-traits`, checked by the absence of `tbl` in the rebuilt
  bulk-read loops).
- **Vectorization**, checked with `Tools/loops` on the benchmark binary and on probes:
  - `forEach` over every byte group:
    - `Byte2`, `Byte4`, `Byte8`: `rev*.16b` + `add` with `ldp q`.
    - `Byte3`: `ld3.16b`.
    - `Byte5`–`Byte7`: NEON `tbl` unpacking.
    - `Byte9`–`Byte15`: `rev64.16b`/`usra.2d`.
  - `forEach` over every bit width: `Bits<3>` with `ld3.16b`, `Bits<5>`–`Bits<7>` from 64-bit blocks.
  - Bulk `read(_:_:into:)` of `Byte3` and `Byte5`–`Byte7`: an innermost loop of 4 `tbl.16b` with `ldp`/`stp`,
    with no lane moves.
  - `lastByteOffset(of:)`: 12 instructions with 2 `cmeq.16b`, `and.16b`, and `umaxv.16b`.
  - `ByteLanes.lookup(in:)` and `deinterleave`: `tbl.16b`. `interleave`: `zip1`/`zip2` plus an `st2.4h`
    store, with no lane moves.
  - `CRC32._fold`: 8 `pmull`, 8 `pmull2`, and 8 `eor3` per 128 bytes. The tail is `crc32x`.
  - Generating writes vectorize for `Byte2`, `Byte4`, `Byte`, `Nibble`, `Crumb`, and `Bit`.
    - `Byte3` and `Byte5`–`Byte7` use `tbl` packing, with a few lane inserts building the 32/64-bit lanes.
    - `Byte8`–`Byte16` writes are scalar, as recorded below.
- **`Byte16` `forEach` is reported `vector128` by `Tools/loops`, but its decode is scalar.**
  - The loop is `ldp x`, `rev` ×2, `fmov`/`mov.d` into vectors, then `add.2d`. Only the benchmark's sum
    is vectorized, fed one lane at a time.
  - `Tools/counters --mode simd_fp_unit_instructions` on a probe confirms it: 0 SIMD loads for `Byte16`,
    against 66 M `ldp q` for `Byte4` and 219 M (`ld3`) for `Byte3`, over the same 2 GB.
  - Its instruction count is the same as in `bandwidth2`, so this isn't new. The note under "Making loops
    of single reads vectorize" now says so.
- **A tooling note:** `Tools/loops --forbid` matches substrings, so `--forbid bl` also rejects `tbl`. Use
  `blr`, or check the `+calls` verdict.

## Allocation checks

Every workload that shouldn't allocate is registered a second time as `Allocations:<name>`. These count
only allocations (`mallocCountTotal`), for 10 iterations over 64 KB buffers. They cover:

- every read and write bandwidth workload: all widths, `for`-`in`, bulk/NEON, custom types, and zero-copy
  views;
- the field, bit-field, and search parsers;
- a section round trip: LEB128-prefixed sections, length-prefixed UTF-8, and LEB128 values.

`Thresholds/` holds a static p90 threshold for each (140 files):

```sh
# Fails (nonzero exit) if any workload allocates more than its threshold.
swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:.*'
# After adding a workload: record its threshold.
swift package --disable-sandbox --allow-writing-to-package-directory benchmark thresholds update --filter 'Allocations:.*'
```

The check passes with the `NEONShuffle` trait on and off (`--disable-default-traits`). A planted
`[UInt8]` allocation fails it ("WORSE than the defined thresholds", exit 1).

The names have no spaces or slashes: `thresholds update` writes them as `_` in the file name, but
`thresholds check` (benchmark 1.38.1) looks the file up by the unaltered name, so a name with a space
always fails, or, if other files are found, is silently not checked (ordo-one/benchmark#373).

**One allocation found:** `let reader = BytesReader(span); for byte in reader { … }` allocates once per loop, not
per byte. The cause is in the compiler (Swift 6.4.2, and `main` by inspection):

1. SILGen puts a `~Copyable` `let` in a box: `alloc_box ${ let Bytes }`, then a `begin_borrow [var_decl]`.
2. `Iterable` requires `@lifetime(borrow self)` on `makeBorrowingIterator()`. A `let` has no access scope,
   so `LifetimeDependenceInsertion` bases the iterator's `mark_dependence` on the box's borrow.
3. `AllocBoxToStack` has no case for a `mark_dependence` on the box, treats it as an escape, and leaves
   the box on the heap: 56 bytes, the 40-byte cursor and a header.

A `var` reader (its dependence is on a `begin_access`) or a `borrowing` parameter isn't boxed. A
`copy self` witness would avoid the dependence, but the protocol rejects it. The same `AllocBoxToStack` gap
is open as swiftlang/swift#93942 for `consuming` parameters; a report with a standalone reproducer and a
fix brief is ready to file.

The `let` form's threshold is 1, so a compiler fix shows up as an improvement.
`Allocations:Read:_for-in_Bytes_(UInt8),_var_reader` holds the workaround at 0.

## Against swift-binary-parsing (`../BinaryParsingComparison`, full write-up in its RESULTS.md)

Apple's `BinaryParsing` 0.0.4 on the same work, both directions: our zip and integer parsers ported to
`ParserSpan`, and its QOI and LZ4 example parsers ported to `Bytes`.

| Workload | Bytes | `ParserSpan` |
|---|---|---|
| Zip directory, field by field / fixed-size records | 11 / 7 µs | 23 / 13 µs |
| Big-endian `UInt32`s | equal (10 µs, vectorized) | equal |
| 24-bit values | 55 µs (`forEach` 48) | 158 µs |
| QOI, LZ4 (same algorithm) | within 5% either way | |

- **`ParserSpan`'s field reads cost more** for three reasons:
  - A trapping add for each advance, which its bounds check already makes redundant.
  - Per-site error locations, which give each failing read its own throw path: 2.6x the code, and the
    cursor spilled to the stack.
  - An out-of-line generic `sliceSpan(byteCount:)`.
- **Its odd widths** are a byte-by-byte loop; `Byte3` is two overlapping loads.
- **Its published examples** are 4–42x slower than either port: `Data` appends per pixel, and an `Array`
  per LZ4 match.

**Adopted:**
- `atomically { }` (all-or-nothing reads).
- `read(Int.self, as: Byte8.self, .littleEndian)` (throws instead of trapping when an untrusted value
  doesn't fit).
- `ByteGroup.signedInteger(_:as:)` (sign extension for odd widths).

**Learned:** cursors captured by closures that aren't inlined live in memory. That costs Bytes more than a
byte-only cursor, because each byte read then re-checks the bit offset and bit order. The README's caveat
covers it.

## Integer literals for byte groups

`let signature: Byte4 = 0x50_4B_03_04`: the literal's digits are the bytes in memory order, as a hex dump
shows them. In other words, the literal is the group's big-endian value. That's the one reading that
isn't ambiguous: the source shows the bytes in the order the file holds them, whatever byte order the
format uses for its numbers.

- **Width checks.** The literal type is the group's `Integer`, so a literal too wide is a compile error
  for `Byte2`, `Byte4`, `Byte8`, and `Byte16`. For odd widths it's a precondition, since their integers
  have spare bytes.
- **Leading zero bytes** are kept, because the width is fixed (`0x00_04_4D_51_54_54` as a `Byte6`).
- **Converted:** constants in NativeZip (signatures), MQTT (protocol name, `$share/`), the docs, and the
  benchmarks. Array literals still work.

The first version built the value with `init(bigEndian:)`, and `static let signature: Byte4 = 0x50_4B_01_02`
then cost **41% more instructions** parsing fixed-size zip records (281 vs 199 K).

- **Why:** with the array literal, the compiler evaluated the global's initializer at compile time, so
  each use was a `mov`/`movk` constant. With the integer literal, the global stayed lazily initialized: a
  `swift_once` check and a load on every use.
- **The cause:** `init(bigEndian:)` byte-swaps, and the compile-time evaluator can't fold a byte swap (an
  LLVM intrinsic). Swapping back to an interpolated precondition message didn't matter.
- **The fix:** the literal initializer reverses the bytes with shifts. Constant again, no `swift_once`.

Against `safe-final`: field parsing −3% instructions, fixed-size records −1%, signature search −4%
(baseline `literals3`). These didn't hold at HEAD, where the parser's machine code is unchanged: see
the 2026-11-09 section. NativeZip's parsing (computed-property signatures) was unaffected either way.

A `static let` built with a byte order still has the lazy-initialization cost. Checked:
`static let signature = Byte4(0x504B_0102, .bigEndian)` compiles to the `swift_once` check again. Write
constants as literals, or as computed properties.

## Group operations: `ByteGroup` operators, `forEach` with a byte order, and the table CRC

Superseded for the CRC (2026-11-12, "fast portable builds"): the table path is now braided, five
interleaved CRCs, 3.6x faster at 256 KB than the slicing-by-8 measured here. The group operators and
`forEach` with a byte order are unchanged.

The table-driven CRC (the portable path) was written with hand shifts and masks:
`tables[6][Int(word >> 8 & 0xFF)]`, eight times over. Rewritten with `Bytes` APIs:

```swift
reader.forEach(Byte8.self) { group in
    let bytes = group ^ Byte8(UInt64(state), .littleEndian)        // new: byte-wise `^` on groups
    state = 0
    for index in 0..<8 { state ^= tables[7 &- index][Int(bytes[index])] }   // byte subscript, no shifts
}
reader.forEach(Byte.self) { byte in state = state >> 8 ^ tables[0][Int(state[Byte.self, at: 0] ^ byte)] }
```

Benchmarks `CRC-32 tables, …`, 32 MB per iteration:

| Variant | 256 KB in cache | 64 B inputs |
|---|---|---|
| Original (shifts and masks, `[[UInt32]]`) | 336 M instructions, 14.0–15.0 ms | 364 M, 12.0–12.7 ms |
| **Bytes APIs, `[[UInt32]]`** (kept) | **180 M**, 14.1–14.4 ms | **219–223 M, 8.8–9.4 ms** |
| Bytes APIs, `InlineArray<8, InlineArray<256, UInt32>>` | 139 M, 15.3–15.7 ms | 167 M, 9.6–10.0 ms |
| Bytes APIs, split into halves (`lowHalf`/`highHalf`) | 235 M, 14.4 ms | 261 M, 11.1 ms |

- **The rewrite** halves the instructions (each byte becomes one `ubfx` and one indexed load). It's 27%
  faster on short inputs and equal on long ones. Long inputs are bound by the latency of the lookup
  chain, not by instructions.
- **`InlineArray` tables** remove the bounds checks (a byte index can't pass 255) and cut instructions
  further. They're still 7% slower: with one global table, each lookup is an `add` and then an
  `ldr [x, #offset]`, one more cycle on the latency chain.
  - With eight arrays, each table's base is a register, so a lookup is a single
    `ldr w, [table, index, lsl #2]`, and LLVM checks the arrays' bounds once, before the loop.
  - Padding the tables apart (1,056-byte stride) changed nothing, so cache conflicts aren't the cause.
- **Splitting into halves** puts the four state-independent lookups off the critical path. It cost
  instructions without gaining time.

**`forEach(T.self, byteOrder) { integer in … }`** is new, the loop counterpart of `read(T.self, byteOrder)`.
It's exactly as fast as converting in the body: identical instruction counts and times for `Byte2`,
`Byte3`, `Byte4`, `Byte6`, and `Byte8` (benchmarks `forEach(ByteN.self …), 4 MB`). It's sugar, and the
CRC's hardware tail uses it.

**`ByteGroup` gets `^ & | ~`** (and the compound forms), byte by byte in memory order. No byte order is
involved, so they can't be ambiguous the way integer literals or shifts on a group would be. That's why
there are no shifts on groups: "shift by a byte" depends on which end is first, and the byte subscript
and halves already say which byte is meant.

## `CRC32` (measured in NativeZip's benchmarks, against zlib's `crc32_z`)

| Input (32 MB per iteration) | `CRC32` | zlib | |
|---|---|---|---|
| 32 MB | 532 µs (63 GB/s), 10 M instructions | 888 µs (38 GB/s), 13 M | 1.7x |
| 256 KB, in cache | 460 µs | 833 µs | 1.8x |
| 1 KB | 665 µs | 1,279 µs | 1.9x |
| 64 B | 3,084 µs | 6,963 µs | 2.3x |

- **Large inputs:** eight 16-byte accumulators fold 128 bytes per step: per lane, a `pmull`, a `pmull2`,
  and an `eor3` with the next 16 bytes, independent chains so the multiplies' latency overlaps. At the
  end, the lanes fold into one, and the CPU's CRC32 instructions reduce its 16 bytes.
  - The constants are x^(n ± 32) mod P, bit-reflected. A test derives them; the 128- and 512-bit ones
    match Linux's.
- **Below 256 bytes:** `crc32x`, 8 bytes at a time.
- **Bytes tools do the reading:**
  - Each 128-byte step is a fixed-size sub-cursor, so its eight loads compile to four `ldp q` with no
    bounds checks.
  - The tails are `forEach(Byte8.self)` and `forEach(Byte.self)`.
  - The file has no `unsafe`: the C wrappers take and return values.
- **First version 3.5x slower than zlib:**
  - The nested helper that loaded each 16 bytes wasn't inlined. As a call per load, it spilled the eight
    accumulators every time.
  - `@inline(always)` on it gave the loop above (16 `pmull`, 8 `eor3`, 4 `ldp`, ~10 bookkeeping
    instructions per 128 bytes).
- **Other CPUs:** tables (slicing-by-8 then, braided since 2026-11-12). The tests check them against a
  bit-at-a-time reference too.

## Safe constructs instead of unsafe ones (baselines `pre-safety` → `safe-final`)

Every `unsafe` site was tried with its safe standard-library counterpart (`RawSpan.load`,
`MutableRawSpan.storeBytes(of:toByteOffset:as:)`, checked `extracting`, `MutableSpan` subscripts,
`UniqueArray`, `bitCast`) and measured. Instruction counts are the deciding metric (deterministic).

**Kept safe** (no cost, or faster):

| Change | Effect |
|---|---|
| `read(byteCount:)` and `read(_:count:)` use checked `extracting` | Fixed-size records **−21% instructions, −31% time** (199 vs 253 K, 7.3 vs 10.6 µs); field-by-field +3% instructions (301 vs 291 K), same time |
| `HuffmanTable`: `UniqueArray` storage, `Span`/`MutableSpan` indexing in decode and build, `InlineArray` scratch up to 320 symbols | Equal (NativeZip small files 239 vs 239 M) |
| `Shuffle` reinterpretations: `unsafeBitCast` → `bitCast` | Equal |
| Distance-1 match fill: `storeBytes(repeating:)` instead of `initializeMemory` | Equal |
| LEB128 slow paths, section move, unaligned `store`, `BitBuffer` slow refill | Cold paths |

Building `HuffmanTable` safely first cost 5% more instructions on small DEFLATE files. Not the checks:
a nested function that captured the entry closures stopped them being inlined. As a static function, equal.

**Kept unsafe** (each with a comment saying why), because the checked forms measured slower:

| Site | Checked cost |
|---|---|
| `Load` (all cursor reads) | Field-by-field +24% instructions; `Byte3`/`Byte5`–`Byte15` 2–8x; bulk loops stop vectorizing |
| `Store`, `_copy`, `_move` (all writer stores and match copies) | Odd widths +42–144% instructions, packed bit fields +28–47% |
| `BitBuffer.refill` fast path | DEFLATE +10% instructions |
| `lowBytes` (9–15-byte custom types) via `withUnsafeBytes(of:)` | Through an `InlineArray` span: +46% instructions |
| Bulk reads into `OutputSpan`, `Iteration`'s buffer stores | Per-value checks stop vectorization |

The pattern: the standard library's check is `UInt(offset) <= UInt(count) && size <= count - offset`,
and the first half needs `offset >= 0`, which the cursor deliberately doesn't state (see "Making loops of
single reads vectorize"). So it isn't folded into the cursor's own check, except where the offset is
visibly non-negative (constants, or loops counting up from 0). With no safe in-place copy, no safe view of
an `OutputSpan`'s uninitialized capacity, and no safe span-to-`Array` copy in the standard library,
`memmove` in `write(_:RawSpan)`, `withBytesWriter`, and `[UInt8](copying:)` stay unsafe too.

## Bit fields of values already read

From a survey of MQTT's and NativeZip's integer escapes: `value[bit: i]`, `value[Bits<w>.self, at: i]`
(as `Bits`), and `value[bits: range]` on integers, all settable; `Bits` fields (`flags[Crumb.self, at: 1]`);
and `init?(rawBits:)` for raw-value types. They replace NativeZip's DOS date/time shifts and masks, its
attribute and version tests, and MQTT's PUBLISH flags packing and `.rawValue` hops. Positions are
constants, so the range checks fold: NativeZip's central-directory parse is 1% fewer instructions than
before (4,907 vs 4,960 K, baseline `bytes` → `safe-parse`).

## Decoder support (driven by NativeZip's DEFLATE decoder)

Writing a DEFLATE decoder on `Bytes` (`../NativeZipArchive`, `Inflater.swift`; it beats zlib, 13 vs 14 ms
for 32 MB of text, 0 allocations; details in that package's RESULTS.md, step6) needed these additions:

- **`BitBuffer`**: 64 bits in a register, a branch-free refill (one unaligned load, `bits |= word << count`,
  `next += (63 - count) >> 3`, `count |= 56`), and no per-read end check: past the data it reads zeros,
  and `isOverrun`/`finish()` reports it once per block. Both bit orders. `BytesReader.withBitBuffer` and
  `finish()` convert back to a cursor.
- **`HuffmanTable`**: a canonical-code table for both bit orders (DEFLATE/Brotli least significant bit
  first, JPEG most), and the generic `HuffmanTable.build(…into:invalid:symbol:subtable:)` that fills a table
  of the caller's own entry type. It's libdeflate's builder: root entries written once, doubled with
  `memcpy`. Moving the inflater's private builder onto it cost nothing measurable (14 vs 14 ms small files).
- **`BytesWriter.copy(fromDistance:count:)`** (exact) and the `allowingOverrun:` variant that moves 16 or
  8 bytes at a time and may write `copyOverrun` (32) bytes past the copy; `write(_:byteCount:allowingOverrun:)`
  for word-sized stores; `skip(byteCount:)`.
- **`bitReversed`** on `UInt8`–`UInt64` and `Bits` (`Builtin.int_bitreverse`, one `rbit`).
- **`peekBitWindow()`** on `BytesReader`, **`bitPosition`** and **`seek(toBitPosition:)`** (a resumable decoder
  stores one integer: `seek(toByteOffset:)` + `skip(bitCount:)` before).
- **`[UInt8](copying: RawSpan)`**.

Inlining was the main lesson: `@inline(__always)` is a hint, and LLVM's inliner refused it for the match
copy in a large function, which then took the writer by address and kept it in memory: 2x slower. The hot
decoder APIs are `@inline(always)` (SE-0496, guaranteed), and the decoder keeps its `BitBuffer` and
`BytesWriter` as locals of small functions.

API review afterwards: `BitBuffer.peek(_:)`/`consume(_:)` renamed `peek(bitCount:)`/`consume(bitCount:)`,
matching `BytesReader.peek(bitCount:)`, `read(bitCount:)`, and `skip(bitCount:)`. Considered and not added: a
byte-sized write overload (`write(Byte(…))` is what the inflater's literal path uses), and a sliding-window helper
for the writer (NativeZip alternates two buffers, which a single-writer helper doesn't fit).

## Review fixes

A review of the whole library found two bugs, both fixed with regression tests:

- **Bulk reads of a `ByteGroup` defined outside the package** with a wider `Integer` than the lane (e.g. a
  5-byte group over `UInt128`) stored NEON lanes into the wrong slots and left values uninitialized. The
  NEON paths now also require the integer to be the lane size; the check folds to a constant.
- **An over-long LEB128 at the end of the data** (`80 80 80 80`, limit 4) threw `insufficientData`, so a
  streaming parser would wait for bytes that can't help. It now throws `invalidValue`. So does a length
  prefix too large for an `Int`.

Smaller fixes: `Bits >>` with a negative count is masked like `<<`; `<<=`/`>>=` added; `isSet(at:)` removed
(the `bit:` subscript does it); `seek(toByteOffset:)` throws for a negative offset; `read(section:)` renamed
`readSection(byteCount:)`; the LEB128 section writer's `maxByteCount` is now required (a default of 10
always moved the section); unused code removed; docs corrected where they overstated guarantees.

## Writing (`BytesWriter`)

`BytesWriter` mirrors `BytesReader`: `write` for `Bits`, byte groups with a byte order, `ByteRepresentable` types,
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
error ("overlapping accesses to 'cursor'"), while the same code with `BytesReader` compiles. Reading
through a `MutableRawSpan` would be no faster either: the loads are identical. So `BytesReader` reads
shared memory and hands out spans that outlive it; `BytesWriter` writes exclusive or uninitialized memory.
Patching data in place is a `BytesReader` pass and a `BytesWriter` pass over the same memory, one after the other.

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

Superseded in part (2026-11-12): `GroupShuffle`, portable constant shuffles, now handles these widths for
iterators (`for`-`in`) in every build, and for bulk reads, writes, and staged `forEach` wherever
`ByteLanes.isLookupVectorized` is false. This section describes the NEON `Shuffle`, still used otherwise.

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
  `Byte16` loops fully scalar (32 against 56 GB/s). Its loads and byte swaps stay scalar either way
  (`ldp`, two `rev` on general registers), because LLVM's cost model declines two-lane 64-bit vectors for
  them, and Swift has no loop pragmas to override it. Only the benchmark's sum is vectorized, fed through
  `fmov`/`mov.d`, which is why `Tools/loops` calls the loop `vector128` (2026-11-09: no SIMD loads at run
  time). It reaches 56 GB/s on one core and the memory ceiling with all cores.

## The standard library's `ConvertibleFromBytes`

Only standard library types can conform (integers, `Float16`/`Float`/`Double`, `Duration`, `SIMD2`–`SIMD64`,
and `InlineArray`s of them), but `BytesReader` can read those (baseline `zerocopy`):

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
for 4 bytes. The library can't change how `Span` loads its elements; `forEach` stays the path that's at raw
speed for every size.

## `for`-`in` (`Iterable`)

`BytesReader` conforms to the standard library's `Iterable` (macOS 27): `for byte in reader` iterates the unread
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

The views are `Copyable`, so a `let` costs nothing. `for byte in reader` over a `let reader` (`~Copyable`)
heap-allocates the cursor once per loop: a compiler issue, see "Allocation checks". Use a `var` reader.

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
  a byte holds 8 of them, so `Bit` needs ~7 cores to match one core's raw reads (77 GB/s); with all cores
  it reaches the ceiling (237 GB/s).
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
- Fixed-size record (`BytesReader(try reader.read(byteCount: 46))`, then fields): no per-field checks at all,
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
