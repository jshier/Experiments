# HTTPBytes: HTTP framing in Swift at memory speed

HTTP/1.1, HTTP/2, and HTTP/3 framing, field compression, and content codings, written in Swift on the Bytes package,
with no allocations per message and vector code where bytes are scanned. This is the summary: what was built, the
techniques that made it fast, how correctness was established, and the numbers. `RESULTS.md` is the step-by-step record
(every change and its measurement), `PLAN.md` the plan as reviewed.

M1 Max (8 performance and 2 efficiency cores), macOS 27.2, Swift 6.4 (Xcode 27.3). All numbers are from the benchmark
package (`HTTPBytes/Benchmarks`, baseline `final-1`, p50 per iteration) unless a section says it used the cycle harness.

## Results at a glance

| Workload | HTTPBytes | Fastest other | Others |
|---|---|---|---|
| HTTP/1: 401 real request heads (232 KB) | **35 µs** | cursed-http 38 µs | picohttpparser 92, llhttp 89 |
| HTTP/1: top-1k, 3,533 request heads (4.1 MB) | **761 µs** (5.4 GB/s) | cursed-http 806 | picohttpparser 1,773, llhttp 1,744 |
| HTTP/1: 383 real response heads (365 KB) | 53 µs | **cursed-http 45** | picohttpparser 127, llhttp 131 |
| HTTP/1: 20 fields of 128 B, 1,000 heads | **254 µs** | cursed-http 322 | llhttp 485, picohttpparser 806 |
| HTTP/1 heads into owned fields (401) | **111 µs, 0 mallocs** | | swift-http-types `HTTPFields` 604 µs, 3,669 mallocs |
| 3,000 field lookups by name | **8.1 µs** | | `HTTPFields` 634 µs |
| HPACK decode, 401 requests | **132 µs** | cursed-http 162 | ls-hpack 228, NIOHPACK 552 |
| HPACK encode, 401 requests | **89 µs** | ls-hpack 239 | cursed-http 244, NIOHPACK 1,422 |
| QPACK decode, 401 requests, 4 KB table | **120 µs** | cursed-http 171 | ls-qpack 235 |
| QPACK encode, 401 requests, 4 KB table | **107 µs** | cursed-http 238 | ls-qpack 751 |
| Structured Fields, 1,000 dictionaries | **196 µs** | | swift-http-structured-headers 22,000 µs |
| 1 MB gzip body, chunked in 4 KB | **530 µs** (2.0 GB/s out) | | system zlib, whole: 627 µs |

- **HTTP/1:** 2.1–2.6x as fast as picohttpparser and llhttp on every real corpus. Ahead of cursed-http (a C parser built
  on the same idea, and the fastest found) on requests and on long fields. Behind it on responses: 13–16% more cycles, 16–18% more time.
- **HPACK:** fastest of the four both ways. Decoding takes 28–30% fewer instructions than cursed-http; encoding is
  2.5–2.7x as fast as cursed-http and 14–16x as fast as NIOHPACK.
- **QPACK:** fastest of the three on every row. Encoding with a table is 7–8x as fast as ls-qpack.
- **Structured Fields:** 100–130x as fast as the Swift package that builds a value tree. The iterators build nothing.
- **Allocations:** every per-message path allocates nothing after setup. Every `Allocations:` gate is 0: HTTP/1 heads,
  owned field stores, chunked bodies, content decoding with a reused decoder, HPACK and QPACK both ways, Structured
  Fields.

## What's in the package

Six library products, about 13,300 lines, and 207 tests in about 7,000 lines:

