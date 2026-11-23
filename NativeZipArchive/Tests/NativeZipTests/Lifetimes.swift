import BytesTesting
import DiskTestSupport
import Testing

extension Trait where Self == LifetimeChecks {
    /// Every test: nothing left open under its temporary directories, and no Disk descriptor closed at `deinit` (each
    /// extraction closes its destination when Disk's extraction returns; tests close the ones they open).
    static var diskLifetimes: Self {
        .lifetimeChecked(audit: "descriptors closed at deinit") { try await DiskLifetimes.dropped(during: $0) }
    }
}
