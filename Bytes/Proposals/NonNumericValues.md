# Parsing non-numeric values without tricks (2026-11-18)

A review of how Bytes' clients parse what isn't a number (tags and signatures, ASCII characters, digits, flags,
lengths) and where getting the fast code meant knowing an operator or numeric trick: wrapping arithmetic,
unsigned-compare range tests (`byte &- 0x30 < 10`), case folding with `| 0x20`, hex constants for ASCII tags in
memory order, SWAR digit parsing, splatted vectors for lane comparisons. Read-only survey of BinaryParsingComparison's
ports, MQTT, NativeZip, NativeISO8601, Base64, SocketStream, and Bytes' own codecs.

Most of it was already well hidden: named bit fields, `@BitFields`, `BitPattern`, `requireZero`, enum reads, and
`read(Int.self, as: Byte2.self)` cover flags, enums, and lengths. The gaps were ASCII text, ASCII tags, and magic
numbers.

## Implemented (`Sources/Bytes/ASCII.swift`; measurements in `../Benchmarks/RESULTS.md`)

| API | Replaces | Measured |
|---|---|---|
| `Byte4(ascii: "IHDR")`, any `ByteGroup`; `Byte(ascii: "-")` | `0x49_48_44_52` hex in memory order | Identical machine code (LLVM merged the two benchmark functions); PNG, QOI ports unchanged in instructions |
| `expect(0x184D_2204 as UInt32, .littleEndian)` on every cursor | the constant byte-reversed by hand (`0x04_22_4D_18 as Byte4`) | LZ4 port unchanged |
| `read(Int.self, asciiDigits: 4)`, `write(_:asciiDigits:)` | a multiply-add per digit | 20,000 log lines −11.5% instructions, −15% time; one 8-byte load and three multiplies up to 8 digits, two loads up to 16 |
| `UInt8.isASCIIDigit`, `asciiDigitValue`, `asciiHexDigitValue`, `isASCIILetter`, `isASCIIWhitespace`, `asciiLowercased`, `asciiUppercased` | `&- 0x30 < 10`, `| 0x20` | Branchless; a byte loop over `isASCIIDigit` auto-vectorizes |
| `ByteLanes.matching(in:)`, `matching(_: Unicode.Scalar)`, `asciiDigits`, `asciiLetters`, `asciiWhitespace`, `asciiControl` | per-lane tests, scalar comparisons (lane by lane on Swift 6.4) | One `cmhi` per range; counting digits in 620 KB 2.7x faster than the vectorized byte loop |
| `seek(toByteOffset:)` taking any `BinaryInteger` | `Int(exactly:)` helpers (ELF's `offset(_:)`, removed) | — |

Found while measuring: `pointwiseMin` on `SIMD16<UInt8>` is an out-of-line call (use a vector comparison), and a
generic out-of-line slow path on the cursor passed type metadata at every call site (moved to a non-generic static
function over the digits' span).

## Not implemented (ranked by the survey)

1. **Variable-width ASCII numbers** (`read(_:asciiDigitsUpTo:)`, stopping at the first non-digit), and octal/hex
   radixes (tar, HTTP chunk sizes).
2. **An ASCII template literal** (`"dddd-dd-dd"` folded to masks like `BitPattern`) for NativeISO8601's hand-built
   bias constants.
3. **`readSection(count:stride:)`**, throwing on overflow: BPList repeats `multipliedReportingOverflow` before each
   section (`BPList.swift:66-69, 103-105, 156-158`).
4. **`readSection(byteCount:paddedTo:)` and `readSection(leavingLast:)`**: PCAPNG rounds lengths and drops the FCS by
   hand; PNG's CRC, gzip's trailer, and TLS tags have the same shape.
5. **`forEachRecord` yielding the tag group** (not `Tag.Integer`), so RIFF-style ASCII tags compare with
   `Byte4(ascii:)` directly.
6. **Bytes' own code on its API**: Zstandard's frame header masks bits by hand (`ZstdFormat.swift:136-214`) and
   gzip's header finds NUL with a byte loop (`DeflateDecoder.swift:406-412`) where `firstByteOffset(where:)` exists.
   Port and benchmark both.
7. **A `#ascii("…")` macro**, considered and set aside: a generic macro's return type can't be inferred in generic
   positions (`expect(#ascii("qoif"))`), and `init(ascii:)` already folds. It would still help a `static let`, which
   `init(ascii:)` leaves lazily initialized.

## Naming and numeric types (not changed)

- `byteCount` means a field's width in `read(_:byteCount:)` and a length in `read(byteCount:)`.
- A byte is `UInt8` in `matching(_:)` and `read(bytesTerminatedBy:)`, `Byte` in `write(repeating:count:)` and
  `expect(_: Byte)`.
- `Byte(highHalf:lowHalf:)` against `Byte2(lowHalf:highHalf:)`.
- `readSectionIfComplete(prefixedBy:)` against `read(sectionPrefixedBy:)`.
- Magic numbers had three conventions (`expect(Byte4)` in memory order, `expect(UInt32)` in the cursor's order,
  `@Field(expecting:)` in the field's order); WritingParsers.md now shows `init(ascii:)` for text and
  `expect(_:_:)` for numbers as the specification writes them.
