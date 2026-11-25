# BytesCompression review (2026-11-23, after the unification)

Three independent reviews of the unified package and its clients (NativeZip, NativeAEA, Disk, HTTPBytes, the app):
API and design, performance (instruction and cycle counts per stream, C references beside), and an adversarial
correctness pass with crafted inputs. Proposals only: nothing here is implemented yet.

Reproducers, generators, and probes are in `~/Scratch/compression-review-2026-11-23/` (`files/`, `scripts/`,
`perf/`, `api/`, `cprobe-sources/`). Two ZIP findings (§1.1, §1.2) were re-run by hand against the release `nunzip`.

None of the bugs below is a regression from the unification: each was in HEAD's code before the move (checked per
finding). The unification made several of them easier to fix in one place.

## 1. Bugs, confirmed (fix first)

| # | What | Where | Effect | Fix |
|---|---|---|---|---|
| 1.1 | Staged input treats `.finished` as the stream's end; gzip, zstd, xz, bzip2 may continue with another member in input not yet staged | `ChunkedDecompressor.swift:244, 277` | Silent truncation through the public API (200,000 of 400,000 bytes, `finished: true`); a valid ZipCrypto zstd entry whose first frame is exactly 262,144 bytes is refused (`zz-boundary.zip`, password `secret`: "expected 263132 bytes, got 262132") | When the staged bytes are used up, `.finished` is tentative for concatenating formats: return `.needsInput`, accept the end only when the fill returns 0 |
| 1.2 | `ZipArchive.readContents` checks the size only after the last chunk | `ZipArchive.swift` ~686–717 | A 1 MB entry declaring 2 MiB streamed 1 GiB to the body (`nunzip -p bomb2.zip`: 1,073,741,824 bytes), and `contents(of:)` appends all of it | `guard written + chunk.count <= uncompressedSize` before `body` (extraction already checks per chunk) |
| 1.3 | `BZip2Decoder` declares `maximumUnitByteCount` 1 but keeps a block's tables (≈32 KB valid, unbounded corrupt) | `BZip2Streaming.swift:24-32`, `Pipeline.swift:325` | Process trap in a `Pipeline`: valid 49 KB stream with 256-byte buffers; any `Decompressor(.bzip2)` pipeline on a crafted 100 KB stream | Bound the table read (throw past the format's maximum) and declare it; see §3.1 |
| 1.4 | `ParallelBlockDecoder.stop(nil)` passes `nil` upstream and never resumes a waiting consumer | `ParallelBlockDecoder.swift:511–526, 664, 681` | Hang (needs a cancel) when extraction or listing stops while a pbz block spans more AEA segments than are in flight (`big.aea`: list, verify, extract all time out; with `aa -b` ≥ 32 MiB it's likely on any failure) | `upstream.stop(failure ?? .cancelled)`, or `next()` returns when cancelled and unpublished |
| 1.5 | `.slices` layout with `.upstream` input: `produce()` returns without finishing | `ParallelBlockDecoder.swift:406, 565` | Hang until cancelled (the type allows what the doc forbids) | One block-source enum (§3.2) |
| 1.6 | Pools sized by block count × block size; pbz blocks up to 256 MiB, AEA segments up to 2³¹−1 | `PBZ.swift:16`, `AEAFormat.swift:117`, NativeAEA's pool sizing | 2.6 MB `.aar` → 5.1 GB RSS listing (no key); 1.3 MB `.aea` → 2.16 GB (profiles 3–4 need only the public key) | Cap AEA segments at 256 MiB (`aea`'s own maximum); budget pools in bytes (`max(minimum, budget / blockSize)`, scratch included) |
| 1.7 | XAT and ACL blobs accumulated whole, peak kept | `NativeAEA/Extraction.swift:587–597` | 264 KB `.aar` → 4.24 GB RSS (≈12,000 bytes per input byte) | Refuse blobs over a limit (16–64 MiB) where their sizes are parsed |
| 1.8 | `XMLScanner.path` rebuilds the path on every event, before the TOC checksum | `XAR.swift:177` | Unsigned `.xip`: 511 bytes, depth 40,000 → 42.8 s (quadratic; the 64 MiB TOC limit allows weeks) | Incremental path (append, truncate to saved length) and a depth cap (256) |
| 1.9 | `ParallelDeflateDecoder` segments grow past the output's capacity, zeroed | `ParallelInflate.swift:519–524, 557–562` | 4.17 MB gzip, 8 lanes, 16 MiB output → +10.3 GB before `insufficientCapacity` (no client uses it yet) | Limit each segment to the output's free capacity; allocate without zeroing |
| 1.10 | Streaming zstd reserves its whole window zeroed from a 6-byte header; ZIP gives `.zstd()` regardless of entry size | `Workspace.swift:71–99`, `ContainerFormats.swift:71` | +128 MiB per stream (per ZIP worker), +8 MiB under HTTP | Reserve unzeroed (verify the decoder never reads unwritten history); clamp to the container's size as xz's `sizeHint` does |
| 1.11 | X.509 duplicate-extension check re-parses earlier extensions past 16 | `X509Certificate.swift:585–594` | 16,000 extensions (192 KB) → 2.57 s; a `.xip` leaf is parsed before RSA verification (end to end not built) | Cap the count (real certificates: < 30), or sort and compare neighbours |
| 1.12 | `Compressor.reset(for:)` doesn't throw; `.zstd(windowLog:)` outside 10–27 traps; level ≤ 0 runs level 4 (libzstd: 0 is level 3) | `ZstdEncoder.swift:53, 72–80` | Trap on a caller's parameter (no client passes one today) | Throwing `reset(for:)` (Decompressor's already throws `invalidValue`); map 0 to 3 |

Minor, each low severity:

- HTTP/2 and HTTP/3 accept `:status 000`–`099` (`FieldSectionValidation.swift:183–188`; `HTTPStatus(code:)` needs
  100–999): first digit ≥ 1.
- `ZstdDecoder.decompress(_:maximumSize:)` defaults to `.max`: 1 MB of input may still make a zeroed 32 GiB array.
  Finite default, or grow as it decodes.
- HPACK's `literal(continuing:)` recurses once per oversized literal (depth < 30 at default limits; unbounded only with
  both limits 0): a loop.
