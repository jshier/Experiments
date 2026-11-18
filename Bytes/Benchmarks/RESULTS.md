# Bytes performance log

Medians (p50) from `swift package --disable-sandbox benchmark`, M3 Ultra, macOS 27.2, Swift 6.4.2.
Baselines are in `.benchmarkBaselines/`. The table below is baseline `modern` (re-run on 2026-11-09 with no
other benchmarks running); the 2026-11-12 sections have newer full runs. Compare any two with
`../Tools/bench-table . --metric 'Time \(wall clock\)|Instructions|Malloc' <a> <b>`.

## 2026-11-18, LZMA, LZMA2, and .xz decoding: `LZMA2Decoder` against Compression and liblzma 5.8.4 (baselines `lzma-1`, `lzma-2`; Swift 6.4.4)

A decoder in BytesCompression for `.xz` files (`decompressXZ`), raw LZMA2 chunk streams (`decompressLZMA2`), and raw
LZMA (`decompressLZMA`, and `decompressLZMAFile` for `.lzma`), with `LZMAProperties` and `CRC64` (CRC-64/XZ). Made
for Apple's `.aea` archives, whose payload (Xcode's) is 624 xz streams of 16 MB: one block each, LZMA2 with an 8 MB
dictionary, no check. Apple's `aea decrypt` decodes them at about 165 MB/s per core.

`.xz`: stream header and footer (CRC-32s, flags, backward size), block headers (CRC-32, sizes, the LZMA2 filter
alone: BCJ, delta, and chains throw `invalidValue`), block padding, the index checked against the blocks (count,
both sums, and a CRC-32 of the records, as liblzma's `index_hash`, so nothing is allocated), several blocks, and
concatenated streams with stream padding. Checks: none, CRC-32, and CRC-64 verified; SHA-256 read but not verified;
reserved check types throw. LZMA2: control bytes 0x00, 0x01, 0x02, and 0x80–0xFF with the four reset levels; the
range decoder starts again per chunk; each chunk must fill its unpacked size, consume its packed size exactly, and
end with the code at 0; a match past a chunk is rejected (as liblzma does). LZMA: lc up to 8, lp and pb up to 4,
an end marker, a known size, or both. Each call decodes a whole stream into the caller's buffer, which is the
dictionary. The probability model (28 KB) is allocated at creation, and nothing after:
`Allocations:LZMA_decode_xz_0` and `_6` (JSON, 120 KB, CRC-64) pass zero-malloc thresholds.

References: Apple's Compression (`compression_decode_buffer`, `COMPRESSION_LZMA`, scratch buffer allocated once)
and Homebrew's liblzma 5.8.4 (`CLZMA`, a `.systemLibrary` via pkg-config, tests and benchmarks only;
`lzma_stream_buffer_decode`): one call each, whole file into a whole buffer, one thread. Inputs: Silesia files
through liblzma's preset encoder as `xz -6` and `xz -9e` write them (CRC-64, which all three verify; cached as
`CORPUS/cache/NAME-SIZE.xz-5.8-PRESET`), and five of Xcode's `.aea` segments (local only: registered when
`CORPUS/aea/seg*.xz` exist; seg0 is headers and text, the rest mostly binaries).

### Results (`lzma-2`, p50)

One run under the shared benchmark lock, each row's three decoders seconds apart, with other agents' builds on
the machine: times are ±10%. MB/s is the decompressed size over p50 wall-clock time; "×" is the other decoder's time
over Bytes'. Instructions are exact (in millions, so to about 0.1/B here).

| Input | Bytes MB/s | liblzma MB/s | Compression MB/s | × liblzma | × Compression | Bytes ins/B | liblzma ins/B | Compression ins/B |
|---|---|---|---|---|---|---|---|---|
| -6 dickens (9.7 MB) | 192 | 136 | 167 | **1.42x** | **1.15x** | 60.5 | 61.9 | 50.5 |
| -6 mozilla (48.8 MB) | 153 | 105 | 126 | **1.46x** | **1.21x** | 72.4 | 70.9 | 58.3 |
| -6 samba (20.6 MB) | 254 | 171 | 210 | **1.48x** | **1.21x** | 45.1 | 45.4 | 36.7 |
| -6 x-ray (8.1 MB) | 76 | 56 | 60 | **1.35x** | **1.27x** | 173.0 | 151.4 | 139.2 |
| -6 xml (5.1 MB) | 486 | 297 | 445 | **1.64x** | **1.09x** | 22.8 | 25.3 | 18.5 |
| -9e dickens (9.7 MB) | 200 | 142 | 164 | **1.41x** | **1.22x** | 60.4 | 61.9 | 50.5 |
| -9e mozilla (48.8 MB) | 155 | 112 | 122 | **1.38x** | **1.27x** | 71.3 | 70.0 | 57.4 |
| -9e samba (20.6 MB) | 257 | 170 | 212 | **1.51x** | **1.21x** | 44.6 | 44.9 | 36.3 |
| -9e x-ray (8.1 MB) | 77 | 55 | 60 | **1.39x** | **1.28x** | 173.0 | 151.4 | 139.2 |
| -9e xml (5.1 MB) | 535 | 314 | 445 | **1.70x** | **1.20x** | 22.4 | 24.9 | 18.3 |
| Apple seg0 (16.0 MB) | 104 | 88 | 90 | **1.18x** | **1.15x** | 99.5 | 86.8 | 78.6 |
| Apple seg130 (16.0 MB) | 212 | 177 | 186 | **1.20x** | **1.14x** | 49.3 | 46.0 | 40.2 |
| Apple seg200 (16.0 MB) | 430 | 336 | 365 | **1.28x** | **1.18x** | 25.5 | 23.6 | 21.0 |
| Apple seg255 (16.0 MB) | 160 | 124 | 129 | **1.29x** | **1.24x** | 70.8 | 65.1 | 58.9 |
| Apple seg60 (16.0 MB) | 430 | 323 | 357 | **1.33x** | **1.21x** | 26.0 | 23.5 | 21.0 |


Faster than both on every input: 1.09–1.28x Compression and 1.18–1.70x liblzma. On the Apple segments, 1.14–1.24x
Compression in this run; the interleaved harness below, which alternates the decoders in one process, measures
1.21–1.24x on all five (seg0 112 against 90 MB/s, seg60 435 against 357, seg130 226 against 186, seg200 431 against
357, seg255 160 against 131). At Compression's 165 MB/s average per core for Xcode's 624 segments, that's about
200 MB/s: 63 CPU-seconds becomes about 52.

Bytes runs more instructions per byte than Compression (99.5 against 78.6 on seg0) and still finishes first: the
work is a chain of dependent steps per bit, and the instructions added take steps off that chain (below).

`lzma-1` → `lzma-2` is the CRC-64: slicing-by-8 tables (2.2 GB/s, already twice liblzma's) took 18% of xml's
decode time, behind Compression on xml `-6` (0.92x) and samba `-9e` (0.99x). Folded with `pmull` through
CBytesCRC's `bytes_crc_fold` (the CRC-32's helper), four 16-byte lanes 64 bytes per step, it runs 24–41 GB/s:
Silesia rows −2 to −13% instructions, the Apple segments (no check) unchanged.

### How it got there (scratch harness: the three decoders interleaved in one process; cycles and instructions per output byte from `proc_pid_rusage`, so clock changes don't move them)

