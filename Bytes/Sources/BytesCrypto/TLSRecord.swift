public import Bytes
internal import Dispatch

// TLS 1.3's record layer (RFC 8446, 5): records protected with the suite's AEAD, as pipeline stages. The sealer
// writes application data (and alerts and KeyUpdates); the opener reads application data and acts on the rest:
// close_notify ends the stream, other alerts and malformed records throw (with the alert to report in
// `alert`), and a peer's KeyUpdate updates its keys.

/// Record framing shared by the sealer and opener.
enum TLSRecord {
    /// The header: type, legacy version 0x0303, length.
    static var headerSize: Int { 5 }
    /// The AEAD tag.
    static var tagSize: Int { 16 }
    /// The most plaintext per record: 2¹⁴.
    static var maximumPlaintext: Int { 1 << 14 }
    /// The most a record's protected part may be: plaintext, content type, padding, tag (2¹⁴ + 256).
    static var maximumEncrypted: Int { maximumPlaintext &+ 256 }

    /// A record's size for `count` bytes of content and `padding` zeros: header, content, type, padding, tag.
    static func size(content count: Int, padding: Int = 0) -> Int { headerSize &+ count &+ 1 &+ padding &+ tagSize }

    /// The per-record nonce: the IV XOR the 64-bit sequence number, big-endian, in its last 8 bytes.
    static func nonce(_ iv: InlineArray<12, UInt8>, sequence: UInt64) -> InlineArray<12, UInt8> {
        var nonce = iv
        for index in 0..<8 {
            nonce[4 &+ index] ^= UInt8(truncatingIfNeeded: sequence &>> UInt64(56 &- 8 &* index))
        }
        return nonce
    }

    /// The KeyUpdate message (RFC 8446, 4.6.3): type 24, length 1, `update_not_requested` (0) or
    /// `update_requested` (1).
    static func keyUpdate(requested: Bool) -> InlineArray<5, UInt8> { [24, 0, 0, 1, requested ? 1 : 0] }
}

/// The suite's AEAD, keyed.
enum TLSRecordAEAD: Sendable {
    case aesGCM(AESGCM)
    case chaCha(ChaCha20Poly1305)

    init(keys: TLSTrafficKeys) {
        switch keys.suite {
        case .aes128GCMSHA256, .aes256GCMSHA384: self = .aesGCM(AESGCM(key: keys.keyBytes))
        case .chaCha20Poly1305SHA256: self = .chaCha(ChaCha20Poly1305(key: keys.keyBytes))
        }
    }

    func seal(_ message: inout MutableRawSpan, nonce: RawSpan, authenticating aad: RawSpan) -> InlineArray<16, UInt8> {
        switch self {
        case let .aesGCM(aead): aead.seal(&message, nonce: nonce, authenticating: aad)
        case let .chaCha(aead): aead.seal(&message, nonce: nonce, authenticating: aad)
        }
    }

    func open(_ message: inout MutableRawSpan, nonce: RawSpan, authenticating aad: RawSpan, tag: RawSpan) throws(BytesError) {
        switch self {
        case let .aesGCM(aead): try aead.open(&message, nonce: nonce, authenticating: aad, tag: tag)
        case let .chaCha(aead): try aead.open(&message, nonce: nonce, authenticating: aad, tag: tag)
        }
    }
}

/// One direction's record protection: the AEAD, the IV, and the record sequence. Seals or opens one record at a
/// time; ``TLSRecordSealer`` and ``TLSRecordOpener`` drive it as pipeline stages.
public struct TLSRecordProtection: Sendable {
    /// The cipher suite.
    public let suite: TLSCipherSuite
    var aead: TLSRecordAEAD
    var iv: InlineArray<12, UInt8>
    /// The next record's sequence number.
    public private(set) var sequence: UInt64 = 0
    /// The traffic secret the keys came from, if known: needed to update them.
    public private(set) var secret: TLSSecret?
    /// The records one key may protect (``TLSCipherSuite/recordLimit``; lower in tests).
    let recordLimit: UInt64

    /// Protection with `keys`, from the first record. Without the secret the keys can't be updated: once the suite's
    /// record limit is reached, sealing fails.
    ///
    /// - Parameter keys: The traffic keys.
    public init(keys: TLSTrafficKeys) {
        suite = keys.suite
        aead = TLSRecordAEAD(keys: keys)
        iv = keys.iv
        secret = nil
        recordLimit = keys.suite.recordLimit
    }

