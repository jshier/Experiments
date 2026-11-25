# Bytes and BytesCompression: open API and performance items (2026-11-25)

What remained unimplemented after the unification and the 2026-11-24 improvement cycle, checked against the sources on
2026-11-25. The candidates came from `Bytes-Survey-2026-11-24.md`, the open items carried from `Library-Survey-2026-11-23.md`,
`BytesCompression-Fix-Plan-2026-11-23.md` (complete), `BytesCompression-Review-2026-11-23.md`, and the "not done" notes
in both packages' RESULTS.md. Two read-only agents checked each item's status in the code, with evidence. Sizes in
brackets are the surveys'. Instruction counts are probes'; no cycles were measured, so every performance item needs a
baseline first. File and line references are as of this date.

## Done

1. **A reused `Decompressor` gives memory back** (2026-11-25, BytesCompression/RESULTS.md "Memory given back").
   Workspace allocations of 9 MiB or more are mapped, so dropping a decoder unmaps its window. New
   `Decompressor.releaseMemory()` and `ChunkedDecompressor.releaseMemory()`.
2. **Brotli positions past 2^32** (same section). Wrapping is harmless (every comparison is a wrapping difference).
   Shown by `BrotliEncoder.setStreamBase(_:)` tests and 4.5 GiB bulk streams, Brotli and gzip (ISIZE modulo 2^32).

Found on the way: Homebrew's libzstd 1.6.0 makes the same frames as 1.5.7 with 2–18% fewer instructions. Our encoder
is now 2–9% behind it in time on dickens, mozilla, and x-ray (`Benchmarks/RESULTS-zstd-encoder.md`, "libzstd 1.6.0").
That gap is a new item (13a below).

## Performance: Bytes

3. **[H] Block loads are checked one by one.** `byteBlock(at:)` has one precondition, but `ByteBlock(loading:)`
   (`ByteBlock.swift:52–56`) does four checked loads; the survey found they don't fold in loops. The same holds for
   `containsByte`, `firstByteOffset(where:)`, and `bytesEqual` (`ByteScan.swift:191,249,287`), SHA-1/256/512
   (`SHA.swift:214,384,538`), and GHASH (`AESGCM.swift:501`).
4. **[H] `ByteLanes.matching(_:)` is still SWAR** (`ByteScan.swift:35–36`). One `cmeq` would do instead; a 64-byte
   mask would go from 38 to 25 instructions.
5. **[M–L] `firstByteOffset(of:)` and `lastByteOffset(of:)` test candidates a lane at a time**
   (`BytesReader.swift:1396,1426`). That is about 100 instructions a block, where walking a mask costs about 9 a
   candidate.
6. **[H–M] BytesAsync shadows the SDK's noncopyable `Continuation`** (SE-0528; `Waiting.swift:15,31`). It also has two
   `[Element?]` rings that index with `%` (`WaiterQueue`, `AsyncQueue`).
7. **[M] AES-CTR and stitched AES-GCM run 8 blocks in flight**, not 12 (`AES.swift:319`).
8. **[L] `AsyncByteTransform.transform(_:appending:)` zero-fills every round** (`AsyncByteTransform.swift:55`).
9. Not tried, from RESULTS:
   - CRC-32 with scalar `crc32x` streams beside `pmull`.
   - Short-distance back-references kept in a register.
   - Base64's decoder tuned for the M1 Max.

## Performance: BytesCompression

10. **[M] The zstd one-shot encoder stages each block, then copies it out** (`ZstdEncoder.swift:242–274`).
11. **[L] `ZstdHuffman.decodeWeights` is a nested function mutating a captured `var`** (`ZstdEntropy.swift:636–650`).
12. **[M, costly] Brotli ratio.** One block type per category, NPOSTFIX/NDIRECT 0, LSB6 only; qualities 10–11 run as 9.
13. **[L–M] Brotli decode of small inputs.** It was 31% behind Google at 1.6 KB; since then the arena is
    uninitialized, so measure again before working on it.
13a. **[M] The zstd encoder against libzstd 1.6.0.** Read 1.6.0's changes to `ZSTD_compressBlock_fast` and
    `doubleFast`, and to its Huffman encoder (x-ray level 1 −18%). The port follows 1.5.7.
14. **[L, large] zstd encoder levels 5 and up; DEFLATE levels 10–12** (both clamped).
15. **[L] `Decompressor.decompressAll(_:maximumSize:)` reserves `maximumSize` when the size is unknown**
    (`Decompressor.swift:451–455`).

## API: Bytes

16. **`ByteMatches` is high-bit only** (`ByteScan.swift:49,55`). Missing: full lanes, an initializer from `SIMDMask`,
    and `matching(lessThan:)`/`matching(atLeast:)`.
17. **A public typed block view** (`RawSpan.blocks<let n>()` or `ByteBlock(InlineArray<64, UInt8>)`), with
    `WordReads` moved down from BytesCompression. This goes with item 3.
