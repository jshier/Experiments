import ArgumentParser
import Disk
import Foundation
import NativeAEA
import System

@main
struct NUnarchiver: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nunarchiver",
        abstract: "Verify, list, and extract Apple's archives: Apple Encrypted Archives (.aea), Apple Archives (.aar), and xip files (.xip), such as Xcode's."
    )

    @Argument(help: "The archive.")
    var archive: String

    @Option(name: [.customShort("d"), .long], help: "Extract into this directory.")
    var directory: String?

    @Option(name: [.customShort("o"), .long], help: "Decrypt the contents to this file, whatever they are (like `aea decrypt`), instead of extracting.")
    var output: String?

    @Option(name: .long, help: "With --output: the first byte of the contents to write.")
    var rangeOffset: Int?

    @Option(name: .long, help: "With --output: how many bytes of the contents to write.")
    var rangeSize: Int?

    @Option(name: .long, help: "Symmetric key (profiles 1, 2): hex, `hex:…`, or `base64:…`.")
    var key: String?

    @Option(name: .long, help: "A file holding the symmetric key's bytes (profiles 1, 2).")
    var keyFile: String?

    @Option(name: .long, help: "The recipient's P-256 private key, PEM (profiles 3, 4).")
    var recipientPriv: String?

    @Option(name: .long, help: "The password (profile 5).")
    var password: String?

    @Option(name: .long, help: "A file holding the password; trailing newlines are dropped (profile 5).")
    var passwordFile: String?

    @Option(name: .long, help: "IPSW disk images: the PEM private key that opens the key in the archive's auth data (WKMS).")
    var fcsKey: String?

    @Flag(name: .long, help: "IPSW disk images: download that private key from the URL in the archive's auth data (Apple's server).")
    var fetchKey = false

    @Flag(name: [.customShort("l"), .long], help: "List the entries.")
    var list = false

    @Flag(name: .long, help: "Print the archive's header only.")
    var info = false

    @Flag(name: [.customShort("v"), .long], help: "Print statistics after verifying, listing, or extracting.")
    var verbose = false

    @Option(name: .long, help: "Segments decoded at once (one task each).")
    var decodeThreads = ProcessInfo.processInfo.activeProcessorCount

    @Option(name: .long, help: "Writers in file system calls at once (default: a quarter of the performance cores, 2 to 6).")
    var fileSystemWidth = AEAExtractionOptions().fileSystemWidth

    @Option(name: .long, help: "Writers (tasks) compressing and writing files (default: one per performance core).")
    var writerThreads = AEAExtractionOptions().writerThreads

    @Flag(name: .long, help: "Show the extraction's progress on standard error.")
    var progress = false

    @Option(name: .long, help: "Decoded segments held beyond one per decoder and writer.")
    var extraBuffers = 8

    @Option(name: .long, help: "Segment decoder.")
    var decoder = SegmentDecoderBackend.bytes

    @Option(name: .long, help: "How segments are read: positioned reads or a mapping.")
    var input = SegmentInput.read

    @Option(name: .long, help: "How files are stored: as the archive asks (APFS-compressed), the same files as LZFSE (as unxip writes), or uncompressed.")
    var diskCompression = DiskCompressionMode.archived

    @Flag(name: .long, help: "Create entries relative to their open parent directory instead of by path (measured slower).")
    var relativeToParents = false

    @Flag(name: .long, help: "Replace existing files.")
    var overwrite = false

    @Flag(name: .long, help: "Don't copy the archive's quarantine attribute onto what's extracted (aa extract copies it).")
    var noQuarantine = false

    @Flag(name: .long, help: "Skip checking segment MACs and checksums (the prologue and cluster headers are still checked).")
    var noVerify = false

    @Option(name: .long, help: "A P-256 public key (PEM or X9.63) to verify the signature with, instead of the archive's certificate chain.")
    var signPub: String?

    @Flag(name: .long, help: "Use the archive's certificate chain without evaluating its trust.")
    var untrustedChain = false

    func validate() throws {
        guard decodeThreads >= 1, writerThreads >= 1, fileSystemWidth >= 1 else {
            throw ValidationError("--decode-threads, --writer-threads, and --file-system-width must be at least 1.")
        }
        guard extraBuffers >= 0 else { throw ValidationError("--extra-buffers can't be negative.") }
        if rangeOffset.map({ $0 < 0 }) == true || rangeSize.map({ $0 < 0 }) == true {
            throw ValidationError("--range-offset and --range-size can't be negative.")
        }
    }

    func run() async throws {
        // The main task runs at the default priority; the work runs in a child at `.userInitiated` (the user waits for
        // it), which its child tasks (decoders, writers) inherit: the QoS the pipeline's threads had.
        let command = self
        try await withThrowingTaskGroup { group in
            group.addTask(priority: .userInitiated) { try await command.work() }
            try await group.waitForAll()
        }
    }

    private func work() async throws {
        // An Apple Archive file (`aa archive`'s output, plain or `pbz`), not in an AEA container.
        let magic = (try? FileHandle(forReadingFrom: URL(fileURLWithPath: archive)).read(upToCount: 4)) ?? nil
        if magic == Data("xar!".utf8) {
            try await runXIP()
            return
        }
        if let magic, magic != Data("AEA1".utf8) {
            try await runAppleArchive()
            return
        }
        let key: AEASigningKey = if let signPub {
            try AEASigningKey.publicKey(contentsOf: URL(fileURLWithPath: signPub))
        } else {
            untrustedChain ? .untrustedCertificateChain : .certificateChain
        }
        let archive = try AEAArchive(path: FilePath(archive), signingKey: key, decryptionKey: try await decryptionKey())
        let root = archive.rootHeader
        if info || verbose {
            let signer = archive.signer.map { "\($0.subject ?? "given key")\($0.isTrusted ? " (trusted)" : " (not evaluated)")" } ?? "none"
            print("""
            profile: \(archive.prologue.profile.name)
            signer: \(signer)
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
        if let output {
            var range: Range<Int>?
            if rangeOffset != nil || rangeSize != nil {
                let start = rangeOffset ?? 0
                range = start..<(rangeSize.map { start + $0 } ?? root.rawSize)
            }
            statistics = try await archive.decrypt(to: FilePath(output), range: range, overwrite: overwrite, options: read)
        } else if let directory {
            statistics = try await extracting(read) { try await archive.extract(to: FilePath(directory), options: $0) }
        } else {
            // Listing makes an entry (and its strings) for each; verifying alone makes none.
            statistics = list
                ? try await archive.forEachEntry(options: read) { print($0.path) }
                : try await archive.verify(options: read)
        }
        if verbose { print(statistics) }
    }

    private var readOptions: AEAReadOptions {
        var read = AEAReadOptions()
        read.decodeThreads = decodeThreads
        read.decoder = decoder
        read.input = input
        read.extraBuffers = extraBuffers
        read.verifyChecksums = !noVerify
        return read
    }

    private func runAppleArchive() async throws {
        let file = try AppleArchiveFile(path: FilePath(archive))
        if info || verbose {
            print("Apple Archive, \(file.compression.map { "pbz '\(Character(Unicode.Scalar($0.rawValue)))', blocks of \(file.blockSize) bytes" } ?? "uncompressed")")
        }
        if info { return }
        let statistics: AEAStatistics
        if let directory {
            statistics = try await extracting(readOptions) { try await file.extract(to: FilePath(directory), options: $0) }
        } else {
            // Listing makes an entry (and its strings) for each; verifying alone makes none.
            statistics = list
                ? try await file.forEachEntry(options: readOptions) { print($0.path) }
                : try await file.verify(options: readOptions)
        }
        if verbose { print(statistics) }
    }

    /// A `.xip` (a signed XAR archive of a pbzx-compressed cpio archive): Xcode's downloads.
    private func runXIP() async throws {
        // `--no-verify` skips what `xip --expand` skips: the signature and the content's SHA-1.
        let check: XIPSignatureCheck = noVerify ? .none : untrustedChain ? .untrustedCertificateChain : .certificateChain
        let file = try XIPArchive(path: FilePath(archive), signature: check)
        if info || verbose {
            let signer = file.signer.map { "\($0)\(file.isSignatureTrusted ? " (trusted)" : " (not evaluated)")" } ?? "not checked"
            print("""
            xip: content \(file.contentSize) bytes in pbzx blocks of \(file.blockSize)
            signature: \(file.signatureStyle ?? "none") with \(file.certificates.count) certificates, signer: \(signer)
            metadata: \(file.metadata.map { "cpio \($0.uncompressedSize.map(String.init) ?? "?") bytes, file system compression \($0.fileSystemCompressionFormat ?? "?")" } ?? "none")
            """)
        }
        if info { return }
        let statistics: AEAStatistics
        if let directory {
            // `xip --expand` copies no quarantine: the option is ignored.
            statistics = try await extracting(readOptions) { try await file.extract(to: FilePath(directory), options: $0) }
        } else {
            // Listing makes an entry (and its strings) for each; verifying alone makes none.
            statistics = list
                ? try await file.forEachEntry(options: readOptions) { print($0.path) }
                : try await file.verify(options: readOptions)
        }
        if verbose { print(statistics) }
    }

    /// Runs `extract` with the extraction options given, showing its progress with `--progress`: a line on standard
    /// error, redrawn twice a second from the extraction's counters (polled, as an app's timer would).
    private func extracting(_ read: AEAReadOptions, _ extract: (AEAExtractionOptions) async throws -> AEAStatistics) async throws -> AEAStatistics {
        var options = AEAExtractionOptions()
        options.read = read
        options.writerThreads = writerThreads
        options.fileSystemWidth = fileSystemWidth
        options.diskCompression = diskCompression
        options.overwrite = overwrite
        options.relativeToParents = relativeToParents
        options.copyQuarantine = !noQuarantine
        options.collectsTimings = verbose
        guard progress else { return try await extract(options) }
        let counters = ExtractionProgress()
        options.progress = counters
        let reporter = Task {
            func show(_ end: String) {
                let percent = counters.fractionCompleted.map { fraction in
                    let tenths = Int(fraction * 1_000)
                    return "\(tenths / 10).\(tenths % 10)%"
                } ?? "?"
                let line = "\r\(percent)  \(counters.entries) of \(counters.expectedEntries) entries, \(counters.bytes >> 20) of \(counters.expectedBytes >> 20) MiB\(end)"
                FileHandle.standardError.write(Data(line.utf8))
            }
            while !Task.isCancelled {
                show("")
                try? await Task.sleep(for: .milliseconds(500))
            }
            show("\n")
        }
        defer { reporter.cancel() }
        let statistics = try await extract(options)
        reporter.cancel()
        await reporter.value
        return statistics
    }

    /// The key an encrypted archive needs, from the options given.
    private func decryptionKey() async throws -> AEADecryptionKey? {
        if let key { return try AEADecryptionKey.symmetric(text: key) }
        if let keyFile { return .symmetric(Array(try Data(contentsOf: URL(fileURLWithPath: keyFile)))) }
        if let recipientPriv { return try AEADecryptionKey.recipientPrivateKey(contentsOf: URL(fileURLWithPath: recipientPriv)) }
        if let password { return .password(Array(password.utf8)) }
        if let passwordFile {
            var bytes = Array(try Data(contentsOf: URL(fileURLWithPath: passwordFile)))
            while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
            return .password(bytes)
        }
        if fcsKey != nil || fetchKey {
            guard let request = try WKMS.request(in: AEAArchive.prologue(at: FilePath(archive))) else {
                throw ValidationError("The archive has no WKMS request in its auth data.")
            }
            let pem: String
            if let fcsKey {
                pem = try String(contentsOf: URL(fileURLWithPath: fcsKey), encoding: .utf8)
            } else {
                guard let url = request.keyURL, url.scheme == "https" else {
                    throw ValidationError("The archive's key URL is missing or not HTTPS.")
                }
                pem = try await Self.fetch(url)
            }
            return try WKMS.key(request, privateKeyPEM: pem)
        }
        return nil
    }

    /// Downloads a small text file (the WKMS private key).
    private static func fetch(_ url: URL) async throws -> String {
        // A PEM key is a few hundred bytes: a 30-second limit, and nothing over 64 KB accepted.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard data.count <= 65_536, status == 200, let text = String(data: data, encoding: .utf8) else {
            throw ValidationError("\(url): HTTP \(status)")
        }
        return text
    }
}

extension SegmentDecoderBackend: ExpressibleByArgument {}
extension SegmentInput: ExpressibleByArgument {}
extension DiskCompressionMode: ExpressibleByArgument {}