- `HTTPRangeSet.resolve` re-parses the field per pass (≈500× its length): parse once into a 256-entry stack buffer.
- AEA timestamp nanoseconds aren't checked below 10⁹ (the entry's `setattrlist` then fails with `EINVAL`): reject at
  parse.
- `ParallelBlockDecoder.take` reports the first failure in time, not in block order: the error can vary run to run;
  an `.aar` block error reads "segment N".

## 2. Performance (measured, per stream, reusing one coder)

| # | What | Evidence | Effect | Risk |
|---|---|---|---|---|
| 2.1 | `DeflateCompressor.reset()` clears both hash tables (192 KB) every stream; level 1 never reads hash3. Variant: skip hash3 at `.fastest`/`.stored`, clear 64 bytes per store | `perf/v1-deflate-encoder.diff`; identical output | Level 1: 64 B −38% instr / −26% cycles (now near libdeflate: 45.9 K vs 42.3 K), 1 KB −24% / −19%, 4 KB −12% / −8%; level 6 1 KB −14% / −5%; 64 KB −1%. HTTPBytes' per-body gzip, "Deflate 1/6 JSON (1.6 KB)", "Pipeline deflate 1 + TLS" (≈−21%) | Low |
| 2.2 | Also: don't allocate hash3 at levels 0–1 (as `chains` isn't) | — | −64 KB and a fill per encoder | Low |
| 2.3 | LZBITMAP's encoder fills 2¹⁸+32 `UInt16`s with 8 on every call (already 2 `stp` per 64 B) | 49.5 K instructions per call | 56% of a 1 KB encode, 26% at 4 KB, 2.3% of a 64 KiB chunk: ≈2% of Disk's LZBITMAP rows (1 GB file, 2,000 small files). Option (b): store positions biased by −8 so empty is 0 and clear with `memset` (12.3 K vs 18.5 K cycles); option (a): restore only inserted buckets after small inputs | Medium (byte-for-byte parity with Compression is the test; fold the bias in the hot loop) |
| 2.4 | Coder construction: 60% `__bzero`, 16% scalar non-zero fills (`DeflateCompressor.init`'s `UniqueArray(repeating: Int16.min)`, `LZMAWorkspace.allocate`) | Brotli encoder 861 K, bzip2 decoder 517 K, DEFLATE encoder 182 K instructions | Only for clients making a coder per stream; allocate uninitialized and run the existing (vector) reset | Low–medium |
| 2.5 | Brotli quality 1 on small inputs: 150 K vs Google's 69 K on JSON 1.6 KB (2.2×; quality 5 at parity) | Profile: 19% Huffman code building, 8% `storeComplex` | Investigation lead, not a proposal | — |

Checked with nothing to gain: `Decompressor`/`Compressor` dispatch (a whole 64-byte LZ4 stream is 342 instructions);
`ParallelBlockDecoder` fully specialized in NativeAEA, no allocations per block; Disk's `ChunkEncoders` exclusivity
checks (0.006% of a chunk: the follow-ups' "minor" stands, don't restructure for speed); merging the parallel engines;
per-stream decode setup (DEFLATE, zstd, xz, bzip2 at or below libdeflate/libzstd/liblzma/libbz2); inflate's table
builder's indirect call (a variant changed nothing); stack protectors (all per block or call); lazy globals (one, per
call).

