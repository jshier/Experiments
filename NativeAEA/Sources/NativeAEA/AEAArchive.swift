import Bytes
import BytesCrypto
import Foundation
public import System

/// An opened Apple Encrypted Archive: its prologue verified, its segments indexed.
///
/// Opening reads the prologue and every cluster header (about 18 KB per 256 segments; Xcode's archive has three)
/// with positioned reads, verifies the signature and the header MACs, and keeps each segment's location,
/// checksum, and MAC. Segment data is read later, by ``AEAExtractor`` or ``withSegment(_:verify:_:)``.
public final class AEAArchive: Sendable {
    public let prologue: AEAPrologue
    public let rootHeader: AEARootHeader
    /// The segments in order. Their decompressed bytes, concatenated, are an Apple Archive stream.
    public let segments: [AEASegment]
    public let signer: AEASigner
    /// SHA-256 of the prologue as stored: what `aea id` prints.
    public let identifier: [UInt8]

    /// Each segment's checksum, `rootHeader.checksum.byteCount` bytes apiece.
    let checksums: [UInt8]
    /// Each segment's stored MAC and its key, 32 bytes apiece.
    let segmentMACs: [UInt8]
    let segmentKeys: [Key32]
    let descriptor: FileDescriptor
    /// The largest compressed segment, for sizing read buffers.
    public let largestCompressedSegment: Int

    /// Opens and verifies an archive.
    ///
    /// - Parameters:
    ///   - path: The `.aea` file.
    ///   - signingKey: Where the signing key comes from; by default the certificate chain in the archive,
    ///     evaluated as trusted.
    /// - Throws: ``AEAError``: not an archive, an unsupported profile, a bad signature or MAC, a truncated file.
    public init(path: FilePath, signingKey: AEASigningKey = .certificateChain) throws(AEAError) {
        let descriptor: FileDescriptor
        do {
            descriptor = try FileDescriptor.open(path, .readOnly, options: [.closeOnExec])
        } catch {
            throw .fileSystem("open \(path)", error as? Errno ?? .ioError)
        }
        self.descriptor = descriptor
        do {
            let fileSize = try Self.fileSize(descriptor)
            guard fileSize >= AEAPrologue.fixedByteCount else { throw AEAError.notAnAEAFile }
            var fixed = [UInt8](repeating: 0, count: AEAPrologue.fixedByteCount)
            try Self.read(descriptor, at: 0, into: &fixed)
            let prologueCount = try AEAPrologue.byteCount(parsing: fixed.span.bytes)
            var prologueBytes = [UInt8](repeating: 0, count: prologueCount)
            try Self.read(descriptor, at: 0, into: &prologueBytes)
            let prologue = try AEAPrologue(parsing: prologueBytes.span.bytes)
            guard prologue.profile == .signed else { throw AEAError.unsupportedProfile(prologue.profile.rawValue) }
            self.prologue = prologue
            identifier = SHA256.hash(prologueBytes.span.bytes).span.withUnsafeBytes { unsafe Array($0) } // Copies a local digest: safe.

            signer = try AEASignature.verify(prologue, bytes: prologueBytes, key: signingKey)
            let mainKey = AEAKeys.mainKey(prologue, signingPublicKey: signer.publicKey)
            let rootKey = AEAKeys.derive(mainKey, info: Array("AEA_RHEK".utf8))
            let rootMAC = AEAKeys.mac(
                rootKey,
                associatedData: prologue.firstClusterMAC.span.bytes, prologue.authData.span.bytes,
                data: prologue.rootHeaderBytes.span.bytes
            )
            guard AEAKeys.equal(rootMAC, prologue.rootHeaderMAC.span.bytes) else {
                throw AEAError.authenticationFailed("root header")
            }
            let root = try AEARootHeader(parsing: prologue.rootHeaderBytes.span.bytes)
            rootHeader = root
            guard root.containerSize == fileSize else {
                throw fileSize < root.containerSize ? AEAError.truncated : AEAError.invalidHeader("container size \(root.containerSize), file size \(fileSize)")
            }

            // Walk the clusters: each header's MAC is in the one before it (the prologue for the first).
            var segments: [AEASegment] = []
            var checksums: [UInt8] = []
            var segmentMACs: [UInt8] = []
            var segmentKeys: [Key32] = []
            var expectedMAC = prologue.firstClusterMAC
            var offset = prologue.byteCount
            var rawOffset = 0
            var cluster = 0
            let checksumCount = root.checksum.byteCount
            let infoCount = root.segmentsPerCluster * (8 + checksumCount)
            var header = [UInt8](repeating: 0, count: root.clusterHeaderByteCount)
            while rawOffset < root.rawSize {
                guard offset + header.count <= fileSize else { throw AEAError.truncated }
                try Self.read(descriptor, at: offset, into: &header)
                let clusterKey = AEAKeys.derive(mainKey, info: AEAKeys.info("AEA_CK", index: UInt32(cluster)))
                let headerKey = AEAKeys.derive(clusterKey, info: Array("AEA_CHEK".utf8))
                let headerSpan = header.span.bytes
                let infos = headerSpan.extracting(0..<infoCount)
                let nextMAC = headerSpan.extracting(infoCount..<(infoCount + 32))
                let macs = headerSpan.extracting((infoCount + 32)..<header.count)
                let mac = AEAKeys.mac(headerKey, associatedData: nextMAC, macs, data: infos)
                guard AEAKeys.equal(mac, expectedMAC.span.bytes) else {
                    throw AEAError.authenticationFailed("cluster \(cluster) header")
                }
                offset += header.count
                var reader = AlignedBytesReader(infos)
                for index in 0..<root.segmentsPerCluster where rawOffset < root.rawSize {
                    let raw = try Int(reader.read(Byte4.self, .littleEndian))
                    let compressed = try Int(reader.read(Byte4.self, .littleEndian))
                    let checksum = try reader.read(byteCount: checksumCount)
                    guard raw > 0, raw <= root.segmentSize, compressed > 0, compressed <= raw + raw / 16 + 4096,
                          rawOffset + raw <= root.rawSize, offset + compressed <= fileSize
                    else { throw AEAError.invalidHeader("segment \(segments.count) sizes") }
                    segments.append(AEASegment(
                        index: segments.count, cluster: cluster, indexInCluster: index, fileOffset: offset,
                        compressedSize: compressed, rawOffset: rawOffset, rawSize: raw
                    ))
                    checksum.withUnsafeBytes { unsafe checksums.append(contentsOf: $0) } // Copies from a borrowed span: safe.
                    macs.extracting((index * 32)..<(index * 32 + 32)).withUnsafeBytes { unsafe segmentMACs.append(contentsOf: $0) } // Same.
                    segmentKeys.append(AEAKeys.derive(clusterKey, info: AEAKeys.info("AEA_SK", index: UInt32(index))))
                    offset += compressed
                    rawOffset += raw
                }
                expectedMAC = nextMAC.withUnsafeBytes { unsafe Array($0) } // Copies from a borrowed span: safe.
                cluster += 1
            }

            // What follows the last segment is padding, MACed with the padding key into the last header's
            // next-cluster slot.
            if offset < fileSize {
                var padding = [UInt8](repeating: 0, count: fileSize - offset)
                try Self.read(descriptor, at: offset, into: &padding)
                var hmac = HMAC<SHA256>(key: AEAKeys.derive(mainKey, info: Array("AEA_PAK".utf8)).span.bytes)
                hmac.update(padding.span.bytes)
                guard AEAKeys.equal(AEAKeys.finalize(&hmac), expectedMAC.span.bytes) else {
                    throw AEAError.authenticationFailed("padding")
                }
            }
            self.segments = segments
            self.checksums = checksums
            self.segmentMACs = segmentMACs
            self.segmentKeys = segmentKeys
            largestCompressedSegment = segments.map(\.compressedSize).max() ?? 0
        } catch {
            try? descriptor.close()
            throw error as? AEAError ?? .invalidHeader("cluster header")
        }
    }