18. **`ByteBuffer` gaps** (`Buffers.swift:342–471`): `append(copying:)`, `withFreeCapacity`, growth.
    `ChunkedDecompressor.growStaging`/`fillInput` hand-roll them.
19. **The sync/async `withLentBytes` name clash** (`Lending.swift:93` against `BytesAsync/Lending.swift:15`).
20. **`RawStorage` vends pointers only**, and `pointer(_:)` doesn't check its precondition (`RawStorage.swift:63–67`).
21. **Missing helpers:** `String` from a `RawSpan`; `StaticString` as an immortal `RawSpan`; `withWords(of:)`.
22. **Scoped resources:** `AsyncLimiter.withPermit`, a `~Copyable` lease from `AsyncIndexPool`, a closable pool in
    BytesAsync.
23. **Small cleanups:**
    - `readUTF8(byteCount:)` → `read(utf8ByteCount:)`.
    - One unsigned compare in `skip(bitCount:)`/`peek(bitCount:)`.
    - A cancellation error for BytesAsync.

## API: BytesCompression

24. **Format detection and gzip headers.** No `DecompressionFormat(detecting:)`; `GzipHeader` is `package` and
    skips the name and comment; the encoder's header is hard-coded.
25. **`Compressor` gaps.** `init(for:)` is `package`; no `maximumCompressedSize` or array one-shot; it throws on a
    negative level where `DeflateEncoder` clamps. `ZstdEncoder` is half-public. A `zstdForHTTP(level:)` format would
    let SocketStream move onto `Compressor`/`Decompressor`. `Compressor.releaseMemory()` would mirror item 1.
26. **`BlockBufferPool` hands out `Int` indices** with manual `retain`/`release` (`BlockBufferPool.swift:307,313`).
    The proposal is a `~Copyable` lease.
27. **Error vocabulary.** Unsupported features throw `invalidValue`; there are no `unsupported`, `checksumMismatch`,
    or `truncated` cases; `LocatedBytesError` is unused here.
28. **Smaller items:**
    - `ParallelDeflateDecoder.decompressAllConcurrently` is `package`.
    - No streaming `ParallelBrotliEncoder`.
    - `XZCursor.integer()` should use Bytes' LEB128.
    - The `Deflate.swift:49` doc says "0 through 12".
    - No DocC catalogs for BytesCompression or BytesCrypto.

## Narrowing (Bytes; do last)

29. **Still `public` with no outside client:**
    - `LentMutableSpan`.
    - `AsyncByteTransform` and its three adapters.
    - `InPlaceByteTransform`, `FusedPipeline`, `mapError`/`promoted(to:)`.
    - `RunningChecksum`, `ByteRepresentable`, `Byte9`, `Byte11`–`Byte15`.

## Macros

30. **Generated code uses `@inline(__always)`, not `@inline(always)`.** Measure on the ZIP and AEA records.
31. **Expansions, ranked:**
    - One-of magics merged into one compare.
    - Trailing `RawSpan` fields.
    - `validate()` with the client's errors.
    - Writing into an `InlineArray`.
    - Conditional fields.
    - TLV unions.
    - Odd `@BitFields` widths.

## BytesCrypto

32. **An `AEAD` protocol** (`TLSRecord.swift:38`, `HPKE.swift:46`).
33. **An X.509 chain validator**, and `bytesEqual` in place of `X509Certificate.swift:163`'s byte loop.
34. **Missing primitives:** X25519, Ed25519, RSA-PSS, ECDSA signing, SHA-3.
35. **Secrets and serializers:** secret wiping (only scrypt wipes) and fixed-size key serializers.
36. **The C shims to `Builtin.int_aarch64_*`.**

## Features no client asks for

- zstd dictionaries.
- xz filters other than LZMA2.
- The standard LZ4 frame format.
- LZMA, bzip2, and LZ4 encoders.
- Parallel Brotli, zstd, xz, and bzip2 decoders.

## Benchmarks the performance items need

- Codec rows streamed at 1,448 and 16 KB.
- Flushed message streams.
- Worst-case encoder inputs.
- Hash rows at remainder sizes.
- A BytesAsync stress test.

## Next

Items 3–5 with 16–17: the block loads and scans, `cmeq` matching, and mask-walked candidates, with `ByteMatches`
full lanes and a typed block view. Their "before" baselines are saved, all named `scan-before`:

- **Bytes:** the `Scan`, `Search`, `ASCII`, and `Hex` rows, optimized build.
- **BytesCompression:** the SHA, HMAC, and AES-GCM rows.
- **HTTPBytes:** the HTTP/1 head rows.
- **MQTT:** its suite, for the topic checks.

Measure the portable builds too (`Bytes/bench portable`, `portable-no-c`), since `ByteLanes` has a fallback.

After those: 6 with 22 and 26 (BytesAsync on the SDK's `Continuation`, leases), 10–11 and 13a (zstd), then the API
reshaping (18–21, 24–25, 27). Narrowing (29) goes last.
