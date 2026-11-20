# Bytes and its projects: improvements from v1 to 2026-11-17

Every number below comes from one of these logs, named in the text by file and baseline or section:
`Bytes/Benchmarks/RESULTS.md` (cited as **Bytes**), `MQTT/Benchmarks/RESULTS.md` (**MQTT**),
`Bytes/Benchmarks/RESULTS-base64.md` (**Base64**; was `Base64/Benchmarks/RESULTS.md`), `NativeZipArchive/Benchmarks/RESULTS.md` (**NativeZip**),
`BinaryParsingComparison/RESULTS.md` (**BPC**), `SocketStream/RESULTS.md` (**SocketStream**), the 2026-11-17
tracking log (**tracking**), and `Bytes/OPTIMIZATION.md` (**OPTIMIZATION**). Commit dates are from `git log`.
Ratios in the "Factor" columns are computed from the two cited numbers. All runs: M3 Ultra, macOS 27.2,
Swift 6.4.2 (6.4.4 for 2026-11-17), release builds, p50 medians from package-benchmark.

## 1. Summary

Bytes began on 2026-11-06 (commit `f307047`) as a bit- and byte-level reading cursor whose field parser
ran 439 K instructions on a 2,000-entry zip directory, more than the hand-written `ByteReader` it was
compared with (283 K). Over twelve days it gained a writer, vectorized bulk paths for every width from 1
bit to 16 bytes, NEON and portable byte shuffles, a hardware CRC-32, DEFLATE/zlib/gzip and Brotli in both
directions (sequential and parallel), ChaCha20-Poly1305 and TLS 1.3 records, composable pipelines, byte
buffers, byte-aligned and byte-ordered cursors, named bit fields, and macros that generate record parsers.
Six packages were built on it or ported to it: MQTT, Base64, NativeZipArchive, BinaryParsingComparison,
SocketStream, and Bytes' own codecs. Most of the gains came from keeping cursors in registers (inlining,
slow paths taking values), letting LLVM vectorize (typed spans, arithmetic instead of tables, dropping one
`Builtin.assume`), reaching instructions Swift can't express through a small C target, and, late in the
work, from scheduling and stitching (parallel chunks, ChaCha20 with Poly1305). Instruction counts were the
primary measure throughout; times were trusted only from interleaved A/B runs.

### Headline table

