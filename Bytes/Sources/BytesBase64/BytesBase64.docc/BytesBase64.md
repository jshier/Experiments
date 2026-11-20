# ``BytesBase64``

Base64 (RFC 4648) on Bytes' cursors: vectorized, strict, and without allocating.

## Overview

``Base64`` encodes from an `AlignedBytesReader` (or a `RawSpan`) into an `AlignedBytesWriter`, and decodes back,
in the standard and URL-safe alphabets or any other, padded or not. Into memory you provide, nothing is allocated;
`encodedString` and `decodedBytes` allocate only their result.

```swift
import Bytes
import BytesBase64

// Into memory you provide: no allocation.
var output = [UInt8](repeating: 0, count: Base64.encodedByteCount(of: bytes.count))
var span = output.mutableSpan
var writer = AlignedBytesWriter(&span)
try Base64.encode(bytes.span.bytes, into: &writer, alphabet: .urlSafe)

let text = Base64.encodedString(bytes.span.bytes)          // one allocation: the String
let decoded = try Base64.decodedBytes(text)                // one allocation: the array
let der = try Base64.decodedBytes(ignoringWhitespaceIn: pem)  // Base64 in lines (PEM, MIME, XML)
```

- Encoding checks for room first: it throws `insufficientCapacity` before reading or writing anything.
- Decoding is strict and all or nothing: only the alphabet's characters, `=` only as the padding the last group
  needs, and the last character's unused bits zero, so each text has one decoding. A failure throws
  `LocatedBytesError` at the offending character; the reader hasn't moved and the writer is back where it started.
- ``Base64/decode(ignoringWhitespaceIn:into:alphabet:padding:)`` skips spaces, tabs, and line breaks, without
  allocating: text in lines decodes into the caller's buffer.
- ``Base64/Alphabet/init(character62:character63:)`` makes other alphabets.

On ARM64 (`ByteLanes.isLookupVectorized`: Bytes' `NEONShuffle` trait, not `Portable`) the kernels work on 48-byte
blocks (encoding, 29–32 instructions each) and 64-character blocks (decoding, 49) with NEON table lookups; on an M3
Ultra one core encodes about 21 GB/s and decodes about 12.8 GB/s, 4–7x Foundation. Elsewhere, 3-byte and 4-character
groups with arithmetic, which LLVM auto-vectorizes. Bytes' `Benchmarks/RESULTS-base64.md` has the measurements and
what was tried.

Base64 is its own module, not part of `Bytes`, so adding it doesn't change how the core module's code inlines.

## Topics

### Encoding and decoding

- ``Base64``
- ``Base64/Alphabet``
