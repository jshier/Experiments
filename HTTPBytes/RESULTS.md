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
