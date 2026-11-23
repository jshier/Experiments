import Bytes
import BytesCrypto

// The key schedule (all HKDF-SHA256, RFC 5869; info strings are ASCII without a terminator, indices
// little-endian 32-bit):
//
//     main key        HKDF(key material, salt, "AEA_AMK" | profile word | signing public key (X9.63, 65 bytes))
//     root header     HKDF(main key, -, "AEA_RHEK")          MAC key (then, encrypted profiles, AES key and IV)
//     cluster i       HKDF(main key, -, "AEA_CK" | i)
//     cluster header  HKDF(cluster key, -, "AEA_CHEK")
//     segment j       HKDF(cluster key, -, "AEA_SK" | j)    j counts within the cluster
//     padding         HKDF(main key, -, "AEA_PAK")
//
// Every MAC is HMAC-SHA256(key, associated data | data | associated data's size as 64-bit), with:
//
//     root header     associated data = first cluster header's MAC | auth data; data = the root header
//     cluster header  associated data = next cluster header's MAC | segment MACs; data = the segment infos
//     segment         no associated data; data = the stored (compressed) segment
//     padding         plain HMAC of the padding bytes
//
// On profile 0 the key material is stored in the clear: the MACs bind the data to the prologue, which the
// signature covers (with its own field zeroed), so they authenticate everything only together with it.

/// A 32-byte key or MAC.
typealias Key32 = InlineArray<32, UInt8>

/// The keys for one MACed (and, on encrypted profiles, encrypted) piece: HKDF's 80 bytes split into the HMAC key,
/// the AES-256 key, and the counter-mode IV. On profile 0 only the MAC key is used (the first 32 bytes of HKDF's
/// output are the same whatever its length).
struct DataKey: Sendable {
    var mac: Key32
    var cipher: Key32
    var iv: InlineArray<16, UInt8>

    /// Decrypts (or encrypts: the same) `bytes` in place with AES-256 in counter mode: CommonCrypto's 64-bit
    /// big-endian counter in the IV's last eight bytes.
    func crypt(_ bytes: inout MutableRawSpan) {
        let aes = AES(key: cipher.span.bytes)
        var counter = AES.Counter(bigEndian64BitCounterIn: iv.span.bytes)
        aes.counterMode(&bytes, counter: &counter)
    }

    /// Decrypts `input` into `output` (at least as long).
    func crypt(_ input: RawSpan, into output: inout MutableRawSpan) {
        let aes = AES(key: cipher.span.bytes)
        var counter = AES.Counter(bigEndian64BitCounterIn: iv.span.bytes)
        aes.counterMode(input, into: &output, counter: &counter)
    }

    /// Decrypts an array in place.
    func crypt(_ bytes: inout [UInt8]) {
        var span = bytes.mutableSpan
        var raw = MutableRawSpan(mutating: &span)
        crypt(&raw)
    }
}

/// An HKDF info string of the key schedule, held inline: an ASCII label (`"AEA_SK"`), optionally followed by a 32-bit
/// little-endian index. Deriving a key per segment allocates nothing.
struct KeyInfo {
    private var storage = InlineArray<16, UInt8>(repeating: 0)
    private var count = 0

    init(_ label: StaticString, index: UInt32? = nil) {
        precondition(label.utf8CodeUnitCount <= 12, "Key schedule labels are short")
        let bytes = unsafe UnsafeRawBufferPointer(start: label.utf8Start, count: label.utf8CodeUnitCount) // A static string's bytes: safe.
        for unsafe byte in unsafe bytes {
            storage[count] = byte
            count += 1
        }
        if let index {
            for shift in stride(from: 0, to: 32, by: 8) {
                storage[count] = UInt8(truncatingIfNeeded: index >> UInt32(shift))
                count += 1
            }
        }
    }

    /// Calls `body` with the info's bytes.
    func withBytes<R>(_ body: (RawSpan) -> R) -> R {
        body(storage.span.bytes.extracting(0..<count))
    }
}

/// HKDF-SHA256 from one input key with no salt, for deriving many keys from it (a cluster key's header key and its
/// segments' keys): the extract step done once, and the HMAC keyed with its result made once, where
/// `HKDF.expand` would key a new one per call.
typealias KeyExpander = HKDF<SHA256>.Expander

extension HKDF.Expander where H == SHA256 {
    /// The expander for `key` with no salt.
    init(_ key: Key32) {
        self.init(salt: RawSpan(), inputKeyMaterial: key.span.bytes)
    }
}