## 3. API and design

1. **Honest units per format.** Every streaming decoder declares its real `maximumUnitByteCount` (bzip2's bounded
   tables, Brotli's and DEFLATE's largest header), exposed per `DecompressionFormat`. Fixes §1.3, and replaces guessed
   constants: HTTPBytes' 132 KiB carry ("zstd's largest block": zstd holds back 0 bytes, it consumes partial blocks)
   and `ChunkedDecompressor`'s staging. Decided by a byte-at-a-time test over the corpus recording the most held back.
2. **One block source for `ParallelBlockDecoder`** (`.indexed`, `.pbz(file:)`, `.pbz(upstream:)`,
   `.slices(size:start:end:)`) instead of Layout × Input: §1.5 can't be written. Split `BlockStage`'s trapping
   defaults (`block(_:)`, `read(at:into:)`) by stage kind; size the pool in the engine for both initializers (NativeAEA
   computes `decoders + extra + held + 1` by hand in Payload.swift and Decrypt.swift), which is also where §1.6's byte
   budget goes. Recheck specialization with `Tools/calls`.
3. **`PBZ.header(_:)`** returning compression and block size (or `nil`), throwing `.headerCutShort` when short:
   three NativeAEA sites repeat detect / length check / block size. `blockSizes`, `blockHeaderSize` → `package`.
4. **Narrow the public surface by usage** (AGENTS.md's recipe; `api/public.tsv` has the list). Public but used
   nowhere outside: `Decompressor.decompress(_:into:historyCount:)`, `isFinished`, `DecompressionFormat.historySize`,
   `isStreamable`, `DecodedBlock.init`, `ParallelDeflateDecoder.minimumSegment`; types no client names (BZip2Decoder,
   XZDecoder, LZMADecoder, LZFSE/LZVN/LZBitmap encoders, ParallelBrotliEncoder, CRC64, XXHash64, GzipHeader,
   ZstdFrameHeader, DeflateVariant). LZ4/LZFSE/LZVN/LZBITMAP/LZRAVEN/LZMA2 decoders are named only by NativeAEA's
   benchmark `SegmentDecoder`, which reimplements `DecompressionFormat(aeaSegment:)` + `Decompressor`: move it onto
   `Decompressor` (rows measured equal) and they can go `package`. DEFLATE and Brotli coders stay public (SocketStream
   uses them as generic stages). This decides whether the package presents codecs or Decompressor/Compressor.
5. **`Compressor` as a `ResettableByteTransform`** (Decompressor already is), with a throwing `reset(for:)` (§1.12).
   SocketStream's generic stages could then choose by format; `Compressor.init(for:)` and
   `CompressionFormat.isStreamable` are `package` while their Decompressor mirrors are public.
6. **One spelling for whole-buffer calls.** `LZBitmapEncoder.compress(_:into:)` is whole-buffer where every other
   `compress` streams; `decompressAll(_:decodedSize:into:)` vs `(_:into:decodedSize:)`; LZMA2Decoder's four entry
   names; LZFSE/LZVN encoders return `Int`, LZBITMAP's nothing. Add one `Decompressor`-level one-shot to an array
   (reserve then `append(addingCapacity:)`): XIP hand-rolls it twice with a zero-filled array and a redundant size check.
7. **Separate "output full" from "limit exceeded"** (a Bytes `BytesError` case): HTTPBytes tells zstd's window limit
   from a full buffer by checking `freeCapacity`. Related: both `AEAError` and `ZipError` special-case
   `BytesError.cancelled` out of decoding errors.
8. **LZMA's size limit in the decoder:** `.lzma(sizeHint:)` is documented as the most the stream decodes to but only
   caps the window; NativeZip keeps `outputLimit`/`produced` itself. Make it exact (`maximumSize`).
9. **HTTP's decoding knowledge in the package:** deflate's zlib-or-raw sniff, `DecompressionFormat.allowsConcatenation`
   (HTTPBytes' `continuesAfterEnd` repeats what the codecs know, and §1.1's fix needs the same fact), and
   `DeflateDecoder.reset(format:)` so `Decompressor` keeps one DEFLATE and one Deflate64 decoder instead of four
   (≈160 KB each).
10. **Shared in-order delivery for the synchronous parallel codecs:** `ChunkScheduler.deliverReady` and
    `InflateDelivery.deliverReady` are the same loop; three stop flags. Don't merge with the async engine (different
    shapes). ParallelDeflateDecoder has no `…Concurrently` form though both encoders do.