| Area | Started at | Now | Factor | Sources |
|---|---|---|---|---|
| Zip directory, field by field (2,000 entries) | 22 µs, 439 K instructions | 11 µs, 301 K; then 284.6 K | 2.0x time, 1.54x instructions | Bytes "v1"; "Current" (`modern`); 2026-11-10 (`conv-new-*`) |
| Bit fields (8 fields of 1–32 bits, 128 KB) | 127 µs, 2,378 K | 40 µs, 706 K | 3.2x time, 3.4x instructions | Bytes "v1"; "Current" (`modern`) |
| Read bandwidth, `forEach` over `Byte`, 1 core from memory | 12 GB/s | 77 GB/s (equal to raw SIMD loads) | 6.4x | Bytes "Read bandwidth" (`bandwidth` → `bandwidth2`) |
| Read bandwidth, `Bit`, 1 core | 2.0 GB/s | 11 GB/s | 5.5x | same |
| Bulk read of big-endian `Byte3`, 1 core | 19 GB/s | 47 GB/s | 2.5x | Bytes "NEON byte shuffles" (`neon-off` → `neon-on`) |
| Generating write of big-endian `Byte3` | 19 GB/s | 46 GB/s | 2.4x | same |
| MQTT encode PUBLISH (10,000 packets) | 7.8 M instructions, 358 µs (v1); 9.7 M after full validation | 5,132 K | 1.52x fewer than v1, 1.89x fewer than `validated` | MQTT "v1", "What validation costs", 2026-11-16 (`p4-aligned`), 2026-11-17 (`trk-final`) |
| MQTT encode PUBLISH, 1 core | 18.5 M packets/s (`validated`); 20.9 M (`scan16`) | 35.2 M packets/s | 1.7x over `scan16` | MQTT "Current", "`MQTTPacket` out of the hot paths" (`dispatch1`) |
| MQTT parse PUBLISH views, every property | 15 M instructions, 676 µs (15 M packets/s) | 993 instructions per packet (9.93 M), then −0.9% | about 1.5x fewer instructions | MQTT "v1"; 2026-11-09 (`bcd-new-*`); 2026-11-16 (`p4-aligned`) |
| MQTT parse PUBLISH, per-type frames path | 19.0 M packets/s through the enum (`scan16`) | 30.0 M packets/s | 1.58x | MQTT (`scan16` → `dispatch1`) |
| Base64 encode, 1 MB / 64 B | 9.0 / 3.1 GB/s | 21.4 / 4.4 GB/s (`final`); 21.5 / 5.5 (`final2`) | 2.4x / 1.4–1.8x | Base64 "How it got here" (`v1`), "Current", 2026-11-10 |
| Base64 decode, 1 MB | 5.0 GB/s of text (first prototype kernel) | 12.8 GB/s of bytes (17 GB/s of text) | 3.4x | Base64 "A decoder", "Decoding" (`final2`) |
| Base64 decode, 64 B | 1,570 instructions per call | 359 | 4.4x | Base64 "Short inputs" |
| DEFLATE decode, inflate + CRC of 32 MB text (NativeZip) | 33 ms, 359 M (Compression.framework) | 12.9 ms (`native-crc`); 240 M instructions (`trk-final`) | 2.6x time, 1.5x instructions | NativeZip "baseline", step8, step14 |
| Bytes inflater against zlib | 2x slower (first version) | 13 against 14 ms; on pixel runs 9.2 against 9.8 ms | from 0.5x to 1.05–1.08x | NativeZip step6, step10 |
| DEFLATE decode, Main.js 3.8 MB (BytesCompression) | — | 1,894 µs (libdeflate 1,673, zlib 2,092), then −1.7 to −4% instructions | 13% behind libdeflate, ahead of zlib | Bytes 2026-11-15 (`final-1`), 2026-11-16 (`p4-aligned`) |
| DEFLATE encode, level 1, Main.js | 9,216 µs (`all-1`) | 9,011 µs (`final-1`); 135 M instructions, unchanged since | 1.02x; 12% behind libdeflate, about 2x zlib | Bytes 2026-11-15; second pass |
| DEFLATE encode, level 6, samba, 24 lanes | 135 ms on one core | 7.2 ms | 19x | Bytes second pass ("Parallel compression") |
| Zip extraction, 2,000 small files | 306 ms, 129 K mallocs | 105 ms, 14 K mallocs | 2.9x (mostly before Bytes: zlib, file system, worker width) | NativeZip "Benchmark summary: baseline → step4" |
| Zip central directory parse | 287 µs, 6.1 M (before any work); 5,861 K with `ByteReader` | 4,960 K with Bytes; 4,907 K now | 1.18–1.19x over `ByteReader` | NativeZip "baseline", step5, step14 |
| Brotli decode, q11 Main.js | 6,525 µs (`all-1`) | 3,826 µs (`p2-optimized`); Google 3,666 | 1.7x | Bytes 2026-11-15 and second pass |
| Brotli decode, q5 x-ray | 43,000 µs (`final-1`) | 29,000 µs (`p2`) | 1.5x | Bytes second pass |
| Brotli encode, q1 x-ray | 53,000 µs (`final-1`) | 21,000 µs (`p2`); Google 27,000 | 2.5x | Bytes second pass |
| CRC-32, hardware path | 3.5x slower than zlib (first version) | 532 µs for 32 MB (63 GB/s) against zlib's 888 µs; 2.3x zlib at 64 B | from 0.29x to 1.7–2.3x zlib | Bytes "`CRC32`"; NativeZip step8 |
| CRC-32, portable table path, 256 KB | 14.0–15.0 ms (slicing-by-8, shifts and masks) | 3,849 µs (braided) | 3.6–3.9x | Bytes "Group operations"; 2026-11-12 "fast portable builds" |
| ChaCha20-Poly1305 seal, 1 MB | 1,047 µs (`pipe-1`, about 1.0 GB/s) | 419–421 µs, 2.50 GB/s (interleaved A/B) | 2.5x; 2.7x CryptoKit's ChaChaPoly (`ck-final`) | Bytes 2026-11-15, 2026-11-17; OPTIMIZATION "ChaCha20-Poly1305" |
| SocketStream, 64 B payloads, 1 connection | 13.6 M packets/s (`initial`) | 22.4 M packets/s, 2.81 GB/s (`frames`) | 1.65x | SocketStream "Results" |
| SocketStream, in-memory protect with TLS | 1,162 µs (`trk-t0`) | 715 µs (`trk-final`) | 1.6x | SocketStream 2026-11-17 |
| Against swift-binary-parsing, zip field by field | 301 K against 461 K (1.53x); 11 against 23 µs | 285 K against 461 K (1.62x); `@BinaryRecord` 199 K against 325 K records | 1.53x → 1.62x | BPC "Results", 2026-11-09 re-check, 2026-11-17 (`trk-final`) |
| Against swift-binary-parsing, 24-bit values | — | 1,426 K against 4,461 K (3.13x); `forEach` 771 K | 3.1–5.8x | BPC 2026-11-09 re-check |

Two caveats on the table. The NativeZip extraction gains were made before Bytes existed (steps 1–4:
zlib, `DirectoryCache`, eight workers); Bytes' share there is parsing and, later, the inflater. And the
SocketStream TLS transfer itself was last measured at 840 MB/s (`protected-1`), before stitching; the
2.50 GB/s seal has been measured only in memory.

## 2. Timeline

### v1: first complete implementation (2026-11-06, commit `f307047`)

- `BytesReader` over a `RawSpan`, fields from `Bit` to `Byte16`. Zip fields 22 µs and 439 K instructions
  against `ByteReader`'s 19 µs and 283 K; bit fields 127 µs and 2,378 K against a buffer reader's 317 µs and
  8,245 K; a 4-byte signature search 2.0 µs against 33 µs (Bytes "v1").
- The assembly review found the two problems behind the field-parsing gap (Bytes "Assembly findings"):
  bulk decode already auto-vectorized for every width tried; the SIMD search was 16 offsets per ~9
  instructions; `Byte4` literal arrays folded to `mov`/`movk`.

### v2 and v3: inlining, value-taking slow paths, `Builtin.assume`, a harness fix

- Slow paths took plain values instead of borrowing `self`, which had spilled the 40-byte cursor in every
  caller; `read(byteCount:)`, `skip`, and the bit reads became `@inline(__always)`; `Builtin.assume` on the
  offsets let LLVM compare each field's end against a hoisted constant (4 instructions per field to 3)
  (Bytes "v2").
- Zip fields 439 K → 287 K (−35%), equal to `ByteReader`'s 283 K; bit fields 2,378 K → 886 K (−63%),
  127 → 111 µs (Bytes "v2").
