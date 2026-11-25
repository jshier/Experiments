# LZRAVEN decoding: `LZRAVENDecoder` against Compression

## 2026-11-18 (baselines `lzraven-v1`, not kept, and `lzraven-v2`; Swift 6.4, macOS 27.2.1, M3 Ultra)

A decoder in BytesCompression for `COMPRESSION_LZRAVEN` (0xD05), Apple's undocumented algorithm of macOS 27,
which Apple Encrypted Archives (`aea -a lzraven`, 16 MiB segments) and Apple Archive streams (`pbzm` blocks) use.
The format was worked out from libcompression's decoder (`_rav_decode_buffer`, `_RavDecodeBlock`) and is written
up in `LZRAVEN-FORMAT.md`: blocks of 512 KiB, eight interleaved 64-bit rANS decoders with adaptive 16-symbol
distributions, an LZMA-like model (literal nibbles, 16 match kinds, four repeated distances), the model carried
across blocks, and x86 and ARM64 branch filters.

API (`Sources/BytesCompression/LZRAVENDecoder.swift`):

- `LZRAVENDecoder()`: allocates its workspace once: the model twice (19 KB each: the working copy, and the initial
  one it's reset from), plus 64 bytes of states and 272 of copy patterns.
- `decompressAll(_ input: RawSpan, decodedSize: Int? = nil, into: inout OutputRawSpan) throws(BytesError) -> Int`:
  with `decodedSize`, exactly that many bytes (an AEA segment or Apple Archive block, whose container states the
  size), `mismatch` for any other size; without, whatever the buffer holds, `insufficientCapacity` if it doesn't
  fit. Returns the input consumed (all of it). (Two `decompress` overloads until 2026-11-19: see
  RESULTS-lzbitmap.md's API section.)
- `insufficientData` for truncation, `invalidValue` for corruption (including bytes after the end marker).
  Nothing is read or written outside the buffers; nothing is allocated per call (`Allocations:LZRAVEN_decode`,
  coded and stored blocks, passes its zero-malloc threshold).

Tests (`Tests/BytesCompressionTests/LZRAVENDecoderTests.swift`, 10 tests, all against Compression's encoder): 0–70
bytes, sizes ±1/±33/±64 around powers of two to 4 MiB and around 512 KiB blocks, generated text/random/runs and
periods 1–40, stored blocks between coded ones, `/bin/zsh` (ARM64 filter) and `ooffice` (x86 filter), all of
Silesia and the web assets in 16 MiB segments, an `aa`-style header, wrong sizes, truncation at 400 points per
stream, 600 random byte corruptions (no crash; 85% throw, as the format has no checksum), and 200 corruptions
compared with what Compression makes of them (identical output whenever Compression succeeds).

### Results (`lzraven-v2`, p50)

One run under the shared benchmark lock, each row's two decoders seconds apart, with other agents' builds on the
machine: times ±5–10%. MB/s is the decompressed size over p50 wall-clock time (decimal MB); × is Compression's
time over Bytes'. Instructions per byte are exact. Inputs encoded by Compression (cached as
`CORPUS/cache/NAME-SIZE.lzraven-macos27`); "size" is the compressed size.

| Input | Size | Bytes MB/s | Compression MB/s | × | Bytes instr/B | Compression instr/B |
|---|---|---|---|---|---|---|
| JSON (1.6 KB) | 22.0% | 504 | 486 | 1.04× | 26.8 | 29.3 |
| JSON (119.0 KB) | 8.2% | 1434 | 1369 | 1.05× | 15.8 | 17.1 |
| Main.css (375.7 KB) | 12.8% | 1142 | 1145 | 1.00× | 13.8 | 14.8 |
| Main.js (3.8 MB) | 14.5% | 676 | 673 | 1.00× | 15.0 | 16.3 |
| dickens (9.7 MB) | 27.7% | 510 | 485 | 1.05× | 24.4 | 26.2 |
| mozilla, first 16 MiB (an AEA segment's size) | 34.9% | 300 | 284 | 1.05× | 44.0 | 49.0 |
| samba (20.6 MB) | 17.5% | 600 | 569 | 1.06× | 20.5 | 22.4 |
| x-ray (8.1 MB) | 51.6% | 157 | 151 | 1.04× | 87.1 | 98.4 |
| xml (5.1 MB) | 8.6% | 1132 | 1134 | 1.00× | 9.7 | 10.5 |

Same speed as Compression or a few percent faster, with 7–11% fewer instructions. Filtered inputs, from a
scratch harness (cycles and instructions from `proc_pid_rusage`, no lock, so cycles ±5%): `ooffice` (first 4 MB,
x86 filter) 44.0 instr/B and 17.0 cycles/B against Compression's 45.7 and 16.4; `/bin/zsh`'s arm64e slice (ARM64
filter) 45.8 and 15.0 against 49.6 and 15.1. Dickens compresses to 2,826,796 bytes, against `xz -9e`'s 2,831,220
(x-ray 4.38 MB against 4.49, xml 459 KB against 435): LZMA's ratio, decoded about 3x as fast as LZMA
(Bytes' `Benchmarks/RESULTS.md`, 2026-11-18: 160–170 MB/s on dickens).

### What changed between `lzraven-v1` and `lzraven-v2`

`v1` was the first working decoder: instructions already 3–6% under Compression's, and times equal on text, but
mozilla's segment took 79 ms against 59 (−34% throughput) and samba 45 against 37. Per megabyte of mozilla, the
first 4 MB (compressed data, almost all literals) decoded at half Compression's speed with fewer instructions.

| Change | mozilla 16 MiB, cycles/B (Compression 12.5) | Kept |
|---|---|---|
| `v1` | 18.0 | |
| Word reader as cursor + remaining instead of base + count + index | 18.1 | yes (simpler) |
| Repeated distance moved to the front with selects instead of a `switch` | 17.9 | yes |
| States first in the workspace, distributions 64-byte aligned; model shifted 2 KB (4K aliasing) | 17.9, 18.4 | first only |
| Match copies 16 bytes at a time (at most 15 past the end) instead of `ZstdCopy.wild16` (32) | 18.0 | yes (smaller overrun) |
| Distances under 16 as a `tbl` shuffle stored every whole period, instead of `ZstdCopy.overlapping` | 18.2 | yes (no store-forwarding chain; 7% of mozilla's matches) |
| Branchless word read (clamped load, select 0) | +13% instructions, +8% cycles (dickens) | no |
| Branchless refill (`x < 2^32`: selects) | +75–90% instructions, cycles unchanged (maa) or worse | no |
| Previous byte kept in a register instead of reloaded from the output | 17.0 | replaced by the next |
| **Literal context from the high nibble** (`previous = high >> 2`), not the whole byte | **12.7** | yes |

The last one was the whole gap. A literal is two symbols, and the next literal's first distribution depends on
this byte's top two bits. Taken from the stored byte (or from `high << 4 | low`, which LLVM can't reduce to
`high >> 2`), the next literal waited for both symbols plus a store-to-load forwarding: two symbol latencies
(about 14 cycles each: CDF load, compare, `addv`, `fmov`, address) per literal. From the high nibble, the next
literal's first symbol overlaps this one's second. Compression's decoder does the same (`x25 = high << 4`, read
back with `>> 6 & 3`). Text was unaffected because its literals are few; mostly-literal data (compressed files,
x-ray) went from 31.6 to 17.6 cycles/B on mozilla's first MB.

Found with `Tools/profile --keep` and the trace's `time-profile` table exported (leaf addresses counted, mapped to
the binary): samples piled on the instruction after each state load's refill branch, the oldest instruction
waiting on that chain. CPU Counters had shown "processing" (back end) at 34% of cycles against Compression's 11%,
with similar discards, L1 misses, and load/store counts.

### Lessons (for AGENTS.md)

- **A context that needs only part of a value should be computed from the part that's ready first.** LZRAVEN's
  next literal needs the top two bits of this byte, which are in its high nibble: taken from the whole byte (even
  `(high << 4 | low) >> 6`, which LLVM doesn't simplify), each literal's two symbols were serial with the next
  literal's, and incompressible data decoded at half Compression's speed with fewer instructions. Reloading the
  byte from the output added a store-to-load forwarding on top. Look for this when a decoder is slower than a
  reference with fewer instructions and "processing" (back end) dominates `Tools/counters`.
- **Finding the stalled instruction:** `Tools/profile --keep T`, then `xctrace export --xpath
  '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'`, take each row's first `<frame>` (resolving
  `id`/`ref` for frames and `tagged-backtrace`s), subtract the image's `load-addr` (from the `dyld-library-load`
  table or the process's binary entry) and add the binary's base (`0x100000000`), minus 1 for the return-address
  convention; then `objdump --start-address`. Samples land just after the instruction waiting on the long chain.
  (A candidate for a `--pc` option in `Tools/profile`.)
- **rANS refill branches stay branches.** Whether a state needs a word is as unpredictable as the data, but the
  selects to avoid it cost 75–90% more instructions and saved no cycles: the misprediction isn't on the critical
  path when eight states interleave.
- **Reverse-engineering a codec from a dyld-cache library:** `ipsw dyld extract` the dylib, read Binary Ninja's
  pseudo-C for structure, check it against `objdump` where it matters (it dropped a `uxtb` and showed
  `memset_pattern16` as a copy), transcribe it into a C reference, and test the reference against the system's
  encoder on everything before writing the real decoder: here the C transcription decoded all inputs on its first
  run, and the Swift decoder was then a port with the semantics settled.
- **`max(a, b, c, d)` is variadic**: an array (stack-promoted object, `swift_initStackObject`, a release) in a hot
  function. Compare pairwise. And `@inline(__always)` on the coder's symbol and length methods left 10 calls in
  the decode loop: `@inline(always)` inlined them (as the Brotli lesson says), and `start()` had to be inlined
  too, or its `inout` call kept the coder in memory through the loop.