11. **Finer `BlockStage` hooks** (stored bytes: read or map; prepare: MAC and decryption; verify raw bytes):
    `AEASegmentStage.decode` redoes the default's reading, scratch reuse, timing, and stored fast path. Keep the full
    override for mapped, encrypted, stored segments. Decided by NativeAEA's List and Extract rows staying flat.
12. **`BlockBufferPool`'s 64 KiB carry region** is Apple Archive's header limit built into the generic pool: an
    initializer parameter (virtual memory only).

The earlier follow-ups (`Safe-Access-Followups-2026-11-23.md` §3) in the new layout:

- **`MaskedTable`** still belongs in Bytes (HTTPBytes and BytesCompression), now with three concrete compression
  clients: DeflateCompressor's hash tables (span, count precondition, hand mask at every index), Zstandard's
  `unsafe table[hash]`, LZFSE/LZVN's 32-byte `LZMatchTable` lines (a table of lines). Brotli's bucket rings don't fit.
- **Stride-typed storage** (the user's note) is best placed in BytesCompression as a generalization of
  `LZMAWorkspace`: its second client is `DeflateCompressor.clear`'s run-time alignment check, and §2.1's 64-byte clear
  and §2.4's construction fills want the same thing. HTTPBytes needs none.
- **Word reads:** BytesCompression is the main client (XXH64, CRC-64, the LZ encoders); BrotliEncoder borrowing
  `DeflateCompressor.load64` shows the missing shared encoder-helpers file.
- `StaticString.bytes`, path buffers, workspace regions: unchanged (no new sites; the last waits on the language).

## 4. Documentation and dead code

- ARCHITECTURE.md §3 describes block sources as one enum (§3.2's proposal), not the code's Layout × Input; §3 "One
  parallel engine" and §5 omit `ChunkScheduler` and ParallelDeflateDecoder's scheduler; the BytesCompressionAsync box
  omits ParallelCodecs.swift; §1's HTTP row implies one coding-to-format mapping where there are two `switch`es and a
  sniff.
- RESULTS.md's unify note "HTTPBytes keeps its Zstandard decoder" was superseded in stage 3.
- Brotli "quality 0–11" runs 10 and 11 as 9; DEFLATE "level 1–9" also accepts 0 (stored).
- `HTTPContentEncoder.reset()` says DEFLATE and Brotli "start over"; `Compressor.reset()` keeps their memory.
- HTTPBytes' 132 KiB carry comment is wrong (§3.1).
- `ZipDecoder.chunkSize` is unused (and a lazy `static let`).

## 5. Suggested order

1. §1.1–1.5 (truncation, amplification, traps, hangs), each with its reproducer as a regression test.
2. §1.6–1.11 (memory and CPU exposures), with §3.2's engine-side pool budget and §3.1's honest units as their vehicles.
3. §2.1–2.2 (small DEFLATE streams), then §2.3 (LZBITMAP), with small-input rows added first (HTTP bodies, 1–16 KB
   LZBITMAP encodes: none exist today).
4. §3.3–3.12 and §4, then the narrowing (§3.4) last, once the shapes have settled.
