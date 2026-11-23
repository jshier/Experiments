import Foundation

// (`SegmentDecoding`, which decoded one segment with a chosen backend, went with the backends, 2026-11-22: the
// benchmarks decode segments with BytesCompression's decoders and Compression's, as references, themselves.)

@_spi(Benchmarking)
extension AEAArchive {
    /// A segment's stored (compressed) bytes.
    public func storedBytes(of segment: Int) throws(AEAError) -> [UInt8] {
        let info = segments[segment]
        return try Self.read(file, at: info.fileOffset, count: info.compressedSize)
    }
}
