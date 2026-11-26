import Bytes
import BytesCrypto
import BytesTesting
import BytesTestSupport
import CryptoKit
import Foundation
import Testing

// HPKE: RFC 9180's test vectors for DHKEM(P-256, HKDF-SHA256) and HKDF-SHA256 in base mode (each AEAD: every
// encryption and export), CryptoKit both ways, a vector made with CryptoKit the way Apple's firmware archives wrap
// their keys, and, when one is at hand, a real archive's wrapped key.

typealias HPKE = BytesCrypto.HPKE

struct HPKEVector: Decodable {
    struct Encryption: Decodable {
        let aad, ct, nonce, pt: String
    }

    struct Export: Decodable {
        let exporter_context: String
        let L: Int
        let exported_value: String
    }

    let mode: Int
    let kem_id: Int
    let kdf_id: Int
    let aead_id: Int
    let info: String
    let ikmR, ikmE, skRm, skEm, pkRm, enc: String?
    let shared_secret, key, base_nonce, exporter_secret: String?
    let encryptions: [Encryption]?
    let exports: [Export]?
}

extension HPKE.Recipient {
    /// Opens ciphertext ‖ tag given as an array (`#expect` can't take spans).
    mutating func open(_ sealed: [UInt8], _ aad: [UInt8]) throws(BytesError) -> [UInt8] {
        try open(sealed.span.bytes, authenticating: aad.span.bytes)
    }
}

/// Unwraps an archive key as Apple's firmware archives do: HPKE base mode, AES-256-GCM, empty info and associated
/// data, `enc-request` the encapsulated key and `wrapped-key` the sealed key.
func unwrapArchiveKey(privateKeyPEM: String, encRequest: [UInt8], wrappedKey: [UInt8]) throws -> [UInt8] {
    let key = try P256.PrivateKey(pemRepresentation: privateKeyPEM)
    var recipient = try HPKE.Recipient(privateKey: key, aead: .aes256GCM, info: [UInt8]().span.bytes, encapsulatedKey: encRequest.span.bytes)
    return try recipient.open(wrappedKey, [])
}

