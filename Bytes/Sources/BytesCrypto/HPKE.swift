public import Bytes

// HPKE (RFC 9180), base mode: DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, and AES-128-GCM, AES-256-GCM, or
// ChaCha20-Poly1305. Apple's firmware archives (`.dmg.aea`) wrap their keys this way: the "com.apple.wkms.fcs-response"
// entry's `enc-request` is the encapsulated key and `wrapped-key` the sealed archive key (AES-256-GCM, empty info
// and associated data), opened with a P-256 private key.
//
// Nothing allocates after the private key is parsed: the labeled HKDF inputs are fed to HMAC in pieces or built in
// fixed buffers, and the AEADs work in place. Decapsulation is constant-time in the private key (ECDH).

/// Hybrid public-key encryption (RFC 9180) in base mode, with DHKEM(P-256, HKDF-SHA256) and HKDF-SHA256.
///
/// ```swift
/// // A recipient: its private key, the sender's encapsulated key, and the context's info.
/// var recipient = try HPKE.Recipient(privateKey: key, aead: .aes256GCM, info: info, encapsulatedKey: enc)
/// let plaintext = try recipient.open(ciphertextAndTag, authenticating: aad)
///
/// // A sender, to a recipient's public key.
/// var sender = HPKE.Sender(recipientKey: key.publicKey, aead: .aes256GCM, info: info)
/// let sealed = sender.seal(plaintext, authenticating: aad)   // ciphertext ‖ tag; send sender.encapsulatedKey too
/// ```
///
/// Each context seals or opens a sequence of messages, each with the next nonce: open them in the order they were
/// sealed.
public enum HPKE {
    /// The AEAD protecting messages (RFC 9180, 7.3).
    public enum AEAD: UInt16, Sendable, CaseIterable {
        /// AES-128-GCM.
        case aes128GCM = 0x0001
        /// AES-256-GCM.
        case aes256GCM = 0x0002
        /// ChaCha20-Poly1305.
        case chaCha20Poly1305 = 0x0003

        /// Nk.
        var keyByteCount: Int { self == .aes128GCM ? 16 : 32 }
    }

    /// DHKEM(P-256, HKDF-SHA256).
    static var kemIdentifier: UInt16 { 0x0010 }
    /// HKDF-SHA256.
    static var kdfIdentifier: UInt16 { 0x0001 }

