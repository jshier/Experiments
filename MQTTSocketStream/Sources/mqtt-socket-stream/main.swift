import MQTTSocketStream

// Runs one transfer and prints its throughput:
//
//     mqtt-socket-stream [--mode mqtt|raw] [--payload BYTES] [--packets PER-CONNECTION]
//                        [--connections N] [--batch BYTES] [--buffer BYTES] [--pool THREADS]
//                        [--placement threadPerTask|sharedPool] [--runs N]

let options: [String: String] = {
    var options: [String: String] = [:]
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let name = arguments.next() {
        guard name.hasPrefix("--"), let value = arguments.next() else { fatalError("Expected --name value pairs") }
        options[String(name.dropFirst(2))] = value
    }
    return options
}()
func option(_ name: String, _ fallback: Int) -> Int { options[name].flatMap(Int.init) ?? fallback }

let mode = TransferMode(rawValue: options["mode"] ?? "mqtt")!
let placement = Placement(rawValue: options["placement"] ?? "threadPerTask")!
let payload = option("payload", 1_024)
let workload = Workload(
    payloadSize: payload,
    packetsPerConnection: option("packets", max(1, (1 << 30) / (payload + 64))), // ~1 GB per connection
    connections: option("connections", 1),
    batchSize: option("batch", 256 << 10),
    receiveCapacity: option("buffer", 256 << 10),
    poolSize: options["pool"].flatMap(Int.init)
)
print("\(mode), \(placement): \(workload), batches of \(workload.batchSize) B")
for _ in 0..<option("runs", 3) {
    print("  " + String(describing: try await Transfer.run(workload, mode: mode, placement: placement)))
}
