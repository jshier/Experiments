public import Bytes

// HMAC (RFC 2104), HKDF (RFC 5869), and PBKDF2 (RFC 8018), generic over ``HashFunction``. Nothing allocates:
// digests live in fixed-size inline buffers (64 bytes, enough for SHA-512), and keyed hash states are copied
// rather than recomputed, so PBKDF2's thousands of iterations each cost two compressions per hash block.

/// The largest digest any ``HashFunction`` here produces (SHA-512's), and so the size of the inline digest
/// buffers.
@usableFromInline let maximumDigestByteCount = 64

/// A keyed message authentication code over a hash function: HMAC-SHA1 for WinZip AES and PBKDF2, HMAC-SHA256 for
/// TLS 1.3's key schedule and finished messages.
///
/// ```swift
/// var mac = HMAC<SHA256>(key: key)
/// mac.update(message)
/// let tag = mac.finalize()               // [UInt8], 32 bytes
/// ```
///
/// The key's padded inner and outer hash states are computed once, so the keyed MAC can be copied and reused for
/// many messages at the cost of hashing the messages alone.
public struct HMAC<H: HashFunction>: Sendable {
    /// The hash with the key's inner pad absorbed, then the message.
    @usableFromInline var inner: H
    /// The hash with the key's outer pad absorbed: the inner digest goes in last.
    @usableFromInline var outer: H

    /// A MAC keyed with `key`. Keys longer than the hash's block are hashed first, as RFC 2104 specifies.
    ///
    /// - Parameter key: The key, of any length (at least the digest's length is recommended).
    @inlinable
    public init(key: RawSpan) {
        var padded = InlineArray<128, UInt8>(repeating: 0) // The largest block: SHA-512's.
        let blockByteCount = H.blockByteCount
        if key.byteCount > blockByteCount {
            var hash = H()
            hash.update(key)
            var span = padded.mutableSpan
            var bytes = MutableRawSpan(mutating: &span)
            hash.finalize(into: &bytes)
        } else {
            var span = padded.mutableSpan
            span.copyBytes(from: key, toByteOffset: 0)
        }
        for index in 0..<blockByteCount { padded[index] ^= 0x36 }
        inner = H()
        inner.update(padded.span.bytes.extracting(first: blockByteCount))
        for index in 0..<blockByteCount { padded[index] ^= 0x36 ^ 0x5C }
        outer = H()
        outer.update(padded.span.bytes.extracting(first: blockByteCount))
    }

    /// Adds `bytes` to the message.
    ///
    /// - Parameter bytes: The next bytes of the message.
    @inlinable
    public mutating func update(_ bytes: RawSpan) {
        inner.update(bytes)
    }

    /// Finishes the message and writes its MAC (the hash's digest size) to the start of `mac`.
    ///
    /// - Parameter mac: Room for at least `H.digestByteCount` bytes.
    @inlinable
    public mutating func finalize(into mac: inout MutableRawSpan) {
        var digest = InlineArray<64, UInt8>(repeating: 0)
        var span = digest.mutableSpan
        var bytes = MutableRawSpan(mutating: &span)
        inner.finalize(into: &bytes)
        outer.update(digest.span.bytes.extracting(first: H.digestByteCount))
        outer.finalize(into: &mac)
    }

    /// Finishes the message and returns its MAC.
    ///
    /// - Returns: The MAC: `H.digestByteCount` bytes.
    @inlinable
    public mutating func finalize() -> [UInt8] {
        var mac = [UInt8](repeating: 0, count: H.digestByteCount)
        var span = mac.mutableSpan
        var bytes = MutableRawSpan(mutating: &span)
        finalize(into: &bytes)
        return mac
    }

    /// The MAC of `message` with `key`.
    ///
    /// - Parameters:
    ///   - message: The whole message.
    ///   - key: The key.
    ///   - mac: Room for at least `H.digestByteCount` bytes.
    @inlinable
    public static func authenticationCode(for message: RawSpan, key: RawSpan, into mac: inout MutableRawSpan) {
        var hmac = HMAC(key: key)
        hmac.update(message)
        hmac.finalize(into: &mac)
    }
}

