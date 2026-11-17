# Understanding the Bytes types

How the types fit together, which to reach for, and why the cursors are generic over a mode.

## Overview

`Bytes` is a set of small types that each do one job on memory you already have. None of them allocates
as it works; the few that own memory (``ByteBuffer``, ``Pipeline``) allocate once, when they're made.

| Job | Types |
|---|---|
| Read fields from bytes | ``BytesReader``, ``AlignedBytesReader``, ``BigEndianBytesReader``, ``LittleEndianBytesReader`` |
| Write fields into bytes | ``BytesWriter``, ``AlignedBytesWriter``, ``BigEndianBytesWriter``, ``LittleEndianBytesWriter`` |
| Name the flags and fields inside a value | ``BitFlag``, ``BitField``, ``BitPattern`` (and `@BitFields` in `BytesMacros`) |
| Records that read and write themselves | ``BinaryParsable``, ``BinaryWritable``, ``FixedSizeBinary`` (and `@BinaryRecord` in `BytesMacros`) |
| Decode entropy-coded bits (Huffman, ANS) | ``BitBuffer``, ``HuffmanTable`` |
| Encode entropy-coded bits | ``BitWriter`` |
| Hold bytes between a producer and a consumer | ``ByteBuffer`` |
| Stream bytes through stages (compress, encrypt) | ``ByteTransform``, ``Pipeline``, ``FusedPipeline`` (and `AsyncByteTransform` in `BytesAsync`) |
| Share spans with other threads for one call | ``LentBytes``, ``LentMutableBytes`` |
| Test 16 bytes at once | ``ByteLanes``, ``ByteMatches`` |
| Checksums | ``CRC32``, ``Adler32``, ``RunningChecksum`` |
| Field types | ``Byte2`` through ``Byte16``, ``Bits`` (``Bit``, ``Crumb``, ``Nibble``, ``Byte``) |

The package's products: `Bytes` (everything above except the rows marked otherwise), `BytesMacros` (the
`@BitFields` and `@BinaryRecord` macros, with their swift-syntax plugin: depend on it only if you use them), `BytesAsync` (asynchronous pipelines and sockets), `BytesCompression` (DEFLATE, zlib, gzip, and
Brotli), `BytesCrypto` (ChaCha20-Poly1305 and TLS 1.3 records), and `BytesFoundation` (`Data` with spans).

The rest is extensions to the standard library's spans: copying between them, finding patterns in them, and
building arrays and strings with a writer.

## Readers and writers

A reader is a cursor over a `RawSpan` you lend it. It reads fields in order: integers (`read(UInt32.self)`
on a byte-ordered cursor, or fixed-width groups in either byte order, `read(Byte3.self, .bigEndian)`, and
`read(Int.self, as: Byte3.self)` for odd widths), enums by their raw values, LEB128 integers,
length-prefixed sections and strings, whole records (`read(Header.self)`), and views of the bytes
themselves (`read(byteCount:)` returns a span of the same memory, no copy). A writer is its mirror over a
`MutableRawSpan`.

