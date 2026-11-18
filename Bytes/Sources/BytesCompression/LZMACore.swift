internal import Bytes

// The LZMA decode loop, shared by LZMA2 chunks, raw LZMA1, and .xz blocks. It follows Igor Pavlov's
// `LzmaDec.c` (and `LzmaSpec.cpp` for the meaning): a range decoder over adaptive 11-bit probabilities, a
// literal coder that follows the byte at the last distance after a match, two length coders, distance slots
// with reverse bit trees, direct and align bits, four repeat distances, and the 12-state machine that selects
// the probabilities.
//
// The output is the dictionary: symbols are decoded straight into the caller's buffer, so matches copy within
// it and nothing wraps. Positions are integer offsets from the dictionary's start; memory is touched through
// pointers formed only after the checks that bound them.
//
// Two loops run the same body. The fast one runs while at least `inputMargin` bytes of input and
// `outputMargin` bytes of output remain, so it reads input without checking it (a symbol reads at most one
// byte per bit it decodes, under 64) and copies matches 16 bytes at a time without checking the output (a
// match is at most 273 bytes, and wild copies write at most 32 past it). The careful one, out of line, checks
// every input byte (reading zeros past the end, which the caller then rejects) and every match against the
// limit, and copies a byte at a time: it decodes a dictionary's first symbol (so the fast loop can read the
// byte before the position without checking for 0) and the last few hundred bytes of each chunk.
//
// Speed comes from the chain from one bit to the next, since a literal's eight bits each depend on the last.
// Bits of trees (literals, lengths, distance slots and low bits) are decoded with conditional selects, and
// each bit's probability is picked from its parent's two children, loaded together while the parent decodes
// (a matched literal loads both candidates); the normalization after a bit is folded into the next, compared
// against a threshold in a register. Decisions that repeat (literal or match, which kind of match) keep
// branches, as `LzmaDec.c` does. The literal trees are written out, and the loop is specialized for lc 3,
// lp 0, pb 2.

/// The probability model's layout: offsets, in 16-bit probabilities, into the decoder's workspace.
enum LZMAProbabilities {
    static var stateCount: Int { 12 }
    /// `isMatch[state << 4 + posState]`: a literal (0) or a match (1).
    static var isMatch: Int { 0 }
    /// `isRep0Long[state << 4 + posState]`: a one-byte match at rep0 (0) or a longer one (1).
    static var isRep0Long: Int { 192 }
    /// `isRep[state]`: a new distance (0) or a repeated one (1). Then `isRepG0` (rep0, or another), `isRepG1`
    /// (rep1, or rep2 or rep3), `isRepG2` (rep2 or rep3).
    static var isRep: Int { 384 }
    static var isRepG0: Int { 396 }
    static var isRepG1: Int { 408 }
    static var isRepG2: Int { 420 }
    /// Four 6-bit trees of distance slots, by length (2, 3, 4, 5 or more): `posSlot[min(len, 3) << 6 + node]`.
    static var posSlot: Int { 432 }
    /// Reverse trees for the low bits of distances in slots 4 to 13, `specPos[distance - slot + node]`: nodes
    /// 1 to 114 are used.
    static var specPos: Int { 688 }
    /// A 4-bit reverse tree for the low bits of distances in slots 14 and up.
    static var align: Int { 816 }
    /// The match and repeat length coders: `choice` (0), `choice2` (1), sixteen 3-bit low trees
    /// (`2 + posState << 3`), sixteen 3-bit middle trees (`130 + posState << 3`), and an 8-bit high tree (258).
    static var lengthCoder: Int { 832 }
    static var repLengthCoder: Int { 1346 }
    static var lengthCoderSize: Int { 514 }
    static var lengthLow: Int { 2 }
    static var lengthMiddle: Int { 130 }
    static var lengthHigh: Int { 258 }
    /// `0x300` probabilities per literal context (a plain 8-bit tree, then two more used after a match), for
    /// `1 << (lc + lp)` contexts. Aligned to 64 bytes.
    static var literal: Int { 1888 }

