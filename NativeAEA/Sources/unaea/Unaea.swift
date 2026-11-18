import ArgumentParser
import Foundation
import NativeAEA
import System

@main
struct Unaea: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unaea",
        abstract: "Verify, list, and extract Apple Encrypted Archives (.aea), such as Xcode's."
    )

    @Argument(help: "The archive.")
    var archive: String

    @Option(name: [.customShort("d"), .long], help: "Extract into this directory.")
    var directory: String?

    @Flag(name: [.customShort("l"), .long], help: "List the entries.")
    var list = false

    @Flag(name: .long, help: "Print the archive's header only.")
    var info = false

    @Flag(name: [.customShort("v"), .long], help: "Print statistics after verifying, listing, or extracting.")
    var verbose = false

    @Option(name: .long, help: "Threads decoding segments.")
    var decodeThreads = ProcessInfo.processInfo.activeProcessorCount

    @Option(name: .long, help: "Threads in file system calls at once.")
    var fileSystemWidth = 6

    @Option(name: .long, help: "Threads writing files.")
    var writerThreads = 24

    @Option(name: .long, help: "Decoded segments held beyond one per decoding and writing thread.")
    var extraBuffers = 8

    @Option(name: .long, help: "Segment decoder.")
    var decoder = SegmentDecoderBackend.bytes

    @Option(name: .long, help: "How segments are read: positioned reads or a mapping.")
    var input = SegmentInput.read

    @Option(name: .long, help: "How files are stored: as the archive asks (APFS-compressed), or uncompressed.")
    var diskCompression = DiskCompressionMode.archived

    @Flag(name: .long, help: "Create entries relative to their open parent directory instead of by path (measured slower).")
    var relativeToParents = false

    @Flag(name: .long, help: "Replace existing files.")
    var overwrite = false

    @Flag(name: .long, help: "Skip checking segment MACs and checksums (the prologue and cluster headers are still checked).")
    var noVerify = false

    @Option(name: .long, help: "A P-256 public key (PEM or X9.63) to verify the signature with, instead of the archive's certificate chain.")
    var signPub: String?

    @Flag(name: .long, help: "Use the archive's certificate chain without evaluating its trust.")
    var untrustedChain = false

    func run() throws {
        let key: AEASigningKey = if let signPub {
            try AEASigningKey.publicKey(contentsOf: URL(fileURLWithPath: signPub))
        } else {
            untrustedChain ? .untrustedCertificateChain : .certificateChain
        }
        let archive = try AEAArchive(path: FilePath(archive), signingKey: key)
        let root = archive.rootHeader
        if info || verbose {
            print("""
            profile: \(archive.prologue.profile.name)
            signer: \(archive.signer.subject ?? "given key")\(archive.signer.isTrusted ? " (trusted)" : " (not evaluated)")
            identifier: \(archive.identifier.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined())
            raw size: \(root.rawSize), container size: \(root.containerSize)
            segments: \(archive.segments.count) of \(root.segmentSize) bytes, \(root.segmentsPerCluster) per cluster, \
            compression '\(Character(Unicode.Scalar(root.compression.rawValue)))', checksum \(root.checksum)
            """)
        }
        if info { return }
        var read = AEAReadOptions()
        read.decodeThreads = decodeThreads
        read.decoder = decoder
        read.input = input
        read.extraBuffers = extraBuffers
        read.verifyMACs = !noVerify
        read.verifyChecksums = !noVerify
        let statistics: AEAStatistics
        if let directory {
            var options = AEAExtractionOptions()
            options.read = read
            options.writerThreads = writerThreads
            options.fileSystemWidth = fileSystemWidth
            options.diskCompression = diskCompression
            options.overwrite = overwrite
            options.relativeToParents = relativeToParents
            statistics = try archive.extract(to: FilePath(directory), options: options)
        } else {
            let list = list
            statistics = try archive.forEachEntry(options: read) { entry in
                if list { print(entry.path) }
            }
        }
        if verbose { print(statistics) }
    }
}

extension SegmentDecoderBackend: ExpressibleByArgument {}
extension SegmentInput: ExpressibleByArgument {}
extension DiskCompressionMode: ExpressibleByArgument {}