    /// An encryption context's AEAD and nonces (RFC 9180, 5.2), shared by senders and recipients.
    package struct Context: Sendable {
        enum Cipher: Sendable {
            case aesGCM(AESGCM)
            case chaCha20Poly1305(ChaCha20Poly1305)
        }

        let cipher: Cipher
        package let baseNonce: InlineArray<12, UInt8>
        package let exporterSecret: InlineArray<32, UInt8>
        var sequence: UInt64 = 0

        /// KeySchedule (RFC 9180, 5.1) in base mode, from the KEM's shared secret.
        init(aead: AEAD, sharedSecret: RawSpan, info: RawSpan) {
            let suite = Suite.hpke(aead)
            let empty = InlineArray<0, UInt8>(repeating: 0)
            // key_schedule_context = mode ‖ psk_id_hash ‖ info_hash, mode 0 (base).
            var context = InlineArray<65, UInt8>(repeating: 0)
            do {
                var span = context.mutableSpan
                var bytes = MutableRawSpan(mutating: &span)
                var digest = bytes._mutatingExtracting(1..<33)
                suite.labeledExtract(salt: empty.span.bytes, label: "psk_id_hash", ikm: empty.span.bytes, into: &digest)
                var infoDigest = bytes._mutatingExtracting(33..<65)
                suite.labeledExtract(salt: empty.span.bytes, label: "info_hash", ikm: info, into: &infoDigest)
            }
            var secret = InlineArray<32, UInt8>(repeating: 0)
            do {
                var span = secret.mutableSpan
                var bytes = MutableRawSpan(mutating: &span)
                suite.labeledExtract(salt: sharedSecret, label: "secret", ikm: empty.span.bytes, into: &bytes)
            }
            var key = InlineArray<32, UInt8>(repeating: 0)
            do {
                var span = key.mutableSpan
                var bytes = MutableRawSpan(mutating: &span)
                var output = bytes._mutatingExtracting(0..<aead.keyByteCount)
                suite.labeledExpand(prk: secret.span.bytes, label: "key", info: context.span.bytes, into: &output)
            }
            var nonce = InlineArray<12, UInt8>(repeating: 0)
            do {
                var span = nonce.mutableSpan
                var bytes = MutableRawSpan(mutating: &span)
                suite.labeledExpand(prk: secret.span.bytes, label: "base_nonce", info: context.span.bytes, into: &bytes)
            }
            var exporter = InlineArray<32, UInt8>(repeating: 0)
            do {
                var span = exporter.mutableSpan
                var bytes = MutableRawSpan(mutating: &span)
                suite.labeledExpand(prk: secret.span.bytes, label: "exp", info: context.span.bytes, into: &bytes)
            }
            let keyBytes = key.span.bytes.extracting(first: aead.keyByteCount)
            cipher = aead == .chaCha20Poly1305 ? .chaCha20Poly1305(ChaCha20Poly1305(key: keyBytes)) : .aesGCM(AESGCM(key: keyBytes))
            baseNonce = nonce
            exporterSecret = exporter
        }

        /// The current message's nonce: base_nonce XOR the sequence number, big-endian in its last 8 bytes. The
        /// sequence advances only once the message is sealed or opened (RFC 9180, 5.2: a failed open leaves it).
        func currentNonce() throws(BytesError) -> InlineArray<12, UInt8> {
            // RFC 9180 stops at 2⁹⁶ − 1 messages; a 64-bit count stops sooner, and never wraps.
            guard sequence != .max else { throw .invalidValue }
            var nonce = baseNonce
            for index in 0..<8 {
                nonce[4 &+ index] ^= UInt8(truncatingIfNeeded: sequence &>> UInt64(56 &- 8 &* index))
            }
            return nonce
        }

        mutating func seal(_ message: inout MutableRawSpan, authenticating aad: RawSpan) throws(BytesError) -> InlineArray<16, UInt8> {
            let nonce = try currentNonce()
            let tag = switch cipher {
            case let .aesGCM(aead): aead.seal(&message, nonce: nonce.span.bytes, authenticating: aad)
            case let .chaCha20Poly1305(aead): aead.seal(&message, nonce: nonce.span.bytes, authenticating: aad)
            }
            sequence &+= 1
            return tag
        }

        mutating func open(_ message: inout MutableRawSpan, authenticating aad: RawSpan, tag: RawSpan) throws(BytesError) {
            let nonce = try currentNonce()
            switch cipher {
            case let .aesGCM(aead): try aead.open(&message, nonce: nonce.span.bytes, authenticating: aad, tag: tag)
            case let .chaCha20Poly1305(aead): try aead.open(&message, nonce: nonce.span.bytes, authenticating: aad, tag: tag)
            }
            // Only after the tag matched: a forged message doesn't desynchronize the ones after it.
            sequence &+= 1
        }

        /// Context.Export (RFC 9180, 5.3).
        ///
        /// - Throws: ``BytesError/invalidValue`` for an output longer than 255 × 32 bytes (HKDF-SHA256's limit).
        func exportSecret(context: RawSpan, into output: inout MutableRawSpan, aead: AEAD) throws(BytesError) {
            guard output.byteCount <= 255 &* 32 else { throw .invalidValue }
            Suite.hpke(aead).labeledExpand(prk: exporterSecret.span.bytes, label: "sec", info: context, into: &output)
        }
    }

    /// A suite_id, and the labeled HKDF over it (RFC 9180, 4).
    struct Suite {
        /// "KEM" ‖ kem_id, or "HPKE" ‖ kem_id ‖ kdf_id ‖ aead_id.
        let identifier: InlineArray<10, UInt8>
        let identifierByteCount: Int

        static var kem: Suite {
            let kem = HPKE.kemIdentifier
            return Suite(identifier: [0x4B, 0x45, 0x4D, UInt8(kem >> 8), UInt8(truncatingIfNeeded: kem), 0, 0, 0, 0, 0],
                         identifierByteCount: 5)
        }

        static func hpke(_ aead: AEAD) -> Suite {
            let (kem, kdf, id) = (HPKE.kemIdentifier, HPKE.kdfIdentifier, aead.rawValue)
            return Suite(identifier: [0x48, 0x50, 0x4B, 0x45, UInt8(kem >> 8), UInt8(truncatingIfNeeded: kem),
                                      UInt8(kdf >> 8), UInt8(truncatingIfNeeded: kdf), UInt8(id >> 8), UInt8(truncatingIfNeeded: id)],
                         identifierByteCount: 10)
        }

