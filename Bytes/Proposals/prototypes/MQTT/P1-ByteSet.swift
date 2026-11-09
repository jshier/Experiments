public import Bytes

// PROTOTYPES of APIs proposed for Bytes (scratch copy only).

/// P1: a set of byte values, written as the list of its members, which the compiler folds into four
/// constant words. For reason codes, property identifiers, and other byte-valued enumerations a format
/// restricts per message.
@usableFromInline
struct ByteSet: Sendable {
    @usableFromInline var w0, w1, w2, w3: UInt64

    @inlinable @inline(__always)
    init<let count: Int>(_ members: InlineArray<count, UInt8>) {
        // Four scalar accumulators, not an array indexed by the byte: a dynamic index keeps the words in
        // memory, and the loop then isn't folded.
        var (w0, w1, w2, w3): (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        for index in members.indices {
            let byte = members[index]
            let bit: UInt64 = 1 &<< (byte & 63)
            switch byte &>> 6 {
            case 0: w0 |= bit
            case 1: w1 |= bit
            case 2: w2 |= bit
            default: w3 |= bit
            }
        }
        (self.w0, self.w1, self.w2, self.w3) = (w0, w1, w2, w3)
    }

    @inlinable @inline(__always)
    func contains(_ byte: UInt8) -> Bool {
        let word = switch byte &>> 6 {
        case 0: w0
        case 1: w1
        case 2: w2
        default: w3
        }
        return word[bit: Int(byte & 63)]
    }
}
