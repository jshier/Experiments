# Bytes

Parse and write binary formats field by field, at bit or byte granularity, with no copying and no
allocation, at memory speed. `Bytes` reads borrowed memory; `BytesWriter` writes into memory you provide.
Both are `~Copyable`, `~Escapable` cursors.

```swift
import Bytes

var reader = Bytes(data.span)                                   // RawSpan or Span<UInt8>
try reader.expect(0x50_4B_03_04 as Byte4)            // a signature, or throws .mismatch
let version = try reader.read(Byte2.self, .littleEndian)        // UInt16
let length = try reader.read(Byte3.self, .bigEndian)            // UInt32, from 3 bytes
let kind = try reader.read(Bits<3>.self)
let isRetained = try reader.read(Bit.self).isSet
let qos = try reader.read(QualityOfService.self, as: Crumb.self) // an enum from 2 bits
reader.alignToByte()
let name = try reader.read(byteCount: 12)                       // a RawSpan of the same memory

let bytes = try [UInt8](capacity: 64) { output in
    try output.withBytesWriter { writer in                      // commits exactly what's written
        try writer.write(0x50_4B_03_04 as Byte4)
        try writer.write(version, as: Byte2.self, .littleEndian)
        try writer.write(qos, as: Crumb.self)
    }
}
```

Full documentation is in `Sources/Bytes/Bytes.docc`, including a guide to writing your own parser
(`WritingParsers.md`, whose example is also a test).

## Types

- **`Bytes`**: the reading cursor. It can't outlive the memory it reads, and every span it returns borrows
  that memory; copy what you keep with `String(copying:)` or `[UInt8](copying:)`. A read that throws
  (`BytesError`) consumes nothing.
- **`BytesWriter`**: the writing cursor, over a `MutableRawSpan`, or over uninitialized memory through
  `withBytesWriter` on `OutputSpan<UInt8>` and `OutputRawSpan`. A write that throws writes nothing, and
  no write touches memory past the cursor, except section writers (below), whose body writes ahead of
  the length.
- **`Bits<let width: Int>`** (1–8 bits), with aliases `Bit`, `Crumb` (2), `Nibble` (4), and `Byte` (8):
  integer and binary-string literals, single bits (`value[bit: 3] = true`, `toggleBit(at:)`), halves
  (`byte.highHalf` is a `Nibble`, settable), fields (`flags[Crumb.self, at: 1]`, settable), bitwise
  operators, and conversions to integers, `Bool`, and other widths.
- **Fields of a value already read**: a multi-byte field's flags and sub-fields are numbered in its
  integer, so integers get the same vocabulary: `flags[bit: 0]`, `date[Bits<7>.self, at: 9]` (as `Bits`),
  `attributes[bits: 16..<32]` (wider, as the integer), all settable. `QualityOfService(rawBits: crumb)`
  turns a field into a raw-value type.
- **`Byte2` … `Byte16`** (`ByteGroup`): N bytes as they appear in memory. Interpret them with
  `.littleEndian` or `.bigEndian` (the narrowest integer that fits: `Byte3` → `UInt32`), get or set bytes
  (`group[3]`) and halves, and combine them byte by byte with `^`, `&`, `|`, and `~`, which need no byte
  order (`payload ^ maskingKey`). Write constants as hex literals of the bytes in memory order, as a hex
  dump shows them (`0x50_4B_03_04` is `50 4B 03 04`, whatever byte order the data uses; a literal too
  wide is a compile error for 2, 4, 8, and 16 bytes), or as array literals (`[0x50, 0x4B, 0x03, 0x04]`).
- **`ByteRepresentable`**: your own fixed-size types, such as an address backed by `InlineArray<4, UInt8>`.
  Conform with `var rawBytes` and `init(rawBytes:)`; reads and writes are then exactly as fast as the raw
  bytes (one load or store), vectorized in loops.
- **Raw-value types**: enums and option sets with integer raw values read from and write to bit fields
  and byte groups, with `.invalidValue` for undefined values.
- **Standard library types** whose every bit pattern is valid (`ConvertibleFromBytes`: integers, floats,
  SIMD vectors, `InlineArray`s of them): `reader.load(Float.self)` and `writer.store(value)` in native
  byte order, and zero-copy typed spans with `reader.read(InlineArray<4, UInt8>.self, count: n)`.

## Loops

