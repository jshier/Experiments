internal import Bytes

// An LZMA (LZMA1) decoder for zip compression method 14, following the LZMA SDK's reference decoder
// (`LzmaSpec.cpp`): a range decoder over adaptive bit probabilities, a literal coder that uses the byte at
// the last match distance once a match has been seen, two length coders, distance slots with reverse bit
// trees, direct bits and align bits, four repeat distances, and the twelve-state machine that picks the
// probabilities.
//
// It decodes into a circular window the size of the dictionary (but no larger than the entry), then copies
// what it decoded to the caller's buffer, so a stream decodes in steps of any size. A match that doesn't
// fit in a step is split: the rest is copied at the start of the next step.
//
// The whole payload is passed to every step, so input never runs out mid-step except at the payload's end:
// the range decoder reads zeros past the end and counts them, and a step that read any throws `truncated`.
// Every probability and window access is through spans, so malformed input can't read or write out of
// bounds; impossible distances and lengths throw `corruptData`.

/// Why an LZMA payload couldn't be decoded.
enum LZMAError: Error {
    /// The zip LZMA header's properties size isn't 5, or the lc/lp/pb byte is out of range.
    case unsupportedHeader
    /// The stream is invalid: a match before any output, a distance beyond the output or the dictionary,
    /// output beyond the uncompressed size, an end marker in the wrong place, or a bad range coder state.
    case corruptData
    /// The payload ended before the stream did.
    case truncated
}

/// A resumable LZMA decoder for zip method-14 payloads: one entry at a time, decoded in steps into
/// caller-supplied buffers. Its probabilities and window are allocated once and reused across entries.
struct LZMADecoder: ~Copyable {
    // MARK: Probability layout

    // All probabilities live in one array, at these offsets (the SDK's `LzmaDec.c` layout, in its order).
    // Each is an 11-bit probability that the next bit is 0, starting at one half.
    static var states: Int { 12 }
    /// `isMatch[state << 4 + posState]`: a literal (0) or a match (1).
    static var isMatch: Int { 0 }
    /// `isRep[state]`: a new distance (0) or a repeated one (1).
    static var isRep: Int { 192 }
    /// `isRepG0[state]`: rep0 (0), or rep1 through rep3 (1).
    static var isRepG0: Int { isRep + states }
    /// `isRepG1[state]`: rep1 (0), or rep2 or rep3 (1).
    static var isRepG1: Int { isRepG0 + states }
    /// `isRepG2[state]`: rep2 (0) or rep3 (1).
    static var isRepG2: Int { isRepG1 + states }
    /// `isRep0Long[state << 4 + posState]`: a one-byte rep0 match (0) or a rep0 match with a length (1).
    static var isRep0Long: Int { isRepG2 + states }
    /// Four 6-bit trees of distance slots, by length (2, 3, 4, 5 or more).
    static var distanceSlots: Int { isRep0Long + 192 }
    /// Reverse trees for the low bits of distances in slots 4 through 13: 114 used (index 0 never is).
    static var specialDistances: Int { distanceSlots + 4 << 6 }
    /// A 4-bit reverse tree for the low bits of distances in slots 14 and up.
    static var align: Int { specialDistances + 128 }
    /// The two length coders: `choice`, `choice2`, 16 low and 16 middle 3-bit trees (by posState), and an
    /// 8-bit high tree.
    static var lengthCoderSize: Int { 2 + 16 << 3 + 16 << 3 + 256 }
    static var matchLengths: Int { align + 16 }
    static var repeatLengths: Int { matchLengths + lengthCoderSize }
    /// `0x300` probabilities per literal context: a plain 8-bit tree, then two more used with a match byte.
    static var literals: Int { repeatLengths + lengthCoderSize }

    static var initialProbability: UInt16 { 1 << 10 }
    /// The smallest dictionary the SDK uses, whatever the header says.
    static var minimumDictionary: Int { 1 << 12 }
    /// The window starts this small (or the entry's size) and grows as output reaches its end.
    static var initialWindow: Int { 1 << 16 }

    // MARK: State

