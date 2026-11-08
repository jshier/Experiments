# Base64

A Base64 encoder (RFC 4648, standard and URL-safe alphabets, with or without padding) built on
[`Bytes`](../Bytes): it reads with `BytesReader`, writes with `BytesWriter`, allocates nothing, and is
vectorized. On an M3 Ultra one core encodes 21 GB/s, 6–7x Foundation's `base64EncodedData()` and 25x a scalar
table encoder; see `Benchmarks/RESULTS.md`.

```swift
import Base64
import Bytes

// Into memory you provide: no allocation.
var output = [UInt8](repeating: 0, count: Base64.encodedByteCount(of: bytes.count))
var span = output.mutableSpan
var writer = BytesWriter(&span)
var reader = BytesReader(bytes.span)
try Base64.encode(&reader, into: &writer)                        // the rest of the reader, at the writer

try Base64.encode(bytes.span.bytes, into: &writer, alphabet: .urlSafe, padding: false)
let text = Base64.encodedString(bytes.span.bytes)               // one allocation: the String
```

- `encode` checks for room first: it throws `insufficientCapacity` before reading or writing anything.
- `Base64.Alphabet(character62:character63:)` makes other alphabets.

## How it's vectorized

Input is read as typed spans of fixed-size blocks and output written the same way, so each kernel is a loop
from one span to another, with its bounds checks folded out of the loop.

- **ARM64:** 48-byte blocks, 29–32 instructions per block (Swift 6.5 / 6.4), using three helpers added to
  Bytes for this:
  - `ByteLanes.deinterleave` splits a block into its groups' first, second, and third bytes, as `ld3` does
    when loading (3 `tbl`);
  - shifts and masks make each group's four 6-bit values;
  - `ByteLanes.lookup(in:)` maps them to characters in the 64-byte alphabet (4 `tbl`);
  - `ByteLanes.interleave` puts the characters in order, as `st4` does when storing (`zip`s, which LLVM
    turns partly into `st2` stores).
  The last 0 to 47 bytes are encoded as one more block, zero-padded.
- **Other CPUs** (no single-instruction table lookup): 3-byte groups to 4-character groups, mapped with
  arithmetic, which LLVM auto-vectorizes (on ARM64 it's `ld3`, compares, and `st4`, 62–77 instructions per
  48 bytes).

`../Tools/loops` builds the module and checks both kernels' loops in the object code: the ARM64 kernel must
use `tbl` and `zip` with no lane-by-lane inserts, and the portable one must use `ld3.16b` and `st4.16b`. It
prints each loop's instruction mix. Set `TOOLCHAINS` to check another toolchain.

## Tests and benchmarks

```sh
swift test                                    # RFC 4648 vectors; every length to 200 and some larger, in both
                                              # alphabets, with and without padding, against Foundation
../Tools/loops --target . Base64 encodeBlocks --require tbl,zip --forbid mov.b,ins          # ARM64 kernel
../Tools/loops --target . Base64 'encode\(_:into:alphabet:\)' --require ld3.16b,st4.16b  # portable kernel
swift package --disable-sandbox benchmark     # throughput and allocations
swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:.*'  # fails if encoding allocates
```

## Caveats

- Requires the 2027 OS releases, Swift 6.4, and the experimental `Lifetimes` feature (as `Bytes` does).
- Encoding only.
- The ARM64 kernel needs Bytes' `NEONShuffle` trait (on by default), which provides NEON's `tbl` and `zip`
  through a small C module, because Swift can't express them. Without it, encoding uses the portable kernel.
