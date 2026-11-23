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
