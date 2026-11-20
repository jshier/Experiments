# RSA signature verification in BytesCrypto (2026-11-19)

PKCS #1 v1.5 RSA verification in Swift, for NativeAEA's `.xip` expansion: a XAR archive's table of contents carries a
2048-bit RSA signature of its SHA-1 checksum, and a certificate chain "Software Update" → "Apple Software Update
Certification Authority" → "Apple Root CA" signed with sha256WithRSAEncryption. Apple M3 Ultra, Xcode 27.3's Swift 6.4.
Baselines: `.benchmarkBaselines/CompressionBenchmarks/{rsa-v1,rsa-final}`.

## API (`Sources/BytesCrypto/RSA.swift`, `X509Certificate.swift`)

```swift
public enum RSA {
    public enum DigestAlgorithm: Sendable, Hashable, CaseIterable {
        case sha1, sha256, sha384, sha512
        public var digestByteCount: Int { get }
        public init?(signatureAlgorithm: ASN1ObjectIdentifier)        // sha{1,256,384,512}WithRSAEncryption
    }
    public struct PublicKey: Sendable, Equatable {
        public static var minimumModulusBitCount: Int { get }         // 1024
        public static var maximumModulusBitCount: Int { get }         // 4096
        public let publicExponent: UInt64
        public let modulusBitCount: Int
        public var modulusByteCount: Int { get }
        public init(modulus: RawSpan, publicExponent: RawSpan) throws(BytesError)
        public init(derRepresentation: RawSpan) throws(BytesError)    // SubjectPublicKeyInfo or PKCS #1 RSAPublicKey
        public init(pemRepresentation: String) throws(BytesError)     // "PUBLIC KEY" or "RSA PUBLIC KEY"
        public init(certificate: borrowing X509Certificate) throws(BytesError)
        public var modulusBytes: [UInt8] { get }
        public var pkcs1DERRepresentation: [UInt8] { get }
        public var derRepresentation: [UInt8] { get }                 // SubjectPublicKeyInfo
        public var pemRepresentation: String { get }
        public func isValidSignature(_ signature: RawSpan, digest: RawSpan, digestAlgorithm: DigestAlgorithm) -> Bool
        public func isValidSignature(_ signature: RawSpan, for message: RawSpan, digestAlgorithm: DigestAlgorithm) -> Bool
    }
}
extension X509Certificate {
    public func isSigned(by issuer: borrowing X509Certificate) -> Bool  // RSA PKCS #1 v1.5 and ECDSA P-256/P-384
}
```

- Moduli of 1024 to 4096 bits (any length in between, odd), exponents odd, from 3 to 2⁶⁴ − 1. 1024-bit keys and
  SHA-1 are accepted for old signatures and documented as weak.