    /// Not a probability: `1 << 24 >> 16`, the range decoder's normalization threshold, stored where LLVM
    /// can't see it. As a constant, `range < 1 << 24` compiles to `lsr` and `cmp` (LLVM canonicalizes it to
    /// `range >> 24 == 0`); against a value in a register, one `cmp`, a cycle less on the chain from one bit
    /// to the next (5% fewer cycles). In the padding before the literals; the model's resets write it after
    /// filling the probabilities.
    static var topSlot: Int { 1880 }
    static var topValue: UInt16 { 1 << 8 }

    /// The number of probabilities for literal context bits `lc` and literal position bits `lp`.
    static func count(lc: Int, lp: Int) -> Int { literal + 0x300 << (lc + lp) }

    /// Every probability starts at one half.
    static var initial: UInt16 { 1 << 10 }
}

/// The decoder's state between symbols, kept between LZMA2 chunks.
struct LZMARegisters {
    var range: UInt32 = 0xFFFF_FFFF
    var code: UInt32 = 0
    /// 0 to 11: what the last symbols were (0 to 6 after a literal, 7 to 11 after a match).
    var state = 0
    /// The last four distances (1 or more: the source is `position - rep0`).
    var rep0 = 1
    var rep1 = 1
    var rep2 = 1
    var rep3 = 1
    /// The next byte's offset from the start of the dictionary.
    var position = 0
}

/// A stream's fixed parameters.
struct LZMAModel {
    /// Literal context bits (lc): how many high bits of the previous byte select literal probabilities.
    var lc: Int
    /// The masks of the position's low bits that select literal probabilities (lp) and the rest (pb).
    var literalPositionMask: Int
    var positionMask: Int
    /// The farthest a match may reach.
    var dictionarySize: Int

    init(lc: Int, literalPositionMask: Int, positionMask: Int, dictionarySize: Int) {
        self.lc = lc
        self.literalPositionMask = literalPositionMask
        self.positionMask = positionMask
        self.dictionarySize = max(dictionarySize, LZMAModel.minimumDictionarySize)
    }

    init(properties: LZMAProperties) {
        self.init(
            lc: properties.literalContextBits, literalPositionMask: 1 &<< properties.literalPositionBits &- 1,
            positionMask: 1 &<< properties.positionBits &- 1, dictionarySize: properties.dictionarySize
        )
    }

    /// The smallest dictionary decoders keep, whatever a header says (as `LzmaDec.c` and liblzma).
    static var minimumDictionarySize: Int { 1 << 12 }

    /// lc 3, lp 0, pb 2: the default, what xz, 7-Zip, and Apple's encoders write.
    var isDefault: Bool { lc == 3 && literalPositionMask == 0 && positionMask == 3 }
}

/// The range decoder: `range` and `code`, the input, and the probability model, with the bit, tree, length,
/// and distance decoders. A local in the decode loop, so its fields live in registers.
@safe
struct LZMARangeDecoder {
    var range: UInt32
    var code: UInt32
    /// The next input byte. In careful mode, it may pass `end` (each byte read there is a zero).
    var input: UnsafePointer<UInt8>
    let end: UnsafePointer<UInt8>
    /// The probability model, laid out as `LZMAProbabilities` says.
    let probabilities: UnsafeMutablePointer<UInt16>
    /// Whether to check each byte read against `end`. A constant in each copy of the loop.
    let careful: Bool
    /// `1 << 24`, loaded from the model (see `LZMAProbabilities.topSlot`).
    let top: UInt32

    @inline(__always)
    init(
        range: UInt32, code: UInt32, input: UnsafePointer<UInt8>, end: UnsafePointer<UInt8>,
        probabilities: UnsafeMutablePointer<UInt16>, careful: Bool
    ) {
        self.range = range
        self.code = code
        unsafe self.input = input
        unsafe self.end = end
        unsafe self.probabilities = probabilities
        self.careful = careful
        // Unsafe: a load from the model. Safe: the slot is within it.
        top = UInt32(unsafe probabilities[LZMAProbabilities.topSlot]) &<< 16
    }

