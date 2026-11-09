# Bytes API proposals (2026-11-09)

Gathered while updating every package built on Bytes (MQTT, MQTTSocketStream, NativeZipArchive, Base64,
BinaryParsingComparison) and reviewing Bytes itself. Every proposal was prototyped outside Bytes, used at a
real call site, and measured: instruction counts, or machine code compared with the code it replaces.
None is implemented in Bytes yet. Details, before/after code, and measurements are in the per-package
files here; prototype sources are in `prototypes/`.

"Same code" means the prototype compiled to identical or equivalent machine code (often the compiler
merged the before and after functions into one).

## Performance wins (measured faster, or removes a workaround)

| # | Proposal | From | Evidence |
|---|---|---|---|
| 1 | **Copy spans of up to 64 bytes inline** in `BytesWriter.write(_: RawSpan)` (today: inline up to 32, then `memmove`) | [Base64 §1](Base64.md) | Base64's `writeShort` workaround: 47 B inputs 22.2 → 15.5 ns. Removes the workaround |
| 2 | **Copy from a reader with overrun**: `writer.write(from: &reader, byteCount:, allowingOverrun:)` (LZ4 "wildcopy" of literals) | [BinaryParsingComparison §1](BinaryParsingComparison.md) | LZ4 −22% instructions (65 → 51 M) |
| 3 | **Run-length fills**: `write(repeating: byte, count:)` (a `memset`) and `write(repeating: group, count:)` for multi-byte elements | [Bytes §8](Bytes.md), [BinaryParsingComparison §2](BinaryParsingComparison.md), [Base64 §6](Base64.md) | QOI runs −65% instructions (6.57 → 2.27 M); byte fills become `memset` |
| 4 | **A zero-padded last block**: `read(paddedTo:)`, plus `ByteLanes.shiftDown` | [Base64 §2](Base64.md) | Kept inside Base64 as `shiftedDown`: 95 B inputs 26 → 15 ns |
| 5 | **Minimal LEB128** (`requiringMinimal:`) in Bytes' own decode loop | [MQTT §1](MQTT.md), [Bytes §3](Bytes.md) | Same code for the plain read; +20 instructions if built outside Bytes, so it belongs inside |
| 6 | **Cheaper `read(sectionPrefixedBy:)`**: check the length once, or a non-throwing "only if it's all there" form | [NativeZipArchive §5](NativeZipArchive.md) | The current form costs +0.7% in zip directory parsing against a hand-written check |

## Simpler code at no cost (prototypes compiled to the same code)

| # | Proposal | From |
|---|---|---|
| 7 | **Non-throwing save and restore**: `position` / `rewind(to:)` (replaces `let saved = …; try! seek(…)` rollbacks) | [MQTT §3](MQTT.md), [Bytes §3](Bytes.md) |
| 8 | **Cursors that start at a position**: `BytesReader(span, atByteOffset:)` / `atBitPosition:`, `BitBuffer(_:bitPosition:bitOrder:)`, `BytesWriter(_:startingAt:)` | [Bytes §4](Bytes.md), [NativeZipArchive §3](NativeZipArchive.md) |
| 9 | **One-closure array builders**: `[UInt8](byteCapacity:writing:)` and `append(byteCapacity:) { writer in }` (today: two nested typed closures) | [Bytes §1](Bytes.md), [BinaryParsingComparison §4](BinaryParsingComparison.md) |
| 10 | **Signed values**: `readSigned(_:_:as:)`, `signedBits(_:as:)`, `Bits.signedValue`, `readSigned(bitCount:)` | [Bytes §5](Bytes.md) |
| 11 | **Flags and raw values**: `read(Bool.self)` / `write(_: Bool)`; `Bits(rawBitsOf:)`, the write side of `init?(rawBits:)` | [Bytes §2](Bytes.md), [MQTT §4](MQTT.md) |
| 12 | **Bit-field helpers**: `matches(_:mask:)` / `expect(_:mask:)` for version and reserved bits; `keepingLowBits(_:)` / `lowBitMask(_:)`; an unchecked `bits(from:upTo:)` for runtime offsets | [BinaryParsingComparison §5](BinaryParsingComparison.md), [Bytes §9](Bytes.md), [NativeZipArchive §2](NativeZipArchive.md) |
| 13 | **Errors with their location**: `reader.located(error)` inside `catch` (+1.3%; a closure wrapper cost +15%, don't offer one) | [BinaryParsingComparison §3](BinaryParsingComparison.md) |
| 14 | **Small conveniences**: `CRC32.checksum(_:continuing:)`, `readRemainingBytes()`, `RawSpan.hasPrefix(_: some ByteGroup)`, `forEachRecord(tag:length:_:_:)` for tag-length-value records, `Byte16` ↔ vector conversions | [NativeZipArchive §6](NativeZipArchive.md), [Bytes §6–7, §10](Bytes.md), [MQTT §6](MQTT.md), [Base64 §6](Base64.md) |

## Specialized (useful to one kind of format)

| # | Proposal | From | Note |
|---|---|---|---|
| 15 | **A packed Huffman entry type** (libdeflate's layout) with generic root/subtable lookups | [NativeZipArchive §1](NativeZipArchive.md) | NativeZip's code moved into Bytes: same code |
| 16 | **4-way deinterleave and 3-way interleave** (`ld4`, `st3` equivalents, from `uzp`/`zip`) | [Base64 §3](Base64.md) | Needed for a Base64 decoder (prototyped at 12.2 GB/s with today's lookups) |
| 17 | **A 128-byte `tbl`/`tbx` lookup** | [Base64 §6](Base64.md) | Larger tables in one step |
| 18 | **MS-DOS date and time** (`DOSDateTime`) | [NativeZipArchive §4](NativeZipArchive.md) | Same code; may belong in NativeZip instead |
| 19 | **LZ4-style saturated lengths** (a nibble continued by bytes while they're 255) | [BinaryParsingComparison §6](BinaryParsingComparison.md) | Low priority |

## Considered and not recommended

- **Branch-free lane masks** (`UInt8.mask(atLeast:)`) and **a typed transform into the writer**: no
  codegen change over writing them by hand ([Base64 §4–5](Base64.md)).
- **Byte-value sets from a list of members**: not folded at compile time in plain Swift (a loop per use,
  or `swift_once`, +14 to +146 instructions); only worth it as a macro ([MQTT §5](MQTT.md)).

## Performance findings in Bytes (not new API)

- **`atomically { }` around a large body** (a whole zip entry) costs +50% instructions (453 K against
  301 K): the closure isn't inlined, so the cursor lives in memory, and 14 calls to the unaligned slow path
  appear. Small bodies are fine. Worth fixing in Bytes, or documenting ([BinaryParsingComparison](BinaryParsingComparison.md)).
- **Sub-byte reads and writes at a byte boundary** (`read(Bit.self)` × 8 when byte-aligned) are about 3x
  the code of reading one `Byte` and splitting it; MQTT now reads whole flag bytes. A fast path, or a
  documentation note ([MQTT §2](MQTT.md)).
- **`Byte16` `forEach`** shows as `vector128`, but only the consumer's sum is vectorized; the loads and
  byte swaps are scalar (0 SIMD loads in `Tools/counters`). RESULTS.md corrected.
