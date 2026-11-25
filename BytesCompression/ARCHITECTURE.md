# BytesCompression: what's unified, and where everything lives

The codecs (`BytesCompression`'s DEFLATE, Brotli, Zstandard, LZMA/xz, bzip2, and Apple's LZ formats) were always
here. Until 2026-11-23 the layers above them were not: NativeZip chose a decoder per ZIP method and pumped it a chunk
at a time; NativeAEA chose one per AEA segment compression, decoded segments in parallel into a buffer pool, and read
`pbz`/pbzx block framing for `.aar` and `.xip`; Disk chose an encoder per APFS `decmpfs` type; HTTPBytes chose one per
content coding. Each container's identifier went to the codecs through its own `switch`, and two parallel decoding
engines (AEA segments, `pbz` blocks) shared nothing but a buffer pool.

Now the codec layers are here, once, and each container keeps only what is about its container: headers and
directories, encryption and authentication, walking the decoded stream, writing files.

```
              ┌──────────────── BytesCompression (synchronous) ────────────────┐
 ZIP method ──┤ DecompressionFormat(zipMethod:) / .zipLZMA(_:…)                 │
 AEA segment ─┤ DecompressionFormat(aeaSegment:)  ─┐                            │
 pbz block ───┤ DecompressionFormat(pbzBlock:)    ─┼─► Decompressor ◄── ChunkedDecompressor (ZIP's pump)
 decmpfs ─────┤ (Disk: DiskCodec.decompressionFormat)                           │
 HTTP coding ─┤ (HTTPBytes' HTTPContentCoding, DeflateFormat(zlibOrRaw:))       │
              │ CompressionFormat ──────────────────► Compressor ◄── Disk's chunk encoders, HTTP's encoder
              │ PBZ (pbz / pbzx framing), AppleArchiveCompression (the letters)  │
              │ Parallel codecs (one call, N threads): ParallelDeflateEncoder,  │
              │ ParallelBrotliEncoder (ChunkScheduler), ParallelDeflateDecoder  │
              │ (InflateScheduler); in-order delivery shared, StopFlag          │
              └────────────────────────────────────────────────────────────────┘
              ┌──────────────── BytesCompressionAsync ─────────────────────────┐
              │ ParallelBlockDecoder<Stage>: independent blocks, decoded by N   │
              │ tasks into a BlockBufferPool, handed out in order               │
              │ (OrderedBlockSource); BlockStage: the client's per-block work   │
              │ ParallelCodecs.swift: the parallel codecs' async entry points   │
              │ (on a Dispatch queue, or `…Concurrently` as a task group)       │
              └────────────────────────────────────────────────────────────────┘
```

## 1. One codec identity

**Decoding: `DecompressionFormat`** (`Decompressor.swift`) is the one run-time identity, and `Decompressor` the one
decoder over it (each format's state made on first use and kept; whole buffers with `decompressAll`, streams with
`decompress`/`transform`, DEFLATE into the caller's buffers after history). Each container maps its own identifier to
it (`ContainerFormats.swift`):

| Container | Identifier | Mapping |
|---|---|---|
| ZIP | method (APPNOTE 4.4.5) | `DecompressionFormat(zipMethod:uncompressedSize:)`: 8 DEFLATE, 9 Deflate64, 12 bzip2, 93 Zstandard, 95 xz. Method 14's properties are in the payload: `LZMAProperties(zipHeader:)` reads ZIP's 9-byte LZMA header (APPNOTE 5.8.8), `.zipLZMA(_:uncompressedSize:hasEndMarker:)` makes the format (end marker: no size, the stream must end with its marker). |
| AEA | root header's compression byte | `AppleArchiveCompression` (the letters `-` `4` `b` `e` `f` `m` `x` `z`), `DecompressionFormat(aeaSegment:)`: LZ4 as raw blocks, LZMA as an xz stream, zlib with its wrapper. |
| `pbz` / pbzx | the header's fourth byte | the same letters, `DecompressionFormat(pbzBlock:)`: LZ4 as Compression's `bv41` frames. |
| APFS `decmpfs` | type (`AFT`) | Disk's `DiskCodec` (a file-system format, so it stays in Disk): `.decompressionFormat`, `.compressionFormat`. |
| HTTP | content coding | HTTPBytes' `HTTPContentCoding`. Decoding: one property, `decompressionFormat` (`gzip` → `.deflate(.gzip)`, `br` → `.brotli`, `zstd` → `.zstd(maximumWindowSize: 8 << 20)`, RFC 9659's limit, the format's own since 2026-11-23, stage 3), except `deflate`, zlib by RFC 9110 but sent raw by some servers: `DeflateFormat(zlibOrRaw:)` decides from its first two bytes (here since 2026-11-24, fix plan D5; it was HTTPBytes' own sniff). Whether a stream's end may be followed by another is the format's `allowsConcatenation`. gzip's and deflate's streams share `Decompressor`'s one DEFLATE decoder (`DeflateDecoder.reset(format:)`). Encoding: `HTTPContentEncoder`'s own `switch` to `CompressionFormat` (each coding at its level; `zstd` with a 512 KiB window). |
| XAR (`.xip`) | member encoding | NativeAEA: `application/x-bzip2` → `.bzip2`, the TOC → `.deflate(.zlib)`, through `Decompressor`'s one-shot into a new array (`decompressAll(_:maximumSize:decodedSize:)`). |

