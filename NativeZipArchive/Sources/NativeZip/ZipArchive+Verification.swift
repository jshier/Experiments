import Foundation
import Synchronization

public extension ZipArchive {
    /// Decompresses every non-directory entry (in parallel) and checks its size and CRC-32 without writing
    /// anything.
    ///
    /// A failing entry doesn't stop the others. Failures are collected, so this doesn't throw.
    ///
    /// `@concurrent`: the decompression runs off the caller's actor, in child tasks of the call.
    ///
    /// - Parameters:
    ///   - entries: The entries to check; all of the archive's by default.
    ///   - maxConcurrency: The most entries to decompress at once.
    ///   - backend: Which DEFLATE and CRC-32 implementation to use.
    ///   - password: The password, for encrypted entries.
    /// - Returns: The entries that failed and why (the errors of ``contents(of:using:password:_:)``), in the
    ///   order given. Empty means every entry is intact. If the task is cancelled, the entries not checked are
    ///   returned with `CancellationError`.
    @concurrent
    func verify(
        _ entries: [ZipEntry]? = nil,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        backend: ZipDecoder.Backend = .bytes,
        password: String? = nil
    ) async -> [(entry: ZipEntry, error: any Error)] {
        let indexed = Array((entries ?? self.entries).filter { $0.kind != .directory }.enumerated())
        let failures = FailureLog(count: indexed.count)
        // The body never throws (failures are recorded instead), so neither does the loop.
        try? await forEachConcurrently(indexed, maxConcurrency: maxConcurrency, backend: backend, weight: \.element.uncompressedSize) {
            [self] item, decoder in
            do {
                try contents(of: item.element, using: &decoder, password: password) { _ in }
                failures.checked(index: item.offset)
            } catch {
                failures.record(index: item.offset, entry: item.element, error: error)
            }
        }
        // Cancelled: workers stopped claiming entries. Those never checked aren't reported intact.
        for (index, entry) in indexed where !failures.wasChecked(index) {
            failures.record(index: index, entry: entry, error: CancellationError())
        }
        return failures.sorted()
    }

    /// Whether `password` passes `entry`'s password check: the traditional cipher's check byte, or AES's
    /// verifier. A wrong password passes the traditional check about once in 256 tries (decryption then
    /// fails its CRC-32); AES's, once in 65,536 (then its authentication code).
    ///
    /// - Parameters:
    ///   - password: The password to try.
    ///   - entry: An encrypted entry.
    /// - Returns: `false` if the check fails or the entry's header can't be read; `true` for an entry that
    ///   isn't encrypted.
    func passwordMatches(_ password: String, for entry: ZipEntry) -> Bool {
        guard let encryption = entry.encryption else { return true }
        guard let payload = try? Self.payload(of: entry, in: file.bytes) else { return false }
        let key = Array(password.utf8)
        switch encryption {
        case .traditional:
            guard payload.byteCount >= TraditionalCipher.headerSize else { return false }
            var cipher = TraditionalCipher(password: key.span.bytes)
            let expected = entry.flags & 0x8 != 0 ? UInt8(truncatingIfNeeded: entry.dosTime >> 8) : UInt8(truncatingIfNeeded: entry.crc32 >> 24)
            return cipher.checkByte(payload.extracting(0..<TraditionalCipher.headerSize)) == expected
        case let .aes(bits, _):
            return WinZipAES.verify(payload, bits: bits, password: key.span.bytes)
        case .unsupported:
            return false
        }
    }
}

/// Results from concurrent workers: failures, and which entries were checked at all.
private final class FailureLog: Sendable {
    private struct State {
        var failures: [(index: Int, entry: ZipEntry, error: any Error)] = []
        var checked: [Bool]
    }

    private let state: Mutex<State>

    init(count: Int) {
        state = Mutex(State(checked: Array(repeating: false, count: count)))
    }

    func checked(index: Int) {
        state.withLock { $0.checked[index] = true }
    }

    func record(index: Int, entry: ZipEntry, error: any Error) {
        state.withLock { state in
            state.checked[index] = true
            state.failures.append((index, entry, error))
        }
    }

    func wasChecked(_ index: Int) -> Bool {
        state.withLock { $0.checked[index] }
    }

    func sorted() -> [(entry: ZipEntry, error: any Error)] {
        state.withLock { $0.failures.sorted { $0.index < $1.index }.map { ($0.entry, $0.error) } }
    }
}
