# MQTT over a local socket: results

M3 Ultra (24 performance + 8 efficiency cores), macOS 27.2. The swiftlang/swift#91981 toolchain, build 2511
(Swift 6.5-dev), swift-platform-executors `bd74d56`, kqueue backend. Benchmarks: medians from
`../Tools/toolchain . -- swift package --disable-sandbox benchmark`, about 512 MB per connection per iteration (256 MB for the multi-connection runs).
Bandwidth counts every byte on the wire, MQTT headers included; the timing runs from the first listener to
the last receiver's end of stream. Every packet is checked on arrival. The package now also measures
compressed and TLS-encrypted streams through Bytes pipelines (2026-11-15 below).

## 2026-11-17: stitched ChaCha20-Poly1305 (baselines `trk-t0` → `trk-final`, Swift 6.4.4)

Bytes' ChaCha20-Poly1305 now interleaves Poly1305 with ChaCha20's rounds (`../Bytes/Benchmarks/RESULTS.md`,
2026-11-17). In-memory transfers, 64-byte payloads, µs:

| Workload | t0 | final | Change |
|---|---|---|---|
| Protect, TLS records | 1,162 | 715 | −38% |
| Unprotect, TLS records | 1,230 | 758 | −38% |
| Protect, brotli + TLS / deflate + TLS | 3,074 / 2,613 | 2,648 / 2,265 | −14 / −13% |
| Unprotect, brotli + TLS / deflate + TLS | 1,551 / 947 | 1,349 / 840 | −13 / −11% |

The packet code moved to `BigEndianBytesReader`/`BigEndianBytesWriter` and `ByteBuffer.receive` to Bytes' new
`BytesAsync` module, both unchanged in instructions. Check and encode times moved −9 and −10% between these runs
with unchanged instructions: drift.

## 2026-11-16: byte-aligned cursors (baseline `p4-aligned`)

The packet encoder and checker use Bytes' `AlignedBytesWriter` and `AlignedBytesReader`, as MQTT now does.

| Benchmark (in memory) | Change against `ss-new-2` |
|---|---|
| Encode 64 B packets | −1.2% (4,751 K → 4,694 K, below its earlier 4,735 K) |
| Check 64 B packets | −1.3% |
| Protect and unprotect | unchanged |

`ss-new-2` also predates Bytes' matching, bit-writing, and search changes (the 2026-11-16 section of that file). Details: `../Bytes/Benchmarks/RESULTS.md`.

## 2026-11-16: receive buffers are Bytes' `ByteBuffer` (baselines `ss-old-1`, `ss-new-1`, `ss-old-2`, `ss-new-2`)

`ReceiveBuffer` (a raw allocation with `copyMemory` compaction) and `PlainBuffer` (an array compacted a byte
at a time) are now `ByteBuffer`, from Bytes. So is the in-memory benchmark's third copy.
- **Socket reads** go through `ByteBuffer.receive`, which can suspend with its output span in place. The
  `read(from:)` extension in `ReceiveBuffer.swift` keeps the "packet larger than the buffer" precondition.
- **Pipeline output** into a reused array goes through `[UInt8].withOutputRawSpan`.

Unsafe code in `Sources` went from 9 sites to 1: copying a CryptoKit secret out.

Interleaved old/new runs, two rounds each:

| Benchmark | Instructions | Change |
|---|---|---|
| Unprotect 64 B packets, Brotli + TLS | 27 M → 26 M | −3.7% |
| Encode 64 B packets | 4,735 K → 4,751 K | +0.3% |
| Other in-memory rows | unchanged | |

- **Unprotect** is faster because the buffer moves a partial packet to the front only below half free; the
  old code moved it after every piece.
- **Encode** is code I didn't change; it compiled differently (291 instructions instead of 301 in its
  specialization). MQTT's own encode is identical with the new Bytes.
- **Allocations:** 0 throughout.
- **Transfers:** 1 KB plain, TLS, and deflate + TLS are within their run-to-run variation.

## 2026-11-15: where protected transfers spend their time

Why protected transfers run at 0.45–1 GB/s when plain ones reach the socket's ceiling. Measured with the
CLI (1 connection unless noted), `Tools/profile` per thread, and a scratch harness that times each stage
alone on the transfer's own stream (64 MB of batches, the same packets and telemetry payloads, built with the
same toolchain; best of 5).