**Encoding: `CompressionFormat` and `Compressor`** (`Compressor.swift`), the mirror image, for clients that choose an
encoder at run time: DEFLATE (raw, zlib, gzip) at a level, Brotli at a quality, Zstandard at a level and window, and
Apple's LZFSE, LZVN, LZBITMAP (whole buffers only). Each encoder is made on first use and kept. Disk's APFS chunk
encoders (one per writer, a call per 64 KiB chunk) and HTTPBytes' content encoder (a streaming body) both go through
it; `Compressor` calls the format's own encoder after one `switch`, so their loops are unchanged.

## 2. One streaming pump: `ChunkedDecompressor`

What NativeZip's decoder did between its entries and `Decompressor`, now here (`ChunkedDecompressor.swift`): a stream
decoded a chunk (at most 1 MiB) at a time into two buffers the decompressor owns, so a consumer can read one chunk
while the next is decoded into the other buffer.

- **Whole:** input all present (not staged) and the decoded size known and at most a chunk: one `decompressAll`
  into the buffer, no window (most ZIP entries).
- **History:** DEFLATE and Deflate64 decode straight into the buffers, after the last 32 or 64 KiB of the previous
  chunk moved to the buffer's front.
- **Stream:** the others, through the format's own window, a chunk at a time.

Input is either **borrowed** (`borrowInput(_:)`: a mapped payload, all of it) or **staged** (`stageInput()`): the
client appends pieces (`fillInput(_:)`) as the decoder drains them, and `nextChunk(into:)` returns `.needsInput` when
it has consumed them all, continuing the same chunk after the client refills. A container header before the stream is
read from `pendingInput` and skipped with `consumeInput(_:)` (ZIP's LZMA properties), then `start(_:decodedSize:)`
picks the mode. `chunkRoom(_:)` lends a buffer to a client that fills a chunk itself (a stored entry, decrypted). That is how NativeZip decrypts encrypted entries in pieces
without any decryption here. ZIP's own rules stay in NativeZip: which methods, ZipCrypto and WinZip AES, sizes and
CRC-32, and the errors (`ZipError.decoding(BytesError, entry)`). An LZMA entry ending with its marker gets its size as
the decoder's maximum (`DecompressionFormat.zipLZMA`: `.lzma(maximumSize:)`, exact since 2026-11-24; NativeZip counted
the output itself before), and NativeZip reports the decoder's `limitExceeded` as its size mismatch.

## 3. One parallel engine: `ParallelBlockDecoder`

AEA segments, `pbz` blocks in an `.aar` or inside AEA segments, and a `.xip`'s pbzx blocks of xz are independent
blocks: decoded in parallel, consumed in order. `ParallelBlockDecoder<Stage>` (BytesCompressionAsync,
`ParallelBlockDecoder.swift`) is the one engine for all of them (it was NativeAEA's `SegmentStream` and
`BlockStream`):

