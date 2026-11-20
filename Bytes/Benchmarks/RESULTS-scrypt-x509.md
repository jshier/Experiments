# scrypt and X.509 in BytesCrypto (2026-11-18)

Apple M3 Ultra, Xcode 27.3's Swift 6.4. Timed runs under the shared benchmark lock while other agents built; instruction
and malloc counts are exact. Baselines: `.benchmarkBaselines/CompressionBenchmarks/{scrypt-final,x509-v1,x509-v2}`.

## scrypt (RFC 7914): `Sources/BytesCrypto/Scrypt.swift`

```swift
Scrypt.scratchByteCount(cost: n, blockSize: r, parallelism: p, lanes: 1) throws(BytesError) -> Int
Scrypt.deriveKey(password:salt:cost:blockSize:parallelism:lanes:scratch:into:) throws(BytesError)  // allocates nothing
Scrypt.deriveKey(password:salt:cost:blockSize:parallelism:lanes:into:) throws(BytesError)          // one buffer per call
```

PBKDF2-HMAC-SHA256 (the existing `PBKDF2`) → ROMix per block → PBKDF2. Scratch is `p·128r` (B) plus, per lane,
`(N + 2)·128r` (V, then X and Y, which BlockMix alternates between; V[i+1] is written straight from V[i], no copy).
Parameters are checked as RFC 7914 states (N a power of two above 1, r·p < 2³⁰, N < 2^(16r)) and overflow, and throw
`invalidValue` rather than trap: AEA headers carry them. `lanes` > 1 runs the `p` ROMix calls on
`DispatchQueue.concurrentPerform`, a table per lane.

Tests (`Tests/BytesCryptoTests/ScryptTests.swift`): RFC 7914's four vectors (the N = 2²⁰ one in optimized builds only,
30 s in debug), 40 random parameter sets (N 2..4096, r 1..9, p 1..4, keys 1..100 bytes) against `hashlib.scrypt`
(OpenSSL 4.1) through `python3 -I`, scratch and allocating forms, one lane and `p` lanes; parameter rejection.

### Salsa20/8: scalar beats vector here

A single scrypt lane has no independent work: every Salsa20/8 starts from the previous one's output, and within it the
32 quarter-round steps of the 4 double rounds form one dependent chain (four quarter rounds side by side). So it's
latency that counts, not width:

| ROMix kernel, N = 2^14, r = 8 (min of 20) | time | per Salsa20/8 |
|---|---:|---:|
| scalar, 16 words in general registers (`add` + `eor …, ror #k` per step) | 16.5 ms | ~127 cycles |
| `SIMD4<UInt32>` diagonals (Percival's SSE layout: `add.4s`, `shl`+`usra`, `eor3`, `ext` for the lane rotations) | 49.2 ms | ~380 cycles |

The vector form compiled cleanly (`Tools/loops`: `vector128`, rounds unrolled, 176 instructions per block, no lane
moves) but each step is four dependent vector instructions of 2–3 cycles; the scalar step is two. 32 steps × ~3
cycles ≈ 96 cycles plus the block boundary is the scalar bound measured. (Harness and variant code were in the
scratchpad: kept out of the library.) Vector code would pay only with four or more independent blocks, i.e. p ≥ 4 on
one thread; threads already give that (below).

One fix in the scalar code: with the 16 words loaded and stored as consecutive `UInt32`s, LLVM's SLP vectorizer turned
the XOR-in before the rounds and the feed-forward add after them into vector operations with every word moved between
register files (24 `mov.s`/`fmov` per block, on the chain from block to block). Loading and storing 64-bit pairs keeps
them scalar (`Tools/loops --target Bytes BytesCrypto romix --forbid mov.s,fmov,ins,umov` passes): median 18.2 → 17.1 ms
over 4 interleaved rounds (−6%), the same as compiling with `-vectorize-slp=false` (17.0 ms), though instructions rose
181 M → 194 M (`lsr`/`orr` to split and join pairs).

### Against OpenSSL

OpenSSL 4.1.0 (Homebrew) through Python's `hashlib.scrypt` in one process (min/median over 3–192 runs, its 16 MiB–1 GiB
allocation included), and the `openssl kdf … SCRYPT` command (hyperfine, process start included):

