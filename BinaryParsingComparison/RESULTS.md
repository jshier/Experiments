# Bytes vs swift-binary-parsing

`Bytes` (../Bytes) against Apple's [swift-binary-parsing](https://github.com/apple/swift-binary-parsing)
0.0.4 (`BinaryParsing`, `ParserSpan`) on the same work. Two directions:

- Our parsers ported to `ParserSpan`: the zip central directory and integer runs.
- Two of its example parsers, QOI and LZ4, ported to `Bytes`.

The example parsers are also measured as published (`Sources/Workloads/Example*.swift`, copied with only
their types renamed). Every variant of a workload produces identical output (`swift test`): the LZ4
decoders reproduce the original files, and the QOI decoders match the example's pixels.

Medians from `swift package --disable-sandbox benchmark`, M3 Ultra, macOS 27.2, Swift 6.4.2.

## Results

| Workload | Bytes | `ParserSpan` | Example as published |
|---|---|---|---|
| Zip central directory, 2,000 entries, field by field | **11 µs**, 301 K instr | 23 µs, 461 K | — |
| …each 46-byte header as a sub-cursor/slice | **7 µs**, 199 K | 13 µs, 325 K | — |
| 192 K big-endian `UInt32`s (768 KB) | 10 µs, 197 K | 10 µs, 197 K | — |
| 256 K big-endian 24-bit values | **55 µs**, 1,426 K (`forEach`: 48 µs, 771 K) | 158 µs, 4,461 K | — |
| QOI `antelope.qoi` (1833×1222, 5 MB), same algorithm | 7.9 ms, 129 M | 8.0 ms, 138 M | 35 ms, 764 M |
| …Bytes with run fills (`write(repeating:)`) | **7.6 ms**, 111 M | | |
| QOI `tricolor.qoi` (600×600, 98.5% runs), same algorithm | 215 µs, 5.9 M | **176 µs**, 4.6 M | 4.4 ms, 104 M |
| …Bytes with run fills | **67 µs**, 1.5 M | | |
| LZ4 `swift-help` (10.6 MB from 3.8 MB), same algorithm | 4.2 ms, 63 M, 2 mallocs | 4.5 ms, 66 M, 2 | 189 ms, 3,113 M, 706 K mallocs |
| …Bytes with overrun literal copies | **2.5 ms**, 48 M, 2 | | |
| LZ4 `tricolor.qoi` (22 KB), same algorithm | 8.3 µs, 208 K | 9.3 µs, 218 K | 375 µs, 2,397 mallocs |
| …Bytes with overrun literal copies | **7.2 µs**, 160 K | | |

(QOI and LZ4 rows: 2026-11-09, round 2 of the interleaved runs below.)

"Same algorithm" rows run the example's algorithm with either library reading the input; both write output
with `BytesWriter`. (`BinaryParsing` only parses.) The `…` rows are the Bytes ports as they are now, with
Bytes APIs `ParserSpan` has no counterpart for on the output side; the `ParserSpan` ports are kept as they
were, against the shipping library.

## Why

**Field-by-field parsing: Bytes is 2x faster.** From the generated code, three reasons, each from
`ParserSpan`'s implementation rather than its API shape:

1. **Overflow-checked advance.** After the bounds check, `consumeUnchecked` advances with
   `_lowerBound += MemoryLayout<T>.stride`, a trapping add: `adds` + `b.vs` on every field. The bounds
   check already proves the add can't overflow. Bytes uses `&+=` there, so a field is `add, sub, cmp, b.le`
   and a load, against `adds, b.vs, sub, cmp, b.le` and a load.
2. **Error locations.** Every throw builds a `ParsingError` carrying that site's byte offset, so each
   failing read has its own throw path. The function is 2.6x larger (568 against 220 instructions), and
   register pressure spills the cursor's position to the stack (`stur`/`ldur` in the loop). Bytes' failing
   reads all branch to one shared throw.
   - Bytes gets locations for free: a throwing read consumes nothing, so after `catch`,
     `reader.byteOffset` is where the failing read started.
3. **Out-of-line slicing.** `sliceSpan(byteCount:)` is generic over `some FixedWidthInteger` and wasn't
   inlined: three calls per entry. The call also hides the slice's length from the optimizer, which is
   why reading the fixed 46-byte header as a slice saves `ParserSpan` 29% of instructions, where Bytes'
   sub-cursor (whose length is a visible constant, so every field check folds) saves 34%.

