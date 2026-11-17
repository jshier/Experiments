public import Bytes
internal import CryptoKit
internal import Foundation

/// One direction's TLS 1.3 traffic keys (RFC 8446, 7.3): a 32-byte AEAD key and a 12-byte IV.
public struct TLSTrafficKeys: Sendable {
    /// The AEAD key.
    public var key: InlineArray<32, UInt8>
    /// The IV the record nonces start from.
    public var iv: InlineArray<12, UInt8>

    /// The keys for a traffic secret: `HKDF-Expand-Label(secret, "key", "", 32)` and `(secret, "iv", "", 12)`.
    public init(trafficSecret secret: RawSpan) {
        let prk = SymmetricKey(data: Self.data(secret))
        key = Self.inline(TLSKeySchedule.expandLabel(prk, label: "key", context: Data(), length: 32))
        iv = Self.inline(TLSKeySchedule.expandLabel(prk, label: "iv", context: Data(), length: 12))
    }

    static func data(_ span: RawSpan) -> Data {
        var data = Data(count: span.byteCount)
        for index in 0..<span.byteCount {
            data[index] = span.load(fromByteOffset: index, as: UInt8.self)
        }
        return data
    }

    static func inline<let count: Int>(_ data: Data) -> InlineArray<count, UInt8> {
        var array = InlineArray<count, UInt8>(repeating: 0)
        for index in 0..<count {
            array[index] = data[data.startIndex + index]
        }
        return array
    }
}

/// TLS 1.3's key schedule (RFC 8446, 7.1) from an (EC)DHE shared secret, with CryptoKit's HKDF-SHA256: the
/// application traffic secrets an X25519 exchange leads to, without the handshake's transcript (each
/// `Derive-Secret` hashes the empty transcript). The record protection that follows is TLS 1.3's; the
/// handshake that would authenticate the peers isn't part of this experiment.
public enum TLSKeySchedule {
    /// The client's and server's application traffic keys for an X25519 shared secret.
    public static func applicationKeys(sharedSecret: RawSpan) -> (client: TLSTrafficKeys, server: TLSTrafficKeys) {
        let zeros = Data(repeating: 0, count: 32)
        let early = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: zeros), salt: Data())
        let derived1 = deriveSecret(SymmetricKey(data: Data(early)), label: "derived")
        let handshake = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: TLSTrafficKeys.data(sharedSecret)), salt: derived1)
        let derived2 = deriveSecret(SymmetricKey(data: Data(handshake)), label: "derived")
        let master = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: zeros), salt: derived2)
        let masterKey = SymmetricKey(data: Data(master))
        let client = [UInt8](deriveSecret(masterKey, label: "c ap traffic"))
        let server = [UInt8](deriveSecret(masterKey, label: "s ap traffic"))
        return (TLSTrafficKeys(trafficSecret: client.span.bytes), TLSTrafficKeys(trafficSecret: server.span.bytes))
    }

    /// `Derive-Secret(secret, label, "")`: `HKDF-Expand-Label` with the empty transcript's SHA-256.
    static func deriveSecret(_ secret: SymmetricKey, label: String) -> Data {
        expandLabel(secret, label: label, context: Data(SHA256.hash(data: Data())), length: 32)
    }

    /// `HKDF-Expand-Label(secret, label, context, length)`: HKDF-Expand with the `HkdfLabel` structure.
    static func expandLabel(_ secret: SymmetricKey, label: String, context: Data, length: Int) -> Data {
        var info = Data()
        info.append(UInt8(length >> 8))
        info.append(UInt8(length & 0xFF))
        let fullLabel = Array("tls13 \(label)".utf8)
        info.append(UInt8(fullLabel.count))
        info.append(contentsOf: fullLabel)
        info.append(UInt8(context.count))
        info.append(context)
        let key = HKDF<SHA256>.expand(pseudoRandomKey: secret, info: info, outputByteCount: length)
        // Unsafe: the key's bytes, copied out. Safe: `Data` copies them within the closure.
        return unsafe key.withUnsafeBytes { unsafe Data($0) }
    }
}

/// TLS 1.3 record framing (RFC 8446, 5.2), shared by the sealer and opener.
enum TLSRecord {
    /// The header's size: type (23, application data), legacy version 0x0303, length.
    static var headerSize: Int { 5 }
    /// The Poly1305 tag's size.
    static var tagSize: Int { 16 }
    /// The most plaintext per record.
    static var maximumPlaintext: Int { 1 << 14 }
    /// The most a record's encrypted part may be: plaintext, content type, padding, tag.
    static var maximumEncrypted: Int { maximumPlaintext &+ 256 }
    static var applicationData: UInt8 { 23 }

    /// A record's size for `count` bytes of plaintext: header, plaintext, inner content type, tag.
    static func size(plaintext count: Int) -> Int { headerSize &+ count &+ 1 &+ tagSize }

    /// The per-record nonce: the IV XOR the 64-bit sequence number, big-endian, in its last 8 bytes.
    static func nonce(_ iv: InlineArray<12, UInt8>, sequence: UInt64) -> InlineArray<12, UInt8> {
        var nonce = iv
        for index in 0..<8 {
            nonce[4 &+ index] ^= UInt8(truncatingIfNeeded: sequence &>> UInt64(56 &- 8 &* index))
        }
        return nonce
    }
}

