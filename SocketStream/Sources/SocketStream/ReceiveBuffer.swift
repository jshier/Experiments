import Bytes
import BytesAsync
import PlatformExecutors

/// A receiver's buffer for reassembling packets from a byte stream is Bytes' `ByteBuffer`: reads append at
/// the end, parsing consumes from the start, and a partial packet left at the end moves to the front once
/// less than half the buffer is free. Its one allocation never moves, so a read can suspend with its output
/// span in place.
extension ByteBuffer {
    /// Reads once from `connection` into the free space (after moving a partial packet to the front, if less
    /// than half the buffer is free).
    ///
    /// Runs on its caller's executor.
    ///
    /// - Parameter connection: The connection to read from.
    /// - Returns: The bytes read (0 at the end of the stream).
    /// - Throws: `IOError` if the read fails.
    /// - Precondition: The buffer isn't full: a packet larger than the buffer can never be completed.
    nonisolated(nonsending) mutating func read(from connection: inout TCPConnection) async throws(IOError) -> Int {
        precondition(!isFull, "A packet larger than the receive buffer")
        return try await receive { output throws(IOError) in try await connection.read(into: &output) }
    }
}
