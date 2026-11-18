internal import Bytes
internal import BytesCrypto

// Zip encryption: the traditional PKWARE stream cipher ("ZipCrypto", APPNOTE 6.1) and WinZip's AES
// (AE-1/AE-2: PBKDF2-HMAC-SHA1 keys, AES in counter mode with a little-endian counter, HMAC-SHA1 over the
// ciphertext). Both decrypt in pieces, into the decoder's own buffers: nothing is allocated per entry, and no
// payload is held whole in memory. The primitives are `BytesCrypto`'s, in Swift (AES and SHA-1 with ARM's
// instructions through its small C module).

/// How an entry is encrypted.
public enum ZipEncryption: Sendable, Hashable {
    /// The traditional PKWARE cipher. Weak, but what `zip -e` and most tools write.
    case traditional
    /// WinZip AES with a 128-, 192-, or 256-bit key. `authenticatesCRC` is AE-1, which also records the
    /// contents' CRC-32; AE-2 records 0 there and relies on the HMAC alone.
    case aes(bits: Int, authenticatesCRC: Bool)
    /// PKWARE's strong encryption or an unknown scheme, which can't be read.
    case unsupported
}

/// The traditional cipher's three keys.
struct TraditionalCipher {
    private var key0: UInt32 = 0x1234_5678
    private var key1: UInt32 = 0x2345_6789
    private var key2: UInt32 = 0x3456_7890

    /// The length of the encryption header before the data.
    static var headerSize: Int { 12 }

    init(password: RawSpan) {
        let table = Self.crcTable.span
        for offset in 0..<password.byteCount {
            update(password.load(fromByteOffset: offset, as: UInt8.self), table)
        }
    }

    @inline(__always)
    private mutating func update(_ byte: UInt8, _ table: Span<UInt32>) {
        key0 = table[Int(UInt8(truncatingIfNeeded: key0) ^ byte)] ^ (key0 >> 8)
        key1 = (key1 &+ (key0 & 0xFF)) &* 134_775_813 &+ 1
        key2 = table[Int(UInt8(truncatingIfNeeded: key2) ^ UInt8(truncatingIfNeeded: key1 >> 24))] ^ (key2 >> 8)
    }

    @inline(__always)
    private mutating func decrypt(_ byte: UInt8, _ table: Span<UInt32>) -> UInt8 {
        let temp = (key2 & 0xFFFF) | 2
        let plain = byte ^ UInt8(truncatingIfNeeded: (temp &* (temp ^ 1)) >> 8)
        update(plain, table)
        return plain
    }

    /// Decrypts the 12-byte header and returns its last byte, which must match the entry's check byte.
    ///
    /// - Parameter header: The first 12 bytes of the payload.
    /// - Returns: The decrypted check byte.
    mutating func checkByte(_ header: RawSpan) -> UInt8 {
        let table = Self.crcTable.span
        var last: UInt8 = 0
        for offset in 0..<header.byteCount {
            last = decrypt(header.load(fromByteOffset: offset, as: UInt8.self), table)
        }
        return last
    }

    /// Decrypts `input` into the start of `output`, which holds at least as many bytes. The cipher's state
    /// carries over, so a payload can be decrypted in pieces.
    mutating func decrypt(_ input: RawSpan, into output: inout MutableRawSpan) {
        precondition(output.byteCount >= input.byteCount)
        let table = Self.crcTable.span
        for offset in 0..<input.byteCount {
            output.storeBytes(of: decrypt(input.load(fromByteOffset: offset, as: UInt8.self), table), toByteOffset: offset, as: UInt8.self)
        }
    }

    /// CRC-32's byte table (polynomial 0xEDB88320), which the key schedule uses.
    private static let crcTable: [UInt32] = (0..<256).map { byte in
        var crc = UInt32(byte)
        for _ in 0..<8 {
            crc = crc & 1 != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }
}

/// WinZip AES for one payload: salt, a 2-byte password verifier, the ciphertext, and a 10-byte authentication code.
enum WinZipAES {
    enum Failure: Error {
        case badPassword, authenticationFailed, truncated
    }

    static func saltSize(bits: Int) -> Int { bits / 16 }
    static var verifierSize: Int { 2 }
    static var macSize: Int { 10 }

    /// The size of the plaintext for a payload of `payloadSize` bytes.
    static func plaintextSize(payloadSize: Int, bits: Int) -> Int {
        max(0, payloadSize - saltSize(bits: bits) - verifierSize - macSize)
    }

