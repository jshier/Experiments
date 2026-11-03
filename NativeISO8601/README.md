# NativeISO8601

A Swift-native, allocation-free ISO 8601 / RFC 3339 timestamp parser. It reads `String`, `Data`,
`Span<UInt8>`, `RawSpan` or `UTF8Span` and produces a `Date`. It uses no regexes, `Formatter`s or ICU.

```swift
let date = try ISO8601.date(from: "2024-01-15T10:30:45.123+05:30")   // throws(ISO8601ParseError)
let maybe = Date(iso8601: "2024-W03-1")                                // failable convenience
let fromBytes = try ISO8601.date(from: buffer.span.extracting(range)) // zero-copy slice of a larger buffer

// The components as written, validated, plus the instant they denote.
let stamp = try ISO8601.timestamp(from: "1985-W15-5T23:20,5+04")
stamp.dateValue   // .weekDate(year: 1985, week: 15, weekday: 5)
stamp.time        // TimeOfDay(hour: 23, minute: 20, fraction: DecimalFraction(value: 5, digits: 1))
stamp.utcOffset   // UTCOffset(isNegative: false, hours: 4, minutes: 0, isHoursOnly: true)
stamp.date        // 1985-04-12 19:20:30 UTC
```

## Design

Parsing has two phases:

1. **Lexical** (`Lexer`, a `~Copyable & ~Escapable` cursor over a borrowed `RawSpan`). It scans
   bytes into `RawComponents`, which holds the numeric fields exactly as written plus the date form.
   It checks shape only, never ranges. Lexical errors report the byte offset.
   - Fast paths: the very common prefixes `YYYY-MM-DDThh:mm:ss` (three word loads) and, if that
     fails, basic-format `YYYYMMDDThhmmss` (two loads) are checked with SWAR tests. Each word is XORed
     with a template (`'0'` at digit positions, exact punctuation elsewhere). A per-byte bias then
     flags any byte that isn't a valid digit (0...9) or exact punctuation (0), all branch-free. The
     digit values come straight out of the XORed words. Each fast path gets its own inlined copy of
     the fraction and offset suffix, so its `RawComponents` never leaves registers.
   - General path: a recursive-descent scanner for every other form, kept out of line so it doesn't
     force the fast paths' components into memory. Basic-format dates are recognized by the length of
     the digit run (2 = century, 3 = decade, 4 = year, 7 = ordinal, 8 = calendar date; 6 more for a
     signed year). `peek` returns NUL past the end, so productions need no separate bounds checks.
2. **Semantic** (`RawComponents.resolve()`, `consuming`). It range-checks each field against the
   proleptic Gregorian calendar and converts to a `Date`. Day counting uses Neri–Schneider's Euclidean
   affine algorithm (unsigned, one division by 100): 32-bit for years 0...9999, and an out-of-line
   64-bit version for expanded and negative years. The leap-year division only runs for February 29,
   ordinal dates and week dates. Reduced-precision dates resolve to the start of their period.

The package builds in Swift 6 mode with `strictMemorySafety()` and the `Lifetimes` feature
(`@_lifetime`). The only `unsafe` expression is the bounds-checked byte read in `peek`.

### Accepted grammar

| Part | Forms |
|---|---|
| Complete date | `YYYY-MM-DD`, `YYYYMMDD`, ordinal `YYYY-DDD` / `YYYYDDD`, week `YYYY-Www-D` / `YYYYWwwD` |
| Reduced date | month `YYYY-MM`, year `YYYY`, decade `YYY`, century `YY`, week `YYYY-Www` / `YYYYWww` (start of the period; no time may follow) |
| Expanded year | a sign, then 4–9 digits up to the `-` in extended format (`-0001-12-31`, `+002024-01-15`), or exactly 6 digits in basic format (`+0020240115`), where `+0020` is a century and `+00202` a decade |
| Separator | `T`, `t`, or space, only after a complete date |
| Time | `hh`, `hh:mm`, `hh:mm:ss`, `hhmm`, `hhmmss`, with an optional `.` or `,` fraction of the last field (`hh,5` = 30 min, `hh:mm,5` = 30 s; nine digits kept, the rest truncated) |
| Offset | `Z`, `z`, `±hh`, `±hhmm`, `±hh:mm` (up to ±23:59). If omitted, UTC is assumed. |

