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
    /// Who signed it, verified: `nil` on the unsigned profiles (1, 3, 5).
    public let signer: AEASigner?
    /// SHA-256 of the prologue as stored: what `aea id` prints.
    public let identifier: [UInt8]
    /// The archive file.
    public let path: FilePath

    /// Each segment's checksum, `rootHeader.checksum.byteCount` bytes apiece.
    let checksums: [UInt8]
    /// Each segment's stored MAC, 32 bytes apiece, and its keys.
    let segmentMACs: [UInt8]
    let segmentKeys: [DataKey]
    /// Whether segments (and headers) are encrypted: every profile but 0.
    public let isEncrypted: Bool
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
    public init(path: FilePath, signingKey: AEASigningKey = .certificateChain, decryptionKey: AEADecryptionKey? = nil) throws(AEAError) {
        let descriptor: FileDescriptor
        do {
            descriptor = try FileDescriptor.open(path, .readOnly, options: [.closeOnExec])
        } catch {
            throw .fileSystem("open \(path)", error as? Errno ?? .ioError)
        }
        self.descriptor = descriptor
        self.path = path
        do throws(AEAError) {
            let fileSize = try Self.fileSize(descriptor)
            guard fileSize >= AEAPrologue.fixedByteCount else { throw AEAError.notAnAEAFile }
            var fixed = [UInt8](repeating: 0, count: AEAPrologue.fixedByteCount)
            try Self.read(descriptor, at: 0, into: &fixed)
            let prologueCount = try AEAPrologue.byteCount(parsing: fixed.span.bytes)
            // The auth data's size is a u32 from the file: no allocation past what the file holds.
            guard prologueCount <= fileSize else { throw AEAError.truncated }
            var prologueBytes = [UInt8](repeating: 0, count: prologueCount)
            try Self.read(descriptor, at: 0, into: &prologueBytes)
            let prologue = try AEAPrologue(parsing: prologueBytes.span.bytes)
            self.prologue = prologue
            identifier = SHA256.hash(prologueBytes.span.bytes).span.withUnsafeBytes { unsafe Array($0) } // Copies a local digest: safe.
            let encrypted = prologue.profile != .signed
            isEncrypted = encrypted

            // The signer first: its public key is part of the main key's derivation.
            if !prologue.profile.isSigned {
                // A key given explicitly for an unsigned archive would verify nothing: say so rather than succeed.
                switch signingKey {
                case .publicKey, .certificateChainTrusting:
                    throw AEAError.untrustedSigningKey("the archive isn't signed (profile \(prologue.profile.rawValue))")
                case .certificateChain, .untrustedCertificateChain:
                    break
                }
            }
            let signing = prologue.profile.isSigned ? try AEASignature.signer(prologue, signingKey) : nil
            let mainKey = try AEAKeys.mainKey(prologue, signingPublicKey: signing?.publicKey ?? [], decryptionKey: decryptionKey)
            if let signing {
                try AEASignature.verify(prologue, bytes: prologueBytes, signer: signing, mainKey: mainKey)
            }
            signer = signing

            let rootKey = AEAKeys.deriveDataKey(mainKey, KeyInfo("AEA_RHEK"))
            let rootMAC = AEAKeys.mac(
                rootKey.mac,
                associatedData: prologue.firstClusterMAC.span.bytes, prologue.authData.span.bytes,
                data: prologue.rootHeaderBytes.span.bytes
            )
            guard AEAKeys.equal(rootMAC, prologue.rootHeaderMAC.span.bytes) else {
                // On an encrypted profile, a wrong key fails here first.
                throw encrypted ? AEAError.authenticationFailed("root header (wrong key?)") : AEAError.authenticationFailed("root header")
            }
            var rootBytes = prologue.rootHeaderBytes
            if encrypted { rootKey.crypt(&rootBytes) }
            let root = try AEARootHeader(parsing: rootBytes.span.bytes)
            rootHeader = root
            guard root.containerSize == fileSize else {
                throw fileSize < root.containerSize ? AEAError.truncated : AEAError.invalidHeader("container size \(root.containerSize), file size \(fileSize)")
            }

            // Walk the clusters: each header's MAC is in the one before it (the prologue for the first).
            let checksumCount = root.checksum.byteCount
            // The per-segment tables at their final size, allocated once: the segments the root header promises, as
            // many as the file can hold (each takes at least a byte of data and its info and MAC in a header), so a
            // forged size can't reserve more than the file's size.
            let promised = (root.rawSize - 1) / root.segmentSize + 1
            let segmentCount = min(promised, fileSize / (8 + checksumCount + 32 + 1))
            var segments: [AEASegment] = []
            segments.reserveCapacity(segmentCount)
            var checksums: [UInt8] = []
            checksums.reserveCapacity(segmentCount * checksumCount)
            var segmentMACs: [UInt8] = []
            segmentMACs.reserveCapacity(segmentCount * 32)
            var segmentKeys: [DataKey] = []
            segmentKeys.reserveCapacity(segmentCount)
            var expectedMAC = Key32(repeating: 0)
            for index in 0..<32 { expectedMAC[index] = prologue.firstClusterMAC[index] }
            var offset = prologue.byteCount
            var rawOffset = 0
            var cluster = 0
            var largest = 0
            let infoCount = root.segmentsPerCluster * (8 + checksumCount)
            var header = [UInt8](repeating: 0, count: root.clusterHeaderByteCount)
            while rawOffset < root.rawSize {
                guard offset + header.count <= fileSize else { throw AEAError.truncated }
                try Self.read(descriptor, at: offset, into: &header)
                // The cluster key's HKDF extract and keyed HMAC, once for its header key and every segment's key.
                let clusterKey = KeyExpander(AEAKeys.derive(mainKey, KeyInfo("AEA_CK", index: UInt32(cluster))))
                let headerKey = AEAKeys.expandDataKey(clusterKey, KeyInfo("AEA_CHEK"))
                do {
                    let headerSpan = header.span.bytes
                    let nextMAC = headerSpan.extracting(infoCount..<(infoCount + 32))
                    let macs = headerSpan.extracting((infoCount + 32)..<headerSpan.byteCount)
                    let mac = AEAKeys.mac(headerKey.mac, associatedData: nextMAC, macs, data: headerSpan.extracting(0..<infoCount))
                    guard AEAKeys.equal(expectedMAC, mac.span.bytes) else {
                        throw AEAError.authenticationFailed("cluster \(cluster) header")
                    }
                }
                offset += header.count
                // The segment infos, decrypted in place on encrypted profiles (MACed as stored); the MACs after them
                // stay as stored.
                if encrypted {
                    header.withUnsafeMutableBytes { bytes in
                        // The header array's first `infoCount` bytes (fewer than its count), used only in this call: safe.
                        var infoBytes = unsafe MutableRawSpan(_unsafeBytes: UnsafeMutableRawBufferPointer(rebasing: bytes[0..<infoCount]))
                        headerKey.crypt(&infoBytes)
                    }
                }
                let headerSpan = header.span.bytes
                let macs = headerSpan.extracting((infoCount + 32)..<headerSpan.byteCount)
                var reader = AlignedBytesReader(headerSpan.extracting(0..<infoCount))
                for index in 0..<root.segmentsPerCluster where rawOffset < root.rawSize {
                    // The infos are exactly `segmentsPerCluster` entries (the header's size comes from them): these
                    // reads fail only on a bug.
                    let sizes: SegmentSizes, checksum: RawSpan
                    do throws(BytesError) {
                        sizes = try reader.read(SegmentSizes.self)
                        checksum = try reader.read(byteCount: checksumCount)
                    } catch {
                        throw AEAError.invalidHeader("cluster \(cluster) segment \(index) info: \(error)")
                    }
                    let raw = sizes.raw, compressed = sizes.stored
                    guard raw > 0, raw <= root.segmentSize, compressed > 0, compressed <= raw + raw / 16 + 4096,
                          rawOffset + raw <= root.rawSize, offset + compressed <= fileSize
                    else { throw AEAError.invalidHeader("segment \(segments.count) sizes") }
                    segments.append(AEASegment(
                        index: segments.count, cluster: cluster, indexInCluster: index, fileOffset: offset,
                        compressedSize: compressed, rawOffset: rawOffset, rawSize: raw
                    ))
                    checksum.withUnsafeBytes { unsafe checksums.append(contentsOf: $0) } // Copies from a borrowed span: safe.
                    macs.extracting((index * 32)..<(index * 32 + 32)).withUnsafeBytes { unsafe segmentMACs.append(contentsOf: $0) } // Same.
                    segmentKeys.append(AEAKeys.expandDataKey(clusterKey, KeyInfo("AEA_SK", index: UInt32(index))))
                    largest = max(largest, compressed)
                    offset += compressed
                    rawOffset += raw
                }
                for index in 0..<32 { expectedMAC[index] = header[infoCount + index] }
                cluster += 1
            }

            // What follows the last segment is padding, MACed with the padding key into the last header's
            // next-cluster slot.
            if offset < fileSize {
                var padding = [UInt8](repeating: 0, count: fileSize - offset)
                try Self.read(descriptor, at: offset, into: &padding)
                var hmac = HMAC<SHA256>(key: AEAKeys.derive(mainKey, KeyInfo("AEA_PAK")).span.bytes)
                hmac.update(padding.span.bytes)
                let mac = AEAKeys.finalize(&hmac)
                guard AEAKeys.equal(expectedMAC, mac.span.bytes) else {
                    throw AEAError.authenticationFailed("padding")
                }
            }
            self.segments = segments
            self.checksums = checksums
            self.segmentMACs = segmentMACs
            self.segmentKeys = segmentKeys
            largestCompressedSegment = largest
        } catch {
            try? descriptor.close()
            throw error
        }
    }

    deinit {
        try? descriptor.close()
    }

    /// Opens and verifies an archive.
    public convenience init(url: URL, signingKey: AEASigningKey = .certificateChain, decryptionKey: AEADecryptionKey? = nil) throws(AEAError) {
        try self.init(path: FilePath(url.path(percentEncoded: false)), signingKey: signingKey, decryptionKey: decryptionKey)
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