| Product | Contents |
|---|---|
| `HTTPBytes` (core) | `HTTPMethod`, `HTTPStatus`, `HTTPVersion`, `HTTPFieldName` (a perfect hash over about 120 names), `HTTPFieldView`, `HTTPFieldStore`, `HTTPList`/`HTTPToken` field grammar, request-target validation (RFC 3986), Structured Fields (RFC 9651) and `HTTPPriority` (RFC 9218), the HPACK/QPACK Huffman code and prefix integers, the dynamic and static field tables both compressors share, field-section validation |
| `HTTP1` | Streaming request and response head parsers, body framing (RFC 9112 §6.3), a chunked decoder that hands out slices, a chunked encoder, a head writer |
| `HTTP2` | Every frame type, settings, CONTINUATION joining with a flood limit, HPACK decoder and encoder, cookie crumbs, RFC 9113 §8.2–8.3 field rules |
| `HTTP3` | QUIC variable-length integers, frames with per-stream order and role rules, QPACK decoder and encoder (encoder and decoder streams, blocked streams, acknowledgments) |
| `HTTPPayload` | Content codings gzip, deflate, br, and zstd (decode only), stacked up to two, with a decoded-size limit, on BytesCompression |
| `HTTPBytesHTTPTypes` | Conversions to and from swift-http-types |

No NIO, no C, no Foundation in the library. It is Swift 6 language mode, with `NonisolatedNonsendingByDefault`,
`InferIsolatedConformances`, `ExistentialAny`, `MemberImportVisibility`, and `InternalImportsByDefault`. Lifetimes are
on, the library targets have strict memory safety, and every error is a typed throw. The benchmarks are a separate
package, so the library never builds the C references, NIO, or swift-http-types.

### API shape

- **Views, not copies.** A parsed field is an `HTTPFieldView`: a name span, a value span, and (where one is known) the
  name's index in the well-known table. Views are `~Escapable`, so the compiler rejects one that would outlive its bytes.
  For HPACK and QPACK, it also rejects one kept past the decoder's next call.
- **Streaming events.** `HTTP1RequestParser.next(in:)` returns events in order:
  - `.requestLine`, then
  - `.field` for each field, then
  - `.end(headByteCount:)`, or `.needsMore` when the bytes so far don't reach the next event.

  A server can act on the method, the path, or one header as soon as it arrives, and stop reading. The whole-head parse is
  the same loop. The parser keeps offsets, not bytes, and resumes inside the line it stopped in.
  ```swift
  var parser = HTTP1RequestParser()
  loop: while true {
      switch try parser.next(in: received) {
      case .requestLine(let line): if line.knownMethod == .connect { … }
      case .field(let field): if field.knownName == .host { … }
      case .end(let headByteCount): body = received.extracting(droppingFirst: headByteCount); break loop
      case .needsMore: received = await more(); continue  // the same bytes, with more after them
      }
  }
  ```
- **Owned storage, reused.** `HTTPFieldStore` holds fields that must outlive the input in one byte array and one entry
  array, emptied with `removeAll(keepingCapacity:)`. Coders and decoders are made once per connection and reset:
  HPACK, QPACK, the chunked decoder, and now `HTTPContentDecoder.reset(contentEncoding:)`.
- **swift-http-types' vocabulary, distinct names.** Names such as method, status, field name, pseudo-header, and
  never-indexed come from swift-http-types, but the types are called `HTTPMethod`, `HTTPFieldStore`, `HTTPFieldView`.
  Code importing both needs no module qualification, and `HTTPBytesHTTPTypes` converts between them.
- **Errors carry no payloads.** `HTTP1Error` knows its status (400, 414, 431, 501, 505). `HPACKError` and `QPACKError`
  map to the RFC error codes. Nothing is boxed and no strings are built.

## HTTP/1: a structural index walked with bit scans

### The design, chosen by prototype

Three throwaway parsers ran on 401 real request heads before any API existed:

| Strategy | ns/head | instructions/B | cycles/B |
|---|---|---|---|
| Scan each line for its delimiters (16-byte `firstByteOffset` tests) | 168 | 2.62 | 0.93 |
| **Structural index:** classify 64-byte blocks into bitmasks once, walk them with `ctz` | **112** | 3.18 | **0.62** |
| picohttpparser (scalar on ARM: its fast path is SSE4.2) | 225 | 7.81 | 1.23 |
| llhttp (a generated state machine) | 220 | 6.55 | 1.20 |