    /// The same decoder in another mode.
    @inline(__always)
    func with(careful: Bool) -> LZMARangeDecoder {
        unsafe LZMARangeDecoder(range: range, code: code, input: input, end: end, probabilities: probabilities, careful: careful)
    }

    /// Whether the input is still before `limit` (the fast loop's input limit), or in careful mode, not past
    /// the end.
    @inline(__always)
    func hasInput(before limit: UnsafePointer<UInt8>) -> Bool {
        // Unsafe: comparing pointers only.
        unsafe careful ? input <= end : input < limit
    }

    /// Shifts in a byte when the range drops below 2^24.
    @inline(always)
    mutating func normalize() {
        if range < 1 << 24 {
            // Unsafe: reads the next input byte. Safe: careful mode checks it against `end`; the fast loop
            // runs only while `LZMALoop.inputMargin` bytes remain, more than a symbol can read.
            let byte: UInt8 = unsafe careful ? (input < end ? input.pointee : 0) : input.pointee
            unsafe input += 1
            range &<<= 8
            code = code &<< 8 | UInt32(byte)
        }
    }

    /// Decodes a bit of a tree with probability `p`, without adapting it: the bit is 1 when `one`, and
    /// `difference` is `code - bound` in 64 bits (its high half all ones for a 0).
    ///
    /// The bit is taken arithmetically, from the borrow of `code - bound`: as `one ? 1 : 0`, LLVM made it a
    /// branch, which mispredicts on half of a literal's bits. In the fast loop, the normalization after a bit
    /// is deferred to the next one, which computes its bound from the range shifted or not while deciding
    /// whether to shift: the shift is off the chain from one bit to the next. ``finishSteps()`` does the last bit's normalization.
    @inline(always)
    mutating func step(_ p: UInt32) -> (one: Bool, difference: UInt64) {
        if careful {
            let bound = (range &>> 11) &* p
            let difference = UInt64(code) &- UInt64(bound)
            let one = code >= bound
            range = one ? range &- bound : bound
            code = one ? code &- bound : code
            normalize()
            return (one, difference)
        }
        // Unsafe: reads the next input byte. Safe: the fast loop runs only while `LZMALoop.inputMargin` bytes
        // remain.
        let byte = UInt32(unsafe input.pointee)
        let needs = range < top
        // `(range << 8) >> 11` is `range >> 3` when the range is below 2^24, so the shift is chosen without
        // waiting for the shifted range. LLVM makes `needs` a branch, which predicts well: selecting constant
        // shifts instead (no branch) took 10% more cycles.
        let bound = (needs ? range &>> 3 : range &>> 11) &* p
        let normalizedRange = needs ? range &<< 8 : range
        let normalizedCode = needs ? code &<< 8 | byte : code
        unsafe input += needs ? 1 : 0
        let difference = UInt64(normalizedCode) &- UInt64(bound)
        let one = normalizedCode >= bound
        range = one ? normalizedRange &- bound : bound
        code = one ? normalizedCode &- bound : normalizedCode
        return (one, difference)
    }

    /// Completes a run of ``step(_:)``s: the last bit's normalization.
    @inline(always)
    mutating func finishSteps() {
        if !careful {
            normalizeWithoutBranch()
        }
    }

    /// A literal after a match, at `base`, with `matchByte` the byte at rep0: while the decoded bits agree with
    /// its bits, each uses the probabilities for that bit of it (0x100 + 0x100 * bit + node); after they
    /// differ, the plain tree's. Both candidates for the next bit's probability are loaded while a bit is
    /// decoded, as in `literal`.
    @inline(always)
    mutating func matchedLiteral(_ base: Int, matchByte: Int) -> Int {
        // `matched` is 0x100 while the bits agree, 0 after; `next` is the match byte's next bit, as 0x100 or 0.
        let shifted = matchByte &<< 1
        let next = shifted & 0x100
        // Unsafe: probability loads and stores. Safe: `base` starts a literal context's 0x300 probabilities;
        // indices are `matched & next` (0 or 0x100) plus `matched` (0 or 0x100) plus a node below 0x200.
        let index = base &+ next &+ 0x100 &+ 1
        var state = (symbol: 1, matched: 0x100, shifted: shifted, next: next, index: index, p: UInt32(unsafe probabilities[index]))
        matchedStep(base, &state)
        matchedStep(base, &state)
        matchedStep(base, &state)
        matchedStep(base, &state)
        matchedStep(base, &state)
        matchedStep(base, &state)
        matchedStep(base, &state)
        matchedStep(base, &state)
        finishSteps()
        return state.symbol
    }

