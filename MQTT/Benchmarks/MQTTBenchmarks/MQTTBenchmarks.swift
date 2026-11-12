import Benchmark
import Bytes
import Dispatch
import Foundation
import MQTT

// MARK: - Fixtures

let packetCount = 10_000
let topics = (0..<16).map { "sensors/building-\($0 % 8)/floor-\($0 % 4)/temp-\($0)" } // ~32 bytes each
let payload: [UInt8] = (0..<64).map { UInt8(truncatingIfNeeded: $0 &* 37) }
let unitName = "unit"
let unitValue = "celsius"

/// Message expiry 60 s and a user property, encoded once.
let propertyBytes: [UInt8] = try! [UInt8](byteCapacity: 64) { writer in
    try writer.write(MQTTProperty.messageExpiryInterval(60))
    try writer.write(MQTTProperty.userProperty(name: unitName.utf8Span, value: unitValue.utf8Span))
}

func encode(_ packet: borrowing MQTTPacket, into stream: inout [UInt8]) {
    try! stream.append(byteCapacity: packet.encodedByteCount) { writer in try packet.write(to: &writer) }
}

/// 10,000 QoS 1 PUBLISH packets.
let publishStream: [UInt8] = {
    var stream: [UInt8] = []
    let properties = try! MQTTProperties(validating: propertyBytes.span.bytes)
    for index in 0..<packetCount {
        encode(.publish(MQTTPublish(
            qos: .atLeastOnce, topic: topics[index % topics.count].utf8Span, packetIdentifier: UInt16(index % 65_535 + 1),
            properties: properties, payload: payload.span.bytes
        )), into: &stream)
    }
    return stream
}()

/// 10,000 packets of every type, in a session-like order.
let mixedStream: [UInt8] = {
    var stream: [UInt8] = []
    let properties = try! MQTTProperties(validating: propertyBytes.span.bytes)
    // CONNECT can't carry Message Expiry Interval: a session expiry and the user property instead.
    let connectPropertyBytes = try! [UInt8](byteCapacity: 64) { writer in
        try writer.write(MQTTProperty.sessionExpiryInterval(3_600))
        try writer.write(MQTTProperty.userProperty(name: unitName.utf8Span, value: unitValue.utf8Span))
    }
    let connectProperties = try! MQTTProperties(validating: connectPropertyBytes.span.bytes)
    let subscriptions = try! [UInt8](byteCapacity: 64) { writer in
        try writer.write(MQTTSubscription(topicFilter: "sensors/+/floor-1/#".utf8Span, options: MQTTSubscriptionOptions(maximumQoS: .atLeastOnce)))
        try writer.write(MQTTSubscription(topicFilter: "alerts/#".utf8Span, options: MQTTSubscriptionOptions(maximumQoS: .exactlyOnce)))
    }
    let codes: [UInt8] = [1, 2]
    var count = 0
    while count < packetCount {
        encode(.connect(MQTTConnect(cleanStart: true, keepAlive: 60, properties: connectProperties, clientIdentifier: "client-1".utf8Span,
                                    will: nil, userName: "user".utf8Span, password: payload.span.bytes.extracting(first: 8))), into: &stream)
        encode(.connectAcknowledgement(MQTTConnectAcknowledgement(sessionPresent: false, reasonCode: .success, properties: MQTTProperties())), into: &stream)
        encode(.subscribe(MQTTSubscribe(packetIdentifier: 1, properties: MQTTProperties(),
                                        subscriptions: try! MQTTSubscriptions(validating: subscriptions.span.bytes))), into: &stream)
        encode(.subscribeAcknowledgement(MQTTSubscribeAcknowledgement(packetIdentifier: 1, properties: MQTTProperties(), reasonCodes: codes.span)), into: &stream)
        for qos in [MQTTQoS.atMostOnce, .atLeastOnce, .exactlyOnce] {
            encode(.publish(MQTTPublish(qos: qos, topic: topics[count % topics.count].utf8Span, packetIdentifier: qos == .atMostOnce ? nil : 7,
                                        properties: properties, payload: payload.span.bytes)), into: &stream)
        }
        encode(.publishAcknowledgement(MQTTPublishResponse(packetIdentifier: 7, properties: MQTTProperties())), into: &stream)
        encode(.publishReceived(MQTTPublishResponse(packetIdentifier: 7, properties: MQTTProperties())), into: &stream)
        encode(.publishRelease(MQTTPublishResponse(packetIdentifier: 7, properties: MQTTProperties())), into: &stream)
        encode(.publishComplete(MQTTPublishResponse(packetIdentifier: 7, properties: MQTTProperties())), into: &stream)
        encode(.pingRequest, into: &stream)
        encode(.pingResponse, into: &stream)
        encode(.disconnect(MQTTDisconnect()), into: &stream)
        count += 14
    }
    return stream
}()