Per-line scanning runs fewer instructions and more cycles. Header lines are 15–40 bytes, and every short scan's exit
branch mispredicts. The structural index (simdjson's idea) classifies each 64-byte block into two masks:

- "stops": controls other than tab, and DEL;
- non-token bytes.

A field line is then two bit scans. The name ends at the first non-token byte, which must be the colon, so no other
check of the name's characters is needed. The value ends at the first stop, which must be CR then LF. The walk only
moves forward, so the parser keeps one block's masks rather than an index of the head, and needs no memory per message.

Swift's SIMD can't express a 64-byte movemask, which on NEON is an `addp` reduction. So Bytes gained `ByteBlock`, 64
bytes tested into one 64-bit mask, with `bytes_movemask64` in its CBytesNEON C module (portable fallback: four 16-byte
bitmasks). With 16-byte masks in Swift alone the index ran 0.87 cycles a byte.

### Getting a library to the prototype's speed, then past cursed-http

The first library version ran 1.12 cycles a byte, the prototype 0.62. The gap was inlining and memory, not the
algorithm:

- `next(in:)` and the per-field step `@inline(always)` into the caller's loop.
- The mask builder made a static function returning values. As an out-of-line `mutating` method it kept the whole
  scanner in memory for the loop.
- Unchecked byte loads where the offset is proven in range.
- The field-name hash on two 8-byte words.

Together: 1.12 → 0.84 cycles a byte.

cursed-http, a C parser on the same design whose README claims it beats picohttpparser everywhere, then became the
target. Seven steps took request heads from 491 to 258 cycles each, against cursed-http's 275 (cycle harness):

1. **The walk reorganized.** Each line's end is found first, in the block's stop mask. The name comes from one 16-byte
   nibble-class mask at the line's start. Common methods (`GET `, `PUT `, `POST`, `HEAD`) and `HTTP/1.x` CR LF are word
   compares. Anything unusual goes to exact, stateless paths out of line.
2. **The exact paths take and return values**, and the walk and the start lines are inlined. Each piece left out of
   line had kept the parser in memory.
3. **Known names are looked up only when asked** (`HTTPFieldView.knownName`, lazily). Looking up every field's name
   cost a fifth of the parse for callers that never ask; asking for all of them now costs 44 cycles a head.
4. **The target scan moved out of line.** The inlined loop had outgrown the SIL inliner's caller limit, after which
   `RawSpan.byteCount`, a two-instruction getter, stayed a call three times per field. Each call clobbered the vector
   registers holding the name tables. −16% on 1-byte fields.
5. **Line stops are just controls or DEL** (two compares and an OR), with a tab checked where the walk stops.
6. **The target scan builds its block's stop mask**, which starts the walk, and a partial block is copied inline.
7. **Masks from four plain loads, combined by weighted pairwise adds.** This replaced `ld4` and cursed-http's
   shift-right-insert packing, which takes 5% fewer instructions but 5–16% more cycles: the mask is on the walk's
   critical path, and `ld4` delivers 64 bytes in 2 cycles against 1.33 for four plain loads (`Tools/cpu-probe insn`).

Per head, cycles (cycle harness):

| Corpus | HTTPBytes | cursed-http | picohttpparser | llhttp |
|---|---|---|---|---|
| 401 requests (580 B) | **258** | 275 | 711 | 698 |
| 383 responses (953 B) | 426 | **366** | 1,055 | 1,058 |
| top-1k requests (1,162 B) | **665** | 724 | 1,579 | 1,566 |
| top-1k responses (2,004 B) | 1,028 | **912** | 2,447 | 2,128 |
| 20 fields of 128 B | **788** | 1,028 | 2,590 | 1,525 |
| tiny requests (38 B) | 52 | **47** | 62 | 158 |

The response gap is branch mispredictions. CPU Counters put 42% of HTTPBytes' cycles on top-1k responses in discarded
work, against cursed-http's 33%. 57% of those heads' bytes sit in lines of 256 bytes or more, and cursed-http's response
parser classifies four blocks ahead, so a line crossing blocks takes no branch. Two batched versions were built here.
Both cost more than they saved, because they classify past a short head's end and test long lines again.

### Measured and rejected

| Idea | Why not |
|---|---|
| Masks for 5 blocks at a time, a 64-bit window across two | requests 279 → 312 cycles, tiny heads 55 → 86 |
| A ring of 8 blocks' masks, 4 tested ahead | requests 279 → 350 |
| A name's first 32 bytes without a branch | 128-byte fields 788 → 913 |
| The mask builder inlined into the walk | 333 → 347: the loop's size again |
| Request-target validation on by default | +15% to +69% cycles, and it rejected 52 of 401 real browser requests (raw `[` `]` in queries): it's `validatesTargets`, off by default |

### Heads in pieces, framing, bodies

- **Partial lines are scanned once.** A partial line is remembered: where it starts, how far it was checked, and a mark.
  The next call resumes its scans. Rather than a test per line, remembering a line sets the walk's mask to one bit at
  its start, so the walk's own test sends it to the exact path. A 60 KB value fed a byte at a time: 0.13 s before, 0.48
  ms after.
- **Framing** (`HTTP1Framing`, fed each field) covers RFC 9112 §6.3:
  - Content-Length and Transfer-Encoding conflicts; `Content-Length: ,` and an empty Transfer-Encoding are invalid.
  - CONNECT with a body is rejected.
  - Responses take the request's method (HEAD, 1xx/204/304, 2xx to CONNECT).
  - `Expect: 100-continue` is honored only from HTTP/1.1.
  - A message with both Content-Length and Transfer-Encoding closes the connection.
- **Chunked bodies** come from a cursor that returns slices of the input. Chunk data is never copied, and the slices go
  straight into the content decoder. Chunk extensions are parsed to their grammar, and extensions and trailers have
  byte limits. A 1 MB body in 4 KB chunks takes 3.4 µs to frame.

## Field names: a perfect hash on two words

About 120 well-known names (IANA's registry, plus the HPACK and QPACK static tables' names) are looked up by a perfect
hash. The key is the length and two 8-byte words read from fixed offsets (four 4-byte loads, selected without a
branch), ORed with 0x20 to fold case. The bucket holds the name's words precomputed, so a lookup is one hash, one table
load, and two compares, with no byte loop and no case-folding pass.

- **Branch-free word loads.** A first version branched on the length class: `Host`, `Accept`, and `Connection`
  alternate between short and long. It mispredicted whenever consecutive names changed class, and cost 38 cycles a head.
  Selecting the loads instead removed that.
- **Generated tables.** The tables come from a Perl generator as literals, so they're statically initialized (no
  `swift_once`). Name bytes that spans must reference forever are `StaticString` literals. A `static let` `InlineArray`
  can't back an immortal span: reading it may make a temporary copy, and the span then points at dead stack. That bug
  was found by tests reading the last names as garbage.

