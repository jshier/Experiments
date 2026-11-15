/// Builds length-limited canonical Huffman codes from symbol frequencies, for the DEFLATE and Brotli
/// encoders.
///
/// libdeflate's algorithm (`make_huffman_code`): sort the used symbols by frequency with a counting sort,
/// build the tree in place in the sorted array (two queues, leaves and internal nodes, no heap), compute the
/// depth of each leaf, and limit lengths with a heuristic that keeps the code complete: when a leaf would be
/// too deep, it is placed at the deepest level that still has a free slot. Not optimal in the package-merge
/// sense, but close, and linear after the sort.
enum HuffmanCodeBuilder {
    /// Bits of each packed entry holding the symbol; the frequency, or later a node's parent and then its
    /// depth, goes above them.
    static var symbolBits: UInt32 { 10 }
    static var symbolMask: UInt32 { (1 << symbolBits) - 1 }

    /// The most symbols an alphabet can have: Brotli's insert-and-copy alphabet.
    static var maximumSymbols: Int { 704 }

    /// Computes code lengths and codewords for `frequencies`.
    ///
    /// Symbols with frequency 0 get length 0. If fewer than two symbols are used, two get 1-bit codes
    /// (the used one, if any, and symbol 0 or 1), as DEFLATE requires a complete code.
    ///
    /// - Parameters:
    ///   - frequencies: How often each symbol occurs; at most ``maximumSymbols``, each below 2^22.
    ///   - maximumLength: The longest code allowed, 1 through 15; it must fit every used symbol.
    ///   - lengths: Receives each symbol's code length; as long as `frequencies`.
    ///   - codewords: Receives each symbol's codeword, bit-reversed (least significant bit first, as DEFLATE
    ///     and Brotli write them); as long as `frequencies`. Also the scratch space.
    static func build(
        frequencies: Span<UInt32>, maximumLength: Int, lengths: inout MutableSpan<UInt8>, codewords: inout MutableSpan<UInt32>
    ) {
        let count = frequencies.count
        precondition(count <= maximumSymbols && lengths.count >= count && codewords.count >= count)
        let used = sortSymbols(frequencies, &lengths, &codewords)
        if used < 2 {
            let symbol = used == 1 ? Int(codewords[0] & symbolMask) : 0
            let other = symbol == 0 ? 1 : 0
            for index in 0..<count {
                lengths[index] = 0
            }
            lengths[symbol] = 1
            lengths[other] = 1
            for index in 0..<count {
                codewords[index] = 0
            }
            codewords[max(symbol, other)] = 1
            return
        }
        buildTree(&codewords, used)
        var lengthCounts = InlineArray<16, Int>(repeating: 0)
        computeLengthCounts(&codewords, root: used &- 2, &lengthCounts, maximumLength)
        assignCodewords(&codewords, &lengths, lengthCounts, maximumLength, count)
    }

    /// Sorts the used symbols by increasing frequency, then symbol, into `sorted` as `frequency << 10 |
    /// symbol`, and zeroes the lengths of unused symbols.
    ///
    /// A counting sort with about `count / 4` buckets; the last bucket, for the most frequent symbols, gets
    /// a heap sort.
    ///
    /// - Returns: The number of used symbols.
    private static func sortSymbols(_ frequencies: Span<UInt32>, _ lengths: inout MutableSpan<UInt8>, _ sorted: inout MutableSpan<UInt32>) -> Int {
        let count = frequencies.count
        let bucketCount = ((count &+ 3) / 4 &+ 3) & ~3
        var buckets = InlineArray<180, Int>(repeating: 0) // At least `bucketCount`: 176 for 704 symbols.
        for symbol in 0..<count {
            buckets[min(Int(frequencies[symbol]), bucketCount &- 1)] &+= 1
        }
        // Bucket starts; bucket 0 (unused symbols) gets none.
        var used = 0
        for bucket in 1..<bucketCount {
            let size = buckets[bucket]
            buckets[bucket] = used
            used &+= size
        }
        for symbol in 0..<count {
            let frequency = frequencies[symbol]
            if frequency == 0 {
                lengths[symbol] = 0
            } else {
                let bucket = min(Int(frequency), bucketCount &- 1)
                sorted[buckets[bucket]] = UInt32(symbol) | frequency &<< symbolBits
                buckets[bucket] &+= 1
            }
        }
        // After filling, `buckets[b]` is the end of bucket b: the last bucket runs from the end of the one
        // before it to the end.
        let lastStart = buckets[bucketCount &- 2]
        heapSort(&sorted, from: lastStart, to: used)
        return used
    }

    /// Sorts `array[start..<end]` in place, ascending.
    private static func heapSort(_ array: inout MutableSpan<UInt32>, from start: Int, to end: Int) {
        let count = end &- start
        guard count > 1 else { return }
        func siftDown(_ root: Int, _ size: Int) {
            var parent = root
            let value = array[start &+ parent]
            while true {
                var child = parent &* 2 &+ 1
                if child >= size { break }
                if child &+ 1 < size, array[start &+ child &+ 1] > array[start &+ child] { child &+= 1 }
                if value >= array[start &+ child] { break }
                array[start &+ parent] = array[start &+ child]
                parent = child
            }
            array[start &+ parent] = value
        }
        var index = count / 2
        while index > 0 {
            index &-= 1
            siftDown(index, count)
        }
        var size = count
        while size > 1 {
            size &-= 1
            array.swapAt(start, start &+ size)
            siftDown(0, size)
        }
    }