/// The same publishes as owned values, for the conventional encoder.
let conventionalPublishes: [ConventionalPublish] = (0..<packetCount).map { index in
    ConventionalPublish(
        duplicate: false, qos: 1, retain: false, topic: topics[index % topics.count], packetIdentifier: UInt16(index % 65_535 + 1),
        properties: [.messageExpiryInterval(60), .userProperty(unitName, unitValue)], payload: payload
    )
}

// MARK: - Copies for the all-core runs

/// The all-core benchmarks run each workload over this many separate copies of its fixture, 4 per core,
/// handed out as cores free up: 100–150 MB per fixture, beyond every cache. Single-core runs use copy 0
/// (about 1.2 MB, which stays in a core's L2).
let copyCount = ProcessInfo.processInfo.activeProcessorCount * 4

/// `copyCount` copies of `stream`, back to back.
func copies(of stream: [UInt8]) -> [UInt8] {
    var copies: [UInt8] = []
    copies.reserveCapacity(stream.count * copyCount)
    for _ in 0..<copyCount {
        copies += stream
    }
    return copies
}

let publishStreams = copies(of: publishStream)
let mixedStreams = copies(of: mixedStream)

/// Room for `copyCount` encoded `publishStream`s, every page touched.
nonisolated(unsafe) let encodeBuffers: UnsafeMutableRawBufferPointer = {
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: publishStream.count * copyCount, alignment: 1 << 14)
    buffer.initializeMemory(as: UInt8.self, repeating: 0)
    return buffer
}()

/// The bytes of copy `index` in a fixture made by `copies(of:)` from a `byteCount`-byte stream.
func range(ofCopy index: Int, byteCount: Int) -> Range<Int> { index * byteCount..<(index + 1) * byteCount }

// MARK: - Workloads

/// Parses copy `index` of `publishStream` with views: every field, and every property when
/// `iteratingProperties`.
func parsePublishes(copy index: Int, iteratingProperties: Bool) {
    var reader = BytesReader(publishStreams.span.bytes.extracting(range(ofCopy: index, byteCount: publishStream.count)))
    var checksum = 0
    while let packet = try! MQTTPacket.read(from: &reader) {
        guard case let .publish(publish) = packet else { fatalError() }
        checksum &+= publish.topic.count &+ publish.payload.byteCount &+ Int(publish.packetIdentifier ?? 0)
        if iteratingProperties {
            publish.properties.forEach { property in
                switch property {
                case let .messageExpiryInterval(seconds): checksum &+= Int(seconds)
                case let .userProperty(name, value): checksum &+= name.count &+ value.count
                default: break
                }
            }
        }
    }
    blackHole(checksum)
}

/// Parses copy `index` of `publishStream` as `parsePublishes` does, without `MQTTPacket`: reads frames and
/// parses each as the PUBLISH its type says.
func parsePublishFrames(copy index: Int) {
    var reader = BytesReader(publishStreams.span.bytes.extracting(range(ofCopy: index, byteCount: publishStream.count)))
    var checksum = 0
    while let frame = try! MQTTFrame.read(from: &reader) {
        guard frame.type == .publish else { fatalError() }
        let publish = try! MQTTPublish(parsing: frame)
        checksum &+= publish.topic.count &+ publish.payload.byteCount &+ Int(publish.packetIdentifier ?? 0)
        publish.properties.forEach { property in
            switch property {
            case let .messageExpiryInterval(seconds): checksum &+= Int(seconds)
            case let .userProperty(name, value): checksum &+= name.count &+ value.count
            default: break
            }
        }
    }
    blackHole(checksum)
}

/// Parses copy `index` of `mixedStream` with views.
func parseMixedStream(copy index: Int) {
    var reader = BytesReader(mixedStreams.span.bytes.extracting(range(ofCopy: index, byteCount: mixedStream.count)))
    var checksum = 0
    while let packet = try! MQTTPacket.read(from: &reader) {
        checksum &+= Int(packet.type.rawValue)
        if case let .publish(publish) = packet { checksum &+= publish.payload.byteCount }
        if case let .subscribe(subscribe) = packet { subscribe.subscriptions.forEach { checksum &+= $0.topicFilter.count } }
    }
    blackHole(checksum)
}