`HTTPFieldStore` keeps each field's known-name index beside its offsets, so finding a field by name is a 16-lane scan of
one-byte indexes: 3,000 lookups in 8.1 µs, against 634 µs for swift-http-types' `HTTPFields`.

## HPACK

| Row (instructions, time) | HTTPBytes | cursed-http | ls-hpack | NIOHPACK |
|---|---|---|---|---|
| decode 401 requests | **1,113 K, 132 µs** | 1,558 K, 162 µs | 2,150 K, 228 µs | 5,796 K, 552 µs |
| decode 383 responses | **1,906 K, 216 µs** | 2,664 K, 280 µs | 3,961 K, 387 µs | 9,363 K, 884 µs |
| decode hpack-test-case story 30 (nghttp2's blocks) | **2,212 K, 206 µs** | 3,142 K, 299 µs | 4,817 K, 416 µs | 11 M, 936 µs |
| encode 401 requests | **1,708 K, 89 µs** | 2,978 K, 244 µs | 3,281 K, 239 µs | 19 M, 1,422 µs |
| encode 383 responses | **2,556 K, 143 µs** | 4,006 K, 359 µs | 4,801 K, 376 µs | 27 M, 1,940 µs |

ls-hpack allocates 139–2,933 times per row, NIOHPACK 1,102–2,416 per decoding row. HTTPBytes allocates nothing.

- **Huffman decoding** uses a prototype winner: a 14-bit table where each entry decodes one or two symbols. Input past
  the end reads as ones, which is EOS's prefix, so the last symbols need no separate path. NUL, CR, and LF are flagged in
  bit 24 of each entry and ORed per lookup (cursed-http's idea), so decoded values need no second scan for forbidden
  bytes. The Huffman loop is two thirds of decoding.
- **Huffman encoding** merges 8 codes per flush and stops at the raw length (Huffman isn't used when it wouldn't be
  shorter).
- **The dynamic table** keeps entries contiguous in a byte store twice the table's size. An entry that would straddle the
  end goes to the start, so every entry is one span. Entries are numbered by insertion, so nothing is renumbered when
  one is evicted. The encoder finds entries through two hash chains (name and value; name alone) linked by insertion
  number, so an eviction costs nothing: a chain ends at the first number older than the oldest entry.
- **Validation is cached.** Characters are checked once per literal and the verdict is stored with the dynamic entry, so
  validation adds 8% to decoding, down from 43%.
- **Static entries live in the coder's own memory, by address.** Reaching the generated tables and
  `HTTPFieldName.lowercaseBytes` from another module had been a call per field. This cut decoding 12% and encoding 18% in
  instructions.
- **The indexing policy is nghttp2's.** `:path`, `content-length`, and date-like fields stay out of the table; short
  cookies and credentials are never indexed. Requests come out 15% smaller than ls-hpack's and NIOHPACK's, which index
  everything.

## QPACK

| Row (instructions, time) | HTTPBytes | cursed-http | ls-qpack |
|---|---|---|---|
| decode 401 requests, static only | **2,341 K, 249 µs** | 3,402 K, 396 µs | 3,693 K, 372 µs |
| decode 401 requests, 4,096-byte table | **1,221 K, 120 µs** | 1,624 K, 171 µs | 2,163 K, 235 µs |
| decode nghttp3's encoding of qifs fb-resp-hq | **2,464 K, 269 µs** | 3,537 K, 408 µs | 4,600 K, 490 µs |
| encode 401 requests, 4,096-byte table | **2,089 K, 107 µs** | 2,939 K, 238 µs | 9,273 K, 751 µs |
| encode 383 responses, 4,096-byte table | **2,593 K, 142 µs** | 3,910 K, 346 µs | 14 M, 1,180 µs |

- **One table design for both compressors.** HPACK's dynamic table, static entries, hash chains, and validator moved to
  the core and serve QPACK too. QPACK's absolute index is the insertion number. HPACK measured within ±0.4% after the
  move on every row but one.
- **Blocked streams are held by the caller, not copied.** `begin(_:stream:)` returns `false` for a section whose
  Required Insert Count hasn't arrived and records the stream (two words each, up to the blocked-streams setting).
  `nextUnblockedStream()` names it once the encoder stream catches up. RFC 9204 forbids releasing that stream's flow
  control, so its bytes are already in the caller's receive buffer, and a pool would be a second copy.
- **Insert on the second sighting.** In HPACK an insertion is free; in QPACK the value goes on the encoder stream as
  well. Inserting one-off response values evicted entries that would have been used. Inserting a field the second time
  it's seen (ls-qpack's idea, a direct-mapped history of field hashes) cut responses 16%, at +4% on requests.
- **Strict and reliable.** A Required Insert Count larger than the section needs is an error. Acknowledgments go into a
  buffer made with the decoder and can't be dropped: a dropped one would freeze the peer's table. That was a review
  finding; the decoder now reports `decoderStreamFull` before changing anything.
- **The worst bug found by a gate.** A `var` pointer assigned in branches and borrowed by a span was heap-boxed: one
  allocation per literal field. QPACK's malloc gate failed, and as `let`s set once on each path the box went away.
  Static decoding went from 5.2 M to 2.5 M instructions. AGENTS.md has the lesson from NativeAEA; it was met again here.

## Structured Fields and Priority

RFC 9651's parser is a set of iterators over the field's bytes. Lists, dictionaries, inner lists, and parameters
are walked, never built. Items come out as views: strings and byte sequences as spans with an unescaping or Base64
decoding step on request, integers and decimals as values. Every case in the httpwg structured-field-tests passes: 1,607
parse cases and 553 serialization cases. Parsing 1,000 seven-member dictionaries takes 196 µs against 22 ms for
swift-http-structured-headers, which builds a Swift value tree. `HTTPPriority` (RFC 9218) reads `u=` and `i` in 23 ns a
field.

## Content codings

`HTTPContentDecoder` undoes `Content-Encoding` in reverse order: gzip, deflate (zlib or raw, decided from the first two
bytes as browsers do), br, and zstd. All use BytesCompression's decoders, with no zlib or Compression framework.

- **Input in any pieces, each passed once.** A chunked body's pieces aren't contiguous: size lines sit between them. When
  a codec stops short at a piece's end, the remainder goes to a carry buffer, and the next piece continues from it. The
  common case, a piece decoded to its end, copies nothing. A 1 MB gzip body arriving as 4 KB chunks decodes in 530 µs
  against 526 µs whole, so the framing adds 0.8%. System zlib decodes it whole in 627 µs.
- **Two codings stack** through a 64 KiB middle buffer made once. `finish()` checks every stage, because the outer
  stream can be cut short after the inner one happened to end.
- **Limits.**
  - `maximumDecodedByteCount` guards against decompression bombs.
  - RFC 9659's 8 MB zstd window limit is reported as `tooLarge`, not as "out of room". A caller draining its output
    would otherwise loop forever.
- **Reset per body.** A connection keeps one decoder and calls `reset(contentEncoding:)` for each body, which keeps each
  coding's codec state and the buffers. After the first body of each coding, decoding allocates nothing.

## Correctness

### Other implementations' test suites, run as differential tests

Each suite's cases are generated into `TestData` by a checked-in script. They run through HTTPBytes' parsers and
framing, and the outcome is compared with the suite's verdict:

| Source | What it brought |
|---|---|
| llhttp's markdown suite (258 cases) | Smuggling and framing edge cases. Found: raw UTF-8 targets, empty Transfer-Encoding, CR LF before a status line |
| Go's net/http, h11, httparse (305), http-parser (101), picohttpparser (94) | Each parser's own request and response tables |
| cursed-http's extractor (300) | Its conformance cases |
| HTTP Garden, PortSwigger's DesyncBox permutations | Request smuggling: framing ambiguities across front ends and back ends |
| h2o's fuzz corpus (1,972 inputs, bulk) | Verdicts compared with llhttp's |

A `differences` table per suite lists each deliberate disagreement with its reason:

- extension methods are tokens (llhttp knows a fixed list);
- RTSP and HTTP/0.9 aren't HTTP/1.1;
- a transfer coding other than `chunked` gets 501;
- obsolete line folding is rejected (RFC 9112 §5.2).

An entry that stops differing fails the test, as does a `withKnownIssue` that stops recording, so the tables stay exact.
The suites found 11 real gaps, all fixed:

- raw UTF-8 targets;
- an empty Transfer-Encoding;
- the chunk-extension grammar and its limits;
- CONNECT with a body;
- persistence with both Content-Length and Transfer-Encoding;
- `100-continue` in HTTP/1.0;
- HTTP/1.2 as 1.1;
- and others.

Five known issues remain, all invalid request targets that only the off-by-default validator rejects.

Beside them are the RFC examples:

- RFC 7541 Appendix C (HPACK);
- RFC 9204 Appendix B, with the encoder stream split at every byte;
- RFC 9651's suite;
- qifs' 528 QPACK interop encodings by six implementations (f5, ls-qpack, nghttp3, proxygen, qthingey, quinn);
- hpack-test-case's stories.

There are also truncation at every byte, mutation at every byte (bulk), and round trips through both coders of every
corpus.

### Adversarial reviews

The plan said to review after each phase with a separate agent given the code, not the conclusions. Two reviews found
15 confirmed defects. Each became a probe package that reproduced it, then a regression test:

- **CR LF injection:** an HTTP/2 field converted to HTTP/1 through an unchecked store append.
- **Smuggling:** `Content-Length: ,` slipped past the CL+TE check; CONNECT with Content-Length was accepted.
- **Unbounded input:** trailers and leading empty lines had no limits; CONTINUATION frames had no count limit.
- **QPACK:** a dropped Section Acknowledgment would have frozen the peer's table; a DATA frame header was misread.
- **Quadratic re-scans** when input arrives a byte at a time, in four places:
  - HTTP/1 partial lines;
  - chunk trailers;
  - QPACK encoder-stream literals;
  - the stacked content decoder's stalled middle buffer, which looped forever.

Every incremental parser now has a test fed a byte at a time with a time limit.

## How it was measured

- **Instructions and cycles, not just time.** Parsers are branch-bound, and other agents were often building, so changes
  were judged by `proc_pid_rusage`'s instruction and cycle counters in small harnesses (best of several runs, every
  head checked first), then confirmed in the benchmark package.
