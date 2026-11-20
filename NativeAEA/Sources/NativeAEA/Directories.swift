import Darwin

/// The directories the walker made, by path, each with an open descriptor, so entries are created relative to their
/// parent (`openat(parent, "name")`, one path component) instead of from the destination (Xcode's paths are 10–14
/// components deep, each looked up per call).
///
/// An open-addressed table keyed by the path's bytes, kept in one arena: no allocation per lookup. Only the walker
/// thread touches it; writers get descriptors in their jobs. A directory whose descriptor couldn't be opened (the
/// process's descriptor limit) isn't in it, and its entries fall back to paths from the destination.
///
/// Empty unless ``AEAExtractionOptions/relativeToParents`` opens directories (it's off by default): then it allocates
/// nothing, and ``resolve(_:count:)`` returns the destination at once, without scanning or hashing the path.
struct DirectoryTable: ~Copyable {
    private var arena: [UInt8] = []
    private var entries: [(hash: UInt64, start: Int, count: Int, descriptor: Int32)] = []
    /// Indices into `entries`, plus one; 0 is empty. A power of two, at most half full; empty until the first insert.
    private var slots: [Int32] = []
    let root: Int32

    init(root: Int32) {
        self.root = root
    }

    /// Every directory descriptor, for setting attributes at the end.
    func descriptor(atEntry index: Int) -> Int32 { entries[index].descriptor }

    @inline(__always)
    private static func hash(_ bytes: UnsafeRawPointer, _ count: Int) -> UInt64 {
        // FNV-1a.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for index in 0..<count {
            hash = (hash ^ UInt64(unsafe bytes.load(fromByteOffset: index, as: UInt8.self))) &* 0x100_0000_01B3
        }
        return hash
    }

    /// The descriptor of the directory at `path`, or `nil` if the walker didn't open it.
    func lookup(_ path: UnsafeRawPointer, count: Int) -> Int32? {
        if count == 0 { return root }
        if entries.isEmpty { return nil }
        let hash = unsafe Self.hash(path, count)
        let mask = slots.count - 1
        var slot = Int(truncatingIfNeeded: hash) & mask
        while slots[slot] != 0 {
            let entry = entries[Int(slots[slot]) - 1]
            if entry.hash == hash, entry.count == count {
                // Arena bytes against the path's: both `count` long.
                let equal = arena.withUnsafeBytes { unsafe memcmp($0.baseAddress! + entry.start, path, count) == 0 }
                if equal { return entry.descriptor }
            }
            slot = (slot + 1) & mask
        }
        return nil
    }

    /// Records the directory at `path`, open as `descriptor`.
    ///
    /// - Returns: The entry's index.
    @discardableResult
    mutating func insert(_ path: UnsafeRawPointer, count: Int, descriptor: Int32) -> Int {
        if slots.isEmpty {
            // The first directory: room for Xcode's 30,000 without growing.
            slots = Array(repeating: 0, count: 1 << 16)
            arena.reserveCapacity(4 << 20)
            entries.reserveCapacity(1 << 15)
        }
        if (entries.count + 1) * 2 > slots.count { grow() }
        let hash = unsafe Self.hash(path, count)
        let start = arena.count
        unsafe arena.append(contentsOf: UnsafeRawBufferPointer(start: path, count: count)) // The caller's path bytes: safe.
        entries.append((hash, start, count, descriptor))
        place(entries.count - 1)
        return entries.count - 1
    }

    private mutating func place(_ index: Int) {
        let mask = slots.count - 1
        var slot = Int(truncatingIfNeeded: entries[index].hash) & mask
        while slots[slot] != 0 { slot = (slot + 1) & mask }
        slots[slot] = Int32(index + 1)
    }

    private mutating func grow() {
        slots = Array(repeating: 0, count: slots.count * 2)
        for index in entries.indices { place(index) }
    }

    /// Splits `path` into its parent's descriptor and the name in it, or the destination and the whole path when the
    /// parent wasn't opened.
    func resolve(_ path: UnsafeRawPointer, count: Int) -> (directory: Int32, leaf: Int) {
        // No directory opened: every path is from the destination (what the scan and lookup below would find).
        if entries.isEmpty { return (root, 0) }
        var slash = count - 1
        while slash >= 0, unsafe path.load(fromByteOffset: slash, as: UInt8.self) != 0x2F { slash -= 1 }
        guard slash >= 0 else { return (root, 0) }
        if let parent = unsafe lookup(path, count: slash) { return (parent, slash + 1) }
        return (root, 0)
    }

    func closeAll() {
        for entry in entries { close(entry.descriptor) }
    }

    /// Raises the process's soft descriptor limit as far as the system allows (Xcode has 30,000 directories).
    static func raiseDescriptorLimit() {
        var limit = rlimit()
        guard unsafe getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        var perProcess: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let maximum = unsafe sysctlbyname("kern.maxfilesperproc", &perProcess, &size, nil, 0) == 0 ? rlim_t(perProcess) : limit.rlim_max
        let wanted = min(limit.rlim_max, maximum)
        if limit.rlim_cur < wanted {
            limit.rlim_cur = wanted
            _ = unsafe setrlimit(RLIMIT_NOFILE, &limit)
        }
    }
}

/// The walker's per-entry parent lookup, for benchmarks: ``DirectoryTable/resolve(_:count:)`` as the extraction sink
/// calls it for every file, directory, and link, with no directories opened (the default).
@_spi(Benchmarking)
public enum DirectoryResolution {
    /// Makes a table, then resolves each of `paths` (ranges of `bytes`) `rounds` times.
    ///
    /// - Returns: The sum of the results' name offsets, so the work isn't optimized away.
    public static func resolve(_ bytes: [UInt8], paths: [Range<Int>], rounds: Int) -> Int {
        let table = DirectoryTable(root: 3)
        var sum = 0
        bytes.withUnsafeBytes { buffer in
            for _ in 0..<rounds {
                for path in paths {
                    // A range of `bytes`, which outlives the call: safe.
                    let (directory, leaf) = unsafe table.resolve(buffer.baseAddress! + path.lowerBound, count: path.count)
                    sum &+= Int(directory) &+ leaf
                }
            }
        }
        return sum
    }
}
