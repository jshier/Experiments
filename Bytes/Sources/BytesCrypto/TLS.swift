internal import Bytes

// TLS 1.3 (RFC 8446): cipher suites, content types, alerts, the key schedule (7.1), traffic keys (7.3) and their
// updates (7.2), and the transcript hash (4.4.1). The record layer is in `TLSRecord.swift`.
//
// What's here is what a TLS 1.3 implementation derives and protects with. The handshake itself (building and
// parsing its messages, (EC)DHE, certificates and their signatures) isn't: an application gets the shared secret
// and transcript hashes from its handshake and drives the key schedule with them, as RFC 8448's traces do, which
// the tests replay byte for byte.

/// TLS 1.3's cipher suites (RFC 8446, B.4): an AEAD and the hash for HKDF and the transcript.
public enum TLSCipherSuite: UInt16, Sendable, CaseIterable {
    /// AES-128-GCM with SHA-256: the suite every TLS 1.3 implementation must support.
    case aes128GCMSHA256 = 0x1301
    /// AES-256-GCM with SHA-384.
    case aes256GCMSHA384 = 0x1302
    /// ChaCha20-Poly1305 with SHA-256.
    case chaCha20Poly1305SHA256 = 0x1303

    /// The AEAD's key length in bytes.
    public var keyByteCount: Int {
        switch self {
        case .aes128GCMSHA256: 16
        case .aes256GCMSHA384, .chaCha20Poly1305SHA256: 32
        }
    }

    /// The hash's output length in bytes: the length of every secret.
    public var hashByteCount: Int {
        switch self {
        case .aes128GCMSHA256, .chaCha20Poly1305SHA256: 32
        case .aes256GCMSHA384: 48
        }
    }

    /// The most records one traffic key may protect before it must be updated (RFC 8446, 5.5): 2^24.5 full-size
    /// records for AES-GCM, to keep the AEAD's safety margin; for ChaCha20-Poly1305 the 64-bit sequence number
    /// runs out first.
    public var recordLimit: UInt64 {
        switch self {
        case .aes128GCMSHA256, .aes256GCMSHA384: 23_726_566 // ⌊2^24.5⌋
        case .chaCha20Poly1305SHA256: UInt64.max
        }
    }
}

/// A record's content type (RFC 8446, 5.1).
public enum TLSContentType: UInt8, Sendable {
    /// Sent unprotected for middlebox compatibility; ignored.
    case changeCipherSpec = 20
    /// An alert: a closure or an error.
    case alert = 21
    /// Handshake messages, including the post-handshake ones (NewSessionTicket, KeyUpdate).
    case handshake = 22
    /// The application's data.
    case applicationData = 23
}

/// A TLS alert (RFC 8446, 6): the reason a connection ends, as an error. The raw value is its wire description.
public enum TLSAlert: UInt8, Error, Sendable {
    case closeNotify = 0
    case unexpectedMessage = 10
    case badRecordMAC = 20
    case recordOverflow = 22
    case handshakeFailure = 40
    case badCertificate = 42
    case unsupportedCertificate = 43
    case certificateRevoked = 44
    case certificateExpired = 45
    case certificateUnknown = 46
    case illegalParameter = 47
    case unknownCA = 48
    case accessDenied = 49
    case decodeError = 50
    case decryptError = 51
    case protocolVersion = 70
    case insufficientSecurity = 71
    case internalError = 80
    case inappropriateFallback = 86
    case userCanceled = 90
    case missingExtension = 109
    case unsupportedExtension = 110
    case unrecognizedName = 112
    case badCertificateStatusResponse = 113
    case unknownPSKIdentity = 115
    case certificateRequired = 116
    case noApplicationProtocol = 120

    /// Whether the alert ends the connection as an error. All do but `closeNotify` and `userCanceled`, which
    /// TLS 1.3 sends at warning level.
    public var isFatal: Bool { self != .closeNotify && self != .userCanceled }
}

// MARK: - Secrets

/// A secret of the key schedule: as long as the suite's hash (32 or 48 bytes), and the suite it belongs to.
public struct TLSSecret: Sendable {
    /// The cipher suite whose hash made it.
    public let suite: TLSCipherSuite
    @usableFromInline var storage: InlineArray<48, UInt8>

    /// The secret's bytes.
    public var bytes: RawSpan {
        @_lifetime(borrow self) get { storage.span.bytes.extracting(first: suite.hashByteCount) }
    }