    /// The PBKDF2-HMAC-SHA1 output (1,000 iterations): the encryption key, the authentication key, then the
    /// 2-byte password verifier, at most 66 bytes (for 256-bit keys).
    static func deriveKeys(salt: RawSpan, bits: Int, password: RawSpan) -> InlineArray<66, UInt8> {
        var derived = InlineArray<66, UInt8>(repeating: 0)
        var span = derived.mutableSpan
        var bytes = MutableRawSpan(mutating: &span)
        var used = bytes._mutatingExtracting(0..<(2 * (bits / 8) + verifierSize))
        PBKDF2.deriveKey(SHA1.self, password: password, salt: salt, iterations: 1000, into: &used)
        return derived
    }

    /// Whether `password` matches the payload's verifier, without decrypting.
    static func verify(_ payload: RawSpan, bits: Int, password: RawSpan) -> Bool {
        let saltSize = saltSize(bits: bits)
        guard payload.byteCount >= saltSize + verifierSize else { return false }
        let derived = deriveKeys(salt: payload.extracting(0..<saltSize), bits: bits, password: password)
        let keyBytes = bits / 8
        return constantTimeEquals(derived.span.bytes.extracting((2 * keyBytes)..<(2 * keyBytes + verifierSize)),
                                  payload.extracting(saltSize..<(saltSize + verifierSize)))
    }

    /// Checks the password and the whole payload's authentication code, and returns a decryptor for the
    /// ciphertext, which is `payload[ciphertextRange]`.
    ///
    /// The HMAC covers the ciphertext and is checked first, over the whole payload, before anything is decrypted:
    /// a corrupt or altered entry fails here, never reaching the decompressor. That reads the ciphertext twice (it's
    /// mapped, and HMAC-SHA1 with SHA instructions runs at about 3 GB/s) instead of decrypting it all into memory.
    ///
    /// - Throws: ``Failure/badPassword`` if the verifier doesn't match; ``Failure/authenticationFailed`` if the HMAC
    ///   doesn't; ``Failure/truncated`` if the payload is too short for its header and code.
    static func open(_ payload: RawSpan, bits: Int, password: RawSpan) throws(Failure) -> (cipher: AES, counter: AES.Counter, ciphertext: Range<Int>) {
        let saltSize = saltSize(bits: bits)
        let keyBytes = bits / 8
        guard payload.byteCount >= saltSize + verifierSize + macSize else { throw .truncated }
        let start = saltSize + verifierSize
        let ciphertext = start..<(payload.byteCount - macSize)

        let derived = deriveKeys(salt: payload.extracting(0..<saltSize), bits: bits, password: password)
        let keys = derived.span.bytes
        guard constantTimeEquals(keys.extracting((2 * keyBytes)..<(2 * keyBytes + verifierSize)), payload.extracting(saltSize..<start)) else {
            throw .badPassword
        }
        var mac = HMAC<SHA1>(key: keys.extracting(keyBytes..<(2 * keyBytes)))
        mac.update(payload.extracting(ciphertext))
        var digest = InlineArray<20, UInt8>(repeating: 0)
        var span = digest.mutableSpan
        var bytes = MutableRawSpan(mutating: &span)
        mac.finalize(into: &bytes)
        guard constantTimeEquals(digest.span.bytes.extracting(0..<macSize), payload.extracting(ciphertext.upperBound...)) else {
            throw .authenticationFailed
        }
        return (AES(key: keys.extracting(0..<keyBytes)), AES.Counter(littleEndianFrom: 1), ciphertext)
    }
}

/// An entry's decryption in progress: the cipher, and how much of the ciphertext it has decrypted.
struct PayloadDecryptor {
    enum Cipher {
        case traditional(TraditionalCipher)
        case aes(AES, AES.Counter)
    }

    var cipher: Cipher
    /// The ciphertext's place in the payload.
    let ciphertext: Range<Int>
    /// Where in the payload the next piece starts.
    var position: Int

    /// Whether all the ciphertext has been decrypted.
    var isFinished: Bool { position == ciphertext.upperBound }

    /// Decrypts the next piece of the payload's ciphertext into the start of `output`, as much as fits.
    ///
    /// - Returns: The number of bytes decrypted.
    mutating func decryptNext(from payload: RawSpan, into output: inout MutableRawSpan) -> Int {
        let count = min(output.byteCount, ciphertext.upperBound - position)
        let piece = payload.extracting(position..<(position + count))
        switch cipher {
        case .traditional(var traditional):
            traditional.decrypt(piece, into: &output)
            cipher = .traditional(traditional)
        case .aes(let aes, var counter):
            aes.counterMode(piece, into: &output, counter: &counter)
            cipher = .aes(aes, counter)
        }
        position += count
        return count
    }
}