/// PBKDF2 (RFC 8018, 5.2): a key from a password, made slow on purpose by iterating an HMAC. WinZip AES uses
/// PBKDF2-HMAC-SHA1 with 1,000 iterations.
public enum PBKDF2 {
    /// Derives `key.byteCount` bytes from `password` and `salt`.
    ///
    /// ```swift
    /// var key = [UInt8](repeating: 0, count: 66)
    /// var span = key.mutableSpan
    /// var bytes = MutableRawSpan(mutating: &span)
    /// PBKDF2.deriveKey(SHA1.self, password: password, salt: salt, iterations: 1000, into: &bytes)
    /// ```
    ///
    /// - Parameters:
    ///   - hash: The hash function HMAC uses.
    ///   - password: The password's bytes (UTF-8, by convention).
    ///   - salt: The salt.
    ///   - iterations: The number of HMAC iterations per block, at least 1.
    ///   - key: Where the derived key goes; its length is the key's.
    /// - Precondition: `iterations` is at least 1.
    @inlinable
    public static func deriveKey<H: HashFunction>(
        _ hash: H.Type, password: RawSpan, salt: RawSpan, iterations: Int, into key: inout MutableRawSpan
    ) {
        precondition(iterations >= 1, "PBKDF2 needs at least one iteration")
        let keyed = HMAC<H>(key: password)
        let digestByteCount = H.digestByteCount
        var block: UInt32 = 1
        var offset = 0
        while offset < key.byteCount {
            // U1 = HMAC(password, salt ‖ INT(block)); Uj = HMAC(password, Uj-1); T = U1 ⊕ … ⊕ Uc.
            var u = InlineArray<64, UInt8>(repeating: 0)
            var t = InlineArray<64, UInt8>(repeating: 0)
            var mac = keyed
            mac.update(salt)
            let index: InlineArray<4, UInt8> = [UInt8(block >> 24), UInt8(truncatingIfNeeded: block >> 16),
                                                UInt8(truncatingIfNeeded: block >> 8), UInt8(truncatingIfNeeded: block)]
            mac.update(index.span.bytes)
            do {
                var span = u.mutableSpan
                var bytes = MutableRawSpan(mutating: &span)
                mac.finalize(into: &bytes)
            }
            t = u
            for _ in 1..<iterations {
                var next = keyed
                next.update(u.span.bytes.extracting(first: digestByteCount))
                var span = u.mutableSpan
                var bytes = MutableRawSpan(mutating: &span)
                next.finalize(into: &bytes)
                for byte in 0..<digestByteCount { t[byte] ^= u[byte] }
            }
            let take = min(digestByteCount, key.byteCount &- offset)
            key.copyBytes(from: t.span.bytes.extracting(first: take), toByteOffset: offset)
            offset &+= take
            block &+= 1
        }
    }
}

/// HKDF (RFC 5869): extract a pseudorandom key from input keying material, then expand it into keys. TLS 1.3's
/// key schedule is built from these two steps.
public enum HKDF<H: HashFunction> {
    /// `HKDF-Extract(salt, ikm)`: the pseudorandom key, `HMAC-Hash(salt, ikm)`.
    ///
    /// - Parameters:
    ///   - salt: The salt (an empty salt is a string of zeros the digest's length, as HMAC pads it).
    ///   - inputKeyMaterial: The secret, such as a Diffie–Hellman shared secret.
    ///   - key: Room for `H.digestByteCount` bytes.
    @inlinable
    public static func extract(salt: RawSpan, inputKeyMaterial: RawSpan, into key: inout MutableRawSpan) {
        HMAC<H>.authenticationCode(for: inputKeyMaterial, key: salt, into: &key)
    }

    /// `HKDF-Expand(prk, info, L)`, with `L` the output's length.
    ///
    /// - Parameters:
    ///   - pseudorandomKey: The key from ``extract(salt:inputKeyMaterial:into:)``.
    ///   - info: Context binding the output to its use (TLS 1.3's `HkdfLabel`).
    ///   - output: Where the keying material goes; at most 255 digests long.
    /// - Precondition: `output` is at most `255 × H.digestByteCount` bytes.
    @inlinable
    public static func expand(pseudorandomKey: RawSpan, info: RawSpan, into output: inout MutableRawSpan) {
        let digestByteCount = H.digestByteCount
        precondition(output.byteCount <= 255 &* digestByteCount, "HKDF-Expand makes at most 255 digests")
        let keyed = HMAC<H>(key: pseudorandomKey)
        var previous = InlineArray<64, UInt8>(repeating: 0)
        var previousCount = 0
        var counter: UInt8 = 1
        var offset = 0
        while offset < output.byteCount {
            // T(i) = HMAC(prk, T(i-1) ‖ info ‖ i).
            var mac = keyed
            mac.update(previous.span.bytes.extracting(first: previousCount))
            mac.update(info)
            let index = InlineArray<1, UInt8>(repeating: counter)
            mac.update(index.span.bytes)
            var span = previous.mutableSpan
            var bytes = MutableRawSpan(mutating: &span)
            mac.finalize(into: &bytes)
            previousCount = digestByteCount
            let take = min(digestByteCount, output.byteCount &- offset)
            output.copyBytes(from: previous.span.bytes.extracting(first: take), toByteOffset: offset)
            offset &+= take
            counter &+= 1
        }
    }
}