        /// LabeledExtract(salt, label, ikm) = Extract(salt, "HPKE-v1" ‖ suite_id ‖ label ‖ ikm): 32 bytes.
        func labeledExtract(salt: RawSpan, label: StaticString, ikm: RawSpan, into output: inout MutableRawSpan) {
            var mac = HMAC<SHA256>(key: salt)
            Self.withBytes("HPKE-v1") { mac.update($0) }
            mac.update(identifier.span.bytes.extracting(first: identifierByteCount))
            Self.withBytes(label) { mac.update($0) }
            mac.update(ikm)
            mac.finalize(into: &output)
        }

        /// LabeledExpand(prk, label, info, L) = Expand(prk, I2OSP(L, 2) ‖ "HPKE-v1" ‖ suite_id ‖ label ‖ info, L), L
        /// being `output`'s length.
        ///
        /// HKDF-Expand written out (T(i) = HMAC(prk, T(i − 1) ‖ info ‖ i)), so the labeled info goes into the HMAC in
        /// pieces: any context length, nothing assembled in a buffer.
        ///
        /// - Precondition: `output` is at most 255 × 32 bytes (callers check what callers of theirs pass).
        func labeledExpand(prk: RawSpan, label: StaticString, info: RawSpan, into output: inout MutableRawSpan) {
            precondition(output.byteCount <= 255 &* 32, "HKDF-SHA256 expands to at most 8,160 bytes")
            let length: InlineArray<2, UInt8> = [UInt8(output.byteCount >> 8), UInt8(truncatingIfNeeded: output.byteCount)]
            var previous = InlineArray<32, UInt8>(repeating: 0)
            var previousCount = 0
            var offset = 0
            var counter: InlineArray<1, UInt8> = [1]
            while offset < output.byteCount {
                var mac = HMAC<SHA256>(key: prk)
                mac.update(previous.span.bytes.extracting(first: previousCount))
                mac.update(length.span.bytes)
                Self.withBytes("HPKE-v1") { mac.update($0) }
                mac.update(identifier.span.bytes.extracting(first: identifierByteCount))
                Self.withBytes(label) { mac.update($0) }
                mac.update(info)
                mac.update(counter.span.bytes)
                var previousSpan = previous.mutableSpan
                var block = MutableRawSpan(mutating: &previousSpan)
                mac.finalize(into: &block)
                previousCount = 32
                let take = min(32, output.byteCount &- offset)
                output.copyBytes(from: previous.span.bytes.extracting(first: take), toByteOffset: offset)
                offset &+= take
                counter[0] &+= 1
            }
        }

        /// Calls `body` with a static string's UTF-8 bytes.
        static func withBytes(_ string: StaticString, _ body: (RawSpan) -> Void) {
            // Unsafe: the string's buffer as a span. Safe: the buffer is the string's own static storage, and the
            // span doesn't outlive the closure.
            string.withUTF8Buffer { buffer in body(unsafe RawSpan(_unsafeElements: buffer)) }
        }
    }

    /// DHKEM's ExtractAndExpand (RFC 9180, 4.1): the KEM's shared secret from the Diffie–Hellman value and
    /// kem_context = enc ‖ pkRm.
    static func kemSharedSecret(dh: RawSpan, encapsulatedKey: RawSpan, recipientKey: P256.PublicKey) -> InlineArray<32, UInt8> {
        var kemContext = InlineArray<130, UInt8>(repeating: 0)
        do {
            var span = kemContext.mutableSpan
            var bytes = MutableRawSpan(mutating: &span)
            bytes.copyBytes(from: encapsulatedKey, toByteOffset: 0)
            var point = bytes._mutatingExtracting(65..<130)
            recipientKey.core.point.writeX963(to: &point)
        }
        var prk = InlineArray<32, UInt8>(repeating: 0)
        do {
            var span = prk.mutableSpan
            var bytes = MutableRawSpan(mutating: &span)
            Suite.kem.labeledExtract(salt: InlineArray<0, UInt8>(repeating: 0).span.bytes, label: "eae_prk", ikm: dh, into: &bytes)
        }
        var secret = InlineArray<32, UInt8>(repeating: 0)
        do {
            var span = secret.mutableSpan
            var bytes = MutableRawSpan(mutating: &span)
            Suite.kem.labeledExpand(prk: prk.span.bytes, label: "shared_secret", info: kemContext.span.bytes, into: &bytes)
        }
        return secret
    }

