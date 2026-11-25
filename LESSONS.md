# LESSONS.md

What investigations in this repository found, in the order they were learned (moved out of AGENTS.md on
2026-11-25; references elsewhere to "AGENTS.md" plus a date mean the section of that date here). Each section names
the RESULTS.md or writeup with the numbers. AGENTS.md keeps the rules these lead to; read the section for a topic
before working in it.

Where to look:

- Vectorization, SIMD, NEON, shuffles, tables: "Vectorization on ARM64", "API design and code generation",
  "Apple's formats, curves…", "A second machine", "Masked tables, word loads, and narrowing".
- Inlining, allocations, codegen traps, typed throws: "Allocations, concurrency, and codegen", "Compression and
  crypto", "The 2026-11-18 pass", "Every zip method in Swift", "Making decoders…".
- Compression codecs: "Compression and crypto", "Apple Encrypted Archives and the LZMA decoder", "Xcode's `.xip`…",
  "Every zip method in Swift", "Zstandard encoding", "One-shot reuse and gzip members", "The fix plan", "Small inputs
  and making coders".
- Concurrency and parallel work: "Allocations, concurrency, and codegen", "Threads to structured concurrency", "Bytes
  cleanup", "One codec layer", "The fix plan".
- File systems, extraction, Apple's archive tools, Archive Utility: "Apple Encrypted Archives…", "Xcode's `.xip`…",
  "The Disk package and the Nunarchiver app", "Matching Archive Utility", "The survey's bugs", "The archive-coverage
  set".
- HTTP parsing: "HTTP/1 heads against cursed-http", "HTTPBytes as a whole", "HTTPBytes round 2".
- The app (TCA26, SwiftUI, AppKit): "The Disk package and the Nunarchiver app", "Reviewing the Nunarchiver app".
- Tooling, Instruments, LLDB, the Edit tool's traps: "Every zip method in Swift", "The second cleanup pass", "The
  survey's bugs", "Masked tables…".
- Memory footprint, malloc's caching, `mmap`/`madvise`: "Giving memory back, and positions past 2^32".

## Vectorization on ARM64

Swift 6.4; details and numbers: `Bytes/Benchmarks/RESULTS-base64.md`, `Bytes/Benchmarks/RESULTS.md`.

- Loops from one typed span to another (`Span<InlineArray<3, UInt8>>` → `MutableSpan<InlineArray<4,
  UInt8>>`) auto-vectorize to `ld3`/`st4`; bounds checks on typed elements fold away. Offset loads from a
  `RawSpan` are each bounds-checked and don't.
- A table lookup in a loop is a gather: it blocks the vectorizer. Compute instead, with arithmetic masks
  (`(v &+ 128 &- k) &>> 7`), not `if`/ternary chains: LLVM threads correlated conditions into branches,
  then reports "loop control flow is not understood".
- `SIMD16<UInt8>` on 6.4: comparisons of two vectors (`a .== b`, `a .>= b`) are one instruction (`cmeq`,
  `cmhs`), but the overloads taking a scalar (`v .== 0`, `v .>= 0x80`) compile lane by lane; `any()`/`all()`
  are inlined (`umaxv`) in some loops and out-of-line calls elsewhere. Splat scalars
  (`SIMD16(repeating:)`), or use `ByteLanes`. All fixed in 6.5-dev. The dynamic subscript is per lane on
  both. NEON `tbl` isn't reachable from Swift: use a small C target (`CBytesNEON`) with `static inline`
  intrinsics.
- LLVM merges consecutive shuffles: two rounds of `zip`s written with Swift lane initializers became
  four-source shuffles lowered to 1 `zip` and 14 lane inserts per vector. `bytes_interleave4` in C keeps
  the rounds apart with an empty `asm("" : "+w"(v))` (a standalone C version without it didn't merge, in a
  later check). Shuffles chosen by a `Bool` parameter, and vectors built from an array literal then mutated
  per lane, also become inserts (16 for the literal).
- The Base64 `tbl` kernel ends up bound by `tbl` throughput (vector unit pressure), not instruction count:
  fewer instructions didn't mean faster. Measure variants.

## Allocations, concurrency, and codegen

Allocations: package-benchmark's malloc counter with a `Thresholds/` file at 0 is the gate (names without
spaces: thresholds for names with spaces break, ordo-one/package-benchmark#373). To find a source:
`Tools/calls … --callee 'swift_allocObject|swift_slowAlloc|malloc'` statically, `Tools/runtime-count
--break swift_allocObject` dynamically, `Tools/allocations` for responsible callers.

Concurrency: find actual hops with `Tools/tasks` (Instruments' `SwiftTaskStateTable`: thread and actor per
Running interval); count executor checks with `Tools/runtime-count --break
swift_task_switch@libswift_Concurrency.dylib` (and `--who …=x0`); check suspension points statically with
`Tools/calls --target PKG TARGET PATTERN --callee swift_task_switch`. In SocketStream, 55–113
`swift_task_switch` calls per transfer turned out to be zero hops for the socket tasks.
`nonisolated(nonsending)` keeps async functions on the caller's executor. System Call Trace (`syscall`
table) counts syscalls without the breakpoint perturbation.

Enums: big `switch`es over payload enums in hot code can get poorly optimized; the MQTT fix was per-type
`init(parsing:)`/`write(to:)` with a single dispatch (`MQTT/Sources/MQTT/Framing.swift`).

Old and new code in one benchmark run (variants of a function chosen by a constant `Bool`, so one run
compares them without drift): check that each variant really is specialized. LLVM's function merging can
fold the two copies back into one `merged …` function taking the constant as a parameter, and a closure
that captures the flag is specialized once, taking it at run time: both variants then test it in their
hot loop. Look for `merged` symbols (`nm --defined-only X.o | xcrun swift-demangle | grep merged`), and pass
the constant as a literal at the inlined call inside the closure (BinaryParsingComparison's LZ4). Likewise
don't measure a new path and its reference in one function behind a run-time flag: changing one path moved
the other's register allocation (an unchanged reference went 70 → 102 K instructions). Give each its own
`@inline(never)` function over a shared `@inline(__always)` body. And compare instruction counts across two
builds of a harness with care: identical code differed by a constant ~1.3 K per iteration between them.

Rare paths stay out of line even when they're the thing being optimized: Bytes' faster short-distance
back-reference, inlined, grew DEFLATE's decode loop 15% and cost 12–14% on text, where it never runs. As a
static function taking values (Bytes' slow-path pattern), it kept its gain (−38% on pixel runs) at no cost
elsewhere. Check the hot loop's size with `Tools/loops` before and after.

`@inlinable` doesn't mean inlined: a new `BytesWriter` initializer, only `@inlinable`, was called out of line
from NativeZip's decode function (789 → 891 instructions, the writer returned through memory). Anything a
hot function calls once per entry, initializers included, should be `@inline(__always)`; check with
`Tools/calls … --callee init` after adding API.

Constant vectors: `SIMD16<UInt8>` array literals (`[0, 16, 32, …]`) inside inlinable library code compiled
to calls to `SIMD.init(_:)` in the caller's loop (Base64's decoder: 3 calls per block, then 5 per call for
its table, ~1,200 instructions); in other functions the same literals folded. Write them as `Byte16`
literals (bytes in memory order, `0x00_10_20_…`) and take `.vector`: integer constants always fold. Check
new kernels with `Tools/calls … --callee 'SIMD.init'`.

LLVM narrows loads to the lanes a shuffle uses: the first round of `uzp1`s needs only the even bytes, so a
64-byte block feeding `ByteLanes.deinterleave` was loaded as 8-, 4-, 2-, and 1-byte lane loads (`ld1.b`,
`mov.h`, `ext`): 91 instructions per block against 45. An empty `asm` on the vectors before the shuffle
(`CBytesNEON.h`) keeps the loads whole.

Shifts bind tighter than multiplication in Swift: `count &* 3 &>> 2` is `count &* (3 &>> 2)`, which is 0.
Parenthesize (`(count &* 3) &>> 2`).

Portable byte shuffles: a `SIMD16<UInt8>` built from `v[k]` picks of one vector with constant `k` (or
constant zeros), `SIMD16(v[4], v[3], …, 0)`, compiles to one shuffle: a single-register `tbl` on ARM64,
`pshufb` on x86-64 macOS (SSE2-only x86-64 expands it into a longer sequence). Bytes' `GroupShuffle` packs
and unpacks 3- and 5–7-byte groups this way with no C; a one-register `tbl` is a quarter of a 64-byte
one's micro-ops, and for iterators it beat the NEON lookups by 22–44%, so every build uses it there. Two traps, both from LLVM merging what it can see:
building the vector from computed scalars and then shuffling became one byte insert per byte (40 per
vector), and taking values out of the vector into a caller's body kept the body scalar. The portable fix
for both (no `asm` barrier) is a small stack buffer (`withUnsafeTemporaryAllocation`, no allocation):
compute values into it with a plain loop and load vectors back, or unpack into it and run the body over
it, so the plain loops vectorize on their own.

Emulating a lookup that's one instruction on one CPU is no portable fallback: Bytes' 64-byte `tbl` shuffles,
emulated a lane at a time in C, ran 37–113x slower than the NEON build and 15–54x slower than the plain
Swift loops. Gate such algorithms on the instruction being there (`ByteLanes.isLookupVectorized`), and
measure the other builds (`Bytes/bench portable`, `portable-no-c`; `BytesCompression/bench` for the codecs).

Table lookups in a `Span` lose their bounds checks only while the optimizer knows the count: 256-entry
spans for a CRC's byte tables folded the checks in one loop and not another, and a precondition stating
the counts fixed that loop and made the other spill and check again. For hot tables, pointers into
borrowed storage, with the reason in a comment (Bytes' `CRC32._Tables`).

On M3, NEON `ld4`/`st3` didn't beat `uzp` and `tbl` shuffles for Base64 decoding (C, 12.9 against 12.5
GB/s): the loop is bound by vector-pipe micro-ops, and each `tbl`/`tbx` costs one per table register. Count
those (a 64-byte `tbx` is 4) when choosing a lookup: Base64's decoder went from a 128-byte table (`tbl` +
`tbx` on 64 each) to an 80-byte window (64 + 16), 69 to 61 micro-ops per block, +11%.

Closures passed to a generic `throws(E)` parameter: unannotated, `{ x in … }` is inferred as
`throws(any Error)` (Swift 6.4, without `FullTypedThrows`), and such a closure wasn't inlined into Bytes'
array builder: the writer went through memory, +3% instructions. Annotated `{ (x) throws(BytesError) in … }`,
it was inlined. An overload taking only `throws(BytesError)` doesn't fix it: the unannotated closure still
infers `any Error`, then fails to convert. Annotate the error type of closures in hot code. (The builder
itself now reserves an empty array and appends, through the standard library's specialized
`append(addingCapacity:)`, where both forms measure the same.)

The standard library's `[UInt8](capacity:initializingWith:)` (the `OutputSpan` initializer) and
`init(unsafeUninitializedCapacity:)` allocate through an unspecialized function: ~500 instructions and ~27
ns per array more than `reserveCapacity` then `append(addingCapacity:)`, or `Array(UnsafeRawBufferPointer)`,
at any size. For small arrays in hot code, use those.

## Compression and crypto

Details: `Bytes/Benchmarks/RESULTS.md`, `SocketStream/RESULTS.md`.

- **Compression bugs often show only as size.** Matches are verified, so a broken match finder still
  round-trips: DEFLATE's 16-bit positions rebased on `position - base == 32768`, positions that weren't
  inserted (a flush's last bytes) stepped over it, and every match after was lost (14% → 62% after 26 MB of
  a socket stream). Use `>=` for boundary checks, and test long streams with flushes against one-shot size.
- **Pick an adaptive path by what the optimization saves, measured, not a proxy.** Brotli's tag filter
  (8 extra hash bits per bucket entry, 16 compared at once) was 17–30% slower on text and 35% faster on
  x-ray. Copied fraction and average match length didn't predict it; the entries the tags rule out did
  (text 3–6 of 16, binaries 10–14). Sampled every 32nd search, decided per meta-block: best of both.
- **Specialize hot loops on a constant, as a copy:** Brotli quality 1's one-entry table ran through the
  bucket code's loop, 7–10% more instructions. Two `@inline(never)` wrappers over an `@inline(__always)`
  body with a constant `Bool` fixed it (check for `merged` symbols, above).
- **Reused state carries stale entries.** A reset that keeps a table by moving the position base leaves
  every old entry out of range but still scanned: check the newest entry first (a 1.6 KB stream −24%).
  Breaking out of the scan loop instead cost large inputs 3–5%.
