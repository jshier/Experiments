# MQTTSocketStream

How fast can structured data go through a local socket? MQTT 5 PUBLISH packets are encoded with
`BytesWriter` (../MQTT, ../Bytes) on one end of a loopback TCP connection, read and parsed with `BytesReader`
on the other, and every packet is checked: its identifier is the next in sequence, its topic matches byte
for byte, and its payload is the size sent. The sockets and executors are
[swift-platform-executors](https://github.com/swiftlang/swift-platform-executors)'s `TCPListener`,
`TCPConnection`, and `PThreadTaskExecutor` (kqueue). Results and analysis are in [RESULTS.md](RESULTS.md).

## Requirements

swift-platform-executors' I/O is behind its `ExperimentalIO` trait and needs a toolchain with
[swiftlang/swift#91981](https://github.com/swiftlang/swift/pull/91981) (the split continuation), which isn't
merged, so no release or `main` snapshot has it (swiftly can't install it). This was built and measured with
the PR's macOS toolchain build 2511 (Swift 6.5-dev, October 25), installed at
`~/Library/Developer/Toolchains/swift-PR-91981-2511.xctoolchain`:

```sh
curl -LO https://download.swift.org/tmp/pull-request/91981/2511/xcode/swift-PR-91981-2511-osx.tar.gz
tar -xzf swift-PR-91981-2511-osx.tar.gz -C ~   # its paths start with Library/Developer/Toolchains
```

Processes must run against that toolchain's Concurrency runtime, not the OS's: with the OS's, the first
socket operation crashes. The executables embed the runtime's path at link time (`ld -dyld_env`, see
Package.swift; override with `MQTT_SOCKET_STREAM_RUNTIME` when building), because `swift test` and the
benchmark plugin replace `DYLD_LIBRARY_PATH` for the processes they start. The scripts select the toolchain
(override with `TOOLCHAIN=…`):

```sh
Scripts/run.sh --payload 1024 --connections 4     # one transfer, printed: GB/s and packets/s
Scripts/test.sh                                   # the tests, run against the toolchain's runtime
Scripts/benchmark.sh                              # the benchmarks
Scripts/benchmark.sh thresholds check --filter 'Allocations:.*'   # fails if packets allocate
```

`mqtt-socket-stream` options: `--mode mqtt|raw`, `--payload BYTES`, `--packets PER-CONNECTION`,
`--connections N`, `--batch BYTES` (encode and write size), `--buffer BYTES` (receive buffer),
`--placement threadPerTask|sharedPool`, `--pool THREADS` (shared pool), `--runs N`.

`Scripts/loopback-probe.c` measures the kernel's ceiling with blocking C sockets: loopback TCP, or a
Unix-domain socketpair.

## How it works

- **Sender** (`Transfer.sendPackets`): encodes packets into a 256 KB batch with `BytesWriter` until the next
  one doesn't fit (`MQTTPublish.write(to:)` throws `insufficientCapacity` without writing anything), then
  `TCPConnection.write(from:)`s the batch.
- **Receiver** (`Transfer.receivePackets`): `TCPConnection.read(into:)` appends to a `ReceiveBuffer`. A
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