    /// DHKEM's DeriveKeyPair (RFC 9180, 7.1.3): a private key from input keying material, deterministically.
    ///
    /// - Parameter ikm: At least 32 bytes of keying material.
    /// - Returns: The key.
    /// - Throws: ``BytesError/invalidValue`` in the (2⁻²⁵⁶ⁱˢʰ) case that 256 candidates all fail.
    public static func deriveKey(from ikm: RawSpan) throws(BytesError) -> P256.PrivateKey {
        var prk = InlineArray<32, UInt8>(repeating: 0)
        do {
            var span = prk.mutableSpan
            var bytes = MutableRawSpan(mutating: &span)
            Suite.kem.labeledExtract(salt: InlineArray<0, UInt8>(repeating: 0).span.bytes, label: "dkp_prk", ikm: ikm, into: &bytes)
        }
        for counter in 0..<256 {
            var candidate = InlineArray<32, UInt8>(repeating: 0)
            do {
                var span = candidate.mutableSpan
                var bytes = MutableRawSpan(mutating: &span)
                let info = InlineArray<1, UInt8>(repeating: UInt8(counter))
                Suite.kem.labeledExpand(prk: prk.span.bytes, label: "candidate", info: info.span.bytes, into: &bytes)
            }
            // The bitmask for P-256 is 0xFF: all 32 bytes are used, and candidates of 0 or n and more are retried.
            if let key = try? P256.PrivateKey(rawRepresentation: candidate.span.bytes) { return key }
        }
        throw .invalidValue
    }

    /// The receiving side of an HPKE context: decapsulates the sender's key, then opens messages. Not copyable: two
    /// copies would open with the same sequence of nonces.
    public struct Recipient: ~Copyable, Sendable {
        var context: Context
        /// The AEAD the context uses.
        public let aead: AEAD

        /// Sets up a base-mode context (SetupBaseR): decapsulates `encapsulatedKey` with `privateKey`. Allocates
        /// nothing.
        ///
        /// - Parameters:
        ///   - privateKey: The recipient's key.
        ///   - aead: The AEAD the sender chose.
        ///   - info: The application's context string (empty for Apple's archives).
        ///   - encapsulatedKey: The sender's ephemeral public key, enc: 65 bytes, uncompressed.
        /// - Throws: ``BytesError/invalidValue`` if `encapsulatedKey` isn't a valid uncompressed P-256 point.
        public init(privateKey: P256.PrivateKey, aead: AEAD, info: RawSpan, encapsulatedKey: RawSpan) throws(BytesError) {
            let ephemeral = try P256.PublicKey(x963Representation: encapsulatedKey)
            let dh = privateKey.sharedSecret(with: ephemeral)
            let secret = kemSharedSecret(dh: dh.span.bytes, encapsulatedKey: encapsulatedKey, recipientKey: privateKey.publicKey)
            context = Context(aead: aead, sharedSecret: secret.span.bytes, info: info)
            self.aead = aead
        }

        /// Checks `tag` and decrypts the next message in place.
        ///
        /// - Parameters:
        ///   - message: The ciphertext, replaced by the plaintext if the tag matches; untouched otherwise.
        ///   - aad: The associated data it was sealed with.
        ///   - tag: The 16-byte tag.
        /// - Throws: ``BytesError/mismatch`` if the tag doesn't match (a wrong key, info, order, or an altered message).
        public mutating func open(_ message: inout MutableRawSpan, authenticating aad: RawSpan, tag: RawSpan) throws(BytesError) {
            try context.open(&message, authenticating: aad, tag: tag)
        }

        /// Opens the next message, sealed as ciphertext ‖ tag (HPKE's usual form).
        ///
        /// - Parameters:
        ///   - sealed: The ciphertext followed by its 16-byte tag.
        ///   - aad: The associated data it was sealed with.
        /// - Returns: The plaintext.
        /// - Throws: ``BytesError/insufficientData`` if `sealed` is shorter than a tag; ``BytesError/mismatch`` if the
        ///   tag doesn't match.
        public mutating func open(_ sealed: RawSpan, authenticating aad: RawSpan) throws(BytesError) -> [UInt8] {
            guard sealed.byteCount >= 16 else { throw .insufficientData }
            let count = sealed.byteCount &- 16
            var plaintext = [UInt8](repeating: 0, count: count)
            var span = plaintext.mutableSpan
            var bytes = MutableRawSpan(mutating: &span)
            bytes.copyBytes(from: sealed.extracting(first: count), toByteOffset: 0)
            try context.open(&bytes, authenticating: aad, tag: sealed.extracting(droppingFirst: count))
            return plaintext
        }