| r = 8, p = 1 | Bytes, scratch | Bytes, allocating | OpenSSL (hashlib) | OpenSSL CLI | Bytes vs hashlib |
|---|---:|---:|---:|---:|---:|
| N = 2^14 (16 MiB) | 17.0 ms | 17.0 ms | 25.6 ms | 31.3 ms | 1.51x |
| N = 2^16 (64 MiB) | 70 ms | 72 ms | 107 ms | 116.6 ms | 1.53x |
| N = 2^18 (256 MiB) | 289 ms | 295 ms | 432 ms | 447.7 ms | 1.50x |
| N = 2^20 (1 GiB) | 1,167 ms | 1,174 ms | 1,781 ms | 1,705 ms | 1.53x |

Instructions (scratch): 194 M, 774 M, 3.10 G, 12.0 G: linear in N. Time per Salsa20/8 grows from 29 ns (N ≤ 2^14) to
35–36 ns at 2^16 and above: ROMix's second loop reads V[j] at a data-dependent j, and the first two cache lines of each
block are needed at once, so one DRAM (and TLB) miss per BlockMix is exposed; it can't be prefetched, j is known only
when the previous BlockMix ends. The allocating form costs one malloc and two passes over the memory (zeroing before,
clearing after): +0–3%.

p = 4, N = 2^14: 70 ms on one lane, 17 ms on four (4.1x; same 775 M instructions).

Mallocs: `Allocations:Scrypt_N1024_r8_p2_scratch` = 0, threshold in `Thresholds/`. (Only one lane: package-benchmark's
malloc interposer traps on threads Dispatch starts.)

## X.509: `Sources/BytesCrypto/ASN1DER.swift`, `Sources/BytesCrypto/X509Certificate.swift`

- `ASN1Tag`, `ASN1Element` (tag + byte ranges), `AlignedBytesReader.readASN1Element()` / `readASN1Element(_:)` /
  `nextASN1Tag`: strict DER on Bytes' aligned reader (definite, shortest-form lengths of at most 4 bytes, low tag
  numbers, every element inside the span it's read from).
- `ASN1ObjectIdentifier`: contents inline (≤ 63 bytes), `Hashable`, dotted `description` and `init(_: String)`,
  constants for the algorithms, curves, name attributes, extensions, and extended key usages a chain check needs.