`24:00:00` means the following midnight. A leap second (`:60`) rolls into the next second, because
`Date` can't represent one. Standalone times and offsets (`23:20`, `+05`) are rejected because
there's no date to turn into a `Date`.

Signed basic-format years need an agreed digit count, which ISO 8601 leaves to the parties involved.
The 6-digit agreement used here matches ECMAScript and the CalConnect suite's expanded-year tests. Under it,
`-0001` is century −1 rather than year −1; write `-0001-01-01` or `-000001` for the year.

### Differences from `ISO8601DateFormatter`

- **Strict calendar validation.** `2024-02-30` is rejected; Foundation rolls it over to March 1.
- **Proleptic Gregorian before 1582.** ISO 8601 requires this. Foundation switches to the Julian calendar
  before October 1582, so results for those dates differ by days.
- **More precise fractions.** Results match `Date.ISO8601FormatStyle` exactly. `ISO8601DateFormatter`
  truncates to milliseconds, with float error (`.123` parses as `.1229999`).
- **More accepted forms.** Basic, ordinal, week, lowercase, space-separated, comma-fraction and
  offset-less forms are all accepted by one entry point, with no options to configure.

## Tests

`swift test` runs 24 Swift Testing tests:

- 20,000 random RFC 3339 timestamps (years 1583–9999, random offsets) give exactly the same result as
  `ISO8601DateFormatter`.
- Every day from 1600 to 2400, written in all six date forms, matches `Calendar(identifier: .iso8601)`.
- Expanded and negative years, where Foundation (Julian before 1582) can't serve as a reference:
  known anchors (year 0, year −1, ISO weeks of years 0 and −1) plus day-by-day continuity across
  year boundaries from −1005 to 100,004, checking leap years along the way.
- Every reduced-precision form resolves to the start of its period; hour and minute fractions scale
  correctly; `ISO8601.timestamp(from:)` reports each form as written.
- Fractions match `Date.ISO8601FormatStyle` exactly.
- Every byte value at every position of seven fast-path inputs (extended and basic) gives the same
  result (or the same error) from the SWAR fast paths as from the general path.
- Exact lexical errors (with offsets) and semantic errors (with field and value) are checked.

## ISO 8601 conformance suite