Each stage alone, one core, GB/s of MQTT bytes:

| Stage | 64 B payloads | 1 KB | 16 KB |
|---|---|---|---|
| MQTT encode | 7.07 | 33.0 | 87.6 |
| DEFLATE level 1, Bytes (flushed per batch) | 0.55 | 0.69 | 1.19 |
| DEFLATE level 1, libdeflate (per batch) | 0.62 | 0.80 | 1.32 |
| Brotli quality 1, Bytes | 0.41 | 0.53 | 1.72 |
| Inflate, Bytes / libdeflate | 2.22 / 2.39 | 2.62 / 2.93 | 7.13 / 7.67 |
| TLS seal / open (ChaCha20-Poly1305) | 1.41 / 1.39 | 1.39 / 1.39 | 1.39 / 1.37 |
| memcpy | 61.5 | 59.2 | 60.2 |

- **The stages, not the pipeline, set the rate.** MQTT encoding (0.14 ns per byte at 64 B) and parsing cost
  less than the kernel's socket copy, so plain transfers reach the socket's ceiling. Sealing costs 0.71
  ns per byte, 5x the encoder, and DEFLATE level 1 costs 1.8 ns, 13x. Adding the stage costs per end
  predicts what the transfers measure. TLS at 64 B: sender encode 0.14 + seal 0.71 + `sendto` about 0.17
  ns/B, receiver about 0.37 + open 0.72, so about 0.9 GB/s predicted against 0.84–0.89 measured. DEFLATE +
  TLS at 64 B: sender 0.14 + 1.82 + 0.16 × 0.71 for sealing a sixth of the bytes, so 0.48 predicted
  against 0.45.
- **Profiles agree.** TLS, 16 KB: the sender thread is busy for the whole transfer: ChaCha20 47%, Poly1305
  29%, `sendto` 19%, `memmove` 3%. The receiver is about 90% busy: ChaCha20 51%, Poly1305 35%, `recvfrom`
  8%. DEFLATE + TLS, 64 B: the sender is fully busy, about 80% of it in the DEFLATE compressor (`parseFastest`
  34%, its inlined loads 17%, `extend` 13%, `writeSequences` 9%) and 3% in ChaCha20-Poly1305. The receiver
  is about 40% busy. Pipeline glue, executor work (`kevent` about 1%), and extra copies (`memmove` 1.7–3.2%)
  are small.
- **One connection is one core per end, and the stages run one after another on it.** Each sender encodes,
  compresses, seals, and writes on its own thread, so its rate is one over the sum of the stage costs.
  Across connections (64 B, `--packets 3000000`, one run each), GB/s:

  | Connections | plain | TLS | deflate + TLS |
  |---|---|---|---|
  | 1 | 2.81 | 0.89 | 0.46 |
  | 4 | 3.61 | 3.18 | 1.69 |
  | 8 | 3.20 | 4.57 | 3.17 |
  | 16 | 3.18 | 2.82 | 6.27 |

  DEFLATE + TLS scales almost linearly (13.6x at 16). Plain and TLS stop at the loopback ceiling for this
  write pattern, about 3–4.5 GB/s on the wire. With 16 connections, compressed transfers deliver twice the
  MQTT bytes of plain ones, because only a sixth of the bytes cross the socket.
- **ChaCha20-Poly1305 is two passes, each leaving half the core idle.** ChaCha20's 8-block double round is
  261 instructions (64 `add`, 64 `eor`, 48 `shl` + 48 `usra` for rotations by 12, 8, and 7, 16 `rev32`,
  and 18 spills: SIMD8 state fills all 32 registers). That is about 5.7 instructions per byte with the
  transposes, about 1.4 cycles per byte on four vector pipes, which is roughly what it measures. Poly1305
  then runs over the same bytes on the scalar multiplier, about 1 cycle per byte, while the vector pipes
  sit idle. Interleaving the two in one loop (as OpenSSL does) could approach the longer of the two, not
  their sum: perhaps 1.8–2.5 GB/s per core (estimate). Smaller wins: rotating by 8 with one `tbl` instead of
  `shl` + `usra` (16 instructions per double round), and fewer spills. AES-128-GCM, TLS 1.3's other
  required suite, runs at about 10 GB/s with the CPU's AES and PMULL instructions (CryptoKit, 1 MB). It would
  need those instructions through the C target, with ChaCha20 kept for the portable builds.