    deinit {
        try? descriptor.close()
    }

    /// Opens and verifies an archive.
    public convenience init(url: URL, signingKey: AEASigningKey = .certificateChain) throws(AEAError) {
        try self.init(path: FilePath(url.path(percentEncoded: false)), signingKey: signingKey)
    }

    // MARK: Reading

    static func fileSize(_ descriptor: FileDescriptor) throws(AEAError) -> Int {
        do {
            return try Int(descriptor.seek(offset: 0, from: .end))
        } catch {
            throw .fileSystem("seek", error as? Errno ?? .ioError)
        }
    }

    /// Fills `buffer` from `offset`, with as many positioned reads as it takes.
    static func read(_ descriptor: FileDescriptor, at offset: Int, into buffer: inout [UInt8]) throws(AEAError) {
        let result: Result<Void, AEAError> = buffer.withUnsafeMutableBytes { bytes in
            // `bytes` is the array's storage, used only inside the closure: safe.
            unsafe readFully(descriptor, at: offset, into: bytes)
        }
        try result.get()
    }

    /// Fills `buffer` from `offset` with positioned reads.
    ///
    /// - Precondition: `buffer` is valid for writes for the call's duration.
    static func readFully(_ descriptor: FileDescriptor, at offset: Int, into buffer: UnsafeMutableRawBufferPointer) -> Result<Void, AEAError> {
        var done = 0
        while done < buffer.count {
            let count: Int
            do {
                count = unsafe try descriptor.read(
                    fromAbsoluteOffset: Int64(offset + done),
                    into: UnsafeMutableRawBufferPointer(rebasing: buffer[done...]) // Within `buffer`: safe.
                )
            } catch {
                return .failure(.fileSystem("read", error as? Errno ?? .ioError))
            }
            guard count > 0 else { return .failure(.truncated) }
            done += count
        }
        return .success(())
    }

    // MARK: Segments

    /// Whether `checksum` is the one recorded for `segment` (compared in constant time).
    func checksumMatches(_ segment: Int, _ checksum: RawSpan) -> Bool {
        let count = rootHeader.checksum.byteCount
        let checksums = self.checksums // Bound to a local, so its span lives for the comparison.
        return checksum.byteCount == count
            && constantTimeEquals(checksums.span.bytes.extracting((segment * count)..<(segment * count + count)), checksum)
    }

    /// Whether `mac` is the one recorded for `segment` (compared in constant time).
    func macMatches(_ segment: Int, _ mac: Key32) -> Bool {
        let macs = segmentMACs // Bound to a local, so its span lives for the comparison.
        return AEAKeys.equal(mac, macs.span.bytes.extracting((segment * 32)..<(segment * 32 + 32)))
    }
}

