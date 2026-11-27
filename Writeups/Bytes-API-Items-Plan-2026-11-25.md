# Bytes API items 18–21, 23: plan (2026-11-25)

From `Open-Items-2026-11-25.md`. Access levels don't matter yet (the user); public where another package uses it.
Baselines before: Bytes, HTTPBytes/Benchmarks, MQTT, NativeAEA, Disk `bytesapi-before`; BytesCompression and
SocketStream `api-after` (no source change since).

## 18. `ByteBuffer`: copy in, write in place, grow

Today one allocation, never grown; clients hand-roll the rest (`ChunkedDecompressor.growStaging`/`fillInput`,
HTTPPayload's carry and middle buffers on `RawStorage`: six `unsafe` copies and two hand-built output spans).

- `capacity` becomes `public private(set) var`; `_storage` a `var`.
- `mutating func reserveCapacity(_ minimumCapacity: Int)`: when larger, allocates `minimumCapacity`, copies the
  unread bytes to its front, frees the old one. `compactionThreshold` stays as given (a fixed number of bytes). The
  "never moved" promise becomes "never moved during a fill": `fill`/`receive` hold `self` `inout` for their whole
  call (suspension included), so nothing can grow it under a live span. The type's doc changes to say so.
- `mutating func append(copying bytes: RawSpan)`: compacts first if the bytes don't fit at the end.
  Precondition: `bytes.byteCount <= capacity - unreadByteCount` (callers cap first; a buffer that should grow says so
  with `reserveCapacity`).
- `var availableCapacity: Int { capacity - unreadByteCount }`: what an append or a fill can add after compacting
  (`freeCapacity` stays: the end only).
- `mutating func withFreeCapacity<R, E>(_ body: (inout MutableRawSpan, _ written: inout Int) throws(E) -> R)`:
  `fill { $0.withFreeCapacity(body) }`, for writers that take a `MutableRawSpan` and return a count
  (`ChunkedDecompressor.fillInput`'s public shape).
- `[UInt8].append(writingUpTo byteCount: Int, _ body: (inout OutputRawSpan) throws(E) -> R)`: reserves, runs `body`
  on an output span over the new capacity, counts what it wrote. Replaces the six-line idiom (reserve,
  `append(addingCapacity:)`, `withUnsafeMutableBufferPointer`, `OutputRawSpan`, `finalize`) in
  `Compressor.compressAll(_:)`, `Decompressor.decompressAll(_:capacity:decodedSize:)`, and BytesAsync's pipeline
  helper. A label distinct from the standard library's `append(addingCapacity:initializingWith:)`, whose trailing
  closure would otherwise be chosen by type.

Adoption:

- `ChunkedDecompressor`: `growStaging` → `staging?.reserveCapacity(capacity)`; `stagingSize` goes (the buffer's
  `capacity`); `fillInput` → `compact()`, `guard !isFull`, `withFreeCapacity`.
- HTTPPayload `HTTPContentDecoder` (`~Copyable`, so it can hold one): `carry` and `middle` become `ByteBuffer?`
  (`middle` compacting below its capacity: today it moves the leftover to the front before every refill).
  `carryCount`/`middleStart`/`middleCount` go. The decoder calls its own `mutating` stage methods while reading a
  buffer, so each call takes the buffer out of its optional into a local and puts it back (also on the throwing
  paths, `do throws(E)`), as the class reference did. Measured on HTTPBytes' content-coding rows: a move of three
  words per call against the reference's retain.

## 19. The sync/async lending name clash

`RawSpan.withLentBytes` and `OutputRawSpan.withLentFreeCapacity` exist sync (Bytes) and `async` (BytesAsync) under
one name; a call whose closure names its error type is ambiguous in Swift 6.4, so Disk wrote its own
`withUnsafeBytesAsync`. The `async` forms are renamed `withLentBytesAsync(_:)` and `withLentFreeCapacityAsync(_:)`
(the clash is the reason for the name; `ByteBuffer.receive` took a different verb for the same reason, but "lend" is
the concept here). Callers: BytesAsync `AsyncByteTransform`, BytesCompressionAsync `ParallelCodecs` (6 pairs), the
tests. Disk's `withUnsafeBytesAsync` is deleted; its two writers use `withLentBytesAsync` and `.buffer`. `fill`/
`receive` stay.

## 20. `RawStorage`: checked pointer, spans

- `pointer(_:)` checks its precondition: `UInt(bitPattern: offset) <= UInt(bitPattern: byteCount)` (the end
  pointer allowed). Its callers are BlockBufferPool's `blockBase` and a test (the codecs' `workspace.pointer` is
  `CodecWorkspace`'s own).
- `bytes(_ range: Range<Int>) -> RawSpan`, `@_lifetime(borrow self)` (BlockBufferPool's accessor shape, proven on a
  class), range-checked.
- `withMutableBytes(_ range:, _ body: (inout MutableRawSpan) throws(E) -> R)` and
  `withOutputRawSpan(overwriting range:, _ body: (inout OutputRawSpan) throws(E) -> R)` (an empty output span over
  the range; `body` reads `byteCount` for what it wrote), range-checked. Synchronization stays the owner's rule, as
  the type says (and as BlockBufferPool's accessors do).
- Adoption: Disk `Planner` (157), `Decmpfs.decode` (284, 286–289), BytesCompressionAsync `ParallelBlockDecoder`'s
  header reads (865, 977). The rest of the census's sites are pointers from elsewhere (an engine's lent buffers,
  `mmap`, a caller's arguments) or syscalls taking `.base`, which stay.

## 21. Missing helpers

- **`String(decoding: RawSpan, as: UTF8.Type)`**: repairing, like the standard library's form for sequences, which
  a `RawSpan` isn't (callers wrote `withUnsafeBytes`, a per-byte `map`, or a `[UInt8]` copy first). Adopt: HTTPBytes
  `FieldName.description`, `Method.description`, HTTPBytesHTTPTypes `Conversions.string` (per-byte loop), Disk
  `EntryPath` (58), NativeAEA `Listing` (184), `Extraction` (459). (`HTTPDate` builds a `[UInt8]`; `JobQueue` has a
  pointer: unchanged.)
- **`StaticString.bytes: RawSpan`**, `@_lifetime(immortal)`, precondition `hasPointerRepresentation`: HTTPBytes'
  package `immortalSpan(_:)` moved down and deleted (15 calls plus `StaticFieldEntries` 52/65); BytesCrypto HPKE
  (209), NativeAEA `AEAKeys` (65–66), MQTT `Basics` `==` and `hash` (73, 81). `ASCII`/`BitFields` keep `utf8Start`
  unless the span form folds a literal to constants too (checked with `Tools/calls`/instruction counts).
- **Words**: `RawSpan.chunks(of: InlineArray<n, UInt8>.self)` (2026-11-25) already gives the element view a
  `withWords(of:)` closure would have; what's left is reading an element as an integer without the stack copy that
  `element.span` costs. `UInt64(littleEndianBytes: InlineArray<8, UInt8>)`, `UInt32(littleEndianBytes:
  InlineArray<4, UInt8>)` and the big-endian pair, by `bitCast` (BytesCompression's `WordReads.value` moved down
  and deleted; CRC-64, XXH64 use it). So no `withWords(of:)`: the closure form adds nothing over `chunks(of:)` plus
  these, and a closure is one more thing for the inliner to decline. Adopt: `ZstdEncoderEntropy` (623, a spelled-out
  `bitCast`); BytesCrypto Poly1305 `blocks` (493–497: reads each 16-byte element through `.span`, the stack-copy
  form: two words by `bitCast` of 8-byte chunks instead; measured on ChaCha20-Poly1305's rows); NativeAEA
  `Murmur64` only if it measures no worse (its checked loads already fold).

## 23. Small cleanups

- `readUTF8(byteCount:)` → `read(utf8ByteCount:)`, and `read(utf8ByteCount:excluding:)`. Callers: BinaryParsingComparison
  (BPList, PCAPNG ×2, PNG), two tests.
- `skip(bitCount:)`: `guard likely(UInt(bitPattern: bitCount) <= UInt(bitPattern: remainingBitCount))` (a negative
  count wraps above any remaining count; the throw path still tells the two errors apart). `peek(bitCount:)`:
  `precondition(UInt(bitPattern: bitCount) <= 64)`. Checked in the machine code of a test function (one `cmp`).
- **Cancellation out of `BytesError`**: `.cancelled` is thrown only by the parallel codecs' stop paths, yet every
  exhaustive switch over `BytesError` (every reader's) handles it. It goes:
  - BytesAsync gains `CancellableError<Failure: Error>: Error { case cancelled; case failed(Failure) }`
    (`Equatable` when `Failure` is, `CustomStringConvertible`), for async entry points that stop on cancellation
    with a typed error.
  - BytesCompressionAsync's public `compressAll`/`decompressAll` (`ParallelCodecs`) throw
    `CancellableError<BytesError>`.
  - BytesCompression's package stop paths stop throwing: the async layer checks the stop flag and the delivery's
    `cancelled` itself before each step (`ParallelDeflateEncoder.end`, `ParallelBrotli`'s end, `ParallelInflate`'s
    `joinSegments`/`decompressSequentially`/`decompressMembers` take no `stop` check; their callers make it). The
    sync codecs never had a stop flag set.
  - Clients: NativeZip `ZipError.init(decoding:)` and `BytesError.zipError` lose the arm; NativeZip's parallel
    inflate call maps `.cancelled` → `ZipError.cancelled`. NativeAEA `AEAError`'s `.decoding(.cancelled, …)` arm
    goes (`BlockDecodingError` has its own `.cancelled`). Tests updated (`ParallelCancellationTests`).

## Measurement and checks

- Instruction counts against the baselines above: Bytes (bit reader rows, Poly1305), BytesCompression (chunked
  decompression, zstd encode, CRC-64, XXH64, parallel rows), HTTPBytes (content coding), MQTT (error equality is in
  no hot row; built and tested), NativeAEA (listing, extraction, murmur64), Disk (decmpfs, planner).
- Tests: `ByteBuffer` growth keeping bytes at every capacity and offset, `append` compacting, `availableCapacity`,
  `withFreeCapacity` counts; `[UInt8].append(writingUpTo:)` on a non-empty array; `RawStorage` range checks
  (exit tests for out-of-range `pointer`, `bytes`); `String(decoding:)` repairing invalid UTF-8;
  `StaticString.bytes` equal to the literal's bytes; word readers against `load(as:)`; `read(utf8ByteCount:)`;
  `skip`/`peek` with negative counts (invalidValue, precondition); cancellation as `CancellableError.cancelled`
  from both async codecs. Break each new check once.
- No warnings in every package; Nunarchiver's `build.sh`; DocC links for Bytes; SwiftFormat at the end.

## Plan review (2026-11-25) and what changed

A read-only reviewer with probes (`~/Scratch/bytesapi-review.noindex`). Accepted:

1. **The queue path stops inside one sync call** (`decompressAll(_:into:on:)` runs `ParallelInflate`'s composite on
   the queue), so the async layer can't check the flag between steps; dropping `joinSegments`' check would turn a
   cancel into a full sequential re-decode. Changed: `CancellableError<Failure>` lives in **Bytes** (beside
   `BytesError`), not BytesAsync, and the async entry points throw `CancellableError<BytesError>`. As built:
   BytesCompression's sync steps stay on `BytesError` with no stop parameter; the stop-aware composite is
   `decompressAll(_:into:stopping:) -> Int?` (nil when stopped), checking the flag before the join, a sequential
   decode, and gzip's later members (`membersFollow(_:after:)`); the public sync form force-unwraps it with no flag;
   the task-group path makes the same checks itself. Also fixes finding 2 (a BytesAsync type in BytesCompressionAsync's
   public signatures under an `internal import`). `group.next() ?? …` and the `Result<…>` types changed with it.
   Tests: a stopped one-call decode returns nil with nothing appended; the queue forms joined the
   cancel-while-running test.
2. (Above.)
3. NativeZip has no parallel inflate call: only its three arms go (`ZipError.init(decoding:)`, `zipError`,
   `isCancellation`'s `.decoding(.cancelled, _)`). Docs naming `BytesError.cancelled` (Bytes.docc
   `UnderstandingTheTypes.md`, `WritingParsers.md`, the parallel codecs' comments) updated.
4. `ParallelDeflateEncoder.end`/`ParallelBrotliEncoder.end` keep a guard: a precondition (a cancelled delivery must
   never get a trailer); the async layer throws `.cancelled` before calling them. Exit test, broken once.
5. HTTPContentDecoder: no take-out-and-put-back. `decodeStacked`/`decodeCarried` become static functions taking the
   stages and buffers `inout` (disjoint stored properties; LESSONS.md's TLSRecordSealer pattern). Test: a decode
   that throws, then `reset` and another body allocate nothing.
6. Decmpfs binds `let stored = self.stored` before `bytes(_:)` (a class property's span escapes otherwise).
7. `RawStorage.withMutableBytes`/`withOutputRawSpan` are `@unsafe` (nonmutating on a shared class: nothing stops a
   live `bytes(_:)` span or another task); `bytes(_:)` stays safe. BlockBufferPool's accessors delegate to them.
8. `append(writingUpTo:)`'s third site is Bytes' sync `Pipeline.swift:129` (BytesAsync's can't: a suspension);
   nothing appended on a throw; the array-returning rows (compress/decompress to array, pipeline appending) are
   measured.
9. TLSRecord.swift:380 adopts `ByteBuffer.append(copying:)`.
10. A default compaction threshold scales with growth (half the new capacity); `withFreeCapacity(byteCount:)` as
    `OutputRawSpan`'s; `availableCapacity` and `freeCapacity` documented together; tests for growth no-op, with
    `_start > 0`, and empty.
11. Item 18 lands before item 20 (HTTPPayload's `pointer` calls go with it).

Rejected: 12 (Disk's helper changing executors): Disk enables `NonisolatedNonsendingByDefault`, so its helper
already ran on the caller's executor, as BytesAsync's does.
