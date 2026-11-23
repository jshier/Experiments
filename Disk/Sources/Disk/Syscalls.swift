#if DISK_SYSCALL_COUNTING
import BytesAsync
#endif
import Darwin
#if DEBUG
import Synchronization
#endif

/// The file system calls Disk makes, each through a wrapper here, so the `SyscallCounting` trait can count them.
///
/// package-benchmark's `.syscalls` metric on macOS is the process's total (`proc_pidinfo`'s Unix and Mach calls,
/// every thread, the runtime's waits and the allocator's too), so it can't say what one entry costs. These counters
/// are exactly Disk's calls, by kind. Without the trait (the default) the wrappers are the calls themselves: nothing is
/// compiled in.
package enum SyscallKind: Int, CaseIterable, Sendable {
    case openat, close, pwrite, mkdirat, fsetxattr, fsetattrlist, setattrlistat, fchflags
    case symlinkat, linkat, unlinkat, mkfifoat, mknodat, fstatat, fstat, fgetxattr, fremovexattr, setxattr, aclSet
    case renameat, pread, read, other
}

#if DISK_SYSCALL_COUNTING
/// One atomic counter per kind of call, in one allocation.
enum SyscallCounters {
    static let shared = RelaxedCounters(count: SyscallKind.allCases.count)
}
#endif

@inline(__always)
func countSyscall(_ kind: SyscallKind) {
    #if DISK_SYSCALL_COUNTING
    SyscallCounters.shared.add(at: kind.rawValue)
    #endif
}

/// Counts a call (with the trait) and says whether to fail it instead (`errno` set): `false` always outside debug
/// builds, where it compiles to nothing.
@inline(__always)
func enterSyscall(_ kind: SyscallKind) -> Bool {
    countSyscall(kind)
    #if DEBUG
    if let faults = SyscallFaults.current, let code = faults.failures[kind] {
        faults.failed.add(1, ordering: .relaxed)
        errno = code
        return true
    }
    #endif
    return false
}

#if DEBUG
/// Debug builds only: failures injected into Disk's calls, for the task that sets them and the tasks it starts (an
/// extraction's writers), and the descriptors those tasks opened and closed, in order. Tests reach the paths a real
/// volume rarely takes (a quarantine refused, a full disk) and check that every descriptor is closed exactly once.
///
/// ```swift
/// let faults = SyscallFaults(failing: [.fsetxattr: ENOTSUP])
/// try await faults.run { … }
/// #expect(faults.doubleCloses.isEmpty && faults.leftOpen.isEmpty)
/// ```
package final class SyscallFaults: Sendable {
    /// The calls to fail, with the `errno` each sets.
    package let failures: [SyscallKind: Int32]
    /// Opens (`true`) and closes, in order.
    private let events = Mutex<[(open: Bool, descriptor: Int32)]>([])
    let failed = Atomic<Int>(0)

    /// Calls failed so far (a test that injects a failure checks the code reached the call).
    package var injected: Int { failed.load(ordering: .relaxed) }

    @TaskLocal static var current: SyscallFaults?

    package init(failing failures: [SyscallKind: Int32] = [:]) {
        self.failures = failures
    }

    /// Descriptors opened (`openat`, `fcntl(F_DUPFD)`), in order.
    package var opened: [Int32] { events.withLock { $0.filter(\.open).map(\.descriptor) } }
    /// Descriptors closed, in order.
    package var closed: [Int32] { events.withLock { $0.filter { !$0.open }.map(\.descriptor) } }

    /// Descriptors closed when not open (twice, or never opened in this scope): each a close that could have hit
    /// another thread's file.
    package var doubleCloses: [Int32] { walk().doubleCloses }
    /// Descriptors opened in this scope and still open.
    package var leftOpen: [Int32] { walk().open.sorted() }

    private func walk() -> (open: Set<Int32>, doubleCloses: [Int32]) {
        var open = Set<Int32>(), doubleCloses: [Int32] = []
        for event in events.withLock({ $0 }) {
            if event.open {
                open.insert(event.descriptor)
            } else if open.remove(event.descriptor) == nil {
                doubleCloses.append(event.descriptor)
            }
        }
        return (open, doubleCloses)
    }

    /// Runs `body` with these faults.
    @discardableResult
    package func run<R>(_ body: () throws -> R) rethrows -> R {
        try Self.$current.withValue(self) { try body() }
    }

    /// Runs `body` with these faults.
    @discardableResult
    package func run<R>(_ body: () async throws -> R) async rethrows -> R {
        try await Self.$current.withValue(self) { try await body() }
    }

    static func recordOpen(_ descriptor: Int32) {
        if descriptor >= 0, let faults = current { faults.events.withLock { $0.append((true, descriptor)) } }
    }

    static func recordClose(_ descriptor: Int32) {
        if let faults = current { faults.events.withLock { $0.append((false, descriptor)) } }
    }
}
#endif