- **Every benchmark checks every item.** The first HTTP/1 baseline read 3.4x picohttpparser because a head limit
  wrongly failed most heads at once, and the row summed results. Every setup now checks that every item succeeded.
- **References built the same way.** picohttpparser, llhttp, cursed-http, ls-hpack, and ls-qpack come from pinned
  sources in `TestData`, compiled with -O3 and NDEBUG through unity-build wrappers. NIOHPACK, swift-http-types, and
  swift-http-structured-headers are the Swift references.
- **Old against new.** For the HTTP/1 optimization, the previous parser was compiled as a second module and both were
  compared on 1.6 million inputs: corpus heads and their mutations, whole and in pieces, under four option sets. It
  caught a scan that skipped a block on its first run.
- **Codegen checked.** `Tools/calls` shows no allocation, retain/release, `swift_once`, metadata, or error boxing in the
  request parser's functions; `Tools/loops` shows its name scan as a `vector128` loop.

## What Bytes gained

- **`ByteBlock`:** 64 bytes tested into one 64-bit mask, byte i in bit i, built from four `ByteMatches`. On NEON
  (`bytes_movemask64`) it's 8 vector instructions and a move, taking full comparison lanes; elsewhere four bitmasks.
  `RawSpan.byteBlock(at:)` and `byteBlock(at:padding:)` load a block, copying a partial last block inline. Any
  simdjson-style structural index can use it.