```swift
reader.forEach(Byte4.self, .bigEndian) { sum &+= $0 }                  // fused and vectorized
reader.forEach(Byte8.self) { group in … group[0] … }                   // or the groups themselves
try writer.write(Byte4.self, .bigEndian, count: ids.count) { ids[$0] }  // the same, for writing
for byte in reader { … }                                               // the unread bytes, zero-copy
let lengths = reader.values(of: Byte3.self, .bigEndian)                 // typed views are `Iterable`;
for length in lengths { … }                                            // bind them first (Swift 6.4)
```

Iterating never moves the cursor; `forEach` consumes what it reads.

## Variable-size data

```swift
let length = try reader.read(LEB128.self, maxByteCount: 4)                 // varints: MQTT, protobuf, Wasm
var body = try reader.readSection(byteCount: Int(length))                  // a cursor bounded to the section
var record = try reader.read(sectionPrefixedBy: Byte2.self, .bigEndian)    // length first, then the section
let name = try record.read(utf8PrefixedBy: Byte2.self, .bigEndian)         // validated UTF8Span, no copy
try record.expectEnd()                                                     // or throws .trailingData

try writer.write(name, prefixedBy: Byte2.self, .bigEndian)
try writer.write(sectionPrefixedBy: Byte2.self, .bigEndian) { (section) throws(BytesError) in
    try section.write(id, as: Byte4.self, .bigEndian)                      // length filled in afterwards
}
```

Reading a section as its own cursor bounds every read in it, and reads stay atomic: a section whose
length or bytes haven't all arrived throws `.insufficientData` without consuming its length, so a
streaming parser can wait and retry, while malformed data throws `.invalidValue`. A `ByteGroup`-prefixed
section writer fills in the length in place; a LEB128-prefixed one reserves `maxByteCount` bytes and moves
the section down if the length is shorter, so size the section first when you can (`LEB128.byteCount(of:)`)
and write the length directly.

## Decoders

For entropy coders and LZ77 (DEFLATE, PNG, JPEG, Brotli), Bytes has a bit buffer, Huffman tables, and
back-reference copies. They're what NativeZip's DEFLATE decoder is built on; it beats zlib.

```swift
var bits = BitBuffer(reader)                         // 64 bits in a register, refilled 8 bytes at a time
var table = HuffmanTable(symbolCount: 288)
try table.build(codeLengths: lengths.span, bitOrder: .leastSignificantFirst)
bits.refill()                                        // ≥ 56 bits, branch-free; zeros past the end
let symbol = try table.decode(&bits)                 // one lookup, two for codes longer than the root
let extra = bits.read(bitCount: 5)                   // reads refill only when needed
try writer.copy(fromDistance: 3, count: 10, allowingOverrun: true) // LZ77 match, 16 bytes at a time
reader = try bits.finish()                           // back to a cursor; throws if it read past the end
let resume = reader.bitPosition                      // save, then `seek(toBitPosition:)` next call
```

- `BitBuffer` doesn't check for the end per read: past the data it reads zeros, and `isOverrun` or
  `finish()` reports it once, per block rather than per code.
- `HuffmanTable.build(codeLengths:bitOrder:rootBits:…into:invalid:symbol:subtable:)` fills a table of
  your own entry type, so an entry can carry more than a symbol (DEFLATE packs the length base and extra
  bits in, so a match length is one lookup). It's libdeflate's builder: each root entry is written once.
- `copy(fromDistance:count:allowingOverrun:)` and `write(_:byteCount:allowingOverrun:)` may write up to
  `BytesWriter.copyOverrun` bytes past the end of what they copy, for fixed-size moves; keep that much
  room free, and they fall back to exact copies when there isn't.