/// The counts, for the benchmarks' custom metric.
@_spi(Benchmarking)
public enum SyscallCounter {
    /// Whether this build counts (the `SyscallCounting` trait).
    public static var isEnabled: Bool {
        #if DISK_SYSCALL_COUNTING
        true
        #else
        false
        #endif
    }

    /// Calls made so far, all kinds together (0 without the trait).
    public static var total: Int {
        #if DISK_SYSCALL_COUNTING
        (0..<SyscallCounters.shared.count).reduce(0) { $0 + SyscallCounters.shared.value(at: $1) }
        #else
        0
        #endif
    }

    /// Calls made so far by kind (empty without the trait).
    public static var byKind: [String: Int] {
        #if DISK_SYSCALL_COUNTING
        var result: [String: Int] = [:]
        for kind in SyscallKind.allCases {
            let count = SyscallCounters.shared.value(at: kind.rawValue)
            if count > 0 { result["\(kind)"] = count }
        }
        return result
        #else
        [:]
        #endif
    }
}

/// The wrapped calls. Each takes C strings and buffers the caller keeps valid for the call. Unsafe throughout: each
/// passes the caller's pointers on to the call, which reads or writes them only during it.
enum Sys {
    @inline(__always)
    static func openat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t = 0) -> Int32 {
        if enterSyscall(.openat) { return -1 }
        // Unsafe: `path` to `openat`. Safe: the caller's NUL-terminated string, read only during the call.
        let descriptor = unsafe Darwin.openat(directory, path, flags, mode)
        #if DEBUG
        SyscallFaults.recordOpen(descriptor)
        #endif
        return descriptor
    }

    @inline(__always)
    static func close(_ descriptor: Int32) {
        countSyscall(.close)
        #if DEBUG
        SyscallFaults.recordClose(descriptor)
        #endif
        _ = Darwin.close(descriptor)
    }

    /// `close`, with its error: 0, or the `errno` it set (for a file just written, a failed close can be the only sign
    /// that data didn't reach the disk). The descriptor is released either way.
    @inline(__always)
    static func closeChecked(_ descriptor: Int32) -> Int32 {
        countSyscall(.close)
        #if DEBUG
        SyscallFaults.recordClose(descriptor)
        #endif
        return Darwin.close(descriptor) == 0 ? 0 : errno
    }

    @inline(__always)
    static func pwrite(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int, _ offset: Int) -> Int {
        if enterSyscall(.pwrite) { return -1 }
        // Unsafe: `bytes` to `pwrite`. Safe: the caller's `count` readable bytes, read only during the call.
        return unsafe Darwin.pwrite(descriptor, bytes, count, off_t(offset))
    }

    @inline(__always)
    static func pread(_ descriptor: Int32, _ bytes: UnsafeMutableRawPointer, _ count: Int, _ offset: Int) -> Int {
        if enterSyscall(.pread) { return -1 }
        // Unsafe: `bytes` to `pread`. Safe: the caller's `count` writable bytes, written only during the call.
        return unsafe Darwin.pread(descriptor, bytes, count, off_t(offset))
    }

    @inline(__always)
    static func read(_ descriptor: Int32, _ bytes: UnsafeMutableRawPointer, _ count: Int) -> Int {
        if enterSyscall(.read) { return -1 }
        // Unsafe: `bytes` to `read`. Safe: the caller's `count` writable bytes, written only during the call.
        return unsafe Darwin.read(descriptor, bytes, count)
    }

    @inline(__always)
    static func mkdirat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32 {
        if enterSyscall(.mkdirat) { return -1 }
        // Unsafe: `path` to `mkdirat`. Safe: the caller's NUL-terminated string, read only during the call.
        return unsafe Darwin.mkdirat(directory, path, mode)
    }

    @inline(__always)
    static func fsetxattr(_ descriptor: Int32, _ name: UnsafePointer<CChar>, _ value: UnsafeRawPointer?, _ count: Int, _ position: Int, _ options: Int32 = 0) -> Int32 {
        if enterSyscall(.fsetxattr) { return -1 }
        // Unsafe: `name` and `value` to `fsetxattr`. Safe: the caller's NUL-terminated name and `count` readable bytes
        // (or `nil` with 0), read only during the call.
        return unsafe Darwin.fsetxattr(descriptor, name, value, count, UInt32(truncatingIfNeeded: position), options)
    }

    @inline(__always)
    static func fsetattrlist(_ descriptor: Int32, _ list: UnsafeMutablePointer<attrlist>, _ values: UnsafeMutableRawPointer, _ count: Int) -> Int32 {
        if enterSyscall(.fsetattrlist) { return -1 }
        // Unsafe: `list` and `values` to `fsetattrlist`. Safe: the caller's attribute list and `count` bytes of values,
        // read only during the call.
        return unsafe Darwin.fsetattrlist(descriptor, list, values, count, 0)
    }

    @inline(__always)
    static func setattrlistat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ list: UnsafeMutablePointer<attrlist>, _ values: UnsafeMutableRawPointer, _ count: Int, _ options: UInt32) -> Int32 {
        if enterSyscall(.setattrlistat) { return -1 }
        // Unsafe: `path`, `list`, and `values` to `setattrlistat`. Safe: the caller's NUL-terminated string, attribute
        // list, and `count` bytes of values, read only during the call.
        return unsafe Darwin.setattrlistat(directory, path, list, values, count, options)
    }

    @inline(__always)
    static func fchflags(_ descriptor: Int32, _ flags: UInt32) -> Int32 {
        if enterSyscall(.fchflags) { return -1 }
        return Darwin.fchflags(descriptor, flags)
    }

    @inline(__always)
    static func symlinkat(_ target: UnsafePointer<CChar>, _ directory: Int32, _ name: UnsafePointer<CChar>) -> Int32 {
        if enterSyscall(.symlinkat) { return -1 }
        // Unsafe: `target` and `name` to `symlinkat`. Safe: the caller's NUL-terminated strings, read only during the
        // call.
        return unsafe Darwin.symlinkat(target, directory, name)
    }

    @inline(__always)
    static func linkat(_ fromDirectory: Int32, _ from: UnsafePointer<CChar>, _ toDirectory: Int32, _ to: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
        if enterSyscall(.linkat) { return -1 }
        // Unsafe: `from` and `to` to `linkat`. Safe: the caller's NUL-terminated strings, read only during the call.
        return unsafe Darwin.linkat(fromDirectory, from, toDirectory, to, flags)
    }

    @inline(__always)
    static func unlinkat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
        if enterSyscall(.unlinkat) { return -1 }
        // Unsafe: `path` to `unlinkat`. Safe: the caller's NUL-terminated string, read only during the call.
        return unsafe Darwin.unlinkat(directory, path, flags)
    }

    @inline(__always)
    static func mkfifoat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32 {
        if enterSyscall(.mkfifoat) { return -1 }
        // Unsafe: `path` to `mkfifoat`. Safe: the caller's NUL-terminated string, read only during the call.
        return unsafe Darwin.mkfifoat(directory, path, mode)
    }

    @inline(__always)
    static func mknodat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ mode: mode_t, _ device: dev_t) -> Int32 {
        if enterSyscall(.mknodat) { return -1 }
        // Unsafe: `path` to `mknodat`. Safe: the caller's NUL-terminated string, read only during the call.
        return unsafe Darwin.mknodat(directory, path, mode, device)
    }

    @inline(__always)
    static func fstatat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ info: inout stat, _ flags: Int32) -> Int32 {
        if enterSyscall(.fstatat) { return -1 }
        // Unsafe: `path` and a pointer to `info` to `fstatat`. Safe: the caller's NUL-terminated string, read during
        // the call, which writes one `stat` into the caller's `inout` one.
        return unsafe Darwin.fstatat(directory, path, &info, flags)
    }

    @inline(__always)
    static func fstat(_ descriptor: Int32, _ info: inout stat) -> Int32 {
        if enterSyscall(.fstat) { return -1 }
        // Unsafe: a pointer to `info` to `fstat`. Safe: the call writes one `stat` into the caller's `inout` one.
        return unsafe Darwin.fstat(descriptor, &info)
    }

    @inline(__always)
    static func fgetxattr(_ descriptor: Int32, _ name: UnsafePointer<CChar>, _ value: UnsafeMutableRawPointer?, _ count: Int, _ position: Int) -> Int {
        if enterSyscall(.fgetxattr) { return -1 }
        // Unsafe: `name` and `value` to `fgetxattr`. Safe: the caller's NUL-terminated name, and `count` writable bytes
        // (or `nil` with 0, to ask the size), used only during the call.
        return unsafe Darwin.fgetxattr(descriptor, name, value, count, UInt32(truncatingIfNeeded: position), 0)
    }

    @inline(__always)
    static func fremovexattr(_ descriptor: Int32, _ name: UnsafePointer<CChar>) -> Int32 {
        if enterSyscall(.fremovexattr) { return -1 }
        // Unsafe: `name` to `fremovexattr`. Safe: the caller's NUL-terminated string, read only during the call.
        return unsafe Darwin.fremovexattr(descriptor, name, 0)
    }

    @inline(__always)
    static func setxattr(_ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>, _ value: UnsafeRawPointer?, _ count: Int, _ options: Int32) -> Int32 {
        if enterSyscall(.setxattr) { return -1 }
        // Unsafe: `path`, `name`, and `value` to `setxattr`. Safe: the caller's NUL-terminated strings and `count`
        // readable bytes (or `nil` with 0), read only during the call.
        return unsafe Darwin.setxattr(path, name, value, count, 0, options)
    }

    @inline(__always)
    static func aclSet(_ descriptor: Int32, _ acl: acl_t) -> Int32 {
        if enterSyscall(.aclSet) { return -1 }
        // Unsafe: `acl` to `acl_set_fd_np`. Safe: the caller's live ACL (not yet `acl_free`d), read only during the
        // call.
        return unsafe acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED)
    }

    @inline(__always)
    static func renameatx(_ fromDirectory: Int32, _ from: UnsafePointer<CChar>, _ toDirectory: Int32, _ to: UnsafePointer<CChar>, _ flags: UInt32) -> Int32 {
        if enterSyscall(.renameat) { return -1 }
        // Unsafe: `from` and `to` to `renameatx_np`. Safe: the caller's NUL-terminated strings, read only during the
        // call.
        return unsafe renameatx_np(fromDirectory, from, toDirectory, to, flags)
    }

    /// `fcntl(F_DUPFD_CLOEXEC)`: a second descriptor for the same open file.
    @inline(__always)
    static func duplicate(_ descriptor: Int32) -> Int32 {
        if enterSyscall(.other) { return -1 }
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        #if DEBUG
        SyscallFaults.recordOpen(duplicate)
        #endif
        return duplicate
    }

    /// `closedir`, which closes the descriptor `fdopendir` took (`descriptor`, recorded as closed in debug builds).
    @inline(__always)
    static func closedir(_ stream: UnsafeMutablePointer<DIR>, descriptor: Int32) {
        countSyscall(.close)
        #if DEBUG
        SyscallFaults.recordClose(descriptor)
        #endif
        // Unsafe: `closedir` on the caller's stream. Safe: the caller's open stream, closed once here and not used after.
        _ = unsafe Darwin.closedir(stream)
    }

    @inline(__always)
    static func countOther() {
        countSyscall(.other)
    }
}
