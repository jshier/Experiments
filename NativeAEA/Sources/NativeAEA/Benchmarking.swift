import Foundation

/// Decodes single segments outside the extraction pipeline, for benchmarks comparing decoders.
@_spi(Benchmarking)
public final class SegmentDecoding {
    private var codec: SegmentCodec

    public init(_ archive: AEAArchive, backend: SegmentDecoderBackend) {
        codec = SegmentCodec(compression: archive.rootHeader.compression, backend: backend)
    }

    /// Decodes `stored` into `output`, which must be the segment's raw size.
    public func decode(_ stored: [UInt8], into output: inout [UInt8], segment: Int = 0) throws(AEAError) {
        let result: Result<Void, AEAError> = stored.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                // Both buffers are arrays the caller holds for the call's duration.
                do throws(AEAError) {
                    try unsafe codec.decode(input, into: output, segment: segment)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
        }
        try result.get()
    }
}

@_spi(Benchmarking)
extension AEAArchive {
    /// A segment's stored (compressed) bytes.
    public func storedBytes(of segment: Int) throws(AEAError) -> [UInt8] {
        let info = segments[segment]
        var bytes = [UInt8](repeating: 0, count: info.compressedSize)
        try Self.read(descriptor, at: info.fileOffset, into: &bytes)
        return bytes
    }
}
