# HTTPBytes: measurements and decisions

M1 Max (8 performance and 2 efficiency cores), macOS 27.2, Swift 6.4 (Xcode 27.3). Benchmarks are in their own package,
`Benchmarks/` (C references and swift-http-types stay out of the library's build): baselines in
`Benchmarks/.benchmarkBaselines/HTTPBytesBenchmarks/`. Corpus: `Tools/test-data fetch qifs http-corpus` (qifs' real
HTTP/3 traffic as HTTP/1 heads: 401 requests, 580 B average; 383 responses, 953 B average). References: picohttpparser
(dd573d8) and llhttp (release 9.4.4), built -O3 with NDEBUG from `Tools/test-data fetch picohttpparser llhttp`.

## 2026-11-23: HTTP/1 head parsing (baselines `http1-1`, `http1-2`)

### The design, from three prototypes (PLAN.md, phase 0.5)

On the request corpus, per head and per byte (`proc_pid_rusage` instructions and cycles, a throwaway harness):

| Strategy | ns/head | instructions/B | cycles/B |
|---|---|---|---|
| A: scan each line with `firstByteOffset` (16-byte tests, overlapping short-span loads) | 168 | 2.62 | 0.93 |
| B: structural index: 64-byte blocks classified once into masks (CTL/DEL "stops", non-token bytes), walked with ctz | 112 | 3.18 | 0.62 |
| picohttpparser (scalar on ARM: its fast path is SSE4.2) | 225 | 7.81 | 1.23 |
| llhttp | 220 | 6.55 | 1.20 |

A runs fewer instructions and more cycles: its many short scans (header lines are 15–40 bytes) mispredict. B needs a
64-byte movemask, which Swift's SIMD can't express (NEON's `addp` reduction): Bytes now has `ByteBlock` and
`bytes_movemask64` in CBytesNEON (portable fallback: four `bitmask`s). With 16-byte nibble masks in Swift alone, B fell
to 0.87 cycles/B.

A field line is then: the name ends at the first non-token byte (which must be the colon: no other check of the name's
characters), the value at the first stop (which must be CR, then LF); two bit scans. The walk only moves forward, so the
parser keeps the current block's masks, not an index: no memory per head.

### Getting the library to the prototype's speed

| Change | ns/head | instructions/B | cycles/B |
|---|---|---|---|
| First library version (events, field-name lookup per field) | 202 | 6.69 | 1.12 |
| Scanner `next`/`fieldLine` `@inline(always)` (they were calls) | 202 | 5.78 | 1.09 |
| (lookup off, to measure it) | 187 | 4.73 | 1.00 |
| `next(in:)` `@inline(always)` into the caller's loop | 180 | 3.88 | 0.96 |
| Mask building a static function returning values (the out-of-line `mutating build` kept the scanner in memory for the whole loop: AGENTS.md's lesson) | 153 | 3.71 | 0.84 |
| Unchecked byte loads where the offset is proven < count | 150 | 3.43 | 0.80 |
| (lookup back on) | 165 | 4.51 | 0.88 |
| Field-name hash on two 8-byte words, compared against precomputed table words | 157 | 4.17 | 0.84 |

Forcing the mask builder itself inline made it worse (0.98): the mutating wrapper around it was then left out of line.

### A bad first baseline

`http1-1` measured failures: the request line checked the whole remaining buffer against the 64 KiB head limit, so with
more than 64 KiB after a head (the corpus is 232 KB) it threw `headTooLarge` at once, and the benchmark summed results
without checking them. Fixed (the limit is checked where a line ends and where more bytes are needed), with a test that a
small head followed by 100 KB parses, and every benchmark's setup now checks that every head parses. `http1-2` is the
first valid baseline.

### `http1-2` (before the lookup and the last two changes above)

| Row | HTTPBytes | picohttpparser | llhttp |
|---|---|---|---|
| 401 request heads (232 KB) | 65 µs, 1,052 K instructions | 91 µs, 1,820 K | 90 µs, 1,532 K |
| 383 response heads (365 KB) | 104 µs | 130 µs | 132 µs |
| 1,000 tiny requests (38 B) | 43 µs | 20 µs | 51 µs |
| 1,000 × 20 fields of 1 B | 265 µs | 208 µs | |
| … of 16 B | 282 µs | 270 µs | |
| … of 32 B | 336 µs | 348 µs | |
| … of 64 B | 441 µs | 521 µs | |
| … of 128 B | 553 µs | 825 µs | |
| 401 requests into owned fields | 125 µs, 0 mallocs (`HTTPFieldStore`, reused) | | swift-http-types `HTTPFields`: 643 µs, 3,669 mallocs (this table first said 1,018; the baseline has 3,669) |
| 3,000 lookups by name | 8.4 µs (`HTTPFieldStore`, a 16-lane scan of name indexes) | | `HTTPFields`: 647 µs |
| 1 MB chunked body, 4 KB chunks | 3.8 µs (data handed out as slices) | | 3.4 µs |

Every HTTPBytes row allocates nothing (`Allocations:` gates at 0). Open: the fixed cost per field (about 200
instructions with 1-byte values, picohttpparser's 195) and per head (tiny heads, 2.2x pico).

## 2026-11-23: HTTP/1 heads against cursed-http (baseline `http1-opt`)

cursed-http (github.com/public/cursed-http at 5e10ca8, MIT; `Tools/test-data fetch cursed-http`) is a C parser on this
same design whose README says it beats picohttpparser everywhere, Apple M5 included. Its `fbparse.h` and `fbresp.h`
are now a reference (`Benchmarks/Sources/CReferences/cursed_http.c`; they read up to 64 bytes past what they're given,
so the corpora carry 64 bytes of padding), and its `tests/top1k` (3,533 requests that Chromium sent loading the Tranco
top 1,000, 2,054 response heads, values scrubbed) is a corpus: `Tools/test-data fetch http-top1k`
(`Fixtures/top1k/make-top1k.sh`; request bodies left out). Measured with a harness reading `proc_pid_rusage`'s
instructions and cycles (best of 3 runs of about 40 ms; other agents were building, so cycles, not times, decided),
which checks before measuring that every parser gives every head its exact length and picohttpparser's field count, and
an old-versus-new differential (the previous `HTTP1` sources as a second module: events and errors equal on 1.6 million
inputs, corpus heads and their mutations, whole and fed 1, 7, and 64 bytes at a time, under four option sets).

Per head, cycles (instructions). `req`/`resp`: http-corpus; `treq`/`tresp`: top-1k; `tiny`: 38-byte requests;
`f1`/`f128`: 20 fields of 1 or 128 bytes. Each head is parsed from a span of everything after its start (a
connection's buffer). Up to step 4 HTTPBytes looked every field's name up; from step 5 it doesn't (as the C parsers
don't), and "known names" says what looking them up costs.

| Step | req | resp | treq | tresp | tiny | f1 | f128 |
|---|---|---|---|---|---|---|---|
| Start (`http1-2` code, names looked up) | 491 (2,407) | 807 | 1,116 | 1,755 | 107 (524) | 774 (3,926) | 1,714 |
| 1. The walk: a line's end first, from its start, in the block's stop mask; the name from one 16-byte nibble mask at the line start; value from the colon (`vs = colon + 1 + (byte == SP)`, trims with one `<= 0x20` compare); `GET `/`PUT `/`POST`/`HEAD` and `HTTP/1.x` CR LF as word compares; anything else to exact, stateless paths | 367 | 643 | 948 | 1,565 | 68 | 563 | 1,355 |
| 2. The exact paths take and return values; the walk, `fieldLine`, and the request and status lines `@inline(always)` (left out of line, each kept the parser in memory) | 333 | 590 | 907 | 1,504 | 61 | 495 | 1,221 |
| 3. Known names looked up only when asked (below) | 335 (1,584) | 529 | 834 | 1,263 | 62 | 520 | 1,363 |
| 4. The target's scan out of line: the inlined parse loop had grown past the SIL inliner's caller limit, and `RawSpan.byteCount` stayed a call (three per field) | 306 (1,308) | | | | 55 | 429 (2,342) | |
| 5. Line stops are controls or DEL (2 compares and an OR; `fieldValueStop` takes 5 to leave tabs out), a tab checked where the walk stops; a line running past its block in a loop of its own | 279 (1,143) | 447 | 703 | 1,045 | 55 | 406 | 913 |
| 6. The target's scan also builds its block's stop mask, which starts the walk; a partial block copied inline (no `memcpy`) | 274 (1,200) | 448 | 685 | 1,049 | 50 | 366 | 912 |
| 7. Masks gathered from four plain loads by weighted pairwise adds, the lanes' high bits not spread again (comparison lanes are full), instead of `ld4` and cursed-http's shift-right-insert packing | **258** (1,263) | **426** | **665** | **1,028** | **52** | **365** | **788** |
| cursed-http | 275 (1,057) | 366 | 724 | 912 | 47 | 353 | 1,028 |
| picohttpparser | 711 (4,538) | 1,055 | 1,579 | 2,447 | 62 | 651 | 2,590 |
| llhttp | 698 (3,814) | 1,058 | 1,566 | 2,128 | 158 | 1,119 | 1,525 |

Final, per head (ns, cycles); "alone" gives each tiny head only its 38 bytes, as a server that has read one request:

| Corpus | HTTPBytes | known names | cursed-http | picohttpparser | llhttp |
|---|---|---|---|---|---|
| 401 requests (580 B) | 85 ns, 258 | 96, 302 | 88, 275 | 230, 711 | 230, 698 |
| 383 responses (953 B) | 139, 426 | 170, 519 | 120, 366 | 348, 1,055 | 348, 1,058 |
| top-1k: 3,533 requests (1,162 B) | 219, 665 | 272, 827 | 239, 724 | 520, 1,579 | 500, 1,566 |
| top-1k: 2,054 responses (2,004 B) | 338, 1,028 | 444, 1,371 | 298, 912 | 774, 2,447 | 696, 2,128 |
| tiny requests (38 B) | 17.0, 52 | 19.1, 60 | 14.9, 47 | 20.3, 62 | 52, 158 |
| … alone | 23.9, 73 | 28.7, 87 | 15.5, 47 | 19.8, 63 | 54, 172 |
| tiny responses (38 B) | 16.7, 51 | 20.5, 62 | 20.9, 63 | 19.9, 62 | 47, 144 |
| 20 fields of 1 B | 120, 365 | 144, 437 | 116, 353 | 214, 651 | 369, 1,119 |
| … of 16 B | 155, 469 | 164, 519 | 155, 489 | 277, 840 | 373, 1,131 |
| … of 32 B | 199, 630 | 196, 621 | 199, 631 | 358, 1,094 | 379, 1,195 |
| … of 128 B | 256, 788 | 268, 830 | 333, 1,028 | 853, 2,590 | 487, 1,525 |

The benchmark package (`http1-opt`, p50 µs and instructions per iteration; rows for 8, 15, 16, 31, 32, 64 B fields too):

| Row | HTTPBytes | known names | cursed-http | picohttpparser | llhttp |
|---|---|---|---|---|---|
| 401 requests | 36 µs, 489 K | 41, 649 K | 39, 435 K | 95, 1,831 K | 93, 1,543 K |
| 383 responses | 55, 873 K | 66, 1,270 K | 48, 744 K | 134, 2,658 K | 137, 2,302 K |
| top-1k, 3,533 requests | 787, 8.2 M | 965, 11 M | 850, 7.5 M | 1,862, 32 M | 1,815, 26 M |
| top-1k, 2,054 responses | 686, 7.0 M | 931, 9.6 M | 609, 6.0 M | 1,663, 27 M | 1,444, 17 M |
| 1,000 tiny requests | 17, 347 K | 22, 404 K | 18, 325 K | 22, 487 K | 54, 908 K |
| … alone | 27, 432 K | 32, 489 K | 20, 349 K | 25, 516 K | 60, 1,063 K |
| 1,000 × 20 fields of 1 B | 127, 2.16 M | 148 | 119, 1.74 M | 216, 3.94 M | 370, 6.36 M |
| … of 16 B | 165, 2.42 M | 174 | 165, 1.95 M | 280, 5.54 M | 373, 6.68 M |
| … of 128 B | 265, 3.68 M | 294 | 343, 3.18 M | 856, 18 M | 504, 8.92 M |

HTTPBytes is 2.1–2.8x as fast as picohttpparser and llhttp on every real corpus (cycles per head above; 2.1–2.6x in
the benchmarks' times), ahead of cursed-http on requests (6% on
http-corpus, 8% on top-1k) and long fields (23% at 128 B), level with it at 16–32 B, and behind it on responses (14–17%),
on 1-byte fields (3%) and on tiny heads (10%; 55% given only the head's bytes, where cursed-http's contract lets it read
64 bytes past them and HTTPBytes copies the partial block). The response gap is mispredicts: CPU Counters put 42% of
HTTPBytes' cycles on top-1k responses in discarded work against cursed-http's 33% (on requests, 9% against 6%); 57% of
those heads' bytes are in lines of 256 bytes or more, and fbresp.h classifies 4 blocks ahead in a table so a line
crossing blocks takes no branch (two batched versions here, below, cost more than they saved).

What was kept and why:

- **Known names are looked up when asked** (`HTTPFieldView.knownName`, an API change): HTTP/1 fields carry their name's
  bytes and an index of 0xFE, "not looked up"; HPACK's and QPACK's keep theirs from their tables. Looking every name up
  while parsing cost 300–400 instructions a request head, a fifth of the parse, for callers that don't ask. Reading
  `knownName` for every field now costs 44 cycles a head (http-corpus requests; 162 on top-1k requests).
- **The lookup's words without branches**: the length class (`Host`, `Accept`, `Connection` alternate between 4–7 and
  8+) picked the loads with a branch, a mispredict whenever consecutive names changed class (in step 1's loop,
  looking names up cost 38 cycles a head: 367 against 329 without). Now four 4-byte loads at selected offsets, paired
  by a select. The lookup isn't inlined into the parser: from another module its `static let` tables are reached through addressor calls (4
  per lookup).
- **Request methods as words** (`GET `, `PUT `, `POST`/`HEAD` and a space), the version and CR LF as one 8-byte and one
  2-byte compare.
- **`ByteBlock` stays in byte order** (Bytes): `bytes_movemask64` now takes full lanes (the `sshr` spreading each lane's
  high bit is done in Swift, where LLVM drops it for comparison results: 8 vector instructions and a move, instead of
  12). cursed-http's `ld4` and shift-right-insert packing (5 instructions) was 5% fewer instructions and 5–16% more
  cycles here (tiny heads 4% fewer): the mask is on the walk's critical path, and `ld4` loads 64 bytes in 2 cycles
  against 1.33 for four plain loads (`Tools/cpu-probe insn ld4`, new rows) with more latency. A partial last block is
  copied inline in 16-, 8-, or 4-byte words (`memcpy` and a byte loop before); HTTP/1 also tests the block ending at the
  bytes' end and shifts its mask, copying nothing when there are 64 bytes.
- **Responses' `HTTP/1.2`–`HTTP/1.9` are HTTP/1.1** (RFC 9110 §2.5: processed as the highest minor version
  implemented), requests' too; `HTTP/1.32` is an invalid version (400), not an unsupported one.
- **Request-target validation is an option, off by default** (`HTTP1ParserOptions.validatesTargets`, calling the core's
  `HTTPRequestTarget.validate` out of line). On the heads it accepts it costs, per head: http-corpus requests 236 → 272
  cycles (+15%), top-1k requests 657 → 1,113 (+69%: long targets, many `%XX`), tiny 49 → 70 (+43%), 20 × 1-byte
  fields +2%, 20 × 128-byte +5%. And it rejects real traffic: 52 of http-corpus's 401 requests (Facebook's
  `?filter[0]=…`: brackets in a query) and 8 of top-1k's 3,533 (`|`, `^`, `{`, a bare `%`); enabled in the
  conformance harness, it also rejected targets those suites accept (`*` for `M-SEARCH` and `NOTIFY`, `#` fragments,
  quotes, `/_goRPC_` for CONNECT, WHATWG query characters), so the harness leaves it off and those known issues stay.

Tried and not kept (cycles per head):

| Change | Effect |
|---|---|
| Stop masks for 5 blocks at a time, a 64-bit window from the line start across two (fbresp.h's idea) | req 279 → 312, tiny 55 → 86, f1 406 → 484, f128 913 → 1,382: classifying blocks past a short head's end, and lines longer than the window tested again |
| A ring of 8 blocks' masks, 4 tested ahead | req 279 → 350, tiny 55 → 92, f128 913 → 1,414 |
| The first 32 bytes of a name without a branch on which half ends it (2 of 5 response names have 16+ bytes) | resp 426 → 427, f1 365 → 388, f128 788 → 913 |
| The stop-mask builder inlined into the walk | req 333 → 347: the loop's size again |
| The lookup inlined, from the parser's own loads | instructions −50 a head, cycles unchanged (the addressor calls) |

Not done: cursed-http's whole-head fast path (the head's end found from an LF mask first, then fields without
per-field checks): HTTPBytes' per-field checks are branches that predict, and finding the end first is a pass over
the head the walk then repeats. Its skip windows for long values (a cheap "any control in 256 bytes?" before exact
masks) are a candidate for the response gap.

The inliner's limit is worth knowing beyond this parser: with every per-field function `@inline(always)`, the parse
loop's SIL grew past the performance inliner's caller limit, after which it stopped inlining ordinary functions into
it, `RawSpan.byteCount` among them (a two-instruction call, three per field, each clobbering the vector registers the
name scan kept its tables in). Moving the once-per-head target scan out of line brought the loop back under it: −5%
cycles on requests, −16% on 1-byte fields (step 4).

## Conformance: llhttp's test suite

llhttp's markdown cases (`Tools/test-data fetch llhttp-tests llhttp-cases`: 258 cases, 211 in its strict modes) run
through HTTPBytes' parsers and framing (`LLHTTPDifferentialTests`). Agreement on all but 13, each a deliberate
difference listed in the test with its reason: extension methods are tokens (llhttp knows a fixed list), RTSP, ICE, and
HTTP/0.9 aren't HTTP/1.1, and a request naming a transfer coding besides `chunked` gets 501. The comparison found four
real gaps, fixed: raw UTF-8 in a request target (now rejected, as RFC 3986 and llhttp's strict mode do), an empty
`Transfer-Encoding` (now a framing error), CR LF before a status line (now skipped, as for requests), and a parse error
in the case generator.

## 2026-11-23: HPACK (baseline `hpack-1`)

HPACK (RFC 7541) and HTTP/2 field sections (RFC 9113 §8.2–8.3) in `HTTP2`; the Huffman code (prototype winner: 14-bit
two-symbol table, input read past its end as EOS's ones) and prefix integers in the core, for QPACK too. Each row is one
connection: a fresh 4,096-byte table and every field set of the corpus in order (http-corpus' QIF requests and responses;
hpack-test-case story 30, 646 responses, decoding nghttp2's own blocks). Decode rows decode HTTPBytes' encoder's blocks
(story 30: nghttp2's); every setup checks every block's fields byte for byte. Wall times were taken with other agents
running: judge by instructions.

| Row | HTTPBytes | cursed-http | ls-hpack | NIOHPACK |
|---|---|---|---|---|
| decode 401 requests | 1,067 K, 132 µs | 1,556 K, 169 µs | 2,152 K, 233 µs (139 mallocs) | 5,812 K, 574 µs (1,102) |
| decode 383 responses | 1,830 K, 211 µs | 2,664 K, 304 µs | 3,985 K, 408 µs (1,565) | 9,363 K, 929 µs (1,970) |
| decode story 30 | 2,093 K, 207 µs | 3,142 K, 306 µs | 4,817 K, 425 µs (1,980) | 11,000 K, 962 µs (2,416) |
| decode and validate 401 requests | 1,241 K, 135 µs | | | |
| decode and validate 383 responses | 1,974 K, 215 µs | | | |
| encode 401 requests | 1,615 K, 94 µs → 51,813 B | 2,978 K, 259 µs → 51,813 B | 3,281 K, 247 µs → 61,097 B (937) | 19 M, 1,489 µs → 61,097 B |
| encode 383 responses | 2,480 K, 161 µs → 80,966 B | 4,006 K, 385 µs → 80,966 B | 4,805 K, 392 µs → 83,388 B (1,912) | 27 M, 2,050 µs → 83,354 B |
| encode story 30 | 2,955 K, 196 µs → 66,752 B | 4,846 K, 476 µs → 66,752 B | 6,107 K, 514 µs → 67,398 B (2,933) | 36 M, 2,918 µs → 67,398 B |

HTTPBytes allocates nothing per block (`Allocations:HPACK_*` gates at 0; coders made once, `reset()` per connection).
HTTPBytes' decoder hands out views (known names resolved, characters checked once per literal); cursed-http's also
checks characters; ls-hpack copies every field out; NIOHPACK builds strings. The encoders' indexing policies differ:
HTTPBytes and cursed-http follow nghttp2's (no `:path`, `content-length`, dates-like fields in the table; short cookies and
credentials never indexed), ls-hpack and NIOHPACK index everything, and their requests come out 18% larger.

What it took, measured on the decoder and encoder alone (instructions per 401 requests):

| Change | decode | encode |
|---|---|---|
| First version | 1,124 K | 1,980 K |
| Static table entries as addresses in coder-owned memory, dynamic entries always storing names (the generated tables' accessors and `HTTPFieldName.lowercaseBytes` were cross-module calls per field: `Tools/calls`) | 992 K | 1,615 K |
| Characters checked once per literal, the verdict kept in dynamic entries (decoding and validating the responses: 1,974 K, against 2,408 K before, when validation added 43% to decoding; now 8%) | 1,124 K | |
| NUL, LF, CR flagged by the Huffman table (bit 24 of an entry, ORed per lookup: cursed-http's idea) instead of scanning decoded values | 1,061 K | |

Profile of the decoder (requests): the Huffman loop 66% of samples, `decodeNext` 28%. Of the encoder: Huffman coding 39%,
the field (static and dynamic matching, hashing, comparison) the rest.

Design notes: dynamic tables keep entries contiguous in a byte store twice the table's size (an entry that would straddle
the end goes to 0; live bytes plus the gap always fit), entries numbered by insertion so nothing renumbers; the encoder
finds entries through two hash chains (name and value; name) linked by insertion number, so evictions cost nothing (a
chain ends at the first number older than the oldest entry). The decoder's `next(in:)` returns fields whose views borrow
the block and the decoder (`@_lifetime(copy block, &self)`), so a field can't outlive the next call (the compiler rejects
it). Blocks split across CONTINUATION frames are joined in an `HTTP2FieldBlockBuffer` (one copy, only for split blocks).

## 2026-11-23: QPACK (baseline `qpack-1`)

QPACK (RFC 9204) and HTTP/3 field sections (RFC 9114 §4.2–4.3) in `HTTP3`: `QPACKDecoder` (field sections, the encoder
stream applied as its bytes arrive, the decoder stream's acknowledgments, cancellations, and increments, blocked streams)
and `QPACKEncoder` (static only until the peer's settings give a table; then the dynamic table with acknowledgment and
blocked-stream accounting). Each row is one connection from a fresh table: every field set of the corpus in order, each
section after the encoder stream bytes it needs, each section that used the table acknowledged at once (the encoders
take the peer's Section Acknowledgment; the decoders write their decoder stream). Static rows are static-only encodings;
"4,096" rows a 4,096-byte table and 100 blocked streams allowed; the qifs row decodes nghttp3's encoding of
`fb-resp-hq` (4,096 bytes, never blocking). Decode rows decode HTTPBytes' encoder's output (all three decoders decode the
same bytes). Every setup checks every section: HTTPBytes' decoder must give every field byte for byte (of its own
encoder's output and of each C encoder's), and each C decoder every section's field count and the corpus' total bytes
(the differential test against ls-qpack and cursed-http). References: ls-qpack 2.7.1 (`Tools/test-data fetch ls-qpack`,
`lsqpack_unity.c`, its xxhash shared with ls-hpack's: the files are identical) and cursed-http's `qpack.h` (5e10ca8). Wall
times taken with other agents building: judge by instructions.

| Row | HTTPBytes | cursed-http | ls-qpack |
|---|---|---|---|
| decode 401 requests, static | 2,333 K, 265 µs | 3,402 K, 421 µs | 3,693 K, 402 µs |
| decode 383 responses, static | 3,246 K, 381 µs | 4,370 K, 542 µs | 4,719 K, 556 µs |
| decode 401 requests, 4,096 | 1,211 K, 123 µs | 1,624 K, 176 µs | 2,165 K, 231 µs (89 mallocs) |
| decode 383 responses, 4,096 | 1,498 K, 143 µs | 2,191 K, 238 µs | 2,777 K, 300 µs (325) |
| decode qifs fb-resp-hq (nghttp3), 4,096 | 2,460 K, 287 µs | 3,537 K, 437 µs | 4,596 K, 524 µs (1,167) |
| encode 401 requests, static | 2,839 K, 152 µs → 149,146 B | 3,285 K, 198 µs → 149,146 B | 5,485 K, 332 µs → 149,146 B (3) |
| encode 383 responses, static | 3,879 K, 209 µs → 207,109 B | 4,526 K, 305 µs → 207,109 B | 7,127 K, 448 µs → 207,109 B (3) |
| encode 401 requests, 4,096 | 2,056 K, 112 µs → 55,074 B | 2,939 K, 252 µs → 52,874 B | 9,273 K, 780 µs → 53,439 B (119) |
| encode 383 responses, 4,096 | 2,533 K, 147 µs → 62,241 B | 3,910 K, 366 µs → 77,790 B | 14,000 K, 1,227 µs → 53,087 B (318) |

HTTPBytes allocates nothing per section (`Allocations:QPACK_*` gates at 0 for decoding static, dynamic, and the qifs file,
and encoding static and dynamic; coders made once, `reset()` per connection). Encoded sizes include the encoder stream.

What moved the numbers (decode instructions, 401 requests static / 4,096 / qifs):

| Change | static | 4,096 | qifs |
|---|---|---|---|
| First version | 5,190 K | 1,770 K | 3,832 K |
| The literal step's name as `let`s set once per path: a `var name: UnsafeRawPointer` assigned in branches and borrowed by a span was heap-boxed, a `swift_allocObject` per literal field (AGENTS.md's trap; found by the malloc gates, then `Tools/calls --callee swift_allocObject`) | 2,505 K | 1,229 K | 2,540 K |
| The literal step `@inline(always)` (`@inline(__always)` left it a call from three sites) | 2,333 K | 1,194 K | 2,460 K |

Before the box was found, a head-to-head of the Huffman decoders on the corpus' 9,502 strings (a throwaway driver)
showed HTTPBytes' at 282 µs a pass against cursed-http's `hh_decode_f` at 454: the gap had to be elsewhere.

The encoder's automatic policy is HPACK's (nghttp2's lists) plus one rule: a field is inserted the second time it's seen
(a direct-mapped history of field hashes, ls-qpack's idea). In HPACK an insertion is free (the literal carries the value
once either way); in QPACK it's the value again on the encoder stream plus a reference, and one-off response values
evicted entries that would have been used: 383 responses 74,097 → 62,241 B (−16%), 401 requests 52,874 → 55,074 B (+4%:
repeated fields' first sighting is a literal). Inserting a first-seen field anyway while it fits without evicting was
worse on both (57,140 and 64,066 B). ls-qpack still compresses responses 15% better (Duplicate instructions and a
draining index, which this encoder doesn't do yet).

Design notes:

- **Shared with HPACK, moved to the core (`Sources/HTTPBytes/FieldTables/`):** the dynamic table (`DynamicFieldTable`,
  insertion-numbered: QPACK's absolute index is the insertion number; a Duplicate's name and value move together, since
  they may be an entry the insertion evicts), the static tables by address in coder-owned memory (`StaticFieldEntries`,
  with a next-entry-with-the-same-name chain: QPACK's table doesn't keep a name's entries together), the encoders' hash
  chains and output cursor (`DynamicFieldIndex`, `FieldEncoderOutput`), the indexing strategy, and the field-section
  validator (`HTTPFieldSectionValidator`, called `HTTP2FieldValidator` and `HTTP3FieldValidator`). Huffman string literals
  take any prefix (QPACK's 3- and 5-bit name lengths) through a second entry point; HPACK's keeps its constants. QPACK's
  integers go to 62 bits (`readPrefixInteger62Continuation`). HPACK after the move (`qpack-hpack-before` →
  `qpack-hpack-after`): within ±0.4% on every row but decode-and-validate of the requests, +2.0% (1,241 → 1,266 K), not
  yet explained.
- **Blocked streams are held by the caller, not copied.** `begin(_:stream:)` returns `false` for a section whose
  Required Insert Count is past the inserts received, recording the stream (at most SETTINGS_QPACK_BLOCKED_STREAMS, two
  words each, allocated with the decoder); `nextUnblockedStream()` names it after the encoder stream catches up. A blocked
  request stream can't be read past its HEADERS frame (RFC 9204 §2.2.1 says not to release its flow control), so those
  bytes are already in the stream's receive buffer: a pool would be a second copy.
- **The encoder stream** is applied as complete instructions; the caller keeps an incomplete one's bytes, bounded at
  about four times the table's capacity (an insertion whose string lengths can't fit is rejected from its length).
  **The decoder stream**: acknowledgments and cancellations queue in a buffer made with the decoder
  (`QPACKError.decoderStreamFull`, checked before anything changes, when it can't take one); Insert Count Increments
  are counted and written after them.
- **Strict decoding:** a Required Insert Count larger than the section needs is an error (RFC 9204's MAY), as is any
  reference at or past it, to an evicted entry, or below a negative Base.

Tests (`Tests/HTTP3Tests`): RFC 9204 Appendix B (every example, table state after each, the encoder stream split at
every byte), the qifs interop corpus (`encoded/qpack-05`, which `qpack-06` links to: 528 encodings by f5, ls-qpack,
nghttp3, proxygen, qthingey, and quinn at capacities 256, 512, 4,096, blocking or not; these drafts started the table
at its maximum capacity, so the harness sends that Set Dynamic Table Capacity first; 24 files in the fast set, all in
`.bulk`), the `errors` set (err9 and err10 are valid under RFC 9204's static table), round trips through both coders
(http-corpus and every QIF file, five table configurations, instructions delivered late so sections block, no
acknowledgments, every strategy, Huffman on and off), malformed sections and instructions, every byte of 20 sections
truncated, 40 sections mutated at every byte (bulk), and HTTP/3 field-section validation.

## 2026-11-23: review fixes, HTTP/1 heads in pieces and HTTP/2 hardening

Measured with the `http1opt` head harness (`proc_pid_rusage` cycles, best of 5, every head checked) and a small HPACK
harness over http-corpus (4,751 request fields, 5,599 response fields; best of 7 × 200), old and new builds interleaved
three times.

**Lines in pieces are scanned once.** A partial line is remembered (`HeadScanner.partialLine`, `checked`, `mark`) and the
next call resumes its scans. A test of the partial line per line cost 4–10% of cycles on f128 (heads of 128-byte
values); instead, remembering a field line sets the walk's block mask to one bit at the line's start, so the walk's own
test sends it to the exact path, which resumes. The status line's inlined part shrank to the common line (`HTTP/1.x`, a
code, a reason without tabs, CR LF, inside the limit); the rest went out of line (`exactStatusLine`): limit checks and
resumption written inline cost the response corpora 5% in cycles with fewer instructions. A 60 KB value fed a byte at a
time: 60,025 calls in 0.13 s before, 0.48 ms after.

| cycles/head (instructions) | before | after |
|---|---|---|
| req | 237 (1,112) | 240 (1,113) |
| resp | 426 (2,275) | 432 (2,101) |
| treq | 659 (2,323) | 666 (2,329) |
| tresp | 1,014 (3,391) | 1,037 (3,164) |
| tiny / tinyresp | 49 / 51 | 48 / 44 |
| f128 | 788 (3,741) | 785 (3,740) |
| reqx / respx | 237 / 424 | 238 / 435 |

The +1–2.6% rows have the same instruction counts or fewer; an unchanged f128 build moved 788 → 822 cycles with identical
instructions during this work (layout), so they're within what code placement alone does here.

**Limits.** Empty lines before the start line count against `maximumHeadByteCount` (offsets from the bytes' start), and
the exact paths don't look past the limit (`headPrefix`), so a head's error no longer depends on how it was split (400
whole, 431 in pieces, for a malformed byte past the limit).

**HPACK.** The decoder checks a call's block against the one in progress (address and length, kept per block) and stays
stopped after an error; `decode(_:into:)` checks characters and connection-specific fields; the encoder lowercases HTTP/1
names and drops connection-specific fields when encoding a store.

| instructions (cycles) | before | after |
|---|---|---|
| requests: `next(in:)` | 1,057,834 (396,974) | 1,102,468 (397,628) |
| requests: `decode(_:into:)` | 2,953,741 (710,331) | 3,023,678 (734,762–745,639) |
| requests: encode | 1,620,158 (271,177) | 1,701,198 (271,997) |
| responses: `next(in:)` | 1,823,342 (636,132) | 1,895,026 (648,049) |
| responses: `decode(_:into:)` | 4,067,851 (1,031,557) | 4,211,540 (1,076,216) |
| responses: encode | 2,436,230 (445,760) | 2,548,593 (446,153) |

About 9 instructions per field for the block check, 5 more for `decode(_:into:)`'s field check. The encoder's first
version cost 11–13% in cycles: lowercasing a known name on every field (`lowercaseBytes`) where only a literal written as
a string needs it (matching ignores a known name's bytes), and two inlined copies of the field encoder; both fixed.

## 2026-11-23: the whole suite (baseline `final-1`)

Every benchmark in one run after the review fixes (p50 µs and instructions per iteration). Full table:
`Tools/bench-table HTTPBytes/Benchmarks final-1`. In instructions, HTTP/1, HPACK, and QPACK rows moved −8% to +6% from
the baselines above: HPACK's misuse checks (about 9 instructions a field) +4–6%, HTTP/1 responses −8% (the status line's
common case inlined, the rest out of line), QPACK +1%. The rows new here:

| Row | HTTPBytes | Reference |
|---|---|---|
| Structured Fields: 1,000 dictionaries (7 members) | 196 µs, 3.66 M | swift-http-structured-headers 22,000 µs, 368 M |
| Structured Fields: 1,000 lists (5 members) | 137 µs, 2.20 M | 14,000 µs, 236 M |
| Structured Fields: 1,000 `Priority` fields | 23 µs, 435 K (`HTTPPriority`) | 3,011 µs, 51 M |
| Body: 1 MB text, gzip, whole | 526 µs, 4.74 M (`HTTPContentDecoder`) | system zlib 627 µs, 7.18 M |
| Body: the same, chunked in 4 KB, chunk slices straight into the content decoder | 530 µs, 4.89 M | |
| Body: 1 MB text, br, whole | 2,001 µs, 23 M | |

The chunked path adds 0.8% to decoding the body (the chunked decoder's slices are passed on uncopied; a codec's
unconsumed tail at a chunk's end goes to a carry buffer). The Structured Fields parser is the iterators' (values are
views; nothing is built), against a library that builds a Swift value tree.

**Allocations.** Every gate is 0: HTTP/1 heads, heads into a reused `HTTPFieldStore`, chunked bodies, HPACK and QPACK
both ways, Structured Fields. `Allocations:Body_chunked_gzip` first counted 6 mallocs per body: the benchmark made a new
`HTTPContentDecoder` per body, and the codec's state (DEFLATE window and tables) is made with it. The decoder now has
`reset(contentEncoding:)` and `reset(applied:then:)`, which keep each coding's codec (`Decompressor.reset(for:)` keeps a
format's state) and the buffers: a connection's decoder reset per body allocates nothing after the first body of each
coding (gate 0; `resetForEachBody` checks gzip, br, a stack, gzip again, and identity on one decoder, each after a body
cut short). A fresh decoder per body costs 5 allocations against 1 MB of output; the timed rows still make one each.

## 2026-11-23: QPACK encoder: draining, Duplicate, names alone (baselines `r2-qpack-before`, `r2-qpack-after`)

ls-qpack compressed http-corpus' responses 15% better (53,087 B against 62,241 with a 4,096-byte table). The encoder
now does what ls-qpack does (`lsqpack.c`: `qenc_entry_is_draining`, `qenc_duplicable_entry`, `EEA_INS_LIT_NAME`):

- **A draining index** (RFC 9204 §2.1.1.1). Each entry's start among all insertions' bytes is kept per ring slot
  (encoder memory, made with it); an entry drains once three quarters of the capacity has been inserted from its start
  on, so a quarter or less of insertions will evict it. A boundary number moves forward as entries are inserted (each
  entry passed once). Draining entries aren't name references.
- **Duplicate** (§4.3.4). A field whose newest copy is draining is copied to the front when room can be made without
  evicting an entry still referred to: a section that may block refers to the copy (the old one can go); one that can't
  refers to the old entry, acknowledged (referred to first, so making room can't evict it), and later sections use the
  copy. When no copy can be made the old entry is still referred to if it may be.
- **Names alone.** A name the static table lacks, seen recently in a literal with another value, is inserted with an
  empty value and referred to (post-base if the section may block). The responses' lines with literal names went from
  157 (9,960 B) to 14 (485 B).
- **A shorter memory.** The history of fields seen (insert on the second sighting) has one slot per 64 bytes of
  capacity instead of one per 8, sized by the peer's capacity rather than the encoder's.

Step by step (383 responses, 4,096 bytes, acknowledged at once): 62,241 B; draining and Duplicate 58,031; the shorter
memory 55,386; names alone, and no name references to draining entries, 53,137 (ls-qpack 53,087). Where the bytes went
(lines: HTTPBytes before, after, ls-qpack): dynamic indexes 2,817, 2,832, 2,784; literals with a literal name 157, 14,
13; literals with a dynamic name 456, 630, 670; encoder stream 16,071 B, 6,264 B, 2,831 B (154 Duplicates against
ls-qpack's 202).

Method. A scratch driver (not checked in) runs each corpus as a connection under each setting: after section i the
peer's decoder has taken everything through section i − k in order, and its decoder stream (Section Acknowledgments,
Insert Count Increments) reaches the encoder: HTTPBytes' decoder for HTTPBytes' encoder, ls-qpack's for ls-qpack's (its
default options, Duplicate on). Bytes are sections plus encoder stream. The same model is in the benchmarks as
`QPACKFlight` (the decoder stream recorded once in setup and replayed per iteration, so iterations time the encoder
alone); its setups check HTTPBytes' output decodes exactly by HTTPBytes' decoder and by ls-qpack's (an FNV digest of
every field, `lsqpack_decode_digest`), in order and with each section decoded after the encoder stream of the k sections
after it, and ls-qpack's by HTTPBytes'. Instructions and cycles below are the driver's (`proc_pid_rusage` around 100
passes, the least cycles of 3 runs alternating old and new builds; other agents were building).

| Corpus, capacity, sections in flight, blocked | before | after | ls-qpack | after / ls-qpack | instructions | cycles |
|---|---|---|---|---|---|---|
| 383 responses, 4,096, at once, 100 | 62,241 | **53,137** | 53,087 | 1.001 | −4.5% | −5.6% |
| 383 responses, 4,096, at once, 0 | 78,764 | **60,688** | 59,850 | 1.014 | −8.7% | −8.6% |
| 383 responses, 4,096, 4, 0 | 78,394 | 81,148 | 86,262 | 0.941 | +1.3% | +1.6% |
| 383 responses, 4,096, 4, 100 | 59,677 | **53,396** | 59,918 | 0.891 | −2.3% | −0.5% |
| 383 responses, 4,096, 16, 0 | 82,276 | 84,389 | 129,724 | 0.651 | +0.7% | +1.5% |
| 383 responses, 4,096, 16, 100 | 62,356 | **53,631** | 66,216 | 0.810 | −3.5% | −0.9% |
| 383 responses, 16,384, at once, 100 | 46,082 | 46,053 | 50,623 | 0.910 | +0.2% | −0.2% |
| 383 responses, 16,384, 4, 0 | 57,124 | 56,740 | 57,945 | 0.979 | +0.0% | −0.3% |
| 383 responses, 16,384, 16, 0 | 68,089 | 67,726 | 68,873 | 0.983 | +0.1% | −0.1% |
| 401 requests, 4,096, at once, 100 | 55,074 | **53,392** | 53,439 | 0.999 | −0.3% | −0.7% |
| 401 requests, 4,096, at once, 0 | 58,869 | **56,690** | 55,698 | 1.018 | −0.6% | −0.9% |
| 401 requests, 4,096, 4, 0 | 64,401 | **61,009** | 59,803 | 1.020 | −0.9% | −0.4% |
| 401 requests, 4,096, 4, 100 | 59,710 | **53,411** | 53,438 | 0.999 | −2.7% | −2.5% |
| 401 requests, 4,096, 16, 0 | 70,882 | 73,896 | 73,535 | 1.005 | +3.1% | +4.4% |
| 401 requests, 4,096, 16, 100 | 60,997 | **54,359** | 54,037 | 1.006 | −3.2% | −1.7% |
| 401 requests, 16,384, at once, 100 | 53,210 | 53,210 | 52,137 | 1.021 | +0.4% | −0.1% |
| 401 requests, 16,384, 16, 0 | 68,092 | 68,092 | 66,659 | 1.021 | +0.4% | +0.2% |

Bytes went up only with no blocking and acknowledgments 4–16 sections late (+2.6% to +4.3%): the shorter memory inserts
fewer fields there, and still beats or matches ls-qpack. With the table never full (requests, 16,384) nothing drains;
ls-qpack is 2% smaller there by inserting `:path` and the other fields HPACK's policy avoids (inserting them too: 47,452
B there, but +1% to +22% on the 4,096-byte request rows; not kept).

The benchmark rows (`Tools/bench-table HTTPBytes/Benchmarks r2-qpack-before r2-qpack-after`; instructions per corpus,
wall times under load, where ls-qpack's unchanged rows moved −3% to +3%):

| Row | before | after | ls-qpack |
|---|---|---|---|
| encode 383 responses, 4,096 table | 2,593 K, 149 µs | 2,478 K, 138 µs | 14,000 K, 1,192 µs |
| … 4 in flight, 0 blocked | 2,800 K, 156 µs | 2,836 K, 165 µs | 15,000 K, 1,359 µs |
| … 16 in flight, 0 blocked | 2,882 K, 151 µs | 2,902 K, 155 µs | 26,000 K, 2,343 µs |
| … 16 in flight, 100 blocked | 2,595 K, 143 µs | 2,503 K, 137 µs | 14,000 K, 1,177 µs |
| … 16,384 table, at once | 2,267 K, 125 µs | 2,271 K, 125 µs | 5,394 K, 409 µs |
| encode 401 requests, 4,096 table | 2,089 K, 112 µs | 2,083 K, 111 µs | 9,273 K, 780 µs |
| … 16 in flight, 0 blocked | 2,298 K, 120 µs | 2,374 K, 126 µs | 11,000 K, 924 µs |
| … 16 in flight, 100 blocked | 2,169 K, 114 µs | 2,095 K, 112 µs | 9,322 K, 794 µs |

Every `Allocations:QPACK_encode_*` gate is 0, two new ones included (16 sections in flight, blocking and not). The
encoder's per-field cost is a compare against the draining boundary; an insertion adds a store and the boundary's
advance. `insert` has two call sites now and stays a call, as it was with one (`Tools/calls`).

Tried and not kept (383 responses, 4,096 bytes, at once / 16 in flight with 100 blocked, B):

| Variant | at once | 16 in flight |
|---|---|---|
| Kept: zone ¼, Duplicate on use, names alone | 53,137 | 53,631 |
| A literal for a draining entry no copy can be made of (the strict reading of "not referenced") | 53,137 | 69,736 |
| Second chance: Duplicate, at each section's end, the entries that became draining and were referred to while in the table (ls-qpack's `qenc_dup_draining` keeps recently seen ones) | 54,994 | 69,332 |
| Draining zone 3⁄16 / 5⁄16 of the capacity | 52,350 / 53,412 | 53,419 / 54,391 |
| History with one slot per 32 bytes / per 8 (as before) | 55,110 / 56,300 | 55,783 / 57,659 |
| The draining index without Duplicate | 64,443 | 81,179 |

Second chance cost the 4,096-byte rows 0.5–29% (copies of fields used once crowded out fields used again). Zone 3⁄16
won the immediate row by 1.5% and lost 7.6% with no blocking (65,333 against 60,688). One slot per 8 bytes was better
with 4 sections in flight and no blocking (73,451) and worse everywhere else.

Tests (`QPACKDrainingTests`): the exact bytes of a Duplicate referred to post-base (section may block) and of one whose
old entry is referred to (it can't); draining entries aren't name references; a name seen twice is inserted alone, then
referred to; a link harness with encoder stream and sections each delivered late (0–16 sections), Stream Cancellations
(before a section is read and while it's blocked), Insert Count Increments, and the decoder stream fed back whole or a
byte at a time, checking every section decodes exactly and the decoder never holds more than the blocked-streams
setting (8 settings on both corpora; the bulk suite 5 capacities × 3 blocked settings × 7 lag pairs × cancellations on
5 corpora, 4 s in release); and 7,249 bytes of decoder stream for 767 outstanding sections fed a byte at a time
against the same stream whole (linear: under 500 ms). The harness fails on purpose-broken encoders: ignoring
unacknowledged sections' references when evicting (`invalidIndex`), and one blocked stream too many
(`tooManyBlockedStreams`).

## 2026-11-23: round 2, HTTP/1's remaining gaps (measured, not kept)

The cycle harness of round 1 (`proc_pid_rusage` around each parser, the previous `HTTP1` as a second module in the same
binary), best of 3, cycles per head. Before: req 240, resp 433, treq 662, tresp 1,038, tiny 48, tiny alone 59,
f1 365, f16 481, f128 785; cursed-http resp 367, tresp 897, tiny alone 47.

**Skip windows for long lines** (cursed-http's `fb_ctany_simd`: "maybe a control in 256, then 512 bytes?", an add and a
signed min per 16 bytes). The long lines are there: 44% of http-corpus responses' bytes are in 231 lines of 512–1,023
bytes, 38% of top-1k responses' in 531 lines of 1 KB or more, none with bytes ≥ 0x80. No setting gained:

| Variant | resp | tresp | treq | f128 |
|---|---|---|---|---|
| Windows inside `farStop` after 3 exact blocks | 449 | 1,109 | 690 | 908 |
| Windows in an out-of-line function `farStop` calls | 443 | 1,070 | 674 | 947 |
| `farStop`'s loop kept in shape (its bound capped at 3 blocks), windows after it | 444 | 1,057 | 664 | 792 |
| … windows after 1 or 0 exact blocks | 445 | 1,059–1,078 | 669–688 | |

Instructions rose 5–8%: our exact masks are cheap (29 instructions per 64 bytes, against cursed-http's exact path), and
lines of 256–1,023 bytes waste a window. Two codegen lessons on the way: adding a call to `farStop` left
`RawSpan.byteCount` an out-of-line call in it, and a loop with a second exit for "3 blocks done" became nested duplicated
loops (85 instructions with calls against 29). cursed-http's response parser itself doesn't use windows (an adversarial
review of this round's plan pointed out): it classifies 4 blocks ahead into a per-head array, which round 1 measured in
our design (a ring of 8 blocks) at +25% on requests and +67% on tiny heads; the response gap stays open.

**Tiny heads given only their bytes:** the gap is now 8–11 cycles (tiny alone 56–59 against 48 with the next head's bytes
readable), not round 1's 21. Building the last partial block from overlapping 16-byte loads clamped to the bytes' end, with
the mask put back in place, instead of copying it to the stack: tiny alone 58 against 56, and f128 895 against 787 (the
inlined block mask grew the parse loop again). The copy isn't the cost; a padded-input API (the caller promising
readable bytes past the message) could recover at most those 8 cycles, on heads under 64 bytes only. Not built.

## 2026-11-23: round 2, bodies as pipeline stages

`HTTP1Dechunker` and `HTTP1Chunker` (HTTP1) are chunked transfer coding as Bytes `ByteTransform` stages;
`HTTPContentDecoder` and `HTTPContentEncoder` (HTTPPayload) conform as they are (the decoder `Resettable`, keeping its
codecs); `HTTPBodyDecoder` (HTTPPayload) decodes a whole HTTP/1 body: its framing (`Content-Length`, chunked, until close)
and content codings in one stage.

`HTTPBodyDecoder` exists because of the adversarial review of the first version: composing the stages with Bytes'
`then(_:)` finishes the pipeline when its last stage finishes, so `dechunker.then(gzipDecoder)` ended a body at the gzip
stream's end. A body missing its last chunk read as finished, and bytes inside the chunked body after the stream (an
attacker's request) were left to be read as the next message: request smuggling. The body decoder finishes only at the
framing's end, requires the coded stream to end exactly there (`malformed` for bytes after it or a stream cut short), and
hands chunk slices straight to the content decoder (no buffer). The review's other findings, all fixed: trailers left for
the next reader by default (now skipped by default, `.leave` read through `nextTrailer`); a stacked coding's outer stream
cut short passing `.finish`; options mutable after `init` out of step with an internal flag; a decoder's raised limits
letting a peer trip `Pipeline`'s unit precondition (limits now clamped to the stage's unit); the chunker losing a byte at
digit boundaries (20 bytes of room: 14 of 15; now exact, tested for every room 5–300). Writing the tests found one more:
at the framing's end the content decoder can still hold output (all input taken, output full last time): drained before
the end is checked.

1 MB of text, gzip, chunked in 4 KB (p50): the hand-written loop (chunk slices to the content decoder) 4,887 K instructions,
536 µs; `HTTPBodyDecoder` 4,891 K, 535 µs; the first version's pipeline (dechunker, a 16 KiB buffer, decoder) 4,813 K,
527 µs. `Allocations:Body_decoder_chunked_gzip` (one decoder reset per body): 0.

## 2026-11-23: round 2, dates and field values (baselines `r2-fields-1`, `r2-fields-3`)

`HTTPDate` (RFC 9110 §5.6.7): IMF-fixdate read as four 8-byte words (fixed bytes by mask, 14 digits by one SWAR test,
the month by a perfect hash of its letters: `(letters × 26596) >> 28`, the day name checked against the date's),
Hinnant's day arithmetic both ways; RFC 850 (two-digit years at most 50 years past a reference date, the 50th year
decided by date and time) and asctime byte by byte; writing IMF-fixdate as three words and five bytes; `HTTPDateCache`
(29 bytes reformatted when the second changes). Tests: RFC and Rust httpdate vectors, 39 refusals, Foundation's
`Date.HTTPFormatStyle` agreeing on every day 1970–2200 both ways, every day from year 0 to 9999 round-tripping through
all three formats (bulk, 0.3 s in release). Deliberate differences: case-sensitive (Foundation and Python aren't), a
mismatched weekday refused, second 60 accepted as the next minute's first (Go refuses it).

Field values (HTTPBytes core, all views or plain values, no allocations): the shared grammar (`HTTPListElements`,
`HTTPParameters`, `HTTPQuotedString` with escapes removed only when written or compared, `HTTPWeight`), `HTTPMediaType`,
`HTTPAcceptList` (weights for tokens, media types by specificity, languages by RFC 4647 basic filtering),
`HTTPContentCoding.negotiated` (HTTPPayload), `HTTPRangeSet` (resolved into the caller's storage, sorted and merged, with
a count limit; invalid sets ignored, all-unsatisfiable 416), `HTTPContentRange`, `HTTPEntityTag`/`HTTPEntityTagList`,
`HTTPIfRange`, `HTTPPreconditions` (RFC 9110 §13.2.2's order), `HTTPCacheControl`, `Age`, `Expires`, `HTTPRetryAfter`,
`HTTPTokenList` (Vary, Connection, …), `HTTPUpgradeList`, `HTTPHost`, `HTTPForwardedElements`, `HTTPCredentials` and
`HTTPChallenges` (the comma ambiguity of challenge lists resolved by what follows each element), `HTTPContentDisposition`
with RFC 8187 `filename*` (UTF-8 and ISO-8859-1), `HTTPPercentEncoding`, `HTTPTargetComponents` (path segments, query
items), `HTTPCookies`, `HTTPSetCookie` (written, validated). Tests transcribe Go's `range_test.go` and
`mediatype_test.go`, jshttp's negotiator and fresh, and http-tests' cache-tests (`cc-parse`), with the differences stated.

Every value of a field in http-corpus and top-1k (p50 per iteration over all of them; per value in brackets). Under load
(the zstd agent building): judge by instructions.

| Row (values) | First version | Vector scans | Per value |
|---|---|---|---|
| Date, Last-Modified (3,375): parse | 771 K, 44 µs | 771 K, 44 µs | 228 instructions, 13 ns |
| … Foundation `Date.HTTPFormatStyle` | 27 M, 1,544 µs, 3,807 mallocs | | 8,000, 457 ns |
| 1,000 dates written | 379 K, 23 µs (the harness's array) | 319 K, 20 µs | 319, 20 ns |
| … Foundation | 4.4 M, 272 µs, 1,000 mallocs | | 4,400, 272 ns |
| 1,000 `Date` fields from `HTTPDateCache` | 13 K, 1.5 µs | | 13, 1.5 ns |
| ETag (591) | 372 K | 89 K, 5 µs | 150, 8 ns |
| Host (3,935) | 2.1 M | 1.49 M, 105 µs | 378, 27 ns |
| Content-Type (2,332) | 2.1 M | 1.42 M | 608 |
| Cache-Control (1,942) | 2.6 M | 2.13 M | 1,100 |
| Accept (2,600), weight of text/html | 7.5 M | 5.68 M | 2,180 |
| Accept-Encoding (2,599), br/gzip/identity | 24 M, 16,000 mallocs | 3.51 M, 0 | 1,350 |
| Accept-Language (344), weight of en-US | 333 K | 313 K | 910 |
| Cookie (818), every cookie | 1.33 M | | 1,630 |
| Request targets (3,934), path and query items | 3.4 M | | 866 |

"Vector scans": tokens by `HTTPCharacters.nonToken`'s nibble lookups, quoted strings and entity tags by a search for
the next quote, backslash, or byte that can't be there, a host's registered name by one test of 16 bytes at a time
(`HTTPRequestTarget.nonURIByte` and the six delimiters), all through Bytes' `firstByteOffset(where:)` (short values in
one overlapping block). Accept-Encoding negotiation was generic over `some Sequence` without `@inlinable`: unspecialized,
it boxed its iterator (6 mallocs a value), and parsed the list once per offered coding; now inlinable and one pass.
Allocation gates at 0: `FieldValues_dates`, `_cache_control`, `_accept`, `_cookies_targets`.

An adversarial review (2.6 M fuzzed inputs through every parser, `HTTPDate` against Foundation on 200 K dates, IPv6
against `inet_pton` on 300 K: no traps, no allocations) confirmed six defects, all fixed with regression tests:

1. `HTTPRangeSet.resolve` refused sets whose union fit the storage: it merged a new range only with the one before it,
   and inserting in arrival order can need more slots on the way than in the end (`3-5, 25-41, 4-`). It now sweeps the
   set (the lowest uncovered range, grown while anything overlaps or touches it), so the storage holds only the answer;
   checked against an unbounded sort-and-merge on 20,000 random sets at every storage size 0–4. Sets of more than 256
   ranges are ignored (RFC 9110 §14.2).
2. `Retry-After` with a huge delay wrapped to the past: the sum saturates.
3. One malformed `Cache-Control` element threw the whole field away, `no-store` with it: parsing no longer throws;
   bad elements are skipped, an unclosed quote ends the field there.
4. `HTTPTargetComponents` and `HTTPRequestTarget.validate` disagreed on forms (`http:foo`, `example.com:443` without
   CONNECT): components now take the method and split as `validate` decides.
5. `Content-Disposition` took the first of two `filename`s (RFC 6266 §4.1: invalid; recipients taking the last see
   another name): repeated parameter names are refused.
6. `filename*` decoded to control bytes and invalid UTF-8 (`%00%2F..%2Fx%0D%0A`): decoded names, and plain ones, must be
   well-formed UTF-8 without C0, DEL, or C1 controls.

Lesser ones fixed: a malformed `If-Match` or token list answered by element order (now the whole list is read);
`HTTPPreconditions.evaluate`'s `exists` now defaults to whether the representation has a validator; leap seconds only
at 23:59:60 (and not on 9999-12-31); `components` near the `Int64` extremes clamped as writing is; `HTTPEntityTag.write`
checks its characters (a quote or CR LF would inject); `Set-Cookie`'s `Path` and `Domain` refuse bytes past ASCII;
`Negotiate , Basic realm="x"` parses; a media range's parameter count can't overflow its specificity. Not changed:
`HTTPHost` accepts what RFC 3986's reg-name does (`a,b`, `%00`: a `Host` caller checks its own policy), `Forwarded` pairs
may repeat, `weight(ofToken:)` doesn't map `x-gzip`, `max-age="\5"` isn't unescaped.

## 2026-11-23: round 2, Zstandard bodies (baseline `r2-payload-1`)

`HTTPContentEncoder(.zstd)` encodes with BytesCompression's new `ZstdEncoder` (Bytes/Benchmarks/RESULTS-zstd-encoder.md:
libzstd's levels 1–4, frames byte for byte as libzstd 1.5.7's, cycles −14% to +5% of libzstd's), at level 3 with a
512 KiB window (`ZstdEncoder.Parameters.httpWindowLog`: RFC 9659 caps the window at 8 MB; against level 3's own 2 MB
window it costs 0–4% in size, and the encoder's memory falls from 3.7 to 2.1 MB streaming). `reset()` starts another
body keeping the encoder's memory. 1 MB of text with a reused encoder (p50, under load):

| Coding | Instructions | Time | Mallocs |
|---|---|---|---|
| gzip, level 6 | 138 M | 11.0 ms | 0 |
| br, quality 5 | 183 M | 12.0 ms | 0 |
| zstd, level 3, 512 KiB window | 26 M | 1.7 ms | 0 |

`Allocations:Body_encode_zstd`: 0. Tests: zstd bodies decoded whole and fed 7 and 1,000 bytes at a time, and through the
coding-then-chunking pipeline and `HTTPBodyDecoder`.