    /// Protection with the keys of a traffic secret, from the first record. With the secret, the keys can be
    /// updated (``update()``).
    ///
    /// - Parameters:
    ///   - secret: The traffic secret.
    ///   - recordLimit: The records per key; the suite's limit unless testing.
    public init(secret: TLSSecret, recordLimit: UInt64? = nil) {
        let keys = TLSTrafficKeys(secret: secret)
        suite = secret.suite
        aead = TLSRecordAEAD(keys: keys)
        iv = keys.iv
        self.secret = secret
        self.recordLimit = recordLimit ?? secret.suite.recordLimit
    }

    /// Whether the key has one record left, which the KeyUpdate itself needs: the sender must update it now.
    public var needsKeyUpdate: Bool { sequence >= recordLimit &- 1 }

    /// Moves to the next traffic secret's keys (RFC 8446, 7.2), from sequence number 0.
    ///
    /// - Precondition: The protection was made from a secret.
    public mutating func update() {
        guard let current = secret else { preconditionFailure("Updating keys needs the traffic secret") }
        let next = current.updated
        let keys = TLSTrafficKeys(secret: next)
        aead = TLSRecordAEAD(keys: keys)
        iv = keys.iv
        secret = next
        sequence = 0
    }

    /// Seals `content` as one record of `type` into the start of `output`: header, then the encrypted content,
    /// type, and `padding` zeros, then the tag.
    ///
    /// - Parameters:
    ///   - content: At most 2¹⁴ bytes, less the padding.
    ///   - type: The content type.
    ///   - padding: Zeros added to hide the content's length.
    ///   - output: Room for the record: a 5-byte header, the content, its type byte, the padding, and a 16-byte tag.
    /// - Returns: The record's size.
    /// - Throws: ``TLSAlert/internalError`` if the key has protected its limit of records (update it first).
    /// - Precondition: The content and padding fit a record, and `output` has room.
    public mutating func seal(
        _ content: RawSpan, type: TLSContentType, padding: Int = 0, into output: inout MutableRawSpan
    ) throws(TLSAlert) -> Int {
        precondition(padding >= 0 && content.byteCount &+ padding <= TLSRecord.maximumPlaintext, "A record holds at most 2^14 bytes")
        guard sequence < recordLimit else { throw .internalError }
        let count = content.byteCount
        let encrypted = count &+ 1 &+ padding &+ TLSRecord.tagSize
        let total = TLSRecord.headerSize &+ encrypted
        precondition(output.byteCount >= total, "No room for the record")
        let header: InlineArray<5, UInt8> = [
            TLSContentType.applicationData.rawValue, 0x03, 0x03, UInt8(truncatingIfNeeded: encrypted &>> 8), UInt8(truncatingIfNeeded: encrypted),
        ]
        output.copyBytes(from: header.span.bytes, toByteOffset: 0)
        output.copyBytes(from: content, toByteOffset: TLSRecord.headerSize)
        output.storeBytes(of: type.rawValue, toByteOffset: TLSRecord.headerSize &+ count, as: UInt8.self)
        for index in 0..<padding {
            output.storeBytes(of: 0 as UInt8, toByteOffset: TLSRecord.headerSize &+ count &+ 1 &+ index, as: UInt8.self)
        }
        let nonce = TLSRecord.nonce(iv, sequence: sequence)
        sequence &+= 1
        let plaintextEnd = TLSRecord.headerSize &+ count &+ 1 &+ padding
        var body = output._mutatingExtracting(TLSRecord.headerSize..<plaintextEnd)
        let tag = aead.seal(&body, nonce: nonce.span.bytes, authenticating: header.span.bytes)
        output.copyBytes(from: tag.span.bytes, toByteOffset: plaintextEnd)
        return total
    }

