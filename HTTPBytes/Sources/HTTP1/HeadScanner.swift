public import Bytes
public import HTTPBytes

/// The structural walk over a message head shared by the request and response parsers.
///
/// A field line is a name, then a value; its end is its first control or DEL (a tab, which a value may have, sends the
/// line to the exact path), which must be CR then LF. The walk finds that first, from the line's start, in a 64-byte
/// block's mask of stops (2 compares and an OR per 16 bytes), built once per block and walked with
/// `trailingZeroBitCount`, so the next line's start depends only on the masks and not on this line's name and value:
/// consecutive lines overlap in the CPU. The name is then the bytes before the first
/// non-token character (which must be the colon), found with one 16-byte nibble mask at the line's start, and the value
/// what's between the colon and the line's end, less its whitespace (before the first stop, a byte at or below 0x20 can
/// only be a space: one compare per byte trimmed). cursed-http's fbparse.h (MIT) walks heads this way; its README
/// measured the name scan at the line start against a per-block mask of non-token bytes, whose cache missed whenever a
/// line crossed a block, and those mispredicts were most of its gap (HTTPBytes/RESULTS.md has ours).
///
/// The walk only moves forward, so only the current block's stop mask is kept: no memory per head. Offsets are from the
/// start of the bytes the parser is given; a block the bytes end in has its padding marked as stops (so scans stop
/// there) and is rebuilt when more bytes arrive.
@frozen @usableFromInline
struct HeadScanner: Sendable {
    /// The current block's offset (a multiple of 64), or -64 before the first.
    @usableFromInline var blockStart = -64
    /// The byte count the block's mask was built for, when the bytes ended inside the block (its padding then reads as
    /// stops); `Int.max` for a whole block. A partial block is rebuilt once the bytes grow past this.
    @usableFromInline var blockLimit = Int.max
    /// Field-value stops in the block: bit i for byte `blockStart + i`.
    @usableFromInline var stops: UInt64 = 0
    /// The line a parser stopped in for more bytes (its start offset), or -1: ``checked`` and ``mark`` describe it, so
    /// the next call resumes the line's scans where they stopped instead of from its start. Without them, a long line
    /// fed a few bytes at a time was scanned from its start on every call: quadratic (a 60 KB value a byte at a time
    /// took 60,000 calls and 0.13 s).
    @usableFromInline var partialLine = -1
    /// How far the partial line is known to be well formed: for a field line, its name's bytes are token characters up
    /// to here (before its colon is found), or its value has no field-value stop up to here; for a start line, the same
    /// for its method or target; for a status line, its reason phrase.
    @usableFromInline var checked = 0
    /// In the partial line: a field's colon, or a request line's method end, once found; 0 before.
    @usableFromInline var mark = 0

    @inlinable
    init() {}

    /// Remembers where the scans of the line at `start` stopped (``FieldLine/needsMore(checked:mark:)``).
    @inlinable @inline(__always)
    mutating func remember(line start: Int, checked: Int, mark: Int) {
        partialLine = start
        self.checked = checked
        self.mark = mark
    }

    /// The offset of the first line stop (a control, tab included, or DEL: `HTTPCharacters.controlOrDelete`) at or after
    /// `start`, or `bytes.byteCount` if there's none before the end.
    @inlinable @inline(always)
    mutating func nextStop(_ bytes: RawSpan, from start: Int) -> Int {
        let count = bytes.byteCount
        guard start < count else { return count }
        let block = start & ~63
        if block != blockStart || count > blockLimit {
            stops = Self.stopMask(bytes, block: block)
            blockStart = block
            blockLimit = block &+ 64 <= count ? Int.max : count
        }
        let bits = stops &>> UInt64(start & 63)
        if bits != 0 { return Swift.min(start &+ bits.trailingZeroBitCount, count) }
        // A line that runs into later blocks: a loop of its own, out of line, whose last block becomes the current one.
        let (stop, mask) = farStop(bytes, from: block &+ 64)
        blockStart = stop & ~63
        stops = mask
        blockLimit = blockStart &+ 64 <= count ? Int.max : count
        return stop
    }

