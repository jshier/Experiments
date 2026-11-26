# Plan: block loads, `cmeq` matching, mask-walked candidates, `ByteMatches` lanes, a typed block view (2026-11-25)

Open items 3–5 and 16–17 of `Open-Items-2026-11-25.md`. Probes: `~/Scratch/scan-items.noindex/probe` (a package on
Bytes by path; `probe-check` checks every variant against the current code on random lengths 0–299, 0 mismatches).
Counts are instructions per loop iteration from `Tools/loops`, Xcode 27.3's Swift 6.4, release.

## What the probes found

| Loop | Now | `cmeq` only | Unchecked loads only | Both, or a typed view |
|---|---|---|---|---|
| 64-byte block mask loop, two bytes (HTTPBytes' `farStop` shape) | 64 | 48 | 45 | 29 / 29 |
| SHA's shape: four vectors per 64-byte block | 31 | — | — | 9 (typed view) |
| `containsByte`, two bytes, per 16 | 19 | 12 | — | 7 unchecked / 6 typed |
| `firstByteOffset(where:)`, per 16 | 16 | 13 | — | 9 / 9 |
| `firstByteOffset(of:)`, a block with candidates | 108 | — | — | 24 + 9 a candidate |

- The current loops' checked offset loads (`load(fromByteOffset: o + 16k)`) each keep a compare and branch: the
  comments in `ByteBlock.swift:49–56,94` and `ByteScan.swift:166,215` say they fold, and they don't.
- `vector .== SIMD16(repeating: byte)` is one `cmeq` on 6.4 (two vectors; only the scalar-operand overloads are lane by
  lane). Its lanes are all ones or zeros, so `nibbleMask`'s and the NEON gather's `sshr` disappear (LLVM sees the
  lanes are already full). LLVM even merged `== 0x2B | == 0x23` into one `and` + `cmeq`.
- A typed view (`Span<InlineArray<n, UInt8>>(viewing: span.extracting(first: …))`, elements read by `bitCast`) matches
  unchecked loads in the loop with no `unsafe`, but costs about 6 instructions more to set up (the `extracting` clamp,
  a nil-base select, the stride check): free for SHA/GHASH/checksums on whole blocks, not for the 16–64-byte scans
  most callers make (MQTT topics, HTTP fields).

## Changes

### Bytes, internal (item 3)

- `RawSpan.byteBlock(at:)`: keep its one precondition; load the four vectors with
  `unsafeLoadUnaligned(fromUncheckedByteOffset:)` (each `unsafe` with the precondition as its reason). Delete
  `ByteBlock(loading:at:)`; `byteBlock(at:padding:)` builds its block from the padded `InlineArray` with the new
  `ByteBlock(_:)` (below).
- `containsByte(where:)`, `firstByteOffset(where:)`, `bytesEqual(_:)`: the main loop loads unchecked under
  `offset < count - 16` (proved by the loop condition with `count >= 16`); the final overlapping load stays checked (its
  check folds: `count >= 16` is known). Comments say why it's safe and why not a typed view (setup cost on short spans).
- SHA-1, SHA-256 (`compressWithInstructions`, `compressPortably`), SHA-512 (both), GHASH `absorbBatches`: iterate a
  typed view of whole blocks (`InlineArray<64, UInt8>` / `<128, UInt8>`), read with `bitCast`. No `unsafe` added.
  Check each loop with `Tools/loops` against the four-loads probe (31 → 9 shape).
- Correct the comments that claim the checks fold.

### Bytes, `cmeq` matching and `ByteMatches` (items 4 and 16)

`ByteMatches` keeps its contract (a lane matched when its high bit is set; other bits ignored), so nothing that builds
one from high bits (`nonASCII`, BytesCompression's LZBITMAP sign tricks) changes. Additions:

- `ByteLanes.matching(_ byte:)`: `cmeq` against a splat. Full lanes, valid high bits.
- `ByteLanes.matching(lessThan:)`, `matching(atLeast:)` (unsigned, one `cmhi`/`cmhs` each), and
  `matching(in: ClosedRange<UInt8>)` (subtract and one unsigned compare; HTTPBytes writes this by hand twice).
- `ByteMatches.init(_ mask: SIMDMask<SIMD16<Int8>>)`: a comparison's lanes, as they are (no instructions). Replaces
  HTTPBytes' `HTTPCharacters.matches(_:)` (14 sites), `ASCII.swift:120`'s `replacing(with:where:)`, and
  BytesCompression's `ByteMatches(highBits: (a .== b).lanes(as:))` at `LZBitmapEncoder.swift:415,428`.
- `ByteMatches.fullLanes` public (0xFF where matched; one `sshr`, dropped when the lanes come from a comparison).
- Docs: `ByteLanes`'s header no longer says the scalar comparisons are why it's SWAR; it says which tests are full
  lanes already.

Rejected: making full lanes the stored representation (`nonASCII` would cost a `cmlt`, every `init(highBits:)` an
`sshr`; the probes show LLVM already drops the spread after comparisons, so the change buys about one `and` per `any`).

### Bytes, candidates walked as a mask (item 5)

`GenericBytesReader.firstByteOffset(of:)`: the candidate mask's `nibbleMask`, walked with `trailingZeroBitCount` and
`lanes &= lanes - 1`. `lastByteOffset(of:)`: walked from the top (`leadingZeroBitCount`, clearing the highest bit).
Keep `Load.candidates`; the mask comes from `ByteMatches(candidates)`.

### Bytes, public typed block view (item 17)

- `RawSpan.blocks<let byteCount: Int>() -> Span<InlineArray<byteCount, UInt8>>`, `@_lifetime(copy self)`: the whole
  `byteCount`-byte blocks at the span's start (the remainder, `self.byteCount % byteCount`, left out). Typed by the
  result: `let blocks: Span<InlineArray<64, UInt8>> = bytes.blocks()`. Precondition `byteCount > 0`.
- `ByteBlock.init(_ bytes: InlineArray<64, UInt8>)` (a `bitCast` to `SIMD64<UInt8>` and its four quarters: two `ldp`).
- BytesCompression's `WordReads.words`/`stripes` become `blocks()`; `WordReads.value` stays (one line) or goes inline.
  `WordReads`' unchecked `load32`/`load64`/`byte` stay in BytesCompression: they carry the encoders' invariants and
  Bytes has no client for an unchecked little-endian load (the stdlib's `unsafeLoadUnaligned(fromUncheckedByteOffset:)`
  is the general form). So item 17's "move `WordReads` down" is done for the views, not the unchecked loads.
  XXH64 and CRC-64 must compile to the same instructions (`RESULTS.md` 2026-11-24, E2): check with `Tools/loops`.

### Clients

- HTTPBytes: `HTTPCharacters.matches(_:)` replaced by `ByteMatches(_:)`; the two `&- 0x41 .< 26` tests by
  `matching(in:)`. `HeadScanner` gains through `byteBlock(at:)`.
- BytesCompression: `LZBitmapEncoder` sites as above; `WordReads` views.
- MQTT: nothing to change (its topic checks use `containsByte`).

## Tests

- `ByteScanTests`: for every length 0–200 and every match position (including the last byte, so input ends where the
  last 16-byte load ends), `containsByte`, `firstByteOffset(where:)`, `bytesEqual` (a difference at every position)
  against a byte loop; filler bytes varied (random 0–255 except the matched ones; includes `0x70`-like bytes for the
  nibble trap).
- `matching(lessThan:)`, `matching(atLeast:)`, `matching(in:)`, `matching(_:)`: all 256 byte values in each lane
  position against the scalar predicate, through `bitmask`, `nibbleMask`, `firstIndex`, `any`, and `fullLanes`;
  ranges at 0, 255, empty-width (`x...x`).
- `ByteMatches(SIMDMask)` equals the high-bit form; `fullLanes` is 0 or 0xFF.
- `byteBlock(at:)` at the last offset (`count - 64`) and a precondition failure past it (exit test); `ByteBlock(_:)`
  equals `byteBlock(at: 0)`.
- `blocks()`: lengths 0…3n+r for n ∈ {1, 16, 64, 128}: count, contents, empty span.
- `firstByteOffset(of:)`/`lastByteOffset(of:)`: dense candidates (input of all `head` bytes with the pattern at one
  position; head == tail patterns), patterns of 2–8 bytes at every position near both ends, against a naive search.
- SHA-1/256/512 and AES-GCM: existing known answers, plus lengths 0–300 against CryptoKit (or the existing reference).

Each new fast path broken once to see its test fail.

## Measuring

Before baselines are `scan-before` (Bytes, BytesCompression, HTTPBytes/Benchmarks, MQTT, optimized builds) and
`scan-before-portable` / `scan-before-portable-no-c` (Bytes' `Scan`, `Search`, `ASCII`, `Hex` rows). After:
`scan-after*` likewise; `Tools/bench-table`; instruction counts compared directly, times only in one interleaved run on
an idle machine. Record in `Bytes/Benchmarks/RESULTS.md`, BytesCompression's for SHA/GHASH, HTTPBytes' for heads, and
lessons in `LESSONS.md`.

## Review (2026-11-25), and what changed

An adversarial review (read-only agent, probes in `~/Scratch/scan-items-review.noindex/probe`, 0 mismatches) confirmed
the bounds of every unchecked load, `cmeq`'s contract for every client, the top-down walk for `lastByteOffset(of:)`,
the counts above, the typed-view setup cost and the split, and keeping `WordReads`' unchecked loads. Accepted, and the
plan above is superseded where they differ:

1. **`matching(in:)` already exists** (`ASCII.swift:114`, built into `asciiDigits` etc.): rewrite its body with
   `ByteMatches(SIMDMask)` instead of adding it. **`matching(lessThan:)`/`matching(atLeast:)` dropped**: they are
   `matching(in: 0...n-1)`/`matching(in: n...255)`, the same one `cmhi`/`cmhs` (the subtraction of 0 or the range check
   folds). HTTPBytes' `&- 0x41 .< 26` sites can use `matching(in:)` today.
2. **`&+=` in the unchecked loops**: `+= 16` keeps an overflow check (9 instructions against 7 in `containsByte`); the
   comment asking for `+=` applied to checked loads only.
3. **Candidates gain only where there are candidates**: a block without one is 14 instructions now, 15 walked as a
   mask. Both existing search rows have no candidates, so they are expected flat. Added rows with every offset and a
   quarter of offsets candidates, forward and backward (`Scan: 4-byte marker, …`), baseline `scan-before-dense`.
4. **HTTPBytes' gain is item 3's alone**: the real `farStop` is 48 today, 29 with unchecked loads; replacing
   `HTTPCharacters.matches` (16 sites) changes no code. Do it for the API, not for speed.
5. **`fullLanes` stays internal**: no client outside Bytes.
6. **Whole-block contracts kept**: SHA's and GHASH's typed views `precondition` that their input is whole blocks
   (today a partial block traps in a checked load; a view would drop it silently). GHASH returns `view.count * 128`.
7. **Probe the shapes not probed** before trusting them: SHA-512's 128-byte blocks, GHASH's eight vectors beside 16
   live `p`/`s` vectors, the portable paths' big-endian word reads. `Tools/loops --body` for spills (`stp q…, [sp`)
   and subscript checks, not only counts.
8. **Tests under all three builds**: ByteScan, ByteBlock, ASCII, SHA/AES-GCM suites with default traits,
   `--traits Portable`, and `--disable-default-traits`. `nibbleMasksIgnoreLowBits` must build its matches with
   `ByteMatches(highBits:)` (with `cmeq`, `matching(0)` no longer leaves low bits, so it would stop testing the trap).
9. **More clients**: SocketStream `PacketChecker.swift:64` (PR toolchain: `Tools/toolchain SocketStream`), Disk
   `Planner.swift:183,655`, NativeAEA `XIP.swift:375`, BytesBase64 `Decoding.swift:173,305`, BytesCompression
   `DeflateDecoder.swift:700`, Bytes `Sections.swift:542,627`: `Tools/calls --callee 'specialized SIMD|SIMD.init'` on
   each after the change.
10. **The view's name and inference**: `blocks()` read as yielding `ByteBlock`s, a generic parameter named
    `byteCount` shadowed the property, and inference needs an annotation (fails in a `for`). Now
    `RawSpan.chunks<let n: Int>(of: InlineArray<n, UInt8>.Type) -> Span<InlineArray<n, UInt8>>`:
    `bytes.chunks(of: InlineArray<64, UInt8>.self)`.

**Superseded after measuring (item 5):** the mask walk lost where it was meant to win. With every offset a candidate
it ran +54–71% instructions and 2–3x the time (9 instructions a candidate in a serial chain, against the old fully
unrolled lane tests), and the candidate-free rows +7–16% instructions. Replaced by an exact match per candidate block:
keep the old `any(candidates)` test (candidate-free blocks unchanged), and in a block with candidates compare every
pattern byte at all 16 offsets (`Load.matches`, n shifted loads and `cmeq`s, ANDed; LLVM reuses the candidate test's
two) and take the first or last set lane. Every-candidate −78% instructions, −82% time; a quarter −61%, −95%;
candidate-free unchanged.

Not adopted (item 3): GHASH through a typed view. Its 9 checks went, but LLVM moved Karatsuba's middle XOR into
general registers (173 instructions against 171, 22 lane moves against 14); kept its checked loads, with a comment.

Rejected: a complement operator for `ByteMatches` (its one would-be client, `StructuredFieldScan.swift:95`, is a
`SIMDMask` expression that `ByteMatches(_:)` takes as it is). Noted: LLVM merges identical variants, so benchmark
variants need separate `@inline(never)` bodies.

## Risks

- A wrong bound on an unchecked load reads past the span: the tests at every length and position near the end, and the
  `byteBlock(at:)` precondition exit test.
- Inlining: the scans are `@inline(__always)`; check clients' loops (`Tools/calls --callee 'specialized SIMD|SIMD.init'`)
  after the change, especially HTTPBytes' `HeadScanner` and the MQTT topic check.
- `blocks()`'s generic value parameter inferred from the result type: if the call site can't infer it, add
  `blocks(of: InlineArray<64, UInt8>.self)`.