    /// A secret with these bytes, as the suite's hash long.
    ///
    /// - Parameters:
    ///   - bytes: The secret: `suite.hashByteCount` bytes.
    ///   - suite: The cipher suite.
    /// - Precondition: `bytes` is `suite.hashByteCount` bytes.
    public init(_ bytes: RawSpan, suite: TLSCipherSuite) {
        precondition(bytes.byteCount == suite.hashByteCount, "A \(suite) secret is \(suite.hashByteCount) bytes")
        self.suite = suite
        storage = InlineArray(repeating: 0)
        var span = storage.mutableSpan
        span.copyBytes(from: bytes, toByteOffset: 0)
    }

    /// A secret written by `body` into its storage.
    init(suite: TLSCipherSuite, _ body: (inout MutableRawSpan) -> Void) {
        self.suite = suite
        storage = InlineArray(repeating: 0)
        var span = storage.mutableSpan
        var raw = MutableRawSpan(mutating: &span)
        var used = raw._mutatingExtracting(0..<suite.hashByteCount)
        body(&used)
    }

    /// `HKDF-Expand-Label(Secret, Label, Context, Length)` (RFC 8446, 7.1) into `output`, whose length is `Length`.
    ///
    /// - Parameters:
    ///   - label: The label, without the `"tls13 "` prefix (at most 249 bytes of ASCII).
    ///   - context: The context: a transcript hash, or empty.
    ///   - output: Where the output goes.
    public func expandLabel(_ label: StaticString, context: RawSpan, into output: inout MutableRawSpan) {
        // HkdfLabel: uint16 length, opaque label<7..255> = "tls13 " + label, opaque context<0..255>.
        var info = InlineArray<320, UInt8>(repeating: 0)
        let fullLabel = "tls13 \(label)"
        let labelLength = fullLabel.utf8.count
        precondition(labelLength <= 255 && context.byteCount <= 255 && output.byteCount <= 0xFFFF, "HkdfLabel fields too long")
        let count: Int
        do {
            var span = info.mutableSpan
            var writer = AlignedBytesWriter(MutableRawSpan(mutating: &span))
            // Can't throw: 2 + 1 + 255 + 1 + 255 bytes at most, in 320.
            try! writer.write(UInt16(output.byteCount), as: Byte2.self, .bigEndian)
            try! writer.write(UInt8(labelLength))
            try! writer.write(fullLabel.utf8Span.span.bytes)
            try! writer.write(UInt8(context.byteCount))
            try! writer.write(context)
            count = writer.byteOffset
        }
        let infoBytes = info.span.bytes.extracting(first: count)
        switch suite {
        case .aes128GCMSHA256, .chaCha20Poly1305SHA256:
            HKDF<SHA256>.expand(pseudorandomKey: bytes, info: infoBytes, into: &output)
        case .aes256GCMSHA384:
            HKDF<SHA384>.expand(pseudorandomKey: bytes, info: infoBytes, into: &output)
        }
    }

    /// `Derive-Secret(Secret, Label, Messages)` with the messages' transcript hash: `HKDF-Expand-Label(Secret,
    /// Label, Transcript-Hash(Messages), Hash.length)`.
    ///
    /// - Parameters:
    ///   - label: The label, without the `"tls13 "` prefix.
    ///   - transcriptHash: The hash of the handshake messages so far (``TLSTranscript``).
    /// - Returns: The derived secret.
    public func derive(_ label: StaticString, transcriptHash: RawSpan) -> TLSSecret {
        TLSSecret(suite: suite) { output in expandLabel(label, context: transcriptHash, into: &output) }
    }

    /// The next traffic secret, for a KeyUpdate (RFC 8446, 7.2): `HKDF-Expand-Label(secret, "traffic upd", "",
    /// Hash.length)`.
    public var updated: TLSSecret {
        TLSSecret(suite: suite) { output in expandLabel("traffic upd", context: RawSpan(), into: &output) }
    }

    /// The `finished_key` for a Finished message (RFC 8446, 4.4.4), from the handshake traffic secret that sends it.
    public var finishedKey: TLSSecret {
        TLSSecret(suite: suite) { output in expandLabel("finished", context: RawSpan(), into: &output) }
    }