    /// Opens the protected record whose header and body are given, decrypting the body into the start of
    /// `output`, and strips its padding.
    ///
    /// - Parameters:
    ///   - header: The record's 5-byte header (its additional data).
    ///   - body: The protected part: encrypted content, type, padding, then the tag.
    ///   - output: Room for the body less the tag.
    /// - Returns: The content type and the content's length (at the start of `output`).
    /// - Throws: ``TLSAlert/badRecordMAC`` if it doesn't authenticate; ``TLSAlert/recordOverflow`` if its content
    ///   is over 2¹⁴ bytes; ``TLSAlert/unexpectedMessage`` if it has no content type or an unknown one.
    public mutating func open(header: RawSpan, body: RawSpan, into output: inout MutableRawSpan) throws(TLSAlert) -> (type: TLSContentType, count: Int) {
        guard body.byteCount > TLSRecord.tagSize else { throw .badRecordMAC }
        let encryptedLength = body.byteCount &- TLSRecord.tagSize
        precondition(output.byteCount >= encryptedLength, "No room for the record's plaintext")
        output.copyBytes(from: body.extracting(first: encryptedLength), toByteOffset: 0)
        let nonce = TLSRecord.nonce(iv, sequence: sequence)
        var plaintext = output._mutatingExtracting(0..<encryptedLength)
        do throws(BytesError) {
            try aead.open(&plaintext, nonce: nonce.span.bytes, authenticating: header, tag: body.extracting(droppingFirst: encryptedLength))
        } catch {
            throw .badRecordMAC
        }
        sequence &+= 1
        // The inner plaintext: content, then the type, then zero padding.
        var end = encryptedLength
        while end > 0 && plaintext.bytes.load(fromByteOffset: end &- 1, as: UInt8.self) == 0 { end &-= 1 }
        guard end > 0, let type = TLSContentType(rawValue: plaintext.bytes.load(fromByteOffset: end &- 1, as: UInt8.self)),
              type != .changeCipherSpec else {
            throw .unexpectedMessage
        }
        guard end &- 1 <= TLSRecord.maximumPlaintext else { throw .recordOverflow }
        return (type, end &- 1)
    }
}

// MARK: - Sealer

/// A pipeline stage that seals bytes into TLS 1.3 application-data records with the suite's AEAD.
///
/// Records hold up to 16 KB. A flush ends the current record, so each flushed message is one record (or more,
/// if longer than 16 KB). With nothing buffered and room in the output (and a full record's input or a
/// flush), a record is sealed straight into the output: plaintext copied in, encrypted in place, tag
/// appended. Otherwise the plaintext is buffered first.
///
/// Made from a traffic secret, it updates its keys itself before they reach their record limit (RFC 8446, 5.5),
/// sending a KeyUpdate first. ``alert`` holds the alert to send after a failure.
public struct TLSRecordSealer: ~Copyable {
    var protection: TLSRecordProtection
    /// Plaintext waiting to fill a record.
    var plaintext: ByteBuffer
    /// Sealed records waiting for room in the output: up to a KeyUpdate and a full record.
    var sealed: ByteBuffer
    /// Zeros added to each record (RFC 8446, 5.4).
    public var padding: Int = 0
    /// The alert to send for the last failure, if any.
    public private(set) var alert: TLSAlert?
    /// How many cores may seal at once. With more than one, a call given several full records' worth of input and
    /// room for them seals them in parallel, each straight into its place in the output; records keep their order and
    /// sequence numbers, so the stream is the same as with one.
    public var sealingLanes: Int = 1
    /// The fewest full records worth sealing in parallel: below that, waking the lanes costs more than it saves.
    static let minimumParallelRecords = 4

    /// Creates a sealer for one direction's keys. It can't update them: after the suite's record limit, sealing fails.
    ///
    /// - Parameter keys: The traffic keys.
    public init(keys: TLSTrafficKeys) {
        self.init(protection: TLSRecordProtection(keys: keys))
    }

    /// Creates a sealer for one direction's traffic secret, which updates its keys as needed.
    ///
    /// - Parameters:
    ///   - secret: The application traffic secret.
    ///   - recordLimit: The records per key; the suite's limit unless testing.
    public init(secret: TLSSecret, recordLimit: UInt64? = nil) {
        self.init(protection: TLSRecordProtection(secret: secret, recordLimit: recordLimit))
    }

    init(protection: TLSRecordProtection) {
        self.protection = protection
        // Each is filled from empty and emptied whole (or delivered to the end), so neither compacts.
        plaintext = ByteBuffer(capacity: TLSRecord.maximumPlaintext, compactingBelow: 0)
        sealed = ByteBuffer(capacity: 2 &* TLSRecord.size(content: TLSRecord.maximumPlaintext, padding: 0) &+ 256, compactingBelow: 0)
    }

    /// The record protection: its suite and sequence number.
    public var recordProtection: TLSRecordProtection { protection }

