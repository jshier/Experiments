import Darwin
import Dispatch
import Foundation

// Raw macOS calls, measured outside Disk before choosing among them (Disk/RESULTS.md says what was chosen and why).
// Single-threaded, each in a fresh directory.

enum Probe {
    /// Opens (making) a directory for a probe.
    static func directory(_ path: String) -> Int32 {
        mkdir(path, 0o755)
        return open(path, O_RDONLY | O_DIRECTORY)
    }

    /// The attributes `fsetattrlist` takes for times (and optionally mode and flags) in one call.
    static func setAll(_ descriptor: Int32, mode: UInt32?, flags: UInt32?) -> Int32 {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_CRTIME) | attrgroup_t(ATTR_CMN_MODTIME)
        var buffer = [UInt8](repeating: 0, count: 64)
        var count = 32
        buffer.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: timespec(tv_sec: 1_000_000_000, tv_nsec: 0), toByteOffset: 0, as: timespec.self)
            raw.storeBytes(of: timespec(tv_sec: 1_000_000_000, tv_nsec: 0), toByteOffset: 16, as: timespec.self)
            if let mode {
                list.commonattr |= attrgroup_t(ATTR_CMN_ACCESSMASK)
                raw.storeBytes(of: mode, toByteOffset: count, as: UInt32.self)
                count += 4
            }
            if let flags {
                list.commonattr |= attrgroup_t(ATTR_CMN_FLAGS)
                raw.storeBytes(of: flags, toByteOffset: count, as: UInt32.self)
                count += 4
            }
        }
        return buffer.withUnsafeMutableBytes { fsetattrlist(descriptor, &list, $0.baseAddress!, count, 0) }
    }

    /// `count` small files with mode, flags, and times: separate calls (`fchmod`, `fchflags`, `fsetattrlist` times) or
    /// one `fsetattrlist`.
    static func smallFiles(in path: String, count: Int, bytes: [UInt8], combined: Bool) {
        let directory = Self.directory(path)
        defer { close(directory) }
        var name = [CChar](repeating: 0, count: 64)
        for index in 0..<count {
            _ = snprintf(ptr: &name, 64, "f%d", Int32(index))
            let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY, 0o600)
            _ = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
            if combined {
                _ = setAll(descriptor, mode: 0o444, flags: UInt32(UF_HIDDEN))
            } else {
                _ = fchmod(descriptor, 0o444)
                _ = fchflags(descriptor, UInt32(UF_HIDDEN))
                _ = setAll(descriptor, mode: nil, flags: nil)
            }
            close(descriptor)
        }
    }

    /// `count` identical files: written, or cloned (`clonefileat`) from the first.
    static func identicalFiles(in path: String, count: Int, bytes: [UInt8], clone: Bool) {
        let directory = Self.directory(path)
        defer { close(directory) }
        var name = [CChar](repeating: 0, count: 64)
        for index in 0..<count {
            _ = snprintf(ptr: &name, 64, "f%d", Int32(index))
            if clone, index > 0 {
                _ = clonefileat(directory, "f0", directory, name, UInt32(CLONE_NOFOLLOW))
                continue
            }
            let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            _ = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
            close(descriptor)
        }
    }

    enum LargeWrite: String, CaseIterable {
        case whole = "one pwrite"
        case pieces = "8 MiB pwrites"
        case noCache = "8 MiB pwrites, F_NOCACHE"
        case preallocate = "8 MiB pwrites, F_PREALLOCATE"
        case dispatchIO = "DispatchIO, 8 MiB chunks"
        case mapped = "mmap and copy"
    }

    /// Writes `bytes` (a stable buffer) as one large file, by `method`.
    static func largeFile(at path: String, _ bytes: UnsafeRawBufferPointer, method: LargeWrite) {
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        defer { close(descriptor) }
        let piece = 8 << 20
        func pieces() {
            var offset = 0
            while offset < bytes.count {
                let count = min(piece, bytes.count - offset)
                _ = pwrite(descriptor, bytes.baseAddress! + offset, count, off_t(offset))
                offset += count
            }
        }
        switch method {
        case .whole:
            var offset = 0
            while offset < bytes.count {
                let written = pwrite(descriptor, bytes.baseAddress! + offset, bytes.count - offset, off_t(offset))
                guard written > 0 else { return }
                offset += written
            }
        case .pieces:
            pieces()
        case .noCache:
            _ = fcntl(descriptor, F_NOCACHE, 1)
            pieces()
        case .preallocate:
            var store = fstore_t(fst_flags: UInt32(F_ALLOCATEALL | F_ALLOCATECONTIG), fst_posmode: F_PEOFPOSMODE, fst_offset: 0, fst_length: off_t(bytes.count), fst_bytesalloc: 0)
            if fcntl(descriptor, F_PREALLOCATE, &store) != 0 {
                store.fst_flags = UInt32(F_ALLOCATEALL)
                _ = fcntl(descriptor, F_PREALLOCATE, &store)
            }
            pieces()
        case .dispatchIO:
            let queue = DispatchQueue(label: "probe")
            let channel = DispatchIO(type: .random, fileDescriptor: descriptor, queue: queue) { _ in }
            let group = DispatchGroup()
            var offset = 0
            while offset < bytes.count {
                let count = min(piece, bytes.count - offset)
                // No copy: the data borrows the buffer (it outlives the writes).
                let data = DispatchData(bytesNoCopy: UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + count)]), deallocator: .custom(nil, {}))
                group.enter()
                channel.write(offset: off_t(offset), data: data, queue: queue) { done, _, _ in if done { group.leave() } }
                offset += count
            }
            group.wait()
            channel.close()
        case .mapped:
            _ = ftruncate(descriptor, off_t(bytes.count))
            guard let mapping = mmap(nil, bytes.count, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0), mapping != MAP_FAILED else { return }
            mapping.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            munmap(mapping, bytes.count)
        }
    }
}
