# AES blocks in flight (item 7) and the async append's zero-fill (item 8): plan (2026-11-26)

From `Open-Items-2026-11-25.md`. Item 9 (CRC-32 `crc32x` beside `pmull`, short back-references in a register,
Base64's decoder on the M1 Max) shares no code with either and follows them. M1 Max (8 performance cores, 3.2 GHz).

## 7. AES with more blocks in flight

**What the numbers say now** (`BytesCompression` baseline `api-after`, 1 MB rows):

| Kernel | Measured | Cycles per 128 B | Chain bound (8 chains, 3-cycle fused round) |
|---|---|---|---|
| AES-128-CTR | 12.5 GB/s (84 µs) | ~33 | ~32 (10 rounds) |
| AES-256-CTR | 8.7 GB/s (120 µs) | ~47 | ~45 (14 rounds) |
| AES-128-GCM seal (stitched) | 6.3 GB/s (166 µs) | ~65 | ~32 |

CTR sits on its chain bound. The earlier "about 1.5x" (`Bytes/Benchmarks/RESULTS.md`, "AES kernels") counted the AES
pairs alone; each block also takes about 4 other vector µops (its counter's add and byte swap, the last `aese`, the
final XOR), so with 12 chains the vector pipes (4 a cycle) bind first: about +14% for AES-128 (42 cycles per 192 B
against 49.5 now) and +30% for AES-256. GCM's stitched loop is at neither bound (about 49 cycles of vector µops, 32 of
chain): something else limits it (the GHASH chain through `y`, issue width at 355 instructions per 128 B), so more AES
chains may not help there.

**Plan:**

1. Before: `Tools/loops` on `counterModeBatches`, `sealBatches`, `openBatches` (instructions, any stack traffic),
   `Tools/counters` on the CTR and GCM rows (where the cycles go).
2. A 12-block CTR kernel, `counterModeBatches12`: 192 bytes a batch, the 8-block kernel kept for a 128–191-byte
   remainder, then single blocks. Register budget: 12 states + 15 round keys (AES-256) = 27 of 32 vector registers,
   plus the counter base and one loaded block: no spills allowed (`Tools/loops` must show no stack loads or stores in
   the loop). If AES-256 spills, try 10 blocks for it (or 12 for 128/192 only).
3. Same instruction for every counter layout (`bigEndian32` GCM, `bigEndian64`, `littleEndian128` with its carry
   fallback at the 12-block boundary).
4. GCM: only if step 1 shows the stitched loop waits on AES chains. Otherwise leave it at 8 and record why (12 blocks
   there also needs H¹…H¹² and two GHASH blocks in some rounds, with 12 states + 11–15 keys + 4 accumulators).
5. Measure: instructions and times, A/B alternated (`ab-old-*`/`ab-new-*`, old and new built side by side), on an idle
   machine; AES-128/256-CTR 1 MB, GCM rows (their CTR tails), NativeAEA's decryption rows (AES-256-CTR per segment),
   NativeZip's WinZip AES rows. `Tools/counters` for cycles per byte.
6. Tests: every key size and counter layout against the single-block path at lengths 0–600 (each batch boundary,
   191/192/193, 319/320/321…) and at counters that carry inside a 12-block batch (`littleEndian128` low word at
   max−11…max, `bigEndian64` wrap, `bigEndian32` wrap); in-place and separate buffers; split across calls (pending
   bytes). Break the kernel once (a wrong counter offset) to see a test fail.

## 8. `AsyncByteTransform.transform(_:appending:)` zero-fills every round