    /// One bit of `matchedLiteral`.
    @inline(always)
    mutating func matchedStep(
        _ base: Int, _ state: inout (symbol: Int, matched: Int, shifted: Int, next: Int, index: Int, p: UInt32)
    ) {
        var (symbol, matched, shifted, next, index, p) = state
        // The next bit's candidates: after a 0 (agreeing if the match bit was 0) or a 1.
        shifted &<<= 1
        let following = shifted & 0x100
        let matched0 = matched & (next ^ 0x100)
        let matched1 = matched & next
        let index0 = base &+ (matched0 & following) &+ matched0 &+ symbol &<< 1
        let index1 = base &+ (matched1 & following) &+ matched1 &+ symbol &<< 1 &+ 1
        let p0 = UInt32(unsafe probabilities[index0])
        let p1 = UInt32(unsafe probabilities[index1])

        let (one, difference) = step(p)
        adapt(index, p, difference)
        symbol = symbol &<< 1 | (Int(truncatingIfNeeded: difference &>> 63) ^ 1)
        p = one ? p1 : p0
        index = one ? index1 : index0
        matched = one ? matched1 : matched0
        next = following
        state = (symbol, matched, shifted, next, index, p)
    }

    /// `normalize` with conditional selects, reading the next byte whether it's needed or not: only where
    /// input remains (the fast loop).
    @inline(always)
    mutating func normalizeWithoutBranch() {
        // Unsafe: reads the next input byte. Safe: the fast loop runs only while `LZMALoop.inputMargin` bytes
        // remain.
        let byte = UInt32(unsafe input.pointee)
        let needs = range < top
        range = needs ? range &<< 8 : range
        code = needs ? code &<< 8 | byte : code
        unsafe input += needs ? 1 : 0
    }

    /// Decodes a bit with a branch: for decisions that repeat (literal or match, which kind of match).
    @inline(always)
    mutating func decision(_ index: Int) -> Bool {
        // Unsafe: the probability's load and store. Safe: callers pass indices within the model.
        let p = UInt32(unsafe probabilities[index])
        let bound = (range &>> 11) &* p
        if code < bound {
            range = bound
            unsafe probabilities[index] = UInt16(truncatingIfNeeded: p &+ ((1 << 11) &- p) &>> 5)
            normalize()
            return false
        }
        range &-= bound
        code &-= bound
        unsafe probabilities[index] = UInt16(truncatingIfNeeded: p &- p &>> 5)
        normalize()
        return true
    }

    /// A `count`-bit symbol, most significant bit first, from the tree at `base` (nodes 1 to `1 << count - 1`).
    @inline(always)
    mutating func tree(_ base: Int, count: Int) -> Int {
        var node = 1
        // Unsafe: probability loads and stores. Safe: nodes are below `1 << count`, within the tree; the
        // children loaded for the last bit are below `2 << count`, which every tree's base leaves within the
        // model (the last, the repeat length coder's high tree, reaches into the literals).
        var p = UInt32(unsafe probabilities[base &+ 1])
        let raw = unsafe UnsafeRawPointer(probabilities + base)
        for _ in 0..<count {
            unsafe treeStep(raw, base, &node, &p)
        }
        finishSteps()
        return node &- 1 &<< count
    }