- **DEFLATE level 1 is near its algorithm's speed.** Bytes produces byte-identical output sizes to
  libdeflate and is 10–15% slower. Even libdeflate manages only 0.62 GB/s on this stream, so matching it would
  gain about 12%. Larger gains need DEFLATE split across cores, pigz-style: chunks compressed in parallel,
  each with the previous 32 KB as a preset dictionary, then joined with sync flushes into one standard
  stream. Otherwise a faster format between our own endpoints, which gives up web compatibility.
  Decompression is 4x faster than compression, so receivers idle.
- **The 16 KB payloads overstate compression.** Their 977-byte-stride telemetry windows overlap about 94%
  from one packet to the next, which is why DEFLATE reaches 3.5% and Brotli 1.1% there. The 64 B and 1 KB
  streams are the realistic ones.
- **What the design could change.** The pipeline runs synchronously on the connection's I/O task.
  Throughput per connection is therefore one core's rate for all stages together. TLS records are
  independent given their sequence numbers, and DEFLATE can be split as above. A pipeline stage that hands
  work to other cores, sealing records or compressing chunks in parallel and keeping their order, could lift
  one connection past one core's rate. Moving the `sendto` copy (19% of a TLS sender) off the sealing
  thread would save about that much.

## 2026-11-15: compressed and encrypted transfers (baseline `protected-1`)

The package was renamed from MQTTSocketStream to SocketStream (targets `SocketStream`, `socket-stream`;
older sections below use the old names), and it now also sends the MQTT stream through Bytes pipelines:
DEFLATE (level 1) or Brotli (quality 1) compression, TLS 1.3 records (ChaCha20-Poly1305), or both, with the
receiver undoing them. Medians, one connection, 256 MB per protected iteration, taken after the
ChaCha20-Poly1305 speedups (`Bytes/Benchmarks/RESULTS.md`, 2026-11-15). The earlier toolchain and
bandwidth definition apply.

Bandwidth, MB/s (`protected-1`):

| Payload | plain | TLS | deflate | deflate + TLS | brotli | brotli + TLS |
|---|---|---|---|---|---|---|
| 64 B | **3,411** | 840 | 516 | 493 | 386 | 350 |
| 1 KB | **6,299** | 1,003 | 628 | 601 | 499 | 464 |
| 16 KB | **7,359** | 1,036 | 1,121 | 1,133 | 1,570 | 1,549 |

The CLI's last run (`--runs 3`, before the ChaCha speedups) gave the compressed fractions of the original
bytes: 64 B payloads 16% (deflate) and 17% (brotli); 1 KB 14.5% and 15%; 16 KB 3.5% and 1.1%. TLS alone was
0.67, 0.73 and 0.76 GB/s there, against 0.84, 1.00 and 1.04 above.