- v3 removed a `checksum * 31 + value` chain from every parser in the harness, which had made all three
  field parsers 19 µs; times then separated at equal instruction counts (Bytes "v3").
- Branch-weight hints were tested by removing them: bit-field parsing ran 14% more instructions (689 K →
  787 K), so they stayed (Bytes "Experiment: are the branch-weight hints worth it?", `no-expect`).

### Read bandwidth and vectorization

Like v2 and v3, the log's sections from here to the safety pass are undated; by commit dates they fall between 2026-11-06
(`f307047`) and 11-08 (`eec4a92`).


- The ceiling was measured first: 72 GB/s for one core, 245–250 GB/s for the CPU clusters (Bytes "The
  ceiling").
- Four library changes made every width's `forEach` vectorize (Bytes "Vectorization, checked in the
  assembly"): `Byte9`–`Byte15` as two 64-bit halves; per-byte iteration for bit widths that divide 8
  (`Byte` 12 → 77 GB/s, `Nibble` 6.0 → 50, `Crumb` 3.9 → 28, `Bit` 2.0 → 11); `Bits<3>` through `ld3`
  (2.6 → 12); `Byte3` bytewise in streaming loops (13 → 19 GB/s, bulk decode −53% instructions).
- With 32 cores every width but `Bits<5>`–`Bits<7>` reads at 92–96% of the 249 GB/s ceiling (`bandwidth2`).
- Dropping the `_byteOffset >= 0` assumption made plain loops of `read` calls vectorize: 14 → 113 GB/s in
  cache, at +11% instructions in the zip field parser (263 → 291 K) (Bytes "Making loops of single reads
  vectorize").
- Custom types (`ByteRepresentable`): 1/2/4/8/16-byte types load as integers through `bitCast`; 9–15 bytes
  as two overlapping 64-bit loads (62 against 24 GB/s for a direct 12-byte load); an IPv4 address reads at
  113–114 GB/s in cache against 3.7 for four `Byte` reads (baselines `ipv4`, `vectorized`, `final3`).
- `BytesWriter` arrived with write bandwidth near `memset` for power-of-two widths (`Byte2`/`Byte4` 85–88 GB/s
  against `memset`'s 120 on one core; 210–241 GB/s on all cores for every byte group). Making its slow path
  static and keeping the partial byte in a register were the fixes; bulk nibble writes were 110x faster
  than per-value writes (Bytes "Writing", `writes4`).
- `for`-`in` through `Iterable`: the raw byte view at 111–113 GB/s in cache; typed views up to 2.5x slower
  than `forEach` (Bytes "`for`-`in`"). `@frozen` was removed from every type: instruction counts identical
  (Bytes "`@frozen`").

### NEON shuffles, and a review

- CBytesNEON wrapped `vqtbl1q_u8`–`vqtbl4q_u8` in `static inline` functions, each a single `tbl` in Swift,
  behind the `NEONShuffle` trait (Bytes "NEON byte shuffles", `neon-on`/`neon-off`):

  | Workload (1 core, from memory) | Trait off | Trait on |
  |---|---|---|
  | Bulk read, big-endian `Byte3` | 19 GB/s | 47 GB/s |
  | Bulk read, `Byte5` / `Byte6` / `Byte7` | 21 / 26 / 29 | 42 / 50 / 51 |
  | Generating write, `Byte3` | 19 | 46 |
  | Generating write, `Byte5` / `Byte6` / `Byte7` | 16 / 19 / 21 | 23 / 29 / 28 |

- An independent review (baseline `reviewed`) brute-forced the bit paths with no mismatches and fixed
  empty-span traps, a division by zero for zero-size `RawBytes`, a little-endian assumption, and mid-byte
  bit iteration; instruction counts were identical before and after.

### Safety pass, decoders, CRC-32, and the first consumers (commits `819c1ba`, `fa86687`, `ae7f9e7`, 2026-11-07)

- Safe constructs (Bytes "Safe constructs", `pre-safety` → `safe-final`): checked `extracting` in
  `read(byteCount:)` cut fixed-size records by 21% in instructions and 31% in time (253 → 199 K, 10.6 →
  7.3 µs) and cost field-by-field parsing 3% (291 → 301 K). `HuffmanTable` on `UniqueArray`/`Span` was
  equal. The loads, stores, match copies, and `BitBuffer`'s refill stayed unsafe, each with its measured
  cost (below).
- Decoder support for NativeZip's DEFLATE (Bytes "Decoder support"): `BitBuffer`, `HuffmanTable` (the
  libdeflate builder), `copy(fromDistance:count:allowingOverrun:)`, `bitReversed`. The inflater went from
  2x slower than zlib to 13 against 14 ms on 32 MB of text, 0 allocations (NativeZip step6). The main
  lesson was inlining: the match copy not inlined made it 2x slower; `@inline(always)` (SE-0496) fixed it.
- Integer literals for byte groups (`0x50_4B_03_04`): the first version, built with `init(bigEndian:)`,
  cost 41% more instructions on fixed-size records (281 against 199 K) through a lazy global; the literal
  initializer now reverses with shifts (Bytes "Integer literals").
- The table CRC rewritten with `ByteGroup` operators: 336 M → 180 M instructions at 256 KB, 64 B inputs
  12.0–12.7 → 8.8–9.4 ms (Bytes "Group operations").
- Hardware CRC-32 (`pmull`, `eor3`, `crc32x`): from 3.5x slower than zlib in its first version to 532 µs
  against 888 µs for 32 MB, 1.7–2.3x zlib across sizes (Bytes "`CRC32`"; NativeZip step8).
- NativeZip parsing on Bytes: the central directory 5,861 K → 4,960 K instructions (−15%), payload location
  −5% (NativeZip step5); bit-field subscripts took the directory to 4,907 K (−1%, step7).
- MQTT on Bytes (MQTT "v1", "Current", "16-byte scans", "`MQTTPacket` out of the hot paths"): views parsed
  PUBLISH at 15 M packets/s with 0 allocations, 5.5x the conventional parser; full MQTT 5.0 validation cost
  0 to +7 ns per parsed packet (depending on whether properties are iterated) and +19 ns per encoded one; `ByteLanes` 16-byte scans raised parsing 26–40%
  (`safe-final2` → `scan16`); per-type parse and write raised encoding 68% (20.9 → 35.2 M packets/s,
  `dispatch1`).
- swift-binary-parsing comparison (BPC "Results"): Bytes 2x faster field by field, 2.9x on 24-bit values,
  within 5% on QOI and LZ4; `atomically`, throwing integer conversion, and `signedInteger` were adopted.
- Allocation thresholds: 140 files at zero; one allocation found, `for` over a `let` `~Copyable` reader,
  traced to `AllocBoxToStack` (Bytes "Allocation checks"; report 22).

### 2026-11-09 to 11-12: API additions and the portable builds

- **Verification, 11-09** (Bytes, `modern`): instructions unchanged from `safe-final` in every row. The
  first run was on a loaded machine (5–15% slower times at equal instructions); a later run alone showed a
  median time change of 0.0%. The `literals3` numbers (292 / 197 / 48 K) didn't reproduce at HEAD (301 /
  199 / 50 K) although the parser's machine code was identical: a property of the benchmark binary.
- **MQTT flag bytes read whole** (MQTT, `before-modern` → `modern`): encode −7.9%, mixed stream −15.6%
  instructions; interleaved times within ±4% except the mixed stream, 4–5% faster.
- **`position`/`rewind(to:)` and cursors at an offset** (Bytes, `pos-fields-*`): `rewind` costs 3
  instructions per entry (+2%); `atomically` costs nothing when its closure calls an `@inline(__always)`
  function and +51% when the body is written inside it. MQTT parsing −0.4 to −1.1%; NativeZip raster
  inflate −1.2%; `decodeSymbols` 789 → 769 instructions once the writer initializer was always-inlined.
- **Runs, copies from a reader, short copies, minimal LEB128** (Bytes, `runs-copies-1`): QOI-style runs of
  3- and 4-byte elements −26% and −41% instructions; 0–15-byte literals −46%; 40–63-byte span copies −13 to
  −41% instructions, −34 to −57% time. In the consumers: LZ4 −26% instructions and −42% time, QOI
  `tricolor.qoi` −77% and −70%, MQTT PUBLISH encoding −10% and −13%, Base64 40–47 B −18%.
- **Short-distance back-references** (Bytes, `fu3-old-*` → `fu3-new-*`): distances 2–7 as runs, −69 to
  −77% instructions and −80 to −94% time on long matches; NativeZip's pixel-run inflate 227 → 141 M, 18 →
  9.2 ms, level with zlib's 9.8 ms (NativeZip step10).
- **Inline span writes, array builders, one-check prefixed sections** (Bytes, `bcd2-*`): prefixed sections
  96,559 → 74,207 instructions (−23%); MQTT encoding −3.0% instructions, −8 to −11% time; Base64 40–47 B −13%;
  the `ParserSpan` LZ4 port −15.6% from Bytes' output side alone.
- **Conveniences and lane shuffles, 11-10** (Bytes, `conv-*`, `builder-ab`): `read(Bool.self)`, signed
  reads, `forEachRecord`, `located(_:)`, `ByteLanes.deinterleave`/`interleave`/`lookup`; "Fields: Bytes"
  300.6 → 284.6 K (−5.3%). The array builder moved off the standard library's unspecialized allocation:
  1,696 → 1,228 K for 1,000 38-byte arrays (−27.6%); MQTT's copying benchmark had run 17.5% more
  instructions until then.
- **Base64 decoder, 11-10** (Base64 "Decoding", `final2`): 64 characters to 48 bytes in 49 instructions;
  12.8 GB/s, against 12.9 for the best C kernel and 12.5 for C of the same design; 4.2x Foundation from
  16 KB. The lever was table registers per `tbl`/`tbx`: an 80-character window (61 micro-ops against 69).
  Short inputs 1,570 → 359 instructions per call at 64 B.
- **The three builds, 11-12** (Bytes, `optimized-*`, `portable-*`, `portable-no-c-*`): the portable C
  fallbacks were 37–113x slower than NEON on one core; without the C modules, odd widths lost 1.1–2.9x.
- **Fast portable builds** (Bytes, `final-*`): `GroupShuffle`, constant `SIMD16` picks that compile to one
  shuffle, plus staging through a stack buffer; braided CRC tables. Bulk `Byte3` in the portable build
  8,485 → 88 µs; CRC-32 tables 256 KB 14,000 → 3,849 µs. Geometric mean against optimized: portable
  1.59 → 1.009, portable-no-c 1.055 → 1.016 (337 rows).
- **The optimized build adopts the portable iterator path** (Bytes, `cmp-*`): `for`-`in` over `Byte3`
  294 → 160 µs, over `Byte5`–`Byte7` 22–32% faster; optimized against old, geometric mean 0.988.

### 2026-11-15: BytesCompression, BytesCrypto, pipelines, and a second pass

- **First full results** (Bytes 2026-11-15, `final-1`; all Bytes rows 0 allocations in steady state):

  | Codec | Bytes against the reference |
  |---|---|
  | DEFLATE encode L1 | 6–14% slower than libdeflate on 376 KB and up, 26–34% on JSON; about 2x zlib; 4–6x Apple Compression |
  | DEFLATE encode L6 / L9 | 9–19% slower than libdeflate / equal (Main.js 56 against 59 ms) |
  | DEFLATE decode | 0–13% slower than libdeflate, about equal to zlib, 1.4–2x Apple |
  | Brotli decode | 17–67% slower than Google on 119 KB and up |
  | Brotli encode q5 / q9 | within 0–20% of Google / 1.6x faster (no context modeling: 7% larger) |
  | ChaCha20-Poly1305 seal, 1 MB | 690 µs (1.52 GB/s) against CryptoKit ChaChaPoly's 1,239 |
  | Pipelines | equal to two passes (Main.js 11,000 against 11,000 µs) |

- ChaCha20 on eight blocks (`SIMD8<UInt32>`) took 1 MB from 1.00 to 1.34 GB/s; Poly1305 in radix 2^64 (56
  → 43 instructions per 16 bytes) to 1.50 (harness). The adaptive Brotli tag filter cut x-ray q5 by 30% in
  instructions (3,575 → 2,495 M, `all-1` → `final-1`) without the 15% loss tags-always cost on dickens.
- Bugs found: the DEFLATE encoder's rebase compared with `==` and could be stepped over, after which no
  match was found (a socket stream grew from 14% to 62% of its input after 26 MB); fixed with `>=`.
  Indexing an `InlineArray` field copied it per access: DEFLATE L1 x-ray 153 → 55 ms once fixed.
- **Second pass** (Bytes, `ab-*`, `parallel-1`, `p2-*`):
  - Brotli decode −20 to −42% in the A/B: state in locals, masked indices, Huffman tables from used symbols
    only. Large inputs now within 12% of Google either side; short ones 7–33% behind (were 17–67%).
  - Brotli q1: a 6-byte hash and insertion of only each copy's last 5 positions: x-ray −62%, xml −32%;
    1–6% smaller output than Google's q1 on the five files measured, 18–31% slower on text.
  - `ChunkScheduler` replaced rounds in parallel compression: samba L1 5,198 → 3,090 µs (−41%), L6 9,202 →
    7,197 (−22%) in the harness; 24 lanes reach 14–19x one core for DEFLATE, 15–17x for Brotli.
  - A lazy-matching bug (a second delay could copy one byte past the data) found on samba at q5; fixed and
    covered by `copiesStopAtChunkEnds`.
  - DEFLATE encode and inflate unchanged instruction for instruction.
- SocketStream carried MQTT through these pipelines (SocketStream `protected-1`): TLS alone 840 MB/s at
  64 B payloads (0.67 GB/s before the ChaCha20-Poly1305 speedups), deflate + TLS 493 MB/s, plain 3,411 MB/s;
  0 allocations per packet in every configuration.

### 2026-11-16: buffers, matching in core, byte-aligned cursors

- **Buffer and copy API** (Bytes, `s1-before` → `s1-lib` → `s1-after`): `ByteBuffer`,
  `OutputRawSpan.append(copying:)`, `withFreeCapacity`, `copyBytes`, `withOutputRawSpan`. Unsafe pointer
  sites fell from 66 to 26 in BytesCompression, 10 to 2 in BytesCrypto, 5 to 0 in `Pipeline`, 9 to 1 in
  SocketStream's sources, with no instruction change beyond the reported resolution. SocketStream's
  Brotli + TLS unprotect −3.7% (27 → 26 M), from compacting only below half free.
- **Matching, bit writing, searching in core** (Bytes, `p3-before` → `p3-after`): `commonPrefixLength`,
  `BitWriter`, `ByteMatches`, `firstByteOffset`. Brotli q1 −1.8 to −2.5%, parallel inflate −1.7 to −3.1%,
  Base64 short decodes about −3 to −4%; the rest within ±1%.
- **Byte-aligned cursors** (Bytes, `p4-generic` → `p4-aligned`): one implementation generic over a mode;
  the refactor alone changed nothing. Adopted, it gave MQTT encode −6.1% (5,464 → 5,132 K), MQTT parse
  −0.9 to −2.9%, Base64 encode −1.5 to −7.7%, DEFLATE decode −1.7 to −4%, Brotli 1.6 KB decode −1.5 to
  −2.9%, QOI pixel-at-a-time −22% (5,874 → 4,567 K, BPC). QOI's run-filling decoder kept `BytesReader`.

### 2026-11-17: the proposals pass (baselines `trk-t0` … `trk-t5`, `trk-final`)

Every proposal from the 11-16 review, one step at a time, each step benchmarked in all six packages and,
at milestones, in all three builds (Bytes 2026-11-17; tracking):

| Step | What | Measured effect |
|---|---|---|
| t1 | `BitFlag`, `BitField`, `BitPattern` | Identical to hand-written shifts; an enum setter's `assert` + mask cost MQTT encode +0.8%, fixed in t2 |
| t2 | `read(_:asSigned:_:)`, `BigEndianBytes`/`LittleEndianBytes` cursors, MQTT parse-once | Ordered reads compile to explicit-order reads; MQTT parse visiting properties 8,831 → 7,365 K (−16.6%) |
| t3 | Adler-32 and `RunningChecksum` in core, `nibbleMask`, transform units, `BytesAsync`, `LentBytes` | NativeZip inflate + CRC −2.5 to −2.8% (decode loop 246 → 236 instructions); two regressions reverted |
| t4 | `BinaryParsable`/`BinaryWritable`, `BytesMacros`, `BytesFoundation` | `@BinaryRecord` zip directory 199 K, equal to the hand-written fixed-record parser (297 K before forcing the generated `init` inline) |
| t5 | Stitched ChaCha20-Poly1305 | Seal 1 MB 691–764 → 419–421 µs (−40%, 2.50 GB/s); instructions 8.77 → 8.64 M; SocketStream TLS protect −38% |

Everything else in all packages and all three builds stayed within ±0.5%. Sync parallel DEFLATE allocates
once more per call (11 → 12).

## 3. Tried and reverted, or not done

| Change | Measured | Outcome | Source |
|---|---|---|---|
| Removing branch-weight hints | Bit fields +14% instructions | Hints kept | Bytes `no-expect` |
| `Byte5` loaded bytewise; `Byte6` as three 16-bit loads | 9.2 against 22.5 GB/s; 22 against 27 | Rejected | Bytes "Read bandwidth" |
| `Byte16` from two 64-bit halves | Big-endian loops scalar, 32 against 56 GB/s | Single 128-bit load kept | Bytes "Making loops of single reads vectorize" |
| 3- and 5–7-byte custom types through a narrower integer | 14 against 31 GB/s (6 bytes) | Direct load kept | Bytes "Custom byte-backed types" |
| A combined reader/writer type | Fixed-size-record idiom becomes a compile error | Two types kept | Bytes "Should reading and writing share one type?" |
| NEON unpacking for `forEach` over `Byte3` | 5x slower (body stayed scalar) | Plain `ld3` loop kept | Bytes "NEON byte shuffles" |
| Bit iteration realigning for whole bytes | `for`-`in` over `Byte` −30% | Compiled out for width 8 | Bytes "Review" |
| Checked loads, stores, refill, `lowBytes` | +24% to 8x instructions; DEFLATE +10%; +46% | Kept unsafe, with comments | Bytes "Safe constructs" |
| `HuffmanTable` built in a nested function | +5% on small DEFLATE files | Static function | Bytes "Safe constructs" |
| Byte-group literal via `init(bigEndian:)` | +41% instructions (lazy global) | Shift-based initializer | Bytes "Integer literals" |
| CRC tables as `InlineArray`; split into halves | 7% slower; more instructions, same time | `[[UInt32]]`, later braided | Bytes "Group operations" |
| Inflater variants: 8-byte steps for all distances, unrolled byte copies, exact copies under 32, literal-pair table, adaptive literal runs, word-gathered literals | Literal pairs: small files 14 → 23 ms | All reverted | NativeZip step6 |
| 32 parallel extraction workers; archive-order batches; `openat` | +9% wall; no change; floor −6% | Width capped at 8; others not adopted | NativeZip step1, step2, step4 |
| Extra fields through `read(sectionPrefixedBy:)` under `try?`; `HuffmanEntry.extra` as a range subscript | +0.7%; loop grew 995 → 1,026 lines | Reverted | NativeZip step9 |
| Short-distance fill inlined in the decode loop | Loop 743 → 853 instructions, text +12–14% | Out of line | Bytes 2026-11-09 follow-ups |
| Distance 1 through the out-of-line fill | Long runs +21% | Inline `memset` kept | same |
| `keepingLowBits` in `write(_:bitCount:)`; `bits(from:upTo:)` for the subtable index | Loop 146 → 169 instructions; `decodeSymbols` +5 | Explicit masks kept | Bytes 2026-11-10; NativeZip step13 |
| MQTT: topic-name classification on a separate cursor; inlining `MQTTPacket(parsing:)`; `BitwiseCopyable` packets | +42 instructions; 4–9% slower; identical code | Reverted or not adopted | MQTT 2026-11-09, "`MQTTPacket` out of the hot paths" |
| Error-location wrapper closure; `atomically` per zip entry | +15%; +50% | Not adopted | BPC 2026-11-09 re-check |
| `GroupShuffle` for staged `forEach`, bulk reads, generating writes in the optimized build | +60–100% instructions; level; 1.25–2x slower | NEON kept there | Bytes 2026-11-12 (`cmp-*`) |
| Brotli: tags always on | dickens q5 166 → 191 ms | Adaptive per meta-block | Bytes 2026-11-15 |
| Brotli: breaking out of the scan at the first stale entry | Large inputs +3–5% | Newest-entry check instead | same |
| Brotli q1: Snappy-style skipping | x-ray 55.2 → 58.8 ms | Dropped | Bytes second pass |
| Brotli lazy step's search out of line; a third loop copy for large buckets | q3 +7.7% / q5 +5.4–5.6% | Both reverted | same |
| Parallel compression in rounds | 0.1–0.7 ms lost per round | `ChunkScheduler` | same |
| Checked `commonPrefixLength` in match finders | +3–18% (DEFLATE 6 dickens 1,311 → 1,401 M) | `unsafeCommonPrefixLength` | Bytes 2026-11-16 (`p3-prefix`) |
| Checked `BitWriter.flush()` in the encoders | +0.2–1.7% | `unsafeFlush()` | Bytes 2026-11-16 (`p3-bitwriter`) |
| Compile-time `BitBuffer` bit order | DEFLATE decode +0.5–3.6% | Not done | Bytes 2026-11-16 (`exp7-lsb`) |
| `BitBuffer.rewind` in Brotli's decoder | 1.6 KB streams +1–2 K instructions | New buffer kept; cause not found | Bytes 2026-11-16 |
| Aligned reader in QOI's run-filling decoder (and a `_slowPath` hint, an out-of-line fill) | +54% (22.2 → 34.3 G); 33.5 G; 35.4 G | `BytesReader` kept there | Bytes 2026-11-16 |
| Builders overloaded on the writer type; an `async` overload of `fill` | Ambiguous calls | Named apart; `receive` | Bytes 2026-11-16 |
| Enum field setter with `assert` + mask | MQTT encode +0.8% | `precondition`, unmasked store | Bytes 2026-11-17 |
| Properties validation through an empty `visit` closure, forced inline | MQTT parse −1%, SocketStream check +10.4% (PR toolchain) | Separate bodies | Bytes 2026-11-17 |
| Brotli tag filter on `nibbleMask` | q5 dickens +2.7% (2,463 → 2,529 M) | Reverted | Bytes 2026-11-17; tracking |
| `HuffmanCodeBuilder` in the core | Brotli 1.6 KB +1.3–1.7% (149 → 151 K) whatever the attribute | Moved back | same |
| Public unchecked loads; generic `withBitBuffer` | Codecs use `unsafeLoadUnaligned`; no callers | Dropped | same |
| NEON Poly1305 | Would compete with ChaCha20 for the vector pipes | Not pursued | same |
| DEFLATE compressor staging on `ByteBuffer` | Needs `BitWriter` slack and zero-copy swaps | Kept as is | same |
| Stitched path below 512 bytes | +180 instructions per 64-byte seal | Two passes kept there | OPTIMIZATION "ChaCha20-Poly1305" |
| Base64: remainder count computed directly; `SIMD8<UInt16>` for the alphabet's last vector | +3 instructions; 1 instruction and a little time worse | Not kept | Base64 2026-11-09 |
| Base64 decode with C `ld4`/`st3` | 12.9 against 12.5 GB/s (C, same design) | Not needed: Swift already at 12.8 | Base64 "The ceiling" |

## 4. The API as it stands, and when each part arrived

Dates are from the log sections; the undated early sections fall between the first commit (11-06) and
commit `eec4a92` (11-08).

| Type or API | What it is | Arrived |
|---|---|---|
| `BytesReader`, `Bits`/`Bit`/`Crumb`/`Nibble`/`Byte`, `Byte2`–`Byte16` | Bit-addressable cursor over a `RawSpan`; field types | v1 (11-06) |
| `BytesWriter` | Mirror of the reader over `MutableRawSpan` or `OutputSpan` | Early ("Writing") |
| `ByteRepresentable`, `ConvertibleFromBytes` loads, `Iterable` views | Custom types, zero-copy typed spans, `for`-`in` | Early |
| `ByteLanes`, CBytesNEON (`NEONShuffle` trait) | 16-byte scans, `tbl` lookups; later `deinterleave`/`interleave` | Early; lanes for Base64 on 11-10 |
| `BitBuffer`, `HuffmanTable`, `copy(fromDistance:…)` | Decoder building blocks | With NativeZip's inflater (11-07) |
| `CRC32` (CBytesCRC, `HardwareCRC` trait) | `pmull` folding, `crc32x` tail, braided tables elsewhere | 11-07; braided 11-12 |
| `atomically`, `signedInteger`, throwing integer conversion | From swift-binary-parsing | 11-07 (BPC) |
| `position`/`rewind(to:)`, `atByteOffset:` initializers | Rollback and offset cursors | 11-09 |
| `write(repeating:…)`, `write(from:byteCount:allowingOverrun:)`, `requiringMinimal:` | Runs, literal copies, minimal LEB128 | 11-09 |
| `[UInt8](byteCapacity:writing:)`, `readSectionIfComplete` | Builders, tolerant sections | 11-09 |
| `read(Bool.self)`, `readSigned`, `forEachRecord`, `located(_:)` | Field conveniences | 11-10 |
| `GroupShuffle`, traits `Portable` and default-off C | Three builds | 11-12 |
| `BytesCompression` (DEFLATE, zlib, gzip, Brotli, parallel), `BytesCrypto` (ChaCha20-Poly1305, TLS 1.3), `Pipeline`/`ByteTransform`, `ChunkScheduler` | Codecs and composition | 11-15 |
| `ByteBuffer`, `append(copying:)`, `withFreeCapacity`, `copyBytes`, `withOutputRawSpan` | Safe copies and a fill/drain buffer | 11-16 |
| `commonPrefixLength`, `BitWriter`, `ByteMatches`, `firstByteOffset`, `hasSuffix` | Matching and searching in core | 11-16 |
| `GenericBytesReader`/`GenericBytesWriter<Mode>`, `AlignedBytesReader`/`AlignedBytesWriter` | Byte-aligned mode with the bit state folded to 0 | 11-16 |
| `BitFlag`, `BitField`, `BitPattern`; `read(_:asSigned:_:)` | Named fields; signed reads (replaced `readSigned`) | 11-17 (t1, t2) |
| `BigEndianBytesReader`/`Writer`, `LittleEndianBytesReader`/`Writer` | Byte order in the type | 11-17 (t2) |
| `RunningChecksum`, Adler-32 in core, `BytesAsync`, `LentBytes` | Checksums, async stages, scoped lending | 11-17 (t3) |
| `BinaryParsable`, `BinaryWritable`, `FixedSizeBinary`, `BytesMacros` (`@BitFields`, `@BinaryRecord`), `BytesFoundation` | Formats as declarations; `Data` interop | 11-17 (t4) |

Renamed or removed on the way: `isSet(at:)` (the `bit:` subscript does it), `read(section:)` →
`readSection(byteCount:)`, `BitBuffer.peek(_:)`/`consume(_:)` → `peek(bitCount:)`/`consume(bitCount:)`,
`readSigned` → `read(_:asSigned:_:)`, `@frozen` on every type (Bytes "Review fixes", "Decoder support",
"`@frozen`", 2026-11-17).

## 5. Compiler and toolchain findings (reports 22–28)

From `~/Scratch/swift-bugs/README.md`. All are written with reproducers and marked "ready to file; not
filed"; three are to be posted as comments on existing issues.

| # | Report | Status |
|---|---|---|
| 22 | `for`-`in` over a `~Copyable` `let` heap-allocates it (the iterator's dependence blocks `AllocBoxToStack`) | Ready; new swiftlang/swift issue, cross-link #93942 |
| 23 | package-benchmark `thresholds check` can't find files for names with spaces and skips them | Ready; comment on ordo-one/benchmark#373 (already reported) |
| 24 | A trivial `~Escapable` struct with more than 6 leaf fields is still destroyed at `-O`, through its value witness table from other modules | Ready; new swiftlang/swift issue, cross-link #91781 |
| 25 | A typed-throws closure passed as an untyped generic `rethrows` parameter throws the wrong error silently, or crashes for tuple results | Ready; comment on swiftlang/swift#90291 |
| 26 | `ByteOrder` is `@frozen` but its synthesized `==` isn't inlinable (71 against 53 instructions) | Ready; new swiftlang/swift issue |
| 27 | `.macro` in a manifest without `import CompilerPluginSupport` reported as a type-check timeout | Ready; new SwiftPM issue, cross-link swiftlang/swift#89486 |
| 28 | `.span` of a throwing call's temporary result crashes LLVM verification at `-Onone` | Ready; comment on swiftlang/swift#94359 |

Not reported, but recorded as Swift 6.4 issues met (Bytes 2026-11-15 "Bugs found, and compiler issues";
OPTIMIZATION section 12): a `~Copyable` initializer freeing uninitialized `UniqueArray` fields in release
builds (not reduced); `SIMD16<UInt16>(truncatingIfNeeded:)` not inlined; `InlineArray` fields copied per
access; `Int16` store loops and `MutableSpan.update(repeating:)` compiled scalar; variadic `min` allocating;
cross-module optimization inlining a `deinit` that referenced an internal type; `SIMD16` scalar comparisons
compiled lane by lane (fixed in 6.5-dev); typed-throw sites checking OS availability.

## 6. How it was measured

Instruction counts from package-benchmark were the primary metric, because they are deterministic and
don't drift with machine load; wall times on this machine drift 5–10% between runs and transfers ±20%
(AGENTS.md), so a timing claim was accepted only from interleaved A/B runs of the old and new trees (built
from `git archive`, alternating `ab-old-1`, `ab-new-1`, …). Vectorization was checked in the machine code
(`Tools/loops`) and at run time (`Tools/counters --mode simd_fp_unit_instructions`), allocation freedom by
zero-malloc thresholds (140 files in Bytes alone). Bytes builds three ways (`optimized` with NEON and CRC
instructions, `portable` with the C fallbacks, `portable-no-c` in Swift only), and milestones were run in
all three. From 2026-11-16, every step was benchmarked in every package that uses Bytes (`trk-t0` …
`trk-final` in each), which caught five regressions that no single benchmark showed (OPTIMIZATION "What
tracking caught").

### Where sources disagree, or times were taken under load

- **SocketStream unprotect with TLS:** two spans, both right: 1,230 → 758 µs (−38%) from `trk-t0` to
  `trk-final` (the RESULTS files and OPTIMIZATION), 1,111 → 758 µs (−32%) for the stitching step alone (t4 → t5,
  the tracking log). Likewise Brotli or DEFLATE + TLS: −11 to −14% over the pass, −5 to −8% for the step. The
  step's times were taken while another agent's builds shared the machine.
- **ChaCha20-Poly1305 16 KB × 64:** Bytes 2026-11-17 gives 717 → 433 µs (−40%); the tracking A/B gives 698 →
  432–442 µs (−38%). The 1 MB A/B (691–764 → 419–421 µs) ran on a machine loaded by another agent, both
  sides alike.
- **ChaCha20-Poly1305 before stitching:** 1.50 GB/s in the harness, 1.52 GB/s (690 µs) in `final-1`. The
  ratio to CryptoKit's ChaChaPoly is 1.8x at 1 MB in `final-1` and 2.7x in `ck-final` (stitched, machine
  shared with a build); OPTIMIZATION now cites `ck-final` (2.7x at 1 MB, 3.0–3.7x at smaller sizes).
- **Base64 decode at 1 MB:** 12.5 GB/s in the `final2` results table, 12.8 GB/s in the kernel's step table
  and the C-ceiling table.
- **DEFLATE level 1 against libdeflate:** 6–14% slower on large files (`final-1`), 5.5–12% (second pass),
  10–15% on SocketStream's stream (SocketStream 2026-11-15 stage table).
- **Parallel DEFLATE, Main.js sync:** 19–21% slower in three benchmark runs with the scheduler but not in
  the interleaved harness; the log attributes it to run-to-run variation (10–30% on parallel rows).
- **Loaded-machine runs:** Bytes and Base64 `modern` first runs (load average ~10–14), NativeZip
  `pre-modern`, BPC `original`, and the 11-17 tracking runs; the BPC example ports were not timed for this
  reason. Claims from those runs rest on instruction counts.
- **`literals3`:** its −3% for integer literals did not reproduce at HEAD with identical parser machine
  code (Bytes "Verification, 2026-11-09").