/// Encodes 10,000 PUBLISH packets into copy `index` of `encodeBuffers`.
func encodePublishes(copy index: Int) {
    let buffer = UnsafeMutableRawBufferPointer(rebasing: encodeBuffers[range(ofCopy: index, byteCount: publishStream.count)])
    var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
    let inputs = encodeInputs[index]
    let properties = try! MQTTProperties(validating: inputs.propertyBytes.span.bytes)
    for packet in 0..<packetCount {
        try! MQTTPacket.publish(MQTTPublish(
            qos: .atLeastOnce, topic: inputs.topics[packet % inputs.topics.count].utf8Span,
            packetIdentifier: UInt16(packet % 65_535 + 1), properties: properties, payload: inputs.payload.span.bytes
        )).write(to: &writer)
    }
    precondition(writer.byteCount == publishStream.count)
}

/// Encodes the same packets as `encodePublishes`, each `MQTTPublish` writing itself, without `MQTTPacket`.
func encodePublishesDirectly(copy index: Int) {
    let buffer = UnsafeMutableRawBufferPointer(rebasing: encodeBuffers[range(ofCopy: index, byteCount: publishStream.count)])
    var writer = BytesWriter(MutableRawSpan(_unsafeBytes: buffer))
    let inputs = encodeInputs[index]
    let properties = try! MQTTProperties(validating: inputs.propertyBytes.span.bytes)
    for packet in 0..<packetCount {
        try! MQTTPublish(
            qos: .atLeastOnce, topic: inputs.topics[packet % inputs.topics.count].utf8Span,
            packetIdentifier: UInt16(packet % 65_535 + 1), properties: properties, payload: inputs.payload.span.bytes
        ).write(to: &writer)
    }
    precondition(writer.byteCount == publishStream.count)
}

/// Parses copy `index` of `publishStream` with views, copying out what a caller would keep: the topic as a
/// `String`, the payload as an `Array`, and the user property's strings.
func parsePublishesCopying(copy index: Int) {
    var reader = BytesReader(publishStreams.span.bytes.extracting(range(ofCopy: index, byteCount: publishStream.count)))
    var checksum = 0
    while let packet = try! MQTTPacket.read(from: &reader) {
        guard case let .publish(publish) = packet else { fatalError() }
        let topic = String(copying: publish.topic)
        let body = [UInt8](copying: publish.payload)
        checksum &+= topic.utf8.count &+ body.count
        publish.properties.forEach { property in
            if case let .userProperty(name, value) = property {
                checksum &+= String(copying: name).utf8.count &+ String(copying: value).utf8.count
            }
        }
    }
    blackHole(checksum)
}

/// Parses copy `index` of `publishStream` with the conventional parser.
func parsePublishesConventionally(copy index: Int) {
    var checksum = 0
    try! Conventional.parsePublishes(publishStreams, in: range(ofCopy: index, byteCount: publishStream.count)) { publish in
        checksum &+= publish.topic.utf8.count &+ publish.payload.count &+ Int(publish.packetIdentifier ?? 0)
        for property in publish.properties {
            switch property {
            case let .messageExpiryInterval(seconds): checksum &+= Int(seconds)
            case let .userProperty(name, value): checksum &+= name.utf8.count &+ value.utf8.count
            default: break
            }
        }
    }
    blackHole(checksum)
}

/// A copy of `string` with its own storage.
func distinct(_ string: String) -> String { String(decoding: Array(string.utf8), as: UTF8.self) }

/// The encoders' inputs, `copyCount` times, each copy with its own strings and arrays: cores sharing one
/// string contend on its reference count, which made the all-core encoders 50–100x slower.
let conventionalPublishCopies: [[ConventionalPublish]] = (0..<copyCount).map { _ in
    conventionalPublishes.map { publish in
        var copy = publish
        copy.topic = distinct(publish.topic)
        copy.payload = publish.payload.map(\.self)
        copy.properties = publish.properties.map { property in
            guard case let .userProperty(name, value) = property else { return property }
            return .userProperty(distinct(name), distinct(value))
        }
        return copy
    }
}

struct EncodeInputs {
    let topics: [String]
    let payload: [UInt8]
    let propertyBytes: [UInt8]
}

let encodeInputs: [EncodeInputs] = (0..<copyCount).map { _ in
    EncodeInputs(topics: topics.map(distinct), payload: payload.map(\.self), propertyBytes: propertyBytes.map(\.self))
}

/// Encodes `publishes` with the conventional encoder, into a new array.
func encodePublishesConventionally(_ publishes: [ConventionalPublish]) -> [UInt8] {
    var output: [UInt8] = []
    output.reserveCapacity(publishStream.count)
    for publish in publishes {
        Conventional.appendPublish(publish, to: &output)
    }
    precondition(output.count == publishStream.count)
    return output
}

