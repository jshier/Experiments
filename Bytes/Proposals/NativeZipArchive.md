# Bytes API proposals from NativeZipArchive

Gathered while modernizing NativeZip to the current Bytes API (2026-11-09). Most valuable first. Each was
prototyped as an internal extension in a copy of NativeZip (a scratch copy), used at one call site,
and compared by disassembly of the whole NativeZip object (`Tools/loops`/`Tools/calls` plus an
`objdump` diff with addresses and label numbers normalized) and, where codegen changed, by benchmark
instruction counts. All prototypes were reverted; none is kept as an internal helper (reasons per item).

Line numbers are for the files as left by this run.

---

## 1. A packed Huffman entry type and a generic table lookup (DEFLATE-style decoders)

**Motivation.** `Sources/NativeZip/Inflater.swift:12–60` (the `HuffmanEntry` type: packing, four field
accessors, `extra(_:)`) and `Inflater.swift:352–372` (`lookup`, `rootEntry`, `resolve`). Every fast
DEFLATE/Deflate64/PNG/zstd-Huffman decoder written on Bytes needs exactly this: `HuffmanTable.build`
already lets the caller choose the entry type, but `HuffmanTable.decode` only works with the built-in
table, so anyone using a custom entry re-implements the root/subtable lookup and the bit layout. ~60 lines
here, and the layout constraints (total bits in the low 6 bits so `consume` can shift by the raw entry;
lookup ahead before refill) are subtle and were the result of measurement.

**Proposed API.**

```swift
/// A 32-bit table entry in libdeflate's layout: bits 0–5 total bits to consume (code + extra), 8–11
/// code length (subtable index width for links), 12–14 kind, 16–31 value.
public struct HuffmanEntry: BitwiseCopyable, Hashable, Sendable {
    public enum Kind: UInt32 { case symbol, base, endOfBlock, subtable, invalid }
    public var raw: UInt32
    public init(codeLength: Int, kind: Kind, value: Int, extraBits: Int = 0)
    public var totalBits: Int { get }        // raw[bits: 0..<6], for consume(bitCount:)
    public var codeLength: Int { get }
    public var kind: Kind { get }
    public var value: Int { get }
    /// `value` plus the extra bits that follow the code in `bits` (least significant first).
    public func extra(_ bits: UInt64) -> Int
}

extension HuffmanTable {
    /// The root entry for the next `rootBits` bits: needs only `rootBits` valid bits.
    public static func rootEntry(in table: Span<HuffmanEntry>, _ bits: UInt64, rootBits: Int) -> HuffmanEntry
    /// `entry`, or for a subtable link, the subtable's entry for the bits after the root's.
    public static func resolve(_ entry: HuffmanEntry, in table: Span<HuffmanEntry>, _ bits: UInt64, rootBits: Int) -> HuffmanEntry
    /// Both: the entry for the code at the start of `bits`.
    public static func entry(in table: Span<HuffmanEntry>, _ bits: UInt64, rootBits: Int) -> HuffmanEntry
}
```

(`@inlinable @inline(always)` throughout; `.leastSignificantFirst` only, or a `bitOrder:` parameter that
must be a literal.)

**After.** `Inflater.swift` keeps only DEFLATE's alphabet mapping (`Alphabet.entry`, the base/extra-bit
tables) and the decode loop; the loop reads unchanged, with `HuffmanTable.rootEntry(in:…)` etc.

**Evidence.** The prototype *is* the current code: these are NativeZip's `HuffmanEntry` and lookup
helpers moved behind a public name, so codegen is unchanged by construction (it's all inlined into
`decodeSymbols`). This run's rewrite of those accessors to Bytes' bit-field subscripts
(`raw[bits: 0..<6]`, `raw[Nibble.self, at: 8]`, `Kind(rawBits: raw[Bits<3>.self, at: 12]) ?? .invalid`,
`raw[bits: 16..<32]`) compiled to a byte-identical object, so the public type can be written with Bytes'
own vocabulary at no cost. One trap to avoid in Bytes' version: `extra` must not be
`bits[bits: codeLength..<totalBits]` (see proposal 2).

Not kept as an internal helper: NativeZip already has it; the point is sharing it.

---

## 2. An unchecked bit-field extract for runtime offsets

**Motivation.** `Inflater.swift:55–56`:

