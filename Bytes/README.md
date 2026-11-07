# Bytes

Parse and write binary formats field by field, at bit or byte granularity, with no copying and no
allocation, at memory speed. `Bytes` reads borrowed memory; `BytesWriter` writes into memory you provide.
Both are `~Copyable`, `~Escapable` cursors.

```swift
import Bytes

var reader = Bytes(data.span)                                   // RawSpan or Span<UInt8>
try reader.expect([0x50, 0x4B, 0x03, 0x04] as Byte4)            // a signature, or throws .mismatch
let version = try reader.read(Byte2.self, .littleEndian)        // UInt16
let length = try reader.read(Byte3.self, .bigEndian)            // UInt32, from 3 bytes
let kind = try reader.read(Bits<3>.self)
let isRetained = try reader.read(Bit.self).isSet
let qos = try reader.read(QualityOfService.self, as: Crumb.self) // an enum from 2 bits
reader.alignToByte()
let name = try reader.read(byteCount: 12)                       // a RawSpan of the same memory

let bytes = try [UInt8](capacity: 64) { output in
    try output.withBytesWriter { writer in                      // commits exactly what's written
        try writer.write([0x50, 0x4B, 0x03, 0x04] as Byte4)
        try writer.write(version, as: Byte2.self, .littleEndian)
        try writer.write(qos, as: Crumb.self)
    }
}
```

Full documentation is in `Sources/Bytes/Bytes.docc`, including a guide to writing your own parser
(`WritingParsers.md`, whose example is also a test).

## Types

- **`Bytes`**: the reading cursor. It can't outlive the memory it reads, and every span it returns borrows
  that memory. A read that throws (`BytesError`) consumes nothing.
- **`BytesWriter`**: the writing cursor, over a `MutableRawSpan`, or over uninitialized memory through
  `withBytesWriter` on `OutputSpan<UInt8>` and `OutputRawSpan`. A write that throws writes nothing, and
  no write touches memory past the cursor.
- **`Bits<let width: Int>`** (1–8 bits), with aliases `Bit`, `Crumb` (2), `Nibble` (4), and `Byte` (8):
  integer and binary-string literals, single bits (`value[bit: 3] = true`, `toggleBit(at:)`), halves
  (`byte.highHalf` is a `Nibble`, settable), bitwise operators, and conversions to integers, `Bool`, and
  other widths.
- **`Byte2` … `Byte16`** (`ByteGroup`): N bytes as they appear in memory. Interpret them with
  `.littleEndian` or `.bigEndian` (the narrowest integer that fits: `Byte3` → `UInt32`), write constants as
  array literals, and get or set bytes and halves.
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
reader.forEach(Byte4.self) { sum &+= $0.bigEndian }                    // fused and vectorized
try writer.write(Byte4.self, .bigEndian, count: ids.count) { ids[$0] }  // the same, for writing
for byte in reader { … }                                               // the unread bytes, zero-copy
let lengths = reader.values(of: Byte3.self, .bigEndian)                 // typed views are `Iterable`;
for length in lengths { … }                                            // bind them first (Swift 6.4)
```

Iterating never moves the cursor; `forEach` consumes what it reads.

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

`Benchmarks/RESULTS.md` has the measurements, the assembly review, and the experiments that didn't pay off.

## Caveats

- The module and its main type share the name `Bytes`; with a name clash, use a module selector
  (`Bytes::Byte4`).
- A cursor passed `inout` to a function or closure the compiler doesn't inline goes through memory, and
  loops over it stop vectorizing. Keep cursors local, or in inlinable code.
- Functions that take a cursor `inout` need `@_lifetime` annotations, which need the `Lifetimes`
  experimental feature in your target.
- `#expect(reader.isAtEnd)` doesn't compile in Swift Testing (the macro can't inspect a `~Copyable`,
  `~Escapable` value). Copy the property into a local first.
- `for x in reader.values(...)` with a temporary is rejected in Swift 6.4 ("lifetime-dependent variable
  escapes its scope"), as is the standard library's own `for x in array.span`. Bind the view first.
- `Nibble("1010")` with a *literal* argument is literal coercion: non-optional, and it traps if invalid.
  Parse runtime strings with `Nibble(someString)`, which is failable.
- Requires the 2027 OS releases and the experimental `Lifetimes` and `BuiltinModule` features.