- **Blocks** come from one of four sources, one initializer each (fix plan A4, 2026-11-24; until then a `Layout` ×
  `Input` pair, which allowed slices of an upstream source: a producer that returned without finishing, and a hang,
  review §1.5):
  - **indexed** (`init(stage:blocks:format:blockCapacity:…)`, `Stage: IndexedBlockStage`): all described up front by
    the stage's `block(_:)`; decoders claim the next index with an atomic add (AEA segments);
  - **`pbz` in a file** (`init(stage:pbz:blockSize:file:…)`, `Stage: BlockReadingStage`): a producer task reads each
    16-byte block header with the stage's `read(at:into:)` and queues a job; decoders read the blocks (`.aar`, `.xip`);
  - **`pbz` in an upstream source** (`init(pbz:blockSize:upstream:…)`, `Stage == UpstreamBlocks<Failure>`): another
    `OrderedBlockSource`'s blocks, which the producer copies into a staging pool (blocks cross the upstream's chunks),
    and decoders decode from staging (a `pbz` stream in AEA segments). Whoever makes it runs the upstream too
    (NativeAEA's `AEAPayload.run()` runs both); stopping the engine stops it;
  - **slices** (`init(stage:slices:file:…)`, `Stage: BlockReadingStage`): a plain stream read in slices.

  Inside, one `Source` enum; the generic engine code calls an indexed stage's `block(_:)` through a closure the
  constrained (inlinable) initializer forms, which captures nothing and is specialized in the client, and starts the
  file producer the same way (`produceFromFile`, in a `where Stage: BlockReadingStage` extension, calls `read` directly).
- **Decoders** (child tasks, `decoders` of them) each take a free output buffer, *then* the next block (so the block
  the consumer waits for always has a buffer), decode it, and publish it in a ring of `pool.count` slots, resuming the
  consumer only if it waits for exactly that block.
- **The consumer** (`nextBlock()`, `peek()`) takes blocks strictly in order and releases each buffer when done.
- **Buffers**: `BlockBufferPool` (was NativeAEA's `SegmentBufferPool`): one `RawStorage`, `count` buffers each with a
  carry region before it (for a walker's header split across blocks: `carryCapacity`, which the client passes to the
  engine's initializer because how much it carries is its format's rule, NativeAEA's 64 KiB for Apple Archive and
  cpio headers; 0 by default, and for staging; fix plan D8, 2026-11-24) and 64 bytes after; reference counts per
  buffer (`retain`/`release`, the last release handing it to the longest waiter); an inactive tail activated later
  (`activateAll`); `close()` wakes every waiter. Every initializer sizes its pools from counts with one helper,
  `BlockBufferPool.sizing(blockCapacity:carryCapacity:decoders:extraBuffers:heldBuffers:consumerBuffers:scratchCapacity:staged:budget:)`:
  a buffer per decoder, the extra ones (decoding ahead of the consumer), the ones held beyond decoding (writers'
  references), and the consumer's (1, or more for a consumer that keeps earlier blocks while it waits: NativeAEA's
  extraction walk in small segments), so a decoder can always take the block the consumer waits for;
  `heldUntilActivated` keeps AEA payloads' deferred tail (only what a `pbz` producer holds until the first segment says
  writers will hold segments). Staging is `sized(…, extraBuffers: 0, heldBuffers: 1)`. Clients read the pool from the
  engine (`source.pool`). **Within a byte budget** (2026-11-24, fix plan B1; `nil`: none): the pool, the decoders' read
  buffers, and staging together; over it (blocks of 64 MiB and up), held buffers come down first (to what fits beside one
  decoder; the pool's `heldBuffers` tells a client how many writers to run), then extra buffers, then decoders (which
  the engine runs as many of as the sizing kept), never below one decoder, one held buffer if any were asked for, and
  the consumer's. A source's `bufferByteCount` is what a source made over it subtracts from its budget.