| Step | cycles/B seg0 / seg60 / seg255 | ins/B seg0 / seg60 / seg255 |
|---|---|---|
| Compression (reference) | 44.9 / 11.3 / 30.9 | 78.6 / 21.0 / 58.9 |
| liblzma 5.8.4 (reference) | 46.0 / 11.9 / 32.4 | 86.8 / 23.5 / 65.1 |
| 1. First version (`LzmaDec.c`'s structure, careful/fast loops, lc3/lp0/pb2 copy) | 60.8 / 13.3 / 36.7 | 93.5 / 23.8 / 63.7 |
| 2. `@inline(always)` on the range decoder's methods (`length`, `distance` were calls) | 60.9 / 12.9 / 35.1 | 87.3 / 22.0 / 58.3 |
| 3. Tree bits computed arithmetically, literal loops of 8 | 48.9 / 12.2 / 33.1 | 104.9 / 26.2 / 69.6 |
| 4. Plain literal: both children loaded while the parent decodes | 41.9 / 11.2 / 31.9 | 115.6 / 27.4 / 71.4 |
| 5. Matched literal: both candidates loaded ahead | 40.4 / 10.7 / 28.8 | 119.5 / 28.9 / 80.7 |
| 6. Normalization threshold in a register (`cmp` instead of `lsr` + `cmp`) | 38.3 / 10.4 / 28.4 | 111.9 / 27.3 / 76.4 |
| 7. Normalization deferred into the next bit (shift chosen before the multiply) | 37.6 / 10.3 / 28.0 | 107.7 / 26.8 / 75.7 |
| 8. Children loaded ahead in every tree (lengths, slots, reverse trees) | 36.7 / 9.4 / 25.8 | 108.8 / 27.5 / 76.4 |
| 9. Literal and matched-literal trees written out | 36.1 / 9.3 / 25.3 | 99.7 / 26.0 / 71.1 |


Not kept:

| Variant | cycles/B seg0 / seg60 / seg255 |
|---|---|
| Tree bits with branches, as `LzmaDec.c`'s C (after step 2) | 60.7 / 13.1 / 34.3 (ins/B 73.3 / 19.0 / 51.9) |
| Branch for each tree bit's normalization (after step 3) | 51.4 / 12.7 / 34.4 |
| Deferred normalization with masks instead of selects (after step 7) | 41.7 / 10.8 / 28.4 |
| Normalization with selects in the direct bits (after step 8) | 36.8 / 9.6 / 26.2 |
| Normalization with selects after decisions (after step 9) | 36.2 / 9.35 / 25.4 (neutral) |
| Deferred normalization from constant selects only, no branch (after step 9) | 39.8 / 10.1 / 27.5 |

The first version had `LzmaDec.c`'s structure and was 0.73–0.88x Compression. `Tools/counters` showed why: 52% of
its cycles discarded (mispredictions) and 32% lost in the front end, against Compression's 34% and 8%, with 67%
more branches per byte (13.5 against 8.1). LLVM had made the tree bits' `one ? 1 : 0` a branch, so every literal
bit was a coin-flip branch. After step 7, seg0 was 27% discarded, 40% back-end latency, and 3% front end (seg60
after step 8: 34% discarded, as Compression's 34%: the literal-or-match and repeat decisions). What bounds it now
is the chain from one tree bit to the next: pick the probability, multiply, compare, select. The steps shortened it
from about 11 cycles (index, load, multiply, compare) to about 6: the load is off the chain (both children are
loaded while the parent decodes, one 32-bit load), the normalization compare is one `cmp` against a register, and
the normalization's shift is chosen alongside it instead of after it. Normalization stays a branch: it predicts
well, and every branchless form measured slower.

## 2026-11-18, ASCII without tricks (baseline `d2-ascii`)

`ASCII.swift`: tags and signatures as text (`Byte4(ascii: "IHDR")`, `Byte(ascii: "-")`), magic numbers in a byte order
(`expect(_:_:)`), numbers written as digits (`read(_:asciiDigits:)`, `write(_:asciiDigits:)`), character classes on
`UInt8` and `ByteLanes`. Each new API against what a careful user writes by hand (`ASCII.swift` benchmarks):

| Workload | API | By hand | Change |
|---|---|---|---|
| 20,000 PNG-style chunk types | `Byte4(ascii:)`: 524 K instructions, 36 µs | hex literals: 524 K, 36 µs | identical (merged) |
| 20,000 log lines, 8 fixed-width numbers each | `read(_:asciiDigits:)`: 5,063 K, 151 µs | a digit at a time: 5,722 K, 177 µs | −11.5% / −15% |
| Counting digits in 620 KB | `ByteLanes.asciiDigits`: 854 K, 29 µs | `isASCIIDigit` per byte (auto-vectorized): 1,319 K, 78 µs | 2.7x faster |

Up to 8 digits are one 8-byte load, validated in two word operations and combined in three multiplies (pairs,
fours, eight); 9–16 digits two loads. Two bugs caught by the tests before anything shipped: validating the two
words ORed together (two digit values ORed can exceed 9), and the two-word path taken for fewer than 9 digits, which
loaded past the end of the data (only a test reading digits that end exactly at the data's end found it). Codegen:
`pointwiseMin` was a call per vector (replaced by a vector comparison, one `cmhi`), and the slow path, a generic
method on the cursor, took type metadata at every call site (now a non-generic static function over the digits'
span). BinaryParsingComparison's PNG, QOI, and LZ4 ports use `init(ascii:)` and `expect(_:_:)` at no change in
instructions. Review and remaining proposals: `../Proposals/NonNumericValues.md`.

## 2026-11-18, crypto in Swift, TLS 1.3, parallel sealing, parsing API (baselines `d2-start` → `d2-final`; Swift 6.4.4)

**BytesCrypto without CryptoKit or CommonCrypto.** AES-128/256 (`aese`/`aesmc` through `CBytesCrypto`'s `static
inline` wrappers; a constant-time portable path that computes the S-box in GF(2⁸)), counter mode with WinZip's
little-endian and GCM's big-endian counters, AES-GCM (GHASH by `pmull` Karatsuba, eight blocks aggregated per
reduction, reduction by two `pmull`s; stitched seal; tag checked before decrypting), SHA-1 and SHA-256 on the SHA
instructions, SHA-384/512, and HMAC, PBKDF2, HKDF over a `HashFunction` protocol. Tests: Wycheproof (C2SP) for both
AEADs, HMAC, and HKDF; CryptoKit differentially at every length. `d2-final`, p50, one run:

| Benchmark | Bytes | Apple | Relative |
|---|---|---|---|
| AES-128-GCM seal 1 MB × 1 | 133 µs | 111 (CryptoKit) | 0.83x |
| AES-128-GCM seal 16 KB × 64 | 124 µs | 154 | 1.24x |
| AES-128-GCM seal 1 KB × 1,024 | 212 µs | 919 | 4.33x |
| AES-128-GCM seal 64 B × 16,384 | 3,686 µs | 13,000 | 3.53x |
| AES-128-CTR 1 MB | 62 µs | 56 (CommonCrypto) | 0.90x |
| PBKDF2-HMAC-SHA1 × 1,000 | 118 µs | 343 (CommonCrypto) | 2.91x |
| SHA-1 1 MB | 362 µs | 377 (CryptoKit) | 1.04x |
| HMAC-SHA1 1 MB | 362 µs | 379 (CryptoKit) | 1.05x |
| SHA-256 1 MB | 400 µs | 337 (CryptoKit) | 0.84x |
| ChaCha20-Poly1305 seal 1 MB | 420 µs | 1,240 (CryptoKit) | 2.95x |

Instructions: AES-GCM 1 MB 2,902 K against CryptoKit's 2,980 K; SHA-256 2,065 K against 1,955 K; AES-CTR 1,779 K
against 1,669 K. Along the way: AES-CTR 453 → 80 → 62 µs (unrolled eight-block batches), SHA-256 5.5 M → 2.07 M
instructions (round constants as vector literals), GHASH 191 → 168 µs per MB before stitching, 133 after.

**TLS 1.3 (RFC 8446).** `TLSKeySchedule`, `TLSSecret` (Expand-Label, Derive-Secret, KeyUpdate's next secret,
Finished keys), `TLSTrafficKeys`, `TLSTranscript`, `TLSAlert`; records with inner type and padding, record-size and
record-count limits, automatic KeyUpdate before the limit (opener follows, answers `update_requested`), alerts,
`change_cipher_spec` only during a handshake. Tested against RFC 8448's traces. ChaCha20-Poly1305 enforces its
2^38 − 64-byte limit and rejects malformed tags by throwing.

**Parallel sealing** (`TLSRecordSealer.sealingLanes`): full records sealed on `concurrentPerform` lanes, each into its
place in the output. Its own run (p50, 4 MB per call): AES-128-GCM 5.7 / 20.3 / 32.7 GB/s on 1 / 4 / 8 lanes,
ChaCha20-Poly1305 2.0 / 7.6 / 13.9; `d2-final` measured AES-128-GCM 6.4 / 21.4 / 35.2. Instructions equal for any
lane count. Loopback numbers: `../SocketStream/RESULTS.md`.

**Tried and reverted:** ChaCha20's rotate by 8 as a `tbl` (double round 264 → 323 instructions: the table's
register forced spills). **Resolved:** Brotli's `BitBuffer.rewind` now measures equal to making a new buffer (54 K
instructions for the 1.6 KB stream, every quality and size equal; a scratch copy built both ways).

**Parsing API** (items 9–14 from the swift-binary-parsing ports): `@BinaryRecord` in the cursor's byte order,
`Byte`/`Padding`/`Reserved` fields, run-time integer widths, `read(utf8TerminatedBy:)` (a 16-byte scan,
`RawSpan.firstByteOffset(where:)`), `forEachRecord(… paddedTo:)`, and counts that throw (one unsigned compare: two
compares had cost LZ4 2%). `ByteMatches.nibbleMask` fixed (odd lanes reported bit 3). Effects in
`../BinaryParsingComparison/RESULTS.md`.

Everything else, `d2-start` → `d2-final` in instructions: within ±0.5%, except costs the standards require and
reference rows. ChaCha20-Poly1305 seal 64 B × 16,384 74 → 76 M (+2.7%: the message-length precondition and checks,
per call); TLS open on 1.6 KB streams +1 K (41 → 42 K, 57 → 58 K: the opener's RFC 8446 checks); `Byte7`
`read(_:_:into:)` +1.0%; the `Literals … (before)` reference rows +1.4 to +3.0% and libdeflate's 1.6 KB inflate −5.6%,
code that didn't change (layout).

## 2026-11-18, Zstandard decoding: `ZstdDecoder` against libzstd 1.5.7 (baseline `zstd-1`; Swift 6.4.4)

A Zstandard (RFC 8878) decoder in BytesCompression (`ZstdDecoder`, `ZstdFrameHeader`, `XXHash64`), for
NativeZip's method 93. Every frame form, raw/RLE/compressed blocks, raw/RLE/Huffman (1 and 4 streams,
single- and double-symbol tables)/treeless literals, predefined/RLE/FSE/repeat sequence tables, repeat offsets,
skippable and concatenated frames, content checksums (verified). Dictionaries are rejected. `decompressAll`
decodes into the caller's buffer (no window); `decompress` streams through a window of its own that wraps
(libzstd's "external dictionary" segment), up to `maximumWindowSize` (default 128 MB), resumable at any input or
output boundary.

Reference: Homebrew's libzstd 1.5.7 (`CZstd`, a `.systemLibrary` via pkg-config, linked by the tests and
benchmarks only), one thread, a reused `ZSTD_DCtx` (`ZSTD_decompressDCtx`) or `ZSTD_DStream`. Inputs: Silesia
files through the `zstd` CLI 1.5.7 (`-1`, `-3`, `-19`, `--long=27 -19`; checksums on, as the CLI writes them,
and both decoders verify them), and the first 1–64 KB of dickens, xml, mozilla, and Web Inspector's Main.js at
`-3` and `-19`. Cached as `~/Library/Caches/Experiments/corpus/cache/{,small/}NAME-SIZE.zstd-1.5.7-LEVEL`.

One full run (`zstd-1`, p50) under the shared benchmark lock; another agent's builds were running, so times are
±10% (each row's two decoders ran minutes apart). Instructions are exact, except that the tool prints
instructions in thousands: the 1 KB rows' values are at that resolution (19.53/B is 20 K). MB/s is the input's
decompressed size over p50 wall-clock time; "×" is libzstd's time over ours.

### Silesia, one call and streamed (64 KB input pieces into a 64 KB output buffer, both decoders)

| Input | Bytes MB/s | libzstd MB/s | × | Bytes ins/B | libzstd ins/B | Bytes streamed MB/s | libzstd streamed MB/s | × | Bytes ins/B | libzstd ins/B |
|---|---|---|---|---|---|---|---|---|---|---|
| L1 dickens (9.7 MB) | 1781 | 1504 | **1.18x** | 9.91 | 11.09 | 1760 | 1391 | **1.27x** | 10.01 | 11.38 |
| L1 mozilla (48.8 MB) | 1707 | 1384 | **1.23x** | 8.47 | 9.39 | 1652 | 1249 | **1.32x** | 8.69 | 9.64 |
| L1 samba (20.6 MB) | 2460 | 1964 | **1.25x** | 6.57 | 7.13 | 2396 | 1964 | **1.22x** | 6.76 | 7.36 |
| L1 x-ray (8.1 MB) | 1497 | 1328 | **1.13x** | 7.79 | 10.03 | 1399 | 1258 | **1.11x** | 8.14 | 10.38 |
| L1 xml (5.1 MB) | 3197 | 2505 | **1.28x** | 5.05 | 5.61 | 3086 | 2345 | **1.32x** | 5.24 | 5.80 |
| L19 dickens (9.7 MB) | 1959 | 1352 | **1.45x** | 10.60 | 11.68 | 1973 | 1268 | **1.56x** | 10.79 | 11.97 |
| L19 mozilla (48.8 MB) | 1313 | 1113 | **1.18x** | 10.48 | 11.48 | 1423 | 1113 | **1.28x** | 10.70 | 11.71 |
| L19 samba (20.6 MB) | 2207 | 1964 | **1.12x** | 6.39 | 6.99 | 2161 | 1662 | **1.30x** | 6.62 | 7.22 |
| L19 x-ray (8.1 MB) | 889 | 706 | **1.26x** | 19.47 | 21.48 | 892 | 706 | **1.26x** | 19.71 | 21.83 |
| L19 xml (5.1 MB) | 3916 | 3101 | **1.26x** | 4.12 | 4.49 | 3494 | 3015 | **1.16x** | 4.30 | 4.68 |
| L3 dickens (9.7 MB) | 1536 | 1092 | **1.41x** | 13.44 | 14.91 | 1627 | 1033 | **1.57x** | 13.64 | 15.11 |
| L3 mozilla (48.8 MB) | 1652 | 1313 | **1.26x** | 9.31 | 10.25 | 1652 | 1220 | **1.35x** | 9.53 | 10.48 |
| L3 samba (20.6 MB) | 2488 | 1801 | **1.38x** | 7.13 | 7.87 | 2422 | 1801 | **1.35x** | 7.31 | 8.05 |
| L3 x-ray (8.1 MB) | 1196 | 917 | **1.30x** | 12.98 | 15.46 | 1196 | 921 | **1.30x** | 13.33 | 15.93 |
| L3 xml (5.1 MB) | 3165 | 2414 | **1.31x** | 5.43 | 5.99 | 3005 | 2291 | **1.31x** | 5.61 | 6.17 |
| long=27 L19 mozilla (48.8 MB) | 1220 | 1004 | **1.21x** | 10.41 | 11.99 | 1348 | 1090 | **1.24x** | 10.62 | 12.22 |

Faster on every Silesia input and level: one call 1.12–1.45x, streamed 1.11–1.57x, with 7–22% fewer
instructions per byte (x-ray L1 22%: libzstd picks double-symbol Huffman tables for its literals; see below).
The narrowest are x-ray L1 (Huffman-bound: 85% of the time in the four-stream loop) and samba L19.

### Small inputs, one call

| Input | Bytes MB/s | libzstd MB/s | × | Bytes ins/B | libzstd ins/B |
|---|---|---|---|---|---|
| L19 dickens 1 KB | 384 | 311 | **1.23x** | 29.30 | 30.27 |
| L19 dickens 4 KB | 812 | 692 | **1.17x** | 20.02 | 21.48 |
| L19 dickens 16 KB | 1024 | 655 | **1.56x** | 18.92 | 20.63 |
| L19 dickens 64 KB | 1311 | 923 | **1.42x** | 16.28 | 17.96 |
| L3 dickens 1 KB | 447 | 409 | **1.09x** | 23.44 | 24.41 |
| L3 dickens 4 KB | 826 | 697 | **1.18x** | 18.80 | 20.26 |
| L3 dickens 16 KB | 1092 | 780 | **1.40x** | 16.91 | 18.62 |
| L3 dickens 64 KB | 1394 | 1192 | **1.17x** | 14.02 | 15.20 |
| L19 Main.js 1 KB | 464 | 455 | **1.02x** | 20.51 | 20.51 |
| L19 Main.js 4 KB | 833 | 812 | **1.03x** | 16.60 | 17.58 |
| L19 Main.js 16 KB | 1365 | 1170 | **1.17x** | 11.60 | 12.70 |
| L19 Main.js 64 KB | 1680 | 1237 | **1.36x** | 11.12 | 12.22 |
| L3 Main.js 1 KB | 491 | 455 | **1.08x** | 19.53 | 19.53 |
| L3 Main.js 4 KB | 910 | 806 | **1.13x** | 14.89 | 15.87 |
| L3 Main.js 16 KB | 1489 | 1260 | **1.18x** | 10.99 | 12.15 |
| L3 Main.js 64 KB | 1928 | 1524 | **1.26x** | 10.10 | 11.11 |
| L19 mozilla 1 KB | 431 | 464 | **0.93x** | 14.65 | 15.62 |
| L19 mozilla 4 KB | 799 | 664 | **1.20x** | 17.09 | 17.82 |
| L19 mozilla 16 KB | 1260 | 1092 | **1.15x** | 13.37 | 14.47 |
| L19 mozilla 64 KB | 1986 | 1725 | **1.15x** | 9.32 | 10.13 |
| L3 mozilla 1 KB | 512 | 424 | **1.21x** | 13.67 | 13.67 |
| L3 mozilla 4 KB | 902 | 669 | **1.35x** | 17.09 | 18.07 |
| L3 mozilla 16 KB | 1365 | 1092 | **1.25x** | 13.43 | 14.53 |
| L3 mozilla 64 KB | 2341 | 1725 | **1.36x** | 7.83 | 8.53 |
| L19 xml 1 KB | 447 | 431 | **1.04x** | 19.53 | 19.53 |
| L19 xml 4 KB | 1311 | 1229 | **1.07x** | 9.28 | 10.01 |
| L19 xml 16 KB | 3094 | 2674 | **1.16x** | 5.00 | 5.37 |
| L19 xml 64 KB | 5041 | 4096 | **1.23x** | 3.45 | 3.83 |
| L3 xml 1 KB | 501 | 473 | **1.06x** | 19.53 | 19.53 |
| L3 xml 4 KB | 1199 | 1057 | **1.13x** | 11.23 | 11.72 |
| L3 xml 16 KB | 2829 | 2246 | **1.26x** | 5.92 | 6.41 |
| L3 xml 64 KB | 4369 | 3449 | **1.27x** | 4.33 | 4.81 |

31 of 32 faster by time (1.02–1.56x), and none takes more instructions. The exception is mozilla's first 1 KB at
L19: 0.93x in time (2.4 against 2.2 µs) with 6% fewer instructions; the scratch harness, interleaving the two
decoders, had it at 1.16x. At 1 KB a frame is one block and per-frame setup dominates (table builds, the
checksum's init and digest), so these rows are the most sensitive to the machine's state.

### Allocations

`Allocations:Zstd_decode_L1`, `_L19`, and their `_streaming` forms (JSON, 120 KB): zero, after a first frame,
one call or streamed in 1,000-byte pieces (`Thresholds/CompressionBenchmarks.Allocations:Zstd_*`, checked with
`benchmark thresholds check --filter 'Allocations:Zstd.*'`). The decoder allocates its tables and literal buffer
(160 KB) at creation; streaming adds the window (window size + 128 KB + 64) and an input stash (128 KB) on its
first frame, growing only for a larger window.

### How it got there (instructions per byte from a scratch harness that interleaves the two decoders)

| Step | Effect |
|---|---|
| First complete decoder (libzstd's loops: X1 four-stream fast loop with sentinel bits, sequences executed one at a time with 16/32-byte wild copies, careful path out of line) | Already 5–28% faster than libzstd on every Silesia input; 1–4 KB inputs 1–24% slower, with ~25 K extra instructions per frame |
| Table-building scratch in raw workspace memory instead of `InlineArray`s | 1–4 KB inputs: 18–35% fewer instructions, now 10–24% faster than libzstd. An `InlineArray<256, Int16>` passed `borrowing` was copied (512 bytes, `memmove`) at every subscript in the FSE spreading loop: 16,000 copies per 4 KB frame, 22% of its time |
| Near-start bit reload as a static function taking values, not a `mutating` method | −1 to −1.5%: the reader had been spilled for the whole sequence loop (its address escaped to the out-of-line call) |
| FSE states as absolute entry indices in the workspace (one table pointer for all three) and pointer positions for output and literals | −3 to −5% instructions, 10–20% faster: spills in the loop 21 → 10 stack accesses per sequence |
| Double-symbol (X2) Huffman tables, chosen by a measured rule | dickens L1 −8% instructions, 1.08x → 1.23x libzstd; nothing else moves by more than 0.1% |

Kept out, with the measurement:

| Change | Measured | Outcome |
|---|---|---|
| libzstd's `HUF_selectDecoder` cost model for X1/X2 | picks X2 for x-ray's literals (compressing to 12–13/16): x-ray L1 +6% instructions, 1.12x → 1.07x libzstd; mozilla, xml +0.3–4% | replaced by "X2 when literals compress to under 10/16 and there are 8 KB or more" |
| Prefetching each match's source when its offset is decoded (libzstd does on AArch64; `Builtin.int_prefetch` gives `prfm pldl1keep`) | +0.7% instructions; interleaved A/B, 3 rounds: mozilla L19 1,315 against 1,411 MB/s, long=27 1,391 against 1,423, x-ray and dickens unchanged | removed |
| libzstd's long-offset decoder (8 sequences decoded ahead, matches prefetched) | not built: the `--long=27` case is already 1.2–1.3x libzstd | — |

## 2026-11-17, the proposals pass: named fields, byte-ordered cursors, macros, BytesAsync, stitched ChaCha20-Poly1305 (baselines `trk-t0` … `trk-t5`, `trk-final`, each also `-portable` and `-portable-no-c` where run; Swift 6.4.4)

Every proposal from the 2026-11-16 review, implemented one step at a time, each step benchmarked across every
package that uses Bytes (this one, MQTT, BinaryParsingComparison, Base64, NativeZip, SocketStream) and, at
milestones, in all three builds. Instruction counts are the measure; times only where the change is large or was
A/B'd. Steps, in order:

| Step | What | Baselines |
|---|---|---|
| t1 | Named bit fields: `BitFlag`, `BitField<Value>`, `BitPattern`; `read(UInt8.self)`, `read(Int.self, as: Bits<n>.self)` | `trk-t1` |
| t2 | `read(_:asSigned:_:)` (replaces `readSigned`), any-integer writes and byte counts; `BigEndianBytes`/`LittleEndianBytes` cursor modes; MQTT parse-once | `trk-t2` (+ builds) |
| t3 | Adler-32 and `RunningChecksum` in the core; `nibbleMask`; declared transform units, one end-of-stream rule, a drive loop; `BytesAsync`; `LentBytes` | `trk-t3` (+ builds) |
| t4 | `BinaryParsable`/`BinaryWritable`/`FixedSizeBinary`; `BytesMacros` (`@BitFields`, `@BinaryRecord`); `BytesFoundation` | `trk-t4` |
| t5 | Stitched ChaCha20-Poly1305 | `trk-t5` |

### Results, t0 → final (instructions unless noted)

| Workload | t0 | final | Change |
|---|---|---|---|
| ChaCha20-Poly1305 seal 1 MB, time (interleaved A/B, 3 rounds) | 691–764 µs | 419–421 µs | **−40%** (1.52 → 2.50 GB/s) |
| ChaCha20-Poly1305 seal 16 KB × 64, time | 717 µs | 433 µs | **−40%** |
| ChaCha20-Poly1305 seal 16 KB × 64 | 8,905 K | 8,774 K | −1.5% |
| ChaCha20-Poly1305 seal 64 B × 16,384 | 77 M | 74 M | −3.9% |
| SocketStream protect, TLS records (time) | 1,162 µs | 715 µs | **−38%** |
| SocketStream unprotect, TLS records (time) | 1,230 µs | 758 µs | **−38%** |
| SocketStream protect/unprotect with brotli or deflate (time) | | | −11 to −14% |
| NativeZip inflate + CRC, 32 MB text / 2,000 files | 247 / 238 M | 240 / 232 M | −2.8 / −2.5% |
| MQTT PUBLISH parse, properties visited while parsing (new) vs frames + `forEach` | 8,831 K | 7,365 K | **−16.6%** |
| Zip directory with `@BinaryRecord` (new) vs field by field / ParserSpan | 285 / 461 K | 199 K | −30 / −57% |
| Everything else in all packages and all three builds | | | within ±0.5% |

Sync parallel DEFLATE allocates once more per call (11 → 12): the scheduler's `ChunkBatch` holds its worker as a
closure. Times of the other rows moved within this machine's drift (±5–10% between runs; `trk-t0` also ran while
tests built).

### Kept, measured neutral

- Named fields: every accessor compiles to the hand-written shift and mask (a probe package; LLVM merged each pair).
  A `BitPattern` literal folds to its two masks only with `@inline(__always)` on both initializers. Adopted in MQTT,
  LZ4, QOI, NativeZip (DOS date/time, attributes, the Huffman entry: decode loop 246 → 236 instructions, inflate
  −2.5 to −2.8%), and DEFLATE/zlib/gzip headers.
- Byte-ordered cursors: `read(UInt32.self)` on a `BigEndianBytesReader` compiles to `read(Byte4.self, .bigEndian)`
  exactly; writes too, once the order test is a `switch` (the standard library's `ByteOrder.==` is an out-of-line
  call: 71 against 53 instructions; `~/Downloads/swift-bugs/26`). Adopted: MQTT, SocketStream, NativeZip, BPC's zip.
- Macros: `@BinaryRecord` parses BPC's zip directory in 199 K instructions, the same as the hand-written
  fixed-record parser, once the generated `init(parsing:)` is forced inline (297 K before: a call, the record
  returned through memory). NativeZip's directory with macro records: +0.4% (unchanged code in the same file
  moved as much). Brotli output byte-identical through every change.
- `BytesAsync`: the async entry points moved without change; `withLentBytes`/`withLentFreeCapacity` replace the
  codecs' private pointer wrappers; `offloaded(to:)` runs any stage on a queue.

### Reverted or not done, with the measurement

| Change | Measured | Outcome |
|---|---|---|
| Enum field setter with `assert` + mask | MQTT PUBLISH encode +0.8% | `precondition`, unmasked store: back to t0 |
| Properties validation through an empty `visit` closure, forced inline | MQTT parse −1%, SocketStream check +10.4% (PR toolchain) | separate bodies: both at t1 |
| Brotli tag filter on `nibbleMask` (4 bits per slot) | q5 dickens +2.7% | reverted; the one-bit gather stays |
| `HuffmanCodeBuilder` in the Bytes core | Brotli 1.6 KB streams +1.3–1.7%, whatever the inlining attribute | moved back to BytesCompression |
| Public unchecked loads | the codecs use the standard library's `unsafeLoadUnaligned` | dropped |
| Generic `withBitBuffer` over the error type | no callers | dropped |
| NEON Poly1305 | would compete with eight-block ChaCha20 for the vector pipes in the stitched loop | not pursued |
| DEFLATE compressor staging on `ByteBuffer` | needs `BitWriter` slack and zero-copy buffer swaps | kept as is |

### ChaCha20-Poly1305, stitched

Poly1305's multiply chain (integer units) between ChaCha20's eight-block double rounds (vector units, all 32
registers): three Poly1305 blocks after each double round, two at the end, 32 per 512-byte batch. Sealing
authenticates the batch before the one being encrypted; opening authenticates the batch it decrypts and, on a
tag mismatch, XORs again to restore the ciphertext. Below 512 bytes, two passes, as before. The loop is the old
264-instruction double round plus 127 for the Poly1305 blocks (`Tools/loops`), with the same spills. Instructions
for 1 MB: 8.77 → 8.64 M; time −40%.

## 2026-11-16, byte-aligned cursors: `AlignedBytesReader` and `AlignedBytesWriter` (baselines `exp10-*`, `p4-generic`, `p4-aligned`)

**The cost.** `BytesReader` and `BytesWriter` can read and write at any bit position, and they carry that state
everywhere:
- a bit offset (and, in the writer, the partly written byte), tested on every byte-level operation;
- a partial-byte term in `remainingByteCount`.

The optimizer can't prove the bit offset stays 0 through a loop, because the unaligned path, never taken by
byte-only formats, can change it.

**The ceiling.** To measure the most a byte-only cursor could save, scratch copies of the tree were built
(`exp10-base`, and `exp10-byte` with the bit offset and partial byte made the constant 0):

| Client | Change (instructions) |
|---|---|
| MQTT encode | −6.1% (writer alone: −6.1%) |
| MQTT parse | −0.9% to −2.9% (reader) |
| Base64 encode, short inputs | −1.5% to −7.7% |
| QOI, runs written a pixel at a time (BinaryParsingComparison) | −22% (reader) |
| QOI, runs filled at once | +54% (antelope.qoi) and +9% (tricolor.qoi), also from the reader |

**The design.** One implementation, two modes:
- `GenericBytesReader<Mode>` and `GenericBytesWriter<Mode>`, with `Mode` either `BitAddressable` or
  `ByteAligned` (`Sources/Bytes/CursorMode.swift`).
- `BytesReader` and `BytesWriter` are the bit-addressable forms; `AlignedBytesReader` and
  `AlignedBytesWriter` the byte-aligned ones.
- The bit offset and partial byte are accessors over stored fields: `Mode.addressesBits ? stored : 0`. For a
  byte-aligned cursor, every test of them folds after specialization.
- The byte-level API is written once, in unconstrained extensions. Bit reads and writes, `seek(toBitPosition:)`,
  `skip(bitCount:)`, and `Bits` iteration are in extensions constrained to `BitAddressable`.
- `Byte` (`Bits<8>`) reads, writes, `expect`, and raw-value forms are in both. An aligned reader converts to and
  from a bit-addressable one at a byte boundary.
- Out-of-line helpers (`_copyLong`, `_copyRepeating`, `_writeUnalignedBytes`, `_unalignedBytes`,
  `_readLEB128`) moved to the `BitAddressable`-constrained extensions. There they're not generic, so
  specialized code of either mode calls them without passing type metadata (checked: `Tools/calls` finds no
  metadata accessors).
- **Builders are named apart:** `[UInt8](alignedByteCapacity:)`, `append(alignedByteCapacity:)`, and
  `withAlignedBytesWriter`. Overloads on the closure's writer type made every closure that works with either
  writer ambiguous; generic over the mode, they couldn't infer it.
- `String(utf8Capacity:)` now takes an `AlignedBytesWriter`, since UTF-8 is whole bytes.

**The refactor alone changes nothing** (`p4-generic` against `p3-after` and `exp10-base`, clients unchanged).
Every row of Bytes' two benchmark targets, MQTT, BinaryParsingComparison, and Base64 is within the reporting
resolution.

**Adopted:**
- MQTT, entirely;
- SocketStream's packet encoder and checker;
- Base64 (its API now takes the aligned cursors);
- BinaryParsingComparison's Bytes parsers;
- NativeZip's archive parsing and its inflater's output;
- BytesCompression's decoder outputs and gzip/zlib header and trailer readers;
- BytesCrypto's TLS records and ChaCha20 key and nonce readers.

The bit readers (DEFLATE and Brotli headers, `BitBuffer` users) stay bit-addressable.

Results (`p4-generic` → `p4-aligned`, instructions):

| Rows | Change |
|---|---|
| MQTT encode | −6.1% (5,464 K → 5,132 K) |
| MQTT parse | −0.9% to −2.9% |
| Base64 encode, 40–95 B | −4.5% to −7.7% |
| Base64 encode, 1 KB | −1.5% |
| Base64 encodedString | −0.9% to −1.4% |
| Base64 decode, 47 B | −3.7% |
| Base64 decodedBytes | −0.6% to −1.5% |
| DEFLATE decode (one-shot and streaming, every corpus file) | −1.7% to −4% |
| Brotli decode, 1.6 KB streams | −1.5% to −2.9% |
| Brotli decode, large streams | 0 to −0.4% |
| TLS + inflate receive pipelines | −1.5% to −2% |
| TLS + Brotli receive, 1.6 KB | −3.4% |
| SocketStream in-memory encode and check (vs `ss-new-2`, which also predates the section above) | −1.2% and −1.3% |
| SocketStream protect and unprotect | unchanged |
| NativeZip inflate and parse | unchanged (its "extract small files" row moves ±13% between runs: file-system calls) |
| QOI pixel-at-a-time (BinaryParsingComparison) | −22% |

Base64's "portable groups" decode rows, which don't use either cursor in their hot path, moved +1.6% and +2.2%.

**QOI's run-filling decoder keeps `BytesReader`.** With the aligned reader, LLVM nested the run fills' loops
(the vectorized `write(repeating:)`) inside the per-pixel loop, where before they sat beside it: an 88-instruction
innermost loop became a 287-instruction outer one, with spills. That cost 54% more instructions on
antelope.qoi (22.2 G → 34.3 G for 200 decodes, a scratch driver). Two attempts didn't change it:
- a `_slowPath` hint on runs: 33.5 G;
- the fill moved out of line: 35.4 G.

So that variant uses `BytesReader` and the aligned writer, and the pixel-at-a-time variant the aligned reader.
The decoder is generic over the reader's mode.

With that (BinaryParsingComparison `p4-aligned2`):
- the run-filling decoder is back to 111 M and 1,318 K;
- the pixel-at-a-time one stays at −22%;
- the zip-directory, LZ4, and integer workloads didn't change with the aligned reader: their loops were already
  as tight as the `exp10` ceiling allowed.

## 2026-11-16, matching, bit writing, and searching in core (baselines `p3-before`, `p3-after`, and probes)

`p3-before` was built from a copy of the tree before these changes, and `p3-after` after them, in Bytes'
CompressionBenchmarks (every Bytes row) and BytesBenchmarks (everything but allocations), Base64 (Bytes rows)
and NativeZipArchive (Bytes rows). Where a row moved by one reported unit, exact percentiles were exported from
both builds (`--format histogramPercentiles`). Timings weren't compared.

**What was added and moved:**
- **`RawSpan.commonPrefixLength(at:and:from:maxLength:)`**, checked once per call, and
  **`unsafeCommonPrefixLength`**. The compressors' match extension is now the unchecked form (it was a private
  copy).
- **`BitWriter`**, from BytesCompression's private `DeflateBitWriter`. It writes least significant bit first,
  flushes 8 bytes at a time, and has a checked `flush()` and an `@unsafe` `unsafeFlush()`.
- **`BitBuffer.position` and `rewind(to:)`.**
- **`bits(from:count:)`**, a shift then a mask, used by the DEFLATE and NativeZip subtable lookups.
- **`seek(toByteOffset:)` and `seek(toBitPosition:)`** are now always inlined. Base64's encoder seeks instead
  of making a new reader.
- **`RawSpan.hasSuffix(_:)`.** Base64's padding test uses it, and a checked load, where it had an unchecked
  one.
- **`ByteMatches.bitmask` and `firstIndex`.** Brotli's private lane mask is gone.
- **`RawSpan.firstByteOffset(of:from:)`.** It replaced the parallel inflater's hand-written search for
  `00 00 FF FF`.

**Results** (instructions, `p3-before` → `p3-after`):

| Rows | Change |
|---|---|
| Brotli quality 1 encode | −1.8% to −2.5% (Main.js 143 M → 140 M, xml 122 M → 119 M) |
| Brotli q5/q9, DEFLATE 1/6/9 encode | 0 to −0.6% |
| Parallel inflate | −1.7% to −3.1% |
| Parallel Brotli | −1.1% to −1.3% |
| Base64 decode, 40 and 64 bytes | about −3% to −4% (exact: 37 → 36 and 24 → 23 in the benchmark's scaled units) |
| Base64 encode, 1 KB and 1000 B | +0.2% |
| NativeZip inflate | identical |
| Everything else | within ±1% |

- **Parallel inflate** is probably faster because of the new search, which compares a vector's first and last
  bytes, where the old one compared four offset vectors. Parallel rows include the threads' variation.
- **NativeZip's "extract 2,000 small files"** moved +2% in one run and −4% in another: it's file-system calls.
- **Brotli's small-stream decode** is unchanged once `rewind` was reverted (see below).

**Probes that changed the design:**
- **A checked match extension costs too much in a match finder.** `commonPrefixLength`'s one bounds check (an
  OR of the bounds, one sign test) adds about eight instructions per call. The match finders call it per
  candidate: 3–18% more instructions (DEFLATE 6 dickens 1,311 M → 1,401 M, Brotli q9 dickens 4,664 M →
  5,515 M; `p3-prefix`). The unchecked form restored every row exactly (`p3-prefix2`). Both forms stay. The
  compressors' safety argument (`maxLength` never passes the data's end) is now a comment at their one call
  site.
- **`BitWriter.flush()`'s capacity check costs 0.2–1.7%** (`p3-bitwriter`). It's two instructions and a branch
  against about five for the flush. The encoders use `unsafeFlush()`, because their staging buffers are
  reserved per block or meta-block. With that, the core writer is slightly ahead of the private one
  (`p3-bitwriter2`): Brotli q1 −1.8% to −2.5%, the rest 0 to −0.6%.
- **A compile-time bit order isn't worth it** (`exp7-lsb`, built in a scratch copy). With `BitBuffer`'s
  `switch bitOrder` hard-coded to least significant first, DEFLATE decode ran 0.5–3.6% *more* instructions and
  Brotli ±0.3%. The run-time `let` already folds wherever the buffer is inlined. So `BitBuffer` stays
  non-generic, and `BitWriter` is least-significant-first only (DEFLATE, Brotli and zstd's order).
- **Brotli's decoder still builds a new `BitBuffer` to undo a unit.** Rewinding at its six "input ran out" sites
  ran 1–2 K more instructions on 1.6 KB streams (q5 56 K → 57–58 K, q11 68–69 K → 70 K, TLS + Brotli receive
  59 K → 60 K). Those streams decode entirely in that near-the-end path.
  - Bisected in scratch copies: reverting the rewinds restored the counts; un-inlining `seek` didn't change them.
    Keeping `rewind` out of line cost the same.
  - The cause wasn't found. The API stays, with this measurement in its documentation.

**Not done:**
- `withBitBuffer` generic over the error type. A body's error and the overrun error would need one type.
- A public `Load`/`Store` namespace.
- Byte-only cursors (suggestion 10): done separately, in the section above.

## 2026-11-16, buffer and copy API: no change in instructions (baselines `s1-before`, `s1-lib`, `s1-after`)

New in `Sources/Bytes/Buffers.swift`, for the copies every client wrote with `withUnsafeMutableBytes` and
`copyMemory`, since the standard library (Swift 6.4) has no safe copy into a `MutableRawSpan` or an
`OutputRawSpan`:

- `OutputRawSpan.append(copying:)`;
- `OutputRawSpan.withFreeCapacity(byteCount:_:)`, which hands the closure a `MutableRawSpan` over the free
  capacity and counts the bytes the closure reports writing;
- `copyBytes(from:toByteOffset:)` and `copyBytes(within:toByteOffset:)` (the ranges may overlap) on
  `MutableRawSpan` and `MutableSpan<UInt8>`;
- `withOutputRawSpan(overwritingFrom:_:)` on `[UInt8]`, `MutableSpan<UInt8>` and `MutableRawSpan`. It keeps the
  closure's error type, so it also avoids swiftlang/swift#90291.
- `ByteBuffer`, which fills at its end and drains from its front:
  - one allocation that never moves, so `receive(_:)` can suspend (a socket read) with its output span in place;
  - `fill(_:)` compacts first when less free space is left at the end than a threshold (half by default);
  - `consume(_:)` and `compact()`.
- `BytesWriter(&mutableSpan, atByteOffset:)`, a writer that continues after bytes already written.

The new copies share `write(_: RawSpan)`'s inline copy for spans up to 64 bytes (now `BytesWriter._copyBytes`).

Moved onto them:
- `Pipeline`'s buffer, now a `ByteBuffer` that compacts below a quarter free, as before;
- the DEFLATE and Brotli decoders' one-shot output, delivery and window slides;
- the encoders' window fills, slides and delivery;
- the parallel DEFLATE encoder's window and delivery, and the parallel decoder's buffer growth;
- the TLS sealer's and opener's copies and in-place sealing and opening;
- SocketStream's two receive buffers, which were three hand-written copies of `ByteBuffer`;
- the compression benchmarks' output buffers.

Counts of `withUnsafe*Bytes`, `copyMemory`, `OutputRawSpan(buffer:)` and `MutableRawSpan(mutating:)` before
and after:

| Where | Before | After |
|---|---|---|
| BytesCompression | 66 | 26 |
| BytesCrypto | 10 | 2 |
| `Pipeline` | 5 | 0 |
| SocketStream sources | 9 | 1 |
| SocketStream benchmarks | 4 | 0 |
| compression benchmarks | 34 | 10 |

What remains in BytesCompression is mostly the parallel codecs handing pointers to worker threads.

Instruction counts, on the inflate, Brotli decode and encode, streaming deflate, pipeline, two-pass and
parallel rows, and BytesBenchmarks' span copies, literals, fields and sections:
- **`s1-before`** was built from a copy of the old tree.
- **`s1-lib`** is the library change only, with the benchmarks unchanged.
- **`s1-after`** also has the converted benchmark harnesses.

Every row is unchanged within the reported resolution, three significant figures (1 K on 30 K). Allocations
are unchanged; pipelines still allocate nothing per stream.

The largest apparent change, Inflate JSON 1.6 KB at 29 K → 30 K (+3.4%), read 30 K → 30 K when the exact
percentiles were exported from both builds. The others are within 0.7%, and the reference rows (Google, Apple)
move as much. MQTT's encode and parse (5,464 K and 9,888 K) are identical with the old and new Bytes.
Timings weren't compared, since the instruction counts didn't move.

SocketStream (`SocketStream/.benchmarkBaselines`, `ss-old-1`, `ss-new-1`, `ss-old-2`, `ss-new-2`,
interleaved):
- **Unprotect, Brotli + TLS: 27 M → 26 M instructions (−3.7%), in both rounds.** This is the benchmark's
  receive buffer, now a `ByteBuffer`. It moves a partial packet to the front only when less than half is free,
  where the old code moved it after every piece.
- **The other in-memory rows are flat**, with no allocations either way.
- **Encode 64 B packets: +0.3% (4,735 K → 4,751 K), in both rounds.** The encode code is unchanged, but its
  specialization compiled to 291 instructions instead of 301, and its wrapper went from 1 to 16; not
  investigated further.
- **Socket transfers** are within their usual run-to-run variation.

A 4 KB receive buffer with TLS records (16 KB) traps, in the old code as in the new: a record must fit the
buffer.

Ergonomics, met while doing it:
- **`[1, 2, 3].span.bytes` is 24 bytes.** The literal is an `[Int]`. `copyBytes`' precondition caught it in
  the tests.
- **An async overload doesn't work here.** An `async` overload of `fill` taking a `throws(E)` closure made
  calls from async code ambiguous, even with a closure that doesn't suspend. Hence the separate name,
  `receive`.
- **A class's `ByteBuffer` property can't lend `unread` for long.** The access ends at once. The in-memory
  benchmark passes the buffer `inout` to a static function instead.

## 2026-11-15, second pass: Brotli decode and quality 1, a chunk scheduler for parallel compression (baselines `ab-old-1`, `ab-new-1`, `ab-old-2`, `ab-new-2`, `parallel-1`, `p2-optimized`, `p2-portable`, `p2-portable-no-c`)

All in `.benchmarkBaselines/CompressionBenchmarks/`, on an idle machine. `ab-*` is an interleaved A/B (old =
`git archive fd46f8f`, built in the scratchpad; old, new, old, new): the timing claims below come from it.
`p2-*` are the three builds after everything, Bytes rows only; their reference columns (Google, libdeflate)
come from `final-1`, an earlier run, so read those comparisons as ±10%. `parallel-1` is the parallel rows
with the old round-based scheduler.

### Brotli decode: −17 to −45% (A/B: −20 to −42%)

| Input | q5 `final-1` | q5 `p2` | q5 Google | q11 `final-1` | q11 `p2` | q11 Google |
|---|---|---|---|---|---|---|
| JSON 1.6 KB | 7.38 | **4.04** | 3.08 | 8.17 | **4.88** | 3.79 |
| JSON 119 KB | 112 | **79** | 72 | 125 | **89** | 75 |
| Main.css 376 KB | 425 | **280** | 261 | 387 | **296** | 268 |
| Main.js 3.8 MB | 4,727 | **3,439** | 3,742 | 4,841 | **3,826** | 3,666 |
| dickens 9.7 MB | 22,000 | **17,000** | 17,000 | 18,000 | **14,000** | 15,000 |
| x-ray 8.1 MB | 43,000 | **29,000** | 26,000 | 41,000 | **34,000** | 35,000 |
| xml 5.1 MB | 4,207 | **3,310** | 3,443 | 4,317 | **3,187** | 3,224 |

- In the A/B, every decode row is 20–42% faster (q5 Main.js 4,878 → 3,314 µs, q5 x-ray 42,000 → 28,000,
  the 1.6 KB streams the most). The decoder now runs with Google's on the large inputs (Main.js, dickens,
  x-ray, xml within 12%, either side) and is 7–33% behind on the short ones, where per-stream setup
  dominates; it was 17–67% behind.
- What did it (AGENTS.md, "hot decode loops keep their state in locals"): the bit buffer had been passed
  `inout` to a function that wasn't inlined, so it lived in memory for the whole loop, and its bit order was
  tested at run time; now it's copied into locals, passed by value, and stored back after. Masked indices
  (`types & 0xFF`, `context & 0x3F`) let span checks fold. Huffman tables are built from only the symbols
  in use, sorted, so setup costs scale with them (the 1.6 KB rows).
- The TLS + Brotli receive pipeline follows: −30 to −39% in the A/B (Main.js 6,840 → 4,981 µs from `final-1`
  to `p2`).

### Brotli quality 1: 6-byte hash, sparse insertion

| Input | `final-1` µs | `p2` µs | Google µs | Bytes size | Google size |
|---|---|---|---|---|---|
| JSON 1.6 KB | 11 | 11 | **5.92** | | |
| JSON 119 KB | 239 | 186 | **157** | | |
| Main.css 376 KB | 996 | 799 | **610** | **71.1 KB** | 74.0 KB |
| Main.js 3.8 MB | 13,000 | 11,000 | **9,101** | **842 KB** | 893 KB |
| dickens 9.7 MB | 54,000 | 52,000 | **43,000** | **3.82 MB** | 4.04 MB |
| x-ray 8.1 MB | 53,000 | **21,000** | 27,000 | **6.64 MB** | 6.69 MB |
| xml 5.1 MB | 14,000 | 9,437 | **7,447** | **730 KB** | 764 KB |

A/B: x-ray −62%, xml −32%, JSON 119 KB −24%, Main.css −21%, Main.js −15%, samba −14%, dickens −4.5%.
Quality 1 now beats Google's speed on x-ray and its size on the five files measured (1–6% smaller), and is 18–31%
slower on text (2x on 1.6 KB).

- **Insert only a copy's last positions.** Every position of every copy went into the table. Sweep (harness,
  best of 5×5, inserting the last N positions of each copy):

  | File | all: ms / size | N = 2 | N = 5 | N = 8 | N = 16 |
  |---|---|---|---|---|---|
  | dickens | 59.7 / 4,202,139 | 45.8 / 4,382,566 | 54.0 / 4,234,474 | 55.7 / 4,213,092 | 56.9 / 4,206,645 |
  | xml | 13.9 / 961,308 | 9.6 / 851,127 | 10.9 / 861,800 | 11.7 / 884,191 | 12.4 / 906,945 |
  | samba | 65.2 / 5,532,481 | 53.0 / 5,768,088 | 58.1 / 5,626,394 | 60.4 / 5,595,362 | 62.0 / 5,565,821 |
  | Main.js | 13.2 / 872,559 | 10.6 / 935,789 | 11.6 / 901,584 | 12.3 / 889,099 | 12.7 / 879,604 |

  N = 5 keeps sizes within 4% of inserting everything (xml gets smaller: fewer recent entries crowd out
  older, longer matches) for 10–22% less time. N = 2 is faster still but 4–7% bigger on dickens and Main.js.
- **A 6-byte hash and a 6-byte minimum match** (Google's `kHashMul64`, 2^17 one-entry buckets): a 4-byte
  hash with a 4-byte minimum: 55 → 21 ms on x-ray (an image) and smaller output on every file, presumably
  from fewer, longer matches (not measured per match). The longer
  load needs an 8-byte margin at the end of the data (4 for the bucket path).
- Tried and dropped: Snappy-style skipping (step grows with misses): x-ray 55.2 → 58.8 ms, others flat.
- The text gap is not analyzed yet. Google's quality 1 is a separate compressor
  (`compress_fragment_two_pass.c`), not its general parse at a lower setting, so the two loops differ in shape.

### Quality 5 and 9: `@inline(always)`, and a lazy-matching bug

- Splitting the match search into `findSingleMatch` and `findBucketMatch` (so each path's loop has only its
  own code) made q5 run 2–8% more instructions: the SIL inliner declined the bucket search
  (`Tools/remarks --passes sil-inliner`: "Not profitable to inline … cost = 785", at both call sites), and
  LLVM then found it too costly. `@inline(__always)` is a hint; `@inline(always)` (Swift 6.4) forced it,
  and q5 is back at the old code's numbers (harness, two runs each: x-ray 148.8 / 151.5 ms against 150.5 /
  150.9; xml slightly faster). Instructions against `final-1`: q5 −0.4% (dickens) to −2.0% (xml).
- **Its cost at quality 9: +3.8% (Main.js) and +5.0% (dickens) instructions** against `final-1`; the time
  in the harness, alternating, is within 0–2.5%. `@inline(always)` puts a second whole copy of the bucket
  search in the lazy step. Two fixes tried (harness, instructions, identical output):

  | Variant | q3 | q5 | q7 | q9 | q11 |
  |---|---|---|---|---|---|
  | lazy step's search out of line (`@inline(never)` wrapper) | +7.7% | +1.0 to +2.6% | −0.1% | −2.9 to −4.4% | −2.9% |
  | a third loop copy, out of line only for buckets of 64+ (q8 and up) | +3.7% | +5.4 to +5.6% | +6.0% | −1.3 to −2.7% | −1.3% |

  The third copy changed the existing bucket loop's code, not its source (outer loop 1,302 → 1,381
  instructions, 87 → 77 loops in `Tools/loops`). Neither is better at both qualities, and q5 is the one
  used: both reverted.
- **Bug: a lazy step's copy could run past the data.** The lazy loop computed `maxLength` once, at the first
  position, as `dataEnd - position`, and each delay searched with `maxLength - 1`. A second delay was then
  allowed one byte too many. Sequentially that compared a byte past the input with an unchecked load (an
  out-of-bounds read; no test faulted or matched on it); in a parallel chunk, the next chunk's bytes are there, they matched,
  and the stream decoded one byte long (found on samba at q5 and up). Each lazy search now takes
  `min(dataEnd - position - 1, maximumCopy)` for its own position. Random and text inputs never hit it
  (skipping stepped over the position); `copiesStopAtChunkEnds` builds an input that forces two delays
  ending at a chunk's last bytes, and fails without the fix.

### Parallel compression: a chunk scheduler instead of rounds

`ParallelDeflate` and `ParallelBrotli` cut the input into chunks (256 KB; DEFLATE chunks carry 32 KB of
history for matches, Brotli's none) and compress them on lanes, each lane a `~Copyable` encoder with its own
staging buffer. They had run in rounds: one chunk per lane, a barrier, the round's output copied in order,
repeat. Measured with a thread experiment (`cpexp` in the scratchpad), each round's last thread started
124–722 µs after the first: waking 24 threads and their cores ramping clock again, every round, plus the
serial copy between rounds.

`ChunkScheduler` (`ParallelScheduler.swift`) does one `concurrentPerform` (or one discarding task group)
per call. Workers take the next chunk index with an atomic fetch-add, compress it, and hand the output to a
slot by swapping their staging `UniqueArray` with the slot's (no copy). Whoever finishes the next chunk in
order copies it to the output (under a `Mutex`: delivered count, running checksum combined with
`Adler32/CRC32.combine`, failure); a worker more than a slot ring ahead waits, delivering what's ready.
Slots: lanes + max(2, lanes / 2). The output doesn't depend on which worker took which chunk.

Rounds against the scheduler, interleaved in one process (harness, gzip, 24 lanes, sync, same output bytes,
best of 5 × 20; the round-based schedule rebuilt as a temporary method for the comparison, since removed):

| Input (chunks on 24 lanes) | L1 rounds | L1 scheduler | L6 rounds | L6 scheduler |
|---|---|---|---|---|
| samba 20.6 MB (96, 4 rounds) | 5,198 | **3,090** (−41%) | 9,202 | **7,197** (−22%) |
| dickens 9.7 MB (48, 2 rounds) | 2,859 | **2,229** (−22%) | 6,458 | **5,929** (−8%) |
| xml 5.1 MB (24, 1 round) | 972 | 941 | 2,255 | 2,288 |
| Main.js 3.8 MB (24, 1 round) | 690–741 | 683–730 | 1,540–1,858 | 1,507–1,885 |

(Chunks are a whole number per lane, at most 256 KB: Main.js gets 24 of 164 KB.) The gain is the rounds
saved: none with one round (Main.js, three repeats each: ratios 0.94–1.02), 8–22% with two, 22–41% with
four. In the benchmarks (`parallel-1` → `p2-optimized`, then two re-runs `p2-par-1`, `p2-par-2`, µs):

| Row, 24 lanes | rounds | scheduler (three runs) | sequential |
|---|---|---|---|
| deflate 1 samba, sync | 5,124 | 3,090–3,203 | 55,000 |
| deflate 1 samba, task group | 4,780 | 3,074–3,111 | |
| deflate 6 samba, sync | 9,110 | 7,279–7,385 | 135,000 |
| deflate 6 dickens, sync | 7,479 | 6,300–6,324 | 124,000 |
| deflate 1 dickens, sync | 2,685 | 2,451–2,697 | 39,000 |
| deflate 1 Main.js, sync | 677 | 804–820 | 9,257 |
| deflate 1 Main.js, task group | 753 | 599–726 | |

- Samba and dickens agree with the harness. Main.js sync reads 19–21% slower in all three benchmark runs but
  not interleaved in the harness, so it is a difference between benchmark runs (`parallel-1` was a separate
  build and process), not the schedule: these rows swing 10–30% between runs (dickens L6 task group:
  5,861 and 8,069 µs in the two re-runs). At 8 lanes, where every input takes several rounds, samba and xml
  were 13–18% faster in `p2`.
- Speed-up over one core at 24 lanes: DEFLATE 14–19x (level 6 samba 135 → 7.2 ms), Brotli q1 15x (dickens
  52 → 3.6 ms), q5 15–17x (dickens 170 → 10 ms, 1.10% bigger than one stream). Parallel inflate (of a stream
  made of independent chunks) 5–10x.
- A task group was up to 10% faster than `concurrentPerform` in the harness (dickens L1 2.01 against 2.19
  ms), 0–7% in the benchmarks, with more spread. All three forms are offered: sync (the caller's thread
  plus Dispatch's pool), `async` on a Dispatch queue, and `async` on the cooperative pool.
- Chunks stay a whole number per lane: equal chunks, 39 on 24 lanes, take as long as 48.
- Allocation: the sequential paths allocate nothing. The parallel ones allocate the thread pool's
  bookkeeping, now once per call instead of once per round: `concurrentPerform` 11 (8 lanes) and 27 (24
  lanes) mallocs per call, one more through a Dispatch queue, a task group 34 and 98 (about 4 per task).
- Bug found on the way: slots keep their chunk index across calls, so a slot still naming chunk 0 from the
  previous call looked ready (corrupt output, or `insufficientCapacity`); `start()` resets them.
  `laneAndChunkEdges` caught it.

### The three builds (`p2-optimized`, `p2-portable`, `p2-portable-no-c`, µs)

| Row | optimized | portable | portable-no-c |
|---|---|---|---|
| Brotli decode q11 Main.js | 3,826 | 3,686 | 3,787 |
| Brotli decode q5 x-ray | 29,000 | 28,000 | 27,000 |
| Brotli encode q1 x-ray | 21,000 | 21,000 | 21,000 |
| Brotli encode q5 dickens | 170,000 | 168,000 | 174,000 |
| Deflate 6 dickens | 124,000 | 120,000 | 120,000 |
| Inflate Main.js | 1,911 | 1,927 | 1,879 |
| TLS + Brotli receive Main.js | 4,981 | 4,801 | 4,788 |

The Brotli changes are pure Swift and land the same in every build (decode −17 to −42%, q1 x-ray −65%
against `c3-*`). The builds stay within run-to-run noise of each other, apart from gzip inflate's CRC-32
(above, unchanged).

### DEFLATE: unchanged, and where its gap is

DEFLATE encode and inflate run instruction for instruction what they did (`ab-old-1` and
`ab-new-1`: Main.js L1 135 M, dickens L6 1,311 M both). Level 1 is 5.5–12% behind libdeflate with
identical output; level 6, 11–18%. Reading the level 1 loop: about 45 instructions per literal byte, with
separate checks for the data's end, the position rebase, and the sequence buffer's count, and the maximum
length's `min` computed twice. That's the next thing to fold, not done in this pass.

## 2026-11-15: BytesCompression, BytesCrypto, and pipelines (baselines `dec-1`, `enc-1`, `all-1`, `c3-optimized`, `c3-portable`, `c3-portable-no-c`, `pipe-1`, `pipe-2`, `final-1`)

All baselines are in `.benchmarkBaselines/CompressionBenchmarks/`. M3 Ultra, macOS 27, Swift 6.4. Corpus:
`Tools/corpus fetch` (Silesia's dickens, xml, x-ray, samba; WebKit Web Inspector's Main.js 3.8 MB and Main.css
376 KB) plus generated JSON (16 and 1,200 records: 1.6 KB, 119 KB). References: system zlib, Apple
Compression (zlib and Brotli), Homebrew libdeflate 1.26 and brotli 1.2.1. Times are medians in µs from
`Tools/bench-table` (values of 10 ms and up carry two significant digits in the baselines); comparisons are
within one run (`final-1`) unless a table says otherwise. What each baseline holds: `all-1` is the first
full optimized run (before the Brotli decoder's fast path and the encoder's tags); `c3-*` the three builds
after both; `pipe-1` the crypto, pipeline, and Brotli encode rows before the q1 parse split, `pipe-2` the
Brotli encode rows after it; `final-1` everything below.

Every Bytes row in `final-1` (compression, decompression, checksums, crypto, pipelines) allocates 0 times in
steady state. The comparators allocate: Google's Brotli 5–428 times per call, Apple Compression 8–20,
CryptoKit 2 per seal (below).

### DEFLATE encode (`final-1`, µs)

| Input | L1 Bytes | L1 libdeflate | L1 zlib | L1 Apple | L6 Bytes | L6 libdeflate | L6 zlib | L9 Bytes | L9 libdeflate | L9 zlib |
|---|---|---|---|---|---|---|---|---|---|---|
| JSON 1.6 KB | 8.96 | **6.71** | 6.58 | 9.30 | 11 | **9.63** | 10 | | | |
| JSON 119 KB | 150 | **119** | 153 | 575 | 514 | **470** | 700 | | | |
| Main.js 3.8 MB | 9,011 | **8,045** | 17,000 | 38,000 | 24,000 | **22,000** | 55,000 | **56,000** | 59,000 | 82,000 |
| dickens 9.7 MB | 38,000 | **35,000** | 70,000 | 218,000 | 119,000 | **105,000** | 315,000 | 228,000 | **221,000** | 412,000 |
| x-ray 8.1 MB | 50,000 | **47,000** | 90,000 | 189,000 | 76,000 | **64,000** | 202,000 | | | |
| xml 5.1 MB | 9,462 | **8,421** | 17,000 | 37,000 | 23,000 | **21,000** | 51,000 | | | |

(Apple Compression has one level; it is listed in the L1 column.)

- Level 1: Bytes is 6–14% slower than libdeflate on files of 376 KB and up (x-ray +6%, dickens +9%, Main.js
  +12%, xml +12%, Main.css +14%), 26–34% slower on the JSON inputs (fixed costs matter at 1.6 KB: 8.96
  against 6.71 µs). It is about 2x faster than zlib on the large files and 4–6x faster than Apple
  Compression. On JSON 1.6 KB zlib is as fast as libdeflate.
- Level 6: 9–19% slower than libdeflate (x-ray +19%, dickens +13%, Main.js +9%, xml +10%), 2.3–2.7x faster
  than zlib on Main.js, dickens and x-ray.
- Level 9: equal to libdeflate (Main.js 56 against 59 ms, dickens 228 against 221 ms), 1.5–1.8x faster than
  zlib.
- Instructions (L1, millions): Main.js 135 against libdeflate's 96, dickens 519 against 372. The gap in
  time is smaller than the gap in instructions.
- Streaming through a 64 KB window costs 0–2% (Main.js L1 9,093 against 9,011).
- Output sizes (FINDINGS' ratio report): L1's output is the same size as libdeflate's L1.
- `all-1` to `final-1` is flat for DEFLATE encode (Main.js L1 9,216 → 9,011, dickens L6 119,000 →
  119,000), apart from the rebase fix below, which changes output size, not speed.

### DEFLATE decode and the wrappers (`final-1`, µs)

| Input | Bytes | libdeflate | zlib | Apple | gzip: Bytes | gzip: libdeflate | gzip: zlib |
|---|---|---|---|---|---|---|---|
| JSON 1.6 KB | **2.54** | 2.63 | 2.46 | 3.58 | 2.54 | 2.71 | 2.42 |
| JSON 119 KB | 28 | 28 | 27 | 58 | 29 | 29 | 30 |
| Main.js 3.8 MB | 1,894 | **1,673** | 2,092 | 3,592 | 1,943 | 1,752 | 2,118 |
| dickens 9.7 MB | 8,806 | 8,479 | **8,430** | 17,000 | 9,191 | 8,618 | 8,610 |
| x-ray 8.1 MB | 15,000 | 14,000 | 14,000 | 23,000 | 15,000 | 14,000 | 14,000 |
| xml 5.1 MB | 1,696 | **1,518** | 1,724 | 3,013 | 1,760 | 1,616 | 1,860 |

- Bytes is 0–13% slower than libdeflate (Main.js +13%, xml +12%, dickens +4%), about equal to zlib, and
  1.4–2x faster than Apple Compression. Instructions on Main.js: Bytes 28 M, zlib 23 M, libdeflate 19 M.
- The gzip wrapper (header, CRC-32 trailer) adds 2–5% over raw inflate (Main.js 1,894 → 1,943,
  xml 1,696 → 1,760; libdeflate's gzip adds 5% on Main.js).
- Adler-32 (zlib's trailer): 1 MB in 28 µs (libdeflate 15, zlib 56); 64 B × 16 K in 114 µs (zlib 154). The
  baselines have no CRC-32 rows of their own; its cost shows in the gzip rows above.

### Brotli (`final-1`, µs; Google is brotli 1.2.1)

Decode, Bytes against Google and Apple Compression:

| Input | q5 Bytes | q5 Google | q5 Apple | q11 Bytes | q11 Google | q11 Apple |
|---|---|---|---|---|---|---|
| JSON 1.6 KB | 7.38 | 3.08 | **2.79** | 8.17 | 3.79 | **3.59** |
| JSON 119 KB | 112 | 72 | **57** | 125 | 75 | **70** |
| Main.css 376 KB | 425 | 261 | **222** | 387 | 268 | **258** |
| Main.js 3.8 MB | 4,727 | 3,742 | **3,316** | 4,841 | 3,666 | **3,545** |
| dickens 9.7 MB | 22,000 | 17,000 | **14,000** | 18,000 | 15,000 | **12,000** |
| x-ray 8.1 MB | 43,000 | 26,000 | **22,000** | 41,000 | 35,000 | **35,000** |
| xml 5.1 MB | 4,207 | 3,443 | **3,187** | 4,317 | 3,224 | **3,082** |

- Bytes' decoder is 17–67% slower than Google's on inputs of 119 KB and larger (q5 x-ray +65%, q5 Main.css
  +63%, q11 JSON 119 KB +67%, q11 x-ray +17%, q5 dickens +29%) and slower still than Apple's. Short inputs cost 2x (q5 1.6 KB: 7.4 against 3.1 µs).
- Against `all-1`, the decoder's fast path made `c3-optimized` and `final-1` 8–26% faster (Main.js q11
  6,525 → 4,542 µs in `c3-optimized`, 4,841 in `final-1`; dickens q11 22,000 → 18,000; xml q5 5,067 →
  4,012 and 4,207); x-ray q5 did not move (43,000 → 42,000 and 43,000). The 64 KB streaming rows track the
  one-shot rows within 1–10%.

Encode, Bytes against Google:

| Input | q1 Bytes | q1 Google | q5 Bytes | q5 Google | q9 Bytes | q9 Google |
|---|---|---|---|---|---|---|
| JSON 1.6 KB | 11 | **5.92** | **16** | 18 | | |
| JSON 119 KB | 239 | **157** | 738 | 736 | | |
| Main.css 376 KB | 996 | **610** | **2,669** | 2,716 | | |
| Main.js 3.8 MB | 13,000 | **9,101** | 34,000 | 33,000 | **59,000** | 94,000 |
| dickens 9.7 MB | 54,000 | **43,000** | 168,000 | 156,000 | **318,000** | 522,000 |
| x-ray 8.1 MB | 53,000 | **27,000** | 146,000 | 121,000 | | |
| xml 5.1 MB | 14,000 | **7,447** | 32,000 | 29,000 | | |

- q5 is within 0–20% of Google in time (x-ray +21%, dickens +8%, xml +10%, Main.js +3%); q9 is 1.6x faster
  than Google's (Main.js 59 against 94 ms, dickens 318 against 522 ms); q1 is 1.3–2x slower than Google's.
- Sizes (FINDINGS' ratio report): q5 output is within 3–6% of Google's q5; q1 is larger (xml +26%); q9 is
  larger by 7% (Bytes has no context modeling or block splitting).

### The Brotli encoder's adaptive tag filter

The hash-bucket search can store a 1-byte tag per entry (Google's SIMD hasher idea) and compare 16 tags
at once before touching candidates. Always on, it loses on text. Chosen per meta-block now. A/B in one
harness, alternating runs, identical output bytes (ms, q5, 2 iterations each; this table is from the
harness, not a baseline):

| File | scan only | tags always | adaptive |
|---|---|---|---|
| dickens | 166 | 191 | **167** |
| Main.js | **33.0** | 38.0 | 33.3 |
| x-ray | 222 | 147 | **146** |
| sao | 174 | 128 | **130** |
| mozilla | 662 | **608** | 620 |
| ooffice | 118 | **103** | 105 |
| osdb | 136 | 117 | **115** |
| samba | **180** | 196 | 185 |

At q9: dickens 344 / 436 / 316 ms, Main.js 61 / 71 / 60, x-ray 409 / 230 / 240, osdb 300 / 243 / 236
(scan only / tags always / adaptive).

- The signal: per search, the filled bucket entries (16 per bucket at q5) the tags rule out. Text 3–6
  (dickens 3.8, Main.js 4.0, xml 2.9, samba 6.1); binaries and tables 10–14 (mozilla 10.3, osdb 11.2,
  ooffice 11.7, sao 13.0, x-ray 14.2). Tags win when they rule out more than half the bucket. The encoder
  measures every search with tags and every 32nd without, and decides per meta-block. The copied fraction
  and the average match length did not separate the files (x-ray copies 60–78%; osdb's average match is 13
  bytes and tags still win).
- Why tags lose on text: most candidates pass, so the tag compare is an extra load (a separate cache line) and
  a data-dependent branchy loop in front of the loads the scan would have issued in parallel anyway.
  Storing tags costs about 5% alone.
- Instructions (millions, comparable across runs), `all-1` / `pipe-1` / `pipe-2` / `final-1`:

| Brotli encode | all-1 | pipe-1 | pipe-2 | final-1 |
|---|---|---|---|---|
| q1 dickens | 858 | 921 | 835 | 835 |
| q1 x-ray | 877 | 900 | 833 | 833 |
| q1 Main.js | 194 | 212 | 191 | 191 |
| q5 dickens | 2,487 | 2,448 | 2,414 | 2,485 |
| q5 x-ray | 3,575 | 2,430 | 2,419 | 2,495 |
| q5 Main.js | 528 | 548 | 533 | 549 |
| q5 xml | 466 | 505 | 484 | 501 |
| q9 dickens | 4,913 | 4,424 | 4,333 | 4,441 |
| q9 Main.js | 964 | 949 | 922 | 939 |

- q1 split (`parseSingle` / `parseBuckets`: `@inline(never)` wrappers over an `@inline(__always)` body with a
  constant): q1 is 7–10% below `pipe-1` and 1–5% below `all-1`.
- x-ray q5: −30% instructions against `all-1` (the tags). Text at q5 sits within ±2% of `all-1` (dickens
  −0.1%, samba +1.5%) and Main.js, Main.css, xml, JSON +4–12%, the price of measuring both ways.
- Stale buckets: a reused encoder keeps earlier streams' entries (out of every window, by `streamBase`),
  and a short stream checked all 16 per search. Checking the newest entry first (if it is out, all are):
  1.6 KB input 24 → 18 µs (−24%, harness), large inputs unchanged. Breaking out of the scan loop at the
  first stale entry cost large inputs 3–5% (a second loop exit).

### The three builds (`c3-optimized`, `c3-portable`, `c3-portable-no-c`, µs)

| Row | optimized | portable | portable-no-c |
|---|---|---|---|
| Deflate 6 dickens | 118,000 | 118,000 | 118,000 |
| Deflate 6 x-ray | 78,000 | 75,000 | 78,000 |
| Inflate Main.js | 1,874 | 1,901 | 1,910 |
| Inflate xml | 1,713 | 1,669 | 1,676 |
| Brotli decode q11 Main.js | 4,542 | 4,751 | 4,948 |
| Brotli encode q5 dickens | 191,000 | 190,000 | 192,000 |
| Adler-32 1 MB | 27 | 27 | 28 |
| **Inflate gzip JSON 119 KB** | **29** | 41 | 41 |
| **Inflate gzip Main.js** | **1,916** | 2,310 | 2,296 |
| **Inflate gzip xml** | **1,797** | 2,308 | 2,259 |
| **Inflate gzip dickens** | **9,044** | 10,000 | 10,000 |

Everything else is within a few percent across the three builds. The exception is gzip inflate, whose
CRC-32 uses the hardware CRC instructions in the optimized build (through `CBytes`): the portable builds are
7–41% slower there (x-ray +7%, dickens +11%, Main.js +20%, xml +26%, JSON 119 KB +41%). Raw inflate has no
checksum and shows no such gap.

### ChaCha20-Poly1305 against CryptoKit (µs per iteration; `pipe-1` → `final-1`)

| Seal | Bytes pipe-1 | Bytes final-1 | CryptoKit ChaChaPoly | CryptoKit AES-128-GCM |
|---|---|---|---|---|
| 1 MB × 1 | 1,047 | **690** (1.52 GB/s) | 1,239 | 103 |
| 16 KB × 64 | 1,051 | **714** | 1,315 | 151 |
| 1 KB × 1024 | 1,170 | **805** | 2,222 | 891 |
| 64 B × 16,384 | 4,575 | **4,461** | 16,000 | 12,000 |

- Two changes took 1 MB from 1.00 to 1.50 GB/s (harness): ChaCha20 eight blocks at a time (`SIMD8<UInt32>`,
  all 32 NEON registers: four blocks are four dependent quarter-round chains and leave half the vector pipes
  idle) 1.00 → 1.34, then Poly1305 in radix 2^64 (OpenSSL's scheme: 4 wide and 2 narrow products per block
  instead of 9 wide; the loop went from 56 to 43 instructions per 16 bytes) 1.34 → 1.50. Before them,
  ChaCha was about 65% of the time and Poly1305 about 33%. Instructions in `final-1`: 1 MB 8.77 M, 16 KB × 64
  8.91 M, 1 KB × 1024 11 M.
- Bytes beats CryptoKit's ChaChaPoly at every size: 1.8x at 1 MB and 16 KB, 2.8x at 1 KB, 3.6x at 64 B, where CryptoKit's
  per-call allocation and setup dominate. CryptoKit allocates twice per seal: 2 for 1 MB × 1, 128 for 16 KB ×
  64, 2,048 for 1 KB × 1024, 33,000 for 64 B × 16,384.
- AES-128-GCM with hardware AES is 6.7x faster than Bytes' ChaCha at 1 MB (10 GB/s): ChaCha cannot match
  it. At 1 KB and below AES-GCM is slower than Bytes' ChaCha (891 against 805 µs; 12,000 against 4,461).
- Not done: stitching, interleaving Poly1305's scalar multiplies with ChaCha's vector rounds.

### Pipelines against two passes (`final-1`, µs)

| Work | Pipeline | Two passes |
|---|---|---|
| deflate 1 + TLS send, JSON 1.6 KB | 9.58 | 9.34 |
| deflate 1 + TLS send, JSON 119 KB | 187 | 184 |
| deflate 1 + TLS send, Main.js | 11,000 | 11,000 |
| TLS + inflate receive, JSON 1.6 KB | 3.38 | 3.34 |
| TLS + inflate receive, JSON 119 KB | 60 | 61 |
| TLS + inflate receive, Main.js | 3,297 | 3,297 |

Other pipeline rows: brotli 5 + TLS send 16 µs (1.6 KB), 840 (119 KB), 37,000 (Main.js); TLS + brotli receive
6.96, 149, 6,840.

- A pipeline equals the same work as two passes through a buffer: it is not a speed-up, and costs nothing.
  It saves the intermediate buffer and, with `ResettableByteTransform`, lets pipelines built once serve
  stream after stream.
- The TLS sealer's `reset` does not restart the record sequence (the same keys and sequence would reuse a
  nonce); the opener's `reset(sequence:)` replays it.

### Bugs found, and compiler issues

- **DEFLATE encoder rebase (found by SocketStream):** 16-bit positions are relative to a base, and the
  encoder rebased when `position - base == 32768`. Positions that are not inserted (a flush's last 4 bytes,
  the end of a match too near the end) can step over 32768; then the check never matches again, entries wrap
  in `Int16`, and no match is found for the rest of the stream. The output stays correct (matches are
  verified) and only grows: the socket stream went from 14% to 62% of the input size after batch 100
  (26 MB). Fixed with `while current >= windowSize { rebase; base += 32K; current -= 32K }` at all four
  sites. Test `flushAcrossTheRebasePointKeepsMatching` (first flush at 32,770): before, 2.1–2.6x bigger than
  one-shot; after, within 10%. Speed rows did not change.
- **Benchmark evaluation order (not the library):** `Array(wire.prefix(send(into: &wire)))` reads `wire`
  before the argument mutates it, so `prefix` saw the old, empty array (the copy-on-write made by the
  `inout` access).
- **Swift 6.4 issues met:** (1) SILGen crash on a typed-throws closure returning a tuple passed to
  `Array.withUnsafeMutableBytes` ("unsupported collection upcast kind"; with other result types the same
  code compiles and throws the wrong error: report 25 in `~/Downloads/swift-bugs`); (2) a `~Copyable` struct `init`
  that reads a `let` before `UniqueArray` fields are initialized: `-O` emits deallocs of uninitialized fields
  (release-only crash; not reduced); (3) `SIMD16<UInt16>(truncatingIfNeeded:)` is not inlined; (4) indexing
  an `InlineArray` field of a struct value copies the whole array per access (take `.span` once: DEFLATE L1
  x-ray 153 → 55 ms); (5) loops of `Int16` stores and `MutableSpan.update(repeating:)` compile scalar
  (explicit `SIMD8` stores); (6) variadic `min(a, b, c, …)` allocates an array per call; (7) default
  cross-module optimization inlined `BrotliEncoder`'s deinit into clients and referenced an internal type's
  metadata (link error; `@usableFromInline` on the type).

## Current: Bytes against the alternatives (same harness, same run; baseline `modern`)

The times below were first taken on a loaded machine (see the 2026-11-09 section). Re-run alone, `modern`
against `safe-final`: instruction counts identical (268 rows, none beyond −0.8%), wall times a median
change of 0.0% (single rows ±18%, run-to-run noise), allocation thresholds pass.

| Workload | Bytes | Comparator | |
|---|---|---|---|
| Zip central directory, 2,000 entries (~170 KB) | **11 µs**, 301 K instr | original `ByteReader`: 17 µs, 259 K instr | 1.5x faster |
| | fixed-size-record style: **7.8 µs**, 199 K instr | hand-written `RawSpan.load` offsets: 16 µs, 317 K instr | 2x faster |
| Bit fields, 8 fields of 1–32 bits per record, 128 KB | **40 µs**, 706 K instr | 64-bit refill-buffer reader: 332 µs, 8,180 K instr | 8x faster |
| Find a 4-byte signature 64 KB back (zip EOCD worst case) | **2.0 µs**, 50 K instr | `RawSpan.load` per offset: 33 µs, 787 K instr | 16x faster |
| 256 K big-endian `UInt32`s | 21 µs, 200 K instr | `RawSpan.load` per value: 21 µs, 201 K instr | equal (all vectorize) |
| 349 K big-endian 24-bit values (`Byte3`), `read(_:_:into:)` | 22 µs, 267 K instr | — | NEON `tbl` unpacking |

Field-by-field parsing uses more instructions than at v3 (301 against 263 K) because one `assume` was
dropped so that loops of reads vectorize (see "Making loops of single reads vectorize"), and the checked
`extracting` added 3% (see "Safe constructs"); wall time is unchanged.

No benchmark allocates, apart from the output array in the bulk ones and one `for`-`in` shape (below).

## 2026-11-12: the optimized build adopts the portable iterator path; all four builds (baselines `cmp-old-*`, `cmp-optimized-*`, `cmp-portable-*`, `cmp-portable-no-c-*`)

Each of `GroupShuffle`'s paths was tried in the optimized build against the NEON `Shuffle`, in alternating
runs of a copy of the code with each (three rounds, against the working code just before the change; the
four-build table below compares with the last commit, so its percentages differ a little):

| Path | With `GroupShuffle` instead of NEON | Verdict |
|---|---|---|
| Iterators (`for`-`in` over `values(of:)`; `_forEach(…, staged: false)`), `Byte5`–`Byte7` | −22 to −32% time, both in cache and from memory (+21–25% instructions) | **Adopted** |
| … `Byte3` (NEON had used the plain `ld3` loop) | −43 to −44% time, −18% instructions | **Adopted** |
| `forEach` with a body (staged), `Byte5`–`Byte7` | +0 to +12% time, +60–100% instructions | NEON kept |
| Bulk reads `read(_:_:into:)` | level (previous section) | NEON kept |
| Generating writes | 1.25–2x slower (previous section) | NEON kept |

An iterator's body only stores each value into its buffer, so there's nothing for the vector to be
pulled apart for: a vector of two values (four for 3 bytes) per load, one single-register `tbl`, against a
64-byte step of four-register `tbl`s (4 micro-ops each). `GroupShuffle.isPreferredForIteration(staged:)`
makes the choice; `staged` is a constant at each call site, so it folds.

Then all four builds, two alternating rounds of the full suite (old code from the last commit, the
optimized build, `portable`, `portable-no-c`); times in µs, the mean of the rounds:

| Workload | Old | Optimized | Portable | Portable, no C |
|---|---|---|---|---|
| `for`-`in` `Byte3`, 4 MB (portable builds before: 284, 290) | 294 | **160** | 163 | 158 |
| `for`-`in` `Byte5` / `Byte6` / `Byte7` | 258 / 213 / 185 | **186 / 157 / 136** | 186 / 155 / 135 | 186 / 157 / 135 |
| Bulk read `Byte3` / `Byte5` / `Byte7` | 83 / 99 / 81 | 88 / 99 / 81 | 89 / 92 / 82 | 88 / 100 / 81 |
| `forEach` summing `Byte5` / `Byte6` / `Byte7` | 192 / 159 / 137 | 196 / 161 / 137 | 193 / 162 / 135 | 190 / 161 / 136 |
| Generating write `Byte3` / `Byte6` | 96 / 147 | 97 / 146 | 189 / 200 | 189 / 198 |
| CRC-32, 256 KB (`checksum`) | 471 | 470 | 3,874 | 3,900 |
| CRC-32 tables, 256 KB / 64 B | 14,000 / 9,564 | **3,864 / 8,272** | 3,879 / 8,333 | 3,856 / 8,393 |

Over all 337 rows (geometric mean of time): optimized against old **0.988**; portable against optimized
1.020, portable-no-c 1.023; within 10% of the optimized build: 321 and 319 rows. The rest are the
odd-width generating writes (1.25–2x), CRC-32 against `pmull` (8.2–8.3x), the MAC reference `forEach`
(1.12–1.14x), and 32-core memory rows within the machine's two timing levels.

The optimized build's instruction counts match the old code's except the CRC tables (−41% at 256 KB,
−31.5% at 64 B), `for`-`in` over `Byte3` (−18%), and `for`-`in` over `Byte5`–`Byte7` (+21–25%, and 26–28%
faster in the table above). Rows slower in both rounds were rerun three more times, alternating: most were
noise, but "Runs: 3-/4-byte elements, per-element writes" (+11–15%) and the 3–32-byte back-references at
distance 2 and 4 (+1–2 µs) stayed slower with identical instruction counts. The per-element writes'
function is the same 132 instructions of machine code in both benchmark binaries, but starts 196 bytes
earlier in the new one (the inlined code laid out before it changed size), so its loops sit at different
offsets within 64-byte blocks: a layout effect in the benchmark executable, not a change in the code Bytes
generates. Tests (129, 128 in the portable builds), warnings (none), and the zero-allocation thresholds
pass in all three builds.

## 2026-11-12: fast portable builds (baselines `final-old-*`, `final-optimized-*`, `final-portable-*`, `final-portable-no-c-*`)

The `portable` and `portable-no-c` builds (previous section) made as fast as possible without CPU-specific
code: no NEON, no `asm`, nothing that checks the architecture. Two changes cover nearly all of the gap.

**Odd-width groups (3, 5, 6, 7 bytes): `GroupShuffle`**, portable Swift, used wherever `tbl` isn't a
single instruction (the NEON `Shuffle` stays for the optimized build). A 16-byte vector holds whole
values in lanes (four 32-bit lanes for 3 bytes, two 64-bit lanes for 5–7); unpacking loads the 12, 10, 12,
or 14 bytes they take and builds the lanes with `SIMD16(v[k], …)` picks at constant `k`, which LLVM turns
into one shuffle: a single-register `tbl` on ARM64 (1 micro-op against the NEON path's 4-register `tbl`'s
4), `pshufb` on x86-64 macOS. Reads are 1 load, 1 shuffle, 1 store per 16 lane bytes. Two traps (LLVM
seeing too much) and a threshold:

- Writes that built each vector from the caller's computed values and then shuffled got merged into one
  byte insert per byte (40 per `Byte3` vector), slower than the plain loop. Values now go through a
  512-byte stack buffer (`withUnsafeTemporaryAllocation`, no allocation): a plain loop computes them (it
  vectorizes the caller's closure), then lanes are loaded back, shuffled, and stored 16 bytes at a time
  (each store overwrites the previous one's spare bytes, and the last stays within the run).
- `forEach` that handed the caller's body each value from the vector kept the body scalar: 2x slower than
  the plain loop when summing. It now unpacks a chunk into the same kind of buffer and runs the body over
  it, so the body vectorizes. Iterators (`for`-`in`), whose body only stores values into their own buffer,
  keep the direct form (`_forEach(…, staged: false)`).
- Staging only pays for a full buffer (128 values of 3 bytes, 64 of 5–7): runs of 1–62 `Byte3`s took 37%
  more instructions staged, and stay on the plain loops, which have code of their own (sharing it with a
  run-time start cost 20 instructions per call).

**CRC-32 tables: braided (zlib's method).** Slicing-by-8 is a latency chain: each word's 8 lookups wait for
the previous word's. Five CRCs now run over interleaved 8-byte words, each jumping 40 bytes per step with
tables that advance over the others' words, combined in the last block (126 instructions per 40 bytes,
45 of them loads). The lookups had a bounds check each; 256-entry spans lost them in one loop and not the
other, and stating the counts made the braided loop spill and check again (126 to 293 instructions), so
the tables are pointers into the borrowed array, with that reasoning in `CRC32._Tables`. This is also the
`CRC-32 tables` benchmark of the optimized build.

Times in µs, two interleaved rounds (old code, new optimized, portable, portable-no-c, twice):

| Workload | Optimized | Portable, before → now | No C, before → now |
|---|---|---|---|
| Bulk read `read(_:_:into:)`, `Byte3`, 4 MB | 87 | 8,485 → **88** | 222 → **88** |
| … `Byte5` / `Byte6` / `Byte7` | 98 / 84 / 82 | 10,500 / 8,371 / 7,291 → **99 / 88 / 81** | 202 / 165 / 139 → **99 / 88 / 81** |
| Bulk BE24 | 22.5 | 2,090 → **22** | 54.5 → **23** |
| `forEach(Byte6.self, .bigEndian)`, 4 MB | 154 | 7,570 → **160** | 169 → **162** |
| `forEach` summing `Byte5` / `Byte6` / `Byte7`, 4 MB | 193 / 161 / 137 | 9,535 / 7,742 / 6,931 → **200 / 165 / 139** | 202 / 171 / 146 → **194 / 162 / 139** |
| `for`-`in` `Byte5` / `Byte6` / `Byte7`, 4 MB | 255 / 205 / 185 | 9,536 / 7,809 / 6,718 → **188 / 155 / 137** | 282 / 235 / 203 → **186 / 157 / 135** |
| Generating write, `Byte3`, 4 MB | 97 | 6,699 → **189** | 204 → **189** |
| … `Byte5` / `Byte6` / `Byte7` | 177 / 148 / 136 | 7,072 / 5,982 / 7,209 → **247 / 208 / 174** | 272 / 227 / 197 → **252 / 208 / 170** |
| CRC-32, 256 KB | 466 (`pmull`) | 14,000 → **3,849** | 14,000 → **3,888** |
| CRC-32 tables, 64 B (×524 K) | 8,342 | 9,417 → **8,315** | 9,532 → **8,254** |

Over all 337 rows (geometric mean of the time against the new optimized build): portable 1.59 → **1.009**,
portable-no-c 1.055 → **1.016**; within 10% of optimized: 292 → **323** and 307 → **322** rows. The rest:
odd-width generating writes (1.25–2x: the stage through memory, and the vectorized loop building values
from 64-bit indices, against the NEON path's lanes), CRC-32 against `pmull` (8.3x, from 30x), and a few
32-core rows within the machine's bimodal memory timing (below). `for`-`in` over 5–7 bytes is now faster
than the optimized build's, and summing `forEach` matches it. (The section above then adopted the portable
path for the optimized build's iterators; staged `forEach` stayed on NEON.)

Not regressed: the optimized build's instruction counts match the old code's in every row but the CRC
tables (−41% at 256 KB, −31% at 64 B); its times average 1.005x the old code's. Five rows were slower in
both rounds; the large ones were 32-core and single-core memory writes that switch between two levels
(~2,250 and ~2,760 µs, also in unchanged code like `memset`), and three more alternating runs of each put
old and new within 1%. All three builds pass their tests (new ones: runs written between guard bytes,
`forEach` stopped mid-chunk), build without warnings, and pass the zero-allocation thresholds.

## 2026-11-12: the three builds (baselines `optimized-*`, `portable-*`, `portable-no-c-*`)

Bytes builds three ways, selected by package traits and run with `./bench BUILD [benchmark args]` (each
build has its own build directory):

- `optimized` (default traits `NEONShuffle`, `HardwareCRC`): CBytesNEON's `tbl` lookups and CBytesCRC's
  `pmull`/`crc32` instructions.
- `portable` (`--traits Portable`): both C modules, with `BYTES_PORTABLE` defined so their headers compile
  the fallbacks other CPUs get, and `CRC32` uses its table path. The Swift targets get `-Xcc
  -DBYTES_PORTABLE` too: a module inlining Bytes' code compiles the headers' `static inline` functions
  itself.
- `portable-no-c` (`--disable-default-traits`): no C modules, so the Swift fallbacks are used throughout.

Checked: the benchmark plugin honors the traits (`pmull` and `crc32` counts 32 and 4 in the optimized
benchmark binary, 0 in the others); tests pass in all three (126 in the portable builds: the folding
constants test is hardware-only); no warnings.

Two interleaved rounds (optimized, portable, no-C, twice), 179 benchmarks without the allocation-only
ones. Times are the mean of the two rounds' medians, in µs. 291 of 337 rows are within 10% of optimized for
`portable`, 301 for `portable-no-c`. The rest:

| Workload | Optimized | Portable | Portable, no C |
|---|---|---|---|
| Bulk read `read(_:_:into:)`, `Byte3`, 4 MB in cache | 77 | 8,485 (110x) | 222 (2.9x) |
| … `Byte5` | 93 | 10,500 (113x) | 202 (2.2x) |
| … `Byte5`, 512 MB from memory | 13,000 | 1,318,500 (101x) | 26,000 (2.0x) |
| Bulk BE24 (`read(_:_:into:)`) | 21 | 2,090 (100x) | 55 (2.6x) |
| Generating write, `Byte3`, 4 MB | 97 | 6,699 (69x) | 204 (2.1x) |
| … `Byte5` / `Byte7`, 4 MB | 178 / 136 | 7,072 / 7,209 (40x / 53x) | 272 / 197 (1.5x) |
| `forEach`/`for`-`in` over `Byte5`–`Byte7`, 4 MB | 155–248 | 6,700–9,500 (37–51x) | 168–282 (1.1x) |
| `Byte5`–`Byte7` reads, 512 MB, 32 cores | 2,323–2,333 | 35,000–49,000 (15–21x) | 2,309–2,322 (1.0x) |
| CRC-32, 256 KB | 466 | 14,000 (30x) | 14,000 (30x) |
| Runs: 3- and 4-byte elements, per-element writes | 5.9 / 8.1 | 6.9 / 9.2 (1.17x / 1.14x) | 7.1 / 9.5 (1.20x / 1.18x) |

Instruction counts agree (bulk BE24: 267 K, 42 M, 900 K), so these aren't timing noise.

What it shows:
- Without the C modules, the odd-width group paths lose 1.1–2.9x on one core and nothing when memory-bound
  on all cores: that is what the `NEONShuffle` trait buys.
- The C modules' portable fallback is a disaster: 37–113x slower than optimized on one core (15–21x on all
  cores, from memory), and 15–54x slower than not having the C module at all. Each lookup copies its 48- or
  64-byte table to the stack and gathers lane by lane (`bytes_table_portable`), and the pack/unpack steps do
  3–4 lookups per 64 bytes: the bulk `Byte3` read loop in the portable binary is 868 instructions per
  64-byte step (64 lane extracts, 81 byte loads, 60 lane inserts, 77 stores, 63 branches), about 200 per
  lookup, where NEON uses one `tbl`. On other CPUs with default traits, Bytes would take the shuffle paths with these
  fallbacks. They should be taken only where lookups are single instructions (as
  `ByteLanes.isLookupVectorized` already reports), and the plain Swift loops used elsewhere. Fixed in the
  next section, which also replaces the plain loops with portable shuffles.
- The table CRC is 30x slower than the folded hardware one at 256 KB, matching the `CRC-32 tables`
  benchmark (14 ms in all three builds).

## 2026-11-10: conveniences, lane shuffles for a decoder, cheaper array builders (baselines `conv-old-*` → `conv-new-*`, `builder-ab`)

New API (proposals 10–14 and parts of 16–17; `Tests/BytesTests/FieldHelperTests.swift`,
`LaneShuffleTests.swift`):

- **Flags and fields:** `read(Bool.self)`, `peek(Bool.self)`, `write(_: Bool)`, `BitBuffer.read(Bool.self)`;
  `readSigned(_:_:as:)`, `readSigned(bitCount:)` (and on `BitBuffer`), `signedBits(_:as:)`,
  `Bits.signedValue`; `bits(from:upTo:)` (unchecked), `keepingLowBits(_:)`, `lowBitMask(_:)`;
  `matches(_:mask:)` on integers, `Bits`, and groups, and `expect(_:mask:)`; `Bits(rawBitsOf:)`.
- **Records and errors:** `forEachRecord(tag:length:_:_:)` (all or nothing per record, no closure inside, so
  the cursor stays in registers); `located(_:)` and `LocatedBytesError`.
- **Small ones:** `readRemainingBytes()`, `CRC32.checksum(_:continuing:)`, `RawSpan.hasPrefix(_:)`,
  `Byte16.vector`/`Byte16(_: SIMD16)`, `[UInt8].append(copying:)`, `String(utf8Capacity:writing:)` (a
  non-throwing overload too: 10 instructions per call cheaper for bodies that can't fail).
- **Lanes, for Base64's decoder:** `ByteLanes.deinterleave` of four vectors (8 `uzp`s, as `ld4`),
  `interleave` of three (3 `tbl`s, as `st3`), `lookup(in:keepingOutOfRange:)` (`tbx`) for 16-, 48-, and
  64-byte tables, a 16-byte `lookup(in:)`, and a 128-byte one.
- **`BytesWriter.position` and `rewind(to:)`**, for all-or-nothing writes (the decoder's failures).
- **Docs:** "Fields that fill a byte: read the `Byte`, then take it apart" (`WritingParsers.md`), and the
  examples use the new forms.

Every new helper was checked against the code it replaces (`@inline(never)` pairs in a probe package,
instructions per function): the pairs merged into one function (`read(Bool.self)`, both signed reads,
`signedValue`, `readRemainingBytes`, `Byte16.vector`, `append(copying:)`) or the new form was shorter:
`keepingLowBits` 6 against 8, `bits(from:upTo:)` 5 against 8 (and 23 for the checked subscript),
`CRC32.checksum(_:continuing:)` 6 against 12, `matches` 8 against 10, `hasPrefix` 14 against 34,
`forEachRecord` 64 against 80. `located` in a `catch` adds 13 instructions to the function, all on the
error path.

Inside Bytes, the masks in `write(repeating:byteCount:count:)`, the run pattern, and `LEB128.maxValue` use
`keepingLowBits`/`lowBitMask` (runs of 3- and 4-byte elements −2.0 to −2.6% instructions; the rest
unchanged), and HuffmanTable's root lookup uses `bits(from:upTo:)` (same 138 instructions). Not
`write(_:bitCount:)`: with a run-time bit count, a loop of those writes grew from 146 to 169 instructions
(LLVM split the function's paths differently), so it keeps the explicit mask.

The comparators now use the new API where Bytes code would (`readSection`, `forEachRecord`,
`readSigned`, `[bit: 0]`):

| Benchmark | Instructions | Time (rounds 1 / 2) |
|---|---|---|
| Fields: Bytes | 300.6 → 284.6 K (−5.3%) | −5.2% / −6.0% |
| Fields: Bytes, position and rewind / in `atomically` | −5.2% / −5.3% | −3 to −8% |
| Fields: fixed-size records | unchanged (198.6 K) | within noise |
| Runs, back-references, other fields rows | within ±0.3% | within noise |

**Array builders.** The standard library's `[UInt8](capacity:initializingWith:)` (and
`init(unsafeUninitializedCapacity:)`) allocate through an unspecialized function: about 500 instructions
and 27 ns more per array than `reserveCapacity` then `append(addingCapacity:)`, at 40 bytes and at 1 KB
alike (a standalone driver). `[UInt8](byteCapacity:writing:)` now reserves and appends, and
`[UInt8](copying:)` uses `Array(UnsafeRawBufferPointer)`:

| Benchmark (`builder-ab`, `old5` against now) | Instructions |
|---|---|
| Array builder: 1,000 38-byte arrays, `[UInt8](byteCapacity:writing:)` | 1,696 → 1,228 K (−27.6%) |
| …closure not annotated | 1,748 → 1,228 K (−29.8%): annotating no longer matters |
| …`[UInt8](capacity:)` + `withBytesWriter` (the old form, unchanged) | 1,696 K |

`[UInt8](copying:)` had been copying through `init(unsafeUninitializedCapacity:)`: once MQTT's copying
benchmark used it, it ran 17.5% more instructions (about 590 per packet) until the change above.

**Harness.** The bandwidth and write benchmarks no longer time inside `scaledIterations`: they report the
framework's throughput (iterations per second); bandwidth is that times the bytes per iteration in the
name.

## 2026-11-09: runs, copies from a reader, short copies, minimal LEB128 (baseline `runs-copies-1`)

The four highest-value proposals from `Proposals/INDEX.md` (1, 2, 3, 5), implemented:

- `write(_: RawSpan)` copies 33–64 bytes inline (four overlapping 16-byte moves) instead of calling
  `memmove`.
- `write(repeating:count:)` for a `Byte` or any `ByteGroup`, and `write(repeating:byteCount:count:)` for a
  1–8-byte element whose size is known only at run time. Capacity is checked once; the element is repeated
  across 16 bytes in whole copies and stored 16 bytes at a time (`stp`); byte runs over 256 call `memset`.
- `write(from: &reader, byteCount:allowingOverrun:)`: LZ4's literal copy. With room in both cursors, 16-byte
  steps (one `ldr q`/`str q` for up to 16 bytes, a 5-instruction loop) that may overwrite up to 15 bytes
  after the copy; otherwise exact.
- `requiringMinimal:` on `read(LEB128.self…)`, `read(bytesPrefixedBy: LEB128.self…)`, and
  `read(sectionPrefixedBy: LEB128.self…)`: one compare in the out-of-line multi-byte loop (a last byte of
  zero after others is padding).

Measured by `Benchmarks/BytesBenchmarks/RunsAndCopies.swift`: each new form next to the code it replaces,
in the same run, filling or reading 64 KB (values below are per 64 KB; widths and sizes are run-time
values). All allocate nothing (thresholds recorded).

| Workload (64 KB) | New | Before (same run) | Change |
|---|---|---|---|
| Runs of 3-byte elements, 1–62 each (QOI RGB) | 129 K instr, 6.3 µs | one 8-byte overrun store per element: 174 K, 8.6 µs | −26% instr, −28% time |
| Runs of 4-byte elements, 1–62 each (QOI RGBA) | 89 K, 4.2 µs | 150 K, 7.5 µs | −41%, −44% |
| Runs of `Byte3`, 1–62 each (width known) | 93 K, 4.6 µs | generating `write(Byte3.self, count:)`: 100 K, 5.3 µs | −7%, −14% |
| Byte runs, 8 / 40 / 1,000 each | 304 K, 10 µs / 71 K, 2.7 µs / 8.6 K, 1.3 µs | generating write: 304 K, 17 µs / 81 K, 6.3 µs / 8.1 K, 1.3 µs | time −41% / −57% / equal (both `memset`) |
| Literals of 0–15 bytes (~8,700 copies) | 257 K, 10 µs (30 instr each) | `write(reader.read(byteCount:))`: 474 K, 18 µs (54 each) | −46%, −44% |
| Literals of 16–64 bytes (~1,600) | 67 K, 4.1 µs | 101 K, 5.2 µs | −34%, −21% |
| 40-byte span copies (1,638) | 110 K, 2.8 ns each | `memmove`: 127 K, 4.3 ns; two writes ≤ 32: 173 K, 4.1 ns | −13% instr, −34% time |
| 48-byte | 92 K, 2.9 ns | `memmove`: 111 K, 4.7 ns; split: 144 K, 4.2 ns | −17%, −38% |
| 63-byte | 70 K, 3.1 ns | `memmove`: 118 K, 7.3 ns; split: 111 K, 4.0 ns | −41%, −57% |
| 64-byte | 69 K, 3.1 ns | `memmove`: 76 K, 3.0 ns | equal (an aligned size `memmove` handles well) |
| LEB128, 1–4 bytes (~35 K values), `requiringMinimal: true` | 2,273 K, 103 µs | read, then compare with `byteCount(of:)` (MQTT's check): 2,396 K, 111 µs | −5%; +4% over an unchecked read (2,185 K) |

In the consumers (interleaved runs of the old and new trees, baselines `ab-old-*`/`ab-new-*` in each):
LZ4 −26% instructions and −42% time (`swift-help.lz4`), QOI `tricolor.qoi` −77% and −70%, Base64's 40–47-byte
inputs −18% and −18% (after its `writeShort` workaround, now removed), MQTT's PUBLISH encoding −10% and −13%
(its 64-byte payloads were `memmove`d), MQTT parsing −1.6 to −2.6% instructions. See each package's RESULTS.md.

### Follow-ups: short-distance back-references, a cheaper pattern (baselines `fu3-old-*` → `fu3-new-*`)

- **`copy(fromDistance:count:)` for distances 2–7** is now a run of the last `distance` bytes: one load,
  then the run fill's 16-byte stores (libdeflate does the same). It copied a byte at a time, each byte
  waiting on one just stored. The overrun form falls back to it for distances under 8, so DEFLATE and LZ4
  matches use it too.
- **The pattern** for a 1–8-byte element is two multiplies: the element times a constant with a 1 at
  each copy's first bit gives the low 8 bytes, and the element rotated by `8 % period` bytes gives the
  high 8 bytes. One `switch` gives the constant, rotation, and step. It compiles to a branch tree, not a
  table, which is still cheaper than doubling a 128-bit value (16 instructions per doubling).

Interleaved runs of the tree before these changes and after, two rounds; instructions are exact minimums,
times from round 2:

| Workload | Instructions | Time |
|---|---|---|
| Back-references 2–7 bytes back, 3–258 bytes each (~490 per 64 KB) | −69 to −77% | −80 to −94% |
| …3–32 bytes each (~3,600) | −2 to −21% | −36 to −59% |
| Back-references 1 back (`memset`, unchanged) and 8 back (control) | +1 to +21%: a constant ~1.3 K difference between the two benchmark binaries, plus noise on 34 K | ±3% |
| Runs of 3- / 4-byte elements, 1–62 each | −20% / −15% | within noise: the fill is store-bound |
| NativeZip: inflate 32 MB of pixel runs (new fixture) | −38% (227 → 141 M) | 18 → 9.2 ms (−49%), level with zlib (9.8 ms) |
| NativeZip: inflate 32 MB text, 2,000 small files | +0.0%, +0.1% | unchanged |
| QOI `tricolor.qoi` (run fills of 3-byte pixels) | 1.52 → 1.32 M (−13%) | within the run's drift |
| LZ4 | ±0.7% | noise |

Two things that went wrong first, both fixed:

- **Inlined, the short-distance fill slowed the common case.** It made NativeZip's `decodeSymbols` loop
  743 → 853 instructions and its text and small-file inflates +12–14% instructions, where almost every
  match is 8 or more bytes back. Now it's out of line (`_copyRepeating`, static, taking values, like the
  other slow paths), and the loop is 722 instructions (743 before any of this): the old byte loop moved
  out too.
- **Distance 1 through that function** (`memset` for more than 64 bytes, the fill below) cost 21% more
  on long runs through the extra call, and short runs gained nothing. It's back to the inline `memset` it
  was.

The run benchmarks first measured the new path and its reference in one function behind a run-time flag.
Changing the new path moved the reference's register allocation (the `Byte3` generating write 70 → 102 K
instructions, unchanged source), so each is now its own `@inline(never)` function. Allocation thresholds
for the back-reference workloads: 0.

## 2026-11-09: inline span writes, array builders, one-check prefixed sections (baselines `bcd2-old-*` → `bcd2-new-*`)

- **`write(_: RawSpan)` is `@inline(__always)`**, with copies over 64 bytes in an out-of-line `_copyLong`
  (`memmove`). It was `@inlinable` and stayed a call: MQTT's encoder made three per packet, Base64 two
  per input, and both LZ4 ports one per literal run.
- **`[UInt8](byteCapacity:writing:)` and `append(byteCapacity:writing:)`**: one closure instead of
  `[UInt8](capacity:)` plus `withBytesWriter`. Generic over the error type. **Annotate the closure in hot
  code** (`{ (writer) throws(BytesError) in … }`): unannotated, Swift 6.4 infers `throws(any Error)`, and
  that closure wasn't inlined. The writer went to it through memory with its unaligned slow paths, for
  +3% here. A `BytesError`-only overload doesn't help: the unannotated closure still infers `any Error`,
  which then doesn't convert.
- **`read(bytesPrefixedBy:)` checks the length once** and builds the span unchecked. Before, it checked
  in `peek`, in its own guard, and again in `read(byteCount:)`'s checked `extracting`. The LEB128 form
  likewise. New: **`readSectionIfComplete(prefixedBy:_:)`**, which returns `nil` without consuming when
  the section isn't all there, for tolerant parsers (zip extra fields) without `try?`.

Same-run comparisons in Bytes' benchmarks (`BuildersAndSections.swift`; exact instruction counts, times from
round 2):

| Workload | Instructions | Time |
|---|---|---|
| 1,000 38-byte arrays: builder, closure annotated | 1,695,567 (same as the nested form, 1,695,589) | 66 µs (nested: 64) |
| …closure not annotated | 1,747,460 (+3%) | 72 µs |
| 64 KB of prefixed sections: `read(sectionPrefixedBy:)` | 96,559 → 74,207 (−23%); now below the hand-written form (81,585) | within noise |
| …`readSectionIfComplete` | 70,362 (−14% against hand-written) | within noise |
| Span copies of 24–64 bytes (`write(_: RawSpan)`) | −33 to −36% | −20 to −34% |
| Literal copies of 0–15 bytes, overrun form | −3% | −12 to −14% |

In the packages (old and new trees interleaved, two rounds): MQTT encoding −3.0% instructions and −8 to
−11% time, parsing −2.2 to −3.2% instructions. Base64 40–47 B: −13% instructions, −14 to −18% time. LZ4
(Bytes): −4.4%, and its exact-copy variant −21%. The `ParserSpan` LZ4 port: −15.6% instructions, −7 to
−11% time, from its output side (Bytes' writer) alone. Zip directory (Bytes): −0.7%. NativeZip's central
directory with `readSectionIfComplete`: +0.2% instructions, +1.7% time, against −14% in the micro-benchmark,
so it's neutral there at best. Code size: `MQTTPublish.write(to:)` 364 → 427 instructions, `writeBody`
127 → 294, NativeZip's `decodeSymbols` unchanged (769).

## 2026-11-09: `position`/`rewind(to:)`, and cursors at an offset (baselines `pos-fields-*`)

Proposals 7 and 8:

- `reader.position` (a `BytesReader.Position`: byte and bit offset) and `rewind(to:)`, which can't fail
  and doesn't throw: two stores and a precondition that the position isn't ahead of the cursor (which keeps
  the invariant `_assumeInvariant` states). It replaces `let start = byteOffset … try! seek(toByteOffset:
  start)` rollbacks, and `atomically { }` where its closure isn't inlined or can't return the result.
- `BytesReader(span, atByteOffset:)` (any integer type: zip's `UInt64` offsets without `Int(clamping:)`),
  `BytesReader(span, atBitPosition:)`, `BitBuffer(span, atBitPosition:bitOrder:)`, and
  `BytesWriter(&bytes, atByteOffset:)` for a buffer passed `inout` with a prefix already written (no
  `_mutatingExtracting(...)` plus `skip` at the call site). All `@inline(__always)`: the writer's
  initializer, only `@inlinable` at first, was called out of line from NativeZip's `decodeSymbols` and grew
  it from 789 to 891 instructions; inlined, it's 769.

All-or-nothing entries in the 2,000-entry zip directory (field by field, same run; exact instruction counts):

| Each entry… | Instructions | Time |
|---|---|---|
| not all or nothing (`Fields: Bytes`) | 300,588 | 10–11 µs |
| in `atomically`, calling an `@inline(__always)` function with the body | 300,588 (free: the closure is inlined) | 10–11 µs |
| in `atomically`, the body written in the closure | 452,574 (+51%) | 16–17 µs |
| between `position` and `rewind(to:)` | 306,591 (+2%: 3 per entry) | 11 µs |

So `atomically` costs nothing or half again depending on how the closure is written, and `rewind` costs a
steady 3 instructions per entry. Its documentation now says so. In the packages (interleaved runs,
`pos-old-*` → `pos-new-*`): MQTT's 5 rollbacks lose their out-of-line `seek` calls and
`swift_unexpectedError` paths (parsing −0.4 to −1.1% instructions); NativeZip's 5 seek-after-create sites
and 3 inflater cursors (raster inflate −1.2% instructions and time, the rest within ±0.3%). Details in
their RESULTS.md files.

## Verification, 2026-11-09 (baseline `modern`)

A full run after the renames, the formatting pass, and the `ByteLanes` additions. Other agents were
building and benchmarking on the machine at the time (load average ~10), so times are not comparable.
Instruction counts are, and they're what this check uses. (The `modern` baseline was later re-run alone:
see the top.)

- **Instructions are unchanged from `safe-final` in every benchmark.** Of 280 rows, none differs by 1% or
  more, except two 32-core rows at +1.3% and +1.5%, which are scheduling noise. Wall times are 5–15%
  slower across the board, including the references (raw SIMD read and store, `RawSpan.load`), and with
  equal instruction counts. That's the load, not the code.
- **The `literals3` numbers don't reproduce at HEAD, but the parser didn't change.** That baseline
  recorded 292 K for "Fields: Bytes", 197 K for the fixed-size records, and 48 K for the search, against
  301, 199, and 50 K now. The comparators that don't use Bytes moved by the same 1–2 K (315 → 317,
  257 → 259).
  - Commit `fa86687`, the literal fix, built from a clean export and run back to back with HEAD, gives
    292 / 197 / 315 / 257 / 48 K again, so both measurements are deterministic.
  - Yet `parseWithBytes` is byte-for-byte the same machine code in both binaries (`objdump`, addresses
    normalized). The signature is still the folded `mov`/`movk` constant with no `swift_once`, so the
    literal fix holds.
  - The difference is outside the measured function: the benchmark binary around it, or the process-wide
    instruction counter. It isn't a library regression.
  - The "−3% against `safe-final`" in "Integer literals" is therefore a property of that build of the
    benchmark binary, not something the literal change does to the parser.
- **Allocations:** `thresholds check --filter 'Allocations:.*'` passes (EQUAL) with the `NEONShuffle`
  trait on, and with it off (`--disable-default-traits`, checked by the absence of `tbl` in the rebuilt
  bulk-read loops).
- **Vectorization**, checked with `Tools/loops` on the benchmark binary and on probes:
  - `forEach` over every byte group:
    - `Byte2`, `Byte4`, `Byte8`: `rev*.16b` + `add` with `ldp q`.
    - `Byte3`: `ld3.16b`.
    - `Byte5`–`Byte7`: NEON `tbl` unpacking.
    - `Byte9`–`Byte15`: `rev64.16b`/`usra.2d`.
  - `forEach` over every bit width: `Bits<3>` with `ld3.16b`, `Bits<5>`–`Bits<7>` from 64-bit blocks.
  - Bulk `read(_:_:into:)` of `Byte3` and `Byte5`–`Byte7`: an innermost loop of 4 `tbl.16b` with `ldp`/`stp`,
    with no lane moves.
  - `lastByteOffset(of:)`: 12 instructions with 2 `cmeq.16b`, `and.16b`, and `umaxv.16b`.
  - `ByteLanes.lookup(in:)` and `deinterleave`: `tbl.16b`. `interleave`: `zip1`/`zip2` plus an `st2.4h`
    store, with no lane moves.
  - `CRC32._fold`: 8 `pmull`, 8 `pmull2`, and 8 `eor3` per 128 bytes. The tail is `crc32x`.
  - Generating writes vectorize for `Byte2`, `Byte4`, `Byte`, `Nibble`, `Crumb`, and `Bit`.
    - `Byte3` and `Byte5`–`Byte7` use `tbl` packing, with a few lane inserts building the 32/64-bit lanes.
    - `Byte8`–`Byte16` writes are scalar, as recorded below.
- **`Byte16` `forEach` is reported `vector128` by `Tools/loops`, but its decode is scalar.**
  - The loop is `ldp x`, `rev` ×2, `fmov`/`mov.d` into vectors, then `add.2d`. Only the benchmark's sum
    is vectorized, fed one lane at a time.
  - `Tools/counters --mode simd_fp_unit_instructions` on a probe confirms it: 0 SIMD loads for `Byte16`,
    against 66 M `ldp q` for `Byte4` and 219 M (`ld3`) for `Byte3`, over the same 2 GB.
  - Its instruction count is the same as in `bandwidth2`, so this isn't new. The note under "Making loops
    of single reads vectorize" now says so.
- **A tooling note:** `Tools/loops --forbid` matches substrings, so `--forbid bl` also rejects `tbl`. Use
  `blr`, or check the `+calls` verdict.

## Allocation checks

Every workload that shouldn't allocate is registered a second time as `Allocations:<name>`. These count
only allocations (`mallocCountTotal`), for 10 iterations over 64 KB buffers. They cover:

- every read and write bandwidth workload: all widths, `for`-`in`, bulk/NEON, custom types, and zero-copy
  views;
- the field, bit-field, and search parsers;
- a section round trip: LEB128-prefixed sections, length-prefixed UTF-8, and LEB128 values.

`Thresholds/` holds a static p90 threshold for each (140 files):

```sh
# Fails (nonzero exit) if any workload allocates more than its threshold.
swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:.*'
# After adding a workload: record its threshold.
swift package --disable-sandbox --allow-writing-to-package-directory benchmark thresholds update --filter 'Allocations:.*'
```

The check passes with the `NEONShuffle` trait on and off (`--disable-default-traits`). A planted
`[UInt8]` allocation fails it ("WORSE than the defined thresholds", exit 1).

The names have no spaces or slashes: `thresholds update` writes them as `_` in the file name, but
`thresholds check` (benchmark 1.38.1) looks the file up by the unaltered name, so a name with a space
always fails, or, if other files are found, is silently not checked (ordo-one/benchmark#373).

**One allocation found:** `let reader = BytesReader(span); for byte in reader { … }` allocates once per loop, not
per byte. The cause is in the compiler (Swift 6.4.2, and `main` by inspection):

1. SILGen puts a `~Copyable` `let` in a box: `alloc_box ${ let Bytes }`, then a `begin_borrow [var_decl]`.
2. `Iterable` requires `@lifetime(borrow self)` on `makeBorrowingIterator()`. A `let` has no access scope,
   so `LifetimeDependenceInsertion` bases the iterator's `mark_dependence` on the box's borrow.
3. `AllocBoxToStack` has no case for a `mark_dependence` on the box, treats it as an escape, and leaves
   the box on the heap: 56 bytes, the 40-byte cursor and a header.

A `var` reader (its dependence is on a `begin_access`) or a `borrowing` parameter isn't boxed. A
`copy self` witness would avoid the dependence, but the protocol rejects it. The same `AllocBoxToStack` gap
is open as swiftlang/swift#93942 for `consuming` parameters; a report with a standalone reproducer and a
fix brief is ready to file.

The `let` form's threshold is 1, so a compiler fix shows up as an improvement.
`Allocations:Read:_for-in_Bytes_(UInt8),_var_reader` holds the workaround at 0.

## Against swift-binary-parsing (`../BinaryParsingComparison`, full write-up in its RESULTS.md)

Apple's `BinaryParsing` 0.0.4 on the same work, both directions: our zip and integer parsers ported to
`ParserSpan`, and its QOI and LZ4 example parsers ported to `Bytes`.

| Workload | Bytes | `ParserSpan` |
|---|---|---|
| Zip directory, field by field / fixed-size records | 11 / 7 µs | 23 / 13 µs |
| Big-endian `UInt32`s | equal (10 µs, vectorized) | equal |
| 24-bit values | 55 µs (`forEach` 48) | 158 µs |
| QOI, LZ4 (same algorithm) | within 5% either way | |

- **`ParserSpan`'s field reads cost more** for three reasons:
  - A trapping add for each advance, which its bounds check already makes redundant.
  - Per-site error locations, which give each failing read its own throw path: 2.6x the code, and the
    cursor spilled to the stack.
  - An out-of-line generic `sliceSpan(byteCount:)`.
- **Its odd widths** are a byte-by-byte loop; `Byte3` is two overlapping loads.
- **Its published examples** are 4–42x slower than either port: `Data` appends per pixel, and an `Array`
  per LZ4 match.

**Adopted:**
- `atomically { }` (all-or-nothing reads).
- `read(Int.self, as: Byte8.self, .littleEndian)` (throws instead of trapping when an untrusted value
  doesn't fit).
- `ByteGroup.signedInteger(_:as:)` (sign extension for odd widths).

**Learned:** cursors captured by closures that aren't inlined live in memory. That costs Bytes more than a
byte-only cursor, because each byte read then re-checks the bit offset and bit order. The README's caveat
covers it.

## Integer literals for byte groups

`let signature: Byte4 = 0x50_4B_03_04`: the literal's digits are the bytes in memory order, as a hex dump
shows them. In other words, the literal is the group's big-endian value. That's the one reading that
isn't ambiguous: the source shows the bytes in the order the file holds them, whatever byte order the
format uses for its numbers.

- **Width checks.** The literal type is the group's `Integer`, so a literal too wide is a compile error
  for `Byte2`, `Byte4`, `Byte8`, and `Byte16`. For odd widths it's a precondition, since their integers
  have spare bytes.
- **Leading zero bytes** are kept, because the width is fixed (`0x00_04_4D_51_54_54` as a `Byte6`).
- **Converted:** constants in NativeZip (signatures), MQTT (protocol name, `$share/`), the docs, and the
  benchmarks. Array literals still work.

The first version built the value with `init(bigEndian:)`, and `static let signature: Byte4 = 0x50_4B_01_02`
then cost **41% more instructions** parsing fixed-size zip records (281 vs 199 K).

- **Why:** with the array literal, the compiler evaluated the global's initializer at compile time, so
  each use was a `mov`/`movk` constant. With the integer literal, the global stayed lazily initialized: a
  `swift_once` check and a load on every use.
- **The cause:** `init(bigEndian:)` byte-swaps, and the compile-time evaluator can't fold a byte swap (an
  LLVM intrinsic). Swapping back to an interpolated precondition message didn't matter.
- **The fix:** the literal initializer reverses the bytes with shifts. Constant again, no `swift_once`.

Against `safe-final`: field parsing −3% instructions, fixed-size records −1%, signature search −4%
(baseline `literals3`). These didn't hold at HEAD, where the parser's machine code is unchanged: see
the 2026-11-09 section. NativeZip's parsing (computed-property signatures) was unaffected either way.

A `static let` built with a byte order still has the lazy-initialization cost. Checked:
`static let signature = Byte4(0x504B_0102, .bigEndian)` compiles to the `swift_once` check again. Write
constants as literals, or as computed properties.

## Group operations: `ByteGroup` operators, `forEach` with a byte order, and the table CRC

Superseded for the CRC (2026-11-12, "fast portable builds"): the table path is now braided, five
interleaved CRCs, 3.6x faster at 256 KB than the slicing-by-8 measured here. The group operators and
`forEach` with a byte order are unchanged.

The table-driven CRC (the portable path) was written with hand shifts and masks:
`tables[6][Int(word >> 8 & 0xFF)]`, eight times over. Rewritten with `Bytes` APIs:

```swift
reader.forEach(Byte8.self) { group in
    let bytes = group ^ Byte8(UInt64(state), .littleEndian)        // new: byte-wise `^` on groups
    state = 0
    for index in 0..<8 { state ^= tables[7 &- index][Int(bytes[index])] }   // byte subscript, no shifts
}
reader.forEach(Byte.self) { byte in state = state >> 8 ^ tables[0][Int(state[Byte.self, at: 0] ^ byte)] }
```

Benchmarks `CRC-32 tables, …`, 32 MB per iteration:

| Variant | 256 KB in cache | 64 B inputs |
|---|---|---|
| Original (shifts and masks, `[[UInt32]]`) | 336 M instructions, 14.0–15.0 ms | 364 M, 12.0–12.7 ms |
| **Bytes APIs, `[[UInt32]]`** (kept) | **180 M**, 14.1–14.4 ms | **219–223 M, 8.8–9.4 ms** |
| Bytes APIs, `InlineArray<8, InlineArray<256, UInt32>>` | 139 M, 15.3–15.7 ms | 167 M, 9.6–10.0 ms |
| Bytes APIs, split into halves (`lowHalf`/`highHalf`) | 235 M, 14.4 ms | 261 M, 11.1 ms |

- **The rewrite** halves the instructions (each byte becomes one `ubfx` and one indexed load). It's 27%
  faster on short inputs and equal on long ones. Long inputs are bound by the latency of the lookup
  chain, not by instructions.
- **`InlineArray` tables** remove the bounds checks (a byte index can't pass 255) and cut instructions
  further. They're still 7% slower: with one global table, each lookup is an `add` and then an
  `ldr [x, #offset]`, one more cycle on the latency chain.
  - With eight arrays, each table's base is a register, so a lookup is a single
    `ldr w, [table, index, lsl #2]`, and LLVM checks the arrays' bounds once, before the loop.
  - Padding the tables apart (1,056-byte stride) changed nothing, so cache conflicts aren't the cause.
- **Splitting into halves** puts the four state-independent lookups off the critical path. It cost
  instructions without gaining time.

**`forEach(T.self, byteOrder) { integer in … }`** is new, the loop counterpart of `read(T.self, byteOrder)`.
It's exactly as fast as converting in the body: identical instruction counts and times for `Byte2`,
`Byte3`, `Byte4`, `Byte6`, and `Byte8` (benchmarks `forEach(ByteN.self …), 4 MB`). It's sugar, and the
CRC's hardware tail uses it.

**`ByteGroup` gets `^ & | ~`** (and the compound forms), byte by byte in memory order. No byte order is
involved, so they can't be ambiguous the way integer literals or shifts on a group would be. That's why
there are no shifts on groups: "shift by a byte" depends on which end is first, and the byte subscript
and halves already say which byte is meant.

## `CRC32` (measured in NativeZip's benchmarks, against zlib's `crc32_z`)

| Input (32 MB per iteration) | `CRC32` | zlib | |
|---|---|---|---|
| 32 MB | 532 µs (63 GB/s), 10 M instructions | 888 µs (38 GB/s), 13 M | 1.7x |
| 256 KB, in cache | 460 µs | 833 µs | 1.8x |
| 1 KB | 665 µs | 1,279 µs | 1.9x |
| 64 B | 3,084 µs | 6,963 µs | 2.3x |

- **Large inputs:** eight 16-byte accumulators fold 128 bytes per step: per lane, a `pmull`, a `pmull2`,
  and an `eor3` with the next 16 bytes, independent chains so the multiplies' latency overlaps. At the
  end, the lanes fold into one, and the CPU's CRC32 instructions reduce its 16 bytes.
  - The constants are x^(n ± 32) mod P, bit-reflected. A test derives them; the 128- and 512-bit ones
    match Linux's.
- **Below 256 bytes:** `crc32x`, 8 bytes at a time.
- **Bytes tools do the reading:**
  - Each 128-byte step is a fixed-size sub-cursor, so its eight loads compile to four `ldp q` with no
    bounds checks.
  - The tails are `forEach(Byte8.self)` and `forEach(Byte.self)`.
  - The file has no `unsafe`: the C wrappers take and return values.
- **First version 3.5x slower than zlib:**
  - The nested helper that loaded each 16 bytes wasn't inlined. As a call per load, it spilled the eight
    accumulators every time.
  - `@inline(always)` on it gave the loop above (16 `pmull`, 8 `eor3`, 4 `ldp`, ~10 bookkeeping
    instructions per 128 bytes).
- **Other CPUs:** tables (slicing-by-8 then, braided since 2026-11-12). The tests check them against a
  bit-at-a-time reference too.

## Safe constructs instead of unsafe ones (baselines `pre-safety` → `safe-final`)

Every `unsafe` site was tried with its safe standard-library counterpart (`RawSpan.load`,
`MutableRawSpan.storeBytes(of:toByteOffset:as:)`, checked `extracting`, `MutableSpan` subscripts,
`UniqueArray`, `bitCast`) and measured. Instruction counts are the deciding metric (deterministic).

**Kept safe** (no cost, or faster):

| Change | Effect |
|---|---|
| `read(byteCount:)` and `read(_:count:)` use checked `extracting` | Fixed-size records **−21% instructions, −31% time** (199 vs 253 K, 7.3 vs 10.6 µs); field-by-field +3% instructions (301 vs 291 K), same time |
| `HuffmanTable`: `UniqueArray` storage, `Span`/`MutableSpan` indexing in decode and build, `InlineArray` scratch up to 320 symbols | Equal (NativeZip small files 239 vs 239 M) |
| `Shuffle` reinterpretations: `unsafeBitCast` → `bitCast` | Equal |
| Distance-1 match fill: `storeBytes(repeating:)` instead of `initializeMemory` | Equal |
| LEB128 slow paths, section move, unaligned `store`, `BitBuffer` slow refill | Cold paths |

Building `HuffmanTable` safely first cost 5% more instructions on small DEFLATE files. Not the checks:
a nested function that captured the entry closures stopped them being inlined. As a static function, equal.

**Kept unsafe** (each with a comment saying why), because the checked forms measured slower:

| Site | Checked cost |
|---|---|
| `Load` (all cursor reads) | Field-by-field +24% instructions; `Byte3`/`Byte5`–`Byte15` 2–8x; bulk loops stop vectorizing |
| `Store`, `_copy`, `_move` (all writer stores and match copies) | Odd widths +42–144% instructions, packed bit fields +28–47% |
| `BitBuffer.refill` fast path | DEFLATE +10% instructions |
| `lowBytes` (9–15-byte custom types) via `withUnsafeBytes(of:)` | Through an `InlineArray` span: +46% instructions |
| Bulk reads into `OutputSpan`, `Iteration`'s buffer stores | Per-value checks stop vectorization |

The pattern: the standard library's check is `UInt(offset) <= UInt(count) && size <= count - offset`,
and the first half needs `offset >= 0`, which the cursor deliberately doesn't state (see "Making loops of
single reads vectorize"). So it isn't folded into the cursor's own check, except where the offset is
visibly non-negative (constants, or loops counting up from 0). With no safe in-place copy, no safe view of
an `OutputSpan`'s uninitialized capacity, and no safe span-to-`Array` copy in the standard library,
`memmove` in `write(_:RawSpan)`, `withBytesWriter`, and `[UInt8](copying:)` stay unsafe too.

## Bit fields of values already read

From a survey of MQTT's and NativeZip's integer escapes: `value[bit: i]`, `value[Bits<w>.self, at: i]`
(as `Bits`), and `value[bits: range]` on integers, all settable; `Bits` fields (`flags[Crumb.self, at: 1]`);
and `init?(rawBits:)` for raw-value types. They replace NativeZip's DOS date/time shifts and masks, its
attribute and version tests, and MQTT's PUBLISH flags packing and `.rawValue` hops. Positions are
constants, so the range checks fold: NativeZip's central-directory parse is 1% fewer instructions than
before (4,907 vs 4,960 K, baseline `bytes` → `safe-parse`).

## Decoder support (driven by NativeZip's DEFLATE decoder)

Writing a DEFLATE decoder on `Bytes` (`../NativeZipArchive`, `Inflater.swift`; it beats zlib, 13 vs 14 ms
for 32 MB of text, 0 allocations; details in that package's RESULTS.md, step6) needed these additions:

- **`BitBuffer`**: 64 bits in a register, a branch-free refill (one unaligned load, `bits |= word << count`,
  `next += (63 - count) >> 3`, `count |= 56`), and no per-read end check: past the data it reads zeros,
  and `isOverrun`/`finish()` reports it once per block. Both bit orders. `BytesReader.withBitBuffer` and
  `finish()` convert back to a cursor.
- **`HuffmanTable`**: a canonical-code table for both bit orders (DEFLATE/Brotli least significant bit
  first, JPEG most), and the generic `HuffmanTable.build(…into:invalid:symbol:subtable:)` that fills a table
  of the caller's own entry type. It's libdeflate's builder: root entries written once, doubled with
  `memcpy`. Moving the inflater's private builder onto it cost nothing measurable (14 vs 14 ms small files).
- **`BytesWriter.copy(fromDistance:count:)`** (exact) and the `allowingOverrun:` variant that moves 16 or
  8 bytes at a time and may write `copyOverrun` (32) bytes past the copy; `write(_:byteCount:allowingOverrun:)`
  for word-sized stores; `skip(byteCount:)`.
- **`bitReversed`** on `UInt8`–`UInt64` and `Bits` (`Builtin.int_bitreverse`, one `rbit`).
- **`peekBitWindow()`** on `BytesReader`, **`bitPosition`** and **`seek(toBitPosition:)`** (a resumable decoder
  stores one integer: `seek(toByteOffset:)` + `skip(bitCount:)` before).
- **`[UInt8](copying: RawSpan)`**.

Inlining was the main lesson: `@inline(__always)` is a hint, and LLVM's inliner refused it for the match
copy in a large function, which then took the writer by address and kept it in memory: 2x slower. The hot
decoder APIs are `@inline(always)` (SE-0496, guaranteed), and the decoder keeps its `BitBuffer` and
`BytesWriter` as locals of small functions.

API review afterwards: `BitBuffer.peek(_:)`/`consume(_:)` renamed `peek(bitCount:)`/`consume(bitCount:)`,
matching `BytesReader.peek(bitCount:)`, `read(bitCount:)`, and `skip(bitCount:)`. Considered and not added: a
byte-sized write overload (`write(Byte(…))` is what the inflater's literal path uses), and a sliding-window helper
for the writer (NativeZip alternates two buffers, which a single-writer helper doesn't fit).

## Review fixes

A review of the whole library found two bugs, both fixed with regression tests:

- **Bulk reads of a `ByteGroup` defined outside the package** with a wider `Integer` than the lane (e.g. a
  5-byte group over `UInt128`) stored NEON lanes into the wrong slots and left values uninitialized. The
  NEON paths now also require the integer to be the lane size; the check folds to a constant.
- **An over-long LEB128 at the end of the data** (`80 80 80 80`, limit 4) threw `insufficientData`, so a
  streaming parser would wait for bytes that can't help. It now throws `invalidValue`. So does a length
  prefix too large for an `Int`.

Smaller fixes: `Bits >>` with a negative count is masked like `<<`; `<<=`/`>>=` added; `isSet(at:)` removed
(the `bit:` subscript does it); `seek(toByteOffset:)` throws for a negative offset; `read(section:)` renamed
`readSection(byteCount:)`; the LEB128 section writer's `maxByteCount` is now required (a default of 10
always moved the section); unused code removed; docs corrected where they overstated guarantees.

## Writing (`BytesWriter`)

`BytesWriter` mirrors `BytesReader`: `write` for `Bits`, byte groups with a byte order, `ByteRepresentable` types,
raw-value types, and spans, `store` for standard library types (native order), and bulk writes from spans
or from a closure (`write(Byte4.self, .bigEndian, count: n) { index in … }`, the counterpart of `forEach`).
It writes into a `MutableRawSpan`, or into uninitialized memory with `output.withBytesWriter { … }` on
`OutputSpan<UInt8>` / `OutputRawSpan`. Every store stays within the bytes being written (odd widths use
two overlapping stores of the next size down, mirroring the loads), so it never touches memory past its
cursor; a throwing write writes nothing.

### Should reading and writing share one type? No.

A combined reader/writer has to hold the memory exclusively (`MutableRawSpan`), so any span it hands out
can only borrow the cursor itself, not the memory. That breaks the fixed-size-record idiom: with a
prototype, `let header = cursor.read(byteCount: 4)` followed by another read from `cursor` is a compile
error ("overlapping accesses to 'cursor'"), while the same code with `BytesReader` compiles. Reading
through a `MutableRawSpan` would be no faster either: the loads are identical. So `BytesReader` reads
shared memory and hands out spans that outlive it; `BytesWriter` writes exclusive or uninitialized memory.
Patching data in place is a `BytesReader` pass and a `BytesWriter` pass over the same memory, one after the other.

### Write bandwidth (GB/s, p50; baseline `writes4`)

Values are generated from their index (a cheap hash), so no memory is read. The ceiling is `memset`.

| Width | In cache | Memory, 1 core | Memory, 32 cores |
|---|---|---|---|
| `memset` (reference) | 125 | 120 | 241 |
| Raw SIMD store (reference) | 116 | 116 | 239 |
| `IPv4Address` (custom, 4 bytes) | 108 | 104 | 239 |
| `Byte2`, `Byte4` | 89 | 85–88 | 239–241 |
| `Byte` / `Nibble` / `Crumb` / `Bit` | 74 / 45 / 18 / 10 | 75 / 44 / 18 / 11 | 231–241 |
| `Byte16` | 73 | 73 | 239 |
| `Byte8` | 36 | 37 | 239 |
| `Byte10`, `Byte12`, `Byte14` | 34–47 | 34–45 | 210–219 |
| `Byte3`, `Byte5`–`Byte7`, `Byte9`, odd `Byte11`–`Byte15` | 16–30 | 15–29 | 213–238 |
| `Bits<3>`, `Bits<5>`–`Bits<7>` | 2.7–3.8 | 2.8–3.9 | 65–87 |
| Per-value loops: `Byte4` / `IPv4Address` / `Byte16` / `Byte` | 87 / 104 / 75 / 55 | 87 / 107 / 69 / 54 | — |
| Per-value loop: `Nibble` (bits one at a time) | 0.4 | 0.4 | — |

- Power-of-two widths and 4-byte custom types write at or near one core's ceiling, and all byte groups
  plus `Bit`/`Crumb`/`Nibble`/`Byte` reach the all-core ceiling (210–241 GB/s).
- Plain loops of single writes vectorize when the writer is a local, like reads.
- Writing bits one at a time can't be fast: each write merges with the byte the previous one left partly
  written. The generating bulk write packs a byte (or 8-value block) at a time instead: 110x faster for
  nibbles.
- Odd widths are compute-bound on one core, like reads. Making them memory-bound needs byte shuffles
  (NEON `tbl`), which Swift can't express: the standard library's SIMD swizzle compiled to a scalar loop
  (0.3 GB/s in a test, against 16.7 for overlapping stores), and `Builtin` doesn't expose target-specific
  intrinsics. A C module with NEON intrinsics in `static inline` functions would.
- `Byte8` is scalar for the same cost-model reason as `Byte16` reads (two 64-bit lanes).

Fixes found while measuring (all in `BytesWriter`):
- The unaligned slow path was a `mutating` method; like the reader's early version, that kept the writer
  in memory in every caller and blocked vectorization. Now `static`, taking and returning the position.
- Bit writes reloaded the partly written byte from memory (store-to-load forwarding on every write); the
  writer now keeps it in a register.

Harness lessons: the first runs measured the benchmark, not the writer. Index-derived values folded into
repeating patterns (`Bit` writes became a constant fill), a 64-bit multiply in the value generator doesn't
vectorize, and passing the writer `inout` to an inner closure let the compiler merge the outer closures into
one thunk that called the inner one indirectly (0.6 GB/s for byte writes, against 54 with a local writer).

## Convenience APIs

`Bits` values have `value[bit: i]` (get and set, bit 0 the least significant), `toggleBit(at:)`,
`nonzeroBitCount`, shifts, compound bitwise operators, and conversions between widths. `Byte`, `Nibble`,
and `Crumb` have `highHalf`/`lowHalf` (get and set) and `init(highHalf:lowHalf:)`; even-width byte groups
have `lowHalf`/`highHalf` in memory order (like SIMD) and settable bytes. Enums and other `RawRepresentable`
types with integer raw values read from and write to bit fields or byte groups
(`reader.read(QualityOfService.self, as: Crumb.self)`), throwing `.invalidValue` for undefined values.
They compile to what you'd write by hand: setting a nibble half is `and` + `orr`, setting or toggling a bit
one `orr`/`eor`, a `Byte4` half one `lsr`.

## NEON byte shuffles (`NEONShuffle` trait, CBytesNEON C module)

Superseded in part (2026-11-12): `GroupShuffle`, portable constant shuffles, now handles these widths for
iterators (`for`-`in`) in every build, and for bulk reads, writes, and staged `forEach` wherever
`ByteLanes.isLookupVectorized` is false. This section describes the NEON `Shuffle`, still used otherwise.

3-, 5-, 6-, and 7-byte groups can't use contiguous vector loads and stores: each value straddles lanes.
NEON's table lookup (`tbl`, up to 64 bytes of table per instruction) packs and unpacks them, but Swift
can't reach it: the standard library's SIMD swizzle compiled to a scalar loop, and `Builtin` doesn't expose
CPU-specific intrinsics. So a small C target, CBytesNEON, wraps `vqtbl1q_u8`–`vqtbl4q_u8` in `static
inline` functions over a vector type Swift imports as `SIMD16<UInt8>`; Swift inlines each to a single
`tbl.16b` instruction. Other CPUs get a portable fallback with the same results. It's behind the
`NEONShuffle` package trait, on by default (`--disable-default-traits` turns it off; the 36 tests pass
both ways).

Values travel in 32-bit lanes (3-byte groups, 16 per step) or 64-bit lanes (5–7 bytes, 8 per step), so a
step is always 64 bytes of lanes: one 4-register table. Packing turns them into the step's 48, 40, 48, or
56 bytes with 3–4 lookups; unpacking does the reverse, and the index vectors apply the byte order, so
big-endian is free. Reads take the shuffle path only while 64 bytes remain (each step loads 64 bytes), and
the existing loops finish the tail.

Trait on against off, same session (GB/s, one core, from memory; baselines `neon-on`, `neon-off`):

| Workload | Off | On |
|---|---|---|
| Bulk read `read(_:_:into:)`, big-endian `Byte3` | 19 | **47** (2.5x) |
| … `Byte5` / `Byte6` / `Byte7` | 21 / 26 / 29 | **42 / 50 / 51** (1.8–2x) |
| Generating write, big-endian `Byte3` | 19 | **46** (2.4x) |
| … `Byte5` / `Byte6` / `Byte7` | 16 / 19 / 21 | **23 / 29 / 28** (1.3–1.5x) |
| `forEach` / `for`-`in` over `Byte5`–`Byte7` | — | −41 to −49% instructions, up to 12% faster |

With all cores, the 5–7-byte writes now reach the memory ceiling (2.25 ms per 512 MB, from 2.5).

Where it isn't used:
- `forEach` over `Byte3`. Its plain loop already vectorizes with `ld3` together with the caller's body;
  unpacking first and calling the body once per lane kept the body scalar: 5x slower, measured. For 5–7
  bytes, whose plain loop barely vectorizes, unpacking still wins, but the per-lane body calls cap it.
- 9–15 bytes: a step's lanes span more than 64 bytes, so each output would need two lookups and a merge.
- Writes of 5–7 bytes are limited by building 64-bit lanes from the generated values (two per vector),
  not by the lookups.

## Review (baseline `reviewed`)

An independent review brute-forced the bit paths (every `read(bitCount:)` count 0–64 at every bit offset on
1–40-byte spans, every `write(_:bitCount:)` round trip, `Byte16` search from every start, exact-capacity
writes) with no mismatches, and checked each `Builtin.assume` against every path that moves the offsets.
It found, and these are fixed with regression tests:

- Force-unwrapped base addresses of empty spans with no memory: writing `Data().span` and bulk reads into
  an empty `OutputSpan()` trapped. (Also `Span(viewing:)` checks alignment even for an empty span, so a
  zero-count typed view now returns `Span()`.)
- A zero-size `RawBytes` divided by zero (now a precondition that folds away).
- The 9–15-byte custom-type load assumed a little-endian host (now `#if _endian(little)`).
- Bit iteration starting mid-byte never returned to the block path; it now reads single values until a
  byte boundary. Doing that for whole bytes (which never realign) cost `for`-`in` over `Byte` 30% just by
  being in the code, so it's compiled out for width 8.
- Policy: values too large for the field they're written as now assert in debug builds and truncate in
  release (bulk writes truncate without the check, which would stop their loops vectorizing).
- A stale comment, missing invariant hints on a few entry points, the writer's 56- vs reader's 57-bit split.

Kept as is, deliberately: `forEach` consumes while `for`-`in` doesn't (now documented on both: the cursor
must be a `var` to call it, so the mutation is visible), and `read(_:count:) -> Span<T>` keeps the `read`
verb, matching `read(byteCount:) -> RawSpan`.

Instruction counts are identical before and after across every read, field-parsing, and bandwidth
benchmark; wall times are within run-to-run noise.

## Custom byte-backed types (`ByteRepresentable`)

Types like an IPv4 address backed by `InlineArray<4, UInt8>` conform by exposing `rawBytes` and
`init(rawBytes:)`. Swift 6.4 doesn't let user types conform to `ConvertibleFromBytes`, so they can't be
loaded from raw memory directly; their `RawBytes` (`InlineArray<N, UInt8>`) can. Reading one is a bounds
check, one load, and `init(rawBytes:)`, which compiles away when it only stores its argument.

The loads matter, measured case by case (baselines `ipv4`, `vectorized`, `final3`):

- Loading `InlineArray<4, UInt8>` as itself compiles to four `ldrb`s plus repacking. Sizes 1, 2, 4, 8,
  and 16 are now loaded as the same-size integer and reinterpreted with the standard library's `bitCast`
  (free: a size precondition that folds, then `Builtin.reinterpretCast`): one `ldr`, the same instructions
  as reading a raw `Byte4`.
- 9–15 bytes: two overlapping 64-bit loads into a `UInt128`, reinterpreted through memory. 62 GB/s, against
  24 for a direct load of a 12-byte type.
- 3 and 5–7 bytes: a direct load. The same trick through a narrower integer measured slower (14 against
  31 GB/s for 6 bytes): its stack slot stayed in the loop. Vector-instruction counts said otherwise;
  benchmarks decided.

| Custom type (1 core, GB/s: in cache / memory) | Custom | Same bytes as a raw `ByteGroup` |
|---|---|---|
| IPv4, 4 bytes, `forEach` | 114 / 78 | 99–113 / 78 |
| IPv4, a loop of `read(IPv4Address.self)` | 113 / 78 | 113 / 78 |
| IPv4, naive: four `read(Byte.self)` into an `InlineArray` | 3.7 / 3.7 | — |
| IPv6, 16 bytes, `forEach` | 111 / 74 | 112 / 74 |
| MAC, 6 bytes, `forEach` | 31 / 31 | 28 / 29 |
| 12 bytes, `forEach` | 61 / 58 | 59 / 58 |
| 3 bytes, `forEach` | 11 / 11 | 11 / 11 |

Every custom size parses at the speed of its raw bytes, and the 4-, 8-, and 16-byte ones at memory speed.

### Making loops of single reads vectorize

A plain loop of `read` calls (`while reader.remainingByteCount >= 4 { … try reader.read(…) … }`) was
scalar, 14 GB/s, for raw `Byte4` and `IPv4Address` alike. Cause: one of the four `Builtin.assume`
invariants, `_byteOffset >= 0`, stops LLVM from vectorizing such loops (tested one at a time; the other
three don't). Dropping it: those loops vectorize (14 → 113 GB/s in cache), at the cost of 11% more
instructions in the zip-header field parser (263 → 291 K; wall time within noise; the fixed-size-record
style unchanged at 253 K).

Also from the assembly review:
- `forEach` is now `@inline(__always)`. For `Byte16` (the largest body) the optimizer had outlined it into a
  closure-specialized function, which keeps the closure's captured variables in memory (a store every
  iteration) and blocks vectorization. Force-inlining keeps them in registers.
- `Byte16` keeps a single 128-bit load. Building it from 64-bit halves, as for 9–15, made big-endian
  `Byte16` loops fully scalar (32 against 56 GB/s). Its loads and byte swaps stay scalar either way
  (`ldp`, two `rev` on general registers), because LLVM's cost model declines two-lane 64-bit vectors for
  them, and Swift has no loop pragmas to override it. Only the benchmark's sum is vectorized, fed through
  `fmov`/`mov.d`, which is why `Tools/loops` calls the loop `vector128` (2026-11-09: no SIMD loads at run
  time). It reaches 56 GB/s on one core and the memory ceiling with all cores.

## The standard library's `ConvertibleFromBytes`

Only standard library types can conform (integers, `Float16`/`Float`/`Double`, `Duration`, `SIMD2`–`SIMD64`,
and `InlineArray`s of them), but `BytesReader` can read those (baseline `zerocopy`):

- `load(_:)`: one value in native byte order (little-endian on Apple), from any offset, e.g.
  `Float`, `SIMD4<UInt8>`, `InlineArray<4, UInt8>`. Same loads as `ByteRepresentable` (integer-sized values
  through `bitCast`). A loop of `load(Float.self)` vectorizes: 99 GB/s in cache, 77 from memory.
- `read(_:count:) -> Span<T>`: a typed view of the input, no copying, via `Span(viewing:)`. It throws
  `.misaligned` where the memory isn't aligned for `T` (a misaligned view traps in the standard library);
  alignment-1 types such as `InlineArray<N, UInt8>` work at any offset.

| 1 core, GB/s (in cache / memory) | Zero-copy span, `for`-`in` | `forEach` | Decoding view, `for`-`in` |
|---|---|---|---|
| `InlineArray<4, UInt8>` | 113 / 76 | 113 / 77 | 42 / 42 |
| … building `IPv4Address(rawBytes:)` per element | 111 / 76 | 113 / 77 | — |
| `UInt32`, aligned | 113 / 77 | 110 / 77 | 42 / 42 |
| `InlineArray<6, UInt8>` | 17 / 17 | 33 / 31 | — |
| `InlineArray<16, UInt8>` | 30 / 32 | 112 / 73 | 33 / 32 |

So a zero-copy span closes the `for`-`in` gap for 4-byte elements (2.7x the decoding view, equal to
`forEach`), but not for 6 or 16: the loop loads each element through `Span`'s subscript as a byte
aggregate, the same problem `Load.rawBytes` solves with `bitCast`, and LLVM only merges those byte loads
for 4 bytes. The library can't change how `Span` loads its elements; `forEach` stays the path that's at raw
speed for every size.

## `for`-`in` (`Iterable`)

`BytesReader` conforms to the standard library's `Iterable` (macOS 27): `for byte in reader` iterates the unread
bytes as one zero-copy `Span<UInt8>`, at 111–113 GB/s in cache and 77–78 from memory, the same as the raw
SIMD read. `reader.values(of: Byte4.self, .bigEndian)` and `reader.values(of: Nibble.self)` return typed
`Iterable` views. Their iterators decode 1,024 (groups) or 4,096 (bits) values at a time into a buffer
they own and hand out a span of it, with the same vectorized decode loop as `forEach`; the loop over
each span vectorizes too.

| 1 core, from memory (GB/s) | `forEach` | `for`-`in` |
|---|---|---|
| `Byte`, `Byte2`, `Byte4`, `Byte8` | 72–77 | 39–54 |
| `Byte3`, `Byte5`–`Byte7` | 19–30 | 15–21 |
| `Byte9`–`Byte16` | 34–56 | 17–31 |
| `Nibble` / `Crumb` / `Bit` | 50 / 27 / 12 | 26 / 12 / 2.7 |

Typed `for`-`in` costs up to 2.5x (4.4x for `Bit`) with a trivial loop body: `Iterable` hands out spans of
elements in memory, so decoded values are stored and reloaded (a 16-byte store per cycle limits it to
roughly 45–60 GB/s), where `forEach` fuses load, decode, and body. The heavier the body, the less it
matters. Raising the span size from 256 values helped the narrow widths (`Byte` 40 → 55, `Nibble` 17 → 25).

Swift 6.4 rejects `for x in reader.values(...)` with a temporary: "lifetime-dependent variable escapes its
scope". The standard library's own `for x in array.span` fails the same way. Bind the view to a `let` first.

The views are `Copyable`, so a `let` costs nothing. `for byte in reader` over a `let reader` (`~Copyable`)
heap-allocates the cursor once per loop: a compiler issue, see "Allocation checks". Use a `var` reader.

## `@frozen`

Removed from every type: it only matters with library evolution (binary frameworks), which SwiftPM
doesn't enable. Instruction counts were identical with and without it; leaving types unfrozen keeps their
layouts free to change until there's an ABI to keep.

## Read bandwidth: every width, 1 bit to 16 bytes

`forEach(_:_:)` iterates every value of a width; `Benchmarks/BytesBenchmarks/Bandwidth.swift` runs it over
4 MB (resident in L2: the code's own ceiling), 512 MB from one core, and 512 MB from all 32 cores (16 chunks
per core, each with its own cursor). Each value is added into a wrapping sum of its own width (two 64-bit
halves for 128-bit values), and byte groups are read as `.bigEndian`, so every value costs a byte swap
and an add. The `Bandwidth (MB/s)` column in the benchmark output is bytes read per second, per iteration.
Baselines: `bandwidth` (first run), `bandwidth2` (final).

### The ceiling

| | Read bandwidth |
|---|---|
| Advertised (M3 Ultra, LPDDR5-6400, 1,024-bit) | 819 GB/s, shared by CPU, GPU, and Neural Engine |
| CPU, measured: 128-byte SIMD loads, 4 GB, 1 thread | 72 GB/s |
| CPU, measured: same, 16–32 threads (saturates at 16) | **245–250 GB/s** |

The CPU clusters' links to the memory fabric cap them at about 30% of the spec-sheet figure (the rest is
there for the GPU), so ~249 GB/s is the "system maximum" a CPU reader can reach, and ~72–77 GB/s is one
core's. Scaling: 1 thread 72, 2 → 133, 4 → 195, 8 → 205, 16 → 245, 32 → 244 GB/s.

### Results (GB/s, p50)

| Width | In cache, 1 core | Memory, 1 core | % of 1-core raw (77) | Memory, 32 cores | % of CPU ceiling (249) |
|---|---|---|---|---|---|
| Raw SIMD read (reference) | 112 | 77 | 100% | 229 | 92% |
| `Bit` | 12 | 11 | 14% | 237 | 95% |
| `Crumb` | 28 | 28 | 36% | 236 | 95% |
| `Bits<3>` | 12 | 12 | 16% | 237 | 95% |
| `Nibble` | 49 | 50 | 65% | 236 | 95% |
| `Bits<5>` | 7.0 | 6.7 | 9% | 157 | 63% |
| `Bits<6>` | 8.4 | 8.3 | 11% | 184 | 74% |
| `Bits<7>` | 9.1 | 9.7 | 13% | 212 | 85% |
| `Byte` | 113 | **77** | **100%** | 235 | 94% |
| `Byte2` | 108 | **75** | **97%** | 235 | 94% |
| `Byte3` | 19 | 19 | 25% | 237 | 95% |
| `Byte4` | 106 | **75** | **97%** | 231 | 93% |
| `Byte5` | 21 | 21 | 27% | 235 | 94% |
| `Byte6` | 26 | 26 | 34% | 236 | 95% |
| `Byte7` | 30 | 30 | 39% | 237 | 95% |
| `Byte8` | 106 | **75** | **97%** | 228 | 92% |
| `Byte9` | 36 | 37 | 48% | 236 | 95% |
| `Byte10` | 34 | 35 | 45% | 238 | 96% |
| `Byte11` | 39 | 39 | 51% | 230 | 92% |
| `Byte12` | 38 | 42 | 55% | 235 | 94% |
| `Byte13` | 44 | 45 | 58% | 238 | 96% |
| `Byte14` | 48 | 48 | 62% | 237 | 95% |
| `Byte15` | 53 | 52 | 68% | 232 | 93% |
| `Byte16` | 54 | 56 | 73% | 235 | 94% |

- **With every core, every width but `Bits<5>`–`Bits<7>` reads at 92–96% of the CPU's memory ceiling**, the
  same as the raw SIMD reference: memory, not decoding, is the limit.
- **On one core, the power-of-two widths (`Byte`, `Byte2`, `Byte4`, `Byte8`) read as fast as raw loads.**
  Everything else is compute-bound on one core (its in-cache speed is no faster than its memory speed):
  odd strides can't use contiguous vector loads, and the bit widths do several operations per value. In
  values per second the bit widths are fast (`Bit` at 11 GB/s is 88 billion values/s, ~22 per cycle), but
  a byte holds 8 of them, so `Bit` needs ~7 cores to match one core's raw reads (77 GB/s); with all cores
  it reaches the ceiling (237 GB/s).
- `Bits<5>`–`Bits<7>` are the slowest: values straddle bytes irregularly, so they're extracted from 64-bit
  blocks with only two lanes per vector register.

### Vectorization, checked in the assembly

Every width's `forEach` loop vectorizes (probe functions compiled with `swiftc -O -S`, both bit orders).
Getting there took four changes, all in the library:

| Change | Effect (1 core, from memory) |
|---|---|
| `Byte9`–`Byte15` built from two independent 64-bit halves, and a `.bigEndian` for 128-bit groups computed on the halves (now a protocol requirement, so generic code uses it) | were scalar (LLVM doesn't vectorize 128-bit arithmetic); now vectorized with `rev64.16b`/`usra.2d` |
| Bit widths that divide 8 iterate per byte instead of per 8-value 64-bit block: 16 lanes instead of 2 | `Byte` 12 → 77, `Nibble` 6.0 → 50, `Crumb` 3.9 → 28, `Bit` 2.0 → 11 |
| `Bits<3>` blocks as 3 bytes in 32-bit lanes, loaded bytewise: NEON `ld3` de-interleaves 48 bytes at once | 2.6 → 12 |
| Stride-3 groups (`Byte3`) loaded bytewise in streaming loops (`forEach`, `read(_:_:into:)`), also `ld3` | `Byte3` 13 → 19; bulk `Byte3` decode −53% instructions |

Separately, the benchmark's consumer changed from a 64-bit sum to a sum in each type's own width: widening
every `UInt16` to 64 bits made the consumer, not the reader, the bottleneck (`Byte2` 37 → 75 GB/s).

Tried and rejected: loading 5-byte groups bytewise (9.2 GB/s, against 22.5 with overlapping loads: there's
no `ld5`), and 6-byte groups as three 16-bit loads (22 against 27).

## v1: first complete implementation

| Workload | Bytes | Comparator |
|---|---|---|
| Zip fields | 22 µs, 439 K instr | `ByteReader` 19 µs, 283 K |
| Bit fields | 127 µs, 2,378 K instr | buffer reader 317 µs, 8,245 K |
| Search | 2.0 µs | 33 µs |

Assembly review (see "Assembly findings" below) found the two problems behind the field-parsing gap.

## v2: inlining, value-taking slow paths, `Builtin.assume`

- Slow paths (`_unalignedBytes`, `_partialWindow`) take plain values instead of borrowing `self`. Borrowing
  forced every caller to spill the whole 40-byte cursor to the stack to pass its address, even on the
  aligned fast path.
- `read(byteCount:)`, `skip`, and the bit reads are `@inline(__always)`: `read(byteCount:)` wasn't inlined,
  which spilled the cursor around each call.
- `Builtin.assume(0 <= byteOffset <= span.byteCount && bitOffset < 8)` at each entry point. Bounds checks are
  `span.byteCount &- byteOffset >= n`, and with wrapping arithmetic LLVM couldn't simplify consecutive ones;
  with the invariant it compares each field's end offset against a hoisted constant (4 instructions per
  field down to 3, the remaining `add` doubling as the load address).
- `Range(uncheckedBounds:)` for `read(byteCount:)`, dropping `Range`'s own precondition.

| Workload | v1 | v2 |
|---|---|---|
| Zip fields | 439 K instr | 287 K (−35%), now equal to `ByteReader`'s 283 K |
| Bit fields | 2,378 K instr, 127 µs | 886 K (−63%), 111 µs |

## v3: harness fix

Every parser folded its fields into `checksum = checksum * 31 + value`: 13 dependent multiplies per record,
which took longer than the parsing and made all three field parsers 19 µs. A plain sum removes the chain;
the instruction counts barely move, but the time differences appear (table above). `Bytes` wins on time at
equal instruction count because every field load is `base + constant offset`, independent of the others,
while `ByteReader` advances a pointer field by field (`csel`, then post-increment `ldrh`), a serial dependency.

## Experiment: are the branch-weight hints worth it? (`no-expect`)

`likely`/`unlikely` (`Builtin.int_expect_Int1`) replaced with the bare condition: bit-field parsing used
14% more instructions (689 K → 787 K), with time within noise; field parsing within noise. Kept.

## Assembly findings (Apple clang/LLVM via `swiftc -O -S`)

- Byte-aligned `read(Byte4.self, .littleEndian)`: two `ldp`s of the cursor, a branch on the bit offset, the
  bounds compare, one `ldr`, and the offset store.
- `Nibble` read: fully inlined and branch-free; both bit orders computed and selected with `csel`.
- Fixed-size record (`BytesReader(try reader.read(byteCount: 46))`, then fields): no per-field checks at all,
  including paired loads (`ldp w7, w19, [x17, #16]`) for adjacent 4-byte fields.
- Bulk decode, `read(_:_:into:)`: autovectorized for every width tried. `Byte2` big-endian uses `rev16.16b`,
  `Byte4` `rev32.16b` (64 bytes per iteration with `ldp q0, q1`), and the odd-width `Byte3` still vectorizes
  its two overlapping loads with `ushll`/`orr`/`rev32`/`ushr`. The per-value `read(_:_:)` loop and a plain
  `RawSpan.load` loop vectorize identically, so the bulk API is for convenience and a guaranteed single
  bounds check, not speed.
- Search: the scalar early-exit loop doesn't vectorize (LLVM doesn't vectorize loops with data-dependent
  exits here). The SIMD version, written with `SIMD16<UInt8>`, lowers directly to `ldr q`/`ldur q`,
  two `cmeq.16b`, `and.16b`, `umaxv.16b`: 16 candidate offsets per ~9 instructions. No builtins needed.
- Constants such as `[0x50, 0x4B, 0x05, 0x06] as Byte4` fold to a single `mov`/`movk` pair at the use site.
