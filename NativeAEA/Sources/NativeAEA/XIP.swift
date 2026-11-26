import Bytes
import BytesCompression
import BytesCrypto
import Disk
import Foundation
import System

// A `.xip`: a signed XAR archive (Xcode's downloads) of two members: `Content`, a pbzx stream (the `pbz` block
// format with xz blocks) of a cpio (odc) archive, and `Metadata`, a small bzip2-compressed property list.

/// How a `.xip`'s signature is checked. It signs the TOC's checksum, which covers the TOC, which holds the content's
/// SHA-1: a verified signature with the content checked (``AEAReadOptions/verifyChecksums``) covers everything.
public enum XIPSignatureCheck: Sendable {
    /// The RSA signature with the leaf certificate's key, and the chain: leaf "Software Update" (for Apple's software
    /// update signing), issued by Apple Software Update Certification Authority, under Apple Root CA (pinned by its
    /// SHA-256), each valid when the archive was made (its TOC's `creation-time`, which the signature covers).
    case certificateChain
    /// The same, trusting these root certificates (DER) instead.
    case certificateChainTrusting([[UInt8]])
    /// The signature with the leaf's key, without verifying the chain.
    case untrustedCertificateChain
    /// No signature check, as `xip --expand` (the TOC's checksum is still checked).
    case none
}

/// A `.xip`'s `Metadata` member: a bzip2-compressed property list.
public struct XIPMetadata: Sendable {
    /// The APFS compression to write (`10.10`: LZVN, as OS X 10.10 introduced).
    public var fileSystemCompressionFormat: String?
    /// The cpio stream's size, decoded.
    public var uncompressedSize: Int?
    public var version: Int?
    /// The property list, as stored once decoded.
    public var propertyList: [UInt8]

    /// Reads the keys from the property list's XML (top-level `dict` entries only).
    init(_ propertyList: [UInt8]) throws(AEAError) {
        self.propertyList = propertyList
        var scanner = XMLScanner(propertyList)
        var key: String?
        while let event = try scanner.next() {
            switch event {
            case let .text("plist/dict/key", text, _): key = text
            case let .text("plist/dict/string", text, _):
                if key == "FileSystemCompressionFormat" { fileSystemCompressionFormat = text }
            case let .text("plist/dict/integer", text, _):
                if key == "UncompressedSize" { uncompressedSize = try XAR.integer(text) }
                if key == "Version" { version = try XAR.integer(text) }
            default: break
            }
        }
    }
}

/// A `.xip` archive, opened and checked: its XAR table of contents (its checksum and signature verified), and where its
/// content stream is. Extracted and listed as Apple Archives are, through the same decoders and writers.
public final class XIPArchive: Sendable {
    public let path: FilePath
    /// The leaf certificate's common name, if the signature was checked, and whether its chain was verified.
    public let signer: String?
    public let isSignatureTrusted: Bool
    /// The `Metadata` member (checked against its SHA-1s), if the archive has one.
    public let metadata: XIPMetadata?
    /// The pbzx stream's block size.
    public let blockSize: Int
    /// The certificates the archive is signed with, leaf first (DER), and the signature's style (`RSA`).
    public let certificates: [[UInt8]]
    public let signatureStyle: String?
    /// The content stream's size (stored, which for `Content` is also its size: pbzx compresses within).
    public let contentSize: Int
    /// The archive file, open for reading (Disk's `InputFile`).
    let file: InputFile
    public let contentStart: Int
    /// SHA-1 of the content stream as stored, from the TOC, if it gives one.
    public let contentChecksum: [UInt8]?
    let toc: XARTableOfContents
    public let heapStart: Int
    /// The compressed TOC (what its checksum and signature cover).
    let tocCompressed: [UInt8]

