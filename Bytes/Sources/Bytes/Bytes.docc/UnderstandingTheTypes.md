# Understanding the Bytes types

How the types fit together, which to reach for, and why the cursors are generic over a mode.

## Overview

`Bytes` is a set of small types that each do one job on memory you already have. None of them allocates
as it works; the few that own memory (``ByteBuffer``, ``Pipeline``) allocate once, when they're made.

| Job | Types |
|---|---|
| Read fields from bytes | ``BytesReader``, ``AlignedBytesReader`` |
| Write fields into bytes | ``BytesWriter``, ``AlignedBytesWriter`` |
| Decode entropy-coded bits (Huffman, ANS) | ``BitBuffer``, ``HuffmanTable`` |
| Encode entropy-coded bits | ``BitWriter`` |
| Hold bytes between a producer and a consumer | ``ByteBuffer`` |
| Stream bytes through stages (compress, encrypt) | ``ByteTransform``, ``Pipeline``, ``FusedPipeline`` |
| Test 16 bytes at once | ``ByteLanes``, ``ByteMatches`` |
| Checksums | ``CRC32`` |
| Field types | ``Byte2`` through ``Byte16``, ``Bits`` (``Bit``, ``Crumb``, ``Nibble``, ``Byte``) |

The rest is extensions to the standard library's spans: copying between them, finding patterns in them, and
building arrays and strings with a writer.

## Readers and writers

A reader is a cursor over a `RawSpan` you lend it. It reads fields in order: fixed-width groups in either
byte order (`read(Byte3.self, .bigEndian)`), enums by their raw values, LEB128 integers, length-prefixed
sections and strings, and views of the bytes themselves (`read(byteCount:)` returns a span of the same
memory, no copy). A writer is its mirror over a `MutableRawSpan`.

Both are `~Copyable`, so a position can't be duplicated by accident (pass them `inout`), and `~Escapable`,
so they can't outlive the memory they borrow. A read or write that throws consumes or writes nothing: the
cursor stays where it was, and ``GenericBytesReader/position`` and ``GenericBytesReader/rewind(to:)`` undo a sequence of
them (a message whose end hasn't arrived).

### Bit-addressable or byte-aligned

There are two of each:

- ``BytesReader`` and ``BytesWriter`` read and write at any bit position: a 3-bit field, then a 12-bit
  one, then a `Byte2` that starts mid-byte. Video and audio headers, DEFLATE's block headers, packed
  telemetry.
- ``AlignedBytesReader`` and ``AlignedBytesWriter`` work only in whole bytes: the same byte-level API, and
  nothing that would leave them mid-byte. Most formats are like this: network protocols (MQTT, HTTP/2,
  TLS records), archives' headers, images' chunk structures, Base64.

A format with flag bits inside a byte is still byte-aligned: read the ``Byte`` and take its bits with
`flags[Crumb.self, at: 6]`. Only formats whose fields cross byte boundaries in the stream need the
bit-addressable cursors. When one part of a format needs them, convert at a byte boundary:
`AlignedBytesReader(bytesReader)` (throws ``BytesError/misaligned`` partway through a byte) and
`BytesReader(alignedReader)`.

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
- **The same names.** ``BytesReader``, ``BytesWriter``, ``AlignedBytesReader``, and ``AlignedBytesWriter``
  are typealiases; you rarely write `GenericBytesReader` except in code that works with either (a decoder
  generic over `Mode`).

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

## Checked and unchecked forms

A few operations come in two forms: `commonPrefixLength` and `unsafeCommonPrefixLength` on `RawSpan`,
``BitWriter/flush()`` and ``BitWriter/unsafeFlush()``. The checked form validates its bounds once per call,
which is free in most code and too much in a match finder or an entropy coder that calls it per candidate
or per code (3–18% and 0.2–1.7% more instructions, measured). The unchecked form is for loops that prove
their bounds once per block, with the proof in a comment at the call; everything else should use the
checked one.