/// A pipeline stage that seals bytes into TLS 1.3 application-data records with ChaCha20-Poly1305.
///
/// Records hold up to 16 KB. A flush ends the current record, so each flushed message is one record (or more,
/// if longer than 16 KB). With nothing buffered and room in the output (and a full record's input or a
/// flush), a record is sealed straight into the output: plaintext copied in, encrypted in place, tag
/// appended. Otherwise the plaintext is buffered first.
public struct TLSRecordSealer: ~Copyable {
    let aead: ChaCha20Poly1305
    let iv: InlineArray<12, UInt8>
    var sequence: UInt64 = 0
    /// Plaintext waiting to fill a record.
    var plaintext: UniqueArray<UInt8>
    var fill = 0
    /// A sealed record waiting for room in the output.
    var sealed: UniqueArray<UInt8>
    var sealedStart = 0
    var sealedEnd = 0

    /// Creates a sealer for one direction's keys.
    public init(keys: TLSTrafficKeys) {
        aead = ChaCha20Poly1305(key: keys.key.span.bytes)
        iv = keys.iv
        plaintext = UniqueArray(repeating: 0, count: TLSRecord.maximumPlaintext)
        sealed = UniqueArray(repeating: 0, count: TLSRecord.size(plaintext: TLSRecord.maximumPlaintext))
    }

    /// Seals `bytes` as one record into `destination`, which must have room, and advances `sequence`.
    ///
    /// Static, taking the state it needs: sealing from this struct's own buffers borrows them while the
    /// sequence number changes.
    ///
    /// - Returns: The record's size.
    static func seal(
        _ bytes: RawSpan, into destination: inout MutableRawSpan, aead: ChaCha20Poly1305, iv: InlineArray<12, UInt8>,
        sequence: inout UInt64
    ) -> Int {
        let count = bytes.byteCount
        let encrypted = count &+ 1 &+ TLSRecord.tagSize
        let total = TLSRecord.headerSize &+ encrypted
        var header = InlineArray<5, UInt8>(repeating: 0)
        header[0] = TLSRecord.applicationData
        header[1] = 0x03
        header[2] = 0x03
        header[3] = UInt8(truncatingIfNeeded: encrypted &>> 8)
        header[4] = UInt8(truncatingIfNeeded: encrypted)
        do {
            var writer = AlignedBytesWriter(destination._mutatingExtracting(0..<total))
            // Can't throw: `destination` has room for the record.
            try! writer.write(header.span.bytes)
            try! writer.write(bytes)
            try! writer.write(Byte(truncatingIfNeeded: TLSRecord.applicationData)) // The inner content type.
        }
        let nonce = TLSRecord.nonce(iv, sequence: sequence)
        sequence &+= 1
        let tag: InlineArray<16, UInt8>
        do {
            var body = destination._mutatingExtracting(TLSRecord.headerSize..<(TLSRecord.headerSize &+ count &+ 1))
            tag = aead.seal(&body, nonce: nonce.span.bytes, authenticating: header.span.bytes)
        }
        var tagWriter = try! AlignedBytesWriter(&destination, atByteOffset: TLSRecord.headerSize &+ count &+ 1)
        try! tagWriter.write(tag.span.bytes)
        return total
    }

    /// Seals the buffered plaintext into ``sealed``.
    mutating func sealBuffered() {
        var target = sealed.mutableSpan
        var raw = MutableRawSpan(mutating: &target)
        sealedEnd = Self.seal(plaintext.span.bytes.extracting(0..<fill), into: &raw, aead: aead, iv: iv, sequence: &sequence)
        sealedStart = 0
        fill = 0
    }

    private mutating func deliverSealed(into output: inout OutputRawSpan) -> Int {
        let count = min(sealedEnd &- sealedStart, output.freeCapacity)
        guard count > 0 else { return 0 }
        output.append(copying: sealed.span.bytes.extracting(sealedStart..<(sealedStart &+ count)))
        sealedStart &+= count
        if sealedStart == sealedEnd {
            sealedStart = 0
            sealedEnd = 0
        }
        return count
    }
}

extension TLSRecordSealer: ResettableByteTransform {
    public typealias Failure = BytesError

    /// Discards buffered plaintext and sealed bytes not yet delivered. The record sequence continues: with the
    /// same keys, restarting it would seal new records under nonces already used.
    public mutating func reset() {
        fill = 0
        sealedStart = 0
        sealedEnd = 0
    }