- `bitReversed` on `UInt8`–`UInt64` and `Bits` is one instruction (`rbit` on ARM).
- `CRC32` is the zip/gzip/PNG checksum (`CRC32.checksum(span)`, or `update` a running one). On Apple
  silicon it folds 128 bytes per step with carry-less multiplies (the small CBytesCRC C module wraps
  `pmull`, `eor3`, and the CRC32 instructions, which Swift can't express): 1.7–2.3x zlib's `crc32`, from
  63 GB/s on large inputs to 64-byte ones. Elsewhere, slicing-by-8 tables.
- In a hot loop, keep the buffer and writer as locals of small functions, so they stay in registers.
  Passing them `inout` to a call the compiler doesn't inline puts them in memory: `@inline(__always)` is
  only a hint and was refused for a large function; `@inline(always)` (SE-0496) is guaranteed.

## Semantics

- Bit order (`.mostSignificantFirst`, the default, or `.leastSignificantFirst` for DEFLATE) is set per
  cursor. Bits within a `Bits` value are numbered from the least significant, bit 0.
- Fields are packed with no implicit padding: after a bit-level read or write, multi-byte fields continue
  mid-byte, each byte made of the next 8 bits. `alignToByte()` moves (or pads with zeros) to the next byte.
- Reading or writing a span requires byte alignment (a precondition).

## Performance

- A byte-aligned read or write is one bounds check and one or two unaligned loads or stores. Odd widths use
  two overlapping accesses of the next smaller power of two, so they never go out of bounds.
- To parse a fixed-size record, read it as a sub-cursor first (`Bytes(try reader.read(byteCount: 46))`):
  its length is a constant the optimizer can see, so field reads inside it need no bounds checks.
- Loops of single reads or writes vectorize when the cursor is a local; so do `forEach`, generating writes,
  and bulk reads and writes, at every width.
- On an M3 Ultra, power-of-two widths and 4-byte custom types read (~77 GB/s) and write (~85–107 GB/s) at a
  single core's memory bandwidth; with all cores, almost every width reaches the CPU's memory ceiling
  (~240 GB/s). Odd widths are compute-bound on one core (19–51 GB/s for bulk reads and writes with the
  `NEONShuffle` trait).
- The library imports the compiler's `Builtin` module (the `BuiltinModule` experimental feature) for
  branch weights and an `assume` of the cursor's invariant, which lets LLVM fold consecutive bounds checks.
- The `NEONShuffle` package trait (on by default) packs and unpacks runs of 3-, 5-, 6-, and 7-byte groups
  with NEON table lookups, through a small C module (CBytesNEON) of `static inline` wrappers Swift inlines
  to single `tbl` instructions: bulk reads 1.8–2.5x and writes 1.3–2.4x faster on one core. Other CPUs
  get a portable fallback; `--disable-default-traits` turns it off.
- Span writes up to 32 bytes (strings, small payloads) copy inline with two overlapping loads and stores;
  longer ones call `memmove`.
- Nothing allocates (one compiler-caused exception is under Caveats). Every workload is also registered as
  an `Allocations:<name>` benchmark that counts only allocations, checked against static thresholds in
  `Thresholds/`: `swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:.*'`.

- Memory safety: the package builds with strict memory safety, and its unchecked accesses are confined to
  a few funnels (`Load`, `Store`, the copy helpers, the NEON shuffles), each behind the cursor's own
  bounds check, with comments saying why. The standard library's checked loads and stores measured 24%
  to 8x slower there, because their check isn't folded into the cursor's. Elsewhere it uses the checked
  forms; for sub-cursors (`Bytes(try reader.read(byteCount: 46))`) the checked `extracting` made
  fixed-size records 31% faster.

`Benchmarks/RESULTS.md` has the measurements, the assembly review, and the experiments that didn't pay off.

## Caveats

- The module and its main type share the name `Bytes`; with a name clash, use a module selector
  (`Bytes::Byte4`).
- A cursor passed `inout` to a function or closure the compiler doesn't inline goes through memory, and
  loops over it stop vectorizing. Keep cursors local, or in inlinable code.
- Functions that take a cursor `inout` need `@_lifetime` annotations, which need the `Lifetimes`
  experimental feature in your target.
- `for byte in reader` over a `let reader` heap-allocates the cursor once per loop (Swift 6.4.2: the
  compiler boxes a `~Copyable` `let` that an iterator borrows). Declare the reader with `var`, or loop
  in a function that takes it `borrowing`.
- `#expect(reader.isAtEnd)` doesn't compile in Swift Testing (the macro can't inspect a `~Copyable`,
  `~Escapable` value). Copy the property into a local first.
- `for x in reader.values(...)` with a temporary is rejected in Swift 6.4 ("lifetime-dependent variable
  escapes its scope"), as is the standard library's own `for x in array.span`. Bind the view first.
- Write byte-group constants as literals (`static let magic: Byte4 = 0x50_4B_03_04`), not with a byte
  order (`Byte4(0x504B_0304, .bigEndian)`): the compiler folds a literal into the code, but a `static let`
  built by byte-swapping stays a lazily initialized global, checked on every use.
- `Nibble("1010")` with a *literal* argument is literal coercion: non-optional, and it traps if invalid.
  Parse runtime strings with `Nibble(someString)`, which is failable.
- Requires the 2027 OS releases and the experimental `Lifetimes` and `BuiltinModule` features.