    /// Builds the Huffman tree in `nodes`, whose first `count` entries are the used symbols sorted by
    /// frequency. Afterwards entry `i < count - 1` is internal node `i` (the root is `count - 2`): its
    /// frequency, then its parent's index, in the bits above the symbol, which stays in place so the
    /// sorted symbol order survives.
    private static func buildTree(_ nodes: inout MutableSpan<UInt32>, _ count: Int) {
        let frequencyMask = ~symbolMask
        let last = count &- 1
        var leaf = 0 // Next unused leaf.
        var branch = 0 // Next unused internal node.
        var next = 0 // Next internal node to create.
        repeat {
            let frequency: UInt32
            if leaf &+ 1 <= last && (branch == next || nodes[leaf &+ 1] & frequencyMask <= nodes[branch] & frequencyMask) {
                // Two leaves.
                frequency = (nodes[leaf] & frequencyMask) &+ (nodes[leaf &+ 1] & frequencyMask)
                leaf &+= 2
            } else if branch &+ 2 <= next && (leaf > last || nodes[branch &+ 1] & frequencyMask < nodes[leaf] & frequencyMask) {
                // Two internal nodes.
                frequency = (nodes[branch] & frequencyMask) &+ (nodes[branch &+ 1] & frequencyMask)
                nodes[branch] = UInt32(next) &<< symbolBits | nodes[branch] & symbolMask
                nodes[branch &+ 1] = UInt32(next) &<< symbolBits | nodes[branch &+ 1] & symbolMask
                branch &+= 2
            } else {
                // A leaf and an internal node.
                frequency = (nodes[leaf] & frequencyMask) &+ (nodes[branch] & frequencyMask)
                nodes[branch] = UInt32(next) &<< symbolBits | nodes[branch] & symbolMask
                leaf &+= 1
                branch &+= 1
            }
            nodes[next] = frequency | nodes[next] & symbolMask
            next &+= 1
        } while next < last
    }

    /// Counts the leaves at each depth, limiting depth to `maximumLength`, from the tree's internal nodes
    /// (each internal node at depth `d` turns one slot at `d` into two at `d + 1`).
    private static func computeLengthCounts(
        _ nodes: inout MutableSpan<UInt32>, root: Int, _ lengthCounts: inout InlineArray<16, Int>, _ maximumLength: Int
    ) {
        lengthCounts[1] = 2
        nodes[root] &= symbolMask // Depth 0.
        var node = root &- 1
        while node >= 0 {
            let parent = Int(nodes[node] &>> symbolBits)
            let parentDepth = Int(nodes[parent] &>> symbolBits)
            var depth = parentDepth &+ 1
            nodes[node] = nodes[node] & symbolMask | UInt32(depth) &<< symbolBits
            if depth >= maximumLength {
                // Too deep: use the deepest level with a free slot instead, keeping the code complete.
                depth = maximumLength
                repeat {
                    depth &-= 1
                } while lengthCounts[depth] == 0
            }
            lengthCounts[depth] &-= 1
            lengthCounts[depth &+ 1] &+= 2
            node &-= 1
        }
    }

    /// Gives the least frequent symbols the longest codes, then assigns canonical codewords, bit-reversed.
    private static func assignCodewords(
        _ nodes: inout MutableSpan<UInt32>, _ lengths: inout MutableSpan<UInt8>, _ lengthCounts: InlineArray<16, Int>,
        _ maximumLength: Int, _ count: Int
    ) {
        var index = 0
        var length = maximumLength
        while length >= 1 {
            for _ in 0..<lengthCounts[length] {
                lengths[Int(nodes[index] & symbolMask)] = UInt8(length)
                index &+= 1
            }
            length &-= 1
        }
        var nextCode = InlineArray<16, UInt32>(repeating: 0)
        if maximumLength >= 2 {
            for length in 2...maximumLength {
                nextCode[length] = (nextCode[length &- 1] &+ UInt32(lengthCounts[length &- 1])) &<< 1
            }
        }
        for symbol in 0..<count {
            let length = Int(lengths[symbol])
            nodes[symbol] = reversed(nextCode[length], length: length)
            nextCode[length] &+= 1
        }
    }

    /// `code`'s low `length` bits in reverse order.
    @inline(__always)
    static func reversed(_ code: UInt32, length: Int) -> UInt32 {
        length == 0 ? 0 : code.bitSwapped &>> UInt32(32 &- length)
    }
}

extension UInt32 {
    /// The bits in reverse order: `rbit` on ARM.
    @inline(__always)
    var bitSwapped: UInt32 {
        var value = self
        value = (value & 0x5555_5555) &<< 1 | (value &>> 1) & 0x5555_5555
        value = (value & 0x3333_3333) &<< 2 | (value &>> 2) & 0x3333_3333
        value = (value & 0x0F0F_0F0F) &<< 4 | (value &>> 4) & 0x0F0F_0F0F
        return value.byteSwapped
    }
}