    /// Starts the walk with `stops`, the stop mask of the block at `block`, built for `count` bytes.
    @inlinable @inline(__always)
    mutating func seed(block: Int, stops: UInt64, count: Int) {
        blockStart = block
        self.stops = stops
        blockLimit = block &+ 64 <= count ? Int.max : count
    }

    /// The stop mask of the block at `block` (`0 <= block < bytes.byteCount`). Static, taking and returning values: a
    /// `mutating` call left out of line would keep the scanner in memory for the whole parse loop (AGENTS.md).
    @inlinable
    static func stopMask(_ bytes: RawSpan, block: Int) -> UInt64 {
        blockMask(bytes, at: block, HTTPCharacters.controlOrDelete)
    }
}

/// The first line stop at or after `block` (a multiple of 64), and the mask of the block it's in: a long line's blocks
/// tested one after another, with nothing else in the loop. `bytes.byteCount` (and its block's mask) if there's none.
@usableFromInline
func farStop(_ bytes: RawSpan, from block: Int) -> (stop: Int, mask: UInt64) {
    let count = bytes.byteCount
    var block = block
    while block <= count &- 64 {
        let mask = bytes.byteBlock(at: block).mask(HTTPCharacters.controlOrDelete)
        if mask != 0 { return (block &+ mask.trailingZeroBitCount, mask) }
        block &+= 64
    }
    guard block < count else { return (count, ~0) }
    let mask = blockMask(bytes, at: block, HTTPCharacters.controlOrDelete)
    // Not zero: the bits past the end are set.
    return (Swift.min(block &+ mask.trailingZeroBitCount, count), mask)
}

// MARK: - Masks and scans

/// `test`'s mask of the 64 bytes at `block` (`0 <= block < bytes.byteCount`): bit i for byte `block + i`, with the bits
/// past the bytes' end set (so a scan stops there; every test here treats the end as a stop).
///
/// A block the bytes end in isn't copied when there are 64 bytes before its end: the block ending at the bytes' end is
/// tested instead, and its mask shifted into place.
@inlinable @inline(__always)
func blockMask(_ bytes: RawSpan, at block: Int, _ test: (ByteLanes) -> ByteMatches) -> UInt64 {
    let count = bytes.byteCount
    if block <= count &- 64 { return bytes.byteBlock(at: block).mask(test) }
    if count >= 64 {
        let last = count &- 64
        // `block - last` and `count - block` are both in 1...63: the block starts after `last` and before `count`.
        return bytes.byteBlock(at: last).mask(test) &>> UInt64(block &- last) | ~0 &<< UInt64(count &- block)
    }
    return bytes.byteBlock(at: block, padding: 0).mask(test)
}

/// The offset of the first byte at or after `start` that passes `test`, scanning 64-byte block masks, or
/// `bytes.byteCount` if there's none before the end. `start` must be less than `bytes.byteCount`.
@inlinable @inline(__always)
func firstMatch(_ bytes: RawSpan, from start: Int, _ test: (ByteLanes) -> ByteMatches) -> Int {
    let count = bytes.byteCount
    var block = start & ~63
    var bits = blockMask(bytes, at: block, test) &>> UInt64(start & 63)
    while bits == 0 {
        block &+= 64
        if block >= count { return count }
        bits = blockMask(bytes, at: block, test)
        if bits != 0 { return Swift.min(block &+ bits.trailingZeroBitCount, count) }
    }
    return Swift.min(start &+ bits.trailingZeroBitCount, count)
}

/// The offset of the first byte at or after `start` that isn't a token character, or `bytes.byteCount` if there's none
/// before the end: 16-byte nibble masks (a name's end is usually in the first), the last one overlapping the end.
@inlinable @inline(always)
func tokenEnd(_ bytes: RawSpan, from start: Int) -> Int {
    let count = bytes.byteCount
    var position = start
    while position &+ 16 <= count {
        // Unsafe: an unchecked 16-byte load. Safe: `position + 16 <= count`.
        let lanes = unsafe bytes.unsafeLoadUnaligned(fromUncheckedByteOffset: position, as: SIMD16<UInt8>.self)
        let nibbles = HTTPCharacters.nonToken(ByteLanes(lanes)).nibbleMask
        if nibbles != 0 { return position &+ nibbles.trailingZeroBitCount &>> 2 }
        position &+= 16
    }
    return tokenEndNearEnd(bytes, from: position)
}