    /// The stream's fixed parameters.
    struct Model {
        /// Literal context bits: how many high bits of the previous byte select the literal probabilities.
        var lc = 0
        /// Masks of the position's low bits for literals (lp) and for everything else (pb).
        var literalPositionMask = 0
        var positionMask = 0
        /// The farthest a match can reach: the dictionary size, at least 4 KB.
        var maximumDistance = minimumDictionary
        /// The circular window's size: a multiple of 16, so a window position's low bits are the
        /// output position's, as lp and pb need.
        var windowSize = minimumDictionary
    }

    /// Where the stream is between steps.
    struct Registers {
        var range: UInt32 = 0xFFFF_FFFF
        var code: UInt32 = 0
        /// The next payload byte for the range decoder; past the end once it has read zeros there.
        var input = 0
        var state = 0
        var rep0 = 0, rep1 = 0, rep2 = 0, rep3 = 0
        /// The next window position to write.
        var position = 0
        /// Bytes of a match left to copy from `rep0`.
        var pending = 0
        var previousByte: UInt8 = 0
        /// The window has wrapped: every position holds history.
        var isFull = false
    }

    private var probabilities: [UInt16] = []
    private var window: [UInt8] = []
    private var model = Model()
    private var registers = Registers()
    private var remaining: UInt64 = 0
    private var hasEndMarker = false
    private var finished = true
    private var failure: LZMAError?

    init() {}

    // MARK: Decoding

    /// Starts a zip method-14 payload: the zip LZMA header (version, properties size, the lc/lp/pb byte and
    /// the dictionary size), then the raw LZMA stream.
    ///
    /// - Parameters:
    ///   - payload: The entry's whole compressed data.
    ///   - uncompressedSize: The entry's size, from the zip's central directory.
    ///   - hasEndMarker: Zip flag bit 1: the stream ends with an end marker (one is also accepted, without
    ///     it, exactly at `uncompressedSize`).
    /// - Throws: `unsupportedHeader` for a properties size other than 5 or an lc/lp/pb byte of 225 or more;
    ///   `truncated` if the payload is shorter than the header and the range coder's first five bytes;
    ///   `corruptData` if the range coder's first byte isn't 0 or its code is impossible. `decode` then throws
    ///   the same error.
    mutating func reset(payload: RawSpan, uncompressedSize: UInt64, hasEndMarker: Bool) throws(LZMAError) {
        finished = true
        failure = nil
        do {
            try start(payload, uncompressedSize: uncompressedSize, hasEndMarker: hasEndMarker)
        } catch {
            failure = error
            throw error
        }
    }

    private mutating func start(_ payload: RawSpan, uncompressedSize: UInt64, hasEndMarker: Bool) throws(LZMAError) {
        guard payload.byteCount >= 4 else { throw .truncated }
        // Version major and minor (ignored), then the properties' size.
        guard payload.load(fromByteOffset: 2, as: UInt16.self).littleEndian == 5 else { throw .unsupportedHeader }
        guard payload.byteCount >= 9 + 5 else { throw .truncated }
        // `(pb * 5 + lp) * 9 + lc`: lc ≤ 8, lp ≤ 4, pb ≤ 4, as the SDK's `LzmaProps_Decode` requires.
        var properties = Int(payload.load(fromByteOffset: 4, as: UInt8.self))
        guard properties < 9 * 5 * 5 else { throw .unsupportedHeader }
        let lc = properties % 9
        properties /= 9
        let lp = properties % 5
        let pb = properties / 5
        let dictionarySize = Int(payload.load(fromByteOffset: 5, as: UInt32.self).littleEndian)

        model.lc = lc
        model.literalPositionMask = 1 << lp - 1
        model.positionMask = 1 << pb - 1
        model.maximumDistance = max(dictionarySize, Self.minimumDictionary)
        // No larger than the entry: distances can't reach beyond its start. Rounded up to 16 bytes.
        let size = min(UInt64(model.maximumDistance), max(uncompressedSize, UInt64(Self.minimumDictionary)))
        model.windowSize = (Int(size) + 15) & ~15

        // Probabilities, all one half. The array only grows: literal contexts are `0x300 << (lc + lp)`.
        let probabilityCount = Self.literals + 0x300 << (lc + lp)
        if probabilities.count < probabilityCount {
            probabilities = [UInt16](repeating: Self.initialProbability, count: probabilityCount)
        } else {
            var span = probabilities.mutableSpan
            for index in 0..<probabilityCount {
                span[index] = Self.initialProbability
            }
        }
        // The window grows as output fills it (see `decode`), so a header's large dictionary costs memory only
        // when there's that much output. Kept from earlier entries.
        if window.isEmpty {
            window = [UInt8](repeating: 0, count: min(model.windowSize, Self.initialWindow))
        }

        // The range coder: a zero byte, then the code's first 32 bits, big-endian.
        registers = Registers()
        registers.code = payload.load(fromByteOffset: 10, as: UInt32.self).bigEndian
        registers.input = 9 + 5
        guard payload.load(fromByteOffset: 9, as: UInt8.self) == 0, registers.code != registers.range else {
            throw .corruptData
        }
        remaining = uncompressedSize
        self.hasEndMarker = hasEndMarker
        finished = false
    }