    /// A Finished message's `verify_data`: `HMAC(finished_key, Transcript-Hash(Handshake Context, Certificate*,
    /// CertificateVerify*))`, with this secret as the `finished_key` (see ``finishedKey``).
    ///
    /// - Parameter transcriptHash: The transcript hash up to the Finished message.
    /// - Returns: The verify data, `Hash.length` bytes.
    public func verifyData(transcriptHash: RawSpan) -> TLSSecret {
        TLSSecret(suite: suite) { output in
            switch suite {
            case .aes128GCMSHA256, .chaCha20Poly1305SHA256:
                HMAC<SHA256>.authenticationCode(for: transcriptHash, key: bytes, into: &output)
            case .aes256GCMSHA384:
                HMAC<SHA384>.authenticationCode(for: transcriptHash, key: bytes, into: &output)
            }
        }
    }

    /// `HKDF-Extract(salt: self, IKM: ikm)`: the next stage's secret.
    func extract(_ ikm: RawSpan) -> TLSSecret {
        TLSSecret(suite: suite) { output in
            switch suite {
            case .aes128GCMSHA256, .chaCha20Poly1305SHA256: HKDF<SHA256>.extract(salt: bytes, inputKeyMaterial: ikm, into: &output)
            case .aes256GCMSHA384: HKDF<SHA384>.extract(salt: bytes, inputKeyMaterial: ikm, into: &output)
            }
        }
    }
}

/// One direction's traffic keys (RFC 8446, 7.3): the AEAD key and the IV the record nonces start from, and the
/// suite they're for.
public struct TLSTrafficKeys: Sendable {
    /// The cipher suite.
    public let suite: TLSCipherSuite
    /// The AEAD key: `keyByteCount` bytes of 32.
    public var key: InlineArray<32, UInt8>
    /// The IV.
    public var iv: InlineArray<12, UInt8>

    /// The key's bytes.
    public var keyBytes: RawSpan {
        @_lifetime(borrow self) get { key.span.bytes.extracting(first: suite.keyByteCount) }
    }

    /// The keys for a traffic secret: `HKDF-Expand-Label(Secret, "key", "", key_length)` and `(Secret, "iv", "", 12)`.
    ///
    /// - Parameter secret: A traffic secret: handshake, application, or updated.
    public init(secret: TLSSecret) {
        suite = secret.suite
        key = InlineArray(repeating: 0)
        iv = InlineArray(repeating: 0)
        var keySpan = key.mutableSpan
        var keyRaw = MutableRawSpan(mutating: &keySpan)
        var keyUsed = keyRaw._mutatingExtracting(0..<suite.keyByteCount)
        secret.expandLabel("key", context: RawSpan(), into: &keyUsed)
        var ivSpan = iv.mutableSpan
        var ivRaw = MutableRawSpan(mutating: &ivSpan)
        secret.expandLabel("iv", context: RawSpan(), into: &ivRaw)
    }

    /// The keys for a ChaCha20-Poly1305 traffic secret given as bytes.
    ///
    /// - Parameter secret: A 32-byte traffic secret.
    public init(trafficSecret secret: RawSpan) {
        self.init(secret: TLSSecret(secret, suite: .chaCha20Poly1305SHA256))
    }
}

/// TLS 1.3's key schedule (RFC 8446, 7.1): from a pre-shared key (or none), an (EC)DHE shared secret, and the
/// transcript hashes the handshake supplies at each point, every secret a connection uses.
///
/// ```swift
/// var schedule = TLSKeySchedule(suite: .aes128GCMSHA256)               // no PSK
/// schedule.addSharedSecret(ecdheSharedSecret)                          // after ServerHello
/// let clientHandshake = schedule.secret("c hs traffic", transcriptHash: helloHash)
/// let serverHandshake = schedule.secret("s hs traffic", transcriptHash: helloHash)
/// schedule.finishHandshakeSecrets()                                    // to the master secret
/// let clientApplication = schedule.secret("c ap traffic", transcriptHash: serverFinishedHash)
/// ```
public struct TLSKeySchedule: Sendable {
    /// The current stage's secret: early, then handshake, then master.
    public private(set) var current: TLSSecret

    /// The suite.
    public var suite: TLSCipherSuite { current.suite }

    /// The hash of no messages, for `Derive-Secret(…, "derived", "")`.
    var emptyHash: TLSSecret {
        TLSSecret(suite: suite) { output in
            switch suite {
            case .aes128GCMSHA256, .chaCha20Poly1305SHA256:
                var hash = SHA256()
                hash.finalize(into: &output)
            case .aes256GCMSHA384:
                var hash = SHA384()
                hash.finalize(into: &output)
            }
        }
    }