/// `tokenEnd` for the last bytes, fewer than 16 from `start` to the end: out of line (rare: a name near the end of
/// the bytes).
@usableFromInline
func tokenEndNearEnd(_ bytes: RawSpan, from start: Int) -> Int {
    let count = bytes.byteCount
    guard start < count else { return count }
    if count >= 16 {
        // A 16-byte load ending at the bytes' end: `count >= 16`, so its check folds.
        let lanes = bytes.load(fromByteOffset: count &- 16, as: SIMD16<UInt8>.self)
        // The lanes before `start` shifted out (zeros come in at the top: no match before the end gives `count`).
        let nibbles = HTTPCharacters.nonToken(ByteLanes(lanes)).nibbleMask &>> UInt64(4 &* (start &- (count &- 16)))
        return nibbles == 0 ? count : start &+ nibbles.trailingZeroBitCount &>> 2
    }
    var position = start
    while position < count, isTokenCharacter(bytes.byte(position)) {
        position &+= 1
    }
    return position
}

/// Whether `byte` is a token character (`tchar`, RFC 9110 §5.6.2), from a 128-bit map: for scalar paths.
@inlinable @inline(__always)
func isTokenCharacter(_ byte: UInt8) -> Bool {
    // Bit b of the pair is set when byte b is a tchar: `!#$%&'*+-.` and digits below 64; letters, `^_\``, `|`, `~`.
    let word: UInt64 = byte < 64 ? 0x03FF_6CFA_0000_0000 : byte < 128 ? 0x57FF_FFFF_C7FF_FFFE : 0
    return (word &>> UInt64(byte & 63)) & 1 != 0
}

// MARK: - Lines

/// A field line's parts, as offsets.
@frozen @usableFromInline
enum FieldLine {
    case field(nameEnd: Int, valueStart: Int, valueEnd: Int, next: Int)
    case end(next: Int)
    /// The bytes end inside the line: its scans stopped at `checked`, with the colon at `mark` if found (0 if not), for
    /// ``HeadScanner/remember(line:checked:mark:)``.
    case needsMore(checked: Int, mark: Int)
}

/// `bytes` without what's past `limit`, the head's largest size: a line that needs those bytes makes the head too large
/// whether they've arrived or not, so the exact paths never look at them, and a head's verdict doesn't depend on how
/// its bytes were split (431 for a line crossing the limit, rather than 400 for a malformed byte past it when the bytes
/// arrived at once and 431 when they came in pieces).
@inlinable @inline(__always)
@_lifetime(copy bytes)
func headPrefix(_ bytes: RawSpan, limit: Int) -> RawSpan {
    bytes.byteCount > limit ? bytes.extracting(0..<Swift.max(limit, 0)) : bytes
}