- **Vector code needs independent chains, not just lanes.** ChaCha20 on four blocks (`SIMD4<UInt32>`) was
  four dependent quarter-round chains, the vector pipes half idle; eight blocks (`SIMD8<UInt32>`, all 32
  registers) +36%. For scalar multiply chains, fewer wide products: Poly1305 in radix 2^64 (4 + 2
  products per block) against 2^44 (9), +12%.
- **`a.f(g(&a))` reads `a` before `g` mutates it:** `Array(wire.prefix(send(into: &wire)))` copied the old,
  empty array (the inout access made a copy-on-write). Take the result into a local first.
- **Never pass a `throws(E)` closure to an untyped generic `rethrows` API** (`Array.withUnsafeMutableBytes`,
  `withUnsafeBytes`, `func f<R>(_: () throws -> R) rethrows -> R`). Swift 6.4.2 throws the wrong error,
  silently: the closure throws an `any Error` box as an `E`, and the caller catches the box's address as the
  enum (a `BytesError` printed `()`). With a `Void` or tuple result the compiler crashes instead.
  `~/Scratch/swift-bugs/25-…`, swiftlang/swift#90291. Use Bytes' `array.withOutputRawSpan { … }` (or
  `array.mutableSpan.withUnsafeMutableBytes`), which are generic over the error type and keep it. A span of
  a class instance's stored array lasts only for that property access: bind the array to a local `let` (a
  retain, no copy). A `~Copyable` stored property (a `ByteBuffer`) can't be bound that way: pass it `inout`
  to a function that does the work.
- **Move bytes with Bytes' helpers, not `withUnsafeMutableBytes` and `copyMemory`** (`Bytes/Sources/Bytes/
  Buffers.swift`): `OutputRawSpan.append(copying:)` and `withFreeCapacity { span, written in … }` (a
  `MutableRawSpan` over the free capacity, counting what the closure reports); `copyBytes(from:toByteOffset:)`
  and `copyBytes(within:toByteOffset:)` (overlapping) on `MutableRawSpan` and `MutableSpan<UInt8>`;
  `[UInt8].withOutputRawSpan(overwritingFrom:)`; and `ByteBuffer`, a buffer filled at the end
  (`fill`, or `receive` from an async source such as a socket) and drained from the front, compacting below a
  threshold. Moving the codecs, TLS records, `Pipeline`, and SocketStream onto them changed no instruction
  count beyond the reported resolution (`Bytes/Benchmarks/RESULTS.md`, 2026-11-16). Two traps: `[1, 2, 3].span.bytes` is an `[Int]`'s 24 bytes (type the literal `[UInt8]`), and a sync
  method and an `async` overload of one name taking a `throws(E)` closure are ambiguous from async code
  (hence `fill` and `receive`).
- **Nonce reuse hides in `reset()`.** A TLS sealer reset with the same keys must not restart its record
  sequence; the opener gets `reset(sequence:)` to replay records in tests and benchmarks.
- **`@inline(__always)` is a hint; `@inline(always)` is a guarantee.** The SIL inliner declined Brotli's
  `@inline(__always)` match search into the parse loop ("Not profitable to inline … cost = 785" in
  `Tools/remarks --passes sil-inliner`) once the loop grew, and LLVM then found it "too costly": quality 5
  ran 2–8% more instructions. `@inline(always)` (Swift 6.3, SE-0496) inlined it. After growing a hot loop, check its
  callees with `Tools/calls`.
- **Byte-only formats use `AlignedBytesReader` and `AlignedBytesWriter`.** These are `GenericBytesReader` and
  `GenericBytesWriter` in the `ByteAligned` mode: the same byte-level API, with a bit offset that's the constant
  0.
  - Measured: MQTT encode −6%, parse −1 to −3%, Base64 encode −2 to −8% on short inputs, DEFLATE decode −2
    to −4%.
  - Builders: `[UInt8](alignedByteCapacity:)`, `withAlignedBytesWriter`. `String(utf8Capacity:)` gives an aligned
    writer.
  - Keep `BytesReader`/`BytesWriter` for sub-byte fields in the stream. `Byte` and its bit fields work in both.
  - Out-of-line helpers on the cursors belong in the `BitAddressable`-constrained extensions, so they aren't
    generic. Check new ones with `Tools/calls … --callee metadata`.
  - One exception measured: QOI's run-filling decoder ran 54% more instructions with the aligned reader. LLVM
    nested its fill loops inside the pixel loop, so it keeps `BytesReader`. Measure when switching a hot loop.
- **A safe helper's one check per call can cost more than the work in a hot loop.** Measure before moving
  a hot loop onto a checked core API.
  - Bytes' `commonPrefixLength` checks its bounds once per call (one sign test of the bounds ORed together,
    about eight instructions). Called per match candidate, it cost the compressors 3–18%.
  - `BitWriter.flush()`'s capacity check cost the encoders 0.2–1.7%.
  - Both have `@unsafe` forms (`unsafeCommonPrefixLength`, `unsafeFlush`) for loops that prove their bounds
    once per block. The safety argument goes in a comment at the call site.
  - Fixing `BitBuffer`'s bit order at compile time saved nothing: the run-time `let` folds wherever the buffer
    is inlined. (Brotli's decoder ran 1–2 K more instructions on 1.6 KB streams with `BitBuffer.rewind(to:)`
    than with a new buffer, inlined or not, cause unknown: it keeps the new buffer.)
- **Hot decode loops keep their state in locals.** Brotli's bit buffer passed `inout` to a function that
  wasn't inlined lived in memory for the whole loop (and its bit order was tested at run time): copy it into
  a local, pass values, and store it back after. Masked indices (`types & 0xFF`, `context & 0x3F`) let span
  checks fold; Huffman tables built from only the used symbols, sorted, cost in proportion to them. Together
  20–42% faster across the corpus, 1.6 KB streams the most.
- **Truncated input looks like data.** A bit reader's zeros past the end can decode as a valid but wrong
  symbol (DEFLATE's code-length code 16 at index 0, "repeat the previous length", threw `invalidValue` when
  the input ended 8 bytes into a dynamic header): when a decoder rejects a value, check `isOverrun` and ask
  for more input instead. Find such bugs by recording a stream's calls and replaying them cut at every point.
- **Copies stop at the data's end, not the buffer's.** A parse whose lazy step reused `maxLength - 1` from
  the first position let a second delay's copy run a byte past `dataEnd`. Sequentially that read past the
  input (unchecked loads); in a parallel chunk, the next chunk's bytes matched and the stream decoded a byte
  long. Random test inputs never triggered it: build inputs that force the path (Bytes'
  `copiesStopAtChunkEnds`), and check parallel outputs with an independent decoder on real corpora.
- **Parallel compression: avoid rounds.** Rounds of one chunk per lane with a barrier after each lost
  0.1–0.7 ms per round to thread wake-ups and cores still at low clocks, plus the serial copy of the round's
  output. One `concurrentPerform` (or task group) per call, workers taking the next chunk, output handed to
  slots by swapping buffers and copied in order by whichever worker finishes the next chunk
  (`ChunkScheduler`): 8–22% faster with two rounds, 22–41% with four, even with one (interleaved; across
  benchmark runs these rows swing 10–30%, so A/B parallel changes in one process). Keep chunks a whole
  number per lane (39 chunks on 24 lanes take as long as 48). State reused across calls must be reset per call: a slot still naming chunk 0 from the last call
  looked ready. Task groups beat `concurrentPerform` by up to 10% here; async APIs that take `inout`
  storage are `nonisolated(nonsending)` (otherwise `@concurrent`, and callers must send `self`).
- **Extracting files: the kernel is the limit** (`NativeZipArchive/Benchmarks/RESULTS.md`, step15). Small files
  cost `open`, `write`, `close`, and metadata syscalls (decoding was 2%), and APFS creation contends beyond about 8
  writers (12 or more got slower, 24 took 3x as long). Writes to one file are serialized: parallel `pwrite`s of a
  1 GB file gained nothing, and parallel copies into a shared mapping of it were 1.4–3x slower. What helped:
  overlapping serial planning with the writes (a queue filled while planning, −17% on 20,000 files), one pool
  for several archives (8 archives of one large entry each, 4.6x), working in cache-sized pieces (checksum
  8 MB, then write it: −29% for 1 GB stored), and setting times and mode in one `fsetattrlist`. Put benchmark
  output in a `*.noindex` directory: Spotlight indexing what you extract loads the machine.
- **Payload structs with resilient fields (`Date?`) copy through value witnesses** (`swift_cvw_initWithCopyImpl`
  in profiles): jobs that are queued, sorted, and handed between tasks are cheaper as final classes.

## API design and code generation (2026-11-17)

The proposals pass; numbers in `Bytes/Benchmarks/RESULTS.md`.

- **Check a new API's codegen from another module** (a throwaway package depending on the dev tree, `@inline(never)`
  probes beside hand-written equivalents, `objdump`): LLVM merges identical functions, which is the proof. Named bit
  fields (`flags[ConnectFlags.userName]`) matched hand shifts; a `BitPattern` literal folded to its two masks only
  with `@inline(__always)` on both initializers (otherwise a run-time parse per call).
- **The standard library's `ByteOrder.==` is a call** (derived `==` of any other module's `@frozen` enum is:
  `~/Scratch/swift-bugs/26`). `switch` over the order instead; a byte-ordered writer went 71 → 53 instructions.
- **Store a checked value unmasked.** An enum field setter with `assert` + mask cost MQTT's PUBLISH encoding 0.8%;
  `precondition(raw <= mask)` then an unmasked store folds both away when the enum's raw values are visible.
- **An empty default closure isn't free, and compilers disagree about it.** MQTT's properties validation with a
  `visit: { _ in }` parameter cost 2% under Xcode's compiler; forced inline, it gained 1% there and cost SocketStream
  (PR toolchain) 10%. Give the plain path its own body; force-inline only the variant that needs it.
- **Generated code needs `@inline(__always)`.** `@BinaryRecord`'s `init(parsing:)` stayed a call (the 17-field record
  returned through memory): 297 K against 199 K instructions for the same hand-written parser. Forced inline, equal.
- **Moving code to another module can cost instructions even when it's inlined.** `HuffmanCodeBuilder` in Bytes
  instead of BytesCompression: +2 K per 1.6 KB Brotli stream with `@inlinable`, `@inline(__always)`, and
  `@inline(always)` alike; it went back. Benchmark every move.
- **Stitch scalar work into vector loops.** Poly1305 (integer multiplies) between ChaCha20's eight-block rounds
  (vector, all 32 registers): sealing 1 MB −40% time, 1.52 → 2.50 GB/s, instructions barely changed.
- **A cheaper mask isn't a cheaper loop.** `ByteMatches.nibbleMask` (one `shrn`, from plain Swift) beats `bitmask`
  for finding the first lane, but Brotli's tag filter walking 4-bit slots ran 2.7% more instructions than with the
  one-bit gather.
- **Spans can't be captured through two closures** ("lifetime-dependent variable escapes its scope"), nor borrowed
  from a property while another property is mutated in a closure: pass both as parameters to a static function
  (TLS sealer's `ByteBuffer`s).
- **Overloads and literals:** a generic `write(_: some FixedWidthInteger, as:)` beside `write(_: T.Integer, as: T)`
  takes integer literals (they default to `Int`) unless `@_disfavoredOverload`; a bare `writer.write(7)` is ambiguous
  between `Byte`, `UInt8`, and `Int8`, which is right: state the width.
- **`.macro` targets need `import CompilerPluginSupport`**; without it the manifest fails as a type-check timeout
  (`~/Scratch/swift-bugs/27`).
- **Cross-toolchain checks:** SocketStream builds with a PR toolchain whose inliner differs; a change that helps MQTT
  under Xcode's compiler can hurt SocketStream. Track both.

## The 2026-11-18 pass

Zstandard, native crypto and TLS, parallel sealing; numbers in each package's RESULTS.md.

- **A count check is one unsigned compare.** `UInt(bitPattern: n) <= UInt(bitPattern: remaining)` rejects negative and
  too-large counts at once; `n >= 0 && n <= remaining` cost BinaryParsingComparison's LZ4 2% in instructions.
- **`InlineArray` passed `borrowing` can be copied at every subscript.** The zstd decoder's FSE spreading loop copied a
  512-byte table (`memmove`) per access: 16,000 copies per 4 KB frame, 22% of its time. Hot tables go in raw memory
  the decoder owns (a workspace), indexed through a pointer, with the safety argument in a comment.
- **An out-of-line `mutating` call makes its struct live in memory for the whole loop.** The zstd bit reader's reload
  (and Brotli's bit buffer before it) kept the reader spilled while one cold path called a `mutating` method on it:
  make such helpers static functions that take values and return them.
- **Lane-mask tricks need varied test data.** `ByteMatches.nibbleMask` shifted bytes right before narrowing, so odd
  lanes reported bit 3: bytes like `0x70` matched. Tests with one filler byte never showed it. Spread the high bit
  first (an arithmetic shift by 7), and test with varied bytes around each match.
- **`~Copyable` members made on first use:** an `Optional`. `x!.mutate()` works in place, but `x!.property` in a read
  consumes the optional ("cannot partially consume 'self'"): borrow with `switch x { case let .some(y): … }`
  (SE-0432). NativeZip's staging buffer and streaming decoder are made this way, on the first encrypted entry. A
  benchmark that makes its decoder inside the measured closure then counts that first-use setup as per-iteration
  mallocs.
- **Records are independent once their sequence numbers are fixed.** TLS sealing in parallel: full records have known
  sizes, so each lane seals its records straight into their places in the output (`concurrentPerform` over pointers
  in an `@unchecked Sendable` wrapper). 3.6–3.8x on 4 lanes, 5.8–6.9x on 8. Opening isn't symmetric: a record's
  plaintext length (inner type and padding at its end) is known only after decrypting it.
- **Register pressure beats instruction choice:** ChaCha20's rotate by 8 as a `tbl` byte shuffle (one instruction
  instead of shift and insert) took the eight-block double round from 264 to 323 instructions, from spills of the
  shuffle's table. Reverted.
- **A shuffle-heavy SSE kernel isn't a NEON kernel.** Base64's reshuffling encoder (one-register `tbl`s, then shifts
  and masks per 32-bit lane) was 75 instructions per block against the deinterleaving kernel's 32, which LLVM folds
  into `st2` stores. Per-lane shift amounts on `SIMD8<UInt16>` compiled to split halves (143); lane picks across two
  vectors became byte inserts unless written as a contiguous run (one `ext`).
- **Bytes' crypto types share CryptoKit's names** (`SHA256`, `HMAC`, `HKDF`, `AES`, `HashFunction`): qualify with the
  module in code importing both (`CryptoKit.AES.GCM`).
- **Don't take `.span` of a throwing call's result directly**: at `-Onone` the LLVM verifier crashed
  (`~/Scratch/swift-bugs/28`). Bind the result to a local first.
- **Test reads that end exactly at the data's end.** `read(_:asciiDigits:)`'s two-load path lacked a `count > 8`
  condition, so short reads near the end loaded 8 bytes past the data (unchecked loads); every test with bytes after
  the field passed. Every fast path with wide loads gets a test whose input ends where the field does.
- **`pointwiseMin`/`pointwiseMax` on `SIMD16<UInt8>` are calls** (Swift 6.4): use a vector comparison
  (`a .<= b`, one `cmhs`/`cmhi`) and `replacing(with:where:)`.
- **ASCII tags fold:** `Byte4(ascii: "IHDR")` (`@inline(__always)`, a `StaticString` read in a loop over the
  constant width) compiles to the same code as the hex literal; LLVM merged the two benchmark functions. A
  `static let` of it would still be lazily initialized.

## Apple Encrypted Archives and the LZMA decoder (2026-11-18)

NativeAEA/RESULTS.md, Bytes' RESULTS.md; format in NativeAEA/FORMAT.md.

- **APFS file creation peaks at about 4 threads** (46,000 small files a second) and slows beyond 8, in one directory
  or many: the contention is in the file system. Keep CPU work (compression) outside a semaphore around the calls;
  extracting Xcode went 11.4 → 9.0 s with 24 writers and at most 6 in the kernel (Apple's `aa extract`, 32 threads
  in the kernel: 47 s, 347 s of system time). Instrument the stages (time per call kind, summed) before guessing.
- **Creating entries relative to an open parent wasn't faster** than paths from the destination (3% slower: the
  name cache makes lookups cheap, and opening each directory is one more call). Deep paths cost ~20% in a
  microbenchmark but not in the pipeline.
- **Setting an extended attribute checks the file's mode, not the descriptor's**: `fsetxattr` on a file created
  0444 fails with `EACCES` even with the descriptor open for writing. Create owner-writable, `fchmod` at the end.
- **APFS compression (`decmpfs`) is three calls after `open`:** the resource fork (`fsetxattr("com.apple.ResourceFork",
  position)`), `com.apple.decmpfs` (16-byte header, data inline when small), `fchflags(UF_COMPRESSED)`. Chunks are
  64 KiB, 0xFF + raw bytes when they don't compress. `clonefile` keeps all of it but was slower than creating (23,000
  a second on 4 threads, one source).
- **A pool of slots that jobs hold until they finish waits on the queue's latency**, not the work's: 4 large-file
  slots made the walker wait 6.0 s of 9.0 s, because a piece's job sat behind 16,000 queued small files. Size such
  pools for the queue.
- **Overwrite consumed input in place** to compress pieces in parallel without memory: each 64 KiB chunk's output
  moves back over the piece's own consumed bytes while the output stays behind the unread input (it can grow by a
  byte per chunk), falling back to a buffer when it would catch up.
- **Shared mutable state the walker reads to decide reference handoffs is a leak**: a writer cleared a large file's
  fork type while the walker used it to decide whether to pass a buffer reference on; the reference leaked and
  `DispatchSemaphore` trapped at deinit (freed below its initial value). Keep the decider's own copy.
- **package-benchmark's malloc interposer traps on thread exit** (`count_free` → `_tlv_get_addr` → `calloc` in
  `_pthread_tsd_cleanup`): benchmarks that start threads can't count mallocs. Count them in single-threaded ones.
- **`aea` rejects some PEM keys**: a P-256 private scalar with a leading zero byte (1 in 256) DER-encodes in 31
  bytes, and `aea` fails with "Error parsing PEM blob". CryptoKit's PKCS #8 PEM isn't accepted at all; use
  `openssl ecparam -genkey` and check the octet string is 32 bytes.
- **`aea decrypt -o -` doesn't write to stdout**: it writes a file named `-`.
- **LZMA decoding (the decoder agent):** LLVM turned a range coder's `one ? 1 : 0` into a branch that mispredicted
  half the literal bits; the bit from the borrow (`(UInt64(code) &- UInt64(bound)) >> 63`) cut cycles 20%. Load both
  children's probabilities (adjacent `UInt16`s, one 32-bit load) while the parent bit decodes (−14%). `x < 1 << 24`
  compiles to `lsr`+`cmp`; a threshold in a register is one `cmp` (−5%). The normalization branch predicts well:
  every branchless form was 2–10% slower. CRC-64 by `pmull` folding: 24–41 GB/s against a table's 2.2.
- **Destructive shell sequences:** `perl … > new && diff …; cp new file` copied an empty file over a source file when
  the script failed to compile (the `;` ran `cp` anyway), and the new package wasn't in git yet. Chain every step
  with `&&`, or use Edit.

## Apple's formats, curves, and running five agents at once (2026-11-18)

NativeAEA/RESULTS.md, Bytes' and BytesCompression's `Benchmarks/RESULTS-*.md`.

- **CommonCrypto's CTR mode (`kCCModeOptionCTR_BE`) counts only the block's last 8 bytes**, wrapping with no carry
  into the first 8 (checked from an IV at 2⁶⁴ − 1). Apple Encrypted Archives use it: `AES.Counter(bigEndian64BitCounterIn:)`.
  The difference from a 128-bit counter shows only when the low word wraps, so test IVs about to wrap.
- **Undocumented Apple codecs can be read from libcompression**: `ipsw dyld extract` pulls the dylib from the shared
  cache; its local symbols (`_rav_decode_buffer`, `RavGetLitLamContext(unsigned char)::lut`) name the functions and
  tables. Transcribe to a C reference first and check it decodes Compression's output exactly; then write Swift.
- **Generic standard-library SIMD conversions are inlined only while they have few callers**: `SIMD8<UInt16>(
  truncatingIfNeeded:)` in LZBITMAP's decoder was inlined until the LZFSE and LZVN encoders, in the same module,
  used SIMD conversions too; then it stayed a call (6 per 16 groups), and decoding ran 12–15% more instructions
  with no change to the decoder's file. Found by bisecting the module's files in a copy of the package. In hot
  code, widen with a byte zip (lane picks of two vectors: `zip1`/`zip2`) and narrow with Bytes' `_lowBytes`
  (`Builtin.trunc`: one `xtn`, or `shrn` after a shift); picking even bytes to narrow was merged by LLVM into
  lane moves. Recheck hot loops with `Tools/calls --callee 'specialized SIMD'` after adding code to their module.
- **An encoder's output can depend on the room it's given**: Compression's LZBITMAP (and Bytes' copy of it) needs
  working room beyond its result, so a chunk given exactly its own size can fail, or come out larger, where 64 KiB
  of room compresses it. `aa extract` gives every APFS chunk 64 KiB; giving each its own size left 1,604 of Xcode's
  files stored differently. Compare stored bytes, not just storage forms, and find such rules from the data (fit
  the rule against every file: NativeAEA/RESULTS.md, 2026-11-19).
- **Probe a decoder with crafted streams, and expect two rule sets**: Compression's LZBITMAP decoder has a fast loop
  and a careful one for a chunk's end, which disagree on corrupt input. Its buffer API also stops once the output
  is full and returns that count, so it "decodes" streams missing their end; 0 is its only failure.
- **Vectorize independent work, not a dependent chain**: Salsa20/8 as `SIMD4<UInt32>` diagonals was clean
  `vector128` code and 3x slower than scalar (each step 4 dependent vector instructions). And SLP turns a scalar
  kernel's 16 loads or stores into vector ops with lane moves: load and store `UInt64` pairs (−6%); check with
  `Tools/loops --forbid mov.s,fmov,ins,umov`.
- **Write out fixed-count loops of multi-limb arithmetic**: LLVM left Montgomery's row loop rolled with the
  accumulator in memory (P-384 −13% time written out). A field multiply that wins alone (wide integers, special
  reductions) can lose inlined into point formulas: measure the whole operation. Constant-time ladders: Jacobian
  formulas with the special cases selected by masks beat complete formulas (−28%).
- **Spans and Swift Testing**: `#expect`, `#require`, and `Optional.map` don't take `~Escapable` values (compute a
  `Bool` first, use `if let`). `array[i].span` is a temporary's (bind `let x = array[i]`), and so is the span of a `let`
  assigned inside a `switch` ("lifetime-dependent value escapes its scope"): bind it to another constant.