/// A benchmark workload: one pass over one copy of a fixture.
struct Workload {
    let name: String
    /// The bytes and packets in one copy.
    let byteCount: Int
    let packetCount: Int
    /// Whether it must not allocate, so it also gets an allocation check.
    let isAllocationFree: Bool
    let run: @Sendable (_ copy: Int) -> Void
}

let workloads: [Workload] = [
    Workload(name: "Parse PUBLISH: Bytes views", byteCount: publishStream.count, packetCount: packetCount,
             isAllocationFree: true) { parsePublishes(copy: $0, iteratingProperties: true) },
    Workload(name: "Parse PUBLISH: frames, MQTTPublish(parsing:)", byteCount: publishStream.count,
             packetCount: packetCount, isAllocationFree: true, run: parsePublishFrames),
    Workload(name: "Parse PUBLISH: Bytes views, properties not iterated", byteCount: publishStream.count,
             packetCount: packetCount, isAllocationFree: true) { parsePublishes(copy: $0, iteratingProperties: false) },
    Workload(name: "Parse PUBLISH: Bytes views, copying topic, payload, and strings", byteCount: publishStream.count,
             packetCount: packetCount, isAllocationFree: false, run: parsePublishesCopying),
    Workload(name: "Parse PUBLISH: conventional ([UInt8] indexes, owned values)", byteCount: publishStream.count,
             packetCount: packetCount, isAllocationFree: false, run: parsePublishesConventionally),
    Workload(name: "Parse mixed stream: Bytes views", byteCount: mixedStream.count, packetCount: packetCount,
             isAllocationFree: true, run: parseMixedStream),
    Workload(name: "Encode PUBLISH: Bytes writer", byteCount: publishStream.count, packetCount: packetCount,
             isAllocationFree: true, run: encodePublishes),
    Workload(name: "Encode PUBLISH: MQTTPublish.write(to:)", byteCount: publishStream.count, packetCount: packetCount,
             isAllocationFree: true, run: encodePublishesDirectly),
    Workload(name: "Encode PUBLISH: conventional ([UInt8] appends)", byteCount: publishStream.count,
             packetCount: packetCount, isAllocationFree: false) { blackHole(encodePublishesConventionally(conventionalPublishCopies[$0])) },
]

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        // Only the work runs inside `scaledIterations`. Bandwidth and packet rate are the framework's
        // throughput (iterations per second) times a workload's bytes and packets per iteration: 10,000
        // packets on one core, `copyCount` times that on every core.
        metrics: [.wallClock, .instructions, .mallocCountTotal, .throughput],
        warmupIterations: 3,
        scalingFactor: .one,
        maxDuration: .seconds(1),
        maxIterations: 1_000
    )

    // The encoders' output, checked once rather than on every iteration.
    encodePublishes(copy: 0)
    precondition(Array(UnsafeRawBufferPointer(rebasing: encodeBuffers[..<publishStream.count])) == publishStream)
    precondition(encodePublishesConventionally(conventionalPublishes) == publishStream)

    // One core: 10,000 packets from copy 0, which stays in cache.
    for workload in workloads {
        Benchmark(workload.name) { benchmark in
            for _ in benchmark.scaledIterations {
                workload.run(0)
            }
        }
    }

    // Every core: all `copyCount` copies (4 per core, 100–150 MB), so the total throughput of the machine,
    // from memory.
    let cores = ProcessInfo.processInfo.activeProcessorCount
    for workload in workloads {
        Benchmark("\(workload.name), \(cores) cores") { benchmark in
            for _ in benchmark.scaledIterations {
                DispatchQueue.concurrentPerform(iterations: copyCount, execute: workload.run)
            }
        }
    }

    // Allocation checks: the workloads that must not allocate, registered again as "Allocations:<name>",
    // counting only allocations against a static threshold of zero (in `Thresholds/`), so
    // `swift package benchmark thresholds check --filter 'Allocations:.*'` fails if any of them allocates.
    // Counts are deterministic, so a few iterations are enough; warmup runs the lazy fixtures' initializers.
    let zeroAllocations = Benchmark.Configuration(
        metrics: [.mallocCountTotal],
        warmupIterations: 1,
        maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    for workload in workloads where workload.isAllocationFree {
        // No spaces: `thresholds update` writes "_" for them in the file name, but `thresholds check` looks the
        // file up by the unaltered name (benchmark 1.38.1, ordo-one/benchmark#373).
        Benchmark("Allocations:\(workload.name.replacing(" ", with: "_"))", configuration: zeroAllocations) { benchmark in
            for _ in benchmark.scaledIterations {
                workload.run(0)
            }
        }
    }
}