/// The line at `start`, decided byte by byte and with vector scans: the walk's path for anything it doesn't take (the
/// bytes ending inside the line, a line that doesn't end in CR LF, a malformed name, the empty line with a bare LF), so
/// its results and errors are the exact ones. Out of line: it runs for at most one line a call in well-formed heads.
///
/// It resumes a line it stopped in before (`checked` past `start`: the name's bytes before it are token characters, or,
/// with the colon at `mark`, the value has no field-value stop before it), so a line fed in pieces is scanned once.
/// Bytes past `limit` aren't looked at (`headPrefix`).
@usableFromInline
func exactFieldLine(_ whole: RawSpan, at start: Int, checked: Int, mark: Int, allowsBareLineFeed: Bool,
                    limit: Int) throws(HTTP1Error) -> FieldLine {
    let bytes = headPrefix(whole, limit: limit)
    let count = bytes.byteCount
    guard start < count else { return .needsMore(checked: start, mark: 0) }
    let first = bytes.byte(start)
    var colon = mark
    var scanFrom = checked
    if colon == 0 {
        if first == .cr {
            guard start &+ 1 < count else { return .needsMore(checked: start, mark: 0) }
            guard bytes.byte(start &+ 1) == .lf else { throw .invalidLineEnding }
            return .end(next: start &+ 2)
        }
        if first == .lf {
            guard allowsBareLineFeed else { throw .invalidLineEnding }
            return .end(next: start &+ 1)
        }
        // The name's bytes before `checked` are token characters (checked by an earlier call).
        colon = tokenEnd(bytes, from: Swift.max(start, checked))
        guard colon < count else { return .needsMore(checked: colon, mark: 0) }
        guard bytes.byte(colon) == .colon, colon > start else {
            if colon == start, first == .space || first == .tab { throw .obsoleteLineFolding }
            throw .invalidFieldName
        }
        scanFrom = colon &+ 1
    }
    // The value's stop, from where an earlier call left off (whitespace before the value isn't a stop, so the scan can
    // start at the colon).
    guard scanFrom < count,
          let stopOffset = bytes.extracting(droppingFirst: scanFrom).firstByteOffset(where: HTTPCharacters.fieldValueStop)
    else { return .needsMore(checked: Swift.max(scanFrom, count), mark: colon) }
    let stop = scanFrom &+ stopOffset
    guard let next = try lineEnd(bytes, at: stop, allowsBareLineFeed: allowsBareLineFeed, otherwise: .invalidFieldValue)
    else { return .needsMore(checked: stop, mark: colon) }
    var valueStart = colon &+ 1
    while valueStart < stop, case let byte = bytes.byte(valueStart), byte == .space || byte == .tab {
        valueStart &+= 1
    }
    var valueEnd = stop
    while valueEnd > valueStart, case let byte = bytes.byte(valueEnd &- 1), byte == .space || byte == .tab {
        valueEnd &-= 1
    }
    return .field(nameEnd: colon, valueStart: valueStart, valueEnd: valueEnd, next: next)
}

/// The end of the line whose content ends at `stop` (a field-value stop): the offset after CR LF (or a bare LF where
/// allowed), `nil` if the bytes end first; throws `error` if `stop` isn't a line end.
@inlinable @inline(__always)
func lineEnd(_ bytes: RawSpan, at stop: Int, allowsBareLineFeed: Bool, otherwise error: HTTP1Error) throws(HTTP1Error) -> Int? {
    let count = bytes.byteCount
    guard stop < count else { return nil }
    switch bytes.byte(stop) {
    case .cr:
        guard stop &+ 1 < count else { return nil }
        guard bytes.byte(stop &+ 1) == .lf else { throw .invalidLineEnding }
        return stop &+ 2
    case .lf:
        guard allowsBareLineFeed else { throw .invalidLineEnding }
        return stop &+ 1
    default:
        throw error
    }
}

/// A field line in the walk: where its name and value are, once its end (`stop`, the line's first field-value stop,
/// followed by LF) is known. `nil` when the name isn't a token followed by a colon (the exact path then says why).
///
/// - Precondition: `start < stop`, `stop + 1 < bytes.byteCount`, and no field-value stop in `start..<stop`.
@inlinable @inline(always)
func walkedField(_ bytes: RawSpan, at start: Int, stop: Int) -> (nameEnd: Int, valueStart: Int, valueEnd: Int)? {
    // At most `stop`: CR isn't a token character.
    let nameEnd = tokenEnd(bytes, from: start)
    guard bytes.byte(nameEnd) == .colon, nameEnd > start else { return nil }
    // The usual ": " in one step; then any more whitespace (before `stop`, bytes at or below 0x20 are spaces and tabs:
    // every other control is a stop). `byte(valueStart)` is read before the bound: `valueStart <= stop`, a byte of the
    // line, and the common case is then one compare.
    var valueStart = nameEnd &+ 1
    valueStart &+= bytes.byte(valueStart) == .space ? 1 : 0
    while bytes.byte(valueStart) <= .space, valueStart < stop {
        valueStart &+= 1
    }
    var valueEnd = stop
    while bytes.byte(valueEnd &- 1) <= .space, valueEnd > valueStart {
        valueEnd &-= 1
    }
    return (nameEnd, valueStart, valueEnd)
}

extension RawSpan {
    /// The byte at `offset`, unchecked: every caller in this module has compared `offset` with `byteCount` first (the
    /// parsers' `guard … < count` before each read), and a bounds check per byte read was a compare and a branch on
    /// every field's colon, value start and end, and line end.
    ///
    /// - Precondition: `0 <= offset < byteCount` (asserted in debug builds).
    @inlinable @inline(__always)
    func byte(_ offset: Int) -> UInt8 {
        assert(offset >= 0 && offset < byteCount, "byte offset out of bounds")
        // Unsafe: an unchecked load. Safe: the precondition above, which every caller establishes.
        return unsafe unsafeLoad(fromUncheckedByteOffset: offset, as: UInt8.self)
    }