**Standard-width integers: identical.** Both are one check and one load per value, and both loops
vectorize.

**Odd widths: Bytes 2.9x faster (3.3x with `forEach`).** `ParserSpan` reads a 24-bit value with
`byteCount: 3`: it slices off 3 bytes, then folds them in one at a time (`reduce`), about 17 instructions
per value. `Byte3` is two overlapping 2-byte loads and a combine (5.4 per value); `forEach` turns them into
NEON `ld3` (2.9 per value).

**Decoders (QOI, LZ4): about equal; the examples' output handling dominates.**
- **Same algorithm:** within 5% on the large inputs. The work is the decoding, not the reads, and both
  libraries' byte reads compile to a load and a compare.
- **Small QOI image:** `ParserSpan` won by 30% in instructions. The image is 98.5% runs, a path with no
  reads at all, identical in source in both ports. The difference is the whole loop's register
  allocation: the Bytes build keeps the pixel widened to 16-bit lanes and narrows it on every store.
- **The published examples** are 4–42x slower, for reasons outside the parsing library:
  - QOI appends each pixel to a `Data` (`append(_:count:)` through `withUnsafeBytes`), and keeps the
    64-entry cache in an `Array`.
  - LZ4 builds each block in a `Data` and copies every match through a new `Array` (706 K allocations for
    10 MB). The example's own TODOs point at `OutputSpan` for this.
  - The ports write into preallocated memory with `BytesWriter` (16-byte match copies for LZ4) and keep
    the cache in an `InlineArray`.

