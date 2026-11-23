# HTTPBytes: plan

HTTP message framing and payload coding on Bytes, for HTTP/1.1, HTTP/2, and HTTP/3: parsing and serializing, with
**no allocations on the steady-state path and vectorized scanning wherever bytes are scanned**. Draft 2, 2026-11-23,
revised after an adversarial review (its points are folded in below; the main changes: prototypes before scaffolding,
HPACK before QPACK, C references instead of NIO's pipeline, per-protocol errors, no ring-straddling table entries, a
chunked cursor that hands out input slices, a wider RFC checklist, multipart/forms deferred).

## Goals and standards

- **Scope: a codec, with the validation a conforming implementation needs at the message and frame level.** No
  transports (sockets, TLS, QUIC). HTTP/2 and HTTP/3 connection state (stream state machines, flow-control windows) is a
  separate, later layer (phase 7), stated as such: phases 2–6 give frame, field-section, and message conformance.
- **Performance (the repository's rules):** a malloc threshold of 0 for every per-message benchmark after setup; hot
  scanning loops `vector128` under `Tools/loops`; no retain/release, metadata, `swift_once`, or `swift_allocError` in hot
  paths (`Tools/calls`); rows report instructions, cycles, and branch mispredicts (`Tools/counters`), since parsers are
  branch-bound; changes made while agents run are judged by instructions and cycles, final timings interleaved on an
  idle machine.
- **Swift:** tools-version 6.4, `.swiftLanguageMode(.v6)` stated, the upcoming features Bytes uses (`ExistentialAny`,
  `MemberImportVisibility`, `InternalImportsByDefault`, `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`),
  `Lifetimes`, strict memory safety in library targets, typed throws everywhere (`do throws(E)`), `~Escapable` views over
  borrowed bytes, `@inlinable` public API with `@inline(__always)` on per-field calls, every `unsafe` with its reason.
- **API:** swift-http-types' vocabulary for concepts (method, status, field name, pseudo-header fields, the
  never-index strategy), but **distinct type names** where the shape differs, so code importing both modules needs no
  qualification (the CryptoKit lesson): `HTTPMethod`, `HTTPStatus`, `HTTPFieldName`, views named `…View`, the owned field
  store not called `HTTPFields`. HTTP/1 names keep their case (raw and canonical forms, as swift-http-types does).
  Conversions to and from swift-http-types in a separate product.

## Phase 0.5: prototypes that decide the design (throwaway code in the scratchpad)

1. **Head scanning**, on a corpus of real heads (tiny ~40-byte heads through 2 KB, line lengths 1–40 one by one):
   (a) per-line `firstByteOffset` scans; (b) a structural index: one pass over 64-byte blocks building bitmasks of CR,
   LF, `:`, and invalid bytes (simdjson-style), then a scalar walk with `ctz`, names checked by masking the invalid-name
   bits over the name's range; (c) a scalar table-driven state machine (llhttp/picohttpparser style). Measured by
   instructions, cycles, and mispredicts against picohttpparser in C.