```swift
Int(truncatingIfNeeded: (bits & ((1 &<< UInt64(totalBits)) &- 1)) &>> UInt64(codeLength))
```

The natural Bytes spelling, `bits[bits: codeLength..<totalBits]`, is checked: the `..<` operator traps if
`lower > upper`, and the subscript checks `0 <= lower`, `upper <= bitWidth`. With runtime bounds those
checks can't fold. Measured in `decodeSymbols`: 995 → 1,026 lines of assembly, two more `brk` traps, more
spills (20 `ldp`/14 `stp` vs 15/10) in the decode loop. Reverted.

**Proposed API.**

```swift
extension FixedWidthInteger {
    /// The bits from `low` up to (not including) `high`, shifted down to bit 0. Unchecked: shift amounts
    /// wrap as `&<<`/`&>>` do, so it's a mask and a shift with no traps; `0 <= low <= high < bitWidth`
    /// gives the meaningful result.
    @inlinable @inline(always)
    func bits(from low: Int, upTo high: Int) -> Self { (self & ((1 &<< high) &- 1)) &>> low }
}
```

(Alternatively `subscript(uncheckedBits range: Range<Int>)` with `Range(uncheckedBounds:)` at call sites,
but a two-argument function avoids the `Range` precondition entirely.)

**After.** `Int(truncatingIfNeeded: bits.bits(from: codeLength, upTo: totalBits))`.

**Evidence.** Prototyped at that call site: `decodeSymbols` has the same 995 lines and the same
instructions; the 14 differing lines are the same six instructions scheduled in a different order
(`lsr w8, w20, #16` hoisted above the `ubfx`/`lsl`/`bic`/`lsr`/`add`). Everything else in the object is
identical. Not kept internally: one call site, and the current expression is already commented.

---

## 3. Cursors that start at a saved position

**Motivation.** Resumable decoders save a bit position between calls and rebuild their cursors from it.
NativeZip does it three times for reading and twice for writing:

- `Inflater.swift:200–204` (stored block), `:234–236` (block header), `:270–274` (symbol loop):
  ```swift
  var reader = BytesReader(input, bitOrder: .leastSignificantFirst)
  try reader.seek(toBitPosition: bitPosition)
  var bits = BitBuffer(reader)
  var writer = BytesWriter(output._mutatingExtracting(...))
  try writer.skip(byteCount: end)
  ```

**Proposed API.**

```swift
extension BitBuffer {
    @_lifetime(copy span)
    init(_ span: RawSpan, bitPosition: Int, bitOrder: BitOrder) throws(BytesError)
}
extension BytesReader {
    @_lifetime(copy span)
    init(_ span: RawSpan, bitPosition: Int, bitOrder: BitOrder = .mostSignificantFirst) throws(BytesError)
}
extension BytesWriter {
    /// A writer over `output` whose first `offset` bytes are already written (history, a prefix).
    @_lifetime(&output)
    init(_ output: inout MutableRawSpan, startingAt offset: Int) throws(BytesError)
}
```

**After.**

```swift
var bits = try BitBuffer(input, bitPosition: bitPosition, bitOrder: .leastSignificantFirst)
var writer = try BytesWriter(&output, startingAt: end)
```

It also hides `_mutatingExtracting(...)`, an underscored standard-library API callers otherwise need to
reborrow an `inout MutableRawSpan` as a consumable one.

**Evidence.** Prototyped (`@inline(always)` extensions) in `readBlockHeader` and `decodeSymbols`:
`decodeSymbols`' code is instruction-for-instruction the same apart from the throw paths, which got
*shorter* (two `insufficientData` throw sites merged: 995 → 981 lines); `readBlockHeader` 343 → 306 lines,
again only throw-path layout. No new calls (`Tools/calls` identical). Not kept internally: small saving
in a file that otherwise uses only public Bytes API; better in Bytes.

---

## 4. MS-DOS packed date and time

**Motivation.** `Sources/NativeZip/ZipArchive.swift:266–276`: six `Bits` extractions from the zip
header's DOS date and time, with the 1980 base and the 2-second unit. The same format is in FAT
directory entries, CAB, and LHA/ARJ headers. The bit layout is easy to get wrong (the year is 7 bits at
9, the month a nibble at 5) and is now documented only in the Bytes doc example.

**Proposed API.**

