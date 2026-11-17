# SocketStream

(Formerly MQTTSocketStream.) How fast can structured data go through a local socket? MQTT 5 PUBLISH packets
are encoded with `AlignedBytesWriter` (../MQTT, ../Bytes) on one end of a loopback TCP connection, read and parsed
with `AlignedBytesReader` on the other, and every packet is checked: its identifier is the next in sequence, its
topic matches byte for byte, and its payload is the size sent. Optionally the stream is compressed (Bytes'
DEFLATE or Brotli) and encrypted (TLS 1.3 records, ChaCha20-Poly1305) through Bytes pipelines on the way, and
decrypted and decompressed on the other end. The sockets and executors are
[swift-platform-executors](https://github.com/swiftlang/swift-platform-executors)'s `TCPListener`,
`TCPConnection`, and `PThreadTaskExecutor` (kqueue). Results and analysis are in [RESULTS.md](RESULTS.md).

## Requirements

swift-platform-executors' I/O is behind its `ExperimentalIO` trait and needs a toolchain with
[swiftlang/swift#91981](https://github.com/swiftlang/swift/pull/91981) (the split continuation), which isn't
merged, so no release or `main` snapshot has it (swiftly can't install it). This was built and measured with
the PR's macOS toolchain build 2511 (Swift 6.5-dev, October 25). `.swift-toolchain` names it (`pr-91981`),
and `../Tools/toolchains.json` records where it comes from; to install it (a 3 GB download):

```sh
../Tools/toolchain install pr-91981
```

Processes must run against that toolchain's Concurrency runtime, not the OS's: with the OS's, the first
socket operation crashes. The executables embed the runtime's path at link time (`ld -dyld_env`, see
Package.swift: the runtime of the toolchain the build uses), because `swift test` and the benchmark plugin
replace `DYLD_LIBRARY_PATH` for the processes they start. `../Tools/toolchain` selects the toolchain this
package names:

```sh
../Tools/toolchain . -- swift run -c release socket-stream --payload 1024 --connections 4   # one transfer: GB/s and packets/s
../Tools/toolchain . -- swift run -c release socket-stream --compression deflate --encrypted   # compressed and encrypted
../Tools/toolchain . test                                                 # the tests, against the toolchain's runtime
../Tools/toolchain . -- swift package --disable-sandbox benchmark        # the benchmarks
../Tools/toolchain . -- swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:.*'   # fails if packets allocate
```

`socket-stream` options: `--mode mqtt|raw`, `--compression none|deflate|brotli`, `--encrypted`,
`--payload BYTES`, `--packets PER-CONNECTION`, `--connections N`, `--batch BYTES` (encode and write size),
`--buffer BYTES` (receive buffer; at least 17 KB with `--encrypted`, to hold a whole record),
`--placement threadPerTask|sharedPool`, `--pool THREADS` (shared pool), `--runs N`.

`../Tools/socket-ceiling` measures the kernel's ceiling with blocking C sockets: loopback TCP, or a
Unix-domain socketpair (`--unix`).

## How it works

- **Sender** (`Transfer.sendPackets`): encodes packets into a 256 KB batch with `AlignedBytesWriter` until the next
  one doesn't fit (`MQTTPublish.write(to:)` throws `insufficientCapacity` without writing anything), then
  `TCPConnection.write(from:)`s the batch.
- **Receiver** (`Transfer.receivePackets`): `TCPConnection.read(into:)` appends to a `ByteBuffer`. A
  `PacketChecker` reads complete packets out of it as frames (`MQTTFrame.read(from:)` returns `nil`,
  consuming nothing, for a packet that hasn't fully arrived), parses each as `MQTTPublish(parsing:)`, and
  checks it. A partial packet left at the end moves to the front before the buffer runs out of room.
- **No `MQTTPacket`** on either end: the enum is 153 bytes, built in memory, and a call per case test, so
  both ends use the PUBLISH type directly.
- **Per packet**, neither end allocates or touches a reference count (`Allocations:` benchmarks, with
  thresholds of zero), and strings are checked 16 bytes at a time (Bytes' `ByteLanes`).
- **Concurrency**: the async functions are `nonisolated(nonsending)`, so the send and receive loops run
  on their task's executor with no executor checks around the socket calls.
- **Placement**: each sender and receiver on its own single-thread `PThreadTaskExecutor` (`threadPerTask`,
  the default), or all on one pool (`sharedPool`). Each pair has its own listener, bound and accepted on its
  receiver's executor: a `TCPConnection` keeps the scheduler it was created with.
- **Raw mode**: the same number of bytes, neither encoded nor parsed: loopback TCP's own ceiling.
- **Compression and encryption** (`Protection.swift`): the sender runs each encoded batch through a Bytes
  pipeline (`DeflateEncoder` or `BrotliEncoder`, then `TLSRecordSealer`) with a flush at the batch's end, so
  the receiver can decode every packet in it, and writes what comes out; the receiver runs what it reads
  through the reverse pipeline (`TLSRecordOpener`, then the decoder) into a second buffer, where packets are
  checked as before. Keys come from an X25519 exchange (CryptoKit) and TLS 1.3's key schedule; the pipelines
  are built once per connection and allocate nothing per packet. These transfers' payloads are windows of
  about 1 MB of generated JSON telemetry, a different one per packet: the fixed payload of plain transfers
  would compress to almost nothing.
