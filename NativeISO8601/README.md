# NativeISO8601

A Swift-native, allocation-free ISO 8601 / RFC 3339 timestamp parser. It reads `String`, `Data`,
`Span<UInt8>`, `RawSpan` or `UTF8Span` and produces a `Date`. It uses no regexes, `Formatter`s or ICU.

```swift
let date = try ISO8601.date(from: "2024-01-15T10:30:45.123+05:30")   // throws(ISO8601ParseError)
let maybe = Date(iso8601: "2024-W03-1")                                // failable convenience
let fromBytes = try ISO8601.date(from: buffer.span.extracting(range)) // zero-copy slice of a larger buffer
```

## Design

Parsing has two phases:

1. **Lexical** (`Lexer`, a `~Copyable & ~Escapable` cursor over a borrowed `RawSpan`). It scans
   bytes into `RawComponents`, which holds the numeric fields exactly as written plus the date form.
   It checks shape only, never ranges. Lexical errors report the byte offset.
   - Fast path: the very common prefix `YYYY-MM-DDThh:mm:ss` is checked with three
     little-endian word loads and a SWAR test. Each word is XORed with a template (`'0'` at digit
     positions, exact punctuation elsewhere). A per-byte bias then flags any byte that isn't a valid
     digit (0...9) or exact punctuation (0), all branch-free. The digit values come straight out of the
     XORed words.
   - General path: a recursive-descent scanner for every other form. `peek` returns NUL past the end,
     so productions need no separate bounds checks.
2. **Semantic** (`RawComponents.resolve()`, `consuming`). It range-checks each field against the
   proleptic Gregorian calendar and converts to a `Date`. Day counting uses Neri–Schneider's Euclidean
   affine algorithm (unsigned, one division by 100). The leap-year division only runs for
   February 29, ordinal dates and week dates.

The package builds in Swift 6 mode with `strictMemorySafety()` and the `Lifetimes` feature
(`@_lifetime`). The only `unsafe` expression is the bounds-checked byte read in `peek`.

### Accepted grammar

| Part | Forms |
|---|---|
| Date | `YYYY-MM-DD`, `YYYYMMDD`, ordinal `YYYY-DDD` / `YYYYDDD`, week `YYYY-Www-D` / `YYYYWwwD` |
| Separator | `T`, `t`, or space |
| Time | `hh:mm`, `hh:mm:ss`, `hhmm`, `hhmmss`, with an optional `.` or `,` fraction (nanoseconds kept, extra digits truncated) |
| Offset | `Z`, `z`, `±hh`, `±hhmm`, `±hh:mm` (up to ±23:59). If omitted, UTC is assumed. |

`24:00:00` means the following midnight. A leap second (`:60`) rolls into the next second, because
`Date` can't represent one. Expanded (more than 4-digit or signed) years aren't supported.

### Differences from `ISO8601DateFormatter`

- **Strict calendar validation.** `2024-02-30` is rejected; Foundation rolls it over to March 1.
- **Proleptic Gregorian before 1582.** ISO 8601 requires this. Foundation switches to the Julian calendar
  before October 1582, so results for those dates differ by days.
- **More precise fractions.** Results match `Date.ISO8601FormatStyle` exactly. `ISO8601DateFormatter`
  truncates to milliseconds, with float error (`.123` parses as `.1229999`).
- **More accepted forms.** Basic, ordinal, week, lowercase, space-separated, comma-fraction and
  offset-less forms are all accepted by one entry point, with no options to configure.

## Tests

`swift test` runs 13 Swift Testing tests:

- 20,000 random RFC 3339 timestamps (years 1583–9999, random offsets) give exactly the same result as
  `ISO8601DateFormatter`.
- Every day from 1600 to 2400, written in all six date forms, matches `Calendar(identifier: .iso8601)`.
- Fractions match `Date.ISO8601FormatStyle` exactly.
- Every byte value at every position of four fast-path inputs gives the same result (or the same error)
  from the SWAR fast path as from the general path.
- Exact lexical errors (with offsets) and semantic errors (with field and value) are checked.

## Benchmarks

```
swift package --allow-writing-to-package-directory benchmark
swift package benchmark baseline compare v1-straightforward v5-template-swar
```

The suite uses [package-benchmark](https://github.com/ordo-one/package-benchmark), which needs
jemalloc for the malloc counts. Each iteration parses 1,000 timestamps, and every figure below is
**per parse** (p50, Apple Silicon, macOS 27, Swift 6.4.2, release).

### Against Foundation

| Parser | Input | Instructions | Mallocs | Wall time |
|---|---|---:|---:|---:|
| **NativeISO8601** | `RawSpan` | **235** | **0** | **8 ns** |
| **NativeISO8601** | `String` (UTC) | 315 | 0 | 13 ns |
| **NativeISO8601** | `String` (fractional) | 380 | 0 | 15 ns |
| **NativeISO8601** | `String` (offset) | 378 | 0 | 14 ns |
| **NativeISO8601** | `String` (1,000 mixed) | 460 | 0 | 20 ns |
| **NativeISO8601** | `Data` | 569 | 0 | 22 ns |
| `Date.ISO8601FormatStyle` | `String` (UTC) | 7,152 | 1 | 297 ns |
| `Date.ISO8601FormatStyle` | `String` (offset) | 7,565 | 1 | 316 ns |
| `ISO8601DateFormatter` | `String` (UTC) | 1,013,000 | 479 | 55 µs |
| `ISO8601DateFormatter` | `String` (1,000 mixed) | 1,022,000 | 480 | 55 µs |

These numbers make NativeISO8601 roughly 23× faster than `Date.ISO8601FormatStyle` and about 4,000×
faster than `ISO8601DateFormatter` for `String` input. The `ISO8601DateFormatter` figure was confirmed
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

† From a fresh `[UInt8]` each iteration, which includes about 90 instructions of array retain/release.
From v4 on, the span is acquired once outside the loop.

### Possible next steps

- Parse the fraction and the `±hh:mm` offset with SWAR as well (a fractional string currently costs
  about 65 more instructions than a UTC one).
- Write `RawComponents` straight into registers instead of zero-initializing it on the stack.