- **Failures come in block order.** A block that fails (its read, its stage's checks, its decoding, its framing, or the
  upstream's failure under it) sets a limit at its index: nothing past it is decoded or handed out, the blocks before it
  (all claimed already: claims go in order, so each is in flight or queued) are still decoded and handed out, and the
  consumer gets the failure when it reaches that index. A lower block failing later lowers the limit and replaces the
  failure, so the error is the lowest failing block's, the one a sequential decoder reports, whichever task failed
  first (it was the first in time: the error could vary run to run, review §3 minor). The consumer never waits on a
  block that won't come: every block below the limit is claimed or queued, and decoders only exit past it. A failure
  also closes the job queue and staging and stops the upstream (with `.cancelled`): the producer is past the failure.
- **Stops can't hang.** `stop(_:)` (cancellation, or `stop(nil)` once the consumer is done) ends everything at once:
  the consumer waiting for a block wakes with the stop's failure (`.cancelled` for `nil`; a block's failure already
  stored stays), the pools and queue close, and an upstream is stopped with `failure ?? .cancelled`: its only consumer
  is this engine's producer, which a `nil` stop left waiting forever in the middle of a block spanning more upstream
  blocks than were in flight (review §1.4, `big.aea`). The cancellation failure stays invisible to clients:
  `withDecoding(onCancel:_:)` returns what `consume` returned, and its `stop(nil)` comes after.
  `withDecoding` runs decoders and consumer in one task group with the operation's one cancellation handler;
  `releaseUnconsumed()` returns what was decoded and not taken.

**The stage protocols ask for what each source needs**, so no requirement traps by default:

- `BlockStage`: `Failure` and `decode(_:into:context:)`, the client's work for each block, synchronous, on the
  decoder's task. It gets the block (`BlockJob`), its output buffer, and a `BlockContext` (the task's `Decompressor`,
  its read buffer, the counters, the source's `BlockKind`), and calls `context.decompress(_:into:block:)` for the codec.
