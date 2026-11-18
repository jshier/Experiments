import CommonCrypto

// Zip encryption: the traditional PKWARE stream cipher ("ZipCrypto", APPNOTE 6.1) and WinZip's AES
// (AE-1/AE-2: PBKDF2-HMAC-SHA1 keys, AES in counter mode with a little-endian counter, HMAC-SHA1 over the
// ciphertext). Both decrypt a whole payload at once, into a buffer the decoder owns, before decompression.

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

    init(password: [UInt8]) {
        let table = Self.crcTable.span
        for byte in password {
            update(byte, table)
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
        let bytes = Span<UInt8>(viewing: header)
        var last: UInt8 = 0
        for index in bytes.indices {
            last = decrypt(bytes[index], table)
        }
        return last
    }

    /// Decrypts `input` into `output`, which holds exactly as many bytes.
    mutating func decrypt(_ input: Span<UInt8>, into output: inout MutableSpan<UInt8>) {
        precondition(output.count == input.count)
        let table = Self.crcTable.span
        for index in input.indices {
            output[index] = decrypt(input[index], table)
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

/// WinZip AES decryption of one payload: salt, a 2-byte password verifier, the ciphertext, and a 10-byte
/// authentication code.
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
    /// 2-byte password verifier.
    ///
    /// Unsafe: CommonCrypto takes pointers and lengths. Safe: `salt` is valid for the call, the others are
    /// arrays whose buffers live for it.
    private static func deriveKeys(salt: UnsafeRawBufferPointer, bits: Int, password: [UInt8]) -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: 2 * (bits / 8) + verifierSize)
        let status = password.withUnsafeBytes { password in
            derived.withUnsafeMutableBufferPointer { derived in
                unsafe CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                    salt.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000,
                    derived.baseAddress, derived.count
                )
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return derived
    }

    /// Whether `password` matches the payload's verifier, without decrypting.
    static func verify(_ payload: RawSpan, bits: Int, password: [UInt8]) -> Bool {
        let saltSize = saltSize(bits: bits)
        guard payload.byteCount >= saltSize + verifierSize else { return false }
        // Unsafe: buffers over the payload's span, valid for the closure.
        return payload.withUnsafeBytes { payload in
            let derived = unsafe deriveKeys(salt: UnsafeRawBufferPointer(rebasing: payload[..<saltSize]), bits: bits, password: password)
            return unsafe derived[(bits / 4)...].elementsEqual(payload[saltSize..<(saltSize + verifierSize)])
        }
    }

    /// Checks the password and the authentication code, then decrypts the ciphertext into `output`.
    ///
    /// - Parameters:
    ///   - payload: The whole payload.
    ///   - bits: The key size: 128, 192, or 256.
    ///   - password: The password's bytes.
    ///   - output: Room for at least ``plaintextSize(payloadSize:bits:)`` bytes.
    /// - Returns: The number of plaintext bytes.
    /// - Throws: ``Failure/badPassword`` if the verifier doesn't match; ``Failure/authenticationFailed`` if
    ///   the HMAC doesn't (the data is corrupt or was altered); ``Failure/truncated`` if the payload is too
    ///   short for its header and code.
    static func decrypt(
        _ payload: RawSpan, bits: Int, password: [UInt8], into output: UnsafeMutableRawBufferPointer
    ) throws(Failure) -> Int {
        let saltSize = saltSize(bits: bits)
        let keySize = bits / 8
        guard payload.byteCount >= saltSize + verifierSize + macSize else { throw .truncated }
        let count = plaintextSize(payloadSize: payload.byteCount, bits: bits)
        precondition(output.count >= count)

        // Unsafe throughout: CommonCrypto's C API takes pointers and lengths. Safe: each describes a buffer
        // valid for the call (the payload's span, the output buffer, or a local array), with the exact length.
        return try payload.withUnsafeBytes { (payload) throws(Failure) -> Int in
            let salt = unsafe UnsafeRawBufferPointer(rebasing: payload[..<saltSize])
            let verifier = unsafe UnsafeRawBufferPointer(rebasing: payload[saltSize..<(saltSize + verifierSize)])
            let ciphertextStart = saltSize + verifierSize
            let ciphertext = unsafe UnsafeRawBufferPointer(rebasing: payload[ciphertextStart..<(ciphertextStart + count)])
            let mac = unsafe UnsafeRawBufferPointer(rebasing: payload[(ciphertextStart + count)...])

            let derived = unsafe deriveKeys(salt: salt, bits: bits, password: password)
            guard unsafe derived[(2 * keySize)...].elementsEqual(verifier) else { throw .badPassword }

            // The HMAC covers the ciphertext: check it before decrypting anything.
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            derived.withUnsafeBufferPointer { derived in
                digest.withUnsafeMutableBytes { digest in
                    unsafe CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA1), derived.baseAddress! + keySize, keySize,
                        ciphertext.baseAddress, ciphertext.count, digest.baseAddress
                    )
                }
            }
            guard unsafe digest.prefix(macSize).elementsEqual(mac) else { throw .authenticationFailed }

            derived.withUnsafeBytes { key in
                unsafe counterMode(ciphertext, key: UnsafeRawBufferPointer(rebasing: key[..<keySize]), into: output)
            }
            return count
        }
    }

    /// AES in counter mode as WinZip uses it: the counter is a 128-bit little-endian integer starting at 1
    /// (CommonCrypto's CTR mode counts big-endian), so the key stream is made by encrypting counter blocks
    /// in ECB mode, a batch at a time.
    ///
    /// Unsafe: raw buffers for CommonCrypto. Safe: `input` and `output` hold at least `input.count` bytes, and
    /// the batch buffers are local.
    private static func counterMode(_ input: UnsafeRawBufferPointer, key: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) {
        var cryptor: CCCryptorRef?
        let status = unsafe CCCryptorCreate(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
            key.baseAddress, key.count, nil, &cryptor
        )
        precondition(status == kCCSuccess, "AES setup failed: \(status)")
        defer { unsafe CCCryptorRelease(cryptor) }

        let batchBlocks = 4096
        var counters = [UInt64](repeating: 0, count: 2 * batchBlocks)
        var stream = [UInt8](repeating: 0, count: 16 * batchBlocks)
        var counter: UInt64 = 1
        var offset = 0
        while offset < input.count {
            let bytes = min(input.count - offset, 16 * batchBlocks)
            let blocks = (bytes + 15) / 16
            for block in 0..<blocks {
                counters[2 * block] = counter.littleEndian
                counter &+= 1
            }
            var moved = 0
            let status = counters.withUnsafeBytes { counters in
                stream.withUnsafeMutableBytes { stream in
                    unsafe CCCryptorUpdate(cryptor, counters.baseAddress, 16 * blocks, stream.baseAddress, stream.count, &moved)
                }
            }
            precondition(status == kCCSuccess && moved == 16 * blocks, "AES failed: \(status)")
            stream.withUnsafeBytes { stream in
                for index in 0..<bytes {
                    unsafe output[offset + index] = input[offset + index] ^ stream[index]
                }
            }
            offset += bytes
        }
    }
}
