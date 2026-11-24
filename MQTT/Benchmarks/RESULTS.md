# MQTT performance log

Medians (p50) from `swift package --disable-sandbox benchmark`, M3 Ultra (24 performance and 8 efficiency
cores), macOS 27.2, Swift 6.4.2. Single-core times vary about ±10% from run to run. Fixtures:

- 10,000 QoS 1 PUBLISH packets (~1.25 MB): ~32-byte topics, a 64-byte payload, and two properties
  (message expiry and a user property);
- a 10,000-packet session-like mix of every packet type.

One core parses the same 1.25 MB again and again, from cache. All 32 cores each parse their own copies
(4 per core, 128 in all, 100–150 MB, beyond every cache) and report the machine's total throughput. Numbers
are M3 Ultra unless a heading says otherwise; the 2026-11-19 section runs the same benchmarks on an M1 Max.

## 2026-11-23: `MQTTError.detail` as a `String`, tried and reverted (baselines `safe-bytes-before` → `safe-bytes-after`, `safe-bytes-control`, M1 Max)

The unsafe-code survey listed `MQTTError`'s `==` and `hash(into:)` (`StaticString.withUTF8Buffer`, the package's last two
`unsafe` lines but one) as free with `detail: String`: string literals are immortal, so making an error allocates nothing,
and the synthesized `Hashable` does the rest. Measured under load (instruction counts are the evidence): encoding PUBLISH
+1.2% (5,132 → 5,194 K), parsing +0.2 to +0.5%, frames −0.3%, no allocations either way. A control run with the
`StaticString` restored and the same Bytes (`safe-bytes-control`) matched `safe-bytes-before` on every row, so the cost
is the `String` itself: every throwing helper takes its detail as a `String`, and those calls grew. Reverted; the comment
at `==` still says why it's unsafe.

## 2026-11-22: Bytes' cleanups, as a control (baselines `unify-old-{1,2}` → `unify-new-{1,2}`, M1 Max)

The whole suite, two interleaved rounds against HEAD (5f28068), after Bytes' writers gained preconditions
(`IntegerFields`, `ConvertibleFromBytes`), `ByteGroup.withBytes`, `includingPrefix:` on prefixed reads, and
`[UInt8].append(_:as:_:)`. No MQTT code changed. Every row's instructions are within 0.1% in both rounds, mallocs
unchanged.

## 2026-11-19: the same suite on an M1 Max (baselines `d2-final` → `m1max`)

Every benchmark, run unchanged on a new machine and compared with the M3 Ultra's `d2-final` (2026-11-18). The
existing M3 numbers aren't touched.