- **Typed throws**: `do { } catch` around a typed-throws call boxes the error (`swift_allocError`) unless written
  `do throws(E)`.
- **C references in SwiftPM build at `-Os` without `NDEBUG`**: their asserts stay in (lzfse's cost 18%): set
  `cSettings: [.define("NDEBUG")]` before comparing. Release tests with `@testable` need `-Xswiftc -enable-testing`;
  elliptic-curve code in debug is hundreds of times slower.
- **`Darwin.membership` is an explicit submodule** (`mbr_identifier_to_uuid` for ACL qualifiers): `import
  Darwin.membership`, no shim needed.
- **`aa archive` hangs on a FIFO in the tree** (it opens it to read). `pbz` blocks have no checksums: damage to a
  stored block isn't detected (by `aa` either); test corruption on a compressed block.
- **The first URLSession request to a new domain waits on a security prompt** (the program hangs, curl doesn't): tell
  the user to look for it, as for the attach prompt.
- **zsh's `status` is read-only**: `local status=$?` aborts a zsh script; name it `rc`.
- **Agent worktrees stay locked by the parent session** (`git worktree remove` refuses: "locked working tree, lock
  reason: claude agent"): once the agent has finished and its files are merged, `git worktree unlock` then remove.
  Before removing old worktrees, compare each changed file's added lines with main, not just whole files.
- **Five agents benchmarking under one lock**: their timed runs queue (an hour of a three-hour task was waiting), and
  each run still meets the others' builds. Judge by instruction counts during the work; time on an idle machine after.

## Xcode's `.xip`, bzip2, RSA, and Compression's LZVN (2026-11-19)

NativeAEA/XIP-REPORT.md, FORMAT.md §4, Bytes' RESULTS-rsa.md, BytesCompression's RESULTS-bzip2.md and
RESULTS-lz4-lzfse.md.

- **Find an Apple tool's storage rule from every file, in its units.** `xip --expand` compresses files over 16 KiB
  that aren't PNGs when the fork saves a fifth of the **4 KiB blocks** (`ceil(fork/4096)×5 ≤ ceil(size/4096)×4`); by
  bytes, ratios from 0.787 to 0.864 went both ways. `aa extract`'s rule is in bytes (93%). The room differs too: `xip`
  gives each LZVN chunk only its own size (LZVN needs 1–10 bytes beyond its stream, so 42 short last chunks were stored
  raw where 64 KiB of room compressed them), `aa` gives every LZBITMAP chunk 64 KiB.
- **`fchflags(UF_COMPRESSED)` sets the file's modification time to now**: set times after the flags (and locking flags
  after the times).
- **Compression's LZVN (0x900) is the open lzvn reference with another hash**: `((v & 0xFFFFFF) × 0x9E3779B1) >> 18`
  against the reference's `× 4161 >> 12`, and every room check the reference's (1–10 bytes beyond the stream; under 8
  bytes of input it returns 0). Compression's LZFSE differs from the reference in one constant (pending literals pushed
  past 945, not 2,520). Read the library's code (`ipsw dyld extract`, Binary Ninja) and check a patched C reference on
  every corpus file and capacity before writing Swift; Bytes' encoders now match both byte for byte.
- **A `.xip`'s signature is RSA PKCS #1 v1.5 of the TOC checksum itself** (the 20 SHA-1 bytes as the `DigestInfo`
  digest), chained to the 2006 Apple Root CA; check the certificates' validity at the TOC's `creation-time`. This
  macOS's `xar` no longer signs (`--sign` is gone): tests write their XAR archives in Swift and sign with `openssl
  pkeyutl`.
- **APFS spends ~280 µs of kernel CPU on every `linkat`** (first or later link, plain or compressed file, measured
  alone): Xcode's 26,000 later names cost 2.6 s on 6 threads, and links made during the writes slowed the writers by
  as much. Hard links are the xip's largest serial phase.
- **bzip2 decoding**: a nested function that captures the decoder's state is heap-boxed (7 allocations a block); hot
  loops with any call spill their registers; loading the bit buffer's refill one symbol ahead takes a load off each
  symbol's critical path; the inverse BWT (a dependent load per byte) runs 24 interleaved walks of ~1 KB segments.
- **A program blocked in `open` at 0% CPU on a file in ~/Downloads (or Desktop, Documents; why example files are in
  `~/Scratch` now) waits on a privacy
  prompt**, whatever binary opens it, tests included (a `.enabled(if:)` trait that lists the folder blocks too): tell
  the user to look for it. A `gtimeout`ed `swift test` can leave `swiftpm-testing-helper` behind: find it by its
  `--test-bundle-path` and kill it by PID.

## Threads to structured concurrency (2026-11-19)

NativeAEA/RESULTS.md, ARCHITECTURE.md §9.

- **Mark internal async functions `nonisolated(nonsending)`**, and the public entry points `@concurrent`: without it
  NativeAEA's walker made about 4 `swift_task_switch` checks per entry (21,374 → 1,481 for 1,001 files).
- **Waits are `Mutex` state plus a continuation, taken synchronously under the lock when nothing has to wait**; check
  again under the lock inside the continuation's body, remove a waiter under the lock, resume it outside. A
  `CheckedContinuation` allocates per wait: `UnsafeContinuation` in release builds for waits that happen per file.
- **One `withTaskCancellationHandler` per operation** that closes the pools and queues (every waiter wakes) beats a
  handler per await; workers still drain queued jobs after a failure, to release what the jobs hold.
- **CPU-bound tasks filling the cooperative pool didn't starve the others** (32 decoders, one walker, 24 writers):
  yields and priorities measured no different. Measure before adding an executor.
- **An async main task runs at priority 21**, not user-initiated: start the work in a child task with a priority.
- **`sending` closures can't append to a caller's local** that's read afterwards; a plain closure parameter can.
- **A buffer sized for the largest item stays resident at that size**: `madvise(MADV_FREE_REUSABLE)` past a floor
  after each use, `MADV_FREE_REUSE` before (32 read buffers of 16 MiB: −170 to −230 MB, no system time).
- **`stat`'s block counts of freshly extracted `decmpfs` files vary run to run**: compare contents and sizes.
- **`xargs -P` interleaves its children's output lines**: hash files serially, or one output file per process.

## Bytes cleanup (2026-11-19, later)

Bytes' RESULTS.md.

- **Offload synchronous work with a `@concurrent` function taking a non-escaping `@Sendable` closure**
  (`BytesAsync`'s `perform(_:)`, `ByteTransform.concurrently()`): off any actor, no thread switch from a nonisolated
  task, nothing allocated. DEFLATE level 1 in 64 KiB calls: same time as in place, a Dispatch queue hop +7%. A generic
  `@concurrent` function called on a type parameter warns that its conformance "may be isolated" under
  `InferIsolatedConformances`, even with `SendableMetatype`; the closure form doesn't. APIs that borrow caller storage
  (`inout`, spans) stay `nonisolated(nonsending)` and move only their workers off the caller.
- **Values mutated by `@inline(__always)` nested functions can stay in memory behind `swift_beginAccess`**: SHA-512's
  state and schedule as captured variables cost 12 access checks a block (638 instructions); as structs with mutating
  methods, 519, then 489. Prefer structs with mutating methods to nested functions over captured `var`s in kernels.
- **A table that becomes a compile-time constant can make LLVM rematerialize its address in the loop**: CRC-32's
  literal tables (no more `swift_once`) cost 64-byte checksums +10.7% until the inner update was `@inline(never)`
  (the address opaque again). Measure after removing a lazy global, not just `Tools/calls`.
- **Literal `static let` arrays and `InlineArray`s are statically initialized** (no `swift_once`): only computed
  initializers (`(0..<n).map`, closures) are lazy. Check with `nm` (no once token) or `Tools/calls --callee swift_once`.
- **A stitched decrypt-and-authenticate must restore the buffer on a bad tag** (re-encrypt with the same counter):
  AES-GCM open in one pass, −12% instructions, TLS open −14%; every forged case leaves the buffer byte-identical.

## A second machine (M1 Max, 2026-11-19)

`Writeups/M1-Max-vs-M3-Ultra.md`, `Bytes/OPTIMIZATION.md`, Part III "The second machine".

- **One core is the clock** (1.31x time for 1.25x clock, over 773 benchmarks with identical instruction counts); more
  cores change parallel work by the lane count. Keep Instructions beside times when comparing machines: they show whether
  the same code ran.
- **After moving to new hardware, re-run something unchanged on an idle machine first.** Spotlight/`mediaanalysisd` were
  indexing the new files during the first runs; one memory-bound row read 2.2x slow. A standalone probe (a C copy of the
  kernel, or a plain Swift loop over the API) that disagrees with a benchmark row is the signal. `TestData/` has a
  `.metadata_never_index` marker for this.
- **`udot` (FEAT_DotProd) was the unused instruction:** Adler-32's two sums are dot products against ones and against
  64…1, 1.9x faster than the 16-bit Swift SIMD version (57 GB/s, within 10% of libdeflate). Swift SIMD has no widening dot
  product; a `static inline` C wrapper (`bytes_crc_udot`), loop in Swift.
- **Efficiency cores:** queue-fed workers gain from them (the DEFLATE encoder 3–9%, the decoder 7–12% once it took
  segments from a queue); statically split work loses (the decoder with one even segment per lane: 20–35%, because one
  segment lands on a slow core). "Lanes = performance cores" suits only the second kind.
- **Measure a core's instructions rather than assuming** (`Tools/cpu-probe insn`): on the M1 Max, `tbl` with 3 or 4 table
  registers is 2–3 vector slots and `tbx` one per register (4: 8 cycles of latency); 1–2 `tbl` registers are full speed;
  `udot`, `pmull`, `aese` run 4 a cycle at 3 cycles of latency, and `aese`+`aesmc` fuse (3 cycles a round).
- **A throughput probe needs latency × rate independent chains:** the first M1 Max probe had 8, so every 3-cycle
  instruction read 2.7 a cycle instead of 4, and two conclusions built on it were wrong (Adler-32 "bound by `udot`",
  AES-CTR "90% of the bound": it is at the bound of its eight round chains, and 12 blocks could reach about 1.5x).
  Calibrate cycles with a dependent scalar `add` chain (1 cycle); a vector `add` reading 2.00 cycles confirms it.
- **Change a parallel splitter, sweep the corpus:** the decoder's four segments per lane rejected its speculation on one
  stream (mozilla level 1) at 6 of 16 lane counts, sequentially 7x slower; the benchmarks' inputs never hit it. Check
  `lastSegmentCount` over every corpus file and lane count.
- **A throughput probe needs latency × width independent chains** (12 for a 3-cycle instruction on four pipes). The M1 Max
  probe used eight and read 8/3 = 2.7 a cycle for `udot`, `pmull`, `aese`: its own limit (the M3 Ultra reads 2.7 with 8
  chains, 4 with 16; 2026-11-20). Measure with `Tools/probe` (below), which takes the best of 8, 16, and 24.
- **Break a latency bound with chains that nothing carries, not more accumulators.** Adler-32's `udot` loop was bound at
  3 cycles per 64 B by `udot`'s latency *and* by its `prefix` adds (one per byte-sum accumulator a block); 16
  accumulators doubled the adds (+3%). Computing each 128-byte step's byte sum as one `udot` chain from zero, folded in
  with two carried adds, took 19 vector operations per 128 B and 1 MB from 76 to 101 GB/s. Count every vector operation
  (adds, `movi`) against the pipes, not just the expensive instruction, and check both bounds before adding accumulators.
- **Compare machines with `Tools/probe`, not one-off probes** (`Tools/probes/README.md`): `Tools/probe all` on each, then
  `Tools/probe compare`. It takes the best of 8, 16, and 24 chains (on the M3 Ultra, three-source instructions like
  `eor3` fall to 2.8 a cycle at 24) and calibrates the clock next to each instruction (a P cluster's clock moved
  3.6–4.06 GHz under load; a cold first calibration made the first M3 probe's latencies 3% low).
- **Compare instruction counts only between rows measured with the same metrics.** Rows that also counted mallocs (the
  interposer active) read about 700 fewer instructions per sample on 1–100 K-instruction rows than the same rows without
  it (`m3-1120` against `speed-after`, system libraries included).
- **Speculation must fail locally.** `ParallelDeflateDecoder` decoded the whole stream sequentially if any of its
  `4 × lanes` split points was a false `00 00 FF FF` (one inside Huffman-coded data, not just stored data): mozilla level
  1 was 14x slower at 11, 22, 25, and 28–32 lanes, and the benchmarks ran only 8 and 24. Now the segment before a bad
  split decodes on past it, and a failed region is decoded again in place after the real history. Sweep every lane count
  from 1 to the machine's cores in tests (`Tools/probe bytes segments`), not just the counts the benchmarks use.
- **Profile the calling thread of a parallel call, not just the workers.** The parallel decoder's serial copy of the
  joined output was a quarter of its time, and a serial split scan another 8%. Hand each finished piece to the output
  from whichever worker makes it ready, and make each worker's setup depend only on its own piece so workers do it.

## The Disk package and the Nunarchiver app (2026-11-20)

`Disk/RESULTS.md`, `NativeAEA/RESULTS.md`.

- **A GUI app working with no frontmost window runs at background QoS** (App Nap): every thread at priority 4 in `ps -M -p PID`,
  efficiency cores only. Xcode's xip in Nunarchiver was past 83 s against the CLI's 11. Start the work at `.userInitiated`
  and hold `ProcessInfo.beginActivity([.userInitiated, .idleSystemSleepDisabled], …)` while it runs.
- **Xcode 27's autogenerated scheme can instrument Release builds for coverage, packages included**: the LZVN encoder's
  loop went from 188 to 585 instructions (an `adrp`/`ldr`/`add`/`str` per counter), and 24 threads sharing the counters
  made Xcode's expansion over 3 minutes. `-enableCodeCoverage NO` applies only to `test`: commit a shared scheme with
  coverage off, and check built apps with `otool -l APP | grep __llvm_prf_cnts`. Compare an app's hot loop with the CLI's
  (`Tools/loops` on both binaries) when the app is slower.
- **`fsetattrlist` sets times, mode, and flags in one call and keeps the times** even with `UF_COMPRESSED`, where `fchflags`
  resets them; with flags alone it costs 62 K more kernel instructions than `fchflags`.
- **TCA26's `onMount(id:)` remounts the whole feature it modifies, children included**: put it on an empty `Update` of its
  own, or every child's effect restarts when the id changes.
- **`NSApp.terminate` called on the main queue** (from a task or a dispatch source) hangs if it can return
  `.terminateLater`: its nested run loop doesn't drain the main queue. Request it with `RunLoop.main.perform(inModes:)`.
- zsh has a `log` builtin: use `/usr/bin/log`.

## One implementation each (2026-11-21)

`Disk/RESULTS.md`, `NativeAEA/RESULTS.md`, `NativeZipArchive/Benchmarks/RESULTS.md`.

- **Shared concurrency primitives go in BytesAsync, and moving them there cost nothing** when every type is `@frozen`
  or has `@usableFromInline` state and every method is `@inlinable`: Disk's, NativeAEA's, and NativeZip's waits
  (`Continuation`, `WaiterQueue`, limiter, index pool, latch, queue, handoff) and `RawStorage` moved with identical
  mallocs, calls, and (within the rows' spread) instructions. Check a move with `Tools/calls --target PKG TARGET '.*'
  --callee 'MODULE|swift_getGenericMetadata' --sum`: specialized copies in the client are fine, calls into the other
  module's unspecialized generics aren't. `#if DEBUG` in inlinable code is decided when the *defining* module is built.