Each round appends `room` zero bytes (at least `growth`, 16 KiB, or the whole remaining input), lets the stage
overwrite them, then trims what it didn't write: a compressor fed 4 MB writes 4 MB of zeros to produce 1 MB. The sync
form (`ByteTransform`) uses `append(writingUpTo:)` and zeroes nothing, but an array's new capacity can't stay open across
a suspension (`append(addingCapacity:)`'s closure is synchronous).

**Plan:**

1. Rows first (Bytes' `Async.swift`): a copy stage (`ByteTransform`, `Failure == Never`, `synchronously()`), 4 MB in one
   call; a 4x-expanding stage (decoder-like: several rounds at `growth`); 1 MB in 64 KB pieces. Instructions and time.
2. The change: reserve `start + room` once (`reserveCapacity`), take the array's storage pointer (unique after the
   reserve), lend `room` bytes of uninitialized capacity to the stage as the output span across the await (the array
   is `inout` to this call and nothing else touches it until it returns, so its storage can't move), then count the
   bytes the stage wrote as initialized with `append(addingCapacity: produced) { span in span.withUnsafeMutableBufferPointer
   { _, count in count = produced } }` (capacity suffices, so no reallocation; `UInt8` is trivial). Throws: nothing
   counted, as now (`removeLast`).
   Alternatives weighed: a `ByteBuffer` staging buffer filled by `receive`, then copied in (a copy for a zero-fill:
   no saving); keeping the zero-fill but only once per call (still `room` bytes of zeros).
3. Tests: output equals the sync form's for each stage shape and `growth` (1, 7, 16 K), an array that starts
   non-empty, a stage that throws mid-way (what was appended before stays; nothing of the failed round), a stage that
   suspends (offloaded) so the storage is held across a real suspension.
4. Measure: the new rows, and BytesCompression's async pipeline tests' rows if any use it.

## Plan review (2026-11-27) and what changed

A read-only reviewer with the release objects' disassembly and one probe (`~/Scratch/aes-append-review.noindex`).
Accepted:

1. **Exact reserves are quadratic.** `reserveCapacity(count + room)` each round reallocated 256 times in 256 rounds
   (`append(addingCapacity:)` alone: 9). The sync form already does it (`append(writingUpTo:)`, from `Pipeline`'s drive
   loop). Both grow geometrically now: `max(count + room, capacity × 2)` when the room isn't there. Test: a 4x expander
   to about 8 MB at `growth` 1 and 7 under a time limit.
2. **GCM's stitched seal is bound by GHASH's recurrence through `y`, not by AES chains**: `y` round-trips through the
   stack each batch, the y-dependent block starts all three serial XOR chains (7 dependent `eor`s each), the Karatsuba
   middle term and most of the reduction run in general registers (about 10 vector↔GPR moves). About 60–70 cycles on
   y's path, as measured. So GCM's part of item 7 is that recurrence: products summed as a tree with y's last, the
   middle term and reduction kept in vectors, `y` in a register; then see whether AES chains bind. `openBatches` too.
3. Item 8 counts what the stage wrote (`finalize`'s count), with `precondition(produced == written)`; nothing appended on
   a throw.
4. The async form has no minimum output capacity: forward `minimumOutputCapacity` through the async wrappers (a
   protocol requirement with a default of 1) and use it as the sync form does; `precondition(growth > 0)` in both.
5. The `(lastKey, finalKey)` select costs two register copies: a straight-line loop per key size (10, 12, 14 rounds).
6. Fusion needs each `aesmc vN` right after its `aese vN`: the current code already splits pairs in places (AES-192/256
   `sealBatches`; a branch inside one pair in `counterModeBatches`). Check the new kernels' disassembly pair by pair.
7. About 12.5 vector µops a block, not 14: up to about +30% for AES-128 (37–38 cycles per 192 B against 49.5 now).
8. The carry tests: `littleEndian128` at `max − 13 … max` (the fast path's bound becomes `max − 12`), `bigEndian64`
   wrapping with a nonzero high word, `bigEndian32` at `0xFFFF_FFF5 … 0xFFFF_FFFF`.
9. Item 8 keeps a go/no-go: kept only if the copy rows gain clearly (the zero-fill is a fraction of a percent behind a
   real codec). The unsafe part lives in one `[UInt8]` helper in BytesAsync (`append(receivingUpTo:)`, a different name
   from the sync `append(writingUpTo:)` for the overload reason), tested once.

**Outcome (2026-11-27).** CTR with 12 blocks: −18% (AES-128), −25% (AES-256). Item 8: −18 to −29% instructions on
its rows. GCM: finding 2's recurrence was tested (y last, reduction in vectors, schoolbook cross terms, per-key-size
loops): −6 to −8% instructions, no time; lane work moved into vectors made open 18% slower. The loop is bound by vector
throughput (counters: 67% useful slots, 2.3 SIMD a cycle), so it's back as it was. Details in
`Bytes/Benchmarks/RESULTS.md`.

Checked and sound by the review: the storage stays put across the await (`inout` for the whole call);
`append(addingCapacity:)` with room keeps the storage and the bytes written through the pointer; `reserveCapacity`
makes shared storage unique; nothing outlives the call on throw or cancellation; the 8-block CTR loop has no spills.