enum AEAKeys {
    /// HKDF-SHA256, 32 bytes of output.
    static func derive(_ inputKeyMaterial: RawSpan, salt: RawSpan, info: RawSpan) -> Key32 {
        var pseudorandom = Key32(repeating: 0)
        var prkSpan = pseudorandom.mutableSpan
        var prk = MutableRawSpan(mutating: &prkSpan)
        HKDF<SHA256>.extract(salt: salt, inputKeyMaterial: inputKeyMaterial, into: &prk)
        var output = Key32(repeating: 0)
        var outputSpan = output.mutableSpan
        var out = MutableRawSpan(mutating: &outputSpan)
        HKDF<SHA256>.expand(pseudorandomKey: pseudorandom.span.bytes, info: info, into: &out)
        return output
    }

    /// HKDF-SHA256 of `key` with no salt, 32 bytes.
    static func derive(_ key: Key32, _ info: KeyInfo) -> Key32 {
        info.withBytes { derive(key.span.bytes, salt: RawSpan(), info: $0) }
    }

    /// HKDF-SHA256 of `key` with no salt, 80 bytes: a MAC key, an AES key, and an IV.
    static func deriveDataKey(_ key: Key32, _ info: KeyInfo) -> DataKey {
        expandDataKey(KeyExpander(key), info)
    }

    /// HKDF-SHA256's expand step from `expander`'s key, 80 bytes: a MAC key, an AES key, and an IV.
    static func expandDataKey(_ expander: KeyExpander, _ info: KeyInfo) -> DataKey {
        var output = InlineArray<80, UInt8>(repeating: 0)
        var outputSpan = output.mutableSpan
        var out = MutableRawSpan(mutating: &outputSpan)
        info.withBytes { expander.expand(info: $0, into: &out) }
        var key = DataKey(mac: Key32(repeating: 0), cipher: Key32(repeating: 0), iv: InlineArray(repeating: 0))
        for index in 0..<32 {
            key.mac[index] = output[index]
            key.cipher[index] = output[32 + index]
        }
        for index in 0..<16 { key.iv[index] = output[64 + index] }
        return key
    }

    /// The main key:
    ///
    ///     HKDF(input, salt, "AEA_AMK" | profile word | sender's public key | recipient's public key | signing public key)
    ///
    /// with the public keys (X9.63, 65 bytes each) the profile has: the sender's ephemeral and the recipient's on
    /// profiles 3 and 4, the signer's on 0, 2, and 4. The input is the prologue's key material (profile 0), the
    /// symmetric key (1, 2), the ECDH shared secret (3, 4), or the scrypt-derived password key (5, whose salt is
    /// derived too).
    static func mainKey(
        _ prologue: AEAPrologue, input: RawSpan, salt: RawSpan, sender: [UInt8] = [], recipient: [UInt8] = [], signing: [UInt8] = []
    ) -> Key32 {
        var info = Array("AEA_AMK".utf8)
        info.append(prologue.profileWord, as: Byte4.self, .littleEndian)
        info += sender
        info += recipient
        info += signing
        return derive(input, salt: salt, info: info.span.bytes)
    }

    /// HMAC-SHA256(key, associated data | data | associated data's size), the archive's MAC.
    ///
    /// - Parameters:
    ///   - first, second: The associated data, in two pieces, MACed in order before `data`.
    static func mac(_ key: Key32, associatedData first: RawSpan = RawSpan(), _ second: RawSpan = RawSpan(), data: RawSpan) -> Key32 {
        var hmac = HMAC<SHA256>(key: key.span.bytes)
        hmac.update(first)
        hmac.update(second)
        let associatedCount = first.byteCount + second.byteCount
        hmac.update(data)
        Byte8(UInt64(associatedCount), .littleEndian).withBytes { hmac.update($0) }
        return finalize(&hmac)
    }

    /// The segment MAC: no associated data.
    static func segmentMAC(_ key: Key32, data: RawSpan) -> Key32 {
        mac(key, data: data)
    }

    static func finalize(_ hmac: inout HMAC<SHA256>) -> Key32 {
        var result = Key32(repeating: 0)
        var span = result.mutableSpan
        var bytes = MutableRawSpan(mutating: &span)
        hmac.finalize(into: &bytes)
        return result
    }

    /// Compares two MACs in constant time.
    static func equal(_ a: Key32, _ b: RawSpan) -> Bool {
        b.byteCount == 32 && constantTimeEquals(a.span.bytes, b)
    }
}