    /// Starts the schedule: the early secret, `HKDF-Extract(0, PSK)`, or of zeros without a PSK.
    ///
    /// - Parameters:
    ///   - suite: The negotiated cipher suite.
    ///   - preSharedKey: A resumption or external PSK, `Hash.length` bytes; `nil` for a full handshake.
    public init(suite: TLSCipherSuite, preSharedKey: RawSpan? = nil) {
        let zeros = InlineArray<48, UInt8>(repeating: 0)
        let salt = TLSSecret(zeros.span.bytes.extracting(first: suite.hashByteCount), suite: suite)
        if let preSharedKey {
            current = salt.extract(preSharedKey)
        } else {
            current = salt.extract(zeros.span.bytes.extracting(first: suite.hashByteCount))
        }
    }

    /// A secret derived from the current stage: `Derive-Secret(current, label, Messages)`.
    ///
    /// The labels (without `"tls13 "`): early stage `"ext binder"`, `"res binder"`, `"c e traffic"`,
    /// `"e exp master"`; handshake stage `"c hs traffic"`, `"s hs traffic"`; master stage `"c ap traffic"`,
    /// `"s ap traffic"`, `"exp master"`, `"res master"`.
    ///
    /// - Parameters:
    ///   - label: The label.
    ///   - transcriptHash: The transcript hash the label's messages call for.
    /// - Returns: The secret.
    public func secret(_ label: StaticString, transcriptHash: RawSpan) -> TLSSecret {
        current.derive(label, transcriptHash: transcriptHash)
    }

    /// Moves to the handshake secret: `HKDF-Extract(Derive-Secret(early, "derived", ""), (EC)DHE)`.
    ///
    /// - Parameter sharedSecret: The (EC)DHE shared secret (32 bytes for X25519).
    public mutating func addSharedSecret(_ sharedSecret: RawSpan) {
        let empty = emptyHash
        current = current.derive("derived", transcriptHash: empty.bytes).extract(sharedSecret)
    }

    /// Moves to the master secret: `HKDF-Extract(Derive-Secret(handshake, "derived", ""), 0)`.
    public mutating func finishHandshakeSecrets() {
        let empty = emptyHash
        let zeros = InlineArray<48, UInt8>(repeating: 0)
        current = current.derive("derived", transcriptHash: empty.bytes).extract(zeros.span.bytes.extracting(first: suite.hashByteCount))
    }

    /// Both directions' application traffic keys from an (EC)DHE shared secret, with every transcript hash taken
    /// as the empty transcript's: for tests and benchmarks that need realistic keys without a handshake. A real
    /// connection derives them from its handshake's transcript.
    ///
    /// - Parameters:
    ///   - sharedSecret: The shared secret.
    ///   - suite: The cipher suite (ChaCha20-Poly1305 by default).
    /// - Returns: The client's and server's keys.
    public static func applicationKeys(
        sharedSecret: RawSpan, suite: TLSCipherSuite = .chaCha20Poly1305SHA256
    ) -> (client: TLSTrafficKeys, server: TLSTrafficKeys) {
        var schedule = TLSKeySchedule(suite: suite)
        schedule.addSharedSecret(sharedSecret)
        schedule.finishHandshakeSecrets()
        let empty = schedule.emptyHash
        return (TLSTrafficKeys(secret: schedule.secret("c ap traffic", transcriptHash: empty.bytes)),
                TLSTrafficKeys(secret: schedule.secret("s ap traffic", transcriptHash: empty.bytes)))
    }
}

/// The transcript hash (RFC 8446, 4.4.1): the running hash of the handshake messages, read at any point without
/// ending it.
public struct TLSTranscript: Sendable {
    enum State: Sendable {
        case sha256(SHA256)
        case sha384(SHA384)
    }

    var state: State

    /// The suite whose hash it uses.
    public let suite: TLSCipherSuite

    /// An empty transcript for `suite`.
    ///
    /// - Parameter suite: The negotiated cipher suite.
    public init(suite: TLSCipherSuite) {
        self.suite = suite
        state = suite == .aes256GCMSHA384 ? .sha384(SHA384()) : .sha256(SHA256())
    }

    /// Adds a handshake message, header included.
    ///
    /// - Parameter message: The message's bytes as sent.
    public mutating func add(_ message: RawSpan) {
        switch state {
        case var .sha256(hash): hash.update(message); state = .sha256(hash)
        case var .sha384(hash): hash.update(message); state = .sha384(hash)
        }
    }

    /// The hash of the messages so far, as a secret-sized value.
    public var hash: TLSSecret {
        TLSSecret(suite: suite) { output in
            switch state {
            case var .sha256(copy): copy.finalize(into: &output)
            case var .sha384(copy): copy.finalize(into: &output)
            }
        }
    }
}