    /// One bit of `tree`: decodes node `node` with probability `p`, and moves to its child.
    @inline(always)
    mutating func treeStep(_ raw: UnsafeRawPointer, _ base: Int, _ node: inout Int, _ p: inout UInt32) {
        // Unsafe: the children's load. Safe: as `tree`.
        let children = unsafe raw.loadUnaligned(fromByteOffset: node &<< 2, as: UInt32.self)
        let (one, difference) = step(p)
        adapt(base &+ node, p, difference)
        node = node &<< 1 | (Int(truncatingIfNeeded: difference &>> 63) ^ 1)
        p = one ? children &>> 16 : children & 0xFFFF
    }

    /// `tree(base, count: 8)` written out: a literal.
    @inline(always)
    mutating func literal(_ base: Int) -> Int {
        var node = 1
        // Unsafe: as `tree`: a literal context's 0x300 probabilities hold the children of its last level.
        var p = UInt32(unsafe probabilities[base &+ 1])
        let raw = unsafe UnsafeRawPointer(probabilities + base)
        unsafe treeStep(raw, base, &node, &p)
        unsafe treeStep(raw, base, &node, &p)
        unsafe treeStep(raw, base, &node, &p)
        unsafe treeStep(raw, base, &node, &p)
        unsafe treeStep(raw, base, &node, &p)
        unsafe treeStep(raw, base, &node, &p)
        unsafe treeStep(raw, base, &node, &p)
        unsafe treeStep(raw, base, &node, &p)
        finishSteps()
        return node
    }

    /// Stores probability `p` at `index`, adapted to the bit whose `difference` `step` returned.
    @inline(always)
    func adapt(_ index: Int, _ p: UInt32, _ difference: UInt64) {
        // `p - ((p - target) >> 5)`, signed: `p + (2048 - p) >> 5` toward 2048 for a 0, `p - p >> 5` for a 1.
        let target = Int32(truncatingIfNeeded: difference &>> 32) & ((1 << 11) - 31)
        let signed = Int32(bitPattern: p)
        // Unsafe: a probability store. Safe: callers pass indices within the model.
        unsafe probabilities[index] = UInt16(truncatingIfNeeded: signed &- ((signed &- target) &>> 5))
    }

    /// A `count`-bit symbol, least significant bit first, from the tree at `base`.
    @inline(always)
    mutating func reverseTree(_ base: Int, count: Int) -> Int {
        var node = 1
        var symbol = 0
        // Unsafe: as `tree`: the specPos trees' last children are below 0x100 past `specPos`, the align
        // tree's below 32 past `align`.
        var p = UInt32(unsafe probabilities[base &+ 1])
        let raw = unsafe UnsafeRawPointer(probabilities + base)
        for index in 0..<count {
            let children = unsafe raw.loadUnaligned(fromByteOffset: node &<< 2, as: UInt32.self)
            let (one, difference) = step(p)
            adapt(base &+ node, p, difference)
            let bit = Int(truncatingIfNeeded: difference &>> 63) ^ 1
            node = node &<< 1 | bit
            symbol |= bit &<< index
            p = one ? children &>> 16 : children & 0xFFFF
        }
        finishSteps()
        return symbol
    }

    /// `count` bits at a fixed probability of one half, most significant first.
    @inline(always)
    mutating func directBits(_ count: Int) -> Int {
        var result: UInt32 = 0
        for _ in 0..<count {
            range &>>= 1
            code &-= range
            let mask = 0 &- (code &>> 31) // All ones if the code was below the range: a 0.
            code &+= range & mask
            result = result &<< 1 &+ (mask &+ 1)
            normalize()
        }
        return Int(result)
    }

    /// A match length less 2 (0 to 271), from the length coder at `coder`. `positionState` is below 16.
    @inline(always)
    mutating func length(_ coder: Int, positionState: Int) -> Int {
        if !decision(coder) {
            return tree(coder &+ LZMAProbabilities.lengthLow &+ positionState &<< 3, count: 3)
        }
        if !decision(coder &+ 1) {
            return 8 &+ tree(coder &+ LZMAProbabilities.lengthMiddle &+ positionState &<< 3, count: 3)
        }
        return 16 &+ tree(coder &+ LZMAProbabilities.lengthHigh, count: 8)
    }