**A Bytes caveat this exposed.** The first QOI port captured its cursors in the closures passed to
`[UInt8](capacity:)` and `withBytesWriter`, which weren't inlined, so the cursors lived in memory. Both
libraries slowed down, and Bytes more: with its bit offset and bit order in memory, every byte read
re-checked them (`cbz` on the bit offset, the unaligned path's bit-order reload). Keeping the cursors as
locals of one function made both faster (Bytes 9.9 → 7.8 ms, `ParserSpan` 10.6 → 7.9 ms). The README's
caveat about cursors passed `inout` to closures applies, and it applies more to Bytes than to a
byte-only cursor.

## Adopted into Bytes

- **`atomically { }`:** all-or-nothing reads, extending the guarantee that a throwing read consumes
  nothing to several reads (`ParserSpan.atomically`).
- **`read(Int.self, as: Byte8.self, .littleEndian)`:** throws `.invalidValue` instead of trapping when an
  untrusted value doesn't fit (`Int(parsing:storedAsLittleEndian:)`).
- **`ByteGroup.signedInteger(_:as:)`:** sign extension for odd widths
  (`Int32(parsing:endianness:byteCount:)` handles signed types). Our own guide had used
  `Int32(bitPattern: x << 8) >> 8`.

## Considered, not adopted

- **Optional and throwing arithmetic** (`+?`, `*?`, `multipliedThrowingOnOverflow`): useful for
  validating untrusted sizes, but general-purpose, not about reading bytes. The standard library's
  `…ReportingOverflow` covers it.
- **`ParserRange` and `seeking(toRange:)`:** deferred sub-ranges of the input. `Bytes` has `byteOffset`,
  `seek(toByteOffset:)`, and `read(byteCount:)`, and the standard library has `RawSpan.byteOffsets(of:)`.
  NativeZip already uses them for the same pattern.
- **Error locations in the error value:** measured above as part of `ParserSpan`'s 2x. Bytes' cursor
  position is the location already.
- **`#magicNumber("qoif", parsing:)`:** an ASCII magic-number macro. Hex literals of the bytes
  (`0x71_6F_69_66 as Byte4`) now read the same as the file, without a macro.
- **`ExpressibleByParsing`** (`init(parsing: some RandomAccessCollection<UInt8>)`): a convention for types
  that parse themselves from `Data` or `Array`. Bytes takes spans (`data.span`), which every contiguous
  collection now offers.

## What swift-binary-parsing could take from Bytes

- Advance with `&+=` after the bounds check.
- Make `sliceSpan(byteCount: Int)` non-generic (or `@inline(__always)`), so slices inline and their
  lengths fold.
- Odd widths from two overlapping loads instead of a byte loop.
- A shared throw path per function, if error locations can be recovered another way.

## 2026-11-09: current Bytes API, re-check

Baselines `original` (the code before this pass) and `modern` (after), `Tools/bench-table
BinaryParsingComparison original modern`. Same Bytes API as above, swift-binary-parsing still 0.0.4 (the
latest tag), Swift 6.4 (Xcode 27.3). `original`'s times were taken while other agents loaded the machine;
`modern` was re-run alone afterwards, so its times run a median 8.6% faster than `original`'s with
identical instruction counts: that's the machine, not the code. The comparison below is by instruction
and allocation counts, which are stable.

**Bytes side updated** (the `ParserSpan` side and every algorithm unchanged):
- Untrusted sizes read straight into `Int` with `read(Int.self, as: Byte2.self, .littleEndian)` (zip name,
  extra, comment, and extra-field lengths; LZ4 match distance; QOI width and height as `Byte4`
  big-endian), the counterpart of `Int(parsing:storedAsLittleEndian:)` on the `ParserSpan` side. For LZ4's
  8-byte content size this is also a fix: `Int(read(Byte8…))` trapped on a size above `Int.max`; it now
  throws `.invalidValue`.
- Sub-cursors with `readSection(byteCount:)` instead of `BytesReader(read(byteCount:))` (zip header,
  extra field block, each extra field).
- Already current and left as they were: byte-group literals (`0x71_6F_69_66 as Byte4`), bit-field
  subscripts (`first[Crumb.self, at: 6]`, `size[bits: 0..<31]`, `flags[bit: 5]`), `highHalf`/`lowHalf`,
  `forEach(_:_:)` with a byte order, `copy(fromDistance:count:allowingOverrun:)` for LZ4 matches.

**Cost: none.** Every Bytes and `ParserSpan` row has the same instruction and malloc counts in `original`
and `modern` (and as in the table above). `Tools/loops` verdicts are unchanged for every function; the one
structural change is in `LZ4.decodeWithBytes`'s frame-level loop (one more nesting level, 256 → 271
instructions: the content size's new `.invalidValue` throw path), which runs once per block and doesn't
show in the counts. `Tools/calls`: no new runtime calls in the Bytes functions.

**Bytes vs `ParserSpan` now** (instructions; the ratio is `ParserSpan`'s count over Bytes'):

| Workload | Bytes | `ParserSpan` | Ratio |
|---|---|---|---|
| Zip directory, field by field | 301 K | 461 K | 1.53 |
| …fixed-size records | 199 K | 325 K | 1.63 |
| `UInt32` big-endian | 197 K | 197 K | 1.00 |
| 24-bit big-endian, per value | 1,426 K (`forEach`: 771 K) | 4,461 K | 3.13 |
| QOI `antelope.qoi` | 131 M | 138 M | 1.05 |
| QOI `tricolor.qoi` | 6.57 M | 4.59 M | 0.70 |
| LZ4 `swift-help.lz4` | 65 M, 2 mallocs | 66 M, 2 | 1.02 |
| LZ4 `tricolor.qoi.lz4` | 216 K | 219 K | 1.01 |

**The explanations above still hold** (checked in the release object of `Workloads`):
- Trapping adds: `parseWithParserSpan` has 20 `adds` + `b.vs` pairs, `parseWithParserSpanRecords` 2;
  the Bytes functions none.
- Per-site throw paths: `parseWithParserSpan` is 563 instructions against `parseWithBytes`' 219
  (568/220 before), with 8 `stur`/`ldur` stack accesses against none; `Tools/calls` shows 12
  `swift_allocError` and 20 `ParsingError` witness-table accessor call sites in it, against 1 and 3.
- Out-of-line slicing: `specialized ParserSpan.sliceSpan<A>(byteCount:)` is still a call, at 2 call
  sites in each `ParserSpan` zip function.
- 24-bit values: the `ParserSpan` loop is 17 scalar instructions per value; Bytes' per-value loop and
  `forEach` are `vector128`.
- QOI `tricolor.qoi`: the Bytes build's run-pixel loop is 17 instructions (`uzp1.8b` + `fmov` narrowing
  the pixel on every store, and the input's `remainingByteCount >= 8` recomputed each pixel), the
  `ParserSpan` build's 11. Neither the bit-field subscripts nor the `Byte3` read cause it: variants with
  shifts and masks, or three single-byte reads, have the same loop and counts (6.57 M).

**Prototyped Bytes APIs** (measured, then removed; details in this run's API proposals):
- Copying LZ4 literals with a fixed-size move and overrun (`writer.write(from: &reader, byteCount:,
  allowingOverrun: true)`): 65 → 51 M instructions on `swift-help.lz4` (−22%), 216 → 172 K on
  `tricolor.qoi.lz4`.
- Writing a QOI run at once (`writer.write(repeating:byteCount:count:)`): 6.57 → 2.27 M on
  `tricolor.qoi` (−65%), 131 → 106 M on `antelope.qoi` (−19%).
- Both change the decoding algorithm, so they'd have to go into both ports to keep the comparison fair;
  not adopted here.
- An error-location wrapper taking a closure cost 15% (301 → 345 K) because the closure wasn't inlined;
  `catch { throw reader.located(error) }` cost 1.3% (305 K). Wrapping each zip entry in `atomically { }`
  cost 50% (453 K) for the same reason: the closure body isn't inlined, so the cursor lives in memory and
  14 calls to the unaligned slow path appear (see the README's caveat about closures).

## 2026-11-09: run fills and overrun literal copies, Bytes side only (baselines `ab-old-*` → `ab-new-*`)

Bytes now has the two APIs prototyped above, and the Bytes ports use them:

- QOI: a QOI_OP_RUN is one `writer.write(repeating: pixel, byteCount: channels, count: run)`, cut off at the
  end of the image as the pixel loop was. The run counter and its per-pixel `guard` are gone.
- LZ4: literals are `writer.write(from: &reader, byteCount: literalCount, allowingOverrun: true)`: 16-byte
  steps while both cursors have room (most literal runs are under 16 bytes, so one load and one store).

The `ParserSpan` ports are unchanged, against the shipping swift-binary-parsing. To keep a like-for-like
comparison, the previous Bytes algorithm stays as `decodeWithBytesPixelRuns` and
`decodeWithBytesExactLiterals`, benchmarked as "Bytes, pixel-at-a-time runs" and "Bytes, exact literal
copies", which is what the "ParserSpan, same algorithm" rows now compare with. Each pair shares one
`@inline(always)` body with a constant flag. For LZ4, LLVM merged the two wrappers into one function and
specialized the block decoder's closure once with the flag as a run-time argument (both variants then tested
it per sequence), so the flag is passed as a literal at each inlined call inside the closure; it's now
tested once per block. QOI's two variants compiled separately.

Interleaved runs of the previous commit's tree (`ab-old-*`) and this one (`ab-new-*`), two rounds; times
are round 2, instructions exact minimums from the baselines:

| Workload | Bytes before | Bytes now | Change | Bytes, same algorithm as before | `ParserSpan` |
|---|---|---|---|---|---|
| QOI `tricolor.qoi` | 6.57 M, 227 µs | 1.52 M, 67 µs | −77% instr, −70% time | 5.87 M, 215 µs | 4.58 M, 176 µs |
| QOI `antelope.qoi` | 130.4 M, 7.85 ms | 111.2 M, 7.64 ms | −15%, −3% | 128.6 M, 7.87 ms | 137.7 M, 7.96 ms |
| LZ4 `swift-help.lz4` | 64.9 M, 4.36 ms | 48.1 M, 2.53 ms | −26%, −42% | 62.7 M, 4.16 ms | 65.8 M, 4.51 ms |
| LZ4 `tricolor.qoi.lz4` | 216 K, 8.3 µs | 160 K, 7.2 µs | −26%, −13% | 208 K, 8.3 µs | 218 K, 9.3 µs |

Compared with the prototypes: QOI `tricolor.qoi` 2.27 → 1.52 M (the run fill stores 16 bytes at a time
where the prototype stored 8), LZ4 51 → 48 M (one 16-byte move where the prototype used two 8-byte stores).

The same-algorithm Bytes variants also moved, with no change to their decoding source: the same code now
compiled in a different place (inlined from the shared body, next to its other variant).
- LZ4 exact literals, 64.9 → 62.7 M (−3.4%). Not from Bytes' new inline copy of 33–64-byte spans: both
  LZ4 ports call `write(_: RawSpan)` out of line (`Tools/calls`), and the `ParserSpan` port, whose literals
  take the same call, moved −0.1%.
- QOI pixel-at-a-time runs, `tricolor.qoi` 6.57 → 5.87 M (−11%), `antelope.qoi` −1.4%: the run loop the
  earlier analysis found to be the gap to `ParserSpan` (register allocation) compiled differently. It
  remains 1.28x `ParserSpan`'s instructions on `tricolor.qoi`.

So the "before → now" columns above include a few percent of layout change; the "same algorithm" column is
the clean measure of what the new APIs give (QOI `tricolor.qoi` 5.87 → 1.52 M, LZ4 62.7 → 48.1 M).

Later again (baselines `bcd2-old-*` → `bcd2-new-*`): Bytes' `write(_: RawSpan)` is now inlined (it was a
call per literal run, in both LZ4 ports, since both write output with `BytesWriter`); the Bytes LZ4 port
builds its output with `append(byteCapacity:) { (writer) throws(BytesError) in … }`; the Bytes zip-directory
port reads extra fields with `read(sectionPrefixedBy:)`, which now checks the length once. The
`ParserSpan` source is unchanged, but its output side changed with Bytes:

| Workload | Instructions | Time (rounds 1 / 2) |
|---|---|---|
| LZ4 `swift-help.lz4`: Bytes | 48.1 → 46.0 M (−4.4%) | −6% / +6% (noise) |
| …Bytes, exact literal copies | 62.7 → 49.6 M (−21%) | −10% / −8% |
| …`ParserSpan` | 65.8 → 55.5 M (−15.6%) | −10% / −11% |
| LZ4 `tricolor.qoi.lz4`: Bytes / exact / `ParserSpan` | −4.6% / −21% / −16% | 0% / −15% / −7 to −11% |
| Zip directory: Bytes | 300.6 → 298.6 K (−0.7%) | within noise |
| Zip directory: `ParserSpan`, fixed-size records (both) | unchanged | unchanged |

So the LZ4 `ParserSpan` rows above now measure `ParserSpan` input with a faster Bytes output side than
before; the like-for-like comparison is the same-algorithm Bytes row (49.6 M) against `ParserSpan`
(55.5 M).

Later the same day (baselines `fu3-old-*` → `fu3-new-*`): Bytes builds the run fill's 16-byte pattern with
two multiplies instead of 128-bit doubling, and copies matches 2–7 bytes back as runs. QOI `tricolor.qoi`
(Bytes): 1.52 → 1.32 M instructions (−13%; its time moved with the run's drift, −8 to −10% on every row,
`ParserSpan` included). `antelope.qoi` −0.2%; LZ4 ±0.7% (few of its matches are under 8 bytes back). The
`ParserSpan` and same-algorithm rows are unchanged.

Untouched rows (the published examples, every `ParserSpan` row) moved under 0.5% in instructions and
within ±6% in time.

## 2026-11-10: Bytes' conveniences in the Bytes ports (baselines `conv-old-*` → `conv-new-*`)

The `ParserSpan` ports are unchanged. In the Bytes ports: the zip directory's extra fields with
`forEachRecord(tag:length:_:_:)` and the timestamp with `readSigned(_:_:as:)` (the fixed-size-record
variant, `readSigned` only), and LZ4's frame-descriptor check as two `matches(_:mask:)` (version 01,
reserved bits clear, independent blocks) instead of six field tests.

| Workload | Instructions | Time (rounds 1 / 2) |
|---|---|---|
| Zip directory: Bytes | 298.6 → 284.6 K (−4.7%) | −2.0% / −4.9% |
| Zip directory, fixed-size records: Bytes | unchanged (198.6 K) | within noise |
| LZ4, both inputs, Bytes and exact-literals ports | unchanged (±32 instructions) | within ±3% (one +10.5% round) |
| Every `ParserSpan` row and the published examples | within 0.1% | within noise |

So the zip-directory comparison is now 284.6 K (Bytes) against 460.6 K (`ParserSpan`). `forEachRecord` is
the same algorithm as the loop it replaces (tag, length, all of the value or an error), written once: the
record loop got cheaper because it checks the header once and doesn't go through
`read(sectionPrefixedBy:)`. The same change could be made to the `ParserSpan` port with its own API.
