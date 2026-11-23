import Darwin
import Synchronization

// Descriptors with explicit lifetimes. A descriptor is closed where the code decides its use ends (an extraction's last
// call, a publish, a writer's last write), never left to whenever its owner happens to be destroyed. The types make
// that point explicit and checkable:
//
// - `OwnedDescriptor` has one owner (it's noncopyable) and `consuming` `close()` and `release()`: closing twice, or
//   using it after closing, doesn't compile.
// - `DescriptorSlot` holds a descriptor several threads read (a `Destination`'s, used by every writer): `close()` swaps
//   in -1 atomically and closes once, so a late reader gets `EBADF` instead of a number the kernel has given to
//   another file since.
//
// Neither closes as a way of working. Their `deinit` is an audit: a descriptor still open when its owner is destroyed
// was never closed on purpose, so `DescriptorAudit` counts it (and closes it, so a missed close doesn't also leak in a
// shipped build). Tests require the count to stay 0 (`DiskTests`' descriptor trait), alongside a check that nothing is
// left open under each test's directory.

/// Counts descriptors closed by their owner's `deinit` instead of by an explicit close: each is a lifetime bug (a
/// descriptor kept open past its last use, or a close path missed).
///
/// SPI (`Testing`) rather than `package`: DiskTestSupport reads it, and Xcode's builds of the app's tests don't give a
/// package's other targets its `package` symbols (`cannot find 'DescriptorAudit' in scope`, 2026-11-23).
@_spi(Testing)
public enum DescriptorAudit {
    static let dropped = Atomic<Int>(0)

    /// A count of the descriptors dropped by one task and its children (one test's).
    final class Scope: Sendable {
        let dropped = Atomic<Int>(0)
    }

    /// The scope the current task counts into, if any. Read only when a descriptor was dropped (never on a normal path).
    @TaskLocal static var scope: Scope?

    /// Descriptors closed at `deinit` so far, in this process.
    public static var droppedCount: Int { dropped.load(ordering: .relaxed) }

    /// Runs `body` and returns how many descriptors it (and the tasks it started, which inherit the scope) dropped:
    /// tests running in parallel each count their own.
    public static func counting(_ body: @Sendable () async throws -> Void) async throws -> Int {
        let scope = Scope()
        try await $scope.withValue(scope) { try await body() }
        return scope.dropped.load(ordering: .relaxed)
    }

    /// Records one: counted, and named on stderr in debug builds so a failing test says which.
    static func record(_ descriptor: Int32, _ kind: DescriptorKind) {
        dropped.add(1, ordering: .relaxed)
        scope?.dropped.add(1, ordering: .relaxed)
        #if DEBUG
        let message = "Disk: \(kind) descriptor \(descriptor) was never closed (closed at deinit)\n"
        // Unsafe: `fputs` with a C string. Safe: `withCString`'s, valid for the call.
        _ = message.withCString { unsafe fputs($0, stderr) }
        #endif
    }
}

/// What a descriptor is, for the audit's message: a byte, so an `OwnedDescriptor?` stays 8 bytes in a writer's hot
/// state (a `StaticString` here made it 32, and the per-file paths 12–19 instructions longer).
enum DescriptorKind: UInt8, CustomStringConvertible {
    case destination, reopenedDestination, stagingParent, inputFile, outputFile, fileBeingWritten, largeFile

    var description: String {
        switch self {
        case .destination: "destination"
        case .reopenedDestination: "reopened destination"
        case .stagingParent: "staging parent"
        case .inputFile: "input file"
        case .outputFile: "output file"
        case .fileBeingWritten: "file being written"
        case .largeFile: "large file"
        }
    }
}

/// An open descriptor with one owner, closed exactly once by ``close()`` (or handed on by ``release()``).
struct OwnedDescriptor: ~Copyable {
    /// The descriptor.
    let raw: Int32
    /// What it is, for the audit's message.
    let kind: DescriptorKind

    /// Takes ownership of `raw`, an open descriptor.
    init(adopting raw: Int32, kind: DescriptorKind) {
        precondition(raw >= 0, "not an open descriptor")
        self.raw = raw
        self.kind = kind
    }

    /// Closes the descriptor: the end of its use.
    consuming func close() {
        Sys.close(raw)
        discard self
    }

    /// Gives up ownership without closing: for a call that takes the descriptor over (`fdopendir`) or another owner.
    consuming func release() -> Int32 {
        let raw = raw
        discard self
        return raw
    }

    deinit {
        DescriptorAudit.record(raw, kind)
        Sys.close(raw)
    }
}

/// A descriptor shared by readers on several threads, closed once by ``close()``; reads after that get -1.
struct DescriptorSlot: ~Copyable, Sendable {
    private let value: Atomic<Int32>
    /// What it is, for the audit's message.
    let kind: DescriptorKind

    /// A slot holding `owned`.
    init(_ owned: consuming OwnedDescriptor) {
        kind = owned.kind
        value = Atomic(owned.release())
    }

    /// An empty slot.
    init(empty kind: DescriptorKind) {
        self.kind = kind
        value = Atomic(-1)
    }

    /// The descriptor, or -1 once closed (calls then fail with `EBADF`, never reaching a reused number).
    var descriptor: Int32 { value.load(ordering: .relaxed) }

    /// Takes `owned` into an empty slot: for a holder reused for one descriptor after another (a large file's state).
    func adopt(_ owned: consuming OwnedDescriptor) {
        let previous = value.exchange(owned.release(), ordering: .acquiringAndReleasing)
        precondition(previous < 0, "a descriptor slot still holding an open descriptor")
    }

    /// Closes the descriptor if it's still open; safe to call from any thread, any number of times.
    ///
    /// - Returns: Whether this call closed it.
    @discardableResult
    func close() -> Bool {
        let descriptor = value.exchange(-1, ordering: .acquiringAndReleasing)
        guard descriptor >= 0 else { return false }
        Sys.close(descriptor)
        return true
    }

    /// ``close()``, with `close`'s error: 0, or its `errno` (0 too if it was already closed).
    func closeChecked() -> Int32 {
        let descriptor = value.exchange(-1, ordering: .acquiringAndReleasing)
        guard descriptor >= 0 else { return 0 }
        return Sys.closeChecked(descriptor)
    }

    deinit {
        let descriptor = value.load(ordering: .relaxed)
        if descriptor >= 0 {
            DescriptorAudit.record(descriptor, kind)
            Sys.close(descriptor)
        }
    }
}