    /// Updates the keys now, sending a KeyUpdate (with `requested` asking the peer to update theirs too): as a
    /// response to the peer's request (``TLSRecordOpener/peerRequestedKeyUpdate``).
    ///
    /// - Parameter requested: Whether to ask the peer to update its keys as well.
    /// - Throws: ``TLSAlert/internalError`` if the sealer has no traffic secret.
    public mutating func updateKeys(requestingPeerUpdate requested: Bool = false) throws(TLSAlert) {
        guard protection.secret != nil else { throw .internalError }
        let message = TLSRecord.keyUpdate(requested: requested)
        try sealRecord(message.span.bytes, type: .handshake)
        protection.update()
    }

    /// Seals an alert record (`level` from the alert: warning for close_notify and user_canceled, fatal otherwise),
    /// delivered by the next `transform`.
    ///
    /// - Parameter alert: The alert to send.
    public mutating func send(_ alert: TLSAlert) {
        let message: InlineArray<2, UInt8> = [alert.isFatal ? 2 : 1, alert.rawValue]
        try? sealRecord(message.span.bytes, type: .alert)
    }

    /// Seals `content` into ``sealed``, updating the keys first if they're at their limit.
    mutating func sealRecord(_ content: RawSpan, type: TLSContentType) throws(TLSAlert) {
        if protection.needsKeyUpdate {
            guard protection.secret != nil else { alert = .internalError; throw .internalError }
            let message = TLSRecord.keyUpdate(requested: false)
            try Self.seal(message.span.bytes, type: .handshake, padding: 0, protection: &protection, into: &sealed)
            protection.update()
        }
        try Self.seal(content, type: type, padding: padding, protection: &protection, into: &sealed)
    }

    /// Seals `content` as one record appended to `buffer`. (Static, taking what it needs: the content may be a span
    /// of the sealer's own plaintext buffer while the sealed buffer is filled.)
    static func seal(
        _ content: RawSpan, type: TLSContentType, padding: Int, protection: inout TLSRecordProtection, into buffer: inout ByteBuffer
    ) throws(TLSAlert) {
        let size = TLSRecord.size(content: content.byteCount, padding: padding)
        try buffer.fill { (output) throws(TLSAlert) in
            try output.withFreeCapacity(byteCount: size) { (span, written) throws(TLSAlert) in
                written = try protection.seal(content, type: type, padding: padding, into: &span)
            }
        }
    }

    /// Seals the buffered plaintext into ``sealed``.
    mutating func sealBuffered() throws(TLSAlert) {
        if protection.needsKeyUpdate {
            guard protection.secret != nil else { alert = .internalError; throw .internalError }
            let message = TLSRecord.keyUpdate(requested: false)
            try Self.seal(message.span.bytes, type: .handshake, padding: 0, protection: &protection, into: &sealed)
            protection.update()
        }
        try Self.seal(plaintext.unread, type: .applicationData, padding: padding, protection: &protection, into: &sealed)
        plaintext.removeAll()
    }

    private mutating func deliverSealed(into output: inout OutputRawSpan) -> Int {
        let count = min(sealed.unreadByteCount, output.freeCapacity)
        guard count > 0 else { return 0 }
        output.append(copying: sealed.unread.extracting(0..<count))
        sealed.consume(count)
        return count
    }
}

extension TLSRecordSealer: ResettableByteTransform {
    /// Failures are ``BytesError/invalidValue``, with ``alert`` saying why.
    public typealias Failure = BytesError

    /// Discards buffered plaintext and sealed bytes not yet delivered. The record sequence continues: with the
    /// same keys, restarting it would seal new records under nonces already used.
    public mutating func reset() {
        plaintext.removeAll()
        sealed.removeAll()
    }