2. **HPACK Huffman decoding**: nghttp2's 4-bit FSM, ls-hpack's 16-bit multi-symbol decoder, and a 10–12-bit
   multi-symbol table with a second level; against ls-hpack in C. Encoding: lengths summed first (scalar gather vs a
   `tbl4`-based lookup) vs encode-to-scratch then choose.
   **Result (2026-11-23, M1 Max, 401 real request heads, 580 B average, `proc_pid_rusage` counters):** the structural
   index wins: B 112–117 ns/head, 0.62 cycles/B, 3.2 instructions/B; per-line scans (A) 168 ns, 0.93 cycles/B (fewer
   instructions, 2.6/B, more cycles: the short-span paths mispredict); picohttpparser 225 ns, 1.23 cycles/B, 7.8
   instructions/B; llhttp 220 ns, 1.20 cycles/B. The index needs a 64-byte movemask (NEON `addp` tree: not expressible
   in Swift SIMD); with nibble masks per 16 bytes in Swift alone it fell to 0.87 cycles/B, and Swift classification with
   the C movemask to 0.75 (to investigate: the C classification is unrolled and inlined, the Swift one wasn't). So:
   Bytes gets a 64-byte block mask API backed by CBytesNEON (portable fallback), and the head parser is a walk over
   lazily built masks.
   **Streaming (the user's request, secondary to speed):** the walk produces the method, target, and each field in
   order, so the parser's API is an incremental one: `next()` yields the start line, then fields one by one, and resumes
   at a line boundary when more bytes arrive; a server can act on the method, path, or a field before the head is
   complete. The whole-head parse is a loop over it, and must measure the same.
3. **The lifetime API in Swift 6.4**: a `mutating next() -> FieldView?` on a decoder whose view borrows the decoder;
   a view over input bytes returned from a parser; whether these compose with `for`-style use and with typed throws.
   (AGENTS.md's limits: spans through two closures, borrowing one property while mutating another, `#expect` and
   `~Escapable`, spans of `let`s bound in a `switch`.)
   **Result:** both compile under Swift 6.4 and optimize cleanly. A `~Escapable` event enum with `RawSpan` payloads,
   returned by `@_lifetime(copy bytes) mutating func next(in bytes:) throws(E)`, matched with `switch`/`case let`: the
   loop inlined completely, no calls, boxes, or retains. A `~Copyable` decoder's `@_lifetime(&self) mutating func next()
   -> Field?` (a `~Escapable` struct of two spans over its scratch) used as `while let field = decoder.next()`: no calls
   beyond the prototype's own array. The parser's state is offsets only: the structural walk moves forward, so it needs
   the masks of one 64-byte block at a time, not an index of the head (no scratch memory per parser).

## Package layout

`HTTPBytes/` (depends on `../Bytes`; no NIO or C dependencies). Benchmarks are a **separate package**,
`HTTPBytes/Benchmarks/` (depends on `..`, swift-http-types, swift-nio(-http2), and C references), so the library and its
tests build without them.

| Target | Contents |
|---|---|
| `HTTPBytes` | `HTTPMethod`, `HTTPStatus`, `HTTPVersion`; `HTTPFieldName` (validated; well-known names as a small index, compared by index; raw and lowercase forms); `HTTPFieldStore` (owned: one byte store, one entry store, reused with `removeAll(keepingCapacity:)`; per-field never-index flag); request targets (four forms tied to methods; RFC 3986 split and validation; percent-decoding); `HTTPDate` (IMF-fixdate, RFC 850 with two-digit-year rule, asctime; a cached `Date` value formatted once a second); field-value grammar (tokens, quoted strings, parameters, comma lists with OWS, `q` values); field parsers for `Content-Length`, `Transfer-Encoding`, `Content-Encoding`, `Content-Type`, `Connection`, `Host`, `Expect`, `Upgrade`, `Range`/`Content-Range`, entity tags, `Vary`; Structured Field Values (RFC 9651) and `Priority` (RFC 9218); the HPACK/QPACK Huffman code and prefix integers |
| `HTTP1` | Request and response head parsers (incremental; strict by default, leniency options: empty lines before the request line, bare LF); head serializers; body framing per RFC 9112 §6.3 (the response parser takes the request's method: HEAD, 1xx/204/304, 2xx to CONNECT; TE not ending in chunked: 400 for requests, read-until-close for responses; TE in HTTP/1.0 faulty; CL+TE, duplicate CL); a chunked **cursor** returning `.data(RawSpan)` slices of the input, `.needsMore`, `.end` (trailers), with limits on chunk extensions and line lengths; a chunked encoder; `ByteTransform` adapters; exactly one `Host`, absolute-form overrides it; `Connection` field removal, persistence (§9.3), `Expect: 100-continue`, `Upgrade`; limits mapping to 414 and 431 |
| `HTTP2` | Frame header (`@BinaryRecord`: `Byte3` length, type, flags, `@BitFields` stream id with its reserved bit); every frame type incl. PRIORITY_UPDATE (0x10) and unknown types (ignored); settings with range checks (ENABLE_PUSH 0/1, INITIAL_WINDOW_SIZE ≤ 2³¹−1, MAX_FRAME_SIZE 16,384…2²⁴−1, ENABLE_CONNECT_PROTOCOL, NO_RFC7540_PRIORITIES; unknown ignored); header blocks across CONTINUATION (nothing may interleave); HPACK decoder and encoder (dynamic table with contiguous entries, size updates only first in a block and within the setting, never-indexed literals preserved, header-list size counting name+value+32); field-section rules (§8.2: lowercase names, no connection-specific fields, `te: trailers` only; §8.3 pseudo-headers incl. CONNECT and extended CONNECT's `:protocol`); cookie crumbs (§8.2.3) |
| `HTTP3` | QUIC varints; frames (DATA, HEADERS, CANCEL_PUSH, SETTINGS, PUSH_PROMISE, GOAWAY, MAX_PUSH_ID, PRIORITY_UPDATE 0xF0700/0xF0701; reserved types skipped; HTTP/2's 0x2/0x6/0x8/0x9 are H3_FRAME_UNEXPECTED); settings (duplicates and HTTP/2's ids 0x2–0x5 are errors); per-stream-type frame rules; QPACK decoder and encoder (Required Insert Count modulo 2·MaxEntries, post-base indexing, the N bit, encoder and decoder instruction streams, blocked streams buffered in a pool bounded by `SETTINGS_QPACK_BLOCKED_STREAMS` × section size) |
| `HTTPPayload` | Content codings over BytesCompression through an enum of concrete decoders and encoders (as `Decompressor`): `gzip`, `deflate`, `br`, `zstd` (decode; RFC 9659's 8 MB window limit), stacking depth 2, output limits against decompression bombs; fed straight from the chunked cursor's slices |
| `HTTPBytesHTTPTypes` | Conversions to and from swift-http-types (`HTTPRequest`, `HTTPResponse`, `HTTPFields`, indexing strategy) |
| Tests | One test target per library target; `.bulk` for sweeps |

**Errors**, per protocol and payload-free (no `String`s; nothing boxed): `HTTP1Error` (each case knows its status:
400, 414, 431, 501, 505), `HTTP2Error` (connection or stream, with the RFC 9113 error code), `HPACKError`,
`HTTP3Error` (H3_* codes), `QPACKError` (QPACK_* codes), `HTTPFieldError` (field grammar).

**Allocation model.** Parsing input produces borrowed views (`~Escapable`, the input's lifetime): nothing allocated.
Decoded HPACK/QPACK fields can't all be views of the input (Huffman-decoded strings, dynamic-table entries), so a
decoder yields fields through `mutating next()`, each view borrowing the decoder until the next call; Huffman output goes
to decoder-owned scratch sized from the header-list limit; dynamic-table entries are stored contiguously (an entry that
would straddle the end wraps to the start, leaving a gap), so every entry is one span. Owned stores (`HTTPFieldStore`,
the tables, scratch, the blocked-stream pool) are allocated once per connection and reused.

## Performance techniques, per component

- **Head scanning:** decided by prototype 1. Validation by the cheapest test per class: field values need only CTL/DEL
  tests (splatted comparisons, no `tbl`); a well-known name matched against its table needs no character validation;
  nibble-class lookups (two one-register `tbl`s) only for unknown names, tokens, and targets (count the classes:
  tchar's low-nibble sets may need two table pairs).
- **Field names:** well-known names by length and first/last bytes into a small perfect table, then one comparison of
  the case-folded bytes (vector `or 0x20` of letters); names from HPACK/QPACK static tables arrive as indices: no
  hashing.
- **Numbers:** status codes and `Content-Length` with `read(_:asciiDigits:)` (SWAR); chunk sizes with a new SWAR hex
  number read in Bytes.
- **Huffman:** decided by prototype 2; tables generated by a script as literal arrays (statically initialized: no
  `swift_once`; checked with `nm` and `Tools/calls --callee swift_once`).
- **Integers:** HPACK prefix integers branch-light; QUIC varints with one big-endian 8-byte load masked by the length
  class when the span has room.
- **Frames:** `@BinaryRecord` headers, one bounds check; payloads parsed per type with one dispatch (MQTT's pattern).
- **Chunked:** chunk data never copied (cursor slices); the size line found with `matching`, parsed by the SWAR hex read.
- **Content codings:** BytesCompression's streaming decoders read the cursor's slices directly.

## Additions expected in Bytes (prototyped in HTTPBytes, moved with measurements)

- A most-significant-bit-first `BitWriter` (a bit order, as `BitBuffer` has) for Huffman encoding.
- SWAR hexadecimal number reads (`read(_:asciiHexDigitsUpTo:)` or similar).
- `ByteLanes` nibble-class lookups (`ByteClassTable`), ASCII case folding of 16 bytes, case-insensitive equality.
- Possibly a structural-index helper (64-byte block bitmasks) if prototype 1 picks it and it generalizes.

## Test data and correctness

- Sets in `Tools/test-data` (done: `hpack-test-case`, `qifs`, `structured-field-tests`; to add: llhttp's markdown test
  suite, the C references below).
- **One message corpus across versions:** qifs' QIF files (real HTTP/3 traffic: requests and responses from several
  sites) turned into HTTP/1 heads, HPACK blocks, and QPACK sections by a generator, so rows compare across versions;
  plus tiny heads (~40 bytes) and large ones (long cookies).
- RFC examples as unit tests: RFC 7541 Appendix C, RFC 9204 Appendix B, RFC 9112 examples, RFC 9651's suite.
- Incremental parsers fed split at every byte; truncation at every byte ("truncated input looks like data"); inputs
  ending exactly where a field ends, for every wide-load path; malformed and smuggling tables (llhttp's suite);
  differential tests against llhttp, picohttpparser, ls-hpack, and NIOHPACK on mutated corpora; RFC 7541 §5.2 Huffman
  errors (padding over 7 bits, padding not all ones, EOS in a string).

## Benchmarks (`HTTPBytes/Benchmarks`, its own package)

- **References:** picohttpparser and llhttp in C (the speed bars; built with `NDEBUG` and -O3 through unity-build
  wrapper files including the test-data sources), ls-hpack and ls-qpack in C, NIOHPACK and swift-http-types in Swift
  (NIOHTTP1 only as the "what a Swift server does today" row, labeled as such).
- **Rows:** per head size and per line length; per field and per byte; instructions, cycles, mispredicts, time, mallocs
  (malloc rows separate, AGENTS.md); HPACK and QPACK over the same message corpus; Huffman alone by length; chunked and
  content-coded bodies; field lookup and building against swift-http-types; allocation thresholds at 0.

## Phases

Status (2026-11-23): phases 0–6 and 8 done (RESULTS.md, WRITEUP.md, the online report); 9 in progress; phase 7 not
started. From phase 2's list, not built: `HTTPDate`; the `Range`, `Content-Type`, entity-tag, and `Vary` parsers;
`ByteTransform` adapters. Of the Bytes additions planned below, only `ByteBlock` (the structural index's masks) was
made; HTTPBytes' Huffman coder and chunk-size reader are its own.

0. Plan and review (done). **0.5** Prototypes 1–3.
1. **Scaffold** both packages, settings, C reference targets, the corpus generator, a first benchmark row.
2. **Core types** (`HTTPBytes`), with Bytes additions as needed; review.
3. **HTTP/1** (me) and **HPACK + HTTP/2** (an agent, its own target and scratch directory, core read-only, new core API
   proposed not added) in parallel; reviews.
4. **QPACK + HTTP/3**, on HPACK's Huffman, integers, and table design; review.
5. **Payload** (content codings, chunked integration, limits); **Structured Fields**; review.
6. **Optimization pass** over everything: interleaved A/B on an idle machine, `RESULTS.md` tables, AGENTS.md lessons,
   Bytes additions moved with before/after numbers, baselines slimmed.
7. **Connection layer (if time):** HTTP/2 stream states and flow-control accounting, HTTP/3 stream rules, as pure state
   machines over the codecs.
8. **Write-up:** `HTTPBytes/WRITEUP.md` and an online report.
9. **Optimization report:** Sonnet agents update `Bytes/OPTIMIZATION.md` and its online version (Fast Swift for Binary
   Data, claude.ai/artifact/HZtxE3JpWQnTm7gVkhjiJq): this session's earlier work, the HTTP use case, new Bytes APIs.

Adversarial review after each of phases 2–5 (a separate agent given the code, not my conclusions); findings verified by
measurement before acting; highest performance wins conflicts with taste.

## Deferred

`multipart/form-data` (RFC 7578) and form encoding (WHATWG: application-level); HTTP Datagrams and capsules (RFC 9297);
h2c upgrade; ORIGIN and ALTSVC frames; Cache-Control (RFC 9111). Any of these can follow on the same primitives.

## Round 2 (2026-11-23, draft 1): the open items, then dates and field parsers

The user's scope: WRITEUP.md's open items except HTTP/2 and HTTP/3 stream states and flow control (phase 7 stays
deferred, with HTTP/3's stream rules), HTTP-level work first; then `HTTPDate` and the field parsers; multipart and forms
stay deferred. Same standards as round 1 (0 mallocs per message after setup, `vector128` scans, cycles and mispredicts
judged, not just instructions, every change measured before and after; adversarial review agents given the code).
Baselines named `r2-*`, slimmed.

### HTTP level

1. **HTTP/1 responses: skip windows** (cursed-http's `fb_ctany_simd`, fbparse.h). In `farStop` (lines crossing blocks,
   already out of line), after N exact blocks (cursed-http: 2), test 256- then 512-byte windows for "maybe a control":
   `(Int8)(x + 1) < 0x21` holds for controls, HT, DEL, and bytes ≥ 0x80 (false positives send the window to exact
   masks), as add and signed min per vector, two accumulators, one `sminv`. Swift's `pointwiseMin` is a call on 6.4: a
   CBytesNEON `static inline` helper (with a portable fallback), proposed to Bytes as a `ByteBlock`/`RawSpan` API once
   it wins. Sweep N, window sizes, and prefetch distance. **Target:** resp and tresp cycles −10% or more; req, tiny, f1,
   f16 within 1%; differential against round 1's parser (the second-module harness) on the 1.6 M inputs.
2. **Tiny heads given only their bytes** (73 cycles against 52 when the next bytes are readable): (a) a padded-input
   entry point on both head parsers, `next(in: RawSpan, byteCount: Int)`: the span may extend past the message (a
   receive buffer's capacity), the parser may load whole blocks from it and treats bytes past `byteCount` as absent;
   `next(in:)` is the case `byteCount == bytes.byteCount`. (b) Bytes: a way for a receive buffer to offer that span
   (`ByteBuffer` storage zeroed once at `init`, so its capacity is always initialized, and an accessor for the unread
   bytes plus what follows). (c) The copy-free path for a partial block when there aren't 64 bytes: overlapping
   loads and a one-register `tbl` shift instead of the 16/8/4-byte copy. **Target:** alone ≤ 55 cycles with (a);
   (c) kept only if it gains without the API.
3. **QPACK compression** (an agent, `HTTP3` only, in a worktree): Duplicate instructions for referenced entries near
   the draining end and a draining index (entries past it aren't referenced, so they can be evicted), as ls-qpack does.
   **Target:** response sections within 5% of ls-qpack's size (now 15% larger); encode cycles +10% at most; 0 mallocs;
   interop with ls-qpack's and our decoder, blocked streams included.
4. **zstd encoding** (an agent, `BytesCompression`, in a worktree): a Zstandard frame encoder with libzstd's fast and
   double-fast strategies (its levels 1–4), lazy if time allows; raw/RLE/compressed literals with Huffman (the
   `HuffmanCodeBuilder`), FSE sequence tables (predefined, RLE, or built, from LZFSE's FSE encoder where it fits),
   optional checksum (XXH64), whole-buffer and streaming (`ByteTransform`); every output decoded by libzstd (CZstd) and
   our decoder. **Target:** ratio within 2% of libzstd at the same level; cycles at or under libzstd's at levels 1 and
   3; 0 mallocs after setup. Then `HTTPContentEncoder` gets `zstd` (RFC 9659: window ≤ 8 MB).
5. **`ByteTransform` adapters for bodies:** a dechunking stage (`HTTP1ChunkedDecoder` copying its slices, trailers
   checked and skipped), a chunking stage (data → chunks, the last chunk on `.finish`), `HTTPContentDecoder` and
   `HTTPContentEncoder` as stages; a chunked-gzip pipeline against the hand-driven loop: instructions within 3%,
   0 mallocs.

### Dates and field parsers (core `HTTPBytes`)

6. **`HTTPDate`** (RFC 9110 §5.6.7): parse IMF-fixdate (fixed 29 bytes: 8-byte loads, SWAR digit checks, the month by a
   3-letter word hash, weekday checked), RFC 850 (two-digit years against a reference year), and asctime; seconds since
   1970 (`Int64`) and components; days from civil date and back without branches (Hinnant's algorithms); IMF-fixdate
   written into a writer; a server's date cache (29 bytes reformatted when the second changes). **References:**
   Foundation's `Date.HTTPFormatStyle` (parse and format), and `strptime`+`timegm` in C. **Target:** parse and format
   ≤ 10 ns, 0 mallocs.
7. **Field-value parsers**, views and iterators over the value (no allocations), validated as they go, typed throws:
   - shared grammar: tokens, quoted strings (view, escapes decoded on demand into a caller's span), parameters, `q`
     weights in thousandths, comma lists as an iterator (quoted commas respected, as `HTTPList` does now);
   - `Content-Type` (media type, parameters, `charset`; compare with a known type ignoring case); `Accept`,
     `Accept-Encoding`, `Accept-Language`, `Accept-Charset` (ranges and weights; choosing among offered codings);
   - `Range` (`bytes=` sets: first-last, first-, suffix; resolved against a length, with limits on count and overlap),
     `Content-Range` (parse and write), `If-Range`, `Accept-Ranges`;
   - entity tags (`ETag`, `If-Match`, `If-None-Match`, `*`; strong and weak comparison);
   - `Vary` (`*` or field names, as `HTTPFieldName`s), `Connection`, `Upgrade`, `Expect`, `Host` (reg-name, IPv4,
     IPv6 literal, port);
   - `Cache-Control` (RFC 9111 §5.2: directives with arguments, known directives by a small hash), `Age`, `Expires`;
   - request targets: split into components by form (path, query, authority, scheme), path segments, percent-decoding
     into a caller's span (the `%` found by vector scans), query items as raw views (no `+` decoding: that's forms).

   **Tests:** RFC examples, and other implementations' suites as differential tables (Go's net/http `parseRange` and
   conditional tests, jshttp's `content-type`, `range-parser`, `negotiator`, `fresh`; Rust's `httpdate`; Python's
   `email.utils` date cases; curl's date tests), with a table of deliberate differences. **Benchmarks:** values taken from
   the corpora (http-corpus, top-1k) per parser, ns and cycles per value; 0-malloc gates.

### Order and reviews

Agents start 3 and 4 in worktrees (TestData symlinked in) at once; I do 1, 2, 5, then an adversarial review of the
HTTP-level code; then 6 and 7, and a second review; the zstd encoder's integration when its agent finishes. Records:
RESULTS.md per item, AGENTS.md lessons, WRITEUP.md (new sections, open items), the online report updated.

Status (2026-11-23, end of round 2): every item done or measured and closed. 1 and 2 measured, not kept (below); 3
QPACK at ls-qpack's size (responses 1.001); 4 the zstd encoder (libzstd's frames byte for byte at levels 1–4) and
`HTTPContentEncoder(.zstd)`; 5 the chunked stages and `HTTPBodyDecoder`; 6 `HTTPDate`; 7 the field parsers. Each part
reviewed adversarially (plan, body stages, parsers) and every confirmed defect fixed. Records: RESULTS.md ("round 2"),
WRITEUP.md ("Round 2"), Bytes/Benchmarks/RESULTS-zstd-encoder.md.

### Draft 2: the review's changes, and items 1–2 measured

- **1 and 2 measured, neither kept** (RESULTS.md, round 2): skip windows cost responses 1–3% at every setting (our exact
  masks are cheap; cursed-http's response parser doesn't use windows either, it batches masks, which round 1 measured
  at +25% on requests in our design); clamped short blocks left tiny heads alone where they were (the copy isn't their
  cost) and grew the parse loop. The padded-input API isn't built: at most ~8 cycles on heads under 64 bytes.
- **3 and 4:** delayed-acknowledgment rows and eviction-safety tests for QPACK; for zstd, the format traps in the
  agent's brief, libzstd run with explicit parameters, small bodies, memory per encoder, and a 15% cycle target (parity
  a stretch).
- **5:** the dechunking stage finishes at the last chunk and leaves the trailer section unconsumed for the caller (no
  trailers thrown away); `maximumUnitByteCount` covers a size line with its extensions; the chunker writes nothing for
  a flush with no data (a 0-size chunk ends the body); also a dechunking wrapper that hands slices straight to an inner
  stage, measured against the pipeline.
- **6:** RFC 850's two-digit years against a reference date (injectable); HTTP-date is case-sensitive (a deliberate
  difference from Foundation's and Python's lenience); second 60 and a mismatched weekday decided and tested; asctime's
  space-padded day; the date cache takes the time as a parameter and is per thread (29 bytes can't be swapped
  atomically).
- **7:** list fields combined across lines (iterate a name's lines from `HTTPFieldStore`), duplicated singletons
  rejected; iterators as `while let x = try it.next()`; entity tags aren't quoted-strings; `q` grammar and `q=0`;
  `identity` acceptable unless refused; Range: an invalid field is ignored, all-unsatisfiable is 416 with `bytes
  */len`, `-0` unsatisfiable, last-pos clipped, overflow checked, a count cap and coalescing into caller storage;
  If-Range strong comparison only; IPv6 zone IDs rejected; Cache-Control's quoted arguments and 2³¹ clamp; Expires
  ignored under max-age. Added: RFC 9110 §13.2.2 conditional evaluation, Content-Disposition (RFC 6266, RFC 8187
  `filename*`), Retry-After, Forwarded (RFC 7239), Cookie parsing and Set-Cookie writing, Authorization and
  WWW-Authenticate (scheme, token68, auth-params). Cut: Accept-Charset. Suites: Go's `net/http` (range, `fs_test`
  ETag scanning and conditionals, header), `mime/mediatype_test.go`; jshttp's `content-type`, `range-parser`,
  `negotiator`, `fresh`; Rust's `httpdate` and `hyperium/headers`; mnot's `http-tests/cache-tests` (Cache-Control,
  Age, Expires parsing); WPT's MIME-type and URL data as tables of differences.