    /// Decodes the next part of the stream into `output`, from its start, resuming where the last call
    /// stopped. Fills `output` unless the stream finishes first.
    ///
    /// - Parameters:
    ///   - payload: The same whole payload that was passed to ``reset(payload:uncompressedSize:hasEndMarker:)``.
    ///   - output: Where to write; all of it is filled unless the stream finishes.
    /// - Returns: How many bytes were written, and whether the stream is finished (later calls return 0 bytes).
    /// - Throws: `corruptData` or `truncated`; once thrown, every later call throws it again until the next
    ///   reset.
    mutating func decode(
        _ payload: RawSpan, into output: inout MutableRawSpan
    ) throws(LZMAError) -> (produced: Int, finished: Bool) {
        if let failure { throw failure }
        do {
            return try decodeSteps(payload, into: &output)
        } catch {
            failure = error
            finished = true
            throw error
        }
    }

    private mutating func decodeSteps(
        _ payload: RawSpan, into output: inout MutableRawSpan
    ) throws(LZMAError) -> (produced: Int, finished: Bool) {
        var produced = 0
        while !finished {
            if remaining == 0 {
                try finish(payload)
                break
            }
            guard produced < output.byteCount else { break }

            // Room in the window: wrap at its end, or grow it until it's the full size.
            if registers.position == model.windowSize {
                registers.position = 0
                registers.isFull = true
            } else if !registers.isFull && registers.position == window.count {
                let grown = min(model.windowSize, max(window.count * 2, Self.initialWindow))
                window.append(contentsOf: repeatElement(0, count: grown - window.count))
            }
            let start = registers.position
            let windowEnd = registers.isFull ? model.windowSize : min(window.count, model.windowSize)
            // The uncompressed size, as a window position (positions past the window's end are fine: this
            // only bounds matches).
            let sizeLimit = start + Int(min(remaining, UInt64(Int.max / 4)))
            let limit = min(windowEnd, start + (output.byteCount - produced), sizeLimit)

            var probabilitySpan = probabilities.mutableSpan
            var windowSpan = window.mutableSpan
            let endMarker = try Self.decodeSymbols(
                payload, &probabilitySpan, &windowSpan, &registers, model, limit: limit, sizeLimit: sizeLimit
            )
            let end = registers.position
            output.copyBytes(from: windowSpan.span.bytes.extracting(start..<end), toByteOffset: produced)
            produced += end - start
            remaining -= UInt64(end - start)

            guard registers.input <= payload.byteCount else { throw .truncated }
            if endMarker {
                // Only at the uncompressed size, with the range coder finished cleanly.
                guard remaining == 0, registers.code == 0 else { throw .corruptData }
                finished = true
            }
        }
        return (produced, finished)
    }

    /// At the uncompressed size: the stream ends there, or with an end marker next (always, with
    /// `hasEndMarker`). Anything else is corrupt.
    private mutating func finish(_ payload: RawSpan) throws(LZMAError) {
        // Without a marker, a finished range coder's code is 0 (`LzmaSpec`'s `IsFinishedOK`).
        if hasEndMarker || registers.code != 0 {
            var probabilitySpan = probabilities.mutableSpan
            try Self.decodeEndMarker(payload, &probabilitySpan, &registers, model)
        }
        guard registers.input <= payload.byteCount else { throw .truncated }
        finished = true
    }

    // MARK: The decode loop

