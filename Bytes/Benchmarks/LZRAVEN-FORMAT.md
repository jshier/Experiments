# LZRAVEN

`COMPRESSION_LZRAVEN` (0xD05) is an algorithm in Apple's Compression framework from macOS 27 and iOS 27,
buffer API only. `compression.h` says it is "faster than, and generally compresses better than LZMA". Apple
Encrypted Archives (`aea encrypt -a lzraven`) and Apple Archive streams (`aa archive -a lzraven`, `pbzm`
blocks) use it. Apple hasn't published the format; this is what libcompression does, read from its decoder and
checked by decoding Compression's output with a reimplementation (`Sources/BytesCompression/LZRAVENDecoder.swift`,
tests in `Tests/BytesCompressionTests/LZRAVENDecoderTests.swift`).

## Sources and method

- **Binary:** `libcompression.dylib` from macOS 27.2.1 (26B131), extracted from the dyld shared cache with `ipsw
  dyld extract`. Its LZRAVEN symbols are local: `_rav_decode_buffer`, `_RavDecodeBlock`, `_rav_decode_scratch_size`,
  `_rav_encode_buffer`, `_RavEncodeBlock`, `_RavGetOptimal`, `_RavMatchFinder*`, and static tables named by their
  C++ functions: `RavModelInitCommands(RavModel*)::lit_state_count`/`mat_state_count`,
  `RavGetLitLamContext(unsigned char)::lut`, `RavUpdateState(unsigned char, unsigned char)::lut`,
  `RavCopyMatchUnsafe(unsigned char*, unsigned char*, unsigned int)::repeat_perm`/`rep_distance`.
- **Reading:** Binary Ninja's decompiler on `_rav_decode_buffer` (0x2cc76b13c) and `_RavDecodeBlock`
  (0x2cc7ad4c4, 1,214 instructions), checked against `objdump` where the decompiler was loose (it dropped a `uxtb`
  in the x86 filter, and turned `memset_pattern16` into a copy). Addresses below are this build's.
- **Black box:** inputs encoded with `compression_encode_buffer` (empty, 1–3 bytes, runs, random, text, sizes
  around powers of two and 512 KiB, Silesia, web assets, `/bin/zsh`), dumped and decoded.