Both are `~Copyable`, so a position can't be duplicated by accident (pass them `inout`), and `~Escapable`,
so they can't outlive the memory they borrow. A read or write that throws consumes or writes nothing: the
cursor stays where it was, and ``GenericBytesReader/position`` and ``GenericBytesReader/rewind(to:)`` undo a sequence of
them (a message whose end hasn't arrived).

### Which cursor

There are three kinds of each, all one generic type (``GenericBytesReader``, ``GenericBytesWriter``) in
different modes:

- ``BytesReader`` and ``BytesWriter`` read and write at any bit position: a 3-bit field, then a 12-bit
  one, then a `Byte2` that starts mid-byte. Video and audio headers, DEFLATE's block headers, packed
  telemetry. Only they have the bit-level API (``Bits`` reads and writes, `seek(toBitPosition:)`,
  `skip(bitCount:)`).
- ``AlignedBytesReader`` and ``AlignedBytesWriter`` work only in whole bytes: the same byte-level API, and
  nothing that would leave them mid-byte. Most formats are like this: network protocols (MQTT, HTTP/2,
  TLS records), archives' headers, images' chunk structures, Base64. Integers carry their byte order at each
  call (`read(Byte4.self, .bigEndian)`), which suits formats that mix orders.
- ``BigEndianBytesReader``/``BigEndianBytesWriter`` and the little-endian pair are aligned cursors that
  know their byte order, so a format with one order (most of them) reads and writes integers by type:
  `read(UInt32.self)`, `write(UInt16(length))`, `read(Int.self, as: Byte3.self)`, and the group, prefixed, and
  section forms without an order argument. They compile to the same code as an aligned cursor passing the
  order each time.

A format with flag bits inside a byte is still byte-aligned: read the ``Byte`` and take its fields apart by
name (below). Only formats whose fields cross byte boundaries in the stream need the bit-addressable
cursors. When one part of a format needs them, convert at a byte boundary: `AlignedBytesReader(bytesReader)`
(throws ``BytesError/misaligned`` partway through a byte) and `BytesReader(alignedReader)`.

### Named fields: no bit numbers in parsing code

A byte of flags is read as a ``Byte`` and its parts are accessed by name, from descriptors declared once:

```swift
enum ConnectFlags {
    static var userName: BitFlag { BitFlag(bit: 7) }
    static var willQoS: BitField<QualityOfService> { BitField(bits: 3...4) }
    static var reserved: BitFlag { BitFlag(bit: 0) }
}

let flags = try reader.read(Byte.self)
try flags.requireClear(ConnectFlags.reserved)
let qos = try flags.value(of: ConnectFlags.willQoS)     // throws for a raw value with no case
let hasUserName = flags[ConnectFlags.userName]
```

- ``BitFlag`` is one bit, read and written as a `Bool`. ``BitField`` is adjacent bits, read and written as an
  `Int`, a ``Bits`` value, or a `RawRepresentable` type (an enum) with an integer raw value. Positions count
  from the least significant bit; the `…FromMostSignificant` initializers count from the other end, for
  specifications that draw bit 0 on the left.
- The subscripts (`flags[flag]`, `flags[field]`) work on any integer and on ``Bits`` values: a DOS date read
  as a `UInt16` takes its parts as `date[DOSDate.month]`. Setting a field leaves the other bits alone, and
  `Byte { $0[…] = … }` builds a value from fields set on zero.
- ``BitPattern`` checks fixed bits at once, written as the specification draws them:
  `flags.matches("01??_??0?")` (`?` is a free bit).
- Declare descriptors as computed `static var`s: each use compiles to the shift and mask written by hand.

The `@BitFields` macro (in `BytesMacros`) declares the same thing as a struct and generates the reading and
writing, so a flags byte is `reader.read(ConnectFlags.self)`.

### Records

A format's fixed-size structures read and write themselves. ``BinaryParsable`` is an `init(parsing:)` taking
the cursor (generic over its mode, so one implementation serves every cursor), ``BinaryWritable`` is
`write(to:)`, and ``FixedSizeBinary`` states a constant size, which lets a record containing such fields be
read with one bounds check. Write them by hand or have `@BinaryRecord` generate them from the stored
properties:

```swift
@BinaryRecord(.littleEndian)
struct EntryHeader {
    @Field(Byte4.self, expecting: 0x0201_4B50) var signature: UInt32
    @Field(Byte2.self) var method: Int
    @Field(Byte4.self) var compressedSize: UInt64
}

var reader = LittleEndianBytesReader(directory)
let header = try reader.read(EntryHeader.self)        // one bounds check, then each field once
```

The macros live in their own product: add **`BytesMacros`** to the target's dependencies and `import
BytesMacros`. Everything they generate is available to write by hand with the types above, so `Bytes` itself
has no macro dependency. See <doc:WritingParsers> for a format written both ways.

### Why the byte-aligned cursors are faster

A bit-addressable cursor carries state a byte-only format never uses: a bit offset (0 through 7) and, in
the writer, the byte written so far. Every byte-level operation has to look at it:

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

and ``GenericBytesReader/remainingByteCount`` subtracts a partly read byte:
`count - byteOffset - (bitOffset == 0 ? 0 : 1)`.

In a loop of byte-level reads or writes, the compiler would like to prove that `bitOffset` stays 0 and drop
the test, the slow path, and the extra term. It usually can't: the slow path writes `bitOffset`, so its
value at the top of each iteration depends on the last one. So each operation keeps a compare and a branch,
the bit offset and partial byte stay live in registers (or spill), and loop bounds carry the extra term.
Each costs a few instructions per field. In a parser of small fields that's a lot.

The byte-aligned cursors remove the state from the type. ``GenericBytesReader`` and ``GenericBytesWriter``
are generic over a ``BytesCursorMode``, and the bit offset is an accessor:

```swift
var _bitOffset: Int {
    get { Mode.addressesBits ? _bitOffsetStorage : 0 }
    set { if Mode.addressesBits { _bitOffsetStorage = newValue } }
}
```

`Mode.addressesBits` is a static constant: `true` for ``BitAddressable``, `false` for ``ByteAligned``. Every
operation is `@inlinable`, so it's compiled specialized for the cursor you use. For an
``AlignedBytesWriter`` the accessor is the literal `0`, and `if bitOffset == 0 { … } else { … }` folds to
the fast path alone: one bounds check and one store, nothing else in the loop. For a ``BytesWriter`` the
accessor is the stored field, and the code is exactly what it was before the cursors became generic
(measured: no instruction count changed).

Three details keep it that way:

- **One implementation.** The byte-level API is written once, in extensions of the generic types, so the
  two kinds of cursor can't drift apart. Bit-level operations (``Bits`` reads and writes,
  `seek(toBitPosition:)`, `skip(bitCount:)`, ``BitBuffer``) are in extensions constrained to
  ``BitAddressable``, so a byte-aligned cursor doesn't offer them.
- **No run-time generics.** The slow paths that stay out of line (long copies, unaligned assembly, multi-byte
  LEB128) are in the bit-addressable cursor's own extensions, where they aren't generic: specialized code of
  either mode calls them without passing type metadata.
- **Modes nest.** ``ByteAligned``, ``BigEndianBytes``, and ``LittleEndianBytes`` all conform to
  ``ByteAlignedCursorMode`` (the byte-level API is there for all of them), and the last two to
  ``ByteOrderedCursorMode``, whose constant `byteOrder` the integer-by-type reads and writes switch on
  (a `switch`, not `==`: the standard library's `ByteOrder.==` isn't inlinable, and a comparison compiled to
  a call per store). So an ordered cursor is an aligned cursor with the order filled in.
- **The same names.** ``BytesReader``, ``BytesWriter``, ``AlignedBytesReader``, ``AlignedBytesWriter``, and
  the byte-ordered readers and writers are typealiases; you rarely write `GenericBytesReader` except in code
  that works with any of them (a record's `init(parsing:)`, a decoder generic over `Mode`).

Measured (instructions, M3 Ultra, Swift 6.4.2; `Benchmarks/RESULTS.md`):

| Client | Change with the aligned cursors |
|---|---|
| MQTT packet encoding | −6.1% |
| MQTT packet parsing | −0.9% to −2.9% |
| Base64 encoding, 40–95 bytes | −4.5% to −7.7% |
| DEFLATE decoding (output writer) | −1.7% to −4% |
| A QOI decoder writing runs a pixel at a time | −22% |

Each operation does strictly less, but the compiler sees a different loop, and that can change its other
choices: one QOI decoder ran 54% more instructions with the aligned reader, because LLVM nested its
run-filling loops inside the per-pixel loop instead of beside it. It keeps ``BytesReader``. Measure hot
loops when you switch.

### Building arrays and strings

The builders hand you a writer over fresh capacity and keep exactly what it wrote:

- `[UInt8](byteCapacity:writing:)` and `append(byteCapacity:writing:)` give a ``BytesWriter``;
  `[UInt8](alignedByteCapacity:writing:)` and `append(alignedByteCapacity:writing:)` an
  ``AlignedBytesWriter``.
- `withBytesWriter` and `withAlignedBytesWriter` on `OutputSpan<UInt8>` and `OutputRawSpan` do the same for
  an output span you already have.
- `[UInt8](byteCapacity:mode:writing:)`, `append(byteCapacity:mode:writing:)`, and `withBytesWriter(mode:_:)` take
  the mode as an argument, for a byte-ordered writer: `[UInt8](byteCapacity: 6, mode: BigEndianBytes.self) { … }`.
- `String(utf8Capacity:writing:)` gives an ``AlignedBytesWriter``: UTF-8 is whole bytes.

The aligned builders have their own names because an overload on the closure's writer type made every
closure that works with either writer (`{ writer in try writer.write(x) }`) ambiguous.

## Bits for entropy coding: BitBuffer and BitWriter

A cursor reads a bit field with a bounds check and its position update, which is right for headers and
wrong for Huffman codes decoded by the million. ``BitBuffer`` holds up to 64 bits in a register, refilled 8
bytes at a time with one unaligned load: decoding a code is a table lookup on its low bits and a shift.
It never throws while decoding; reading past the end gives zeros, and ``BitBuffer/isOverrun`` or
``BitBuffer/finish()`` reports it once per block. ``BitWriter`` is the encoder's counterpart: codes ORed into
a register, stored 8 bytes at a time by ``BitWriter/flush()``.

``BitBuffer`` takes the bit order (least significant first for DEFLATE, Brotli, and zstd; most significant
first for JPEG and H.264) as a stored value; where the buffer is inlined, a literal order folds to a
constant (fixing it in the type instead saved nothing, measured). ``BitWriter`` writes least significant
bit first, the order of the codecs that use it.

## Buffers, copies, and pipelines

- ``ByteBuffer`` fills at its end and drains from its front: a socket's received bytes waiting to be parsed,
  a stage's output waiting for the next. `fill` hands an output span over the free space, `receive` does the
  same for an asynchronous source (a socket read, which suspends), and it moves unread bytes to the front
  only when the free space at the end runs low. It owns one allocation that never moves.
- The standard library has no safe copy into a `MutableRawSpan` or an `OutputRawSpan`; `copyBytes(from:
  toByteOffset:)`, `copyBytes(within:toByteOffset:)`, `append(copying:)`, and `withFreeCapacity` are the
  checked versions, with short copies inlined.
- ``ByteTransform`` is one stage of a stream (a compressor, a TLS record sealer): input span in, output span
  out, flush semantics like zlib's. `then` composes stages into a ``Pipeline`` (with a ``ByteBuffer``
  between them) or, for a stage that works in place, a ``FusedPipeline`` with no buffer at all.
  - A stage declares its units: ``ByteTransform/maximumUnitByteCount`` (the most input it needs at once, as a
    TLS record's 16,645 bytes) and ``ByteTransform/minimumOutputCapacity``. Pipelines size their buffers
    from them, so a stage that keeps back a partial unit always fits.
  - Every stage ends a stream the same way: at ``TransformFlush/finish`` it reports
    ``TransformStatus/finished`` once its output is delivered, or throws if its input ended early.
  - ``ByteTransform/transform(_:appending:flush:growth:)`` is the drive loop for a message or stream in
    memory: it calls the stage, adding room to an array, until the stage has taken its input.
- `AsyncByteTransform` (the `BytesAsync` product) is `ByteTransform` with `async` calls, for stages that
  wait on a socket or run on another queue. `synchronously()` and `offloaded(to:)` make any stage one, and
  `ByteBuffer.receive` fills a buffer from a read that suspends. The parallel codecs have `async` entry points
  too (`compressAll(_:into:on:)` on a Dispatch queue, or as child tasks of a task group).
- ``LentBytes`` and ``LentMutableBytes`` carry a span's memory to other threads for the length of one
  call (`withLentBytes`, `withLentFreeCapacity`): a span can't be captured by a task, so parallel work over
  a caller's input and output is lent it as a `Sendable` pointer, valid until the lending call returns (which
  the work must finish before).
- ``RunningChecksum`` is what ``CRC32`` and ``Adler32`` share: update over pieces, and combine checksums of
  pieces computed separately.

## Checked and unchecked forms

A few operations come in two forms: `commonPrefixLength` and `unsafeCommonPrefixLength` on `RawSpan`,
``BitWriter/flush()`` and ``BitWriter/unsafeFlush()``. The checked form validates its bounds once per call,
which is free in most code and too much in a match finder or an entropy coder that calls it per candidate
or per code (3–18% and 0.2–1.7% more instructions, measured). The unchecked form is for loops that prove
their bounds once per block, with the proof in a comment at the call; everything else should use the
checked one.
