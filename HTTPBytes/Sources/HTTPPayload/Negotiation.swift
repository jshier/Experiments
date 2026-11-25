public import HTTPBytes

extension HTTPContentCoding {
    /// The coding to answer with, of `available` (in the server's order of preference), for a request's
    /// `Accept-Encoding` value (RFC 9110 §12.5.3): the one with the highest weight, earlier ones winning ties; `nil` if
    /// none is acceptable (`identity` refused too: a 415 or 406). Without the field, a server may use any coding: pass
    /// `nil` to get the first.
    ///
    /// The list is read once: each element's coding recognized (any case; `x-gzip` is `gzip`) and its weight kept, then
    /// the offered codings looked up. A malformed `Accept-Encoding` is treated as accepting only `identity`.
    ///
    /// `@inlinable`: specialized for the caller's collection (unspecialized, iterating `some Sequence` boxed its iterator).
    @inlinable
    public static func negotiated(acceptEncoding: RawSpan?, available: some Sequence<HTTPContentCoding>) -> HTTPContentCoding? {
        guard let acceptEncoding else {
            var iterator = available.makeIterator()
            return iterator.next()
        }
        // Weights in thousandths by coding (-1: not named), and `*`'s.
        var weights = InlineArray<5, Int>(repeating: -1)
        var any = -1
        var list = HTTPAcceptList(acceptEncoding)
        var malformed = false
        do throws(HTTPFieldValueError) {
            while let element = try list.next() {
                if let coding = HTTPContentCoding(token: element.value) {
                    weights[coding.slot] = Swift.max(weights[coding.slot], element.weight)
                } else if element.value.byteCount == 1, element.value.load(fromByteOffset: 0, as: UInt8.self) == 0x2A {
                    any = Swift.max(any, element.weight)
                }
            }
        } catch {
            malformed = true
        }
        var best: HTTPContentCoding? = nil, bestWeight = 0
        for coding in available {
            let weight: Int = if malformed {
                coding == .identity ? 1000 : 0
            } else if weights[coding.slot] >= 0 {
                weights[coding.slot]
            } else if any >= 0 {
                any
            } else {
                // Not named: only `identity` stays acceptable (RFC 9110 §12.5.3).
                coding == .identity ? 1000 : 0
            }
            if weight > bestWeight { (best, bestWeight) = (coding, weight) }
        }
        return best
    }

    /// The coding's index among the five.
    @inlinable
    var slot: Int {
        switch self {
        case .identity: 0
        case .gzip: 1
        case .deflate: 2
        case .brotli: 3
        case .zstd: 4
        }
    }
}