- **Check:** a C transcription of the decoder (kept in the session's scratch directory, not here) decoded every
  test input byte for byte on its first run, including all of Silesia (mozilla's 51 MB: 98 blocks), random
  data (stored blocks), an `aa` archive's block, and inputs that set each filter flag. The Swift decoder passes
  the same tests.

The decoder's scratch size (`compression_decode_scratch_buffer_size`) is 35,424 bytes: 64 for alignment,
18,976 for the model and state, 16,384 for a `UInt16` of flags per 512 KiB block (8,192 blocks, 4 GiB).

## Container

All integers little-endian.

| Offset | Size | Contents |
|---|---|---|
| 0 | 4 | magic `0xECCA002B` (bytes `2B 00 CA EC`) |
| 4 | 4 | low 26 bits 0 (checked); top 6 bits free: Compression writes 0, `aa` writes 17 (`0x44000000`), the decoder ignores them |
| 8 | … | blocks |
| … | 4 | end marker: a word below `0x1000` (Compression and `aa` write 0) |

Each block is a 4-byte header, then `size = header >> 12` bytes (20 bits, so under 1 MiB). The low 12 bits are
flags:

| Bit | Meaning |
|---|---|
| 0 | stored: the bytes are the output |
| 1 | ARM64 branch filter over this block's output; bits 10–11 are the offset of the first instruction word |
| 2 | x86 branch filter over this block's output |

`rav_decode_buffer` checks, per block: the output so far is a multiple of 512 KiB (`total & 0x7FFFF == 0`: every
block but the last makes exactly 512 KiB), the output isn't full yet, and `size` fits in the input after the
header. It needs at least 12 input bytes (header and end marker), and clamps the output capacity to `2^32 - 1`.
It stops at the first word below `0x1000` and doesn't look past it. Compression's encoder stores a block when
coding doesn't help (random data: 512 KiB stored blocks) and when it's under 64 bytes (inputs under 64 bytes, and
a last block under 64): `printf a` encodes as `2B00CAEC 00000000 | 01100000 61 | 00000000`, a stored block of
size 1.

The model and the state below are set up once per buffer and carry over from block to block, through stored
blocks, and matches reach anywhere back in the output (the window is the whole buffer).

## Coded blocks

### Entropy coder

Eight interleaved rANS decoders with 64-bit states read the block as 32-bit words, in order. Each symbol uses the
next state in turn (`states[next & 7]`, `next += 1`), whatever the symbol. Before a symbol, a state below `2^32`
takes the next word: `x = x << 32 | word`. Past the block's last word the "word" is 0, and the block is rejected
unless exactly all its words were read (`size / 4` of them; a `size` that isn't a multiple of 4 leaves bytes
unread). Probabilities are 14-bit: with `slot = x & 0x3FFF`, a symbol with cumulative range `[low, low + freq)`
decodes when `low <= slot < low + freq`, and the state becomes `(x >> 14) * freq + slot - low`.

- **Raw bits** (`n` up to 31): `v = x & (2^n - 1)`, `x >>= n` (after the refill).
- **Binary decisions:** a 16-bit `p` (initially `0x2000`) is the probability of 0 (here, "a match"). `slot < p`
  decodes 0: `p += (0x4000 - p) >> 5`; otherwise 1, with `low = p`, `freq = 0x4000 - p`: `p -= p >> 5`.
- **16-symbol distributions:** 16 cumulative `UInt16`s, `cdf[k]` the top of symbol `k`'s range; `cdf[15]` is
  always `0x4000`. The symbol is the number of entries `<= slot`. libcompression compares all 16 with NEON
  (`cmhi`, `uzp1`, `saddlv`) and reads `low` as `cdf[(s - 1) & 15] & 0x3FFF` (`0x4000 & 0x3FFF` is the 0 below
  symbol 0). Then every entry moves toward a target by `(target - cdf[k]) >> rate` (arithmetic shift, `ssra`):
  entries `k >= s` toward `0x4000 - 32 * (15 - k) + (2^rate - 1)`, entries below toward `32 * (k + 1)`, so each
  symbol keeps at least about 32/16384. The rate is 6 or 7 by distribution (constants at 0x2cc7cefd0–0x2cc7cf040).

### Block start

The first two words are state 0's (`W0 << 32 | W1`). States 1–7 are then set up from state 0: in turn, state 0
refills, gives its low word to state `k`, replaces it with the next word `w`, shifts out `w`'s low 5 bits as a
count `n`, and gives `n` raw bits `v` (after refilling) to state `k`'s high word as `2^n + v`:

```
x = W0 << 32 | W1
for k in 1...7:
    x = refill(x)
    low = x & 0xFFFFFFFF
    w = nextWord()
    x = (x & ~0xFFFFFFFF | w) >> 5
    n = w & 31; v = 0
    if n: x = refill(x); v = x & (2^n - 1); x >>= n
    state[k] = (2^n + v) << 32 | low
x = refill(x)
state[0] = x >> 5
n = x & 31
```

If `n` is 0 the size code is 0 and symbols start at state 1; otherwise the size code is `n` raw bits from state 1
plus `2^n - 1`, and symbols start at state 2. The block's output size is the previous coded block's size (0 at
first) plus the zigzag-decoded size code (`(c >> 1) ^ -(c & 1)`); it must be 64 to 524,288 bytes and fit in the
output.

The block's last 32 bytes are not coded: when the symbols reach `start + size - 32`, the eight states' low words,
little-endian, state 0 first, are the last 32 bytes (`vuzp1q_s32` of the states, stored at the end). The encoder
makes the final states come out that way. A match may end exactly there but not past it.

In the buffer's first block (output offset 0) the first byte is 8 raw bits; elsewhere the block starts with a
symbol. Before decoding, every repeated distance must be at most the current position.

### Model

Offsets in bytes in libcompression's model (the scratch buffer, 64-byte aligned); each distribution is 32 bytes.
`pos` is the output position's low 2 bits (absolute, not per block), `prev` the previous byte's top 2 bits.

| Offset | Count | Use | Rate | Initial |
|---|---|---|---|---|
| 0x0000 | 14×4 | binary: literal or match, `[state][pos]` | 1/32 | `0x2000` |
| 0x0070 | 14 | match kind, `[state]` | 6 | states 0–8: `lit_state_count`; 9–13: `mat_state_count` |
| 0x0230 | 3×4×16 | literal high nibble after a match, `[selector][prev][matchByte >> 4]` | 6 | uniform |
| 0x1A30 | 3×16 | its low nibble when the high nibbles agreed, `[selector][matchByte & 15]` | 6 | uniform |
| 0x2030 | 4×4 | literal high nibble, `[pos][prev]` | 7 | uniform |
| 0x2230 | 4×4×16 | literal low nibble, `[pos][prev][high]` | 7 | uniform |
| 0x4230 | 4 | repeat length, kinds 8–11, `[pos]` | 6 | uniform |
| 0x42B0 | 4 | repeat length, kinds 12–15, `[pos]` | 6 | uniform |
| 0x4330 | 4 | repeat length extension, low, `[pos]` | 6 | uniform |
| 0x43B0 | 1 | repeat length extension after symbol 10 | 6 | uniform |
| 0x43D0 | 1 | repeat length extension after symbol 14 | 6 | uniform |
| 0x43F0 | 7×4 | match length, `[kind][pos]` | 6 | uniform |
| 0x4770 | 4 | match length extension, low, `[pos]` | 6 | uniform |
| 0x47F0 | 1 | match length extension after symbol 10 | 6 | uniform |
| 0x4810 | 1 | match length extension after symbol 14 | 6 | uniform |
| 0x4830 | 7×2 | distance: two symbols per kind | 7 | uniform |
| 0x49F8 | 8 `UInt32` | distance history; the last four are the repeated distances, all 1 at first | | |
| 0x4A18 | `UInt32` | previous coded block's size | | 0 |
| 0x4A1C | byte | state | | 0 |
| 0x4A20 | 8192 `UInt16` | block flags (filters run after all blocks) | | |

"Uniform" is `cdf[k] = 0x400 * (k + 1)`. Kind counts (in 64ths, cumulated and shifted left 8):
`lit_state_count` = 17, 1, 1, 1, 1, 1, 1, 17, 17, 1, 1, 1, 1, 1, 1, 1 (short matches, one-byte repeats, and the
last distance favored after literals); `mat_state_count` = 17, 17, 17, then 1s (short matches after matches).
The memory at 0x0000 is filled by `memset_pattern16` with eight `0x2000`s.

### Symbols

The state is 0–13: 0–8 after a literal, 9–13 after a match.

```
while position < end:
    if decision(isMatch[state][pos]) == 1:            # a literal
        if state < 3:
            hi = symbol(literalHigh[pos][prev]); lo = symbol(literalLow[pos][prev][hi])
        else:                                          # after a match: the byte at rep0 guides it
            m = output[position - rep0]; sel = selector[state]
            hi = symbol(matchedHigh[sel][prev][m >> 4])
            lo = hi != m >> 4 ? symbol(literalLow[pos][prev][hi]) : symbol(matchedLow[sel][m & 15])
        output[position++] = hi << 4 | lo
        state = afterLiteral[state]
        continue
    kind = symbol(kinds[state])
    kind 0–6:  a new distance
        length = lengthCode(matchLength[kind][pos], matchExt10, matchExt14, matchExtLow[pos]) + 2   # 2–332
        a = symbol(distance[kind][0]); b = symbol(distance[kind][1])
        kind 0:   distance - 1 = a << 4 | b                                      # 1–256
        else:     n = (a >> 2) + 4 * kind - 2                                    # 2–25 extra bits
                  distance - 1 = (4 | a & 3) << (n + 4) + bits(n) << 4 + b     # 32-bit; 257 up
        distance must be <= position; push it: rep3 = rep2, rep2 = rep1, rep1 = rep0, rep0 = distance
        state = state < 9 ? 11 : 13
    kind 7:    one byte at rep0: output[position] = output[position - rep0]; position += 1
               state = state < 9 ? 9 : 12
    kind 8–15: repeated distance rep[kind & 3], moved to the front
        kinds 8–11:  length = symbol(repeatShort[pos]) + 2                                    # 2–17
        kinds 12–15: length = lengthCode(repeatLong[pos], repeatExt10, repeatExt14, repeatExtLow[pos]) + 18  # 18–348
        state = state < 9 ? 10 : 12
    copy length bytes from position - rep0 (overlapping, as LZ77); it must end by `end`
```

`lengthCode` reads `s = symbol(first)`: 0–9 are themselves; 10 is `10 + symbol(ext10)` (10–25); 11–13 are
`16 * s + symbol(extLow) - 150` (26–73); 14 is `16 * (14 + symbol(ext14)) + symbol(extLow) - 150` (74–329); 15 is
330.

`selector` (`RavGetLitLamContext::lut` at 0x2cc7cf1a0: 4, 3, 3, 2, 1, 2, 1, 2, 1, 0, 0, 0, 0, 0; read only for
states 3–13) is 2, 1, 2, 1, 2, 1, 0, 0, 0, 0, 0. `afterLiteral` (`RavUpdateState::lut` row 16, at 0x2cc7cf28e) is
0, 0, 0, 2, 3, 1, 5, 1, 7, 4, 6, 8, 6, 8; the table's rows 0–15 are the match kinds' next states quoted above.

The distance history is 8 `UInt32`s whose last four are rep0–rep3. libcompression moves a repeated distance
to the front by shifting four entries up by one from index `kind & 3` and putting the chosen one at index 4,
and pushes a new one by shifting indices 3–6 to 4–7; the first four entries never reach the last four.

Matches are copied 16 bytes at a time (`RavCopyMatchUnsafe`): for distances under 16, a `tbl` with
`repeat_perm[d]` (the pattern 0, 1, …, d - 1 repeated) builds the first 16 bytes, and later stores step by
`rep_distance[d]` (the smallest multiple of `d` over 16: 17, 18, 18, 20, 20, 18, 21, 24, 18, 20, 22, 24, 26, 28,
30). The copies write up to 15 bytes past a match, which the 32 bytes at a block's end make safe. The result is
an ordinary byte-by-byte LZ77 copy.

## Branch filters

After the last block, each 512 KiB of output whose block's flags ask for it, and which is at least 64 bytes, is
filtered: x86 first, then ARM64. Positions are absolute output offsets, 32-bit arithmetic.

**x86** (bit 2): scanning from the block's start, for each byte `E8` or `E9` at `q` with `q + 5 <= end`: if the
operand's last byte (`q + 4`) is `00` or `FF`, the operand `v` at `o = q + 1` becomes

```
t = (v & 0x01000000) - o + (v & 0xFF00) + (v & 0xFF) << 16 + (v >> 16 & 0xFF)
v = (t & 0x01FFFFFF) - (t << 1 & 0x02000000)      # sign-extended from 25 bits
```

and scanning resumes at `q + 5`; otherwise at `q + 4`. (The encoder stores the absolute target's bytes in the
order 2, 1, 0, sign.) libcompression scans 16 bytes at a time with NEON while 20 remain.

**ARM64** (bit 1): every word at `start + offset + 4k` (offset from flags bits 10–11) ending by the block's end:

```
bl   (w & 0xFC000000 == 0x94000000), if (w + 0x800000) & 0x3000000 == 0:
     x = w - (p >> 2); s = x >> 23 & 1
     w = s << 24 | s << 25 | x & 0xFFFFFF | 0x94000000
adrp (w & 0x9F000000 == 0x90000000), if (w + 0x400000) & 0x800000 == 0:
     x = (w >> 11 & 0x1C0000 | w >> 5 & 0x3FFFF) - (p >> 12)
     w = w & 0x9000001F | x << 29 | x << 4 & 0x800000 | x << 3 & 0x7FFFE0
```

`/bin/zsh` (arm64e slice) is encoded with flags `0x002` on its code block; Silesia's `ooffice` (Windows DLLs) with
`0x004`.

## Containers that carry LZRAVEN

- **Apple Archive** (`aa archive -a lzraven`): `pbzm`, the block size (8 bytes, big-endian; 4 MiB by default),
  then per block its uncompressed and compressed sizes (8 bytes each, big-endian) and an LZRAVEN buffer
  (header word 1 is `0x44000000`). One block of a 1 MiB file was 3 LZRAVEN blocks: 162,272, 149,032 and 92
  bytes.
- **Apple Encrypted Archive** (`aea -a lzraven`, compression byte `m`): each segment (up to 16 MiB) is an
  LZRAVEN buffer of its stated size (`NativeAEA/FORMAT.md`).

## What this decoder does differently

Rejections Compression doesn't make, for input its encoders don't write: a nonzero end marker, bytes after the
end marker, and stored blocks over 512 KiB (whose second 512 KiB would take flags Compression never set). Errors:
`insufficientData` for input that ends early, `insufficientCapacity` when the output is too small, `mismatch`
for another size than `decompressAll(_:decodedSize:into:)` was given, `invalidValue` for everything else.
