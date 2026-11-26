import Bytes
import BytesCrypto
import BytesTesting
import BytesTestSupport
import Foundation
import Security
import Testing

// X.509 parsing: the system's root certificates, Apple's Xcode archive signing chain, and chains OpenSSL makes at
// test time, each field checked against OpenSSL's `x509` output and Security (signatures verified with the parsed
// key, so the to-be-signed bytes, algorithm, signature, and key are all right). Then strict DER, PEM, and inputs cut
// short or with bytes flipped, which must throw or parse, never trap.

/// Homebrew's OpenSSL, else the system's LibreSSL.
let opensslPath: String? = ExternalTool.locate("openssl")

/// The system's root certificates as PEM, from `security`; nil if it isn't available.
let systemRootsPEM: String? = (try? ExternalTool.output("/usr/bin/security", ["find-certificate", "-a", "-p", "/System/Library/Keychains/SystemRootCertificates.keychain"]))
    .map { String(decoding: $0, as: UTF8.self) }

/// The certificate chain in an Apple Encrypted Archive's authentication data: Xcode's beta archive, when it's here.
/// The header is `AEA1`, the profile, the data's size (UInt32, little-endian), then the data: entries of a UInt32
/// size (itself included), a NUL-terminated key, and the value.
let xcodeArchiveChainPEM: String? = {
    let path = NSString(string: "~/Scratch/Xcode_27.3_beta_2.aea").expandingTildeInPath
    guard let handle = FileHandle(forReadingAtPath: path), let header = try? handle.read(upToCount: 12), header.count == 12,
          header.prefix(4) == Data("AEA1".utf8) else { return nil }
    let size = header[8..<12].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
    guard let data = try? handle.read(upToCount: size), data.count == size else { return nil }
    let bytes = [UInt8](data)
    var offset = 0
    while offset + 4 <= bytes.count {
        let length = bytes[offset..<offset + 4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard length >= 4, offset + length <= bytes.count else { return nil }
        let entry = bytes[offset + 4..<offset + length]
        if let nul = entry.firstIndex(of: 0), String(decoding: entry[..<nul], as: UTF8.self) == "com.apple.ias.signature.certificate-chain" {
            return String(decoding: entry[(nul + 1)...], as: UTF8.self)
        }
        offset += length
    }
    return nil
}()

/// Certificates OpenSSL makes in a temporary directory: an ECDSA chain (P-384 root, P-256 intermediate and leaf),
/// an RSA leaf, and an RSA self-signed certificate, with the extensions the parser decodes.
struct GeneratedCertificates {
    let directory: URL
    /// Name → PEM file.
    var files: [String: URL] = [:]

    static let config = """
    [req]
    distinguished_name = dn
    [dn]
    [root]
    basicConstraints = critical, CA:TRUE, pathlen:1
    keyUsage = critical, keyCertSign, cRLSign
    subjectKeyIdentifier = hash
    [intermediate]
    basicConstraints = critical, CA:TRUE, pathlen:0
    keyUsage = critical, digitalSignature, keyCertSign, cRLSign
    extendedKeyUsage = codeSigning, 1.2.840.113635.100.4.13
    [leaf]
    basicConstraints = CA:FALSE
    keyUsage = critical, digitalSignature, keyAgreement, decipherOnly
    extendedKeyUsage = serverAuth, clientAuth, codeSigning, timeStamping
    subjectAltName = DNS:example.com, DNS:*.example.org
    1.2.3.4.5.6.7 = ASN1:UTF8String:custom value
    [rsa]
    basicConstraints = critical, CA:TRUE
    keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
    """

    init?() {
        guard let openssl = opensslPath else { return nil }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bytes-x509-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? Self.config.write(to: directory.appendingPathComponent("openssl.cnf"), atomically: true, encoding: .utf8)) != nil else { return nil }
        let steps: [[String]] = [
            ["ecparam", "-name", "secp384r1", "-genkey", "-noout", "-out", "root.key"],
            ["req", "-x509", "-new", "-key", "root.key", "-utf8", "-subj", "/C=US/O=Bytes Tests/CN=Bytes Tëst Root ✓", "-sha384",
             "-not_before", "20260101000000Z", "-not_after", "20520229235959Z", "-set_serial", "0x00FF00112233445566778899AABBCCDDEEFF00",
             "-config", "openssl.cnf", "-extensions", "root", "-out", "root.pem"],
            ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "intermediate.key"],
            ["req", "-new", "-key", "intermediate.key", "-subj", "/O=Bytes Tests/OU=Signing/CN=Bytes Test Intermediate", "-config", "openssl.cnf", "-out", "intermediate.csr"],
            ["x509", "-req", "-in", "intermediate.csr", "-CA", "root.pem", "-CAkey", "root.key", "-set_serial", "0x80", "-sha384",
             "-not_before", "20260601120000Z", "-not_after", "20491231235959Z", "-extfile", "openssl.cnf", "-extensions", "intermediate", "-out", "intermediate.pem"],
            ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "leaf.key"],
            ["req", "-new", "-key", "leaf.key", "-subj", "/CN=example.com", "-config", "openssl.cnf", "-out", "leaf.csr"],
            ["x509", "-req", "-in", "leaf.csr", "-CA", "intermediate.pem", "-CAkey", "intermediate.key", "-set_serial", "7", "-sha256",
             "-not_before", "19700101000000Z", "-not_after", "20500101000000Z", "-extfile", "openssl.cnf", "-extensions", "leaf", "-out", "leaf.pem"],
            ["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", "rsa.key"],
            ["req", "-new", "-key", "rsa.key", "-subj", "/CN=RSA Leaf", "-config", "openssl.cnf", "-out", "rsa-leaf.csr"],
            ["x509", "-req", "-in", "rsa-leaf.csr", "-CA", "intermediate.pem", "-CAkey", "intermediate.key", "-set_serial", "123456789", "-sha256",
             "-days", "30", "-extfile", "openssl.cnf", "-extensions", "leaf", "-out", "rsa-leaf.pem"],
            ["req", "-x509", "-new", "-key", "rsa.key", "-subj", "/CN=RSA Root", "-sha512", "-days", "30", "-config", "openssl.cnf",
             "-extensions", "rsa", "-out", "rsa-root.pem"],
        ]
        for step in steps {
            guard (try? ExternalTool.output(openssl, step, in: directory)) != nil else { return nil }
        }
        for name in ["root", "intermediate", "leaf", "rsa-leaf", "rsa-root"] {
            files[name] = directory.appendingPathComponent("\(name).pem")
        }
    }

    func der(_ name: String) throws -> [UInt8] {
        let text = try String(contentsOf: files[name]!, encoding: .utf8)
        return try #require(try X509Certificate.decodePEM(text).first)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// OpenSSL's view of a certificate, from its `x509` subcommand's output.
struct OpenSSLFields {
    var serialHex = ""
    var notBefore: Date?
    var notAfter: Date?
    var signatureAlgorithm = ""
    var curve: String?
    var subjectPublicKeyInfo: [UInt8] = []
    var basicConstraints: String?
    var keyUsage: String?
    var extendedKeyUsage: String?
    var subjectRFC2253 = ""

    init?(pem: String, openssl: String, scratch: URL) {
        let file = scratch.appendingPathComponent("certificate-\(UUID().uuidString).pem")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? pem.write(to: file, atomically: true, encoding: .utf8)) != nil,
              let output = try? ExternalTool.output(openssl, ["x509", "-in", file.path, "-noout", "-serial", "-startdate", "-enddate", "-subject", "-nameopt", "RFC2253,-esc_msb,utf8",
                                                              "-text", "-certopt", "no_header,no_version,no_serial,no_issuer,no_validity,no_subject,no_sigdump,no_aux"]),
              let key = try? ExternalTool.output(openssl, ["x509", "-in", file.path, "-noout", "-pubkey"]) else { return nil }
        let text = String(decoding: output, as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
        func date(_ value: String) -> Date? {
            formatter.date(from: value.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
        }
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            if line.hasPrefix("serial=") { serialHex = String(line.dropFirst(7)) }
            if line.hasPrefix("notBefore=") { notBefore = date(String(line.dropFirst(10))) }
            if line.hasPrefix("notAfter=") { notAfter = date(String(line.dropFirst(9))) }
            if line.hasPrefix("subject=") { subjectRFC2253 = String(line.dropFirst(8)) }
            if trimmed.hasPrefix("Signature Algorithm:") && signatureAlgorithm.isEmpty {
                signatureAlgorithm = trimmed.dropFirst("Signature Algorithm:".count).trimmingCharacters(in: .whitespaces)
            }
            if trimmed.hasPrefix("ASN1 OID:") { curve = trimmed.dropFirst("ASN1 OID:".count).trimmingCharacters(in: .whitespaces) }
            if trimmed.hasPrefix("X509v3 Basic Constraints") { basicConstraints = next }
            if trimmed.hasPrefix("X509v3 Key Usage") { keyUsage = next }
            if trimmed.hasPrefix("X509v3 Extended Key Usage") { extendedKeyUsage = next }
        }
        let keyText = String(decoding: key, as: UTF8.self)
        let base64 = keyText.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        subjectPublicKeyInfo = [UInt8](Data(base64Encoded: base64) ?? Data())
    }
}

/// OpenSSL's short names for the algorithms and curves the tests meet.
let opensslNames: [ASN1ObjectIdentifier: [String]] = [
    .ecdsaWithSHA256: ["ecdsa-with-SHA256"], .ecdsaWithSHA384: ["ecdsa-with-SHA384"], .ecdsaWithSHA512: ["ecdsa-with-SHA512"],
    .sha1WithRSAEncryption: ["sha1WithRSAEncryption"], .sha256WithRSAEncryption: ["sha256WithRSAEncryption"],
    .sha384WithRSAEncryption: ["sha384WithRSAEncryption"], .sha512WithRSAEncryption: ["sha512WithRSAEncryption"],
    .rsassaPSS: ["rsassaPss", "RSASSA-PSS"], .ed25519: ["ED25519"],
    .prime256v1: ["prime256v1"], .secp384r1: ["secp384r1"], .secp521r1: ["secp521r1"],
]

/// OpenSSL's names for the key usage bits, in bit order.
let keyUsageNames = ["Digital Signature", "Non Repudiation", "Key Encipherment", "Data Encipherment", "Key Agreement",
                     "Certificate Sign", "CRL Sign", "Encipher Only", "Decipher Only"]

/// OpenSSL's names for extended key usages.
let extendedKeyUsageNames: [ASN1ObjectIdentifier: String] = [
    .serverAuthentication: "TLS Web Server Authentication", .clientAuthentication: "TLS Web Client Authentication",
    .codeSigning: "Code Signing", .emailProtection: "E-mail Protection", .timeStamping: "Time Stamping", .ocspSigning: "OCSP Signing",
]

/// Security's algorithm for verifying a certificate signature, or nil for ones it can't (or the tests don't) check.
func securityAlgorithm(_ identifier: ASN1ObjectIdentifier) -> SecKeyAlgorithm? {
    switch identifier {
    case .ecdsaWithSHA256: .ecdsaSignatureMessageX962SHA256
    case .ecdsaWithSHA384: .ecdsaSignatureMessageX962SHA384
    case .ecdsaWithSHA512: .ecdsaSignatureMessageX962SHA512
    case .sha1WithRSAEncryption: .rsaSignatureMessagePKCS1v15SHA1
    case .sha256WithRSAEncryption: .rsaSignatureMessagePKCS1v15SHA256
    case .sha384WithRSAEncryption: .rsaSignatureMessagePKCS1v15SHA384
    case .sha512WithRSAEncryption: .rsaSignatureMessagePKCS1v15SHA512
    default: nil
    }
}

/// A Security key from a parsed certificate's public key bytes, for an EC (X9.63) or RSA (PKCS #1) key.
func securityKey(_ certificate: borrowing X509Certificate) -> SecKey? {
    let type: CFString
    if certificate.publicKeyAlgorithm == .ecPublicKey { type = kSecAttrKeyTypeECSECPrimeRandom }
    else if certificate.publicKeyAlgorithm == .rsaEncryption { type = kSecAttrKeyTypeRSA }
    else { return nil }
    let bytes = [UInt8](copying: certificate.publicKey)
    let attributes = [kSecAttrKeyType: type, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary
    return SecKeyCreateWithData(Data(bytes) as CFData, attributes, nil)
}

/// Whether `certificate`'s signature verifies with `issuer`'s parsed key; nil if the algorithm isn't one Security
/// checks here.
func verifies(_ certificate: borrowing X509Certificate, issuedBy issuer: borrowing X509Certificate) -> Bool? {
    guard let algorithm = securityAlgorithm(certificate.signatureAlgorithm), let key = securityKey(issuer) else { return nil }
    let tbs = Data([UInt8](copying: certificate.tbsCertificate))
    let signature = Data([UInt8](copying: certificate.signature))
    return SecKeyVerifySignature(key, algorithm, tbs as CFData, signature as CFData, nil)
}

/// Checks every field of `der` against OpenSSL's output and Security's parse of the same certificate.
func crossCheck(_ der: [UInt8], label: String, openssl: String, scratch: URL) throws {
    let certificate = try X509Certificate(derEncoded: der.span.bytes)
    #expect([UInt8](copying: certificate.der) == der)
    let base64 = Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    let pem = "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    let fields = try #require(OpenSSLFields(pem: pem, openssl: openssl, scratch: scratch), "\(label): openssl x509 failed")
    let secCertificate = try #require(SecCertificateCreateWithData(nil, Data(der) as CFData), "\(label): Security rejects it")

    // Serial number: OpenSSL prints the magnitude's hex; Security returns the contents.
    let serial = [UInt8](copying: certificate.serialNumber)
    #expect(Data(serial) == SecCertificateCopySerialNumberData(secCertificate, nil) as Data?, "\(label): serial")
    let serialHex = serial.drop { $0 == 0 }.map { String(format: "%02X", $0) }.joined()
    #expect(serialHex == fields.serialHex || (serialHex.isEmpty && fields.serialHex == "00"), "\(label): serial \(serialHex) vs \(fields.serialHex)")

    // Validity.
    #expect(fields.notBefore?.timeIntervalSince1970 == TimeInterval(certificate.notBefore.secondsSince1970), "\(label): notBefore \(certificate.notBefore)")
    #expect(fields.notAfter?.timeIntervalSince1970 == TimeInterval(certificate.notAfter.secondsSince1970), "\(label): notAfter \(certificate.notAfter)")
    #expect(SecCertificateCopyNotValidBeforeDate(secCertificate).map { ($0 as Date).timeIntervalSince1970 } == TimeInterval(certificate.notBefore.secondsSince1970))
    #expect(SecCertificateCopyNotValidAfterDate(secCertificate).map { ($0 as Date).timeIntervalSince1970 } == TimeInterval(certificate.notAfter.secondsSince1970))

    // Algorithms and the key.
    if let names = opensslNames[certificate.signatureAlgorithm] {
        #expect(names.contains(fields.signatureAlgorithm), "\(label): \(certificate.signatureAlgorithm) vs \(fields.signatureAlgorithm)")
    } else {
        Issue.record("\(label): unexpected signature algorithm \(certificate.signatureAlgorithm) (\(fields.signatureAlgorithm))")
    }
    #expect([UInt8](copying: certificate.subjectPublicKeyInfo) == fields.subjectPublicKeyInfo, "\(label): SubjectPublicKeyInfo")
    if certificate.publicKeyAlgorithm == .ecPublicKey {
        let curve = certificate.namedCurve
        #expect(curve.flatMap { opensslNames[$0] }?.contains(fields.curve ?? "") == true,
                "\(label): curve \(curve?.description ?? "none") vs \(fields.curve ?? "none")")
        #expect(certificate.publicKey.byteCount > 0 && certificate.publicKey.byteOffsetLoad(0) == 0x04, "\(label): uncompressed point")
    } else {
        #expect(certificate.namedCurve == nil)
    }
    if let key = SecCertificateCopyKey(secCertificate), let external = SecKeyCopyExternalRepresentation(key, nil) {
        #expect([UInt8](copying: certificate.publicKey) == [UInt8](external as Data), "\(label): public key")
    }

    // Names: the common name as Security reads it, and in OpenSSL's RFC 2253 subject.
    var commonName: CFString?
    SecCertificateCopyCommonName(secCertificate, &commonName)
    #expect(certificate.subject.commonName == commonName as String?, "\(label): common name")
    if let name = certificate.subject.commonName {
        #expect(fields.subjectRFC2253.contains("CN=" + name.replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "+", with: "\\+")),
                "\(label): \(name) in \(fields.subjectRFC2253)")
    }
    var attributeCount = 0
    var attributes = certificate.subject.attributes
    while let attribute = attributes.next() {
        attributeCount += 1
        _ = attribute.type.description
    }
    #expect(attributeCount > 0 || fields.subjectRFC2253.isEmpty, "\(label): subject attributes")

    // Extensions.
    if let constraints = certificate.basicConstraints {
        var expected = constraints.isCertificateAuthority ? "CA:TRUE" : "CA:FALSE"
        if let length = constraints.pathLengthConstraint { expected += ", pathlen:\(length)" }
        #expect(fields.basicConstraints == expected, "\(label): basic constraints \(expected) vs \(fields.basicConstraints ?? "none")")
    } else {
        #expect(fields.basicConstraints == nil, "\(label): basic constraints")
    }
    if let usage = certificate.keyUsage {
        let names = keyUsageNames.enumerated().filter { usage.rawValue & (1 << $0.offset) != 0 }.map(\.element)
        #expect(fields.keyUsage == names.joined(separator: ", "), "\(label): key usage \(names) vs \(fields.keyUsage ?? "none")")
    } else {
        #expect(fields.keyUsage == nil, "\(label): key usage")
    }
    if var usages = certificate.extendedKeyUsage {
        var names: [String] = []
        while let usage = usages.next() {
            names.append(extendedKeyUsageNames[usage] ?? usage.description)
        }
        #expect(fields.extendedKeyUsage == names.joined(separator: ", "), "\(label): extended key usage \(names) vs \(fields.extendedKeyUsage ?? "none")")
    } else {
        #expect(fields.extendedKeyUsage == nil, "\(label): extended key usage")
    }
    var extensionCount = 0
    var extensions = certificate.extensions
    while let item = extensions.next() {
        extensionCount += 1
        #expect(certificate.extension(item.identifier)?.value.byteCount == item.value.byteCount)
    }
    #expect(certificate.version == 3 || extensionCount == 0)

    // Self-signed roots: the signature verifies with the certificate's own key.
    if certificate.isSelfIssued, let verified = verifies(certificate, issuedBy: certificate) {
        #expect(verified, "\(label): self-signature")
    }
}

