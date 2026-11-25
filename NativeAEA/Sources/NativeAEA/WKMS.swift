import Bytes
import BytesBase64
import BytesCrypto
import Foundation
import System

/// The key of an iOS IPSW's encrypted disk image (`.dmg.aea`, profile 1), from its auth data.
///
/// The auth data's `com.apple.wkms.fcs-response` is JSON: `enc-request`, an HPKE encapsulated key (a P-256 point),
/// and `wrapped-key`, the archive's 32-byte key sealed to it (48 bytes with the tag). The private key that opens
/// it is published at `com.apple.wkms.fcs-key-url` (a PEM file). The suite is DHKEM(P-256, HKDF-SHA256), HKDF-SHA256,
/// AES-256-GCM, base mode, empty info (blacktop/ipsw's `pkg/aea`).
public enum WKMS {
    /// What a disk image's auth data holds.
    public struct Request: Sendable {
        /// Where the private key is published.
        public var keyURL: URL?
        public var encapsulatedKey: [UInt8]
        public var wrappedKey: [UInt8]
    }

    /// The request in an archive's auth data, or `nil` if it has none.
    public static func request(in prologue: AEAPrologue) throws(AEAError) -> Request? {
        guard let entries = prologue.authDataEntries,
              let response = entries.first(where: { $0.key == "com.apple.wkms.fcs-response" })
        else { return nil }
        // A strict JSON object of string members (JSON.swift, on Bytes' reader; Foundation's `JSONDecoder` before),
        // NUL-terminated in the auth data. Other members are ignored, as `JSONDecoder` ignored them.
        // Strict Base64 (BytesBase64): padded, unused bits zero. (Foundation's `Data(base64Encoded:)`, used before,
        // also took nonzero unused bits.)
        let json = Array(response.value.prefix { $0 != 0 })
        guard let members = try? JSON.stringMembers(json.span.bytes),
              let encRequest = members["enc-request"], let wrappedKey = members["wrapped-key"],
              let encapsulated = try? Base64.decodedBytes(encRequest),
              let wrapped = try? Base64.decodedBytes(wrappedKey)
        else { throw .invalidHeader("com.apple.wkms.fcs-response") }
        // Foundation's `URL(string:)` only checks and holds the address for `Request.keyURL` (its public type):
        // fetching is the caller's.
        let url = entries.first(where: { $0.key == "com.apple.wkms.fcs-key-url" })
            .flatMap { URL(string: String(decoding: $0.value.prefix { $0 != 0 }, as: UTF8.self)) }
        return Request(keyURL: url, encapsulatedKey: encapsulated, wrappedKey: wrapped)
    }

    /// Opens the wrapped key with the published private key (PEM).
    public static func key(_ request: Request, privateKeyPEM: String) throws(AEAError) -> AEADecryptionKey {
        guard let privateKey = try? P256.PrivateKey(pemRepresentation: privateKeyPEM) else {
            throw .missingKey("a P-256 private key (PEM) for the WKMS request")
        }
        // BytesCrypto's HPKE: DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM, empty info and associated data.
        guard var recipient = try? HPKE.Recipient(
            privateKey: privateKey, aead: .aes256GCM, info: RawSpan(), encapsulatedKey: request.encapsulatedKey.span.bytes
        ), let key = try? recipient.open(request.wrappedKey.span.bytes, authenticating: RawSpan())
        else { throw .missingKey("the private key that opens this archive's WKMS request") }
        return .symmetric(key)
    }
}

public extension AEAArchive {
    /// Reads an archive's prologue without opening it: its profile and auth data, to find what decrypts it.
    static func prologue(at path: FilePath) throws(AEAError) -> AEAPrologue {
        let file = try open(path)
        defer { file.close() }
        let fixed = try read(file, at: 0, count: AEAPrologue.fixedByteCount)
        let count = try AEAPrologue.byteCount(parsing: fixed.span.bytes)
        // A u32 size from the file: no allocation past what the file holds (`read` checks the file's size first).
        let bytes = try read(file, at: 0, count: count)
        return try AEAPrologue(parsing: bytes.span.bytes)
    }
}