    public init(path: FilePath, signature check: XIPSignatureCheck = .certificateChain) throws(AEAError) {
        // Closed by `close()`, or here if `init` throws.
        let file = try AEAArchive.open(path)
        self.file = file
        self.path = path
        do throws(AEAError) {
            let fileSize = file.count
            guard fileSize >= XAR.fixedHeaderSize else { throw AEAError.invalidArchive("not a XAR archive (too short)") }
            let head = try AEAArchive.read(file, at: 0, count: XAR.fixedHeaderSize)
            var reader = AlignedBytesReader(head.span.bytes)
            let header: XARHeaderRecord
            do throws(BytesError) {
                header = try reader.read(XARHeaderRecord.self)
            } catch {
                throw AEAError.invalidArchive("not a XAR archive (\(error))")
            }
            guard header.version == 1, header.headerSize >= XAR.fixedHeaderSize else {
                throw AEAError.invalidArchive("XAR version \(header.version), header size \(header.headerSize)")
            }
            // The TOC's sizes are u64s from the file: nothing allocated past what the file holds, or 64 MiB inflated.
            guard header.tocCompressedSize > 0, header.tocCompressedSize <= fileSize - header.headerSize,
                  header.tocSize > 0, header.tocSize <= 64 << 20 else {
                throw AEAError.invalidArchive("XAR TOC sizes \(header.tocCompressedSize)/\(header.tocSize)")
            }
            let compressed = try AEAArchive.read(file, at: header.headerSize, count: header.tocCompressedSize)
            tocCompressed = compressed
            let xml: [UInt8]
            do throws(BytesError) {
                // XAR's TOC: zlib, exactly its recorded size (checked above to be at most 64 MiB).
                var decoder = try Decompressor(for: .deflate(.zlib))
                xml = try decoder.decompressAll(compressed.span.bytes, maximumSize: 64 << 20, decodedSize: header.tocSize)
            } catch {
                throw AEAError.invalidArchive("the XAR TOC doesn't decompress (\(error))")
            }
            let toc = try XAR.parseTableOfContents(xml)
            self.toc = toc
            heapStart = header.headerSize + header.tocCompressedSize

            // The TOC's checksum, in the heap, over the compressed TOC.
            guard let checksum = toc.checksum else { throw AEAError.invalidArchive("the XAR TOC has no checksum") }
            guard checksum.offset >= 0, checksum.size >= 0, checksum.size <= 64, heapStart + checksum.offset + checksum.size <= fileSize else {
                throw AEAError.invalidArchive("the XAR TOC checksum's place")
            }
            let stored = try AEAArchive.read(file, at: heapStart + checksum.offset, count: checksum.size)
            guard let computed = Self.digest(checksum.style, compressed.span.bytes), computed.count == stored.count,
                  constantTimeEquals(computed.span.bytes, stored.span.bytes) else {
                throw AEAError.authenticationFailed("the XAR TOC checksum (\(checksum.style))")
            }
            certificates = toc.signature?.certificates ?? []
            signatureStyle = toc.signature?.style
            (signer, isSignatureTrusted) = try Self.verifySignature(
                toc, check, checksum: stored, checksumStyle: checksum.style, file: file, heapStart: heapStart, fileSize: fileSize
            )

            // The content: an unencoded member file holding a pbzx stream.
            guard let content = toc.files.first(where: { $0.name == "Content" }) else {
                throw AEAError.invalidArchive("the xip has no Content")
            }
            guard content.encoding == "application/octet-stream", content.length == content.size else {
                throw AEAError.invalidArchive("the xip's Content is encoded (\(content.encoding))")
            }
            contentStart = heapStart + content.offset
            contentSize = content.length
            guard content.offset >= 0, contentSize >= PBZ.headerSize, contentStart + contentSize <= fileSize else {
                throw AEAError.invalidArchive("the xip's Content is outside the file")
            }
            contentChecksum = content.archivedChecksum.flatMap { $0.style == "sha1" ? (try? [UInt8](hexadecimal: $0.hex)) : nil }
            let pbz = try AEAArchive.read(file, at: contentStart, count: PBZ.headerSize)
            let contentHeader: (compression: AppleArchiveCompression, blockSize: Int)?
            do throws(PBZError) {
                contentHeader = try PBZ.header(pbz.span.bytes)
            } catch {
                throw AEAError(.framing(error))
            }
            guard let contentHeader, contentHeader.compression == .lzma else { // "pbzx"
                throw AEAError.invalidArchive("the xip's Content isn't a pbzx stream")
            }
            blockSize = contentHeader.blockSize
            if let member = toc.files.first(where: { $0.name == "Metadata" }) {
                metadata = try Self.readMetadata(member, file: file, heapStart: header.headerSize + header.tocCompressedSize, fileSize: fileSize)
            } else {
                metadata = nil
            }
        } catch {
            file.close()
            throw error
        }
    }