@Suite struct X509Tests {
    /// Every system root parses, and over 100 are self-signed (by Security, with the parsed key); one root of each
    /// kind (`systemRootSample`) is checked field by field against OpenSSL and Security. `X509BulkTests` checks every
    /// root against them.
    @Test(.enabled(if: systemRootsPEM != nil && opensslPath != nil)) func systemRootCertificates() throws {
        let roots = try X509Certificate.decodePEM(#require(systemRootsPEM))
        #expect(roots.count > 100)
        var selfSigned = 0
        for (index, der) in roots.enumerated() {
            do {
                let certificate = try X509Certificate(derEncoded: der.span.bytes)
                if certificate.isSelfIssued, verifies(certificate, issuedBy: certificate) == true { selfSigned += 1 }
            } catch {
                Issue.record("root \(index): \(error)")
            }
        }
        #expect(selfSigned > 100)
        try Self.crossCheckRoots(systemRootSample)
        try Self.checkAppleRootCAG3(roots)
    }

    /// Each root against OpenSSL's and Security's reading of it (`crossCheck`), returning how many are self-signed.
    @discardableResult
    static func crossCheckRoots(_ roots: [[UInt8]]) throws -> Int {
        let directory = try TemporaryDirectory(prefix: "bytes-x509-roots")
        defer { directory.remove() }
        let scratch = directory.url
        var selfSigned = 0
        for (index, der) in roots.enumerated() {
            let label = "root \(index)"
            do {
                try crossCheck(der, label: label, openssl: opensslPath!, scratch: scratch)
                let certificate = try X509Certificate(derEncoded: der.span.bytes)
                if certificate.isSelfIssued, verifies(certificate, issuedBy: certificate) == true { selfSigned += 1 }
            } catch {
                Issue.record("\(label): \(error)")
            }
        }
        return selfSigned
    }

    /// Apple Root CA - G3's fields.
    static func checkAppleRootCAG3(_ roots: [[UInt8]]) throws {
        // Apple Root CA - G3: ECDSA with SHA-384 on P-384.
        let g3 = roots.first { der in (try? X509Certificate(derEncoded: der.span.bytes))?.subject.commonName == "Apple Root CA - G3" }
        let g3Bytes = try #require(g3)
        let certificate = try X509Certificate(derEncoded: g3Bytes.span.bytes)
        #expect(certificate.signatureAlgorithm == .ecdsaWithSHA384)
        #expect(certificate.namedCurve == .secp384r1)
        #expect(certificate.publicKey.byteCount == 97)
        #expect(certificate.basicConstraints == X509BasicConstraints(isCertificateAuthority: true, pathLengthConstraint: nil))
        #expect(certificate.keyUsage == [.keyCertSign, .cRLSign])
        #expect(certificate.subject.first(.organizationName)?.string == "Apple Inc.")
    }

    @Test(.enabled(if: xcodeArchiveChainPEM != nil)) func xcodeArchiveChain() throws {
        let chain = try X509Certificate.decodePEM(#require(xcodeArchiveChainPEM))
        try #require(chain.count == 3)
        let leafDER = chain[0], intermediateDER = chain[1], rootDER = chain[2]
        let leaf = try X509Certificate(derEncoded: leafDER.span.bytes)
        let intermediate = try X509Certificate(derEncoded: intermediateDER.span.bytes)
        let root = try X509Certificate(derEncoded: rootDER.span.bytes)
        // Each is issued by the next: names match byte for byte, and signatures verify with the parsed keys.
        let leafIssuedByIntermediate = leaf.issuer.der.equals(intermediate.subject.der)
        #expect(leafIssuedByIntermediate)
        let intermediateIssuedByRoot = intermediate.issuer.der.equals(root.subject.der)
        #expect(intermediateIssuedByRoot)
        let rootSelfIssued = root.isSelfIssued
        #expect(rootSelfIssued)
        #expect(verifies(leaf, issuedBy: intermediate) == true)
        #expect(verifies(intermediate, issuedBy: root) == true)
        #expect(verifies(root, issuedBy: root) == true)
        #expect(root.subject.commonName == "Apple Root CA - G3")
        #expect(intermediate.basicConstraints?.isCertificateAuthority == true)
        #expect(leaf.basicConstraints?.isCertificateAuthority != true)
        #expect(leaf.namedCurve != nil)
        // The root is the system's.
        if let roots = systemRootsPEM.flatMap({ try? X509Certificate.decodePEM($0) }) {
            #expect(roots.contains(chain[2]))
        }
        if let openssl = opensslPath {
            let directory = try TemporaryDirectory(prefix: "bytes-x509-xcode")
            defer { directory.remove() }
            let scratch = directory.url
            for (index, der) in chain.enumerated() {
                try crossCheck(der, label: "Xcode chain \(index)", openssl: openssl, scratch: scratch)
            }
        }
    }

    @Test(.enabled(if: opensslPath != nil)) func generatedCertificates() throws {
        let generated = try #require(GeneratedCertificates(), "openssl couldn't make the test certificates")
        defer { generated.remove() }
        for name in generated.files.keys.sorted() {
            try crossCheck(generated.der(name), label: name, openssl: opensslPath!, scratch: generated.directory)
        }
        let rootDER = try generated.der("root"), intermediateDER = try generated.der("intermediate"), leafDER = try generated.der("leaf")
        let rsaLeafDER = try generated.der("rsa-leaf"), rsaRootDER = try generated.der("rsa-root")
        let root = try X509Certificate(derEncoded: rootDER.span.bytes)
        let intermediate = try X509Certificate(derEncoded: intermediateDER.span.bytes)
        let leaf = try X509Certificate(derEncoded: leafDER.span.bytes)
        let rsaLeaf = try X509Certificate(derEncoded: rsaLeafDER.span.bytes)
        let rsaRoot = try X509Certificate(derEncoded: rsaRootDER.span.bytes)

        #expect(root.version == 3)
        #expect(root.subject.commonName == "Bytes Tëst Root ✓")
        #expect(root.subject.first(.countryName)?.string == "US")
        #expect(root.subject.first(.countryName)?.valueTag == .printableString)
        #expect(root.signatureAlgorithm == .ecdsaWithSHA384 && root.signatureAlgorithmParameters == nil)
        #expect(root.namedCurve == .secp384r1 && root.publicKey.byteCount == 97)
        #expect([UInt8](copying: root.serialNumber) == hex("00ff00112233445566778899aabbccddeeff00"))
        #expect(root.notBefore == X509Time(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0))
        // 2052: a GeneralizedTime, on a leap day.
        #expect(root.notAfter == X509Time(year: 2052, month: 2, day: 29, hour: 23, minute: 59, second: 59))
        #expect(root.basicConstraints == X509BasicConstraints(isCertificateAuthority: true, pathLengthConstraint: 1))
        #expect(root.keyUsage == [.keyCertSign, .cRLSign])
        let rootHasExtendedKeyUsage = root.extendedKeyUsage != nil
        #expect(!rootHasExtendedKeyUsage)
        #expect(root.extension(.subjectKeyIdentifier)?.isCritical == false)
        #expect(root.extension(.basicConstraints)?.isCritical == true)
        let rootSelfIssued = root.isSelfIssued
        #expect(rootSelfIssued)

        #expect([UInt8](copying: intermediate.serialNumber) == [0x00, 0x80])
        #expect(intermediate.notAfter == X509Time(year: 2049, month: 12, day: 31, hour: 23, minute: 59, second: 59))
        #expect(intermediate.subject.first(.organizationalUnitName)?.string == "Signing")
        #expect(intermediate.basicConstraints == X509BasicConstraints(isCertificateAuthority: true, pathLengthConstraint: 0))
        #expect(intermediate.keyUsage == [.digitalSignature, .keyCertSign, .cRLSign])
        let appleUsage = try ASN1ObjectIdentifier("1.2.840.113635.100.4.13")
        if var purposes = intermediate.extendedKeyUsage {
            #expect(purposes.next() == .codeSigning)
            #expect(purposes.next() == appleUsage)
            #expect(purposes.next() == nil)
        } else {
            Issue.record("intermediate: no extended key usage")
        }
        let intermediateIssuedByRoot = intermediate.issuer.der.equals(root.subject.der)
        #expect(intermediateIssuedByRoot)
        let intermediateSelfIssued = intermediate.isSelfIssued
        #expect(!intermediateSelfIssued)
        #expect(verifies(intermediate, issuedBy: root) == true)

        #expect(leaf.notBefore.secondsSince1970 == 0)
        #expect(leaf.notAfter == X509Time(year: 2050, month: 1, day: 1, hour: 0, minute: 0, second: 0))
        #expect(leaf.basicConstraints == X509BasicConstraints(isCertificateAuthority: false, pathLengthConstraint: nil))
        #expect(leaf.keyUsage == [.digitalSignature, .keyAgreement, .decipherOnly])
        if let leafPurposes = leaf.extendedKeyUsage {
            #expect(leafPurposes.contains(.serverAuthentication) && leafPurposes.contains(.timeStamping) && !leafPurposes.contains(.emailProtection))
        } else {
            Issue.record("leaf: no extended key usage")
        }
        let customIdentifier = try ASN1ObjectIdentifier("1.2.3.4.5.6.7")
        if let custom = leaf.extension(customIdentifier) {
            let customIsCritical = custom.isCritical
            #expect(!customIsCritical)
            #expect([UInt8](copying: custom.value) == [0x0C, 0x0C] + Array("custom value".utf8))
        } else {
            Issue.record("leaf: no custom extension")
        }
        let hasAlternativeName = leaf.extension(.subjectAlternativeName) != nil
        #expect(hasAlternativeName)
        let hasPolicies = leaf.extension(.certificatePolicies) != nil
        #expect(!hasPolicies)
        #expect(verifies(leaf, issuedBy: intermediate) == true)
        #expect(verifies(leaf, issuedBy: root) == false)

        #expect(rsaLeaf.publicKeyAlgorithm == .rsaEncryption)
        #expect(bytes(rsaLeaf.publicKeyParameters) == [0x05, 0x00])
        #expect(rsaLeaf.signatureAlgorithm == .ecdsaWithSHA256)
        #expect(verifies(rsaLeaf, issuedBy: intermediate) == true)
        #expect(rsaRoot.signatureAlgorithm == .sha512WithRSAEncryption)
        #expect(bytes(rsaRoot.signatureAlgorithmParameters) == [0x05, 0x00])
        #expect(rsaRoot.basicConstraints == X509BasicConstraints(isCertificateAuthority: true, pathLengthConstraint: nil))
        #expect(rsaRoot.keyUsage == [.digitalSignature, .nonRepudiation, .keyEncipherment, .dataEncipherment])
        #expect(verifies(rsaRoot, issuedBy: rsaRoot) == true)
    }

    /// Every prefix of real certificates throws; random byte flips throw or parse, and whatever parses can be read
    /// in full. Nothing traps.
    @Test func truncationsAndFlips() throws {
        var samples: [[UInt8]] = []
        if let generated = GeneratedCertificates() {
            defer { generated.remove() }
            for name in generated.files.keys.sorted() {
                try samples.append(generated.der(name))
            }
        }
        if let roots = systemRootsPEM.flatMap({ try? X509Certificate.decodePEM($0) }) { samples += roots.prefix(8) }
        if let chain = xcodeArchiveChainPEM.flatMap({ try? X509Certificate.decodePEM($0) }) { samples += chain }
        try #require(!samples.isEmpty, "no certificates to mutate (needs openssl, the system roots, or the Xcode archive)")
        var rng = SplitMix64(seed: 5280)
        var parsedAfterFlip = 0
        for sample in samples {
            _ = try X509Certificate(derEncoded: sample.span.bytes)
            for length in 0..<sample.count {
                #expect(throws: BytesError.self) { _ = try X509Certificate(derEncoded: sample.span.bytes.extracting(0..<length)) }
            }
            #expect(throws: BytesError.trailingData) { _ = try X509Certificate(derEncoded: (sample + [0]).span.bytes) }
            for _ in 0..<2_000 {
                var mutated = sample
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    let index = Int.random(in: 0..<mutated.count, using: &rng)
                    // Half the time a single bit, otherwise any byte; lengths and tags are early, so bias toward them.
                    let position = Bool.random(using: &rng) ? index : index % min(mutated.count, 64)
                    if Bool.random(using: &rng) {
                        mutated[position] ^= 1 << UInt8.random(in: 0...7, using: &rng)
                    } else {
                        mutated[position] = UInt8.random(in: 0...255, using: &rng)
                    }
                }
                if let certificate = try? X509Certificate(derEncoded: mutated.span.bytes) {
                    parsedAfterFlip += 1
                    exercise(certificate)
                }
            }
        }
        #expect(parsedAfterFlip > 0)
    }

    @Test func strictDER() throws {
        func element(_ bytes: [UInt8]) throws(BytesError) -> ASN1Element {
            var reader = AlignedBytesReader(bytes.span.bytes)
            return try reader.readASN1Element()
        }
        #expect(try element([0x04, 0x02, 0xAA, 0xBB]) == ASN1Element(tag: .octetString, range: 0..<4, contents: 2..<4))
        #expect(try element([0x30, 0x81, 0x80] + [UInt8](repeating: 0, count: 128)).contents == 3..<131)
        #expect(try element([0x04, 0x82, 0x01, 0x00] + [UInt8](repeating: 0, count: 256)).contents == 4..<260)
        #expect(throws: BytesError.invalidValue) { _ = try element([0x30, 0x80, 0x00, 0x00]) } // Indefinite.
        #expect(throws: BytesError.invalidValue) { _ = try element([0x04, 0x81, 0x05, 1, 2, 3, 4, 5]) } // Long form below 128.
        #expect(throws: BytesError.invalidValue) { _ = try element([0x04, 0x82, 0x00, 0x80] + [UInt8](repeating: 0, count: 128)) } // Leading zero.
        #expect(throws: BytesError.invalidValue) { _ = try element([0x04, 0x85, 0, 0, 0, 0, 1, 0]) } // Five length bytes.
        #expect(throws: BytesError.invalidValue) { _ = try element([0x1F, 0x81, 0x00, 0x00]) } // High tag number.
        #expect(throws: BytesError.insufficientData) { _ = try element([0x04, 0x03, 1, 2]) }
        #expect(throws: BytesError.insufficientData) { _ = try element([0x04, 0x82, 0x01]) }
        #expect(throws: BytesError.insufficientData) { _ = try element([0x04]) }
        #expect(throws: BytesError.insufficientData) { _ = try element([0x04, 0x84, 0xFF, 0xFF, 0xFF, 0xFF]) }
        var reader = AlignedBytesReader([UInt8]([0x02, 0x01, 0x05]).span.bytes)
        #expect(throws: BytesError.mismatch) { _ = try reader.readASN1Element(.octetString) }
        #expect(reader.byteOffset == 0)
        #expect(try reader.readASN1Element(.integer).contents == 2..<3)

        // Times.
        func time(_ text: String, _ tag: ASN1Tag) throws(BytesError) -> X509Time {
            try X509Time(contents: Array(text.utf8).span.bytes, tag: tag)
        }
        #expect(try time("491231235959Z", .utcTime) == X509Time(year: 2049, month: 12, day: 31, hour: 23, minute: 59, second: 59))
        #expect(try time("500101000000Z", .utcTime).year == 1950)
        #expect(try time("20000229000000Z", .generalizedTime).secondsSince1970 == 951_782_400)
        #expect(try time("19691231235959Z", .generalizedTime).secondsSince1970 == -1)
        for (text, tag) in [("4912312359Z", ASN1Tag.utcTime), ("491231235959", .utcTime), ("491231235959+0000", .utcTime),
                            ("20491231235959.5Z", .generalizedTime), ("21000229000000Z", .generalizedTime), ("20491301000000Z", .generalizedTime),
                            ("20490431000000Z", .generalizedTime), ("20491231240000Z", .generalizedTime), ("2049123123595AZ", .generalizedTime),
                            ("491231235959Z", .generalizedTime), ("20491231235959Z", .octetString), ("20491231235960Z", .generalizedTime)] {
            #expect(throws: BytesError.invalidValue, "\(text)") { _ = try time(text, tag) }
        }

        // Object identifiers.
        let ecdsa = try ASN1ObjectIdentifier("1.2.840.10045.4.3.2")
        #expect(ecdsa == .ecdsaWithSHA256)
        #expect(ecdsa.description == "1.2.840.10045.4.3.2")
        #expect([UInt8](copying: ecdsa.contents) == [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        #expect(try ASN1ObjectIdentifier("2.999.18446744073709551615").description == "2.999.18446744073709551615")
        #expect(ASN1ObjectIdentifier.secp384r1.description == "1.3.132.0.34")
        #expect(Set([ASN1ObjectIdentifier.prime256v1, .prime256v1, .secp384r1]).count == 2)
        for bad in ["", "1", "3.1", "1.40", "1..2", "1.2.a", " 1.2"] {
            #expect(throws: BytesError.invalidValue, "\(bad)") { _ = try ASN1ObjectIdentifier(bad) }
        }
        for bad: [UInt8] in [[], [0x2A, 0x80, 0x01], [0x2A, 0x86], [UInt8](repeating: 0x01, count: 64)] {
            #expect(throws: BytesError.invalidValue) { _ = try ASN1ObjectIdentifier(contents: bad.span.bytes) }
        }
    }

    /// Certificates built by hand around one malformed field each, which must be rejected.
    @Test func rejectsMalformedFields() throws {
        func tlv(_ tag: UInt8, _ contents: [UInt8]) -> [UInt8] {
            let length: [UInt8] = if contents.count < 128 { [UInt8(contents.count)] }
            else if contents.count < 256 { [0x81, UInt8(contents.count)] }
            else { [0x82, UInt8(contents.count >> 8), UInt8(contents.count & 0xFF)] }
            return [tag] + length + contents
        }
        let algorithm = tlv(0x30, tlv(0x06, [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        let name = tlv(0x30, tlv(0x31, tlv(0x30, tlv(0x06, [0x55, 0x04, 0x03]) + tlv(0x0C, Array("Test".utf8)))))
        let validity = tlv(0x30, tlv(0x17, Array("260101000000Z".utf8)) + tlv(0x17, Array("270101000000Z".utf8)))
        let key = tlv(0x30, tlv(0x30, tlv(0x06, [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]) + tlv(0x06, [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]))
            + tlv(0x03, [0x00, 0x04] + [UInt8](repeating: 1, count: 64)))
        func certificate(version: [UInt8] = tlv(0xA0, tlv(0x02, [0x02])), serial: [UInt8] = tlv(0x02, [0x01]), innerAlgorithm: [UInt8]? = nil,
                         validity: [UInt8] = validity, extensions: [[UInt8]] = [], signature: [UInt8] = tlv(0x03, [0x00, 0x30, 0x00])) -> [UInt8] {
            var tbs = version + serial + (innerAlgorithm ?? algorithm) + name + validity + name + key
            if !extensions.isEmpty { tbs += tlv(0xA3, tlv(0x30, extensions.flatMap(\.self))) }
            return tlv(0x30, tlv(0x30, tbs) + algorithm + signature)
        }
        func parses(_ der: [UInt8]) -> Bool { (try? X509Certificate(derEncoded: der.span.bytes)) != nil }
        let basic = tlv(0x30, tlv(0x06, [0x55, 0x1D, 0x13]) + tlv(0x01, [0xFF]) + tlv(0x04, tlv(0x30, tlv(0x01, [0xFF]) + tlv(0x02, [0x03]))))
        let usage = tlv(0x30, tlv(0x06, [0x55, 0x1D, 0x0F]) + tlv(0x04, tlv(0x03, [0x07, 0x80])))

        let good = certificate(extensions: [basic, usage])
        let parsed = try X509Certificate(derEncoded: good.span.bytes)
        #expect(parsed.basicConstraints == X509BasicConstraints(isCertificateAuthority: true, pathLengthConstraint: 3))
        #expect(parsed.keyUsage == .digitalSignature)
        #expect(parsed.subject.commonName == "Test")
        #expect(parses(certificate(version: []))) // v1, no extensions.
        #expect(!parses(certificate(version: tlv(0xA0, tlv(0x02, [0x00]))))) // v1 written out (the default).
        #expect(!parses(certificate(extensions: [tlv(0x30, tlv(0x06, [0x55, 0x1D, 0x0E]) + tlv(0x01, [0x00]) + tlv(0x04, tlv(0x04, [1])))]))) // critical FALSE.
        #expect(!parses(certificate(extensions: [tlv(0x30, tlv(0x06, [0x55, 0x1D, 0x13]) + tlv(0x04, tlv(0x30, tlv(0x01, [0x00]))))]))) // cA FALSE.
        #expect(parses(certificate(extensions: [tlv(0x30, tlv(0x06, [0x55, 0x1D, 0x13]) + tlv(0x04, tlv(0x30, [])))]))) // Neither: an end entity.

        #expect(!parses(certificate(version: [], extensions: [basic]))) // Extensions in v1.
        #expect(!parses(certificate(version: tlv(0xA0, tlv(0x02, [0x03]))))) // Version 4.
        #expect(!parses(certificate(version: tlv(0xA0, tlv(0x02, [0x00, 0x02]))))) // Non-minimal integer.
        #expect(!parses(certificate(serial: tlv(0x02, [])))) // Empty integer.
        #expect(!parses(certificate(serial: tlv(0x02, [0xFF, 0x80])))) // Non-minimal negative.
        #expect(!parses(certificate(innerAlgorithm: tlv(0x30, tlv(0x06, [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03]))))) // Mismatch.
        #expect(!parses(certificate(validity: tlv(0x30, tlv(0x17, Array("260101000000Z".utf8)))))) // One time.
        #expect(!parses(certificate(extensions: [basic, basic]))) // Duplicate.
        // At most 64 extensions (more took quadratic time before the signature was checked); duplicates found among all.
        func unknown(_ n: Int) -> [UInt8] { tlv(0x30, tlv(0x06, [0x2A, 0x03, UInt8(n)]) + tlv(0x04, [0x05, 0x00])) }
        #expect(parses(certificate(extensions: (0..<64).map(unknown))))
        #expect(!parses(certificate(extensions: (0..<65).map(unknown))))
        #expect(!parses(certificate(extensions: (0..<63).map(unknown) + [unknown(0)]))) // First and 64th.
        #expect(!parses(certificate(extensions: [tlv(0x30, tlv(0x06, [0x55, 0x1D, 0x13]) + tlv(0x01, [0x01]) + tlv(0x04, tlv(0x30, [])))]))) // BOOLEAN 01.
        #expect(!parses(certificate(extensions: [tlv(0x30, tlv(0x06, [0x55, 0x1D, 0x0F]) + tlv(0x04, tlv(0x03, [0x07, 0x81])))]))) // Padding bits set.
        #expect(!parses(certificate(extensions: [tlv(0x30, tlv(0x06, [0x55, 0x1D, 0x13]) + tlv(0x04, tlv(0x30, tlv(0x02, [0xFF]))))]))) // Negative path length.
        #expect(!parses(certificate(extensions: [tlv(0x30, tlv(0x06, [0x55, 0x1D, 0x25]) + tlv(0x04, tlv(0x30, [])))]))) // Empty EKU.
        #expect(!parses(certificate(extensions: [tlv(0x30, tlv(0x06, [0x55, 0x1D, 0x13]) + tlv(0x04, tlv(0x30, []) + [0x00]))]))) // Trailing.
        #expect(!parses(certificate(signature: tlv(0x03, [0x01, 0x30, 0x00])))) // Signature with unused bits.
        #expect(!parses(certificate(signature: tlv(0x04, [0x30, 0x00])))) // Not a bit string.
    }

    @Test func pem() throws {
        let one: [UInt8] = [0x30, 0x03, 0x02, 0x01, 0x07]
        let two = [UInt8](0..<200)
        func block(_ bytes: [UInt8], label: String = "CERTIFICATE") -> String {
            "-----BEGIN \(label)-----\n" + Data(bytes).base64EncodedString(options: .lineLength64Characters) + "\n-----END \(label)-----\n"
        }
        let text = "Subject: one\n" + block(one) + "\nbetween\r\n" + block([9, 9], label: "PRIVATE KEY") + block(two).replacingOccurrences(of: "\n", with: "\r\n") + "trailer"
        #expect(try X509Certificate.decodePEM(text) == [one, two])
        #expect(try X509Certificate.decodePEM("no blocks here") == [])
        #expect(try X509Certificate.decodePEM(block([1])) == [[1]])
        #expect(try X509Certificate.decodePEM(block([1, 2])) == [[1, 2]])
        for bad in ["-----BEGIN CERTIFICATE-----\nAQ=\n-----END CERTIFICATE-----", // Short padding.
                    "-----BEGIN CERTIFICATE-----\nAR==\n-----END CERTIFICATE-----", // Nonzero padding bits.
                    "-----BEGIN CERTIFICATE-----\nAQ==AQ==\n-----END CERTIFICATE-----", // Data after padding.
                    "-----BEGIN CERTIFICATE-----\nAQ*=\n-----END CERTIFICATE-----", // Outside the alphabet.
                    "-----BEGIN CERTIFICATE-----\nAQID\n-----END PRIVATE KEY-----", // Wrong end label.
                    "-----BEGIN CERTIFICATE-----\nAQID\n"] { // No end.
            #expect(throws: BytesError.invalidValue, "\(bad)") { _ = try X509Certificate.decodePEM(bad) }
        }
    }
}

/// A copy of an optional span's bytes.
func bytes(_ span: RawSpan?) -> [UInt8]? {
    guard let span else { return nil }
    return [UInt8](copying: span)
}

/// Reads every field of a certificate that parsed (for the mutation test): none may trap.
func exercise(_ certificate: borrowing X509Certificate) {
    _ = certificate.version
    _ = certificate.tbsCertificate.byteCount + certificate.serialNumber.byteCount + certificate.signature.byteCount
    _ = certificate.signatureAlgorithm.description
    _ = certificate.signatureAlgorithmParameters?.byteCount
    _ = certificate.publicKeyAlgorithm.description
    _ = certificate.publicKeyParameters?.byteCount
    _ = certificate.namedCurve?.description
    _ = certificate.publicKey.byteCount + certificate.subjectPublicKeyInfo.byteCount
    _ = certificate.notBefore.secondsSince1970 + certificate.notAfter.secondsSince1970
    _ = certificate.notBefore.description
    _ = certificate.basicConstraints
    _ = certificate.keyUsage
    _ = certificate.isSelfIssued
    func readAll(_ name: borrowing X509Name) {
        _ = name.commonName
        var attributes = name.attributes
        while let attribute = attributes.next() {
            _ = attribute.string; _ = attribute.type.description
        }
    }
    readAll(certificate.issuer)
    readAll(certificate.subject)
    if var usages = certificate.extendedKeyUsage {
        while let usage = usages.next() {
            _ = usage.description
        }
    }
    var extensions = certificate.extensions
    while let item = extensions.next() {
        _ = item.identifier.description; _ = item.value.byteCount
    }
}

/// Every system root against OpenSSL and Security, field by field.
@Suite(.bulk) struct X509BulkTests {
    @Test(.enabled(if: systemRootsPEM != nil && opensslPath != nil)) func systemRootCertificates() throws {
        let roots = try X509Certificate.decodePEM(#require(systemRootsPEM))
        #expect(roots.count > 100)
        #expect(try X509Tests.crossCheckRoots(roots) > 100)
    }
}