    /// Seals `input` into records, appending them to `output`; `.flush` or `.finish` seals what's buffered.
    ///
    /// - Parameters:
    ///   - input: The next application data.
    ///   - output: Where to append records.
    ///   - flush: `.flush` or `.finish` to end the current record.
    /// - Returns: What was consumed and produced, and why it returned.
    /// - Throws: ``BytesError/invalidValue`` if a record can't be sealed (``alert`` is
    ///   ``TLSAlert/internalError``: the keys are at their limit and can't be updated).
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        var consumed = 0
        var produced = 0
        do throws(TLSAlert) {
            while true {
                produced &+= deliverSealed(into: &output)
                if !sealed.isEmpty {
                    return TransformProgress(consumed: consumed, produced: produced, status: .needsOutput)
                }
                let available = input.byteCount &- consumed
                if available > 0 {
                    let count = min(available, TLSRecord.maximumPlaintext &- padding)
                    let size = TLSRecord.size(content: count, padding: padding)
                    if sealingLanes > 1 && plaintext.isEmpty && count == TLSRecord.maximumPlaintext &- padding {
                        // Several full records at once, each sealed straight into its place in the output.
                        let batch = min(
                            available / count, output.freeCapacity / size,
                            Int(clamping: protection.recordLimit &- 1 &- min(protection.sequence, protection.recordLimit &- 1)))
                        if batch >= Self.minimumParallelRecords {
                            let bytes = input.extracting(consumed..<(consumed &+ batch &* count))
                            let (padding, lanes) = (padding, sealingLanes)
                            output.withFreeCapacity(byteCount: batch &* size) { span, written in
                                protection.sealInParallel(bytes, count: batch, padding: padding, lanes: lanes, into: &span)
                                written = batch &* size
                            }
                            consumed &+= batch &* count
                            produced &+= batch &* size
                            continue
                        }
                    }
                    if plaintext.isEmpty && (count == TLSRecord.maximumPlaintext &- padding || flush != .none)
                        && output.freeCapacity >= size && !protection.needsKeyUpdate {
                        // Straight into the output.
                        let bytes = input.extracting(consumed..<(consumed &+ count))
                        let padding = padding
                        try output.withFreeCapacity(byteCount: size) { (span, written) throws(TLSAlert) in
                            written = try protection.seal(bytes, type: .applicationData, padding: padding, into: &span)
                        }
                        consumed &+= count
                        produced &+= size
                        continue
                    }
                    let take = min(available, plaintext.freeCapacity &- padding)
                    plaintext.fill { $0.append(copying: input.extracting(consumed..<(consumed &+ take))) }
                    consumed &+= take
                    if plaintext.unreadByteCount &+ padding >= TLSRecord.maximumPlaintext {
                        try sealBuffered()
                    }
                    continue
                }
                if flush != .none && !plaintext.isEmpty {
                    try sealBuffered()
                    continue
                }
                return TransformProgress(consumed: consumed, produced: produced, status: flush == .finish ? .finished : .needsInput)
            }
        } catch {
            alert = error
            throw .invalidValue
        }
    }
}

// MARK: - Opener

/// A pipeline stage that opens TLS 1.3 records into their application data.
///
/// A record is a unit: it's opened only once all of it has arrived (its tag covers it all), straight into the
/// output: ciphertext copied in, tag checked, decrypted in place. Plaintext is never released before its record
/// is authenticated. Other content: a close_notify alert ends the stream (`.finished`); another alert throws; a
/// KeyUpdate updates the keys (the opener must have the traffic secret), and asks for one in return if the peer
/// requested it (``peerRequestedKeyUpdate``); NewSessionTicket messages are skipped. Any failure throws
/// ``BytesError/invalidValue`` or ``BytesError/mismatch`` with the alert to send (or the one received) in ``alert``.
public struct TLSRecordOpener: ~Copyable {
    var protection: TLSRecordProtection
    /// The alert for the last failure: to send, or ``receivedAlert`` when the peer sent it.
    public private(set) var alert: TLSAlert?
    /// Whether ``alert`` came from the peer.
    public private(set) var receivedAlert = false
    /// The peer sent a KeyUpdate with `update_requested`: the sealer should update its keys
    /// (``TLSRecordSealer/updateKeys(requestingPeerUpdate:)``). Cleared by reading it with
    /// ``takePeerKeyUpdateRequest()``.
    public private(set) var peerRequestedKeyUpdate = false
    /// Whether the peer sent close_notify.
    public private(set) var isClosed = false
    /// Whether to drop the unprotected change_cipher_spec records TLS 1.3 tolerates during a handshake.
    public var allowsChangeCipherSpec = false

    /// Creates an opener for one direction's keys. It can't follow a KeyUpdate: one throws.
    ///
    /// - Parameter keys: The traffic keys.
    public init(keys: TLSTrafficKeys) {
        protection = TLSRecordProtection(keys: keys)
    }

    /// Creates an opener for one direction's traffic secret, which follows the peer's KeyUpdates.
    ///
    /// - Parameter secret: The application traffic secret.
    public init(secret: TLSSecret) {
        protection = TLSRecordProtection(secret: secret)
    }

    /// The record protection: its suite and sequence number.
    public var recordProtection: TLSRecordProtection { protection }