`Sources/ISO8601SuiteAdapter` is an adapter for the
[CalConnect ISO 8601 test suite](https://github.com/CalConnect/iso-8601-test-suite), using the suite's
`exec:` JSON protocol:

```
swift build -c release --product iso8601-suite-adapter
cd ../iso-8601-test-suite
ruby scripts/run-tests --adapter "exec:$OLDPWD/.build/release/iso8601-suite-adapter"
```

The adapter follows the suite's purity rules (`adapters/RULES.adoc`). Every component it reports
comes from `ISO8601.timestamp(from:)` exactly as the library produced it, so it declares no
qualification notes. Equivalence compares the library's `Date`s. Generation is `not-supported`
because there's no formatter.

| Run | Pass | Fail | Not-supported |
|---|---:|---:|---:|
| Full suite (800) | 179 | 106 | 515 |
| `calendar-date` / `ordinal-date` classes | 24 / 11 | **0 / 0** | 8 / 4 |
| `date-and-time` class (43) | 37 | 2 | 4 |
| `iso-8601-1-core` profile (76) | 49 | 13 | 14 |

The remaining failures, by cause:

| Cause | Count |
|---|---:|
| Standalone times and offsets (`T23:20`, `+05`), which have no date to convert | 60 |
| Accepted but invalid under a stricter profile (RFC 3339, W3C, EDTF, basic-only) or for mixing basic and extended format | 32 |
| EDTF, intervals and durations | 11 |
| Ambiguous digit strings: `00` and `24` read as centuries rather than hours, `-0001` as century −1 | 3 |

The suite's `week-date-valid-001` expects `1985W015` to be invalid ("week 00"), but that string is
week 01, day 5. It looks like a data error in the suite.

## Benchmarks

```
swift package --allow-writing-to-package-directory benchmark
swift package benchmark baseline compare v1-straightforward v7-basic-swar
```

The suite uses [package-benchmark](https://github.com/ordo-one/package-benchmark), which needs
jemalloc for the malloc counts. Each iteration parses 1,000 timestamps, and every figure below is
**per parse** (p50, Apple Silicon, macOS 27, Swift 6.4.2, release).

### Against Foundation

| Parser | Input | Instructions | Mallocs | Wall time |
|---|---|---:|---:|---:|
| **NativeISO8601** | `RawSpan` | **239** | **0** | **9 ns** |
| **NativeISO8601** | `String` (UTC) | 319 | 0 | 13 ns |
| **NativeISO8601** | `String` (basic format) | 299 | 0 | 13 ns |
| **NativeISO8601** | `String` (fractional) | 389 | 0 | 14 ns |
| **NativeISO8601** | `String` (offset) | 372 | 0 | 15 ns |
| **NativeISO8601** | `String` (1,000 mixed) | 465 | 0 | 21 ns |
| **NativeISO8601** | `String` (reduced `2024-01`) | 481 | 0 | 20 ns |
| **NativeISO8601** | `String` (week date) | 778 | 0 | 29 ns |
| **NativeISO8601** | `String` (expanded year) | 828 | 0 | 31 ns |
| **NativeISO8601** | `timestamp(from:)`, offset | 522 | 0 | 20 ns |
| **NativeISO8601** | `Data` | 573 | 0 | 22 ns |
| `Date.ISO8601FormatStyle` | `String` (UTC) | 7,152 | 1 | 297 ns |
| `Date.ISO8601FormatStyle` | `String` (offset) | 7,565 | 1 | 316 ns |
| `ISO8601DateFormatter` | `String` (UTC) | 1,013,000 | 479 | 55 µs |
| `ISO8601DateFormatter` | `String` (1,000 mixed) | 1,022,000 | 480 | 55 µs |

On the fast paths, NativeISO8601 is roughly 23× faster than `Date.ISO8601FormatStyle` and about 4,000×
faster than `ISO8601DateFormatter` for `String` input. Even the general path (week dates, expanded years) is about 10× faster than
`Date.ISO8601FormatStyle`. The `ISO8601DateFormatter` figure was confirmed
outside the benchmark harness, at about 48 µs per parse, so it isn't an artifact of the malloc
interposer.

The floor benchmarks show where input overhead goes:

| Floor | Instructions |
|---|---:|
| Harness loop, `identity`, `blackHole` | 50 |
| `String.utf8.span` | 72 (22 more than the harness) |
| `Data.span` or `Data.bytes` | 317 (~265 more, from Foundation's representation switch) |

If you already have a span (for example, while scanning a JSON buffer), pass it directly.

### Progress (stored in `.benchmarkBaselines/`)

| Baseline | Change | String UTC | Span / RawSpan UTC |
|---|---|---:|---:|
| `v1-straightforward` | byte-by-byte recursive descent | 568 instr / 21 ns | 595 / 22 ns† |
| `v2-swar` | SWAR prefix, Neri–Schneider day count | 415 / 16 ns | 440 / 18 ns† |
| `v3-inlined` | inline hot productions, truncating conversions | 370 / 14 ns | 403 / 16 ns† |
| `v4-rawspan` | `RawSpan` lexer storage, `resolve` force-inlined, span-held benchmarks | 338 / 15 ns | 277 / 10 ns |
| `v5-template-swar` | XOR-template SWAR, lazy leap year, single code copy | **315 / 13 ns** | **235 / 8 ns** |
| `v6-reduced-expanded` | reduced precision, expanded/negative years, `timestamp(from:)`; general path out of line | 314 / 13 ns | 234 / 9 ns |
| `v7-basic-swar` | basic-format SWAR fast path (`20240115T103045Z`: 787 → 299) | 319 / 13 ns | 239 / 9 ns |

† From a fresh `[UInt8]` each iteration, which includes about 90 instructions of array retain/release.
From v4 on, the span is acquired once outside the loop.

During v6, adding the new forms first cost 45 instructions on the hot path (235 → 280). The
causes were 64-bit day counting for every year, the optimizer declining to inline the larger lexer
(`@inline(__always)` is a hint, `@inline(always)` is not), and the fast path's components being
forced onto the stack by the general path's `inout` productions. Fixing each one brought it back
to 234.

### Possible next steps

- Parse the fraction and the `±hh:mm` offset with SWAR as well (a fractional string currently costs
  about 70 more instructions than a UTC one).
- Speed up the general path (week dates, expanded years) by scanning digit runs a word at a time.