    /// Closes the archive's file: the end of reading it (see ``AEAArchive/close()``). Safe to call more than once.
    public func close() {
        file.close()
    }

    /// Checks the signature (in the heap) over the TOC's checksum as `check` asks; returns the signer's name and whether
    /// its chain was verified.
    ///
    /// The signature is RSA PKCS #1 v1.5 of the checksum itself (its `DigestInfo` names the checksum's algorithm): the
    /// TOC isn't hashed again.
    private static func verifySignature(
        _ toc: XARTableOfContents, _ check: XIPSignatureCheck, checksum: [UInt8], checksumStyle: String,
        file: InputFile, heapStart: Int, fileSize: Int
    ) throws(AEAError) -> (String?, Bool) {
        let anchors: [[UInt8]]?
        switch check {
        case .none: return (nil, false)
        case .certificateChain: anchors = nil
        case let .certificateChainTrusting(roots): anchors = roots
        case .untrustedCertificateChain: anchors = []
        }
        guard let signature = toc.signature, let leafDER = signature.certificates.first else {
            throw .untrustedSigningKey("the xip isn't signed")
        }
        guard signature.style == "RSA" else { throw .untrustedSigningKey("a \(signature.style) signature") }
        guard signature.offset >= 0, signature.size > 0, signature.size <= 512, heapStart + signature.offset + signature.size <= fileSize else {
            throw .invalidArchive("the XAR signature's place")
        }
        let bytes = try AEAArchive.read(file, at: heapStart + signature.offset, count: signature.size)
        let algorithm: RSA.DigestAlgorithm
        switch checksumStyle {
        case "sha1": algorithm = .sha1
        case "sha256": algorithm = .sha256
        default: throw .untrustedSigningKey("a \(checksumStyle) checksum")
        }
        let leaf = try CertificateChain.parse(leafDER.span.bytes, "the leaf certificate")
        let key: RSA.PublicKey
        do throws(BytesError) {
            key = try RSA.PublicKey(certificate: leaf)
        } catch {
            throw .untrustedSigningKey("the leaf certificate's key (\(error))")
        }
        guard key.isValidSignature(bytes.span.bytes, digest: checksum.span.bytes, digestAlgorithm: algorithm) else {
            throw .invalidSignature
        }
        var trusted = false
        if case .untrustedCertificateChain = check {} else {
            // At the archive's making: Xcode's leaf certificate outlives few of the archives it signs by much.
            let made = toc.creationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
            try CertificateChain.verify(signature.certificates, anchors: anchors, at: made, policy: .softwareUpdate)
            trusted = true
        }
        return (leaf.subject.commonName, trusted)
    }