    /// Reads and clears ``peerRequestedKeyUpdate``.
    public mutating func takePeerKeyUpdateRequest() -> Bool {
        defer { peerRequestedKeyUpdate = false }
        return peerRequestedKeyUpdate
    }

    /// Handles a handshake record's messages: KeyUpdate (which must end the record) and NewSessionTicket; any other
    /// handshake message after the handshake is unexpected.
    mutating func handleHandshake(_ messages: RawSpan) throws(TLSAlert) {
        var reader = BigEndianBytesReader(messages)
        while !reader.isAtEnd {
            // Each message whole: a type, a 3-byte length, the body. A message cut short is malformed.
            guard let type = try? reader.read(UInt8.self), var body = try? reader.read(sectionPrefixedBy: Byte3.self) else {
                throw .decodeError
            }
            switch type {
            case 4: // NewSessionTicket: for resumption, which this layer doesn't do.
                break
            case 24: // KeyUpdate: the last message of its record, with keys to update.
                guard let request = try? body.read(UInt8.self), body.isAtEnd, request <= 1, reader.isAtEnd else { throw .decodeError }
                guard protection.secret != nil else { throw .unexpectedMessage }
                protection.update()
                if request == 1 { peerRequestedKeyUpdate = true }
            default:
                throw .unexpectedMessage
            }
        }
    }
}

extension TLSRecordOpener: ResettableByteTransform {
    /// Failures are ``BytesError/invalidValue`` (``BytesError/mismatch`` for records that don't authenticate,
    /// ``BytesError/insufficientData`` for a stream cut short), with ``alert`` saying why.
    public typealias Failure = BytesError

    /// A whole record: header and up to 16,640 bytes of ciphertext and tag.
    public static var maximumUnitByteCount: Int { TLSRecord.headerSize &+ TLSRecord.maximumEncrypted }

    /// A record's body, opened straight into the output: up to 16,624 bytes.
    public static var minimumOutputCapacity: Int { TLSRecord.maximumEncrypted &- TLSRecord.tagSize }

    /// Nothing to discard: records are opened whole. The record sequence continues, in step with a sealer's
    /// (``TLSRecordSealer/reset()``); ``reset(sequence:)`` sets it.
    public mutating func reset() {}

    /// Expects the next record to have sequence number `sequence`: to open records again (a replay, in a
    /// benchmark or a test). TLS itself rejects replays by never going back.
    public mutating func reset(sequence: UInt64) {
        protection.reset(sequence: sequence)
    }

