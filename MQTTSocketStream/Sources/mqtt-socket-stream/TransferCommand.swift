import ArgumentParser
import MQTTSocketStream

/// Runs one transfer and prints its throughput.
@main
struct TransferCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mqtt-socket-stream",
        abstract: "Send MQTT PUBLISH packets through local TCP sockets and print the throughput.",
        discussion: """
        Each connection pair is a sender encoding packets with BytesWriter and a receiver parsing them with \
        BytesReader. Run it with the toolchain in .swift-toolchain (../Tools/toolchain . -- swift run …).
        """
    )

    @Option(help: "What to send: MQTT packets, or the same bytes unencoded (the socket's ceiling).")
    var mode: TransferMode = .mqtt

    @Option(help: ArgumentHelp("Bytes of application payload per PUBLISH.", valueName: "bytes"))
    var payload = 1_024

    @Option(help: ArgumentHelp("PUBLISH packets per connection (default: ~1 GB per connection).", valueName: "count"))
    var packets: Int?

    @Option(help: "Client/server connection pairs, all transferring at once.")
    var connections = 1

    @Option(help: ArgumentHelp("The sender's write size.", valueName: "bytes"))
    var batch = 256 << 10

    @Option(help: ArgumentHelp("The receiver's buffer size.", valueName: "bytes"))
    var buffer = 256 << 10

    @Option(help: ArgumentHelp("Threads in the shared executor pool (default: one per core).", valueName: "threads"))
    var pool: Int?

    @Option(help: "Executors: one thread per sender and receiver, or one shared pool.")
    var placement: Placement = .threadPerTask

    @Option(help: "Transfers to run.")
    var runs = 3

    /// Checks that `--payload` isn't negative and every other count or size is at least 1.
    ///
    /// - Throws: `ValidationError` naming the offending option.
    func validate() throws {
        guard payload >= 0 else { throw ValidationError("--payload must not be negative.") }
        for (name, value) in [("packets", packets), ("connections", connections), ("batch", batch),
                              ("buffer", buffer), ("pool", pool), ("runs", runs)] {
            if let value, value < 1 { throw ValidationError("--\(name) must be at least 1.") }
        }
    }

    /// Runs the transfer `--runs` times, printing each result.
    ///
    /// - Throws: Any error from `Transfer.run(_:mode:placement:)`.
    func run() async throws {
        let workload = Workload(
            payloadSize: payload,
            packetsPerConnection: packets ?? max(1, (1 << 30) / (payload + 64)), // ~1 GB per connection
            connections: connections,
            batchSize: batch,
            receiveCapacity: buffer,
            poolSize: pool
        )
        print("\(mode), \(placement): \(workload), batches of \(workload.batchSize) B")
        for _ in 0..<runs {
            try await print("  " + String(describing: Transfer.run(workload, mode: mode, placement: placement)))
        }
    }
}

extension TransferMode: ExpressibleByArgument {}
extension Placement: ExpressibleByArgument {}
