@_spi(Testing) import Disk

/// Disk's descriptor audit, for other packages' tests: a test's clients (NativeAEA's archives, NativeZip's
/// extractions) must close every Disk descriptor they own explicitly.
///
/// ```swift
/// extension Trait where Self == LifetimeChecks {
///     static var diskLifetimes: Self {
///         .lifetimeChecked(audit: "descriptors closed at deinit") { try await DiskLifetimes.dropped(during: $0) }
///     }
/// }
/// ```
public enum DiskLifetimes {
    /// Runs `body` and returns how many of Disk's descriptors were closed by their owner's `deinit` (never closed
    /// explicitly) by it and the tasks it started.
    public static func dropped(during body: @Sendable () async throws -> Void) async throws -> Int {
        try await DescriptorAudit.counting(body)
    }
}