    /// Reads `Metadata` (at most 1 MiB, stored or decoded): checks its stored bytes' checksum, decodes it (bzip2, or
    /// stored as is), and checks the decoded bytes' checksum.
    private static func readMetadata(_ member: XARFile, file: InputFile, heapStart: Int, fileSize: Int) throws(AEAError) -> XIPMetadata {
        guard member.offset >= 0, member.length > 0, member.length <= 1 << 20, member.size > 0, member.size <= 1 << 20,
              heapStart + member.offset + member.length <= fileSize else {
            throw .invalidArchive("the xip's Metadata place or size")
        }
        let stored = try AEAArchive.read(file, at: heapStart + member.offset, count: member.length)
        try checkMember(stored, member.archivedChecksum, "the xip's Metadata as stored")
        let decoded: [UInt8]
        switch member.encoding {
        case "application/x-bzip2":
            do throws(BytesError) {
                // At most 1 MiB (checked above), exactly its recorded size.
                var decoder = try Decompressor(for: .bzip2)
                decoded = try decoder.decompressAll(stored.span.bytes, maximumSize: 1 << 20, decodedSize: member.size)
            } catch {
                throw .invalidArchive("the xip's Metadata doesn't decompress (\(error))")
            }
        case "application/octet-stream":
            guard member.length == member.size else { throw .invalidArchive("the xip's Metadata sizes") }
            decoded = stored
        default:
            throw .invalidArchive("the xip's Metadata is \(member.encoding)")
        }
        try checkMember(decoded, member.extractedChecksum, "the xip's Metadata")
        return try XIPMetadata(decoded)
    }

    /// Checks `bytes` against a member's checksum from the TOC (if it gives one this computes).
    private static func checkMember(_ bytes: [UInt8], _ checksum: (style: String, hex: String)?, _ what: String) throws(AEAError) {
        guard let checksum, let expected = try? [UInt8](hexadecimal: checksum.hex), let computed = digest(checksum.style, bytes.span.bytes) else { return }
        guard computed.count == expected.count, constantTimeEquals(computed.span.bytes, expected.span.bytes) else {
            throw .authenticationFailed(what)
        }
    }

    /// The digest `style` names of `bytes`, or `nil` for one this doesn't compute.
    static func digest(_ style: String, _ bytes: RawSpan) -> [UInt8]? {
        switch style {
        case "sha1": [UInt8](copying: SHA1.hash(bytes).span.bytes)
        case "sha256": [UInt8](copying: SHA256.hash(bytes).span.bytes)
        default: nil
        }
    }

    /// The decoded content as a chunk source (not yet running): BytesCompressionAsync's engine over the pbzx stream's
    /// place in the file. The cpio walker reads the blocks: they carry its headers and names.
    private func source(_ options: AEAReadOptions, heldBeyondDecoding held: Int) -> FileBlocks {
        FileBlocks(
            stage: ArchiveFileStage(file: file), pbz: .lzma, blockSize: blockSize, file: contentStart..<(contentStart + contentSize),
            decoders: options.decodeThreads, extraBuffers: options.extraBuffers, heldBuffers: held,
            consumerBuffers: ExtractionSink.walkBuffers(held: held, blockCapacity: blockSize),
            carryCapacity: AppleArchive.headerCarryCapacity, budget: options.bufferBudget
        )
    }

    /// Extracts the archive beneath `destination`, as `xip --expand` does; see ``AEAArchive/extract(to:options:)``.
    /// Apple's expansion copies no quarantine attribute, so ``AEAExtractionOptions/copiesQuarantine`` is ignored.
    /// The progress (``AEAExtractionOptions/disk``) starts from the cpio stream's size in the xip's `Metadata` as its estimate of the
    /// bytes (`Content`'s stored size without it).
    ///
    /// With ``AEAReadOptions/verifyChecksums``, the content's SHA-1 (from the TOC) is checked by a child task while
    /// it's decoded; a mismatch throws after extraction (`xip --expand` checks nothing).
    @concurrent @discardableResult
    public func extract(to destination: FilePath, options: AEAExtractionOptions = .init()) async throws(AEAError) -> AEAStatistics {
        var options = options
        options.copiesQuarantine = false
        return try await extract(opened: Extractor.open(destination, options: options, archivePath: path, quarantinesDestination: false), options: options)
    }

