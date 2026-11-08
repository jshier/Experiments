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
| QOI `antelope.qoi` (1833×1222, 5 MB) | **7.8 ms**, 130 M | 7.9 ms, 138 M | 34.8 ms, 764 M |
| QOI `tricolor.qoi` (600×600, 98.5% runs) | 233 µs, 6.6 M | **182 µs**, 4.6 M | 4.4 ms, 104 M |
| LZ4 `swift-help` (10.6 MB from 3.8 MB) | **4.2 ms**, 65 M, 2 mallocs | 4.4 ms, 66 M, 2 | 172 ms, 3,107 M, 706 K mallocs |
| LZ4 `tricolor.qoi` (22 KB) | **8 µs** | 9 µs | 376 µs, 2,397 mallocs |

The QOI and LZ4 ports run the same algorithm with either library reading the input; both write output
with `BytesWriter`. (`BinaryParsing` only parses.)

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