- Verification is RFC 8017's 8.2.2 with nothing parsed: the signature must be exactly k bytes and below n; s^e mod n is
  compared with the EMSA-PKCS1-v1_5 encoding built from the digest (`00 01 FF…FF 00`, the DigestInfo DER with its
  `NULL`, the digest). DigestInfo without the `NULL` (Wycheproof's "acceptable" MissingNull) is rejected.
- `SubjectPublicKeyInfo` must name `rsaEncryption` with `NULL` parameters (RFC 3279); X.509 signature algorithms may
  have `NULL` or absent parameters (RFC 4055 says verifiers accept both).
- Variable time (only public values), no allocation per verification (thresholds `Allocations:RSA_verify_2048` and
  `Allocations:RSA_public_key_2048_parse` at 0).
- RSA-PSS, signing, and encryption aren't implemented. `isSigned(by:)` doesn't do P-521 (one system root uses it).

### The `.xip` signature and chain

```swift
// header: "xar!", UInt16 header size, UInt16 version, UInt64 TOC compressed size, UInt64 TOC uncompressed size,
// UInt32 checksum algorithm (1 = SHA-1), big-endian. The heap follows the compressed TOC; the TOC's <checksum> and
// <signature> give offsets in it (0 and 20 in Xcode's: the TOC's SHA-1, then 256 bytes of signature).
guard SHA1.hash(compressedTOC) == storedChecksum else { throw … }        // compare the 20 bytes
let leaf = try X509Certificate(derEncoded: leafDER.span.bytes)            // <X509Certificate> 1, Base64
let intermediate = try X509Certificate(derEncoded: intermediateDER.span.bytes)
let root = try X509Certificate(derEncoded: appleRootCADER.span.bytes)     // trusted by its bytes (or SHA-256)
for (certificate, issuer) in [(leaf, intermediate), (intermediate, root)] {  // schematically: ~Escapable
    guard constantTimeEquals(certificate.issuer.der, issuer.subject.der),
          issuer.basicConstraints?.isCertificateAuthority == true,
          issuer.keyUsage?.contains(.keyCertSign) ?? true,
          certificate.isSigned(by: issuer) else { throw … }
}
let key = try RSA.PublicKey(certificate: leaf)
guard key.isValidSignature(signature.span.bytes, digest: storedChecksum.span.bytes, digestAlgorithm: .sha1) else { throw … }
```

The signature is PKCS #1 v1.5 with SHA-1's DigestInfo around the stored checksum (the checksum is the "digest"; the
TOC isn't hashed again): checked for Xcode 27.1 RC, 27.2 RC, and 27.3 beta, natively and with Security's
`.rsaSignatureDigestPKCS1v15SHA1`.

## Tests (`Tests/BytesCryptoTests/RSATests.swift`)

Release: `swift test -c release -Xswiftc -enable-testing --filter RSATests` (5 s; debug 95 s, Wycheproof most of it).

- **Wycheproof** (pinned in `Tools/test-data`, set `wycheproof`): `rsa_signature_{2048,3072,4096}_sha{256,384,512}`
  and the signature-generation sets `rsa_pkcs1_{1024,1536,2048,3072,4096}_sig_gen` (their signatures verified; they
  bring SHA-1, 1024- and 1536-bit keys, e = 3). 2,464 vectors: 140 valid, 2,253 invalid, 71 acceptable (verified
  except MissingNull), all as expected; 24 SHA-224 vectors skipped. Every key also from its PKCS #1 DER and PEM, and
  written back byte for byte. The digest and message forms agree on every vector.
- **Security**, keys from `SecKeyCreateRandomKey` at 1024, 1536, 2048, 3072, 4096 bits: signatures Security makes
  (message and digest forms) over random messages with SHA-1/256/384/512 verify; another hash, a flipped bit in the
  signature (rejected by Security too), a changed message, signatures one byte short or long, and short digests
  don't; edge signatures 0, 1, n − 1, n, all ones are rejected by both. Keys round-trip through DER and PEM.
- **OpenSSL** (`openssl genrsa`, 4.1): 1100, 2048, 2056 (e = 3), 3000, 4096 (e = 3) bits, sizes that aren't whole
  limbs or bytes; "PUBLIC KEY" and "RSA PUBLIC KEY" PEM; `openssl dgst -sign` with each hash.
- **System roots**: every self-issued root Security verifies: `isSigned(by:)` agrees on all of them (104 RSA, 2048
  and 4096 bits; 45 ECDSA); the P-521 root isn't verified. Apple Root CA and Apple Root CA - G3 against each other's
  keys, a flipped signature byte.
- **Xcode archives**: every `.xip` in ~/Downloads (skipped when there's none; nothing is checked in): the TOC's
  SHA-1 is the stored checksum, the leaf's key verifies the signature (Security agrees), the chain verifies natively
  to the system's Apple Root CA, and a changed checksum or the wrong hash fails.
- **Keys**: modulus sizes 1023 and 4097 and 8192, even moduli, exponents 1, 2, even, over 64 bits; negative and
  non-minimal integers, trailing bytes; SubjectPublicKeyInfo without `NULL`, with a non-empty `NULL`, with RSASSA-PSS's
  identifier; the limb count for each size class; −n⁻¹ mod 2⁶⁴.

## Results

Baseline `rsa-final` (`RSABenchmarks.swift`), one run under the shared benchmark lock (p50; µs, instructions in
thousands, mallocs per operation). Keys with e = 65537 from `SecKeyCreateRandomKey`, a 64-byte message hashed with
SHA-256 by both; Security's public key made from the PKCS #1 DER with `SecKeyCreateWithData`.

| Operation | Bytes µs | Security µs | Bytes instr. | Security instr. | Bytes mallocs | Security mallocs |
|---|---|---|---|---|---|---|
| verify 2048 | 13 | 19 | 294 | 338 | 0 | 14 |
| verify 4096 | 42 | 65 | 1,015 | 1,119 | 0 | 14 |
| parse public key 2048 (Bytes: with R² mod n) | 5.9 | 6.8 | 109 | 101 | 0 | 10 |
| parse public key 4096 | 17 | 16 | 372 | 268 | 0 | 10 |
| parse and verify 2048 (a chain's or an archive's use) | 17 | 24 | 401 | 439 | 0 | 24 |
| parse and verify 4096 | 58 | 80 | 1,388 | 1,386 | 0 | 24 |

Bytes verifies 1.5x as fast as Security at both sizes, and parse-and-verify 1.4x. Security's instruction counts are
close to Bytes' (corecrypto's Montgomery code is assembly; the difference is time per instruction, and its API's
14 allocations per call). Against `rsa-v1` (the first version): verification −24% instructions, −38% time (2048) and
−33%, −42% (4096); key parsing −79% and −82%.

The key matters for Security: the public key `SecKeyCopyPublicKey` returns for a generated private key took 150 µs
(2.7 M instructions, 30 mallocs) per 2048-bit verification in `rsa-v1`'s run, 7x the key made from DER (22 µs in a
separate check). The benchmarks now use the DER key, which is what a client reading a certificate gets.

