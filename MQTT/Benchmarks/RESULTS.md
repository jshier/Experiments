# MQTT performance log

Medians (p50) from `swift package --disable-sandbox benchmark`, M3 Ultra (24 performance and 8 efficiency
cores), macOS 27.2, Swift 6.4.2. Single-core times vary about ±10% from run to run. Fixtures:

- 10,000 QoS 1 PUBLISH packets (~1.25 MB): ~32-byte topics, a 64-byte payload, and two properties
  (message expiry and a user property);
- a 10,000-packet session-like mix of every packet type.

One core parses the same 1.25 MB again and again, from cache. All 32 cores each parse their own copies
(4 per core, 128 in all, 100–150 MB, beyond every cache) and report the machine's total throughput.

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

- **Byte scans**:
  - U+0000 in every string, and wildcards in topic names. These are SWAR, 8 bytes per step with an
    overlapping last word, so a 32-byte topic takes 4 steps; LLVM turns the loop into NEON for long
    strings (53 vector instructions in the specialized scan).
  - Plain byte loops vectorize 64 bytes at a time, which sends 16–48-byte strings through their scalar
    remainder.
  - Swift's `SIMDMask` reductions (`any`, `pointwiseMin`) compiled to out-of-line calls, and a `SIMD16`
    compare bit-cast to integers compiled to a lane-by-lane loop. Each was slower than the scalar code.
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