@Suite struct HPKETests {
    @Test func rfc9180Vectors() throws {
        let data = try Data(contentsOf: TestData.file(set: "rfc9180", name: "test-vectors.json"))
        let vectors = try JSONDecoder().decode([HPKEVector].self, from: data)
        var tested = 0
        for vector in vectors where vector.mode == 0 && vector.kem_id == 0x10 && vector.kdf_id == 1 {
            guard let aead = HPKE.AEAD(rawValue: UInt16(vector.aead_id)) else { continue } // 0xFFFF: export-only.
            let info = hex(vector.info)
            // Optional in the schema (export-only and other modes leave some out), present in base mode.
            let ikmR = try hex(#require(vector.ikmR)), skRm = try hex(#require(vector.skRm)), pkRm = try hex(#require(vector.pkRm))
            let ikmE = try hex(#require(vector.ikmE)), skEm = try hex(#require(vector.skEm)), enc = try hex(#require(vector.enc))
            let baseNonce = try hex(#require(vector.base_nonce)), exporterSecret = try hex(#require(vector.exporter_secret))
            let encryptions = try #require(vector.encryptions), exports = try #require(vector.exports)
            // DeriveKeyPair for both keys.
            let recipientKey = try HPKE.deriveKey(from: ikmR.span.bytes)
            #expect(recipientKey.rawRepresentation == skRm)
            #expect(recipientKey.publicKey.x963Representation == pkRm)
            let ephemeral = try HPKE.deriveKey(from: ikmE.span.bytes)
            #expect(ephemeral.rawRepresentation == skEm)
            // The sender's encapsulation and key schedule.
            var sender = HPKE.Sender(recipientKey: recipientKey.publicKey, aead: aead, info: info.span.bytes, ephemeralKey: ephemeral)
            #expect(sender.encapsulatedKey == enc)
            #expect(sender.context.baseNonce.array == baseNonce)
            #expect(sender.context.exporterSecret.array == exporterSecret)
            var recipient = try HPKE.Recipient(privateKey: recipientKey, aead: aead, info: info.span.bytes, encapsulatedKey: enc.span.bytes)
            for (sequence, encryption) in encryptions.enumerated() {
                let aad = hex(encryption.aad), plaintext = hex(encryption.pt)
                let sealed = sender.seal(plaintext.span.bytes, authenticating: aad.span.bytes)
                #expect(sealed == hex(encryption.ct), "aead \(aead) #\(sequence)")
                #expect(try recipient.open(hex(encryption.ct), aad) == plaintext, "aead \(aead) #\(sequence)")
            }
            for export in exports {
                var secret = [UInt8](repeating: 0, count: export.L)
                var span = secret.mutableSpan
                var bytes = MutableRawSpan(mutating: &span)
                try recipient.exportSecret(context: hex(export.exporter_context).span.bytes, into: &bytes)
                #expect(secret == hex(export.exported_value))
            }
            tested += 1
        }
        #expect(tested == 3)
    }

    /// Against CryptoKit both ways, with fresh keys: rounds 0 and 1 here (round 0 has empty info, AAD, and first
    /// message), rounds 2 to 7 in `HPKEBulkTests`.
    @Test(arguments: HPKE.AEAD.allCases)
    func cryptoKit(aead: HPKE.AEAD) throws { try Self.cryptoKit(aead: aead, rounds: 0..<2) }

    static func cryptoKit(aead: HPKE.AEAD, rounds: Range<Int>) throws {
        let cryptoKitAEAD: CryptoKit.HPKE.AEAD = switch aead {
        case .aes128GCM: .AES_GCM_128
        case .aes256GCM: .AES_GCM_256
        case .chaCha20Poly1305: .chaChaPoly
        }
        let suite = CryptoKit.HPKE.Ciphersuite(kem: .P256_HKDF_SHA256, kdf: .HKDF_SHA256, aead: cryptoKitAEAD)
        for round in rounds {
            let info = [UInt8]((0..<(round * 5)).map { UInt8($0) })
            let aad = [UInt8]((0..<(round * 3)).map { UInt8($0 ^ 0x5A) })
            let messages = (0..<3).map { index in [UInt8]((0..<(round * 41 + index)).map { UInt8(truncatingIfNeeded: $0 &* 13) }) }
            // CryptoKit seals, Bytes opens.
            let cryptoKitKey = CryptoKit.P256.KeyAgreement.PrivateKey()
            var cryptoKitSender = try CryptoKit.HPKE.Sender(recipientKey: cryptoKitKey.publicKey, ciphersuite: suite, info: Data(info))
            let key = try P256.PrivateKey(rawRepresentation: Array(cryptoKitKey.rawRepresentation).span.bytes)
            var recipient = try HPKE.Recipient(privateKey: key, aead: aead, info: info.span.bytes,
                                               encapsulatedKey: Array(cryptoKitSender.encapsulatedKey).span.bytes)
            for message in messages {
                let sealed = try Array(cryptoKitSender.seal(Data(message), authenticating: Data(aad)))
                #expect(try recipient.open(sealed, aad) == message)
            }
            // Bytes seals, CryptoKit opens.
            var sender = HPKE.Sender(recipientKey: key.publicKey, aead: aead, info: info.span.bytes)
            var cryptoKitRecipient = try CryptoKit.HPKE.Recipient(privateKey: cryptoKitKey, ciphersuite: suite, info: Data(info),
                                                                  encapsulatedKey: Data(sender.encapsulatedKey))
            for message in messages {
                let sealed = sender.seal(message.span.bytes, authenticating: aad.span.bytes)
                #expect(try Array(cryptoKitRecipient.open(Data(sealed), authenticating: Data(aad))) == message)
            }
            // A tampered message, or one opened out of order, fails.
            let first = messages[0]
            var tampered = sender.seal(first.span.bytes, authenticating: aad.span.bytes)
            tampered[0] ^= 1
            var fresh = try HPKE.Recipient(privateKey: key, aead: aead, info: info.span.bytes, encapsulatedKey: sender.encapsulatedKey.span.bytes)
            #expect(throws: BytesError.mismatch) { _ = try fresh.open(tampered, aad) }
        }
    }

    /// RFC 9180, 5.2: a failed open doesn't advance the sequence, so the genuine message after a forged one opens.
    /// And the exporter takes any context length, rejecting only outputs over HKDF's limit.
    @Test func forgeriesDontDesynchronize() throws {
        let key = P256.PrivateKey()
        var sender = HPKE.Sender(recipientKey: key.publicKey, aead: .aes256GCM, info: [UInt8]().span.bytes)
        var recipient = try HPKE.Recipient(privateKey: key, aead: .aes256GCM, info: [UInt8]().span.bytes,
                                           encapsulatedKey: sender.encapsulatedKey.span.bytes)
        let messages: [[UInt8]] = [Array("first".utf8), Array("second".utf8)]
        let sealed = messages.map { sender.seal($0.span.bytes, authenticating: [UInt8]().span.bytes) }
        var forged = sealed[0]
        forged[2] ^= 0x80
        #expect(throws: BytesError.mismatch) { _ = try recipient.open(forged, []) }
        #expect(try recipient.open(sealed[0], []) == messages[0])
        #expect(try recipient.open(sealed[1], []) == messages[1])

        // A 1,000-byte exporter context (more than fits one block of labeled info), the same on both sides.
        let context = [UInt8]((0..<1_000).map { UInt8(truncatingIfNeeded: $0) })
        var one = [UInt8](repeating: 0, count: 100), two = [UInt8](repeating: 0, count: 100)
        var oneSpan = one.mutableSpan, twoSpan = two.mutableSpan
        var oneBytes = MutableRawSpan(mutating: &oneSpan), twoBytes = MutableRawSpan(mutating: &twoSpan)
        try sender.exportSecret(context: context.span.bytes, into: &oneBytes)
        try recipient.exportSecret(context: context.span.bytes, into: &twoBytes)
        #expect(one == two)
        #expect(one != [UInt8](repeating: 0, count: 100))
        var tooLong = [UInt8](repeating: 0, count: 255 * 32 + 1)
        var tooLongSpan = tooLong.mutableSpan
        var tooLongBytes = MutableRawSpan(mutating: &tooLongSpan)
        #expect(throws: BytesError.invalidValue) { try recipient.exportSecret(context: context.span.bytes, into: &tooLongBytes) }
    }

    /// Made with CryptoKit: a new P-256 key's PKCS #8 PEM, and a random 32-byte key sealed to it with `HPKE.Sender`
    /// (DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM, empty info and associated data), as Apple's firmware
    /// archives' `com.apple.wkms.fcs-response` entries are.
    @Test func archiveKeyVector() throws {
        let pem = """
        -----BEGIN PRIVATE KEY-----
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgcE2vf7sxF+/HeNyN
        7QF75EOxo9pkSXF3jx3Fy5CZRtyhRANCAATdKMblphdkxZBlfGtuGpOG/IqKtx6v
        7cRcC26oF1vXOtdVb+jJoxM6c0gJg8OeNV9kO8f5/EOwRszlvbq5FnGG
        -----END PRIVATE KEY-----
        """
        let enc = Array(Data(base64Encoded: "BGmvNnjp1oDWMOT995dPJ0lbRsedFZWafnMsoh77lN+5Y4u6p0sNGUbG90SppcR30mzzzWY44nV/qbsmSymYRfI=")!)
        let wrapped = Array(Data(base64Encoded: "cPM6htjgnNZd6xQ7Mi15BBW3tdvVcagQEBCfLNSa+XLVcGE7Yf50DPCkwma30x/I")!)
        let key = try unwrapArchiveKey(privateKeyPEM: pem, encRequest: enc, wrappedKey: wrapped)
        #expect(Data(key).base64EncodedString() == "ZIGckWI8dne7bMxiSoVb7zjwCPjDWo0b7DOuary9W0w=")
        // The wrong key fails to open it.
        #expect(throws: BytesError.mismatch) {
            _ = try unwrapArchiveKey(privateKeyPEM: CryptoKit.P256.KeyAgreement.PrivateKey().pemRepresentation, encRequest: enc, wrappedKey: wrapped)
        }
    }

    /// A real firmware archive's wrapped key, when `AEA_FCS_SAMPLE` names a directory holding one `.aea` file and an
    /// `fcs-keys.json` (a map from key name to Base64 PEM, as blacktop/ipsw keeps them) with its key; the expected
    /// key, `base64:…` as `aea` prints it, in `expected-key.txt`. Neither is checked in.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AEA_FCS_SAMPLE"] != nil))
    func realArchive() throws {
        let directory = try URL(filePath: #require(ProcessInfo.processInfo.environment["AEA_FCS_SAMPLE"]))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let archive = try #require(files.first { $0.pathExtension == "aea" })
        // The prologue: "AEA1", profile and scrypt strength (4 bytes), the auth data's size (u32, little-endian), then
        // entries of u32 size (including itself), a NUL-terminated key, and the value.
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let header = try #require(try handle.read(upToCount: 12))
        let authSize = Int(header[8]) | Int(header[9]) << 8 | Int(header[10]) << 16 | Int(header[11]) << 24
        let auth = try Array(#require(try handle.read(upToCount: authSize)))
        var entries: [String: [UInt8]] = [:]
        var offset = 0
        while offset + 4 <= auth.count {
            let size = Int(auth[offset]) | Int(auth[offset + 1]) << 8 | Int(auth[offset + 2]) << 16 | Int(auth[offset + 3]) << 24
            guard size > 4, offset + size <= auth.count else { break }
            let entry = auth[(offset + 4)..<(offset + size)]
            let nul = try #require(entry.firstIndex(of: 0))
            entries[String(decoding: entry[..<nul], as: UTF8.self)] = Array(entry[(nul + 1)...])
            offset += size
        }
        let response = try #require(entries["com.apple.wkms.fcs-response"])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(response)) as? [String: String])
        let encText = try #require(json["enc-request"]), wrappedText = try #require(json["wrapped-key"])
        let enc = try Array(#require(Data(base64Encoded: encText)))
        let wrapped = try Array(#require(Data(base64Encoded: wrappedText)))
        #expect(enc.count == 65 && wrapped.count == 48)
        // The key named by the key URL's last path component.
        let keyURL = try String(decoding: #require(entries["com.apple.wkms.fcs-key-url"]), as: UTF8.self)
        let keyName = try #require(URL(string: keyURL)).lastPathComponent
        let keys = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "fcs-keys.json"))) as? [String: String])
        let encodedPEM = try #require(keys.first { $0.key.caseInsensitiveCompare(keyName) == .orderedSame }?.value)
        let pem = try String(decoding: #require(Data(base64Encoded: encodedPEM)), as: UTF8.self)
        let key = try unwrapArchiveKey(privateKeyPEM: pem, encRequest: enc, wrappedKey: wrapped)
        let expected = try String(contentsOf: directory.appending(path: "expected-key.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect("base64:" + Data(key).base64EncodedString() == expected)
    }
}

/// The CryptoKit rounds `HPKETests` leaves out.
@Suite(.bulk) struct HPKEBulkTests {
    @Test(arguments: HPKE.AEAD.allCases)
    func cryptoKit(aead: HPKE.AEAD) throws { try HPKETests.cryptoKit(aead: aead, rounds: 2..<8) }
}