    /// A match distance less 1, up to `0xFFFF_FFFF` (the end marker), for a match of `length` less 2.
    @inline(always)
    mutating func distance(length: Int) -> Int {
        // `min(length, 3) << 6` selects one of the four slot trees; `distance - slot` is at most 83 for slots
        // 4 to 13, whose trees reach 31 nodes past it.
        let lengthState = length < 3 ? length : 3
        let slot = tree(LZMAProbabilities.posSlot &+ lengthState &<< 6, count: 6)
        if slot < 4 { return slot }
        let count = slot &>> 1 &- 1
        var distance = (2 | slot & 1) &<< count
        if slot < 14 {
            distance &+= reverseTree(LZMAProbabilities.specPos &+ distance &- slot, count: count)
        } else {
            distance &+= directBits(count &- 4) &<< 4
            distance &+= reverseTree(LZMAProbabilities.align, count: 4)
        }
        return distance
    }
}

/// The decode loops.
enum LZMALoop {
    /// Input the fast loop leaves for the careful one: more than a symbol reads (at most one byte per bit,
    /// and the longest symbol, a match with a far distance, decodes 48 bits).
    static var inputMargin: Int { 64 }
    /// Output the fast loop leaves: the longest match, plus a wild copy's overrun.
    static var outputMargin: Int { 273 + 32 }

    /// Decodes symbols into `dictionary` from `registers.position` up to `limit` (not past it, and stopping
    /// short of it only for an end marker or, in careful mode, input that ran out).
    ///
    /// - Parameters:
    ///   - limit: The position to stop at. The fast loop stops `outputMargin` before it.
    ///   - inputLimit: The fast loop stops when the input reaches it.
    ///   - allowsEndMarker: Whether an end marker (distance `0xFFFF_FFFF`) may end the stream.
    ///   - overrun: The error for a match past `limit`.
    /// - Returns: Whether an end marker was decoded.
    @inline(__always)
    static func run(
        _ registers: inout LZMARegisters, _ decoder: inout LZMARangeDecoder, dictionary: UnsafeMutablePointer<UInt8>,
        limit: Int, inputLimit: UnsafePointer<UInt8>, careful: Bool, lc: Int, literalPositionMask: Int,
        positionMask: Int, dictionarySize: Int, allowsEndMarker: Bool, overrun: BytesError
    ) throws(BytesError) -> Bool {
        typealias P = LZMAProbabilities
        var rc = decoder.with(careful: careful) // This loop's mode, as a constant.
        var state = registers.state
        var rep0 = registers.rep0, rep1 = registers.rep1, rep2 = registers.rep2, rep3 = registers.rep3
        var position = registers.position
        let stop = careful ? limit : limit &- outputMargin
        var endMarker = false

        // Unsafe: dictionary reads and writes. Safe: writes are below `limit` (checked per match in careful
        // mode; the fast loop stops `outputMargin` before it). Reads are at `position - distance` with
        // `1 <= distance <= position`: new distances are checked against the position, and repeated ones were
        // checked when decoded (positions only grow, and a dictionary reset comes with a state reset, which
        // sets them to 1); a repeat at position 0 is rejected in careful mode, and the fast loop starts at
        // position 1 or later.
        while unsafe position < stop && rc.hasInput(before: inputLimit) {
            let positionState = position & positionMask
            if !rc.decision(P.isMatch &+ state &<< 4 &+ positionState) {
                // A literal, in one of `1 << (lc + lp)` contexts: the position's low lp bits and the previous
                // byte's high lc bits.
                let previous = careful && position == 0 ? 0 : Int(unsafe dictionary[position &- 1])
                let context = (position & literalPositionMask) &<< lc &+ previous &>> (8 &- lc)
                let literals = P.literal &+ 0x300 &* context
                var symbol = 1
                if state < 7 {
                    symbol = rc.literal(literals)
                    state = state < 4 ? 0 : state &- 3
                } else {
                    // After a match: the byte at rep0 guides the probabilities.
                    symbol = rc.matchedLiteral(literals, matchByte: Int(unsafe dictionary[position &- rep0]))
                    state = state < 10 ? state &- 3 : state &- 6
                }
                unsafe dictionary[position] = UInt8(truncatingIfNeeded: symbol)
                position &+= 1
                continue
            }

            var length: Int
            if !rc.decision(P.isRep &+ state) {
                // A match with a new distance.
                length = rc.length(P.lengthCoder, positionState: positionState)
                state = state < 7 ? 7 : 10
                let distance = rc.distance(length: length)
                rep3 = rep2
                rep2 = rep1
                rep1 = rep0
                let reach = position < dictionarySize ? position : dictionarySize
                if distance >= reach {
                    if allowsEndMarker && distance == 0xFFFF_FFFF {
                        endMarker = true
                        break
                    }
                    throw .invalidValue
                }
                rep0 = distance &+ 1
            } else {
                if careful && position == 0 { throw .invalidValue } // Nothing to repeat.
                if !rc.decision(P.isRepG0 &+ state) {
                    if !rc.decision(P.isRep0Long &+ state &<< 4 &+ positionState) {
                        // One byte from rep0.
                        state = state < 7 ? 9 : 11
                        unsafe dictionary[position] = dictionary[position &- rep0]
                        position &+= 1
                        continue
                    }
                } else {
                    let distance: Int
                    if !rc.decision(P.isRepG1 &+ state) {
                        distance = rep1
                    } else {
                        if !rc.decision(P.isRepG2 &+ state) {
                            distance = rep2
                        } else {
                            distance = rep3
                            rep3 = rep2
                        }
                        rep2 = rep1
                    }
                    rep1 = rep0
                    rep0 = distance
                }
                length = rc.length(P.repLengthCoder, positionState: positionState)
                state = state < 7 ? 8 : 11
            }
            length &+= 2
            let destination = unsafe dictionary + position
            if careful {
                guard length <= limit &- position else { throw overrun }
                for index in 0..<length {
                    unsafe destination[index] = destination[index &- rep0]
                }
            } else if rep0 >= 16 {
                unsafe ZstdCopy.wild16(UnsafeMutableRawPointer(destination), UnsafeRawPointer(destination - rep0), length)
            } else {
                unsafe ZstdCopy.overlapping(UnsafeMutableRawPointer(destination), offset: rep0, count: length)
            }
            position &+= length
        }

        registers.state = state
        registers.rep0 = rep0
        registers.rep1 = rep1
        registers.rep2 = rep2
        registers.rep3 = rep3
        registers.position = position
        decoder.range = rc.range
        decoder.code = rc.code
        unsafe decoder.input = rc.input
        return endMarker
    }