```swift
/// MS-DOS date and time, as zip, FAT, and CAB store them: two little-endian 16-bit fields.
public struct DOSDateTime: Hashable, Sendable {
    public var date: UInt16, time: UInt16
    public init(date: UInt16, time: UInt16)
    public var year: Int { get }     // 1980 + date[Bits<7>.self, at: 9]
    public var month: Int { get }    // date[Nibble.self, at: 5]
    public var day: Int { get }      // date[Bits<5>.self, at: 0]
    public var hour: Int { get }     // time[Bits<5>.self, at: 11]
    public var minute: Int { get }   // time[Bits<6>.self, at: 5]
    public var second: Int { get }   // time[Bits<5>.self, at: 0] * 2
    // settable, plus init(year:month:day:hour:minute:second:) for writers
}
```

**After.**

```swift
let dos = DOSDateTime(date: dosDate, time: dosTime)
components.year = dos.year; components.month = dos.month; components.day = dos.day …
```

**Evidence.** Prototyped as an internal struct used in `ZipArchive.date(dosDate:dosTime:)`: the function's
177 lines of assembly are identical. Not kept internally: one call site, and the subscripts with comments
read fine; its value is in sharing the layout.

---

## 5. Cheaper `read(sectionPrefixedBy:)` / a non-throwing variant for "if it's all there"

**Motivation.** `ZipArchive.swift:168–175`, the extra-field loop: a 2-byte id, a 2-byte size, then that
many bytes, where a size longer than what remains is tolerated as trailing padding. The obvious Bytes
form is

```swift
guard var field = try? extra.read(sectionPrefixedBy: Byte2.self, .littleEndian) else { break }
```

but it measured +0.7% instructions for the whole central-directory parse (4,891 K → 4,927 K, about 18
instructions per entry, two fields per entry), against ±0.1% for the explicit
`read(Byte2…)`/`guard size <= remainingByteCount`/`readSection(byteCount:)` form (4,895 K). Not
isolated further; candidates are `read(bytesPrefixedBy:)` checking the length twice (its own `guard` and
again inside `read(byteCount:)`), and `try?` materializing an `Optional<BytesReader>`. Reverted to the
explicit form.

**Proposed.** (a) Have `read(bytesPrefixedBy:)` do one check and build the span directly (it has already
proven the bytes are there). (b) Optionally `readSectionIfPresent(prefixedBy:_:) -> BytesReader?` that
returns `nil` without consuming when the section isn't all there, so tolerant parsers don't need `try?`.

**Evidence needed in Bytes.** A parse benchmark of a prefixed-section loop before/after (a); here, the
measured +0.7% is the cost to remove.

---

## 6. `CRC32.checksum(_:continuing:)`

**Motivation.** `Sources/NativeZip/ZipDecoder.swift:242–246`: a running CRC kept as an integer (the zip
header's value, zlib's `uLong`) needs three statements:

```swift
var checksum = CRC32(continuing: UInt32(truncatingIfNeeded: crc))
checksum.update(bytes)
return UInt(checksum.value)
```

**Proposed.** `public static func checksum(_ bytes: RawSpan, continuing value: UInt32) -> UInt32`
(and the `Span<UInt8>` overload), matching `crc32_z(crc, buf, len)`.

**After.** `return UInt(CRC32.checksum(bytes, continuing: UInt32(truncatingIfNeeded: crc)))`.

**Evidence.** Prototyped as an internal `@inline(__always)` extension used at that call site: the whole
NativeZip object is byte-identical (after normalizing addresses). Not kept internally: one call site,
a three-line saving.

---

## Lower value, noted

- **Packing several fields into an integer at once** (`HuffmanEntry.init`, `Inflater.swift:36`: four
  shifts and ORs). The settable subscripts (`raw[bits: 16..<32] = …`) can already do it, one statement
  per field, which is longer than the expression. A variadic/parameter-pack
  `UInt32(packing: (value, at: 16), …)` would be the only shorter form; not worth an API.
- **`Bits` read with an offset** (`Int(bits.read(Bits<5>.self)) &+ 257`, `Inflater.swift:383–384`): a
  `read(Bits<5>.self, plus: 257) -> Int` would save a conversion; marginal.
- **Fill a run in a span** (`Inflater.swift:422–424`, repeating a code length): the standard library's
  `MutableSpan.update(repeating:)` on an extracted range covers it; not a Bytes API.