    /// The `T` at `offset`, unchecked, as `byte(_:)`.
    ///
    /// - Precondition: `0 <= offset` and `offset + MemoryLayout<T>.size <= byteCount` (asserted in debug builds).
    @inlinable @inline(__always)
    func word<T: FixedWidthInteger & BitwiseCopyable>(_ offset: Int, as type: T.Type) -> T {
        assert(offset >= 0 && offset &+ MemoryLayout<T>.size <= byteCount, "word offset out of bounds")
        // Unsafe: an unchecked load. Safe: the precondition above, which every caller establishes.
        return T(littleEndian: unsafe unsafeLoadUnaligned(fromUncheckedByteOffset: offset, as: T.self))
    }

    /// The bytes from `start` to `end`, unchecked (no range precondition either: a `Range` checks its bounds' order).
    ///
    /// - Precondition: `0 <= start <= end <= byteCount` (asserted in debug builds).
    @inlinable @inline(__always)
    @_lifetime(copy self)
    func slice(_ start: Int, _ end: Int) -> RawSpan {
        assert(start >= 0 && start <= end && end <= byteCount, "range out of bounds")
        // Unsafe: an unchecked slice. Safe: the precondition above, which every caller establishes.
        return unsafe extracting(unchecked: Range(uncheckedBounds: (start, end)))
    }
}

extension UInt8 {
    @usableFromInline static var cr: UInt8 { 0x0D }
    @usableFromInline static var lf: UInt8 { 0x0A }
    @usableFromInline static var colon: UInt8 { 0x3A }
    @usableFromInline static var space: UInt8 { 0x20 }
    @usableFromInline static var tab: UInt8 { 0x09 }
}

extension UInt16 {
    /// CR LF as a little-endian word.
    @usableFromInline static var crlf: UInt16 { 0x0A0D }
}

/// `HTTP/1.1` and `HTTP/1.0` as little-endian words, and the version they are. `HTTP/1.2` through `HTTP/1.9` are 1.1: RFC
/// 9110 §2.5, a higher minor version of a major version the recipient implements SHOULD be processed as the highest it
/// implements. (A second minor digit, as `HTTP/1.32`, is then where the line's CR or SP should be: the callers reject
/// it as an invalid version.) Other well-formed versions are unsupported (505); anything else is invalid.
@inlinable @inline(__always)
func http1Version(_ bytes: RawSpan, at offset: Int) throws(HTTP1Error) -> HTTPVersion {
    let word = bytes.load(fromByteOffset: offset, as: UInt64.self)
    if word == 0x312E_312F_5054_5448 { return .http1_1 }
    if word == 0x302E_312F_5054_5448 { return .http1_0 }
    if word & 0x00FF_FFFF_FFFF_FFFF == 0x2E_312F_5054_5448, (word &>> 56) &- 0x32 < 8 { return .http1_1 }
    // `HTTP/` then a digit, `.`, and a digit: well formed, but not a version this parser speaks.
    let digits = word &>> 40
    if word & 0xFF_FFFF_FFFF == 0x2F_5054_5448, (digits & 0xFF) &- 0x30 < 10, (digits &>> 8) & 0xFF == 0x2E,
       (digits &>> 16) &- 0x30 < 10 {
        throw .unsupportedVersion
    }
    throw .invalidVersion
}