In-memory per-packet costs (10,000 packets of 64 B per iteration; packets per second is iterations per
second times 10,000, from the baseline's throughput):

| Work | Instructions per 10,000 | Iterations/s | Packets/s |
|---|---|---|---|
| encode | 4.7 M | 5,767 | 57.7 M |
| check | 6.8 M | 4,403 | 44.0 M |
| protect (encode + compress + seal), TLS | 15 M | 973 | 9.7 M |
| protect, deflate + TLS | 44 M | 431 | 4.3 M |
| protect, brotli + TLS | 54 M | 317 | 3.2 M |
| unprotect (open + decompress + check), TLS | 17 M | 899 | 9.0 M |
| unprotect, deflate + TLS | 17 M | 1,199 | 12.0 M |
| unprotect, brotli + TLS | 44 M | 536 | 5.4 M |

Unprotecting deflate + TLS is cheaper than TLS alone because the opener has 16% of the bytes to open.

- What bounds each configuration: TLS alone sits at about 1 GB/s, the ChaCha20-Poly1305 rate on one
  connection (840 MB/s at 64 B, where per-packet work shows). The compressed configurations are bound by the
  sender's compressor (DEFLATE level 1, Brotli quality 1): slower than TLS alone for 64 B and 1 KB payloads
  (protecting 10,000 packets of 64 B takes 44 M instructions with deflate and 54 M with brotli, against 15 M
  for TLS alone), faster at 16 KB, where the stream shrinks to 3.5% (deflate) or 1.1% (brotli) of its size.
  Encryption adds 4–10% on top of compression (deflate
  516 → 493, 628 → 601; brotli 386 → 350, 499 → 464 at 64 B and 1 KB; at 16 KB there is no measurable cost).
- Plain transfers keep their ceiling (3.4 / 6.3 / 7.4 GB/s): none of this touches the plain path.
- Allocations: the new `Allocations:` thresholds are 0 for encode, check, and protect and unprotect with TLS,
  deflate + TLS, and brotli + TLS (6 new, 8 in all; every in-memory row measures 0 mallocs). The transfer's own
  setup allocates 325 times, the same for 100,000 and 1,000,000 packets.
- Payload change: plain transfers keep the fixed payload (a 256-byte cycle). With it, the compressors reduced
  the stream to about 1%, which measured nothing useful. Protected transfers take 977-byte-stride windows
  of about 1 MB of generated JSON telemetry (`Payloads.telemetry`).
- Receiver fix: the TLS opener alone never reports `.finished` (TLS records have no end of stream). The
  receiver treated `needsInput` at the end of the stream as "ended early" and threw; then the executors
  crashed with "A TCPConnection was destroyed without being closed". Now `needsInput` after the end means
  done (the decoders throw themselves if their input is incomplete), and both ends close their connection on
  error paths.
- The transfers found a DEFLATE encoder bug: after batch 100 (26 MB) the compressed stream went from 14% to
  62% of the input, because the position rebase compared with `==` and could be stepped over (details in
  `Bytes/Benchmarks/RESULTS.md`).
- Swift notes met: typed throws through `Array.withUnsafeMutableBytes` does not compile (it rethrows as
  `any Error`); `array.mutableSpan.withUnsafeMutableBytes` keeps the error type. A span of a class instance's
  stored array property is scoped to that access ("lifetime-dependent value escapes its scope"): bind the
  array to a local `let` first (a retain, no copy).

## 2026-11-09: MQTT's flag bytes read whole (baseline `frames` → `modern`)

Nothing changed here but the MQTT package under it, which now reads and writes its fixed header and flag
bytes as whole `Byte`s instead of field by field (its Benchmarks/RESULTS.md), and a debug-build fix (below).

| Per 10,000 packets, in memory | `frames` | `modern` | |
|---|---|---|---|
| Check 64 B payload packets: instructions | 8.60 M | **7.47 M** | −13% |
| Encode 64 B payload packets: instructions | 6.09 M | **5.68 M** | −7% |
| Allocations (`Allocations:` thresholds) | 0 | 0 | pass |
| Allocations per transfer (100 K and 1 M packets) | 120 | 120 | |

- **Transfer times, re-verified by interleaving** the old binary (commit `eec4a92`) and the new, five runs
  each, alternating (median, GB/s): 64 B on 1 connection 2.77 against 2.65, on 4 connections 4.55
  against 4.44, raw 16 KB on 4 connections 3.89 against 4.08. The ranges overlap in every case: equal
  within noise. Single runs vary ±20% (one raw 4-connection run measured +77% slower), so compare
  transfers only interleaved.
- **Executor hops** (`Tools/runtime-count`, one 64 B connection): `swift_task_switch` 55 for 20,000
  packets and 113 for 80,000, `swift_job_run` 16–17: as before.
- **SIMD** (`Tools/counters --mode simd_fp_unit_instructions`, 8.4 M packets of 64 B): receiver 0.58 G
  SIMD arithmetic and 0.11 G SIMD loads (69 and 13 per packet: the string scans and the topic compare);
  sender 0.47 G and 0.11 G (56 and 13), plus 0.06 G SIMD stores.
- **Profile** (`Tools/profile`, 64 B): sender `__sendto` 51%, `BytesWriter.write(_:)` 9%, `memmove` 6%,
  the topic scan 4%; receiver `__recvfrom` 26%, `read(utf8PrefixedBy:_:excluding:)` 14%,
  `MQTTPublish.init(reading:flags:)` 10%. Leaf names include inlined frames: `RawSpan._checkRange`
  (6% of the receiver) and a `ClosedRange` `contains` witness (3% of the sender) are inlined bounds checks
  and `switch` range cases, not calls (the binary has no stub calls to them). `outlined destroy of
  MQTTPublish` is about 2% per side, as below.
- **Debug builds** failed at `Transfer.encode`: `MQTTProperties(validating:
  Fixtures.propertyBytes.span.bytes)`, "lifetime-dependent value escapes its scope". A span of a global
  declared in another file is rejected when files compile separately (debug builds), and accepted with
  whole-module optimization (release builds), with Swift 6.4.2 and the PR toolchain alike: the global's
  addressor is only a declaration in the other file's compilation, so the lifetime checker can't see
  that it's a `let`. The fix binds the global to a local first (once per batch).

## Results

Baseline `frames`, against `nonsending-scan16` (allocations, scans, and concurrency, below) and
`initial` (before either):

| Workload | Bandwidth | Packets/s | `nonsending-scan16` | `initial` |
|---|---|---|---|---|
| 64 B payloads, 1 connection | 2.81 GB/s | **22.4 M** | 16.1 M | 13.6 M |
| 1 KB payloads, 1 connection | 6.35 GB/s | 5.8 M | 4.9 M (5.30 GB/s) | 4.6 M (5.01 GB/s) |
| **16 KB payloads, 1 connection** | **7.3 GB/s** | 444 K | 7.3 GB/s | 7.4 GB/s |
| 64 KB payloads, 1 connection | 6.1–7.2 GB/s | 93–110 K | 6.1–7.2 GB/s | 6.7 GB/s |
| Raw (no MQTT), 1 connection | 7.4–7.5 GB/s | | 7.5 GB/s | 7.3 GB/s |
| 64 B payloads, 2 / 4 / 8 connections | 4.3 / 4.4–4.9 / 3.7 GB/s | 34.3 / 34–39 / 29.7 M | 28.7 / 38–44 / 27.6 M | 17.4 / 19.2 / 25.3 M |
| 16 KB payloads, 2 / 4 connections | 5.9–6.5 / 4.1–4.5 GB/s | | 6.5 / 4.1 GB/s | 6.3 / 4.3 GB/s |
| Raw, 2 / 4 connections | 6.0–6.2 / 3.6–4.4 GB/s | | 6.2 / 4.4 GB/s | 5.9 / 4.1 GB/s |
| 1 KB, 4 connections: thread per task / shared pool | 4.3–4.7 / 4.2–4.8 GB/s | | | 4.45 / 4.20 GB/s |

Raw sends the same bytes in the same 256 KB writes whatever the payload size, so its one-connection figure
(measured with the 1 KB stream's bytes) applies to every row. Rows at loopback TCP's ceiling (16 KB and
up, and the multi-connection bandwidth rows) vary about ±10% from run to run; ranges are from repeated
runs.

**Large packets saturate the socket.** From 16 KB payloads, MQTT encoding and parsing run as fast as the raw
stream: 7.3–7.5 GB/s on one connection, the most loopback TCP carries on this machine. The payload is
copied once into the sender's batch and parsed in place (a `RawSpan` view) on the other side, so per byte
there's almost nothing to do.

**Small packets are bound by per-packet work**, now 45 ns per packet (was 73) with each end on its own
core. Each end alone, in memory on one core (`... in memory` benchmarks), checks 36.4 M or encodes 43.4 M
packets per second, 23–27 ns per packet; the rest is the kernel copying each packet in and out of the
socket, and the system calls. (Since 2026-11-10 those two benchmarks report the framework's throughput,
iterations per second, instead of timing inside the loop with a custom packet-rate metric: packets per
second is that times 10,000. The socket transfers still record the transfer's own timing, from the first
listener to the last end of stream, so starting executor threads isn't counted.)

**With more connections, small packets reach the kernel's ceiling.** 2 connections carry 34 M packets/s
(4.3 GB/s), and 4 carry 34–39 M (4.4–4.9 GB/s; 38–44 M before the enum work, in runs where raw TCP on 4
connections also measured higher, so not clearly a regression). Beyond that, loopback TCP itself declines
(the C probe's 8 pairs: 3.4 GB/s), and so does the MQTT stream: 8 connections carry 3.7 GB/s. Before this
work they were CPU-bound at 25 M packets/s.

## Skipping the `MQTTPacket` enum (`nonsending-scan16` → `frames`)

`MQTTPacket` is 153 bytes, built and returned in memory, and each test of its case is an out-of-line call.
A sample of the 64 B run had a tenth of both threads in that: "get tag" and "tag store" functions for it
and its `Optional`. On top of that, writing a packet tested its case five times. The MQTT package now
reads frames (`MQTTFrame`: a checked fixed header and its bounded body), and each packet type parses and
writes itself. Its Benchmarks/RESULTS.md has the details.

- **Receiver**: `PacketChecker` reads frames and parses each as `MQTTPublish(parsing: frame)`, with no
  enum. In memory, checking went from 21.2 to 36.4 M packets/s (+72%).
- **Sender**: `MQTTPublish(...).write(to:)`, with no enum. In memory, encoding went from 26.2 to 43.4 M
  packets/s (+65%). (`MQTTPacket.write(to:)` itself now tests its case once and is as fast.)
- 64 B on one connection: 16.1 → 22.4 M packets/s (+39%); 1 KB: +20%.
- Still no allocations per packet (the thresholds pass), and 120 per transfer.

## Per packet: no allocations, 16-byte scans, no executor hops

### Allocations: none per packet

- **Receiving**: `PacketChecker` parses frames as PUBLISH packets (`MQTTPublish(parsing:)`), views of the
  receive buffer, and checks each against topics it holds (one array of every topic's bytes, end to end).
  Before, the check read a global array of arrays per packet: no allocation, but a retain and release.
- **Sending**: `BytesWriter` encodes into the batch. Each topic is now a view of the same topic table;
  before, it was `String.utf8Span`, which isn't inlinable, so even a borrowed `String` was retained and
  released around the call. Neither end now touches a reference count per packet.
- **Checked**: `Allocations:Check_64_B_payload_packets` and `Allocations:Encode_64_B_payload_packets` count
  allocations over 10,000 packets against static thresholds of zero (`Thresholds/`):
  `../Tools/toolchain . -- swift package --disable-sandbox benchmark thresholds check --filter
  'Allocations:.*'` fails if either end allocates.
- **A transfer** makes 120–122 allocations (executors, sockets, buffers, tasks), the same for 100,000
  packets as for 1,000,000 (`Transfer allocations` benchmarks): none per packet, read, or write.
- The transfers themselves aren't measured with the malloc interposer that counts allocations: it cost
  large-packet transfers about 10% of their bandwidth.

### Vectorization: what touches the stream's bytes

| Bytes | How | Per 64 B-payload packet |
|---|---|---|
| Topic: UTF-8, wildcards, U+0000 | One pass, NEON, 16 bytes per step (Bytes' `ByteLanes`) | 2 steps |
| User property's name and value: UTF-8, U+0000 | The same pass | 1 step each |
| Topic compared with the one expected | NEON XOR, 16 bytes per step (`RawSpan.bytesEqual`) | 2 steps |
| Payload | Encoding: copied into the batch (`memmove`, NEON in libc; 32 bytes or less inline). Receiving: never touched, only its length | 1 copy |
| A partial packet left at the end of the receive buffer | `memmove` to the front, once the buffer is half full | under a packet, at most once per read |
| Headers, lengths, identifiers, properties | Scalar: each field's position depends on the one before | |

- **The string checks were three passes**: the standard library's UTF-8 validation (an out-of-line
  `_allASCII` and `validateUTF8`), then an 8-byte SWAR scan for U+0000, then another for wildcards in topic
  names. Now one inline pass tests 16 bytes for non-ASCII, U+0000, `+`, and `#` together: ASCII text is
  valid UTF-8 as it is, so ASCII needs nothing else (other text is validated in full afterwards).
- **Why `ByteLanes` and not `SIMD16`'s comparisons**: built with Swift 6.4, the standard library's
  `.==`/`.>=` compile a lane at a time and `any()` is an out-of-line call (which is why MQTT used SWAR).
  `ByteLanes` tests use lanewise wrapping arithmetic and bitwise operations, NEON with Swift 6.4 and 6.5
  alike. In the 6.4-built MQTT benchmarks, parsing PUBLISH went from 15.1 to 19.0 M packets/s (MQTT's
  Benchmarks/RESULTS.md).

### Concurrency: no hops, and no executor checks on the I/O path

The async functions here are now `nonisolated(nonsending)`, like swift-platform-executors' own (it
builds with `NonisolatedNonsendingByDefault`). Counted with LLDB breakpoints over one 64 B transfer:

| Per transfer | 20,000 packets | 80,000 packets | Per socket read or write |
|---|---|---|---|
| Socket reads + writes | 22 | 88 | |
| `swift_task_switch`, plain `nonisolated` async functions | 85 | 201 | 2.5 |
| `swift_task_switch`, `nonisolated(nonsending)` | 55 | 113 | 0.9 |
| Jobs run by the executors (`swift_job_run`) | 14–16 | 14–24 | 0 |

- **There were no hops to remove.** Every task runs on the executor it prefers, and the package resumes a
  suspended read or write on the event loop's thread directly (`resumeSynchronously`), so the executors
  run the same few jobs however many packets and reads there are.
- **But there were executor checks.** A plain `nonisolated` async function calls `swift_task_switch` on
  entry and after each call it makes, to make sure it's on the generic executor. Each finds it already is
  (the task's preferred executor), but it's a runtime call each time: 2.5 per socket operation, from
  `sendPackets`, `receivePackets`, and `ReceiveBuffer.read`. As `nonisolated(nonsending)` they run on
  their caller's executor and make none: there's no `swift_task_switch` left in their code, only in the
  closures that start tasks.
- **The 0.9 that remain** are in the standard library's `ContinuationWaiter.wait()` (the PR's split
  continuation), once each time a socket operation suspends. That's a fast-path check too.
- Effect: 64 B on one connection went from 13.6 to 14.6 M packets/s with the scans, the checker, and
  `nonisolated(nonsending)` together (not measured apart: the checks are a few per 256 KB read, so most
  of it is the scans); the sender's topic table then took it to 16.1 M.

#### Measured with Instruments (2026-11-09)

The breakpoint counts above can't tell a check from a move. Instruments' Swift Concurrency template
records every task state change (Running, Suspended, waiting on a continuation) with the thread and actor
it ran on, which shows actual hops. `Tools/tasks -- .build/…/mqtt-socket-stream ARGS` records and
summarizes it (64 B payloads, `mqtt` mode, one run each):

| Transfer | Tasks | Runs | Thread switches | Actor switches | Continuation waits | Wait before running (median, p90) |
|---|---|---|---|---|---|---|
| 1 connection, 20,000 packets | 5 | 62 | 6 | 6 | 50 | 7.9, 12.2 µs |
| 1 connection, 80,000 packets | 5 | 179 | 6 | 6 | 167 | 5.8, 12.7 µs |
| 4 connections, thread per task | 17 | 277 | 18 | 18 | 239 | 5.8, 12.0 µs |
| 4 connections, shared pool of 2 threads | 10 | 201 | 4 | 4 | 183 | 4.4, 10.6 µs |
| 4 connections, shared pool of 8 threads | 10 | 250 | 4 | 4 | 232 | 5.7, 11.2 µs |
| 1 connection, `raw` mode | 5 | 83 | 6 | 6 | 71 | 5.6, 13.5 µs |

- **The sender and receiver tasks never hop.** In every run, each runs on exactly one thread with no
  thread or actor switch, including 8 tasks sharing a 2-thread pool: a suspended read or write resumes on
  the thread it suspended on (`resumeSynchronously` on the event loop), so the pool's round-robin never
  comes into play once a task is running.
- **Every switch is `main` setting up**: `main` moves between the main thread and the global concurrent
  executor while it creates the executors and starts the tasks: 6 times for one connection, 18 for four
  connections with an executor each, 4 with one shared pool. The same for 20,000 and 80,000 packets: a
  fixed cost per transfer.
- **Suspensions follow socket waits, not packets**: continuation waits grow with the bytes moved (50 →
  167 for 4x the packets), each a socket that wasn't ready. From being made runnable to running takes a
  median of 4–8 µs.
- Together with the breakpoint counts: the 55–113 `swift_task_switch` calls per transfer are fast-path
  checks that leave the task where it is. Instruments records no state change for them, and none is a hop.

### What's left per packet

A sample of the 64 B run, since skipping the enum:
- The largest single item is `sendto` (about a fifth of the sender), then `recvfrom`.
- Then the field-by-field work: `MQTTPublish(reading:)`, its properties and strings, `MQTTFrame.read`,
  `MQTTPublish.write(to:)` and its checks (the topic's wildcard scan), and the payload copy.
- About 2.5% is destroying each parsed `MQTTPublish`: from outside the MQTT module, an indirect call
  through its type metadata to a no-op. Declaring it `BitwiseCopyable` or `@frozen` doesn't change that.

## The ceiling: loopback TCP, not the executors or the parsing

`../Tools/socket-ceiling` (then `Scripts/loopback-probe.c`) measures the kernel with blocking C sockets on
plain threads:

| Blocking C sockets, 1 MB writes | 1 pair | 2 | 4 | 8 | 16 |
|---|---|---|---|---|---|
| Loopback TCP, default buffers | 7.0 GB/s | 5.3 | 3.7 | 3.4 | 3.1 |
| Loopback TCP, 4 MB socket buffers | 7.4 GB/s | 5.8 | 3.3 | | |
| **Unix-domain socketpair** | **29.5 GB/s** | 33.8 | 39.9 | **47.0** | 40.8 |

- **Loopback TCP tops out around 7.5 GB/s for the whole machine**, and the total *drops* as connections are
  added, with or without Swift: the kernel's loopback path serializes them. Bigger socket buffers don't move
  it.
- **The package doesn't cost anything here.** Its kqueue executors reach the ceiling on one connection (7.5
  GB/s raw), faster than the blocking C probe with 256 KB writes (5.6 GB/s).
- **Unix-domain sockets carry 4–6x more**, but swift-platform-executors' sockets are TCP and UDP over IPv4
  and IPv6 only (`SocketAddress` has `v4` and `v6`). Going past 7.5 GB/s locally needs `AF_UNIX` support in
  the package.

At the TCP ceiling the MQTT layer has headroom. A 16 KB stream used 117 ms of CPU across both threads for 72
ms of transfer, and the in-memory MQTT benchmarks parse and encode large-payload packets at memory speed.

## Placement

A shared `PThreadTaskExecutor` pool hands each job to its next thread in turn; one single-thread executor per
sender and receiver keeps each task, its socket's kqueue registration, and its buffers on one thread. In
practice the pool barely matters once tasks are running: Instruments shows each task staying on one pool
thread for the whole transfer, because suspended socket operations resume on the thread that suspended
(see "Measured with Instruments" above). With
4 connections of 1 KB packets, the first measurements had thread per task 6% ahead (4.45 against 4.20
GB/s). Repeated runs now overlap (4.3–4.7 and 4.2–4.8 GB/s): at the 4-connection TCP ceiling, the
difference is within run-to-run noise.

## Notes on swift-platform-executors (as of `bd74d56` and toolchain 2511)

- **Which toolchain:** the PR build the package's manifest names (2475, October 7) no longer compiles its I/O.
  The package now calls `Continuation.resumeSynchronously` and a newer `withContinuation` form. Build 2511
  (October 25), the latest, works.
- **The runtime:** processes must load the toolchain's Concurrency runtime. With the OS's, the first socket
  operation crashes (a null access in `withContinuation`), or the process exits silently. `swift test` and
  the ordo-one benchmark plugin both replace `DYLD_LIBRARY_PATH` for the processes they launch. So the
  executables embed it (`ld -dyld_env`), and `../Tools/toolchain . test` runs the test bundle through
  `swiftpm-testing-helper` itself.
- **Leased buffers:** `PThreadTaskExecutor` doesn't implement them yet (`fatalError("Leasing buffers is not
  implemented yet")`). So `TCPConnection`'s closure-based `read { }` and `write { }`, which would let
  `BytesWriter` encode straight into a platform buffer, can't run on the pool. The sender encodes into its
  own batch and writes that.
- **A connection keeps the scheduler it was created on.** Accepting every connection in one task would put
  every receiver's I/O on that task's executor. Each pair here binds and accepts on its receiver's
  executor.
- **Call it from `nonisolated(nonsending)` code.** Its async APIs run on their caller's executor; calling
  them from plain `nonisolated` async functions adds executor checks around every call (above).
