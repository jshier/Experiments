import Darwin

/// The file system calls Disk makes, each through a wrapper here, so the `SyscallCounting` trait can count them.
///
/// package-benchmark's `.syscalls` metric on macOS is the process's total (`proc_pidinfo`'s Unix and Mach calls,
/// every thread, the runtime's waits and the allocator's too), so it can't say what one entry costs. These counters
/// are exactly Disk's calls, by kind. Without the trait (the default) the wrappers are the calls themselves: nothing is
/// compiled in.
enum SyscallKind: Int, CaseIterable, Sendable {
    case openat, close, pwrite, mkdirat, fsetxattr, fsetattrlist, setattrlistat, fchflags
    case symlinkat, linkat, unlinkat, mkfifoat, mknodat, fstatat, fstat, fgetxattr, fremovexattr, setxattr, aclSet
    case renameat, other
}

#if DISK_SYSCALL_COUNTING
/// One atomic counter per kind of call.
final class SyscallCounters: Sendable {
    static let shared = SyscallCounters()
    let counts: [Counter] = SyscallKind.allCases.map { _ in Counter() }
}
#endif

@inline(__always)
func countSyscall(_ kind: SyscallKind) {
    #if DISK_SYSCALL_COUNTING
    SyscallCounters.shared.counts[kind.rawValue].add()
    #endif
}

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
        SyscallCounters.shared.counts.reduce(0) { $0 + $1.value }
        #else
        0
        #endif
    }

    /// Calls made so far by kind (empty without the trait).
    public static var byKind: [String: Int] {
        #if DISK_SYSCALL_COUNTING
        var result: [String: Int] = [:]
        for kind in SyscallKind.allCases {
            let count = SyscallCounters.shared.counts[kind.rawValue].value
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
        countSyscall(.openat)
        // Unsafe: `path` to `openat`. Safe: the caller's NUL-terminated string, read only during the call.
        return unsafe Darwin.openat(directory, path, flags, mode)
    }

    @inline(__always)
    static func close(_ descriptor: Int32) {
        countSyscall(.close)
        _ = Darwin.close(descriptor)
    }

    @inline(__always)
    static func pwrite(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int, _ offset: Int) -> Int {
        countSyscall(.pwrite)
        // Unsafe: `bytes` to `pwrite`. Safe: the caller's `count` readable bytes, read only during the call.
        return unsafe Darwin.pwrite(descriptor, bytes, count, off_t(offset))
    }

    @inline(__always)
    static func mkdirat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32 {
        countSyscall(.mkdirat)
        // Unsafe: `path` to `mkdirat`. Safe: the caller's NUL-terminated string, read only during the call.
        return unsafe Darwin.mkdirat(directory, path, mode)
    }

    @inline(__always)
    static func fsetxattr(_ descriptor: Int32, _ name: UnsafePointer<CChar>, _ value: UnsafeRawPointer?, _ count: Int, _ position: Int, _ options: Int32 = 0) -> Int32 {
        countSyscall(.fsetxattr)
        // Unsafe: `name` and `value` to `fsetxattr`. Safe: the caller's NUL-terminated name and `count` readable bytes
        // (or `nil` with 0), read only during the call.
        return unsafe Darwin.fsetxattr(descriptor, name, value, count, UInt32(truncatingIfNeeded: position), options)
    }

    @inline(__always)
    static func fsetattrlist(_ descriptor: Int32, _ list: UnsafeMutablePointer<attrlist>, _ values: UnsafeMutableRawPointer, _ count: Int) -> Int32 {
        countSyscall(.fsetattrlist)
        // Unsafe: `list` and `values` to `fsetattrlist`. Safe: the caller's attribute list and `count` bytes of values,
        // read only during the call.
        return unsafe Darwin.fsetattrlist(descriptor, list, values, count, 0)
    }

    @inline(__always)
    static func setattrlistat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ list: UnsafeMutablePointer<attrlist>, _ values: UnsafeMutableRawPointer, _ count: Int, _ options: UInt32) -> Int32 {
        countSyscall(.setattrlistat)
        // Unsafe: `path`, `list`, and `values` to `setattrlistat`. Safe: the caller's NUL-terminated string, attribute
        // list, and `count` bytes of values, read only during the call.
        return unsafe Darwin.setattrlistat(directory, path, list, values, count, options)
    }

    @inline(__always)
    static func fchflags(_ descriptor: Int32, _ flags: UInt32) -> Int32 {
        countSyscall(.fchflags)
        return Darwin.fchflags(descriptor, flags)
    }

    @inline(__always)
    static func symlinkat(_ target: UnsafePointer<CChar>, _ directory: Int32, _ name: UnsafePointer<CChar>) -> Int32 {
        countSyscall(.symlinkat)
        // Unsafe: `target` and `name` to `symlinkat`. Safe: the caller's NUL-terminated strings, read only during the
        // call.
        return unsafe Darwin.symlinkat(target, directory, name)
    }

    @inline(__always)
    static func linkat(_ fromDirectory: Int32, _ from: UnsafePointer<CChar>, _ toDirectory: Int32, _ to: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
        countSyscall(.linkat)
        // Unsafe: `from` and `to` to `linkat`. Safe: the caller's NUL-terminated strings, read only during the call.
        return unsafe Darwin.linkat(fromDirectory, from, toDirectory, to, flags)
    }

    @inline(__always)
    static func unlinkat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
        countSyscall(.unlinkat)
        // Unsafe: `path` to `unlinkat`. Safe: the caller's NUL-terminated string, read only during the call.
        return unsafe Darwin.unlinkat(directory, path, flags)
    }

    @inline(__always)
    static func mkfifoat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32 {
        countSyscall(.mkfifoat)
        // Unsafe: `path` to `mkfifoat`. Safe: the caller's NUL-terminated string, read only during the call.
        return unsafe Darwin.mkfifoat(directory, path, mode)
    }

    @inline(__always)
    static func mknodat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ mode: mode_t, _ device: dev_t) -> Int32 {
        countSyscall(.mknodat)
        // Unsafe: `path` to `mknodat`. Safe: the caller's NUL-terminated string, read only during the call.
        return unsafe Darwin.mknodat(directory, path, mode, device)
    }

    @inline(__always)
    static func fstatat(_ directory: Int32, _ path: UnsafePointer<CChar>, _ info: inout stat, _ flags: Int32) -> Int32 {
        countSyscall(.fstatat)
        // Unsafe: `path` and a pointer to `info` to `fstatat`. Safe: the caller's NUL-terminated string, read during
        // the call, which writes one `stat` into the caller's `inout` one.
        return unsafe Darwin.fstatat(directory, path, &info, flags)
    }

    @inline(__always)
    static func fstat(_ descriptor: Int32, _ info: inout stat) -> Int32 {
        countSyscall(.fstat)
        // Unsafe: a pointer to `info` to `fstat`. Safe: the call writes one `stat` into the caller's `inout` one.
        return unsafe Darwin.fstat(descriptor, &info)
    }

    @inline(__always)
    static func fgetxattr(_ descriptor: Int32, _ name: UnsafePointer<CChar>, _ value: UnsafeMutableRawPointer?, _ count: Int, _ position: Int) -> Int {
        countSyscall(.fgetxattr)
        // Unsafe: `name` and `value` to `fgetxattr`. Safe: the caller's NUL-terminated name, and `count` writable bytes
        // (or `nil` with 0, to ask the size), used only during the call.
        return unsafe Darwin.fgetxattr(descriptor, name, value, count, UInt32(truncatingIfNeeded: position), 0)
    }

    @inline(__always)
    static func fremovexattr(_ descriptor: Int32, _ name: UnsafePointer<CChar>) -> Int32 {
        countSyscall(.fremovexattr)
        // Unsafe: `name` to `fremovexattr`. Safe: the caller's NUL-terminated string, read only during the call.
        return unsafe Darwin.fremovexattr(descriptor, name, 0)
    }

    @inline(__always)
    static func setxattr(_ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>, _ value: UnsafeRawPointer?, _ count: Int, _ options: Int32) -> Int32 {
        countSyscall(.setxattr)
        // Unsafe: `path`, `name`, and `value` to `setxattr`. Safe: the caller's NUL-terminated strings and `count`
        // readable bytes (or `nil` with 0), read only during the call.
        return unsafe Darwin.setxattr(path, name, value, count, 0, options)
    }

    @inline(__always)
    static func aclSet(_ descriptor: Int32, _ acl: acl_t) -> Int32 {
        countSyscall(.aclSet)
        // Unsafe: `acl` to `acl_set_fd_np`. Safe: the caller's live ACL (not yet `acl_free`d), read only during the
        // call.
        return unsafe acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED)
    }

    @inline(__always)
    static func renameatx(_ fromDirectory: Int32, _ from: UnsafePointer<CChar>, _ toDirectory: Int32, _ to: UnsafePointer<CChar>, _ flags: UInt32) -> Int32 {
        countSyscall(.renameat)
        // Unsafe: `from` and `to` to `renameatx_np`. Safe: the caller's NUL-terminated strings, read only during the
        // call.
        return unsafe renameatx_np(fromDirectory, from, toDirectory, to, flags)
    }

    @inline(__always)
    static func countOther() {
        countSyscall(.other)
    }
}