- **Before writing a helper, look for it one module down**: two packages had the same 160 lines of waiting code, and
  three had a class around `Atomic<Int>`. But one user and a format's own layout (NativeAEA's segment pool, Disk's
  job-and-path queue) stay where they are.
- **A sync method and an `async` one of the same name are ambiguous across modules too** when the closure names its
  error type: Disk can't call BytesAsync's `RawSpan.withLentBytes` (Bytes has the sync one) and keeps a two-line helper.
- **package-benchmark prints "Build complete!" for its tool, then builds the benchmark targets.** An edit made after
  that line broke a queued baseline's build. Don't touch a package (or what it depends on) until its first result
  table prints; queue every "before" baseline before the first edit.
- **Build new Bytes API with SocketStream's PR toolchain as well**: it warned ("result of 'offer' cannot be returned":
  region isolation) about enums returned from `Mutex.withLock` that Xcode's compiler accepted. Make such types `Sendable`.
- **A directory isn't always made by its own entry.** Disk's planner assumed a listed directory had the mode its
  `mkdir` gave it; one made earlier as a file's parent (an archive listing it after its contents), or already there,
  kept 0755. And parents an archive never lists (ZIP) got no quarantine. Test archives that list directories last, and
  not at all.
- **A quarantine belongs in the writers, not in a walk afterwards**: one `fsetxattr` on the open file (and one
  `setxattr` per directory in the passes) against a second traversal on one thread, which doubled an 8,060-entry
  archive's time in the app.

