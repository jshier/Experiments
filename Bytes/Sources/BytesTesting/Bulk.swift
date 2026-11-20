public import Testing
internal import Foundation

// Bulk tests: the long sweeps (large inputs, corpora, every capacity, thousands of mutations) kept out of the
// default run. Each lives in a suite named `…BulkTests` marked `.bulk`, and covers what its fast counterpart
// leaves out.
//
//     swift test                                                          # fast tests only
//     BULK_TESTS=1 swift test -c release -Xswiftc -enable-testing         # fast and bulk
//     BULK_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter BulkTests   # bulk only

/// Whether this run includes the bulk tests: `BULK_TESTS` set to anything but `0`.
public let runsBulkTests: Bool = {
    guard let value = ProcessInfo.processInfo.environment["BULK_TESTS"] else { return false }
    return !value.isEmpty && value != "0"
}()

public extension Trait where Self == ConditionTrait {
    /// Runs only when `BULK_TESTS` is set.
    static var bulk: Self { .enabled(if: runsBulkTests, "bulk: run with BULK_TESTS=1") }
}