    /// Opens the whole records in `input` into `output`; a partial record stays unconsumed.
    ///
    /// - Parameters:
    ///   - input: The next bytes received.
    ///   - output: Where to append application data.
    ///   - flush: `.finish` when the input has ended.
    /// - Returns: What was consumed and produced; `.finished` after a close_notify, or at `.finish` with every
    ///   record opened.
    /// - Throws: ``BytesError/mismatch`` for a record that fails authentication; ``BytesError/invalidValue`` for one
    ///   that's malformed or unexpected, or an alert from the peer; ``BytesError/insufficientData`` at `.finish`
    ///   with a partial record left. ``alert`` says which.
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        var consumed = 0
        var produced = 0
        do throws(TLSAlert) {
            while !isClosed {
                let available = input.byteCount &- consumed
                guard available >= TLSRecord.headerSize else { break }
                let headerBytes = input.extracting(consumed..<(consumed &+ TLSRecord.headerSize))
                let type = headerBytes.load(fromByteOffset: 0, as: UInt8.self)
                // The legacy version is ignored, as RFC 8446 requires.
                let length = Int(UInt16(bigEndian: headerBytes.load(fromByteOffset: 3, as: UInt16.self)))
                guard length <= TLSRecord.maximumEncrypted else { throw TLSAlert.recordOverflow }
                guard available >= TLSRecord.headerSize &+ length else { break }
                let body = input.extracting((consumed &+ TLSRecord.headerSize)..<(consumed &+ TLSRecord.headerSize &+ length))
                switch type {
                case TLSContentType.applicationData.rawValue:
                    break
                case TLSContentType.changeCipherSpec.rawValue where allowsChangeCipherSpec && length == 1 && body.load(fromByteOffset: 0, as: UInt8.self) == 1:
                    consumed &+= TLSRecord.headerSize &+ length
                    continue
                default:
                    throw TLSAlert.unexpectedMessage
                }
                let encryptedLength = length &- TLSRecord.tagSize
                guard encryptedLength > 0 else { throw TLSAlert.badRecordMAC }
                guard output.freeCapacity >= encryptedLength else {
                    return TransformProgress(consumed: consumed, produced: produced, status: .needsOutput)
                }
                // Opened in the output's free capacity; only authenticated application data is kept.
                let (contentType, count) = try output.withFreeCapacity(byteCount: encryptedLength) { (span, written) throws(TLSAlert) in
                    let opened = try protection.open(header: headerBytes, body: body, into: &span)
                    written = opened.type == .applicationData ? opened.count : 0
                    if opened.type == .alert {
                        // An alert: exactly a level and a description.
                        guard opened.count == 2 else { throw TLSAlert.decodeError }
                        guard let received = TLSAlert(rawValue: span.bytes.load(fromByteOffset: 1, as: UInt8.self)) else { throw TLSAlert.illegalParameter }
                        receivedAlert = true
                        alert = received
                    } else if opened.type == .handshake {
                        guard opened.count > 0 else { throw TLSAlert.unexpectedMessage }
                        try handleHandshake(span.bytes.extracting(first: opened.count))
                    }
                    return opened
                }
                consumed &+= TLSRecord.headerSize &+ length
                produced &+= contentType == .applicationData ? count : 0
                if contentType == .alert, let received = alert {
                    if received == .closeNotify {
                        isClosed = true
                        return TransformProgress(consumed: consumed, produced: produced, status: .finished)
                    }
                    throw received
                }
            }
        } catch {
            // A received alert was recorded as it was read; anything else is ours to send.
            if !(receivedAlert && alert == error) {
                receivedAlert = false
                alert = error
            }
            throw error == .badRecordMAC ? .mismatch : .invalidValue
        }
        if isClosed { return TransformProgress(consumed: consumed, produced: produced, status: .finished) }
        guard flush == .finish else { return TransformProgress(consumed: consumed, produced: produced, status: .needsInput) }
        guard consumed == input.byteCount else {
            alert = .decodeError
            throw .insufficientData
        }
        return TransformProgress(consumed: consumed, produced: produced, status: .finished)
    }
}

extension TLSRecordProtection {
    /// Sets the next record's sequence number: to replay records in tests and benchmarks.
    mutating func reset(sequence: UInt64) { self.sequence = sequence }

    /// Seals `count` full records of application data (`2¹⁴ − padding` bytes each) from `input` into `output` on up
    /// to `lanes` cores at once, with the sequence numbers they'd have one after another.
    ///
    /// Records are independent once their sequence numbers are fixed, and full ones have a known size, so each lane
    /// seals its records straight into their places in the output: no copy, no reordering.
    ///
    /// - Precondition: `count` records fit before the key's limit, `input` holds them, and `output` has room.
    mutating func sealInParallel(_ input: RawSpan, count: Int, padding: Int, lanes: Int, into output: inout MutableRawSpan) {
        let content = TLSRecord.maximumPlaintext &- padding
        let size = TLSRecord.size(content: content, padding: padding)
        precondition(input.byteCount >= count &* content && output.byteCount >= count &* size, "Not enough input or room")
        precondition(sequence &+ UInt64(count) < recordLimit, "The batch would reach the key's record limit")
        let template = self
        // Unsafe: the input and output lent to the lanes as pointers. Safe: each lane reads and writes only its own
        // records' ranges (disjoint, within the bounds checked above), and `concurrentPerform` returns once every lane
        // is done, inside the closures that lend them.
        unsafe input.withLentBytes { source in
            unsafe output.withLentBytes { target in
                DispatchQueue.concurrentPerform(iterations: min(lanes, count)) { lane in
                    let (input, output) = unsafe (source.buffer.baseAddress!, target.buffer.baseAddress!)
                    var record = lane
                    while record < count {
                        var protection = template
                        protection.sequence &+= UInt64(record)
                        let plaintext = unsafe RawSpan(_unsafeStart: input + record &* content, byteCount: content)
                        var destination = unsafe MutableRawSpan(_unsafeStart: output + record &* size, byteCount: size)
                        // Can't throw: the sequence stays below the limit (checked above).
                        _ = try! protection.seal(plaintext, type: .applicationData, padding: padding, into: &destination)
                        record &+= lanes
                    }
                }
            }
        }
        sequence &+= UInt64(count)
    }
}