## Matching Archive Utility (2026-11-21, later)

`Disk/RESULTS.md`, `NativeZipArchive/Benchmarks/RESULTS.md`, `NativeAEA/RESULTS.md`.

- **Compare with the real tool, item by item, before believing what it "reportedly" does.** Archive Utility
  (`open -W -a "Archive Utility" FILE`, each archive copied into a directory of its own under `~/Scratch`, the
  copy given a `com.apple.quarantine`) against Nunarchiver, both trees through one manifest (type, mode, flags,
  owner, size, mtime, link target, SHA-256, every extended attribute, the ACL's text), then `diff`. Times the
  expansion itself set are normalized (anything later than the corpus is NOW). What it showed that nobody had
  written down: the folder for several items is 0700 unless the archive has an entry for its root (`aa archive -d`:
  then that entry's mode and time); AppleDouble entries are merged (beside the item or under `__MACOSX`), ACLs
  included (`com.apple.acl.text`); symbolic links get their archived times; ZIP names are written decomposed
  (`fileSystemRepresentation`), Apple Archive names as stored; everything is quarantined, the folder too, except a
  `.xip`'s contents.
- **A tool's output can be an accident of its pass order: decide whether to copy it.** Archive Utility restores a
  `.xip`'s directory times before it writes the files, so only directories holding nothing but directories keep
  them (1,877 of Xcode's 30,068, found by classifying every directory by what it holds). Nunarchiver restores all
  of them and says so.
- **A GUI tool's failures are dialogs on the user's screen.** Archive Utility's alerts block `open -W` until someone
  clicks OK, and nothing in a session without Screen Recording or Accessibility can see or dismiss them. Run it
  only on archives it should accept (ordinary `ditto`/`zip`/`aa` output, Xcode's archives), with a timeout, add one
  feature at a time to a known-good archive, and never bisect a failing one by running it again. Its reason is in
  the log: `log show --last 2m --predicate 'process == "ArchiveService"'` ("Main key derivation failed", "Couldn't
  read the header of the entry: … Code=79"). Don't run two `open -W` of one app at once: the second waits on the
  first's dialog.
- **Foundation's directory enumerators leave `._` files out** (`FileManager.enumerator(atPath:)`): a test that lists
  an extracted tree to show no AppleDouble file is left passes whatever is there. List with `readdir`.
- **macOS's `unzip` and `ditto -x -k` merge AppleDouble entries too**, so a raw copy of one for a test comes from an
  extraction with merging off (NativeZip's `mergesAppleDouble = false`) or `python3 -m zipfile -e`.
- **A directory can't have a resource fork**: `fsetxattr("com.apple.ResourceFork")` on one fails with `EPERM`
  (`ditto` warns and goes on; Archive Utility refuses the archive). Leave it out rather than fail the entry.
- **Throughput in a polled UI is the counter's gain over the last n ticks of the poll timer**: no clock reads, no
  Foundation `Progress`; a sample every tick even when nothing changed, so a stalled rate falls to zero. State
  what the bytes are (here: file contents written to disk, before APFS compression).
- **A progress bar by bytes is full before the work is** (a `.xip`'s hard links and directory passes: 3.4 s of
  Xcode's 10.2, measured from the app's polls). A finishing state from `fraction >= 1` left the bar indeterminate for
  that third; now each entry counts as 64 KiB beside the bytes (`ExpansionProgress.fraction(entries:of:bytes:of:)`),
  so the bar moves through the links too, and the app keeps the largest fraction read (totals go from an estimate
  to exact mid-run).
- **`aea encrypt -profile 5` refuses short passwords** ("Password is too short"): tests use a long one.
- **`open` as an instance method hides Darwin's `open`** inside the type: write `Darwin.open`.

## Reviewing the Nunarchiver app (2026-11-21, review pass)

The app's sources and tests.

- **The pfw-tca26 skill's interface is older than the TCA26 the app builds with** (module `ComposableArchitecture`,
  `forEach(\.x)` and `scope(\.x)` without `action:`, `.transformEnvironment` test traits, `store.run`, `store.trigger`).
  Read the checkout: `Nunarchiver/.build/DerivedData-Debug/SourcePackages/checkouts/TCA26` (DocC articles under
  `Sources/ComposableArchitecture/Documentation.docc/Articles`, behaviour in `Tests/` and `Examples/`).
- **A parent commands a child with a `@Trigger` in the child's state, not by sending the child's actions**
  (TCA26's Triggers article): `for expansion in store.expansions { try expansion.cancel() }` in a store task. In a
  `TestStoreActor` the trigger's state changes are asserted in the `send` that caused it; no extra `receive`.
- **A `TestStoreActor` applies an effect's actions as they arrive, before `receive` asserts them**: after anything
  that can end a child (a cancel), `store.send(to: \.children[0], …)` or reading `$0.state.children[0]` races the
  removal and traps (index out of range, taking the whole test process with it). Test a row's own guards on a store
  of the child feature alone.
- **Is the bar really determinate? Ask AppKit**: SwiftUI's linear `ProgressView` is an `NSProgressIndicator` on
  macOS, so a temporary timer walking the window's views can log `isIndeterminate` and `doubleValue` (and count
  `body` evaluations) to the system log, read with `/usr/bin/log stream --level debug --predicate 'subsystem == …'`
  started before the app. `cacheDisplay(in:to:)` does not capture SwiftUI's text. `open --env NAME=VALUE` passes
  the switch; remove the code afterwards.
- **`open -a APP symlink` hands the app the link's target**: an expansion "next to the archive" went to `~/Scratch`.
  Give the app a hard link (same volume) or a copy in the scratch directory.
- **Automatic grammar agreement (`^[\(n) item](inflect: true)`) isn't applied by `String(localized:)`** for an app
  with no String Catalog: the markup came out as written (in tests, and it's what VoiceOver's value would read).
  Use two keys ("1 item", "%lld items") until a catalog carries plural variations.
- **Rates: `Int64.formatted(.byteCount(style: .file).locale(…))` plus a localized "\(amount)/s"**. Foundation has no
  data-rate format style (macOS 27 SDK: `Measurement` has no information-per-time dimension). Other locales put a
  no-break space (U+00A0, or U+202F in French) before the unit: tests spell it out.
- **`#expect(try localFunction(…) == x)` inside a closure failed to compile** ("errors thrown from here are not
  handled", Swift Testing in Xcode 27.2) where `#expect(try Data(contentsOf:) == x)` beside it compiled: bind the
  result with `let` first.
- **A user-facing string held in a `String` property is never localized** (`Text(string)` is verbatim): computed
  titles and captions are `LocalizedStringResource`s (on the feature's state, so tests read them with
  `String(localized:)`), AppKit's take `String(localized:)`.
- **Split a row by what the poll timer changes**: with the icon lookup in the same `body` as the polled progress,
  `NSWorkspace.icon(forFile:)` ran 4 times a second per row; as views of their own (icon by URL; progress by store),
  the counts over a 10 s expansion were icon 1, row 1, list 1, progress 39.
- **An xcodebuild failure can hide behind `| tail`**: `./build.sh … | tail -3` exits 0 with a stale app in place
  (the measurement then ran the old binary). Read build.sh's first line (`exit N`) before using the product.
- **`SWIFT_STRICT_MEMORY_SAFETY = YES` in an app target with TCA26's macros** produced no warnings of the macros'
  own: only the app's two C calls needed `unsafe`. It's on for Nunarchiver, so the "every `unsafe` has its reason"
  rule is checked there too.

## Every zip method in Swift (2026-11-22, M1 Max)

NativeZipArchive's RESULTS.md step17, Bytes' RESULTS.md.

- **A whole-output decoder becomes a streaming one by its window, not its loop.** LZMA and xz kept their decode loops
  and got a flat window that slides the dictionary to its front (within 0.1–0.8% of the whole decode); bzip2 decodes a
  block into its workspace and makes only the run expansion resumable (+0.2–0.5%). Split input costs nothing when the
  careful path near the input's end decodes each symbol first without effect, then for real.
- **A per-symbol bounds check can become an output limit computed per round**: when each iteration reads at most k
  bits per byte it writes, a limit on output guarantees the input. DEFLATE's decode loop: −8 to −11% instructions,
  with named `BitField` reads of table entries instead of range subscripts worth 3–5% of that.
- **Instructions aren't the cost for range coders**: Bytes' xz runs 7.6% more instructions than Compression's liblzma
  and finishes 29% sooner. The trade was memory: a window of the dictionary plus as much room (16 MiB for 8 MiB),
  against a circular one.
- **A quarantined terminal app makes every file this session creates carry `com.apple.provenance`** (iTerm installed
  by Homebrew Cask: its descendants are provenance-tracked, and the kernel owns the attribute, so `xattr -d` and
  `setxattr` silently do nothing). Tests comparing extended attributes must ignore it; `ditto -c` then writes a `._NAME`
  for every symbolic link, and `aa extract` run from such a session writes a fresh `com.apple.quarantine` instead of the
  archive's. A `launchctl submit` job runs untracked when a clean reference is needed.
- **Checked helpers in a loop whose bounds are proven per round cost 12–20 instructions a match.** DEFLATE's fast loop
  on locals with unchecked refills, stores, and its own match copy (libdeflate's design, the round's proof in comments):
  −36 to −39% instructions, below libdeflate's, but only −4 to −7% cycles (the loop is latency- and
  misprediction-bound). Weigh instruction wins against `Tools/counters`.
- **Codegen traps met there:** an `@inline(__always)` throwing helper taking an `inout MutableRawSpan` stayed a call in
  a large loop (`@inline(always)` inlined it: −10% → −35%); an `inout` span's base address is reloaded before every
  store (rebind it to a local); constants the loop keeps in registers are rematerialized after every call in it (a
  division's magic number: use shifts, keep rare cases' constants off the loop); table entries with flags beat a kind
  field (one `tbnz` per decision); a failed vector check should skip to the failing lane, not step a byte.
- **Fewer instructions can be slower for range coders:** LZMA's branchless matched-literal coder runs 1.14x liblzma's
  instructions on x-ray (mostly matched literals) and 20% fewer cycles. A cheaper index formula: −1.7% instructions,
  +0.8% cycles; not kept.
- **Bytes' `Pipeline` didn't fit decrypt-then-decode** (ZipDecoder's encrypted entries): +2–3% instructions, because the
  second stage is driven only through `transform` (DEFLATE loses its decode-into-the-output-buffers path), an encrypted
  LZMA header must be decrypted before the format is known, and an in-place stage can only follow another stage. The
  hand-written pump stays.
- **Read-ahead (`F_RDADVISE`) cut cold-cache read stalls ~60% and changed no wall time** (decoding dominates). For a cold
  cache per run, read an APFS clone (`cp -c`): its page cache is its own.
- **`#expect` can't read a `~Copyable` value's property**: bind it to a `let` first. `URL.resolvingSymlinksInPath()`
  drops `/private` from `/private/var/…`: use `realpath`. Nunarchiver's `project.xcproj` has trailing commas (jq can't
  parse it): edit it by hand. Without the team's certificate, `./build.sh … CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=` builds and tests ad hoc.
- **Baseline names are shared with the repository**: `ab-old-*`/`ab-new-*` are tracked in several packages, and
  `baseline update` overwrites them silently. Name a session's baselines after the work (`zipnative-old-1`), and check
  `git status` for modified `results.json` files after a run.
- **Attribute every allocation with LLDB when Instruments' callers are truncated.** Breakpoints on `swift_slowAlloc`,
  `malloc`, `malloc_type_malloc`, `calloc`, `realloc` with `bt 14; continue`, on the `-debuggable` release binary, then
  group stops by the first frame in your own code (drop a `malloc` stop whose frame #1 is `swift_slowAlloc`: the same
  allocation). 7,000 stops took 40 s. A condition (`-c '$x0 > 1000000'`) lists the large ones. NativeAEA/RESULTS.md,
  2026-11-22 evening. Why Instruments wasn't enough: its stacks are full (4–85 frames), but the `<Call stack limit
  reached>` rows are allocations made before it attached (all at time 0, one placeholder frame), and the only
  per-allocation table `xctrace export` gives (`Allocations List`) holds live allocations only: anything freed, such as a
  per-segment box, never appears there, only in the Statistics counts. `discardEventsForFreedMemory` is already false.
- **Malloc stack logging is a run-time switch, and its full mode changes what it measures.** `MallocStackLogging=1` is
  lite mode now (live allocations only, like `leaks --atExit`). `MallocStackLoggingNoCompact=1` (full) records every
  event with its stack, and `malloc_history PID -allEvents` prints them while the process lives (stopped at `exit`
  under LLDB: `Tools/allocations --history` does it): every allocation of a 6 s extraction in 8 s. But in full
  mode libobjc gives every autorelease pool push a fresh 4 KiB page, and Swift Concurrency pushes one per job run on
  Darwin: 42,148 page allocations that a normal run doesn't make (LLDB without stack logging: 44,695 pushes, 31 pages,
  no `malloc_zone_memalign`; Instruments: 2). Use full mode for stacks; count with breakpoints or Instruments.
  LLDB's `platform shell` runs its command without a shell (a `>` reaches the program as an argument): `platform
  shell -- /bin/sh -c "…"`. `malloc_history` takes a process name as well as a PID.
- **A local `var` pointer assigned in branches and borrowed by spans was heap-boxed**: `var stored:
  UnsafeRawBufferPointer` in `SegmentStream.decode`, one 32-byte `swift_allocObject` per segment (find the size and the
  call with `disassemble`). Constants, each set once on every path (`let x: T; if … { x = … } else { x = … }`), need no
  box. `Tools/calls … --callee swift_allocObject` on hot functions catches it statically.

## The second cleanup pass (2026-11-22, late)

Disk/RESULTS.md, NativeAEA/RESULTS.md, Bytes' RESULTS.md.

- **Narrowing a module's public surface by usage:** list its public symbols from a symbol graph (`swift build --target
  T -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc /abs/dir`, then jq on `accessLevel`), and look
  for each name in the other packages' and the app's sources: a name that appears nowhere can't be used there (`package`
  if the package's own tests, benchmarks, or support products name it, `internal` otherwise). Initializers, enum
  cases (they take their enum's access), and types used only implicitly (`options.permissions = .exact` names no type)
  need the compiler: change the rest, build every client, and revert what it rejects. Disk: 26 symbols to `package`,
  12 to `internal`, one dead method removed; six types stayed public for implicit uses.
- **The Edit tool drops trailing whitespace from its strings**: replacing `options.writerThreads = ` with
  `options.disk.writers = ` produced `options.disk.writers =threads` in 18 places (a build error each). End a
  replacement at a non-space character; grep the diff for `[a-z)] =[^ =]` after a batch of edits.
- **zsh ties `path` to `PATH`**: `while read … path …` in a zsh loop emptied `PATH`, and every command after it was "not
  found". Name the variable `symbol` or `file`.
- **`ManagedBuffer` is explicitly not `Sendable`**: a subclass declaring `@unchecked Sendable` warns ("inherits an
  unavailable Sendable conformance"). For one allocation holding atomics (`RelaxedCounters`), keep the subclass internal
  and wrap it in an `@unchecked Sendable` struct.
- **Range coders, again: take the latency off the chain, even at more instructions.** LZMA's matched literal forms the
  next step's four candidate probability indexes two bits ahead and selects between them by the bit (the loads start
  one select after it): x-ray −1.8% cycles alone. Choosing a tree's child by the comparison (`one ? node1 : node0`)
  rather than from the borrow: −1.8 to −3.5% on four Silesia files, mechanism unknown. Together −1.8 to −4.1% cycles
  on every file at +5 to +10% instructions. Every branchless normalization tried cost more than its mispredictions
  saved (+4 to +12% on x-ray). The agent's driver measured cycles per byte with `proc_pid_rusage` around each decode.
- **`bench-table` prints 3 significant digits**: too coarse for checks within 0.3%. Read exact p50s from an unslimmed
  `results.json`'s histograms before slimming, or compare codegen (identical object code settles it).
- **Check a claim about manifests before acting on it**: MQTT's and SocketStream's libraries never enabled
  `NonisolatedNonsendingByDefault`, so their tests "lacking" it matched; only NativeAEA's and NativeZip's test and
  benchmark targets did, and now have it.
- **A nearly full volume inflates kernel-heavy rows.** At 98% full, every 32 MB extraction read +5% instructions (kernel
  allocation) and a parallel row ran 3–5x slower, which looked like a regression of the change under test; an
  interleaved control showed it in both trees, and freeing 20 GB removed it. Check `Tools/disk-space` before believing a
  file-system row, and remove scratch trees (copies of the repository with `.build`s are 2–5 GB each) when they're merged.
  `df` counts only blocks free now, not purgeable space the system frees on demand: on 2026-11-24 it said 98% full (17.7
  GB) while Finder, and macOS's "available for important use", said 274.8 GB. Judge whether a large write fits by the
  available figure; "free now" is what the kernel sees at once.

## HTTP/1 heads against cursed-http (2026-11-23)

HTTPBytes/RESULTS.md.

- **A loop of `@inline(always)` code can outgrow the inliner's caller limit**, and then ordinary functions stay calls
  in it: HTTPBytes' parse loop called `RawSpan.byteCount` (a two-instruction function) three times per field, each call
  clobbering the vector registers the loop kept tables in. Moving a once-per-head scan out of line fixed it (−16% on
  short fields). After forcing inlining, grep the hot function's disassembly for `bl` to trivial getters.
- **Fewer instructions on the critical path can be slower**: cursed-http's mask packing (`ld4`, then shift-right-inserts:
  5 instructions for 64 bytes) lost 5–16% cycles to plain loads and a weighted `addp` sum (9) where each block's mask
  gates the next line; `ld4` is 0.5 a cycle (`Tools/cpu-probe insn ld4`). Batching masks ahead to avoid a branch per
  block also lost, twice: classifying past a short head's end, and lines longer than the window tested again.
- **A differential against the previous code catches what tests don't**: the old parser compiled as a second module in
  the measuring harness, events and errors compared on corpus heads and their mutations, whole and fed in pieces under
  several option sets (1.6 M inputs in 9 s). It found a scan that skipped a block on its first run.

## HTTPBytes as a whole (2026-11-23)

HTTPBytes/RESULTS.md, WRITEUP.md.

- **A benchmark that sums results measures failures.** The first HTTP/1 baseline read 3.4x picohttpparser because a head
  limit checked against the whole remaining buffer failed most heads at once, and the row summed results. Every setup
  now checks every item succeeded (`everyHead`), never a total.
- **Prototype the scanning strategy before the API.** Three throwaway parsers on the real corpus (per-line
  `firstByteOffset`, a 64-byte structural index, picohttpparser) decided the design in an hour: the per-line scans ran
  fewer instructions and more cycles (short scans mispredict). Judge parsers by cycles and mispredicts, not
  instructions.
- **A `static let` `InlineArray` can't back an immortal span**: reading it may produce a temporary copy, and a span
  overridden to `immortal` then points at dead stack (the last field names read as garbage). Use a `StaticString`
  literal (constant data in the binary) for bytes that spans borrow forever.
- **A `var` pointer assigned in branches and borrowed by a span is heap-boxed again** (QPACK's literal decode: one
  allocation per field, 5.2 M → 2.5 M instructions as `let`s): the lesson from NativeAEA's `SegmentStream`, met anew. A
  zero-malloc gate caught it; check new decoders with `Tools/calls … --callee swift_allocObject`.
- **Import other implementations' test suites as differential tests, with a table of deliberate differences**: llhttp's
  markdown suite, Go's net/http, h11, httparse, http-parser, picohttpparser, cursed-http's extractor, HTTP Garden,
  PortSwigger's DesyncBox permutations, h2o's fuzz corpus. They found 11 real gaps (raw UTF-8 targets, empty
  `Transfer-Encoding`, chunk-extension grammar and limits, CONNECT with a body, CL+TE persistence, `100-continue` in
  HTTP/1.0, HTTP/1.2). A `differences` entry that stops differing, or a `withKnownIssue` that stops recording, fails the
  test, so the tables stay exact.
- **An adversarial review agent given the code, not the conclusions, finds what tests don't**: two reviews found 15
  confirmed defects (HTTP/2-to-HTTP/1 CR LF injection through an unchecked store append, `Content-Length: ,` slipping
  past CL+TE checks, unbounded trailers and leading empty lines, a dropped QPACK Section Acknowledgment that would
  freeze the peer's table, quadratic re-scans when input arrives a byte at a time). Probe packages that reproduce each
  finding become regression tests.
- **Every incremental parser needs a "fed a byte at a time" test with a time limit**: four separate quadratic re-scans
  (HTTP/1 partial lines, chunk trailers, QPACK encoder-stream literals, a stacked content decoder's stalled middle
  buffer, which looped forever) passed every correctness test.
- **Strictness costs real traffic**: RFC 3986 request-target validation rejected 52 of 401 real browser requests
  (Facebook's `?filter[0]=`: raw brackets in a query) and cost 15–69%: it's an option, off by default. Measure a
  validator against real corpora before making it the default.
- **Benchmark packages separate from the library** keep C references, NIO, and swift-http-types out of the library's
  build; when the C references change, delete the stale `CReferences-*.pcm` under the benchmark package's
  `SwiftExplicitPrecompiledModules` if the build can't find new symbols.
- **A simulated peer must be consistent with itself** (QPACK, 2026-11-23; HTTPBytes/RESULTS.md): a check that decoded
  each section after 16 sections' encoder stream failed an encoder whose acknowledgments arrived 4 sections late, and
  rightly: an acknowledgment says the peer has decoded the section, so the encoder may evict its entries after it. Deliver
  late only as far as the feedback says. And break the code on purpose once (here: evictions ignoring unacknowledged
  sections, one blocked stream too many) to see the harness fail.

## HTTPBytes round 2 (2026-11-23)

HTTPBytes/RESULTS.md "round 2".

- **A pipeline ends when its last stage ends: a framing stage must not be followed by one that can end first.**
  `dechunker.then(gzipDecoder)` finished a body at the gzip stream's end, leaving the chunked body's last bytes (or an
  attacker's request inside it) to be read as the next message. Decode framing and coding in one stage that ends where
  the framing ends and requires the coded stream to end there (`HTTPBodyDecoder`).
- **Don't give a hot loop a second exit or a new call to test an idea**: `farStop` with "after 3 blocks, try skip windows"
  became nested duplicated loops (85 instructions with calls against 29), and adding a call to it left
  `RawSpan.byteCount` an out-of-line call. Cap the loop's bound instead (`min(count - 64, block + 128)`) and call the new
  path after the loop.
- **A public generic function over `some Sequence` that isn't `@inlinable` runs unspecialized and boxes its iterator**:
  `HTTPContentCoding.negotiated` allocated 6 times a call. `Tools/calls` on the caller shows `specialized` when it isn't.
- **A case-insensitive comparison against a `StaticString` that folds only one side is a trap for callers**:
  `isScheme("Basic")` never matched (the literal must be lowercase). Public helpers taking a caller's literal fold both
  sides; the one-sided overload asserts its literal is lowercase.
- **Merging into bounded storage: sweep, don't insert in arrival order.** Ranges merged as they came needed more slots
  on the way than in the end (`3-5, 25-41, 4-`); re-reading the set for the lowest uncovered range needs only the answer's
  slots. Test such code against a plain unbounded reference at every storage size.

## Zstandard encoding (2026-11-23)

BytesCompression/Benchmarks/RESULTS-zstd-encoder.md.

- **Port a reference encoder decision for decision, and its frames become the test oracle**: whole-frame comparison
  found each porting slip at its first differing byte (a repeat-offset limit, libzstd's RLE check on blocks it stores
  raw). libzstd shrinks the window and tables to a known content size even with every parameter set
  (`ZSTD_adjustCParams_internal`): a port must too.
- **LLVM turns `a == b && valid` into a branch on `valid` ahead of the loads** (also from `(a ^ b) | invalid == 0`):
  libzstd's cmov candidate check became an unpredictable branch, +18–31% cycles where many table entries are stale
  (small windows, the HTTP window). `unlikely(a == b) && valid` kept the comparison first: `csel`, `cmp`, `ccmp`, one
  branch.
- **`Builtin.int_prefetch_RawPointer(p._rawValue, rw, locality, cache)` emits `prfm`** (modules with the Builtin
  feature): libzstd's prefetches took 2.5–8% off level 1's cycles (dickens, mozilla); level 3 didn't move.

## One-shot reuse and gzip members (2026-11-23)

Bytes' RESULTS.md.

- **A format of concatenated streams (gzip members, zstd frames, xz and bzip2 streams) needs a new stream to start with
  no history in every API**: decoding into the caller's buffer, the earlier stream's output sits right before it, so a
  corrupt match reaches it silently (and its trailer can be made to match). Cut the output span at the stream's start
  (`_mutatingExtracting(start...)`): the loop's `distance <= out` check then rejects it at no cost. Compare members
  against the same data as one stream with a full flush at each boundary: smaller members are slower for any decoder
  (no history, a new dynamic block), and only the difference is the members' cost.
- **Every whole-buffer call starts a new stream as `reset()` would**, keeping the memory: a reused decoder or encoder
  answering the same input differently (nothing, or a precondition) was the survey's bug. Reset lazily where the reset
  isn't free (the DEFLATE encoder's two hash tables: only when already used).

## The survey's bugs (2026-11-23)

Disk/RESULTS.md, ARCHITECTURE.md §8.

- **Close where the use ends, and make every test check it.** No RAII: owners have `close()` (Disk's `Destination`,
  `InputFile`, `OutputFile`; NativeAEA's archives) and `deinit` only audits (`DescriptorAudit`, per task). Bytes'
  `LifetimeChecks` trait (`.diskLifetimes` in Disk's, NativeZip's, and NativeAEA's suites) fails a test that drops a
  descriptor or leaves a file open under its `TemporaryDirectory`s (`OpenFiles`, `proc_pidinfo`). A descriptor several
  threads read is closed by an atomic exchange to -1, so a late reader gets `EBADF`, never a reused number.
- **A shared fixture made lazily inside a test is charged to that test**: make its directory with
  `TemporaryDirectory.$lifetimeRecord.withValue(nil)` (NativeAEA's `SharedFixtures.make`).
- **Reach rare failure paths by injecting them, then break the fix once to see the test fail.** Disk's `Sys` wrappers
  take task-local failures in debug builds (`SyscallFaults`: a call kind and its `errno`) and record opens and closes;
  the double-close test failed all three checks against the old code. Check the injection fired (`injected > 0`): two
  of nine kinds never ran in the first extraction tried.
- **A truncated mapping faults on FAT and exFAT, not on APFS or HFS+** (`SIGBUS` on 675 of 676 pages of an exFAT image;
  original bytes on APFS, cold pages too). Probe file-system behaviour on `hdiutil` images (`-fs ExFAT`, `MS-DOS`,
  `HFS+`; no sudo). An APFS clone is no cheap private copy to read: its page cache is its own (a cached gigabyte through
  a fresh clone, 1.5 s against 46 ms).
- **Compose typed errors instead of boxing them**: a protocol's `associatedtype Failure: Error = Never`, an
  `EntryError<Failure>` of `.disk`/`.source`, and an operation error with a case per origin. Where a closure's type
  can't carry the source's failure (the plan closure), throw a "stopped" case and let the operation's error carry the
  real one. An enum's static method can't share a case's name (`fromDisk`, not `disk`).
- **The Edit tool's trailing-space trap, again**: `replace_all` of `@Suite struct ` gave `@Suite(.x) structName` in 15
  suites. After a batch edit, grep for the glued form (`struct[A-Z]`, `=try`).
- **Xcode's derived data can hand a package target a stale module**: Nunarchiver's build gave DiskTestSupport a
  `Products/Debug/Disk.swiftmodule` from the day before ("cannot find 'DescriptorAudit'"), and its tests a stale
  `BytesCompression.swiftmodule`: NativeZip compiled against the old layout, and the test process died freeing a
  decoder's workspace (`pointer being freed was not allocated`, in `GrowableWorkspace.deinit`). Xcode no longer wrote
  those files (it builds `-t` variants elsewhere) but its module map still preferred them. When an app build disagrees
  with `swift build`, compare `ls -lT …/Build/Products/Debug/*.swiftmodule` dates with the sources' and remove the stale
  ones. Also: Xcode's builds didn't give DiskTestSupport Disk's `package` symbols; SPI (`@_spi(Testing) public`)
  works in both.
- **`storeBytes(repeating:count:as:)` and typed views require the start aligned for the type**; a `UniqueArray<T>` or
  `[T]` promises only `T`'s alignment. Storing `SIMD8<Int16>` groups into a `UniqueArray<Int16>` worked only because
  `malloc` returns 16-byte blocks (a probe at offset 2 traps in debug; release is undefined). Check the address once,
  or type the storage by its store stride. Unaligned `storeBytes(of:toByteOffset:as:)` is always safe but its bounds
  checks didn't fold (8 instructions per 16 bytes against 3).
- **An app composes its packages' errors too**: Nunarchiver's `ExpansionError` (`.credential`, `.failure`, `.zip`,
  `.appleArchive`, `.disk`, `.cancelled`) replaced `any Error` and a message-suffix test for a wrong key
  (`AEAError.incorrectKey` now); the outcome is decided by case.

## One codec layer (2026-11-23, latest)

BytesCompression/RESULTS.md, ARCHITECTURE.md.

- **A shared engine with a per-client hook costs nothing when it's generic over the hook and inlinable.** NativeAEA's
  two parallel decoders became BytesCompressionAsync's `ParallelBlockDecoder<Stage>` (`@inlinable`, state
  `@usableFromInline`): `Tools/calls` on the client shows only `specialized ParallelBlockDecoder.*`, no
  `swift_getGenericMetadata`, the stage called as `specialized BlockStage.decode`; instructions equal. Errors cross it
  typed: the client's failure type conforms to a protocol that makes it from the engine's own error.
- **A pump that needs more input returns `.needsInput` and resumes the same chunk**, rather than taking a refill
  closure: ZIP's decryption stayed in NativeZip, and every decode row stayed equal.
- **An engine over an upstream source doesn't run the upstream**; its maker does (NativeAEA's payload runs both). A test
  that drained only the downstream hung at 0% CPU, with no thread in the stacks (`sample`): suspended tasks, not threads.

## Input conversions (2026-11-23, stage 3)

NativeZipArchive/Benchmarks/RESULTS.md, NativeAEA/RESULTS.md, BytesCompression/RESULTS.md.

- **Bound every size and offset where it's parsed, and still saturate its sums.** Below 2^62 a value converts to `Int`
  and adds to one other (an offset plus leading bytes), but four of them overflow a total: NativeZip's expected bytes, an
  Apple Archive header's blob total, and Disk's progress totals across archives all trapped on values each bounded alone.
  Bound the running total as each value (`count < (1 << 62) - total`), or saturate (`addingReportingOverflow`).
- **A size from a header is a claim: believe it only as far as the input can expand.** A Zstandard frame's content size
  made an array of 2^62 bytes (an abort in `malloc`) before a block was read; no stream decodes to more than its blocks'
  largest ratio (Zstandard: 128 KiB per 4-byte RLE block, 32,768×). Reserve from claims with a cap (AppleDouble: 64 KiB).
- **Confirm a reported trap by disabling its fix once**: the new test then aborts or traps (signal 5 or 6), which a
  `swift test --filter` of that one test shows without taking down the others.
- **Byte-splat fills are `memset` already**: `-1` in `Int` and `0xFF` in `UInt8` compile to `memset` calls; only patterns
  that aren't a repeated byte (LZMA's `UInt16` 0x0400) loop an element at a time. Fill those in 16-byte groups on storage
  the owner sizes and aligns by its group (LZMA's `LZMAWorkspace`), not on a pointer whose type promises less.
- **A defaulted associated value changes construction, not patterns**: after `case zstd(maximumWindowSize: Int = …)`,
  `.zstd` must be written `.zstd()` where a value is made; `case .zstd:` still matches.

## The fix plan (2026-11-24)

`Writeups/BytesCompression-Fix-Plan-2026-11-23.md`, each package's RESULTS.md.

- **Review a fix plan adversarially against the code before implementing it.** The first draft would have corrupted
  output silently (a Zstandard size hint shrinking the window's memory but not the window matches may use: the decoder
  wraps at its allocation), asserted on attacker-controlled sizes (a stored ZIP entry's two sizes aren't tied), and
  refused archives Apple's own tools write (a 64 MiB attribute limit; `aa` round-trips 80 MB). A reviewer given the plan
  and the files found all three, with probes.
- **For concatenating formats, a stream's end with input still to come is tentative.** gzip, Zstandard, and xz report
  `.finished` only with all their input consumed; bzip2 also with 1–3 bytes left. Staged input ending exactly at a
  stream's end (a ZipCrypto entry's frame filling the staging buffer) dropped the rest silently. Track whether the input
  has ended, and make "the caller added nothing" mean only that (not also "the buffer is full").
- **A header parsed all-or-nothing makes the whole header the streaming unit and trickled input quadratic.** Brotli's
  meta-block header (up to 189 KB crafted) and bzip2's tables were re-read from their start each call; `Pipeline`
  trapped on valid Brotli with 1–2 KB buffers. Commit each part (a prefix code, a table) as it completes: units fell to
  451 and 1,324 bytes. Retrying only when the held bytes double was rejected: an interactive stream that flushes and
  waits for a reply would deadlock.
- **A stop without a failure must still wake whatever waits on what it ends.** `stop(nil)` passed `nil` upstream, and
  the upstream's only consumer (a `pbz` producer mid-block) waited forever. When work is claimed in index order,
  failures in block order cost only a limit at the failing index.
- **A liveness minimum counts what the consumer holds while it waits**, not only the workers: Disk's planner keeps up
  to 4 pieces until a 64 KiB chunk completes, so a pool of 3 small segments deadlocked (before any budget). Break each
  part of a sizing rule once to see which one liveness depends on (the writers' share wasn't).
- **Speculative parallel work spends a shared budget in time order**: segments decoding from guessed splits overlap, so
  running out must fail the segment locally (its region decoded again in place), never the call.
- **Size defaults that bound hostile input by the machine**: a flat 1 GiB buffer budget would have cut Xcode's decoders
  on 32 cores; a flat 2 GiB left 128 MiB segments at 2.0 GB on 10. 64 MiB per core (at least 1 GiB) keeps real archives'
  counts everywhere.
- **A closure type with an unsafe-pointer parameter makes every use of the enum holding it unsafe**: capture the
  specialized loop (a producer method) rather than the stage's `read(at:into:)`.
- **Parallel agents on one package**: a COW clone (`cp -cR`, then remove its `.build`s) let one agent change a package's
  decoders while another changed the same package's async engine in the main tree; merge by copying the clone's files
  after checking main's copies are older than the clone.

## Small inputs and making coders (2026-11-24, fix plan C)

BytesCompression/RESULTS.md.

- **Type a table by its store stride**: BytesCompression's `StrideTable<Group: SIMD>` allocates whole groups at a 64-byte
  boundary, so a group fill can't be misaligned and needs no run-time check. Step a pointer in fill loops, not an offset:
  stores post-index (`str q0, [x9], #16`, 3 instructions a 16-byte group), and a 64-byte group's `stp` pair, which has no
  register-offset form, loses its address `add` (6 → 4 instructions).
- **Making a coder touched every page it allocated**: `UniqueArray(repeating: 0, count:)` for windows, staging, and
  command lists that are written before they're read. Allocated uninitialized (`UninitializedBuffer`), a Brotli encoder
  made for a 64-byte stream went from 816 K to 75 K instructions (its 4 MB window is never used one-shot). Zero only what's
  read before it's written; test with `MallocPreScribble=1 MallocScribble=1` (fresh memory 0xAA) and compare output.
- **A separate allocation is one more pointer live in a hot loop**: LZBITMAP's hash table moved out of its workspace
  (where it was the base) ran 1.8% more instructions on large inputs, with or without the change it was moved for. Keep
  hot regions in one allocation off one base.
- **Loop strength reduction can split `x + (k − c)` into one loop invariant per k**: biasing LZBITMAP's eight inserts by
  −8 made eight invariants that spilled. A value stepped as its own (16-bit) induction variable kept immediates.
  `Builtin.freeze_Int64` exists (`import Builtin`) but InstCombine drops a freeze of a value that can't be poison.
- **`bfi` is destructive**: a store of a loop-carried register's value through `bfi` costs a `mov` first (+1 instruction,
  no cycles: the move is eliminated at rename). Measure cycles before chasing it.
- **A clear the tests don't notice can still be the one that matters**: DEFLATE's 3-byte heads are read only for inputs
  under 512 bytes (minimum match 3), so leaving them uncleared passed every test until one encoded a short stream after a
  long one (then an index out of bounds). Test resets with short streams after long ones.

## Making decoders, one-shot spellings, limits (2026-11-24, fix plan E1)

BytesCompression/RESULTS.md.

- **Profile construction before guessing**: a probe package that makes a coder in a loop, under `Tools/profile`. Zeroing
  was bzip2's cost (7.8 MB), but Brotli's was computing a 704-entry table (79%), DEFLATE's building its fixed tables
  (over 90%), LZRAVEN's filling its model a `UInt16` at a time. Constant tables: a literal, or built once in a lazy
  `static let` and copied in (one `swift_once` check per coder).
- **The global-table lesson again**: Brotli's fast loop reading the literal command table (a global array) instead of the
  decoder's copy ran 1.1–1.7% more instructions on every decode row. Copy constants into the coder's own storage. Its
  literal context map as an `UninitializedBuffer` rather than a `UniqueArray` cost another 0.4% on the q11 rows
  (mechanism not chased): a construction change that touches a hot loop's storage type needs the decode rows too.
- **Uninitialized needs a proof per region, including reads whose values are unused**: bzip2's segment copy loaded the
  next page's link after a segment's last piece (a page that may not be full, so never linked); harmless while zeroed,
  a read of unwritten memory after. Restructure such loads rather than argue them away.
- **`MallocPreScribble=1` alone left fresh aligned allocations zero** in a probe (Swift's `allocate(byteCount:alignment:
  64)`, 64 B to 8 MB); with `MallocScribble=1` too they read 0xAA. Set both, and check a probe reads 0xAA first.
- **A lazily made buffer is one more malloc**: a window allocated on first use (an empty placeholder, then the real one)
  took HTTPBytes' per-body decoders from 4 to 5 mallocs for 1–2 K instructions saved; uninitialized memory costs nothing
  until touched, so allocate it eagerly.

## Masked tables, word loads, and narrowing (2026-11-24, E2)

BytesCompression/RESULTS.md, Bytes' and HTTPBytes' RESULTS.md.

- **A masked table is free only where the optimizer still sees the index's range.** Bytes' `MaskedTable` (`index & mask`)
  replaced span checks and hand masks at −2 to −9% in DEFLATE's chained parsers, but a run-time mask (Zstandard's hash
  log) cost +1–5% even in registers, and per-array masks cost HPACK/QPACK's encoder index 0.2–0.8% (one load each where
  one shared mask served six arrays). State a fixed table's count once (`precondition(table.count == 1 << 16)`): the
  stored mask becomes a constant. And InstCombine merges masks across a shift: `((h & 0x7FFF) << 1) & 0xFFFF` became
  `(h << 1) & 0xFFFE`, which no longer folds into a loop-carried hash's phi (+5% at DEFLATE level 1); keep such bucket
  arithmetic on a span with the count stated.
- **A SIMD type's stride isn't always its lanes**: `SIMD3<Int32>` is 16 bytes, and `SIMD3(repeating: 5)` is
  `[5, 5, 5, 0]` in memory, so a fill that stores whole groups zeroes every fourth entry. A check that the stride divides
  the line let it through; `MaskedTable.fill(_:groupedAs:)` also requires `stride == scalarCount × element stride` (a
  constant, folded). Its exit test first read the entry back and `fatalError`ed on a wrong value, which made the test
  pass without the fix too: an exit test's body must exit cleanly unless the check under test traps.
- **A noncopyable table passed `inout` through a large function has its base reloaded per use** (LZFSE's search, +1.2%),
  as `inout` spans do: bind `var lines = table.mutableSpan` once at the top, state its count, and pass the span.
- **A "no-op" refactor needs every specialization compared, not the hot loop**: `Tools/loops` saw nothing, but a
  per-function instruction count over the whole object (objdump, then a diff) found XXH64 +3 (a helper taking an
  `InlineArray` stripe by value loaded it into vector registers and moved lanes out) and one of Zstandard's 16 match
  finders +1 (the same load through a shared helper, even `@inline(always)`, moved its register allocation). Diff all
  functions' sizes before and after; keep a client on its own helper when it moves.
- **Narrowing traps:** symbol graphs' `location.position.line` is 0-based; a text search for a type's initializer misses
  calls through the client's typealiases (`SegmentStream(stage:)` is `ParallelBlockDecoder.init`), and generic
  arguments between name and parenthesis; a public enum case's default argument can't name a `package` type (write
  the value, and test the two agree); a public type's conformance to a public protocol keeps its witnesses public; and
  `package import Bytes` makes Bytes' types `package` in that file ("its result uses a package type").
- **The Edit tool's trailing-space trap, a third time**: `replace_all` of `    public ` with `    package ` glued 80
  declarations (`packagevar`, `packageinit`). Replace `public` alone where the context is unique, or end the strings
  at the keyword (`public var` → `package var`).

## The archive-coverage set (2026-11-24)

NativeAEA/RESULTS.md, NativeZipArchive/Benchmarks/RESULTS.md.

- **Foundation's file APIs decompose names** (`Data.write(to:)`, `FileManager.moveItem`, `createFile(atPath:)` pass
  paths through `fileSystemRepresentation`): a test meaning to make an NFC name made an NFD one. Make names whose
  bytes matter with `open`/`rename` (a Swift `String` passed as a C string keeps its bytes), and compare paths by
  `utf8`: Swift's `==` treats NFC and NFD as equal. Python's `os.setxattr`/`listxattr`/`getxattr` are Linux-only;
  generators call Darwin's through `ctypes`.
- **`aa archive` of an APFS-compressed file records `FLG` `UF_COMPRESSED` and no `AFT`**; `aa extract` compresses it
  again with its default codec, NativeAEA stores it plain. `ditto --hfsCompression` on one volume clones rather than
  compresses: make compressed fixtures with `aa extract -afsc CODEC -afsc-all`.
- **`ditto -x -k` reads Info-ZIP's times as local time with today's daylight-saving offset** (an hour late for
  September times read in November), and sets directories' times before their files (only directories of
  directories keep theirs). A reference manifest from it depends on where and when it was made: compute such
  differences in the test rather than listing them.
- **`aa extract` with several threads resolves colliding names differently run to run**: reference extractions of
  case-colliding archives use `-t 1 -wt 1`.
- **`aa extract` of a profile 0 `.aea` needs `-sign-pub`** (the keys derive from it; without it "Main key derivation
  failed"): take the leaf's key from the archive's certificate chain (`openssl x509 -pubkey`). And **`xip --expand`
  keeps the archived times only of directories holding nothing but directories** (1,874 of Xcode 27.3 beta 2's), as
  Archive Utility does. The conformance check found both; NativeAEA matched `aa extract` on all 167,541 items.
- **Check a generator's determinism by running it twice into two directories and comparing the manifests' items**
  (the `.aar` bytes matched too; `aea` and `ditto` archives don't, by keys and stored times).

## Giving memory back, and positions past 2^32 (2026-11-25)

BytesCompression/RESULTS.md ("Memory given back"); probes in `~/Scratch/release-memory.noindex/`.

- **Freeing a large malloc block doesn't lower the footprint.** A touched 96 MiB block, freed, stayed in
  `ri_phys_footprint` (four of them: 385 MB), after 1.5 s and after `malloc_zone_pressure_relief` (which released 0):
  malloc keeps freed large blocks for reuse. `munmap` of an `mmap`ed block lowers it at once. So "drop the decoder" and
  "free the window" released nothing until BytesCompression mapped its allocations of 9 MiB or more (just above HTTP's
  windows, which are made per message and want malloc's reuse; 16 MiB missed `xz -6`'s 12 MiB window).
- **A test's large input may not make the large allocation**: xz records each block's size, so a 6 MiB stream with a
  16 MiB dictionary got a 6 MiB window (under the threshold), and the footprint test failed for its premise, not the code.
  A temporary in-process test printing the numbers found it; an exit test's `observing: [\.standardErrorContent]` gave
  back nothing on failure here.
- **`madvise` give-backs aren't free, and they outlive `free`.** `MADV_FREE_REUSABLE` then `MADV_FREE_REUSE` cost
  about 220 µs per 8 MB (about 430 ns a 16 KiB page), touched or not: too much after every stream. And a block freed
  while reusable came back from malloc with its pages still reusable (touching them didn't count toward the footprint):
  `REUSE` before freeing, or never mix advice with malloc's memory. `RawStorage` does `REUSE` before every reuse.
- **Measure footprint in an exit test** (`#expect(processExitsWith: .success) { … precondition(drop >= …) }`): the
  child process runs only that body, so parallel tests can't move the number. Break the fix once: with the mapping
  turned off, the test trapped (`DecompressorTests.releaseMemoryGivesALargeWindowBack`).
- **A hand-made zstd frame is the cheapest large window**: no content size, window descriptor exponent 15 (32 MiB),
  then 300 RLE blocks of 128 KiB: nine bytes of header and 4 bytes a block, decoded with `memset`s even in debug.
- **Check whether a wrap is a bug before "fixing" it.** Brotli's encoder keeps table positions as `UInt32`, and every
  comparison is a wrapping difference (`absolute &- entry`): exact for anything a window apart, and an aliased stale
  entry still names a position inside the window whose bytes are compared. A libzstd-style correction was written and
  reverted (it only added code to the hot path); a hook that starts positions just below 2^32 and a 4.5 GiB bulk stream
  test the wrap instead.
- **A Homebrew upgrade can break builds and benchmarks that link it.** zstd 1.5.7 → 1.6.0 left SwiftPM's `CZstd-*.pcm`
  stale ("file … has been modified since the module file … was built": delete the `.pcm`s under
  `.build/out/Intermediates.noindex/SwiftExplicitPrecompiledModules/`), and every benchmark building the libzstd reference
  trapped on its `ZSTD_versionNumber() == 10507` precondition. A crash report in `~/Library/Logs/DiagnosticReports/`
  names the failing frame when package-benchmark only says "error code [5]". Pin what the comparison needs (identical
  frames, checked per setup), not a version: 1.6.0 made the same frames with 2–18% fewer instructions, which is worth
  knowing rather than refusing to measure. Keep the reference's *inputs* fixed (cached frames) so its versions compare.
