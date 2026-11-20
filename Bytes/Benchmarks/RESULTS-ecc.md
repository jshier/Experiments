# Elliptic curves in BytesCrypto: P-256, P-384, HPKE (2026-11-18)

P-256 and P-384 in Swift (no C, no assembly): field and group arithmetic, ECDSA verification, ECDH, key formats
(X9.63, SEC 1, PKCS #8, SubjectPublicKeyInfo, PEM), strict DER reading, and HPKE (RFC 9180) base mode with
DHKEM(P-256, HKDF-SHA256). (Since 2026-11-19 keys read DER through the same parser as X.509, `AlignedBytesReader.
readASN1Contents(_:)` and `ASN1DER.swift`, in place of their own `DERReader`; keys and signatures also write DER and
PEM, `derRepresentation`/`pemRepresentation`; HPKE's `Sender` and `Recipient` are `~Copyable`: Bytes' RESULTS.md.) Benchmarked against CryptoKit (corecrypto). Results of the CompressionBenchmarks target's
`ECCBenchmarks.swift`: one operation per iteration, keys parsed beforehand, a 64-byte message (hashed in both).

## Results

Baseline `ecc-final`, run under the shared benchmark lock (p50; times in µs, instructions in thousands, mallocs per
operation):

| Operation | Bytes µs | CryptoKit µs | Bytes instr. | CryptoKit instr. | Bytes mallocs | CryptoKit mallocs |
|---|---|---|---|---|---|---|
| ECDSA verify P-256 (SHA-256, 64 B) | 54 | 91 | 812 | 1,757 | 0 | 3 |
| ECDSA verify P-256, DER parsed each time | 51 | | 819 | | 0 | |
| ECDSA verify P-384 (SHA-384, 64 B) | 206 | 227 | 2,818 | 4,211 | 0 | 3 |
| ECDH P-256 | 52 | 89 | 818 | 1,826 | 0 | 2 |
| ECDH P-384 | 189 | 244 | 2,951 | 4,317 | 0 | 2 |
| HPKE open, P-256 + AES-256-GCM, 32 B (context setup + open) | 61 | 105 | 849 | 2,101 | 0 | 150 |

Bytes is ahead of CryptoKit on every operation here: 1.7x on P-256, 1.1–1.3x on P-384, with half the instructions on
P-256. (CryptoKit's numbers include its API's costs, `Data` and key objects, which a 50 µs operation hardly notices;
where its time goes inside corecrypto wasn't investigated.) None of the Bytes operations allocates (thresholds at 0 in `Thresholds/CompressionBenchmarks.Allocations:*`); CryptoKit's
allocate 2–3 times per ECDSA or ECDH call and 150 times per HPKE context.

## Correctness

- Wycheproof (pinned in `Tools/test-data`), every vector, valid and invalid:
  - ECDSA: P-256/SHA-256 DER 484 (174 valid, 310 invalid), P1363 262 (173, 89); P-384/SHA-384 DER 504 (194, 310),
    P1363 280 (193, 87). DER reading rejects every BER form (long-form lengths that fit the short form,
    leading zeros, indefinite lengths, trailing bytes); r and s outside [1, n − 1]; signatures of the wrong size.
  - ECDH: P-256 SubjectPublicKeyInfo 612 (330 valid, 52 invalid, 230 acceptable), X9.63 points 355 (330, 24, 1),
    P-384 SubjectPublicKeyInfo 1047 (771, 46, 230). Of the acceptable ones, compressed points are accepted (with the
    right secret); BER encodings and explicit curve parameters are rejected.
- CryptoKit, both curves: random keys and signatures (DER, raw, digest), public keys from private ones, shared
  secrets, PEM/DER/X9.63 private keys, compressed points; a P-384 key verifying a SHA-256 digest.
- OpenSSL: `openssl ecparam -genkey` SEC 1 PEM (with its "EC PARAMETERS" block), P-256 and P-384.
- HPKE: RFC 9180's vectors for DHKEM(P-256, HKDF-SHA256)/HKDF-SHA256 with AES-128-GCM, AES-256-GCM, and
  ChaCha20-Poly1305 (`Tools/test-data fetch rfc9180`): DeriveKeyPair, enc, the key schedule, all 257 encryptions,
  and the exports. CryptoKit both ways for each AEAD. A vector made with CryptoKit as Apple's firmware archives wrap
  their keys. And a real iOS `.dmg.aea`: its `com.apple.wkms.fcs-response` opened with the key from Apple's server
  gave the expected archive key (`AEA_FCS_SAMPLE=dir swift test --filter realArchive`; the material isn't checked
  in).
- The field: random values checked for x·x⁻¹ = 1 (Fermat and binary inversions agree), x² = x·x, and the encoding
  round trip, for all four moduli; the moduli's constants checked against each other.

Run the tests in release when iterating: `swift test -c release -Xswiftc -enable-testing --filter 'ECC|HPKE'`
takes under a second; the debug build takes about four and a half minutes (Wycheproof's P-384 ECDH vectors alone,
four).

## Optimization log

Instructions per operation (thousands), each step against the previous; time is only indicative (other agents were
building and benchmarking).

| Step | P-256 verify | P-384 verify | P-256 ECDH | P-384 ECDH | HPKE open |
|---|---|---|---|---|---|
| v1: complete projective formulas everywhere, generic CIOS Montgomery, Fermat inversions | 1,422 | 5,308 | 1,138 | 4,395 | 1,168 |
| v2: P-256's special reduction (m·2⁹⁶ + m·c·2¹⁹²) | +5% | 0 | +7% | 0 | +7% |
| v3: rows as LLVM wide integers (i384/i512 adds) | +6% | +16% | +10% | +15% | +10% |
| v4: verification in Jacobian coordinates, width-7 NAF of u₁ over a static table of G's odd multiples, width-4 NAF of u₂ | 890 (−37%) | 3,314 (−38%) | | | |
| v5: dedicated Montgomery squaring | +5% | −4% | +2% | −2% | +2% |
| v6: constant-time ladder in Jacobian coordinates | | | 820 (−28%) | 3,160 (−28%) | 851 (−27%) |
| v7: s⁻¹ by binary extended Euclid (variable time; s is public) | 825 (−8%) | 2,984 (−8%) | | | |
| v8: Montgomery rows written out for 4 and 6 limbs | 0 | −2% | 0 | −3% | 0 |
| v9: the square's reduction written out (6 limbs) | +1% | −3% | 0 | −4% | 0 |
| v10: the dedicated square for P-256 too, its reduction written out | +3% | 0 | +5% | 0 | +5% |
| final (v9) | 812 | 2,818 | 818 | 2,951 | 849 |

From v1 to final: verification −43% (P-256) and −47% (P-384), ECDH −28% and −33%, HPKE −27%.
v2, v3, v10 and v5's P-256 square were reverted. Kept: v4, v6, v7, v8, v9, and the square for P-384 only.

## What worked, what didn't

- **Jacobian coordinates over complete formulas, also in constant time.** Renes–Costello–Batina's complete
  formulas have no special cases, so the first ladder was branch-free by construction, but a doubling costs 8M + 3S
  against Jacobian's 3M + 5S. In the fixed-window ladder only two special cases can occur (the accumulator still at
  the identity during leading zero windows, and a zero window): for k < n, the accumulator before window j's
  addition is 16k'·P with 16k' + d ≤ k < n, so 16k' = ±d (mod n) only when k' = 0. Computing the addition anyway and
  choosing among sum, entry, and accumulator with masks removed 28% of ECDH's instructions.
- **Verification is all public:** NAFs (width 7 for u₁ over 64 precomputed affine multiples of G, mixed additions;
  width 4 for u₂ over 8 Jacobian multiples of Q), comparing r·Z² with X instead of inverting Z, and inverting s by
  binary extended Euclid instead of Fermat: −42% together.
- **Written-out Montgomery rows.** LLVM kept the row loop rolled even with a constant trip count, so `t` lived in
  memory (loads and stores in every row). Calling an `@inline(__always)` row function four or six times by hand
  kept it in registers: P-384 −3 to −4% instructions per step, and −13 to −15% time, as loads and stores went.
- **What didn't:** P-256's shift-and-one-product reduction (the trick OpenSSL's assembly uses) cost 7% more
  instructions: LLVM already turns the products by its constant limbs into cheap sequences, and the special form
  needs extra carry handling. Sums of LLVM wide integers (`Builtin.Int384`, one adds/adcs chain per row instead of
  materialized carries) cut a standalone multiply from 284 to 185 instructions but cost 10–16% inlined into the
  point formulas (register pressure); a microbenchmark of the multiply alone didn't predict either. A dedicated
  square (cross products once) only paid off for 6 limbs, once its loops were written out.
- **Not tried, or left out:** Booth-recoded signed windows for the ladder (about 6% fewer additions, but signed digits
  bring partial values near n and the special-case argument above would need redoing); addition chains for the
  Fermat inversions (about 50 multiplications of ~3,500); a fixed-base comb for deriving public keys (key parsing
  isn't measured); ECDSA signing.

## Constant time

- Constant-time in the private key: ECDH and deriving a public key (`JacobianPoint.multiply`, then a Fermat
  inversion). Every window does four doublings and one addition; the table entry is read by visiting all 15 entries
  under masks (compiled to `csel`), and the addition's special cases are resolved with masks. Field arithmetic has
  no data-dependent branches (carries by arithmetic, the final subtraction by mask). In the compiled ladder every
  conditional branch tests a loop counter, a public table index's parity while building the table, or the stack
  guard (checked with objdump).
- Not constant-time: verification (public inputs), the binary inversion (used only for s), parsing (whether a key is
  well formed, including its range check and the comparison of an embedded public key).

## Lessons (for AGENTS.md)

- **Elliptic curves: Jacobian coordinates with masked special cases beat complete formulas for constant-time ladders**
  (−28% ECDH instructions). Prove which cases can arise for scalars below n, compute the addition anyway, and select.
- **Write out fixed-count outer loops of multi-limb arithmetic.** LLVM didn't unroll Montgomery's row loop even with a
  constant trip count; four or six explicit calls of an `@inline(__always)` row kept the accumulator in registers
  (P-384 −13% time, −3% instructions). Check with `Tools/loops`: the point formulas should show no loops.
- **A standalone microbenchmark of a field multiply doesn't predict it inlined into point formulas:** wide-integer
  rows (i384) and P-256's special reduction both won alone and lost in context. Measure the whole operation.
- **Public scalars take variable-time algorithms:** NAFs and binary inversion for ECDSA verification (−8% for s⁻¹
  alone), constant-time code only where a secret is involved.
- **`#expect` can't take spans as arguments of the call it checks** (`#expect(key.isValid(sig, for: bytes.span.bytes))`
  fails to compile): wrap with array-taking helpers. Nested `#require` inside `#require` doesn't compile either.
- **Fast iteration on crypto tests:** `swift test -c release -Xswiftc -enable-testing` keeps `@testable` working;
  EC arithmetic in debug builds is several hundred times slower (Wycheproof's ECC files: 0.6 s against 260 s).