    /// Extracts the archive into `destination`, a directory the caller opened; see ``AEAArchive/extract(into:options:)``.
    /// What's extracted gets the destination's quarantine, if its options give one (`xip --expand` and Archive Utility
    /// give a `.xip`'s contents none: leave it out).
    @concurrent @discardableResult
    public func extract(into destination: Destination, options: AEAExtractionOptions = .init()) async throws(AEAError) -> AEAStatistics {
        try await extract(opened: Extractor.reopen(destination, options: options), options: options)
    }

    /// The extraction into a destination opened with the options' policies, with the content's check beside it.
    private nonisolated(nonsending) func extract(opened target: Destination, options: AEAExtractionOptions) async throws(AEAError) -> AEAStatistics {
        let check = options.read.verifyChecksums ? contentCheck() : nil
        // If the extraction throws, leaving the scope cancels the check (and waits for it).
        async let mismatch = check?.run()
        let statistics = try await Extractor.extract(
            source(options.read, heldBeyondDecoding: options.heldBuffers), format: .cpio, into: target, options: options,
            expectedBytes: metadata?.uncompressedSize ?? contentSize
        )
        if let failure = await mismatch { throw failure }
        return statistics
    }

    /// Decodes the archive and calls `body` with each entry, in order (and checks the content's SHA-1 meanwhile, with
    /// ``AEAReadOptions/verifyChecksums``); see ``AEAArchive/forEachEntry(options:_:)``.
    @concurrent @discardableResult
    public func forEachEntry(options: AEAReadOptions = .init(), _ body: @escaping (AAEntry) -> Void) async throws(AEAError) -> AEAStatistics {
        try await list(options, body)
    }

    /// Decodes the archive and parses every entry without making entries (and checks the content's SHA-1, with
    /// ``AEAReadOptions/verifyChecksums``); see ``AEAArchive/verify(options:)``.
    @concurrent @discardableResult
    public func verify(options: AEAReadOptions = .init()) async throws(AEAError) -> AEAStatistics {
        try await list(options, nil)
    }

    private nonisolated(nonsending) func list(_ options: AEAReadOptions, _ body: ((AAEntry) -> Void)?) async throws(AEAError) -> AEAStatistics {
        let check = options.verifyChecksums ? contentCheck() : nil
        async let mismatch = check?.run()
        let statistics = try await Lister.list(source(options, heldBeyondDecoding: 0), format: .cpio, body)
        if let failure = await mismatch { throw failure }
        return statistics
    }

    /// The check of the content as stored, if the TOC gives its SHA-1.
    private func contentCheck() -> ContentCheck? {
        guard let expected = contentChecksum else { return nil }
        return ContentCheck(file: file, start: contentStart, count: contentSize, expected: expected)
    }
}

/// SHA-1 of a range of a file: positioned reads of 4 MiB into one buffer, made once, run as a child task beside the
/// decoding.
struct ContentCheck: Sendable {
    let file: InputFile
    let start: Int
    let count: Int
    let expected: [UInt8]

    /// Hashes the range: `nil` if it matches, the failure otherwise (or ``AEAError/cancelled``, checked between reads).
    ///
    /// `@concurrent`: background work (gigabytes of reads and SHA-1) run beside the extraction in an `async let`, so it
    /// never runs on its caller's executor, whatever the module's default isolation for `async` functions.
    @concurrent
    func run() async -> AEAError? {
        var buffer = [UInt8](repeating: 0, count: 4 << 20)
        var hash = SHA1()
        var offset = 0
        while offset < count {
            if Task.isCancelled { return .cancelled }
            let piece = min(4 << 20, count - offset)
            do throws(DiskError) {
                try buffer.withOutputRawSpan { output throws(DiskError) in try file.read(at: start + offset, count: piece, into: &output) }
            } catch {
                return AEAError(error)
            }
            hash.update(buffer.span.bytes.extracting(0..<piece))
            offset += piece
        }
        let digest = hash.finalize()
        return digest.span.bytes.bytesEqual(expected.span.bytes) ? nil : .authenticationFailed("the xip's Content SHA-1")
    }
}