    /// Seals `input` into records, appending them to `output`; `.flush` or `.finish` seals what's buffered.
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        var consumed = 0
        var produced = 0
        while true {
            produced &+= deliverSealed(into: &output)
            if sealedEnd > 0 {
                return TransformProgress(consumed: consumed, produced: produced, status: .needsOutput)
            }
            let available = input.byteCount &- consumed
            if available > 0 {
                let count = min(available, TLSRecord.maximumPlaintext)
                if fill == 0 && (count == TLSRecord.maximumPlaintext || flush != .none)
                    && output.freeCapacity >= TLSRecord.size(plaintext: count) {
                    // Straight into the output.
                    let bytes = input.extracting(consumed..<(consumed &+ count))
                    let size = TLSRecord.size(plaintext: count)
                    output.withFreeCapacity(byteCount: size) { span, written in
                        written = Self.seal(bytes, into: &span, aead: aead, iv: iv, sequence: &sequence)
                    }
                    consumed &+= count
                    produced &+= size
                    continue
                }
                let take = min(available, TLSRecord.maximumPlaintext &- fill)
                var target = plaintext.mutableSpan
                target.copyBytes(from: input.extracting(consumed..<(consumed &+ take)), toByteOffset: fill)
                fill &+= take
                consumed &+= take
                if fill == TLSRecord.maximumPlaintext {
                    sealBuffered()
                }
                continue
            }
            if flush != .none && fill > 0 {
                sealBuffered()
                continue
            }
            return TransformProgress(consumed: consumed, produced: produced, status: flush == .finish ? .finished : .needsInput)
        }
    }
}

/// A pipeline stage that opens TLS 1.3 application-data records sealed with ChaCha20-Poly1305.
///
/// A record is a unit: it's opened only once all of it has arrived (its tag covers it all), straight into the
/// output: ciphertext copied in, tag checked against the input, decrypted in place. Plaintext is never
/// released before its record is authenticated.
public struct TLSRecordOpener: ~Copyable {
    let aead: ChaCha20Poly1305
    let iv: InlineArray<12, UInt8>
    var sequence: UInt64 = 0

    /// Creates an opener for one direction's keys.
    public init(keys: TLSTrafficKeys) {
        aead = ChaCha20Poly1305(key: keys.key.span.bytes)
        iv = keys.iv
    }
}

extension TLSRecordOpener: ResettableByteTransform {
    public typealias Failure = BytesError

    /// Nothing to discard: records are opened whole. The record sequence continues, in step with a sealer's
    /// (``TLSRecordSealer/reset()``); ``reset(sequence:)`` sets it.
    public mutating func reset() {}

    /// Expects the next record to have sequence number `sequence`: to open records again (a replay, in a
    /// benchmark or a test). TLS itself rejects replays by never going back.
    public mutating func reset(sequence: UInt64) {
        self.sequence = sequence
    }

    /// Opens the whole records in `input` into `output`; a partial record stays unconsumed.
    ///
    /// - Throws: ``BytesError/mismatch`` for a record that fails authentication; ``BytesError/invalidValue``
    ///   for one that isn't application data or is too long; ``BytesError/insufficientData`` at `.finish` with
    ///   a partial record left.
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        var consumed = 0
        var produced = 0
        while true {
            let available = input.byteCount &- consumed
            guard available >= TLSRecord.headerSize else { break }
            var header = AlignedBytesReader(input.extracting(consumed..<(consumed &+ TLSRecord.headerSize)))
            let type = try header.read(Byte.self).rawValue
            let version = try header.read(Byte2.self, .bigEndian)
            let length = Int(try header.read(Byte2.self, .bigEndian))
            guard type == TLSRecord.applicationData, version == 0x0303,
                  length > TLSRecord.tagSize, length <= TLSRecord.maximumEncrypted else { throw .invalidValue }
            guard available >= TLSRecord.headerSize &+ length else { break }
            let bodyLength = length &- TLSRecord.tagSize
            guard output.freeCapacity >= bodyLength else {
                return TransformProgress(consumed: consumed, produced: produced, status: .needsOutput)
            }
            let headerBytes = input.extracting(consumed..<(consumed &+ TLSRecord.headerSize))
            let body = input.extracting((consumed &+ TLSRecord.headerSize)..<(consumed &+ TLSRecord.headerSize &+ bodyLength))
            let tag = input.extracting((consumed &+ TLSRecord.headerSize &+ bodyLength)..<(consumed &+ TLSRecord.headerSize &+ length))
            let nonce = TLSRecord.nonce(iv, sequence: sequence)
            // Decrypted in the output's free capacity; only the authenticated plaintext is kept.
            let aead = aead
            let plaintextLength = try output.withFreeCapacity(byteCount: bodyLength) { span, written throws(BytesError) -> Int in
                span.copyBytes(from: body, toByteOffset: 0)
                try aead.open(&span, nonce: nonce.span.bytes, authenticating: headerBytes, tag: tag)
                // The inner plaintext ends with its content type, then zero padding.
                var end = bodyLength
                while end > 0 && span.bytes.load(fromByteOffset: end &- 1, as: UInt8.self) == 0 { end &-= 1 }
                guard end > 0, span.bytes.load(fromByteOffset: end &- 1, as: UInt8.self) == TLSRecord.applicationData else {
                    throw .invalidValue
                }
                written = end &- 1
                return written
            }
            sequence &+= 1
            consumed &+= TLSRecord.headerSize &+ length
            produced &+= plaintextLength
        }
        if flush == .finish && consumed < input.byteCount { throw .insufficientData }
        return TransformProgress(consumed: consumed, produced: produced, status: .needsInput)
    }
}