- `IndexedBlockStage: BlockStage`: `block(_:)`.
- `BlockReadingStage: BlockStage`: `read(at:into:)`, and three hooks, each a no-op by default (plan D7): `storedBytes(of:)`
  (bytes the stage has without reading: a mapping), `prepare(_:stored:into:)` (checks and transforms the stored bytes
  into the output for a stored block, the read buffer otherwise, in place where they were read; returns whether it
  wrote), `verify(_:raw:)` (checks the decoded bytes). Its default `decode` is the flow: stored bytes from the mapping,
  or read (a stored block straight into its output, others into the read buffer, timed in `counters.read`, the read
  buffer's pages given back after), prepared, decoded unless stored (copied if a stored block isn't in the output
  already), verified. `.aar` and `.xip` (NativeAEA's `ArchiveFileStage`) use only `read`; NativeAEA's
  `AEASegmentStage` (an `IndexedBlockStage & BlockReadingStage`) maps in `storedBytes`, checks the MAC and decrypts in
  `prepare`, and checks the checksum in `verify`, with no `decode` of its own: every case its old override handled
  (read or mapped, stored or compressed, encrypted or not) is a path of the default flow. That is why AEA's keys, MACs,
  and checksums stay in NativeAEA while the engine is shared.
- `UpstreamBlocks<Failure>: BlockStage`: reads nothing; its `decode` is unreachable (the engine decodes upstream blocks
  from staging) and says so with a precondition.

Errors are typed and composed: the engine's own are `BlockDecodingError` (`.decoding(BytesError, block:, kind:)`,
`.notCompressed(block:)`, `.framing(PBZError)`, `.cancelled`), and the stage's `Failure` (NativeAEA's `AEAError`)
conforms to `BlockDecodingFailure` by making itself from one. The `BlockKind` (`.indexed`, `.pbz`, `.slice`) lets a
client name a block as its format does: NativeAEA's "segment N" (`decompressionFailed(segment:_:)`) for an archive's
segments, "block N" (`blockDecompressionFailed(block:_:)`) for `pbz` blocks (an `.aar` block's error read "segment N").
Nothing is boxed.

The engine is generic over its stage and `@inlinable` throughout (state `@usableFromInline`), as BytesAsync's
primitives are, so the client's instance is specialized in the client's module: no generic dispatch per block
(`Tools/calls --target NativeAEA NativeAEA '.*' --callee 'swift_getGenericMetadata|witness' --sum`: no generic metadata
calls, before and after A4).

## 4. What stayed where, and why

| Package | Keeps | Why |
|---|---|---|
| NativeZip | `ZipArchive.Method` (the numbers, names, `isSupported`), ZipCrypto and WinZip AES, `ZipDecoder` (its public face: decryption into the pump's staged input, the method → format mapping call, the LZMA end-marker limit, CRC-32, `ZipError`), `ZipContentSource` (Disk's writers) | container: the directory, encryption, and ZIP's checks |
| NativeAEA | keys, MACs, signatures, segment authentication and checksums (`AEASegmentStage`), `AEAPayload` (which engine reads the payload: segments or a `pbz` stream inside them), `.aar` and `.xip` openers (XAR TOC, RSA chain, Metadata), the Apple Archive and cpio walkers, the extraction sink | container and archive formats |
| Disk | `decmpfs` storage (`DiskCodec`, `StoragePolicy`, the fork layout, raw markers, `ForkUnpacker`'s fork reading) | a file-system format; only the codec calls go through `Compressor` and `Decompressor` |
| HTTPBytes | content codings, negotiation, the body decoder's framing | HTTP |
| Bytes | `MaskedTable` (a power-of-two table indexed by any integer, masked into it: DEFLATE's match tables, LZFSE's and LZVN's match lines, HTTPBytes' dynamic-table ring) | shared by HTTPBytes and the codecs (2026-11-24, E2); `StrideTable` and `UninitializedBuffer` stay in BytesCompression, whose codecs are their only clients |

The public surface is what other packages use (2026-11-24, E2, plan D11): `Decompressor`/`Compressor` and their formats,
the pump, the block engine, the DEFLATE and Brotli coders (SocketStream's pipeline stages), and the parallel DEFLATE
coders. The other codecs (bzip2, LZMA, LZMA2, xz, Zstandard decoding, LZ4, LZFSE, LZVN, LZBITMAP, LZRAVEN, parallel
Brotli), CRC-64, XXH64, and the Zstandard frame header are `package`: the package's own tests and benchmarks name them.
The encoders' word loads are one file, `WordReads.swift`.

## 5. Not unified (yet)

- **ZIP's stored entries** don't go through `ChunkedDecompressor`: unencrypted ones are written from the mapping, and
  encrypted ones are decrypted into `chunkRoom(_:)` by NativeZip, since there's nothing to decode.
- **NativeAEA's benchmark `SegmentDecoder`** (the "Decode segment 0" rows) decodes through `Decompressor`
  (`DecompressionFormat(aeaSegment:)`, as NativeAEA's segment stage does) beside Compression as the reference: the rows
  measure the codecs, not the engine (2026-11-24, E2: it named the individual decoders until then, the one client that
  kept them public).
- **The parallel codecs' schedulers** aren't `ParallelBlockDecoder`. The engine decodes independent blocks for a
  consumer that reads them one at a time, as tasks that suspend (on buffers, on the consumer), with failures in block
  order; the parallel codecs (`ParallelDeflateEncoder`, `ParallelBrotliEncoder`, `ParallelDeflateDecoder`) make one
  output buffer from one input in one synchronous call, on threads that never wait for anything but a lock:
  - `ChunkScheduler` (`ParallelScheduler.swift`), the encoders': workers take chunks from an atomic counter, compress
    into their lane, hand the output to slot `i % slotCount` by swapping buffers, and the worker that makes the next
    chunk ready copies it to the output, combining the checksums (`ChunkBatch`: the same workers for the async forms).
  - `InflateScheduler` (`ParallelInflate.swift`), the decoder's: workers take segments (from guessed split points)
    from a counter, decode each into a buffer of its own within the call's budget of decoded bytes, and the worker that
    makes the next accepted segment ready copies it; a serial join then decodes failed regions again in place and checks
    the trailer (`SegmentBatch` for the async form).

  Both copy through one loop, `Mutex.deliverInOrder(claim:copy:record:)` (claim the next piece under the lock while no
  worker is copying, copy outside it, record under it), and both stop on one `StopFlag` per call (an async call's
  cancellation handler sets it; workers check it as they take a piece) (2026-11-24, fix plan D6). The engine's stop
  stays its own (a failure value under its lock, which also stops an upstream and wakes the consumer). Their async
  entry points are BytesCompressionAsync's `ParallelCodecs.swift`: `compressAll(_:into:on:)` and
  `compressAllConcurrently` for both encoders, `decompressAll(_:into:on:)` and `decompressAllConcurrently` for the
  decoder (whose plan, join, and sequential parts run in a child task of their own).

Measured: RESULTS.md, 2026-11-23 (later), and 2026-11-24 (fix plan D).