Codegen (`Tools/loops … 'RSAModulus\.(multiply|square|reduce)\(' --forbid brk,bl --require umulh,adcs`: ok for all
five sizes): the product loop is 28 instructions per 4 products: 4 `ldp`, 4 `mul`, 4 `umulh`, 4 `adds`, 4 `adcs`,
2 `cset`, 2 `adc`, and 4 of loop control; no bounds checks, no calls. `Tools/calls`: the hot path calls only
`square`, `multiply`, and `reduce` (and SHA's block function); `memcpy`/`bzero` of the 256–512-byte blocks happen per
verification, outside the loops.

## Optimization log

Instructions and cycles per verification from a harness against the worktree's BytesCrypto (`/usr/bin/time -l`,
the difference between 1,000 and 3,000 verifications of one signature, SHA-256 of 64 bytes, e = 65537); time per
verification from its clock. Key parsing ("parse") includes the precomputation.

| Version | 2048 instr. | 2048 cycles | 2048 µs | 4096 instr. | 4096 cycles | parse 2048 instr. |
|---|---|---|---|---|---|---|
| v1: CIOS (operand scanning, each row's product and reduction in one pass), `InlineArray` subscripts, squares by the multiply, R^e mod n precomputed | 385 K | 66.8 K | 19.0 | 1,517 K | 268 K | 520 K |
| v2: product scanning (FIPS: a column of a·b + q·n at a time in a three-limb accumulator) | 366 K | 61.1 K | 17.4 | 1,423 K | 248 K | 494 K |
| v3: + dedicated squaring (cross products once, doubled) | 377 K | | 14.5 | 1,431 K | | 502 K |
| v4: limbs through pointers into a stack workspace (no bounds checks) | 315 K | | 12.8 | 1,180 K | | 425 K |
| v5: inner loops unrolled ×2 (`ldp` pairs) | 298 K | 44.9 K | 12.3 | 1,086 K | 176 K | 399 K |
| v6: unrolled ×4 | 275 K | 44.2 K | 12.2 | 969 K | 176 K | 370 K |
| v7: two accumulators per product loop | 293 K | 41.6 K | 11.5 | 1,008 K | 155 K | 395 K |
| v8: two accumulators per column (`Column`) | 283 K | 41.9 K | 11.9 | 984 K | 156 K | 380 K |
| v9 (final): R² mod n precomputed instead of R^e; out of Montgomery form by reduction alone | 292 K | 42.6 K | 12.4 | 1,014 K | 164 K | 109 K |

From v1 to final: verification −24% instructions, −36% cycles (2048 bits) and −33%/−39% (4096); parsing −79%.

- **v1 → v2, product scanning.** CIOS's inner loop (two products per column of a row) was 20 instructions: two
  separate carry chains, each `mul`, `umulh`, `adds`, `cset`/`cinc`, `adds`, `adc`, plus loads, the store of t, and
  the loop. Product scanning accumulates a column in three limbs: `mul`, `umulh`, `adds`, `adcs`, `cinc` per product
  (`multipliedFullWidth` and two `addWithCarry`s compile to exactly that), and stores each result limb once.
- **v3, the dedicated square** (n(n + 1)/2 products for a² instead of n²; the reduction's n² stay) should have saved
  ~25% of the products, but its loops had the bounds checks too, and the instruction count went *up* 3%. (Times in
  this table before v5 were taken in different sessions and aren't comparable with each other.)
- **v4, bounds checks.** With `InlineArray` subscripts, the product loops (`a[j]`, `b[i − j]`, j < i) kept two
  `cmp`s and a `b.hi` to a trap per product: LLVM couldn't prove i − j in range (with `&-` or with checked `-`, which
  was worse: 394 K). The arithmetic now takes pointers into one stack `InlineArray<6, InlineArray<limbs, UInt64>>`
  (`withWorkspace`), every index in range by its loop's bounds, said at each `unsafe`. `InlineArray.subscript(unchecked:)`
  and `.span` on a `borrowing` parameter copied the whole array first (256–512 bytes per call), so they weren't used.
- **v5–v6, unrolling.** The product loops (now `addProducts`: Σ x[k]·y[−k]) unrolled by 4 with a one-at-a-time
  remainder: loads pair into `ldp`s and the loop's own instructions (two pointer updates, a counter, compare, branch)
  are paid once per four products. 7.25 instructions per product against 9.
- **v6 → v8, two carry chains.** At 6.2 instructions per cycle, fewer instructions stopped paying: v6 took fewer
  instructions and no fewer cycles. Each product's `adds`/`adcs` waited on the previous one's; alternating products
  between two accumulators (`Column.t`, `Column.u`, merged once per column) took 3–5% fewer cycles at 2048 bits and
  8–10% at 4096 (interleaved A/B runs, three rounds), for 2–3% more instructions. (v7 merged per product loop, two per
  column: more instructions for the same cycles.) A 2048-bit verification is about 30,000 products (60,000 `mul` and
  `umulh`) in 42,600 cycles: 1.4 cycles per product, at 6.9 instructions per cycle.
- **v9, R² instead of R^e.** v1–v8 precomputed R^e mod n per key, so that the signature could enter the Montgomery
  exponentiation as it was (s taken as sR⁻¹'s Montgomery form gives s^e·R^(1−e), and one product with R^e leaves s^e):
  18 Montgomery operations per verification, but an exponentiation per key. A certificate chain and a `.xip` use
  each key once, so parsing counts as much as verifying: with R² mod n (doublings to 2^(64·limbs + limbs), then six
  squarings) the key costs a third of a verification, and verification takes one more product to enter Montgomery
  form, plus a reduction alone (no a·b products) to leave it: +3% for verification, −71% for parsing, parse + verify
  −40%.

## What didn't work or wasn't tried

- Checked `-` in place of `&-` for the indices (v3 → 394 K instructions): the checks stayed, and overflow checks
  joined them.
- Karatsuba for the square's cross products would save about 8% of a 2048-bit verification's products at the cost
  of additions and temporaries; not tried. Nor a 2-column product scan (each loaded limb used twice).
- RSA-PSS: not implemented (nothing here needs it).