    /// Decodes symbols into `window` from `registers.position` until it reaches `limit` (finishing a pending
    /// match first) or an end marker.
    ///
    /// The range decoder and the other registers are locals here, written back at the end: passed in memory,
    /// the loop would load and store them around every bit.
    ///
    /// - Parameters:
    ///   - input: The whole payload.
    ///   - probabilities: The probability model.
    ///   - window: The window, as allocated (at least up to `limit`).
    ///   - registers: The decoder's state, updated.
    ///   - model: The stream's parameters.
    ///   - limit: The window position to stop at: the window's end, the output's, or the uncompressed size's.
    ///   - sizeLimit: The window position of the uncompressed size: matches can't go past it.
    /// - Returns: Whether an end marker was decoded.
    /// - Throws: `corruptData` for a match before any output, a distance beyond the output or dictionary,
    ///   or a match past the uncompressed size; `truncated` for those when the input ran out first.
    private static func decodeSymbols(
        _ input: RawSpan, _ probabilities: inout MutableSpan<UInt16>, _ window: inout MutableSpan<UInt8>,
        _ registers: inout Registers, _ model: Model, limit: Int, sizeLimit: Int
    ) throws(LZMAError) -> Bool {
        var rc = RangeDecoder(range: registers.range, code: registers.code, position: registers.input)
        var state = registers.state
        var rep0 = registers.rep0, rep1 = registers.rep1, rep2 = registers.rep2, rep3 = registers.rep3
        var position = registers.position
        var previousByte = registers.previousByte
        var pending = registers.pending
        let isFull = registers.isFull
        let windowSize = model.windowSize
        let lc = model.lc
        var endMarker = false

        // The rest of a match from the last step.
        if pending > 0 {
            let count = min(pending, limit - position)
            previousByte = copyMatch(&window, to: position, distance: rep0 + 1, count: count, windowSize: windowSize)
            position += count
            pending -= count
        }

        while position < limit {
            let positionState = position & model.positionMask
            if rc.bit(&probabilities, isMatch + state << 4 + positionState, input) == 0 {
                // A literal, in one of `1 << (lc + lp)` contexts: the position's low lp bits and the previous
                // byte's high lc bits.
                let context = (position & model.literalPositionMask) << lc + Int(previousByte) >> (8 - lc)
                let base = literals + 0x300 * context
                var symbol = 1
                if state >= 7 {
                    // After a match: while the bits agree with the byte at rep0, they use the probabilities
                    // for that bit of it.
                    var source = position - rep0 - 1
                    if source < 0 { source += windowSize }
                    var matchByte = Int(window[source])
                    repeat {
                        let matchBit = matchByte >> 7 & 1
                        matchByte <<= 1
                        let bit = rc.bit(&probabilities, base + (1 + matchBit) << 8 + symbol, input)
                        symbol = symbol << 1 | bit
                        if matchBit != bit { break }
                    } while symbol < 0x100
                }
                while symbol < 0x100 {
                    symbol = symbol << 1 | rc.bit(&probabilities, base + symbol, input)
                }
                previousByte = UInt8(truncatingIfNeeded: symbol)
                window[position] = previousByte
                position += 1
                state = state < 4 ? 0 : state < 10 ? state - 3 : state - 6
                continue
            }

            var length: Int
            if rc.bit(&probabilities, isRep + state, input) != 0 {
                // A repeated distance: nothing to repeat before the first byte.
                guard position > 0 || isFull else { throw rc.failure(input) }
                if rc.bit(&probabilities, isRepG0 + state, input) == 0 {
                    if rc.bit(&probabilities, isRep0Long + state << 4 + positionState, input) == 0 {
                        // A one-byte match at rep0 (rep0 is in range: checked when it was decoded).
                        state = state < 7 ? 9 : 11
                        var source = position - rep0 - 1
                        if source < 0 { source += windowSize }
                        previousByte = window[source]
                        window[position] = previousByte
                        position += 1
                        continue
                    }
                } else {
                    let distance: Int
                    if rc.bit(&probabilities, isRepG1 + state, input) == 0 {
                        distance = rep1
                    } else {
                        if rc.bit(&probabilities, isRepG2 + state, input) == 0 {
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
                length = rc.length(&probabilities, repeatLengths, positionState, input)
                state = state < 7 ? 8 : 11
            } else {
                rep3 = rep2
                rep2 = rep1
                rep1 = rep0
                length = rc.length(&probabilities, matchLengths, positionState, input)
                state = state < 7 ? 7 : 10
                rep0 = try rc.distance(&probabilities, length: length, input)
                if rep0 == 0xFFFF_FFFF {
                    endMarker = true
                    break
                }
                // Within the output so far and the dictionary.
                let reach = isFull ? model.maximumDistance : min(position, model.maximumDistance)
                guard rep0 < reach else { throw rc.failure(input) }
            }
            length += 2
            guard length <= sizeLimit - position else { throw rc.failure(input) }
            let count = min(length, limit - position)
            previousByte = copyMatch(&window, to: position, distance: rep0 + 1, count: count, windowSize: windowSize)
            position += count
            pending = length - count
        }

        registers.range = rc.range
        registers.code = rc.code
        registers.input = rc.position
        registers.state = state
        registers.rep0 = rep0
        registers.rep1 = rep1
        registers.rep2 = rep2
        registers.rep3 = rep3
        registers.position = position
        registers.previousByte = previousByte
        registers.pending = pending
        return endMarker
    }

    /// Decodes what must be an end marker: a match with distance `0xFFFFFFFF`, after which the range coder
    /// is finished (its code 0).
    ///
    /// - Throws: `corruptData` for anything else; `truncated` if the input ran out.
    private static func decodeEndMarker(
        _ input: RawSpan, _ probabilities: inout MutableSpan<UInt16>, _ registers: inout Registers, _ model: Model
    ) throws(LZMAError) {
        var rc = RangeDecoder(range: registers.range, code: registers.code, position: registers.input)
        let state = registers.state
        let positionState = registers.position & model.positionMask
        guard rc.bit(&probabilities, isMatch + state << 4 + positionState, input) == 1,
              rc.bit(&probabilities, isRep + state, input) == 0
        else { throw rc.failure(input) }
        let length = rc.length(&probabilities, matchLengths, positionState, input)
        let distance = try rc.distance(&probabilities, length: length, input)
        guard distance == 0xFFFF_FFFF, rc.code == 0 else { throw rc.failure(input) }
        registers.range = rc.range
        registers.code = rc.code
        registers.input = rc.position
    }

    /// Copies `count` bytes from `distance` back, which may overlap the copy (a run), and may wrap around the
    /// window's end.
    ///
    /// - Returns: The last byte copied.
    /// - Precondition: `count` is at least 1, and fits from `position`; `distance` is at most `windowSize`
    ///   and, unless the window is full, `position`.
    @inline(__always)
    private static func copyMatch(
        _ window: inout MutableSpan<UInt8>, to position: Int, distance: Int, count: Int, windowSize: Int
    ) -> UInt8 {
        var source = position &- distance
        if source < 0 { source &+= windowSize }
        if source &+ count <= windowSize {
            if count > 32 && (source &+ count <= position || source > position) {
                // Long, and not overlapping (or from ahead, wrapped: a move reads the same bytes as copying a
                // byte at a time would). Short copies stay inline: most matches are.
                window.copyBytes(within: source..<(source &+ count), toByteOffset: position)
            } else {
                for offset in 0..<count {
                    window[position &+ offset] = window[source &+ offset]
                }
            }
        } else {
            // Wrapping around the window's end.
            for offset in 0..<count {
                window[position &+ offset] = window[source]
                source &+= 1
                if source == windowSize { source = 0 }
            }
        }
        return window[position &+ count &- 1]
    }
}

/// The range decoder (`LzmaSpec`'s `CRangeDecoder`), with the bit, tree, length, and distance decoders that
/// use it. A local in the decode loop, so its fields stay in registers.
private struct RangeDecoder {
    var range: UInt32
    var code: UInt32
    /// The next byte in the payload; past its end after reading zeros there.
    var position: Int

    /// The error for an invalid symbol: `truncated` if the input ran out (decoding zeros past its end is
    /// what made it invalid), otherwise `corruptData`.
    func failure(_ input: RawSpan) -> LZMAError {
        position > input.byteCount ? .truncated : .corruptData
    }

    /// Shifts in a byte when the range drops below 2^24. Past the payload's end, the byte is 0.
    @inline(__always)
    mutating func normalize(_ input: RawSpan) {
        if range < 1 << 24 {
            let byte = position < input.byteCount ? input.load(fromByteOffset: position, as: UInt8.self) : 0
            position &+= 1
            range <<= 8
            code = code << 8 | UInt32(byte)
        }
    }

    /// Decodes a bit with the probability at `index`, and adapts it.
    @inline(__always)
    mutating func bit(_ probabilities: inout MutableSpan<UInt16>, _ index: Int, _ input: RawSpan) -> Int {
        let probability = UInt32(probabilities[index])
        let bound = (range >> 11) &* probability
        let bit: Int
        if code < bound {
            range = bound
            probabilities[index] = UInt16(truncatingIfNeeded: probability &+ (2048 &- probability) >> 5)
            bit = 0
        } else {
            range &-= bound
            code &-= bound
            probabilities[index] = UInt16(truncatingIfNeeded: probability &- probability >> 5)
            bit = 1
        }
        normalize(input)
        return bit
    }

    /// A `bitCount`-bit symbol, most significant bit first, from a tree at `base` (nodes 1 through
    /// `1 << bitCount - 1`).
    @inline(__always)
    mutating func tree(
        _ probabilities: inout MutableSpan<UInt16>, _ base: Int, bitCount: Int, _ input: RawSpan
    ) -> Int {
        var node = 1
        for _ in 0..<bitCount {
            node = node << 1 | bit(&probabilities, base + node, input)
        }
        return node - 1 << bitCount
    }

    /// A `bitCount`-bit symbol, least significant bit first, from a tree at `base`.
    @inline(__always)
    mutating func reverseTree(
        _ probabilities: inout MutableSpan<UInt16>, _ base: Int, bitCount: Int, _ input: RawSpan
    ) -> Int {
        var node = 1
        var symbol = 0
        for index in 0..<bitCount {
            let bit = bit(&probabilities, base + node, input)
            node = node << 1 | bit
            symbol |= bit << index
        }
        return symbol
    }

    /// A match length less 2 (0 through 271), from the length coder at `base`.
    ///
    /// `@inline(always)`, as are `distance` and `directBits`: `@inline(__always)` left these calls, and a
    /// call taking the decoder `inout` kept it in memory for the whole decode loop.
    @inline(always)
    mutating func length(
        _ probabilities: inout MutableSpan<UInt16>, _ base: Int, _ positionState: Int, _ input: RawSpan
    ) -> Int {
        if bit(&probabilities, base, input) == 0 {
            return tree(&probabilities, base + 2 + positionState << 3, bitCount: 3, input)
        }
        if bit(&probabilities, base + 1, input) == 0 {
            return 8 + tree(&probabilities, base + 2 + 16 << 3 + positionState << 3, bitCount: 3, input)
        }
        return 16 + tree(&probabilities, base + 2 + 16 << 3 + 16 << 3, bitCount: 8, input)
    }

    /// A match distance less 1: a 6-bit slot (by length), then for slots 4 and up, low bits from a reverse
    /// tree, or direct bits and 4 align bits. `0xFFFFFFFF` is the end marker.
    ///
    /// - Parameter length: The match length less 2.
    /// - Throws: `corruptData` (or `truncated`) if direct bits leave the code equal to the range, which no
    ///   valid stream does.
    @inline(always)
    mutating func distance(
        _ probabilities: inout MutableSpan<UInt16>, length: Int, _ input: RawSpan
    ) throws(LZMAError) -> Int {
        let slot = tree(&probabilities, LZMADecoder.distanceSlots + min(length, 3) << 6, bitCount: 6, input)
        guard slot >= 4 else { return slot }
        let bitCount = slot >> 1 - 1
        var distance = (2 | slot & 1) << bitCount
        if slot < 14 {
            distance += reverseTree(
                &probabilities, LZMADecoder.specialDistances + distance - slot, bitCount: bitCount, input
            )
        } else {
            distance += try directBits(bitCount - 4, input) << 4
            distance += reverseTree(&probabilities, LZMADecoder.align, bitCount: 4, input)
        }
        return distance
    }

    /// `count` bits at a fixed probability of one half, most significant first.
    @inline(always)
    mutating func directBits(_ count: Int, _ input: RawSpan) throws(LZMAError) -> Int {
        var result: UInt32 = 0
        for _ in 0..<count {
            range >>= 1
            code &-= range
            let mask = 0 &- (code >> 31) // All ones if the code was below the range: a 0 bit.
            code &+= range & mask
            guard code != range else { throw failure(input) }
            normalize(input)
            result = result << 1 &+ (mask &+ 1)
        }
        return Int(result)
    }
}