- **`Tools/test-data`** learned `*.unpack.tar.gz` sets and gained 21 HTTP sets:
  - 13 downloaded at pinned revisions: the C references, the suites' sources, the RFC and interop vectors;
  - 8 generated by checked-in scripts: the case tables, http-corpus from qifs, cursed-http's top-1k as heads, h2o's
    corpus with llhttp's verdicts.
- **`Tools/cpu-probe insn`** gained `ld4` and four-register `ld1` rows, which settled the mask-packing choice.

## Lessons worth keeping

1. **Prototype the scanning strategy before the API.** An hour of throwaway parsers on the real corpus decided the
   design, and the measure that decided it was cycles, not instructions.
2. **A loop of forced-inline code can outgrow the inliner's caller limit,** and then trivial getters become calls inside
   it. After forcing inlining, grep the hot function's disassembly for `bl`.
3. **Fewer instructions on the critical path can be slower.** `ld4` packing, batched masks, and per-line scans each ran
   fewer instructions and lost.
4. **A benchmark that sums results measures failures.** Check every item in setup.
5. **A heap box hides in a `var` pointer assigned in branches** whenever a span borrows it. The zero-malloc gates find
   it, and `let`s set once per path fix it.
6. **Import other implementations' test suites with an exact table of differences.** They found what our own tests
   didn't, and the table keeps the differences deliberate.
7. **An adversarial reviewer given the code, not the conclusions,** finds the security bugs: injection, smuggling,
   unbounded input, quadratic re-scans.
8. **Strictness has a price in real traffic.** RFC 3986 target validation rejected 13% of real browser requests, so it's
   an option.

## Open items

- **HTTP/1 responses:** 13–16% more cycles than cursed-http, from mispredicts on long lines. Its "any control in the next 256
  bytes?" skip windows are the next thing to try.
- **Tiny heads given only their own bytes:** 10–55% behind cursed-http, whose contract lets it read 64 bytes past the
  input. HTTPBytes copies the partial block instead.
- **QPACK compression:** ls-qpack compresses responses 15% better, using Duplicate instructions and a draining index.
- **zstd:** decoding only; BytesCompression has no zstd encoder.
- **Not built from the plan:**
  - the connection layer (HTTP/2 stream states and flow control, HTTP/3 stream rules, as state machines over the codecs);
  - `HTTPDate`;
  - typed parsers for `Range`, `Content-Type`, entity tags, and `Vary`;
  - `ByteTransform` adapters for bodies;
  - multipart and forms (deferred in the plan).