    /// The fast loop for lc 3, lp 0, pb 2, with those as constants.
    @inline(never)
    static func fastDefault(
        _ registers: inout LZMARegisters, _ decoder: inout LZMARangeDecoder, dictionary: UnsafeMutablePointer<UInt8>,
        limit: Int, inputLimit: UnsafePointer<UInt8>, dictionarySize: Int, allowsEndMarker: Bool
    ) throws(BytesError) -> Bool {
        var localRegisters = registers
        var localDecoder = decoder
        let endMarker = try unsafe run(
            &localRegisters, &localDecoder, dictionary: dictionary, limit: limit, inputLimit: inputLimit,
            careful: false, lc: 3, literalPositionMask: 0, positionMask: 3, dictionarySize: dictionarySize,
            allowsEndMarker: allowsEndMarker, overrun: .invalidValue
        )
        registers = localRegisters
        decoder = localDecoder
        return endMarker
    }

    /// The fast loop for any lc, lp, and pb.
    @inline(never)
    static func fastGeneral(
        _ registers: inout LZMARegisters, _ decoder: inout LZMARangeDecoder, dictionary: UnsafeMutablePointer<UInt8>,
        limit: Int, inputLimit: UnsafePointer<UInt8>, model: LZMAModel, allowsEndMarker: Bool
    ) throws(BytesError) -> Bool {
        var localRegisters = registers
        var localDecoder = decoder
        let endMarker = try unsafe run(
            &localRegisters, &localDecoder, dictionary: dictionary, limit: limit, inputLimit: inputLimit,
            careful: false, lc: model.lc, literalPositionMask: model.literalPositionMask,
            positionMask: model.positionMask, dictionarySize: model.dictionarySize, allowsEndMarker: allowsEndMarker,
            overrun: .invalidValue
        )
        registers = localRegisters
        decoder = localDecoder
        return endMarker
    }

