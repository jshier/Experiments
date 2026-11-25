import BytesTestSupport
public import Testing

// Lifetime checks: a suite trait that makes resource lifetimes part of every test, not a separate audit run.
//
//     @Suite(.lifetimeChecked) struct DestinationTests { … }                      // open files only
//     @Suite(.lifetimeChecked(audit: "descriptors closed at deinit") { try await DescriptorAudit.counting($0) }) …
//
// For each test it checks that nothing is still open under the test's `TemporaryDirectory`s when each is removed (or
// when the test ends, for one never removed), and, given an audit (a library's count of resources its owners' `deinit`
// had to release because no explicit close came, kept per task so parallel tests each count their own), that the test
// dropped none.

/// Checks what each test leaves open (see the file's comment).
public struct LifetimeChecks: TestTrait, SuiteTrait, TestScoping {
    /// What the audit counts, for the failure's message.
    let auditName: String?
    /// Runs a test and returns how many resources it released late (at `deinit`), or `nil` for no audit.
    let audit: (@Sendable (@Sendable () async throws -> Void) async throws -> Int)?

    public var isRecursive: Bool { true }

    @concurrent
    public func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
        // Once per test case; a suite and a test function itself just run.
        guard testCase != nil else { return try await function() }
        let record = LifetimeRecord()
        var thrown: any Error?
        var dropped = 0
        do {
            if let audit {
                dropped = try await audit { try await TemporaryDirectory.$lifetimeRecord.withValue(record) { try await function() } }
            } else {
                try await TemporaryDirectory.$lifetimeRecord.withValue(record) { try await function() }
            }
        } catch {
            thrown = error
        }
        // At the test's own declaration: the problem is the test's (or the code it ran), not this trait's.
        for problem in record.finish() {
            Issue.record(Comment(rawValue: "Lifetime: " + problem), sourceLocation: test.sourceLocation)
        }
        if dropped != 0 {
            let what = auditName ?? "resources released at deinit"
            Issue.record(Comment(rawValue: "Lifetime: \(dropped) \(what) (no explicit close)"), sourceLocation: test.sourceLocation)
        }
        if let thrown { throw thrown }
    }
}

public extension Trait where Self == LifetimeChecks {
    /// Checks that nothing is left open under the test's temporary directories.
    static var lifetimeChecked: Self { LifetimeChecks(auditName: nil, audit: nil) }

    /// Checks that nothing is left open under the test's temporary directories, and that the test releases nothing at
    /// `deinit`: `audit` runs the test and returns how many resources its owners released at `deinit` instead of by an
    /// explicit close (counted per task: a library's task-local scope).
    static func lifetimeChecked(audit name: String, _ audit: @escaping @Sendable (@Sendable () async throws -> Void) async throws -> Int) -> Self {
        LifetimeChecks(auditName: name, audit: audit)
    }
}
