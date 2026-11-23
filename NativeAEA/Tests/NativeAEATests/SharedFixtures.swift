import BytesTestSupport
import Foundation
import Synchronization

/// Inputs several tests read and none changes, made once per test process: a signing key pair, source trees, and the
/// archives made of them (`aa`, `aea`, and `openssl` runs, and megabytes of test bytes, are most of what those tests
/// cost). Each is made in its own `TemporaryDirectory`, removed when the process exits; tests still extract into
/// their own.
enum SharedFixtures {
    private static let directories = Mutex<[TemporaryDirectory]>([])

    /// Makes a fixture in a new directory, removed at exit. Use it to initialize a `static let`, so it's made once.
    /// The directory belongs to no test's lifetime record (`LifetimeChecks`): the test that happens to make it first would
    /// be held to account for the files other tests, running in parallel, have open in it.
    static func make<T>(_ body: (TemporaryDirectory) throws -> T) -> Result<T, any Error> {
        TemporaryDirectory.$lifetimeRecord.withValue(nil) {
            Result {
                let directory = try TemporaryDirectory()
                let first = directories.withLock { list in
                    list.append(directory)
                    return list.count == 1
                }
                if first {
                    atexit { SharedFixtures.directories.withLock { list in list.forEach { $0.remove() } } }
                }
                return try body(directory)
            }
        }
    }

    /// One key pair for the tests that sign with any key.
    static let keys: Result<SigningKeys, any Error> = make { try SigningKeys(in: $0) }
}