    /// The careful loop: every input byte and match checked.
    @inline(never)
    static func careful(
        _ registers: inout LZMARegisters, _ decoder: inout LZMARangeDecoder, dictionary: UnsafeMutablePointer<UInt8>,
        limit: Int, model: LZMAModel, allowsEndMarker: Bool, overrun: BytesError
    ) throws(BytesError) -> Bool {
        var localRegisters = registers
        var localDecoder = decoder
        let endMarker = try unsafe run(
            &localRegisters, &localDecoder, dictionary: dictionary, limit: limit, inputLimit: decoder.end,
            careful: true, lc: model.lc, literalPositionMask: model.literalPositionMask,
            positionMask: model.positionMask, dictionarySize: model.dictionarySize, allowsEndMarker: allowsEndMarker,
            overrun: overrun
        )
        registers = localRegisters
        decoder = localDecoder
        return endMarker
    }

    /// Decodes from the decoder's input into `dictionary` up to position `limit`: the careful loop for a
    /// dictionary's first symbol, the fast loop while it can run, and the careful loop to the end.
    ///
    /// - Returns: Whether an end marker was decoded. Without one, the position is `limit` unless the input
    ///   ran out (`decoder.input` past `decoder.end`).
    static func decode(
        _ registers: inout LZMARegisters, _ decoder: inout LZMARangeDecoder, dictionary: UnsafeMutablePointer<UInt8>,
        limit: Int, model: LZMAModel, allowsEndMarker: Bool, overrun: BytesError
    ) throws(BytesError) -> Bool {
        if registers.position == 0 && limit > 0 {
            if try unsafe careful(
                &registers, &decoder, dictionary: dictionary, limit: 1, model: model, allowsEndMarker: allowsEndMarker,
                overrun: overrun
            ) {
                return true
            }
        }
        // Unsafe: comparing and offsetting input pointers. Safe: `inputLimit` is formed only when the input
        // holds more than the margin.
        let available = unsafe decoder.end - decoder.input
        if registers.position > 0 && available > inputMargin && limit &- registers.position > outputMargin {
            let inputLimit = unsafe decoder.end - inputMargin
            let endMarker: Bool
            if model.isDefault {
                endMarker = try unsafe fastDefault(
                    &registers, &decoder, dictionary: dictionary, limit: limit, inputLimit: inputLimit,
                    dictionarySize: model.dictionarySize, allowsEndMarker: allowsEndMarker
                )
            } else {
                endMarker = try unsafe fastGeneral(
                    &registers, &decoder, dictionary: dictionary, limit: limit, inputLimit: inputLimit, model: model,
                    allowsEndMarker: allowsEndMarker
                )
            }
            if endMarker { return true }
        }
        return try unsafe careful(
            &registers, &decoder, dictionary: dictionary, limit: limit, model: model, allowsEndMarker: allowsEndMarker,
            overrun: overrun
        )
    }

    /// Decodes what must be an end marker, at `registers.position`: a match whose distance is `0xFFFF_FFFF`.
    ///
    /// - Throws: ``BytesError/invalidValue`` for anything else.
    static func decodeEndMarker(_ registers: inout LZMARegisters, _ decoder: inout LZMARangeDecoder, model: LZMAModel) throws(BytesError) {
        typealias P = LZMAProbabilities
        var rc = decoder.with(careful: true)
        let positionState = registers.position & model.positionMask
        guard rc.decision(P.isMatch &+ registers.state &<< 4 &+ positionState), !rc.decision(P.isRep &+ registers.state) else {
            throw .invalidValue
        }
        let length = rc.length(P.lengthCoder, positionState: positionState)
        guard rc.distance(length: length) == 0xFFFF_FFFF else { throw .invalidValue }
        decoder = rc
    }
}
