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

enum AEAKeys {
    /// HKDF-SHA256, 32 bytes of output.
    static func derive(_ inputKeyMaterial: RawSpan, salt: RawSpan, info: [UInt8]) -> Key32 {
        var pseudorandom = Key32(repeating: 0)
        var prkSpan = pseudorandom.mutableSpan
        var prk = MutableRawSpan(mutating: &prkSpan)
        HKDF<SHA256>.extract(salt: salt, inputKeyMaterial: inputKeyMaterial, into: &prk)
        var output = Key32(repeating: 0)
        var outputSpan = output.mutableSpan
        var out = MutableRawSpan(mutating: &outputSpan)
        HKDF<SHA256>.expand(pseudorandomKey: pseudorandom.span.bytes, info: info.span.bytes, into: &out)
        return output
    }

    static func derive(_ key: Key32, info: [UInt8]) -> Key32 {
        derive(key.span.bytes, salt: RawSpan(), info: info)
    }

    static func info(_ label: String, index: UInt32) -> [UInt8] {
        var bytes = Array(label.utf8)
        withUnsafeBytes(of: index.littleEndian) { unsafe bytes.append(contentsOf: $0) } // Copies 4 bytes: safe.
        return bytes
    }

    /// The main key of a profile 0 archive.
    static func mainKey(_ prologue: AEAPrologue, signingPublicKey: [UInt8]) -> Key32 {
        var info = Array("AEA_AMK".utf8)
        withUnsafeBytes(of: prologue.profileWord.littleEndian) { unsafe info.append(contentsOf: $0) } // Copies 4 bytes: safe.
        info += signingPublicKey
        return derive(prologue.keyMaterial.span.bytes, salt: prologue.salt.span.bytes, info: info)
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
        let count = UInt64(associatedCount).littleEndian
        withUnsafeBytes(of: count) { unsafe hmac.update(RawSpan(_unsafeBytes: $0)) } // A local's 8 bytes, used in the closure: safe.
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