extension HeadScanner {
    /// The line at `start`: a field, the empty line that ends the head, or not all there yet. The walk takes a line that
    /// ends in CR LF with a well-formed name; anything else goes to the exact path, which finds its error. A line the
    /// bytes ended in before is resumed where its scans stopped (``partialLine``). The exact path ignores bytes past
    /// `limit` (`headPrefix`); the walk's results are checked against it by the caller.
    @inlinable @inline(always)
    mutating func fieldLine(_ bytes: RawSpan, at start: Int, allowsBareLineFeed: Bool, limit: Int = .max) throws(HTTP1Error) -> FieldLine {
        let count = bytes.byteCount
        let stop = nextStop(bytes, from: start)
        if stop &+ 1 < count, bytes.word(stop, as: UInt16.self) == .crlf {
            if stop == start { return .end(next: stop &+ 2) }
            if let (nameEnd, valueStart, valueEnd) = walkedField(bytes, at: start, stop: stop) {
                return .field(nameEnd: nameEnd, valueStart: valueStart, valueEnd: valueEnd, next: stop &+ 2)
            }
        }
        // The exact path. A line the bytes ended in before resumes where its scans stopped; one they end in now is
        // remembered, and the walk is sent straight back here on the next call (`rememberFieldLine`).
        let resumes = partialLine == start
        let line = try exactFieldLine(bytes, at: start, checked: resumes ? checked : start, mark: resumes ? mark : 0,
                                      allowsBareLineFeed: allowsBareLineFeed, limit: limit)
        if case let .needsMore(checked, mark) = line {
            rememberFieldLine(start, checked: checked, mark: mark)
        } else if resumes {
            // The stop mask was the placeholder: the next line's block is built again.
            blockStart = -64
        }
        return line
    }

    /// Remembers where the scans of the field line at `start` stopped, and makes the walk's next `nextStop(_:from:
    /// start)` return `start` itself: the current block's stop mask becomes one bit, at `start`, valid for any byte
    /// count. A line's first byte isn't CR LF unless it's the empty line (which the walk then takes, rightly), so the
    /// walk goes to the exact path, which resumes the line. Without this, the walk's own scan (`farStop`) would cover the
    /// whole line again on every call; with it, the walk pays nothing for resumption (the alternative, a test of
    /// ``partialLine`` per line, cost 4–10% of cycles on heads of long fields).
    @inlinable @inline(__always)
    mutating func rememberFieldLine(_ start: Int, checked: Int, mark: Int) {
        remember(line: start, checked: checked, mark: mark)
        blockStart = start & ~63
        stops = 1 &<< UInt64(start & 63)
        blockLimit = .max
    }
}

/// The end of a request target at `start` (`start < bytes.byteCount`): the first byte that can't be in one, or
/// `bytes.byteCount`. Out of line: once per head, and inlined, its block-mask loop and partial-block cases made the
/// parse loop large enough that the inliner stopped inlining small functions into it (`RawSpan.byteCount` stayed a call).
@usableFromInline
func targetEnd(_ bytes: RawSpan, from start: Int) -> Int {
    firstMatch(bytes, from: start, HTTPCharacters.targetStop)
}

/// `targetEnd`, and the line-stop mask of the block the target ends in, from the same loaded block: the walk starts with
/// that block, so a head's first block (or its only one: a short head ends in it) is loaded, or copied, once.
@usableFromInline
func targetScan(_ bytes: RawSpan, from start: Int) -> (end: Int, block: Int, stops: UInt64) {
    let count = bytes.byteCount
    var block = start & ~63
    var shift = UInt64(start & 63)
    while block < count {
        let targets: UInt64, stops: UInt64
        if block <= count &- 64 {
            let lanes = bytes.byteBlock(at: block)
            (targets, stops) = (lanes.mask(HTTPCharacters.targetStop), lanes.mask(HTTPCharacters.controlOrDelete))
        } else if count >= 64 {
            // As `blockMask`: the block ending at the end, shifted; the bits past the end set.
            let last = count &- 64, lanes = bytes.byteBlock(at: last)
            let move = UInt64(block &- last), padding: UInt64 = ~0 &<< UInt64(count &- block)
            targets = lanes.mask(HTTPCharacters.targetStop) &>> move | padding
            stops = lanes.mask(HTTPCharacters.controlOrDelete) &>> move | padding
        } else {
            let lanes = bytes.byteBlock(at: block, padding: 0)
            (targets, stops) = (lanes.mask(HTTPCharacters.targetStop), lanes.mask(HTTPCharacters.controlOrDelete))
        }
        let found = targets &>> shift
        if found != 0 { return (Swift.min(block &+ Int(shift) &+ found.trailingZeroBitCount, count), block, stops) }
        block &+= 64
        shift = 0
    }
    return (count, block, ~0)
}