        /// Derives a secret from the context (Context.Export, RFC 9180, 5.3).
        ///
        /// - Parameters:
        ///   - exporterContext: The exporter context.
        ///   - output: Where the secret goes; its length is the secret's.
        /// - Throws: ``BytesError/invalidValue`` if `output` is longer than 255 × 32 bytes (RFC 9180's limit for
        ///   HKDF-SHA256).
        public func exportSecret(context exporterContext: RawSpan, into output: inout MutableRawSpan) throws(BytesError) {
            try context.exportSecret(context: exporterContext, into: &output, aead: aead)
        }
    }

    /// The sending side of an HPKE context: encapsulates a fresh key to the recipient, then seals messages. Not copyable:
    /// two copies would seal different messages with the same key and nonce, which breaks AES-GCM and ChaCha20-Poly1305.
    public struct Sender: ~Copyable, Sendable {
        package var context: Context
        /// The AEAD the context uses.
        public let aead: AEAD
        /// enc: the ephemeral public key (65 bytes, uncompressed) the recipient needs to open the messages.
        public let encapsulatedKey: [UInt8]

        /// Sets up a base-mode context (SetupBaseS) with a random ephemeral key.
        ///
        /// - Parameters:
        ///   - recipientKey: The recipient's public key.
        ///   - aead: The AEAD to use.
        ///   - info: The application's context string.
        public init(recipientKey: P256.PublicKey, aead: AEAD, info: RawSpan) {
            self.init(recipientKey: recipientKey, aead: aead, info: info, ephemeralKey: P256.PrivateKey())
        }

        /// SetupBaseS with a chosen ephemeral key: for known-answer tests only (an ephemeral key must never be reused).
        package init(recipientKey: P256.PublicKey, aead: AEAD, info: RawSpan, ephemeralKey: P256.PrivateKey) {
            let enc = ephemeralKey.publicKey.x963Representation
            let dh = ephemeralKey.sharedSecret(with: recipientKey)
            let secret = kemSharedSecret(dh: dh.span.bytes, encapsulatedKey: enc.span.bytes, recipientKey: recipientKey)
            context = Context(aead: aead, sharedSecret: secret.span.bytes, info: info)
            self.aead = aead
            encapsulatedKey = enc
        }

        /// Encrypts the next message in place and returns its tag.
        ///
        /// - Parameters:
        ///   - message: The plaintext, replaced by the ciphertext.
        ///   - aad: Associated data to authenticate.
        /// - Returns: The 16-byte tag.
        /// - Precondition: Fewer than 2⁶⁴ − 1 messages have been sealed.
        public mutating func seal(_ message: inout MutableRawSpan, authenticating aad: RawSpan) -> InlineArray<16, UInt8> {
            do throws(BytesError) {
                return try context.seal(&message, authenticating: aad)
            } catch {
                preconditionFailure("HPKE context exhausted its sequence numbers")
            }
        }

        /// Seals the next message as ciphertext ‖ tag.
        ///
        /// - Parameters:
        ///   - plaintext: The message.
        ///   - aad: Associated data to authenticate.
        /// - Returns: The ciphertext followed by the 16-byte tag.
        public mutating func seal(_ plaintext: RawSpan, authenticating aad: RawSpan) -> [UInt8] {
            var sealed = [UInt8](repeating: 0, count: plaintext.byteCount &+ 16)
            var span = sealed.mutableSpan
            var bytes = MutableRawSpan(mutating: &span)
            bytes.copyBytes(from: plaintext, toByteOffset: 0)
            var message = bytes._mutatingExtracting(0..<plaintext.byteCount)
            let tag = seal(&message, authenticating: aad)
            bytes.copyBytes(from: tag.span.bytes, toByteOffset: plaintext.byteCount)
            return sealed
        }

        /// Derives a secret from the context (Context.Export, RFC 9180, 5.3).
        ///
        /// - Parameters:
        ///   - exporterContext: The exporter context.
        ///   - output: Where the secret goes; its length is the secret's.
        /// - Throws: ``BytesError/invalidValue`` if `output` is longer than 255 × 32 bytes (RFC 9180's limit for
        ///   HKDF-SHA256).
        public func exportSecret(context exporterContext: RawSpan, into output: inout MutableRawSpan) throws(BytesError) {
            try context.exportSecret(context: exporterContext, into: &output, aead: aead)
        }
    }
}