| | M3 Ultra | M1 Max |
|---|---|---|
| Cores | 24 P + 8 E (32 threads in the all-core runs) | 8 P + 2 E (10 threads) |
| P-core clock (max) | ~4.05 GHz | ~3.23 GHz (the M3's is 1.25x) |
| Memory | 256 GB LPDDR5-6400, 819 GB/s | 64 GB LPDDR5-6400, 400 GB/s |
| P-cluster L2 | not measured | 12 MB |
| OS, toolchain | macOS 27.2, Swift 6.4.4 (Xcode 27.3) | macOS 27.2.1, Swift 6.4.4 (Xcode 27.3, same compiler) |

- **Method:** `swift package --disable-sandbox benchmark baseline update m1max --no-progress`, one package at a
  time, nothing else benchmarking. `corespotlightd` used about one core of the M1 Max during the Bytes runs (it
  couldn't be stopped); single-thread medians weren't noticeably affected there.
- **Reading the tables:** the ratio is **M1 Max time / M3 Ultra time**, so above 1 is slower and 1.25 is the clock
  ratio alone. Packet rates are 10,000 packets over the median time (one core), or `copyCount × 10,000` over it
  (all-core runs: 128 copies on the M3, 40 on the M1 Max, since a copy count is 4 per thread). Median times
  from 10 ms are rounded to two digits (the conventional and copying all-core rows): ±5% there.
- **Scope:** the suite parses and encodes PUBLISH packets and parses one session-like mix of every type; there are no
  other per-type benchmarks, so that is all this section can compare. The all-core runs' names include the thread
  count (`, 32 cores` and `, 10 cores`), so they don't pair by name; they're compared by packet rate below.

### Headline

**Geometric mean of M1 Max time / M3 Ultra time over the 10 single-core benchmarks: 1.34** (range 1.15–1.68; the
allocation-free parsers alone, n = 5: 1.20; the two PUBLISH encoders 1.64; the three allocating workloads 1.42).
Instructions per iteration are the same on both machines in all 10 (identical in the recorded digits), so these
are hardware ratios. The all-core runs' instructions per copy agree within 0.3% (5.14 M against 5.15 M per
PUBLISH encode copy, for instance), except the conventional parse, −1.5%, where the M3's total is recorded as
"11 G", two digits.

### One core

| Benchmark (10,000 packets, 1 core) | M3 Ultra | M1 Max | Ratio | M packets/s (M3 → M1) | Instructions | Mallocs |
|---|---|---|---|---|---|---|
| Parse PUBLISH: Bytes views | 392 µs | 496 µs | 1.27x | 25.5 → 20.2 | 9.80 M | 0 |
| Parse PUBLISH: Bytes views, properties not iterated | 358 µs | 410 µs | 1.15x | 27.9 → 24.4 | 7.93 M | 0 |
| Parse PUBLISH: frames, MQTTPublish(parsing:) | 350 µs | 415 µs | 1.19x | 28.6 → 24.1 | 8.83 M | 0 |
| Parse PUBLISH: frames, properties visited while parsing | 281 µs | 333 µs | 1.19x | 35.6 → 30.0 | 7.37 M | 0 |
| Parse PUBLISH: Bytes views, copying topic, payload, and strings | 1,391 µs | 1,882 µs | 1.35x | 7.2 → 5.3 | 33 M | 20,000 |
| Parse PUBLISH: conventional (`[UInt8]` indexes, owned values) | 3,389 µs | 4,833 µs | 1.43x | 3.0 → 2.1 | 85 M | 40,000 |
| Parse mixed stream: Bytes views | 258 µs | 313 µs | 1.21x | 38.8 → 31.9 | 4.69 M | 0 |
| Encode PUBLISH: Bytes writer | 220 µs | 352 µs | 1.60x | 45.5 → 28.4 | 5.13 M | 0 |
| Encode PUBLISH: `MQTTPublish.write(to:)` | 215 µs | 362 µs | 1.68x | 46.5 → 27.6 | 5.13 M | 0 |
| Encode PUBLISH: conventional (`[UInt8]` appends) | 2,826 µs | 4,190 µs | 1.48x | 3.5 → 2.4 | 62 M | 30,000 |

### All cores (the machine's total throughput, from memory)

| Benchmark | M packets/s, 32 threads → 10 threads | M3 / M1 Max total | Per thread (M3 → M1 Max) | Speed-up over 1 core (M3 of 32 → M1 Max of 10) |
|---|---|---|---|---|
| Parse PUBLISH: Bytes views | 567 → 153 | 3.71x | 17.7 → 15.3 | 22.2x → 7.6x |
| Parse PUBLISH: Bytes views, properties not iterated | 645 → 183 | 3.52x | 20.1 → 18.3 | 23.1x → 7.5x |
| Parse PUBLISH: frames, MQTTPublish(parsing:) | 659 → 182 | 3.63x | 20.6 → 18.2 | 23.1x → 7.5x |
| Parse PUBLISH: frames, properties visited while parsing | 840 → 221 | 3.80x | 26.2 → 22.1 | 23.6x → 7.4x |
| Parse PUBLISH: Bytes views, copying topic, payload, and strings | 71 → 29 | 2.49x | 2.2 → 2.9 | 9.9x → 5.4x |
| Parse PUBLISH: conventional (`[UInt8]` indexes, owned values) | 30 → 13 | 2.36x | 1.0 → 1.3 | 10.3x → 6.2x |
| Parse mixed stream: Bytes views | 882 → 237 | 3.72x | 27.5 → 23.7 | 22.7x → 7.4x |
| Encode PUBLISH: Bytes writer | 692 → 152 | 4.54x | 21.6 → 15.2 | 15.2x → 5.4x |
| Encode PUBLISH: `MQTTPublish.write(to:)` | 695 → 149 | 4.67x | 21.7 → 14.9 | 14.9x → 5.4x |
| Encode PUBLISH: conventional (`[UInt8]` appends) | 34 → 11 | 2.95x | 1.1 → 1.1 | 9.5x → 4.8x |

Speed-up is `copies × single-core time / all-core time`: the number of cores' worth of single-core work done.

### The views against the conventional code

Reference time / Bytes time, M3 → M1 Max (`d2-final`'s code, so the M3 figures differ from the older "5.5x and 5.9x"
in `Current`, which predates much of the work above):

| Comparison | 1 core | All cores |
|---|---|---|
| Conventional parse / views parse (every field and property) | 8.6x → 9.7x | 18.6x → 11.8x |
| Conventional parse / views parse (properties not iterated) | 9.5x → 11.8x | 21.1x → 14.2x |
| Copying parse / views parse | 3.5x → 3.8x | 8.0x → 5.3x |
| Conventional encode / `BytesWriter` encode | 12.8x → 11.9x | 20.5x → 13.3x |

- **The views and the writer beat the conventional code by about an order of magnitude on one core on both machines.**
  The M1 Max widens the parse gap (8.6x → 9.7x) and narrows the encode gap (12.8x → 11.9x), which follows from
  the encoders' 1.60x against the conventional encoder's 1.48x.
- **On all cores the gap is smaller on the M1 Max** (18.6x → 11.8x parse, 20.5x → 13.3x encode): the allocating code
  gets 4.8–6.2x of a core's work out of 10 threads, against 9.5–10.3x out of 32, while the allocation-free parsers get 7.4–7.6x and 22–24x.
  Per thread, the allocating workloads are as fast or faster on the M1 Max (1.3 against 1.0 M packets/s for the
  conventional parse).

### Allocations

- All 7 `Allocations:*` benchmarks count 0 mallocs on both machines (the zero thresholds in `Thresholds/` hold).
- The single-core allocating workloads count the same on both: 20,000 (copying parse, 2 per packet), 40,000
  (conventional parse, 4) and 30,000 (conventional encode, 3). Per copy, the all-core rows agree (20,000 per
  copy for the copying parse, and so on).
- The all-core runs of the allocation-free workloads count 35 mallocs on the M3 (32 threads) and 13 on the M1 Max
  (10 threads): `DispatchQueue.concurrentPerform`'s, not parsing's (as the *Allocation checks* section says for 35); how
  the count depends on the thread count is not investigated.

### Observations

Measured:

- **Allocation-free parsing costs 1.15–1.27x the M3's time**: four of the five rows are under the 1.25 clock ratio
  (1.15–1.21x, the mixed stream 1.21x); the views with every property are 1.27x. The allocating parses are
  1.35x (copying) and 1.43x (conventional).
- **Encoding is the outlier at 1.60x and 1.68x**, with the same 5.13 M instructions: 22.0 → 35.2 ns per packet. The M3
  executes 23.3 instructions per ns there and the M1 Max 14.6 (parsing the views: 25.0 against 19.8). Dividing by the maximum
  clocks assumed above, 5.8 against 4.5 instructions per clock for encoding, against 6.2 and 6.1 for parsing the views.
  The conventional encoder, 1.48x, is also above the clock ratio.
- **The M3's whole-machine advantage is 3.5–3.8x for allocation-free parsing**, 4.5–4.7x for encoding and 2.4–3.0x for the
  allocating code. For parsing, that is near the P-core count ratio (24/8 = 3) times the clock ratio (1.25), 3.75;
  the all-core runs also use the E-cores, 8 against 2.
- **Encoding scales worst among the allocation-free workloads on both machines**: 15x of 32 threads and 5.4x of 10,
  against 22–24x and 7.4–7.6x for parsing.

Interpretation, not investigated:

- Why encoding loses 1.60–1.68x against 1.25x of clock: no counters (`Tools/counters`) were run. The encoder
  is store-heavy (writes into a buffer), and the M1 Max's lower rate on it might be about stores, but that is a
  guess; the Base64 encoder, also store-heavy, lost only 1.19–1.22x at large sizes.
- The weaker scaling of encoding may be write traffic to memory (the encoders write into `encodeBuffers`, 128 or 40
  copies of the stream, 100–150 MB on the M3); not measured.
- The allocating workloads' better per-thread rate on the M1 Max is consistent with less allocator contention at 10
  threads than at 32 (the `Current` section attributes the conventional code's poor scaling to the allocator), but
  contention wasn't measured on either machine.

## 2026-11-17: named flags, big-endian cursors, properties parsed once (baselines `trk-t0` … `trk-final`, Swift 6.4.4)

- **Named flags** (`Flags.swift`: `ConnectFlags`, `PublishFlags`, …, Bytes' `BitFlag`/`BitField`): the same code as
  the bit numbers they replace. The enum field setter first cost PUBLISH encoding +0.8% (an assert and a mask);
  Bytes now checks the raw value and stores it unmasked: 5,132 K, as before.
- **`BigEndianBytesReader`/`BigEndianBytesWriter`** throughout (`read(UInt16.self)`, `write(sectionPrefixedBy:)`, no
  byte order at each call): identical instruction counts.
- **Properties parsed once:** `MQTTPublish(parsing:visitingProperties:)` hands each property to a closure as it's
  validated, where reading `properties` afterwards decodes them again. 10,000 PUBLISH frames with both properties
  used: **7,365 K against 8,831 K instructions (−16.6%)**, no allocations. The plain path has its own body: through
  an empty default closure it cost 2% (Xcode's compiler), and forcing that inline cost SocketStream's checker 10%
  (its PR toolchain).

## 2026-11-16: byte-aligned cursors (baselines `p4-generic` → `p4-aligned`)

MQTT now parses with `AlignedBytesReader` and writes with `AlignedBytesWriter`: the same API as before, with no
bit state, since every MQTT field is whole bytes. Its flag bits are read from a `Byte`, not from the stream.

| Benchmark | Change (instructions) |
|---|---|
| Encode PUBLISH | −6.1% (5,464 K → 5,132 K) |
| Parse PUBLISH, views | −0.9% |
| Parse PUBLISH, properties not iterated | −1.2% |
| Parse PUBLISH, frames | −1.0% |
| Parse PUBLISH, copying strings | −2.9% |
| Parse mixed stream | −1.8% |

Details: `../../Bytes/Benchmarks/RESULTS.md`, 2026-11-16 (byte-aligned cursors).

## 2026-11-10: Bytes' conveniences adopted (baselines `conv-old-*` → `conv-new-*`, then `conv-fix`, `conv-qos`)

- `readRemainingBytes()` for the payload, subscription list, topic filters, and reason codes (four
  `do`/`catch` blocks gone); `RawSpan.hasPrefix` for `$share/`; `Crumb(rawBitsOf:)`/`Nibble(rawBitsOf:)`
  for QoS, retain handling, and the packet type; `[UInt8](copying:)` in the tests and the copying benchmark.
- Static sizes: `MQTTSubscribe`/`MQTTUnsubscribe` parsing −46 instructions each, SUBACK 177 → 126,
  `isShared` 35 → 19, no function larger.

| Benchmark | Instructions | Time (rounds 1 / 2) |
|---|---|---|
| Parse PUBLISH: Bytes views, frames, properties not iterated, mixed stream | −0.5 to −0.6% | within noise |
| Parse PUBLISH: copying topic, payload, and strings | 33.63 → 39.52 M (+17.5%), then **33.60 M** | +18% / +18%, then level |
| Encode PUBLISH: Bytes writer, `MQTTPublish.write(to:)` | 5.464 → 5.494 M (+0.5%), then **5.461 M** | +3 to +5% / 0 to +4% |

Two regressions, both fixed:

- **The copying benchmark** used `[UInt8](copying:)` instead of `withUnsafeBytes { Array($0) }`, and
  Bytes' version allocated through the standard library's unspecialized
  `ContiguousArray._allocateBufferUninitialized`: about 590 instructions more per packet. Bytes now copies
  through `Array(UnsafeRawBufferPointer)` (see Bytes' RESULTS.md), and the benchmark is back to 33.60 M.
- **PUBLISH's flags** kept `Crumb(qos.rawValue)`, not `Crumb(rawBitsOf: qos)`: the checked initializer's
  range check lets the flags setter drop its mask, where `rawBitsOf` truncates with an `and` (3 instructions
  per packet). With it restored, encoding is 5.461 M, as before. The other `rawBitsOf` sites are
  unchanged in cost (CONNECT, the subscription options, the frame header).

Not adopted: `read(Byte.self).rawValue` in properties stays (the same load as `load(UInt8.self)`).
`located(_:)`: MQTT's errors say what was malformed, not where.

**Harness:** the benchmarks no longer time inside `scaledIterations` (the custom bandwidth and packet-rate
metrics are gone): bandwidth and packet rate are the framework's throughput (iterations per second) times
a workload's bytes and packets per iteration (1.25 MB and 10,000 packets on one core, 128 times that on
every core).

## 2026-11-09: inline span writes and one-check prefixed reads in Bytes (baselines `bcd-old-*` → `bcd-new-*`)

No MQTT source changed for the speed. Bytes' `write(_: RawSpan)` is now inlined: it was called three times
per PUBLISH (topic, properties, payload). And `read(bytesPrefixedBy:)`, under every UTF-8 string and
binary property, checks its length once. The tests and benchmark fixtures now build arrays with
`[UInt8](byteCapacity:) { writer in … }` and `append(byteCapacity:)` (setup only, not measured).

| Benchmark | Instructions per packet | Time (rounds 1 / 2) |
|---|---|---|
| Encode PUBLISH: `MQTTPublish.write(to:)` | 563 → 546 (−3.0%) | −8% / −8% |
| Encode PUBLISH: Bytes writer | 563 → 546 (−3.0%) | −11% / −9% |
| Parse PUBLISH: frames | 927 → 897 (−3.2%) | −2% / 0% |
| Parse PUBLISH: Bytes views | 1,023 → 993 (−2.9%) | +3% / −1% |
| Parse PUBLISH: properties not iterated | 826 → 808 (−2.2%) | +7% / +3% |
| Parse mixed stream | 491 → 480 (−2.3%) | −2% / +2% |

The encoders got faster; parse times are within this machine's run-to-run noise, the instruction counts
aren't. `MQTTPublish.write(to:)` grew from 364 to 427 instructions and `writeBody` from 127 to 294 (the
inlined copies).

## 2026-11-09: rollbacks with `position`/`rewind(to:)` (baselines `pos-old-*` → `pos-new-*`)

The five places that undo reads (`MQTTFrame.read`: incomplete, malformed, too large; `MQTTPacket.read`;
the topic-name error classification) saved `byteOffset` and restored it with `try! seek(toByteOffset:)`,
which can't fail but throws by signature. They now take `reader.position` and `rewind(to:)`, which doesn't
throw. `Tools/calls`: the 5 out-of-line `BytesReader.seek` calls and 5 `swift_unexpectedError` paths are
gone from `MQTTFrame.read`, `MQTTPacket.read`, and `readMQTTTopicName`.

| Benchmark | Instructions per packet | Time (rounds 1 / 2) |
|---|---|---|
| Parse PUBLISH: Bytes views | 1,030 → 1,023 (−0.7%) | −10% / −6% |
| Parse PUBLISH: frames | 931 → 927 (−0.4%) | −4% / −4% |
| Parse PUBLISH: properties not iterated | 835 → 826 (−1.1%) | −3% / −7% |
| Parse mixed stream | 495 → 491 (−0.8%) | −1% / −2% |
| Encode PUBLISH (unchanged code) | identical | +5% / +9% |

The encoders' identical instruction counts and +5–9% times set this run's noise; the parse times are
within it. The change is the instruction counts and the removed trap paths.

## 2026-11-09: minimal Variable Byte Integers from Bytes, and inline 64-byte copies (baselines `ab-old-*` → `ab-new-*`)

Two Bytes changes:

- `read(LEB128.self, maxByteCount: 4, requiringMinimal: true)` checks the shortest encoding
  [MQTT-1.5.5-1] in Bytes' decode loop. `readMQTTVariableByteInteger` (`atomically`, the read, then a
  comparison with `LEB128.byteCount(of:)`) is now that one call; the property reader's
  `checked ? readMQTTVariableByteInteger() : read(LEB128…)` ternaries are `requiringMinimal: checked`; the
  property list's length-then-bytes is `read(bytesPrefixedBy: LEB128.self, maxByteCount: 4,
  requiringMinimal: true)`. The padded-encoding tests (remaining length, property length, property
  identifier) pass unchanged.
- `write(_: RawSpan)` copies up to 64 bytes inline instead of calling `memmove` above 32. No MQTT source
  changed for this; the fixtures' 64-byte payloads take that path (`Tools/calls`: the same out-of-line
  `BytesWriter.write(_:)` calls in both trees; the copy inside it changed).

Interleaved runs of the previous commit's tree and this one, two rounds (per packet: 10,000 packets per
iteration; instructions are exact minimums from the baselines):

| Benchmark | Instructions per packet | Time, round 1 / round 2 |
|---|---|---|
| Encode PUBLISH: `MQTTPublish.write(to:)` | 626 → 563 (−10.0%) | −14% / −14% |
| Encode PUBLISH: Bytes writer | 626 → 563 (−10.0%) | −10% / −13% |
| Parse PUBLISH: Bytes views | 1,052 → 1,030 (−2.1%) | +5% / +2% (noise: ±10% run to run) |
| Parse PUBLISH: frames, `MQTTPublish(parsing:)` | 953 → 931 (−2.3%) | +3% / −1% |
| Parse PUBLISH: properties not iterated | 857 → 835 (−2.6%) | +4% / +1% |
| Parse mixed stream | 503 → 495 (−1.6%) | −5% / +1% |
| Conventional encoder and parser (no Bytes) | unchanged | −5% to +3% |

## 2026-11-09: flag bytes read and written whole (baselines `before-modern` → `modern`)

Sub-byte fields that fill one byte are now read as one `Byte` and taken apart with Bytes' field
subscripts, and written by packing a `Byte` first, instead of a `read`/`write` per field:

- the fixed header (`header.highHalf`/`lowHalf`; written with `Byte(highHalf:lowHalf:)`);
- CONNECT's flags, CONNACK's flags, and the subscription options byte (`flags[bit: 7]`,
  `flags[Crumb.self, at: 3]`, settable for writing);
- `readMQTTVariableByteInteger` uses `atomically` instead of saving the offset and `try! seek`ing back;
- `ReasonCodeSet`/`PropertySet` test bits with `[bit:]` (identical code).

A byte-aligned `read(Nibble.self)`/`read(Bit.self)` takes Bytes' general bit path (offset, bit order,
two-byte window); a `Byte` read is one load. Instructions per function, release (`MQTT.o`):

| Function | Before | After |
|---|---|---|
| `MQTTFrame.read(from:maximumPacketSize:)` | 457 | 390 |
| `MQTTPublish.write(to:)` | 414 | 364 |
| `MQTTPacket.write(to:)` | 318 | 273 |
| `MQTTConnect.init(reading:)` / `writeBody(to:)` | 930 / 567 | 774 / 339 |
| `MQTTConnectAcknowledgement.init(reading:)` / `writeBody(to:)` | 231 / 183 | 208 / 150 |
| `MQTTSubscriptionOptions.init(reading:)` / `write(to:)` | 278 / 273 | 176 / 83 |
| `MQTTProperties.init(validating:allowing:repeatable:)` | 323 | 288 |

Benchmark instructions, one core (`before-modern` is the same code as `dispatch1`, rebuilt against the
current Bytes, which alone added 0.4–1.5%):

| Workload | `dispatch1` | `before-modern` | `modern` | |
|---|---|---|---|---|
| Encode PUBLISH (both encoders) | 6.70 M | 6.80 M | **6.26 M** | −7.9% |
| Parse PUBLISH: frames | 9.94 M | 10.0 M | **9.54 M** | −4.7% |
| Parse PUBLISH: views, properties not iterated | 8.98 M | 9.11 M | **8.58 M** | −5.9% |
| Parse PUBLISH: views, every property | 11 M | 11 M | 11 M | (reported in millions) |
| Parse mixed stream | 5.93 M | 5.96 M | **5.03 M** | −15.6% |

- **Times, re-verified by interleaving** (the old code, commit `eec4a92`, and the new, run alternately
  twice, one core): encoding and the PUBLISH parsers within ±4% of the old code, round by round; the mixed
  stream 4–5% faster. So the fewer instructions buy little time here: these loops are bound by load
  latency and branches, not instruction count. Absolute times on this day ran 8–10% above `dispatch1`'s
  for the old code too (machine state), so compare times only within one interleaved run.
- **Checked unchanged**: the vectorized loops (`Tools/loops`: the same 11 `vector128` loops, same
  sizes, in `MQTTPublish.init(reading:flags:)`, `MQTTSubscriptions.init(validating:)`, and
  `MQTTPacket.init(parsing:)`); runtime calls (`Tools/calls --callee
  'swift_retain|swift_release|swift_allocObject|outlined|swift_task_switch'`: identical); allocation
  thresholds pass; the fuzz test's counts are identical (accepted 18,636, failed 61,288, incomplete
  20,076).
- **Tried and reverted**: classifying a rejected topic name on a separate cursor over
  `remainingBytes`, instead of re-reading and seeking back: +42 instructions in
  `MQTTPublish.init(reading:flags:)` for a cold path.

## Current (baseline `validated`): every MQTT 5.0 receiver rule checked

### Throughput

| Workload | 1 core | 32 cores | Allocations per pass |
|---|---|---|---|
| Parse PUBLISH: views, every field and property | 1.9 GB/s, 14.8 M packets/s | **43 GB/s, 344 M packets/s** | 0 |
| Parse PUBLISH: views, properties not iterated | 2.1 GB/s, 17.1 M packets/s | 46 GB/s, 370 M packets/s | 0 |
| Parse PUBLISH: views, copying topic, payload, and strings | 0.73 GB/s, 5.8 M packets/s | 7.5 GB/s, 60 M packets/s | 20,000 |
| Parse PUBLISH: conventional (`[UInt8]` indexes, owned values) | 0.34 GB/s, 2.7 M packets/s | 4.0 GB/s, 32 M packets/s | 40,000 |
| Parse mixed stream: views | 0.88 GB/s, 24 M packets/s | 18 GB/s, 503 M packets/s | 0 |
| Encode PUBLISH: `BytesWriter` | 2.3 GB/s, 18.5 M packets/s | **45 GB/s, 359 M packets/s** | 0 |
| Encode PUBLISH: conventional (`[UInt8]` appends) | 0.39 GB/s, 3.1 M packets/s | 4.0 GB/s, 32 M packets/s | 30,000 |

All 32 cores, GB/s:

```
Parse, views, properties not iterated   ██████████████████████████████████████  46
Encode, BytesWriter                     █████████████████████████████████████   45
Parse, views                            ████████████████████████████████████    43
Parse mixed stream, views               ███████████████                         18
Parse, views + copies                   ██████                                  7.5
Parse, conventional                     ███                                     4.0
Encode, conventional                    ███                                     4.0
```

- **Against the conventional code**, the views parse 5.5x as fast and the writer encodes 5.9x as fast on one
  core. The gap doubles on all cores (11x), because the conventional code's 3–4 allocations per packet
  contend in the allocator; copying out of the views (2 allocations per packet) scales about as badly.
- **Packets, not bytes, are the unit of work.** Per-packet cost is 40–70 ns on one core: ~1,400
  instructions to parse a PUBLISH and ~970 to encode one, mostly field-by-field checks. The mixed stream
  has small packets, so it moves the most packets and the fewest bytes.
- **All 32 cores reach about 20x one core.** The workloads are compute-bound: 45 GB/s is about a fifth of
  the CPU's memory bandwidth (~240 GB/s, from the Bytes bandwidth benchmarks).

### What vectorizes

Checked in the release assembly of the benchmark binary.

- **Byte scans** (since `scan16`, below): a string's UTF-8 and its forbidden bytes (U+0000, and wildcards
  in topic names) are checked in one pass of NEON, 16 bytes per step with an overlapping last block, so a
  32-byte topic takes 2 steps of 9 vector instructions, inlined into `MQTTPublish(reading:)`. ASCII
  strings need nothing else; others are validated in full afterwards.
  - Before: SWAR, 8 bytes per step, after the standard library's UTF-8 validation (an out-of-line call),
    and a second scan for wildcards in topic names.
  - Plain byte loops vectorize 64 bytes at a time, which sends 16–48-byte strings through their scalar
    remainder.
  - With Swift 6.4, the standard library's lane comparisons (`.==`, `.>=`) compile a lane at a time and
    `SIMDMask` reductions (`any`, `pointwiseMin`) to out-of-line calls. Bytes' `ByteLanes` tests use only
    lanewise wrapping arithmetic and bitwise operations, which vectorize (Swift 6.5 vectorizes both).
- **UTF-8 validation**: the standard library's `UTF8Span(validating:)` (3.2 ns for 32 ASCII bytes).
- **Copies**:
  - When encoding, payloads, strings, and binary fields up to 32 bytes are copied inline with two
    overlapping loads and stores (`BytesWriter.write(_: RawSpan)`); longer ones call `memmove`.
  - When parsing nothing is copied: payloads and strings are spans of the input.
- **The rest is inherently sequential**: each packet is a chain of dependent fields (lengths decide where
  the next field starts), so a packet parses with scalar loads and branches. It parallelizes across
  packets and cores instead, as the table shows.

### What validation costs

Since v1, parsing rejects everything MQTT 5.0 requires a receiver to reject, and encoding refuses to
write a packet the parser would reject, before writing anything (`MQTTPacket.validate()`). The checks:

- which properties each packet may carry, duplicates, and forbidden values;
- minimal Variable Byte Integers;
- U+0000;
- topic names (wildcards, and empty without a Topic Alias) and topic filters (empty, No Local on a shared
  subscription);
- packet identifiers;
- reason codes for each packet type.

The cost, per PUBLISH:

| | v1 | validated | Per packet |
|---|---|---|---|
| Parse PUBLISH, every field and property | 676 µs, 15 M instructions | 677 µs, 14 M | ±0 |
| Parse PUBLISH, properties not iterated | 520 µs, 11 M | 588 µs, 12 M | +7 ns |
| Encode PUBLISH | 357 µs, 7.7 M | 544 µs, 9.7 M | +19 ns |

- **Parsing:**
  - Most checks are bit tests against literal masks.
  - Iterating properties no longer re-validates them (they're decoded unchecked after the list was
    checked once), which pays for the new checks when properties are read.
- **Encoding** pays mostly for scanning the topic, about 8 ns. The rest is checking each field against
  the packet type's rules.

## `MQTTPacket` out of the hot paths (baseline `scan16` → `dispatch1`)

`MQTTPacket` is 153 bytes (CONNECT, with its optional will, is the largest case), so it's built and returned
in memory, and each test of its case is a call to an outlined "get tag" function. Writing a packet tested
its case five times: `validateFields()`, `remainingLength`, `flags`, `type`, then the body. Parsing built it
inside `parse(type:flags:body:)` and wrapped it in an `Optional`.

- **Each packet type parses and writes itself.** `MQTTPublish(parsing: frame)`, `publish.write(to:)`, and
  the same for every type (the shared PUBACK–PUBCOMP and SUBACK/UNSUBACK shapes take the type:
  `write(to:as:)`). `MQTTPacket.write(to:)` tests its case once and calls them; `MQTTPacket(parsing:)`
  dispatches to them.
- **Framing is separate**: `MQTTFrame.read(from:)` reads and checks the fixed header and bounds the body.
  Dispatching on its `type` parses the packet types you expect without building the enum.
  `MQTTPacket.read(from:)` is now a frame and `MQTTPacket(parsing:)`.
- **Behavior change**: a reserved packet type or reserved flags now throw as soon as the fixed header
  arrives, as a packet over the maximum size already did, instead of once the whole packet has. In the
  fuzz test, 3,304 mutations that were incomplete now fail; the accepted ones are unchanged.

One core, p50:

| Workload | `scan16` | `dispatch1` | |
|---|---|---|---|
| Encode PUBLISH: `MQTTPacket.write(to:)` | 20.9 M packets/s, 9.5 M instructions | **35.2 M**, 6.7 M | +68% |
| Encode PUBLISH: `MQTTPublish.write(to:)` (new) | | 35.9 M, 6.7 M | |
| Parse PUBLISH: `MQTTPacket.read(from:)`, every field and property | 19.0 M, 11 M | 23.7 M, 11 M | +25% |
| Parse PUBLISH: frames, `MQTTPublish(parsing:)` (new) | | **30.0 M**, 9.9 M | +58% |
| Parse PUBLISH: `MQTTPacket.read`, properties not iterated | 24.4 M, 9.3 M | 28.7 M, 9.0 M | +18% |
| Parse mixed stream | 30.7 M, 6.3 M | 37.7 M, 5.9 M | +23% |

- **Writing through the enum now costs nothing**: one case test, then the same code as writing the packet
  type directly.
- **Parsing through the enum still costs 26%** against frames, about 9 ns per packet: building the enum in
  memory, returning it, and testing its case.
- **What didn't help**:
  - Inlining `MQTTPacket(parsing:)` into the caller, so the caller's case test meets the enum where it's
    built: 4–9% slower.
  - Wrapping each case of the switch in an immediately called closure: it doesn't compile, because a
    closure's result can't depend on a lifetime, so it can't return these `~Escapable` packets. The packet
    types' own functions are the per-case functions instead.
  - Declaring the packet types `BitwiseCopyable` (or `@frozen`): identical code. From another module, a
    `~Escapable` struct is still destroyed through its type metadata (an indirect call to a no-op), once
    per parsed PUBLISH; inside the MQTT module, the same destroy is a `ret`.

## 16-byte scans (baseline `safe-final2` → `scan16`)

Strings' checks moved to Bytes' `ByteLanes` scans. Parsing checks a string's UTF-8 and forbidden bytes in
one inline pass (`read(utf8PrefixedBy:_:excluding:)`), instead of the standard library's validation (an
out-of-line call) followed by an 8-byte SWAR scan, or two for topic names. Encoding's checks scan 16 bytes
per step. One core, p50:

| Workload | `safe-final2` | `scan16` | |
|---|---|---|---|
| Parse PUBLISH: views, every field and property | 15.1 M packets/s, 14 M instructions | **19.0 M**, 11 M | +26% |
| Parse PUBLISH: views, properties not iterated | 17.4 M, 12.3 M | **24.4 M**, 9.3 M | +40% |
| Parse PUBLISH: views, copying topic, payload, and strings | 6.1 M, 38 M | 6.8 M, 35 M | +12% |
| Parse mixed stream: views | 26.8 M, 7.3 M | 30.7 M, 6.3 M | +14% |
| Encode PUBLISH: `BytesWriter` | 18.8 M, 9.8 M | 20.9 M, 9.5 M | +11% |
| Parse PUBLISH: conventional (control: unchanged code) | 2.85 M | 2.96 M | +4% |

Each PUBLISH has three strings checked when parsed (the topic and the user property's name and value),
all ASCII: per packet, about 13 ns less to parse. The fuzz test's counts (accepted, rejected,
incomplete) are unchanged, and nothing allocates.

## Safe constructs and Bytes types (baseline `validated` → `safe-final2`)

- **The SWAR string scan** uses checked `RawSpan.load`s instead of unchecked ones: 0.6% more instructions
  encoding PUBLISH packets than unchecked (a wrapping `&+=` in its loop hid that the offset stays
  non-negative; with `+=`, half the checks' cost folded away), no difference in time.
- **Fewer integer escapes**, with Bytes' new field APIs: PUBLISH flags read as `flags[Crumb.self, at: 1]`
  and built with `[bit:]` and field setters, enums from fields with `init?(rawBits:)`, reason codes read
  and written `as: Byte.self`, the protocol version a `Byte`, property identifiers `Byte`s, and the
  `$share/` prefix compared as one `Byte7`.
- Against `validated`: encoding +1% instructions, mixed-stream parsing +2%, PUBLISH parsing equal; wall
  times equal or better.
- The remaining `unsafe` sites (UTF-8 validation skipped for already-validated strings, `StaticString`
  bytes in `MQTTError`'s `==`) have comments saying why.

## Allocation checks

The `Bytes` views and writer must not allocate. Each such workload is also registered as
`Allocations:<name>`, counting only allocations (`mallocCountTotal`, 10 iterations). `Thresholds/` holds a
static threshold of zero for each:

```sh
# Fails (nonzero exit) if any of them allocates.
swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:.*'
# After adding a workload: record its threshold.
swift package --disable-sandbox --allow-writing-to-package-directory benchmark thresholds update --filter 'Allocations:.*'
```

| Workload | Allocations |
|---|---|
| Parse PUBLISH: views, every field and property | 0 |
| Parse PUBLISH: views, properties not iterated | 0 |
| Parse mixed stream: views | 0 |
| Encode PUBLISH: `BytesWriter` into a preallocated buffer | 0 |

A planted allocation fails the check ("WORSE than the defined thresholds", exit 1).

Names have no spaces. Benchmark 1.38.1 writes threshold files with `_` for spaces but looks them up without
converting (ordo-one/benchmark#373).

The all-core runs show 35 allocations per pass, from `DispatchQueue.concurrentPerform`, not from parsing.

## v1: views, the Bytes writer, and a conventional comparison

10,000 packets, one core:

| Workload | Time | Instructions | Allocations |
|---|---|---|---|
| Parse PUBLISH: views | 676 µs (15 M packets/s, 1.8 GB/s) | 15 M | 0 |
| Parse PUBLISH: views, properties not iterated | 523 µs | 11 M | 0 |
| Parse PUBLISH: views, copying topic, payload, and strings | 1,634 µs | 38 M | 20 K |
| Parse PUBLISH: conventional (`[UInt8]` indexes, owned values) | 3,627 µs | 84 M | 40 K |
| Parse mixed stream: views | 335 µs | 6.3 M | 0 |
| Encode PUBLISH: `BytesWriter` | 358 µs | 7.8 M | 0 |
| Encode PUBLISH: conventional (`[UInt8]` appends) | 3,058 µs | 70 M | 30 K |

v1's mixed stream sent CONNECT with a Message Expiry Interval, which CONNECT may not carry; the validating
encoder refused it, and the fixture now uses a Session Expiry Interval instead.

The all-core encoders first ran at 1 GB/s, slower than one core: every core read the same global topic
strings, and `utf8Span` retained them, so the reference counts bounced between cores. Each copy now has its
own inputs.