- `X509Time`: UTCTime/GeneralizedTime (RFC 5280 forms only), `Comparable`, `secondsSince1970`.
- `X509Certificate: ~Escapable` (views of the DER): `tbsCertificate`, `signatureAlgorithm` (+ parameters), `signature`,
  `serialNumber`, `issuer`/`subject` (`X509Name`: raw `der` for chain matching, `commonName`, `first(_:)`, attributes
  iterator with string decoding for UTF8/Printable/IA5/Teletex/BMP/Universal), `notBefore`/`notAfter`,
  `subjectPublicKeyInfo`, `publicKeyAlgorithm`, `publicKeyParameters`, `namedCurve`, `publicKey` (X9.63 point or
  PKCS #1), `basicConstraints`, `keyUsage` (`OptionSet`), `extendedKeyUsage` (iterator + `contains`), `extensions`
  (iterator of `X509Extension`: identifier, critical, value), `extension(_:)`, `isSelfIssued`.
- `X509Certificate.decodePEM(_:)` (`RawSpan` or `String`): every `CERTIFICATE` block, strict Base64; other labels skipped.

Rejected besides malformed TLVs: trailing bytes anywhere, non-minimal INTEGERs, BOOLEANs other than 00/FF, bit strings
with set padding bits (or any unused bits in the signature and key), bad times, malformed OIDs, inner/outer signature
algorithm mismatch, duplicate extensions, extensions before v3, unique IDs in v1, and DEFAULT values written out
(critical/cA FALSE, version v1; none of the 151 system roots has one). Not checked: SET OF ordering.

Tests (`Tests/BytesCryptoTests/X509Tests.swift`), all passing in debug and release:
- all 151 system roots (`security find-certificate -a -p …SystemRootCertificates.keychain`) and the Xcode 27.3 beta 2
  archive's 3-certificate chain: serial, validity, signature algorithm, curve, extensions (basicConstraints, keyUsage,
  EKU), and SubjectPublicKeyInfo against `openssl x509` output; serial, validity, common name, and public key against
  Security (`SecCertificateCopySerialNumberData`, `…NotValidBefore/AfterDate`, `…CopyCommonName`, `SecKeyCopyExternal-
  Representation`); signatures verified with `SecKeyVerifySignature` using the parsed key, TBS bytes, algorithm, and
  signature (every self-signed root with an ECDSA or PKCS #1 algorithm, and each link of the Xcode chain up to Apple
  Root CA - G3, which is byte-identical to the system's);
- chains made by `openssl` at test time in a temporary directory (P-384 root, P-256 intermediate and leaf, RSA leaf and
  RSA-SHA512 root; GeneralizedTime past 2050, a leap day, 1970, high-bit serials, UTF-8 CN, custom extension), same
  checks plus exact values;
- every truncation of each sample (must throw) and 2,000 random 1–3 byte mutations per sample (must throw or parse and
  then read in full; run in debug, so overflow and bounds traps would fail the test);
- hand-built certificates with one malformed field each, DER element edge cases, times, OIDs, PEM.

Parsing, per certificate (x509-v2 = final):

| | instructions | time | mallocs |
|---|---:|---:|---:|
| Apple Root CA - G3 (583 B, P-384, 3 extensions): Bytes | 8.1 K | 0.40 µs | 0 |
| same, parse and read names, key, signature, extensions | 9.5 K | 0.46 µs | 0 |
| same: Security `SecCertificateCreateWithData` | 36 K | 1.76 µs | 11 |
| ACCVRAIZ1 (2,007 B, RSA 4096, 9 extensions): Bytes | 12 K | 0.59 µs | 0 |
| same, parse and read | 15 K | 0.74 µs | 0 |
| same: Security | 97 K | 5.0 µs | 34 |

The first version (x509-v1) took 14 K and 28 K: it walked the whole certificate's structure before parsing it, and
checked each extension for duplicates by parsing every earlier extension again (quadratic). Walking only what the
parse doesn't read (constructed algorithm parameters and name values) and keeping the first 16 extension identifiers'
ranges on the stack: −42% and −57%. `Allocations:X509_parse_and_read_{G3,ACCVRAIZ1}` = 0, thresholds in `Thresholds/`.
Reading `commonName` makes a `String` (allocates past 15 bytes); the spans and OIDs don't.

## Unfinished

- RSA-PSS signature parameters and Ed25519 aren't cross-checked with Security (it can't verify them as certificate
  signatures here); they parse as raw parameters/keys.
- No name constraints, policies, or subjectAltName decoding: available as raw `X509Extension` values.
- `X509Certificate` is `~Escapable`: keep the DER and parse again to store one (0.4–0.6 µs).

## Lessons for AGENTS.md

- **Vectorize for independent work, not for a dependent chain.** Salsa20/8 as `SIMD4<UInt32>` diagonals compiled to
  clean `vector128` code and ran 3x slower than 16 scalar words: each step is 4 dependent vector instructions (2–3
  cycles each) against `add` + `eor …, ror #k`. scrypt with p = 1 is one chain end to end; threads for p > 1.
- **SLP vectorizes the edges of scalar kernels.** Sixteen consecutive `UInt32` loads XORed into scalar state, and
  sixteen stores of scalar results, became vector ops with a lane move per word on the critical path. Loading and
  storing `UInt64` pairs (split with a shift) kept them scalar, −6%. Check scalar kernels with `Tools/loops --forbid
  mov.s,fmov,ins,umov`.
- **`#expect` can't take `~Escapable` operands**: its expansion passes subexpressions to generic helpers requiring
  `Escapable` ("requires that 'RawSpan' conform to 'Escapable'"). Compute a `Bool` or `Escapable` value into a local
  first. Likewise `Optional.map` and `#require` don't take `~Escapable` values: use `if let`/`guard let`.
- **`array[i].span` is a temporary's span** ("lifetime-dependent value escapes its scope"): bind `let x = array[i]` first.
- **Validation passes add up**: a structure walk before a parse plus a quadratic duplicate check doubled X.509 parsing
  (14 K → 8.1 K instructions after removing both). Check only what the parse doesn't read.
- **Watching for a job with `pgrep -f` inside a Monitor/until loop** has the same trap as AGENTS.md's `until ! pgrep`:
  the loop's own command line matches. Wait on the output file's contents instead.
- **Release tests need `-Xswiftc -enable-testing`** for `@testable import` (`swift build -c release --build-tests
  -Xswiftc -enable-testing`, same for `swift test`).
