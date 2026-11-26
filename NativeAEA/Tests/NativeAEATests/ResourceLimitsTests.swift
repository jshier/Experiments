// What an archive can make a reader spend, bounded (review 2026-11-23 §1.6–1.8 and its minor items; fix plan B1–B3,
// B8): buffers within a byte budget, AEA segments at most 256 MiB, an entry's metadata blobs refused at the header past a
// limit, XAR TOCs scanned in linear time however deep, and times whose nanoseconds aren't below a second refused.
import Bytes
import BytesTesting
import BytesTestSupport
import Darwin
import DiskTestSupport
import Foundation
import NativeAEA
import System
import Testing

@Suite(.diskLifetimes) struct ResourceLimitsTests {
    // MARK: Buffers (B1)

    /// A root header's segment size: up to 256 MiB, `aea`'s largest (its `-b 512m`, `1g`, and `2g` all write 268,435,456).
    @Test func segmentsAreAtMost256MiB() throws {
        func rootHeader(segmentSize: UInt32) -> [UInt8] {
            var bytes: [UInt8] = []
            bytes.append(UInt64(1 << 30), as: Byte8.self, .littleEndian) // Raw size.
            bytes.append(UInt64(1 << 20), as: Byte8.self, .littleEndian) // Container size.
            bytes.append(segmentSize, as: Byte4.self, .littleEndian)
            bytes.append(256, as: Byte4.self, .littleEndian) // Segments per cluster.
            bytes += [UInt8(ascii: "e"), AEAChecksum.sha256.rawValue] + [UInt8](repeating: 0, count: 22) // LZFSE.
            return bytes
        }
        #expect(try AEARootHeader(parsing: rootHeader(segmentSize: 256 << 20).span.bytes).segmentSize == 256 << 20)
        for size: UInt32 in [(256 << 20) + 1, 512 << 20, (1 << 31) - 1] {
            #expect(throws: AEAError.invalidHeader("segment size \(size), over 256 MiB")) {
                _ = try AEARootHeader(parsing: rootHeader(segmentSize: size).span.bytes)
            }
        }
    }

    /// A tree with a file of many blocks, files crossing blocks, and small files: blocks of 256 KiB (`pbz`, and AEA
    /// segments of 64 KiB or 100 KiB), so a few buffers' budget is "large blocks" for them.
    private static let tree = SharedFixtures.make { directory in
        let source = directory.path("source")
        try FileManager.default.createDirectory(at: source.appending(path: "d"), withIntermediateDirectories: true)
        try Data(testBytes(3_000_000, seed: 1, compressible: true)).write(to: source.appending(path: "large"))
        try Data(testBytes(1_500_000, seed: 2, compressible: false)).write(to: source.appending(path: "d/incompressible"))
        for index in 0..<30 {
            try Data(testBytes(20_000 + index * 1_000, seed: UInt64(10 + index), compressible: true)).write(to: source.appending(path: "d/f\(index)"))
        }
        let keys = try SharedFixtures.keys.get()
        let pbz = directory.path("tree.aar"), raw = directory.path("raw.aar")
        try ExternalTool.run("/usr/bin/aa", ["archive", "-a", "lzfse", "-b", "256k", "-d", source.path, "-o", pbz.path])
        try ExternalTool.run("/usr/bin/aa", ["archive", "-a", "raw", "-d", source.path, "-o", raw.path])
        let segments = try makeAEA(raw, keys: keys, in: directory, compression: "lzfse", blockSize: "64k")
        let pbzInAEA = try makeAEA(pbz, keys: keys, in: directory, compression: "copy", blockSize: "100k")
        return (source: source, pbz: pbz, raw: raw, segments: segments, pbzInAEA: pbzInAEA, keys: keys)
    }

    /// Every layout extracts and lists within a budget too small for the counts asked for (8 decoders, 8 extra buffers,
    /// 6 writers): at the least that runs (budget 0: one decoder, one writer, the one more), and with a few buffers.
    /// Writers come down with the held buffers; nothing waits forever, every buffer comes back, and the pool's peak shows
    /// the budget applied (it was 23 buffers).
    @Test(.timeLimit(.minutes(1)), arguments: [0, 6 << 20])
    func extractsWithinTheBudget(_ budget: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let tree = try Self.tree.get()
        var options = AEAExtractionOptions()
        options.read.decodeThreads = 8
        options.read.extraBuffers = 8
        options.read.bufferBudget = budget
        options.disk.writers = 6
        let expected = try readTree(tree.source, including: .entries)
        func check(_ statistics: AEAStatistics, _ name: String, most: Int) throws {
            #expect(statistics.unreleasedBuffers == 0, "\(name)")
            #expect(statistics.peakSegmentBuffers <= most, "\(name): \(statistics.peakSegmentBuffers) buffers")
            #expect(try readTree(directory.path(name), including: .entries) == expected, "\(name)")
        }
        // At budget 0, three buffers: one decoder's, one writer's, and the one more.
        let least = budget == 0
        for (name, url) in [("pbz", tree.pbz), ("raw", tree.raw)] {
            let file = try AppleArchiveFile(path: FilePath(url.path))
            defer { file.close() }
            try await check(file.extract(to: FilePath(directory.path(name).path), options: options), name, most: least ? 3 : 23)
            #expect(try await file.verify(options: options.read).unreleasedBuffers == 0)
        }
        for (name, url) in [("segments", tree.segments), ("pbzInAEA", tree.pbzInAEA)] {
            let archive = try AEAArchive(url: url, signingKey: tree.keys.signingKey)
            defer { archive.close() }
            try await check(archive.extract(to: FilePath(directory.path(name).path), options: options), name, most: least ? 3 : 23)
            #expect(try await archive.verify(options: options.read).unreleasedBuffers == 0)
        }
    }

    /// The least that runs, in `aea`'s smallest segments (16 KiB) with large files compressed in pieces: a 64 KiB chunk
    /// spans up to five pieces, and the planner keeps the first four until the fifth arrives, so the pool counts them as
    /// the walk's (`consumerBuffers`). With three buffers (one decoder, one writer, no extra buffers: by the counts asked
    /// for, or by a budget), the decoder waited forever for a buffer while the walk waited for its segment.
    @Test(.timeLimit(.minutes(1)), arguments: [(1, 1, 0, Int.max), (4, 4, 8, 0)])
    func smallSegmentsExtractAtTheLeast(_ decoders: Int, _ writers: Int, _ extra: Int, _ budget: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (url, keys, files) = try ExtractionTests.xcodeStyleArchive(blockSize: "1k")
        var options = AEAExtractionOptions()
        options.diskCompression = .lzfse // LZBITMAP's encoder is slow in debug builds.
        options.read.decodeThreads = decoders
        options.read.extraBuffers = extra
        options.read.bufferBudget = budget
        options.disk.writers = writers
        let archive = try AEAArchive(url: url, signingKey: keys.signingKey)
        defer { archive.close() }
        #expect(archive.rootHeader.segmentSize == 16_384)
        let statistics = try await archive.extract(to: FilePath(directory.path("out").path), options: options)
        #expect(statistics.unreleasedBuffers == 0)
        let tree = try readTree(directory.path("out"), including: .entries)
        for (path, bytes) in files {
            #expect(tree[path]?.contents == bytes, "\(path)")
        }
        #expect(ExtractionSink.walkBuffers(held: writers, blockCapacity: 16_384) == 4)
        #expect(ExtractionSink.walkBuffers(held: 0, blockCapacity: 16_384) == 1)
        #expect(ExtractionSink.walkBuffers(held: writers, blockCapacity: 65_536) == 1)
        #expect(ExtractionSink.walkBuffers(held: writers, blockCapacity: 9_363) == 7)
        #expect(ExtractionSink.walkBuffers(held: writers, blockCapacity: 9_362) == 1) // Stored plain: no chunks.
    }

    // MARK: Metadata blobs (B2)

    /// An entry's header: a file `x` with an `XAT` (and `ACL`) blob of the sizes given, and `data` bytes of contents.
    static func header(attributes: UInt64, acl: UInt64? = nil, data: UInt16 = 0) -> [UInt8] {
        func field(_ key: String, _ value: UInt64, _ width: Int) -> [UInt8] {
            Array(key.utf8) + (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
        }
        var fields = Array("TYP1F".utf8) + Array("PATP".utf8) + [1, 0, UInt8(ascii: "x")] + field("MOD2", 0o644, 2)
        fields += field("XATC", attributes, 8)
        if let acl { fields += field("ACLC", acl, 8) }
        fields += field("DATA", UInt64(data), 2)
        let count = 6 + fields.count
        return Array("AA01".utf8) + [UInt8(count & 0xFF), UInt8(count >> 8)] + fields
    }

    /// The limit on an entry's `XAT` and `ACL` blobs together is checked where their sizes are parsed: at it, accepted;
    /// past it, together or alone, refused; no limit (listing), anything.
    @Test func metadataIsBoundedAtTheHeader() throws {
        let limit = 256 << 20
        func parse(_ bytes: [UInt8], _ maximum: Int = limit) throws(AEAError) -> AAEntryHeader {
            try AppleArchive.parseHeader(bytes.span.bytes, maximumMetadataByteCount: maximum)
        }
        #expect(try parse(Self.header(attributes: UInt64(limit))).extendedAttributes?.count == limit)
        #expect(try parse(Self.header(attributes: 1 << 27, acl: 1 << 27)).accessControlList?.count == 1 << 27)
        let refused: [(UInt64, UInt64?)] = [(UInt64(limit) + 1, nil), (1 << 30, nil), ((1 << 27) + 1, 1 << 27), (1, UInt64(limit))]
        for (attributes, acl) in refused {
            let total = Int(attributes + (acl ?? 0))
            #expect(throws: AEAError.invalidArchive("extended attributes and ACL of \(total) bytes, over the limit of \(limit)")) {
                _ = try parse(Self.header(attributes: attributes, acl: acl))
            }
        }
        #expect(try parse(Self.header(attributes: 1 << 40), .max).extendedAttributes?.count == 1 << 40)
    }

    /// A 1 GiB `XAT` blob declared (the review's `xat-1g.aar` held 4.24 GB extracting it): extraction refuses it at the
    /// entry's header, before reading any of it, where it read the blob into memory until the stream ended; listing,
    /// which holds no blobs, reads past it to the stream's end. A real attribute over a lowered limit is refused too.
    @Test func extractionRefusesMetadataOverTheLimit() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let declared = directory.path("declared.aar")
        try Data(Self.header(attributes: 1 << 30) + testBytes(100_000, seed: 3, compressible: false)).write(to: declared)
        let file = try AppleArchiveFile(path: FilePath(declared.path))
        defer { file.close() }
        let refused = AEAError.invalidArchive("extended attributes and ACL of \(1 << 30) bytes, over the limit of \(256 << 20)")
        await #expect(throws: refused) { try await file.extract(to: FilePath(directory.path("out").path)) }
        await #expect(throws: AEAError.invalidArchive("the stream ends inside an entry")) { try await file.forEachEntry { _ in } }

        // A file with one 19-byte attribute: extracted with it, and refused with a limit of 18.
        let name = Array("user.test".utf8) + [0], value = Array("hello".utf8)
        var blob: [UInt8] = []
        blob.append(UInt32(4 + name.count + value.count), as: Byte4.self, .littleEndian)
        blob += name + value
        let attributed = directory.path("attributed.aar")
        try Data(Self.header(attributes: UInt64(blob.count), data: 3) + blob + [1, 2, 3]).write(to: attributed)
        let small = try AppleArchiveFile(path: FilePath(attributed.path))
        defer { small.close() }
        try await small.extract(to: FilePath(directory.path("with").path))
        #expect(extendedAttributes(of: directory.path("with/x"))["user.test"] == value)
        var options = AEAExtractionOptions()
        options.maximumMetadataByteCount = blob.count - 1
        await #expect(throws: AEAError.invalidArchive("extended attributes and ACL of 19 bytes, over the limit of 18")) {
            try await small.extract(to: FilePath(directory.path("without").path), options: options)
        }
    }

    // MARK: Times (B8)

    /// A `T` field's nanoseconds are below a second: more is refused where it's parsed, naming the field (it was accepted,
    /// and the entry's `setattrlist` failed with `EINVAL` after the entry was made). `S` fields have none.
    @Test func timesWithABillionNanosecondsAreRefused() throws {
        func header(_ field: String, nanoseconds: UInt32) -> [UInt8] {
            var fields = Array("TYP1F".utf8) + Array("PATP".utf8) + [1, 0, UInt8(ascii: "x")]
            fields += Array(field.utf8)
            fields.append(1_700_000_000, as: Byte8.self, .littleEndian)
            if field.hasSuffix("T") { fields.append(nanoseconds, as: Byte4.self, .littleEndian) }
            let count = 6 + fields.count
            return Array("AA01".utf8) + [UInt8(count & 0xFF), UInt8(count >> 8)] + fields
        }
        let latest = try AppleArchive.parseHeader(header("MTMT", nanoseconds: 999_999_999).span.bytes)
        #expect(latest.modificationTime?.seconds == 1_700_000_000 && latest.modificationTime?.nanoseconds == 999_999_999)
        for (field, nanoseconds) in [("MTMT", UInt32(1_000_000_000)), ("CTMT", .max), ("BTMT", 1_000_000_000)] {
            #expect(throws: AEAError.invalidArchive("\(field.prefix(3)) nanoseconds \(nanoseconds)")) {
                _ = try AppleArchive.parseHeader(header(field, nanoseconds: nanoseconds).span.bytes)
            }
        }
        #expect(try AppleArchive.parseHeader(header("MTMS", nanoseconds: 0).span.bytes).modificationTime?.seconds == 1_700_000_000)
    }

    // MARK: XAR's TOC (B3)

    /// A scanner's events as text, to compare.
    static func events(_ xml: [UInt8]) throws -> [String] {
        var scanner = XMLScanner(xml)
        var events: [String] = []
        while let event = try scanner.next() {
            switch event {
            case let .start(path, style): events.append("start \(path) \(style ?? "-")")
            case let .text(path, text, style): events.append("text \(path) \(text) \(style ?? "-")")
            case let .end(path): events.append("end \(path)")
            }
        }
        return events
    }

    /// Foundation's XML parser, as a reference: the same events, paths joined from its element names.
    final class ReferenceEvents: NSObject, XMLParserDelegate {
        var events: [String] = []
        private var names: [String] = []
        private var styles: [String?] = []
        private var text = ""

        private var path: String { names.joined(separator: "/") }

        private func flush() {
            if text.contains(where: { !$0.isWhitespace }), let style = styles.last {
                events.append("text \(path) \(text) \(style ?? "-")")
            }
            text = ""
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            flush()
            names.append(name)
            styles.append(attributes["style"])
            events.append("start \(path) \(attributes["style"] ?? "-")")
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            flush()
            events.append("end \(path)")
            names.removeLast()
            styles.removeLast()
        }
    }

    /// A TOC laid out as Xcode's (as `makeXIP` writes it, with a signature and its certificates): the scanner's events
    /// are Foundation's parser's, path for path.
    @Test func scannerEventsMatchAReferenceParser() throws {
        // Base64 in 64-character lines (LF: XML would normalize a CR LF).
        let certificate = Data(testBytes(700, seed: 9, compressible: false)).base64EncodedString()
        let lines = stride(from: 0, to: certificate.count, by: 64).map { start in
            String(certificate.dropFirst(start).prefix(64))
        }.joined(separator: "\n")
        let xml = Array("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- a comment -->
        <xar>
         <toc>
          <creation-time>2026-10-16T17:24:05</creation-time>
          <checksum style="sha1"><offset>0</offset><size>20</size></checksum>
          <signature style="RSA"><offset>20</offset><size>256</size><KeyInfo xmlns="http://www.w3.org/2000/09/xmldsig#">\
        <X509Data><X509Certificate>\(lines)</X509Certificate><X509Certificate>\(lines)</X509Certificate></X509Data></KeyInfo></signature>
          <file id="1"><data><length>10</length><offset>276</offset><size>10</size><encoding style="application/octet-stream"/>\
        <archived-checksum style="sha1">00ff</archived-checksum><extracted-checksum style="sha1">ff00</extracted-checksum></data>\
        <name>Content &amp; more &#x263A;</name><type>file</type></file>
          <file id="2"><data><encoding style='application/x-bzip2'/></data><name>Metadata</name><type>file</type></file>
         </toc>
        </xar>
        """.utf8)
        let reference = ReferenceEvents()
        let parser = XMLParser(data: Data(xml))
        parser.delegate = reference
        #expect(parser.parse())
        let events = try Self.events(xml)
        #expect(events == reference.events)
        #expect(events.contains("text xar/toc/signature/KeyInfo/X509Data/X509Certificate \(lines) -"))
        #expect(events.contains("text xar/toc/file/name Content & more \u{263A} -"))
        // And the TOC reads as it did.
        let toc = try XAR.parseTableOfContents(xml)
        #expect(toc.checksum?.style == "sha1" && toc.signature?.certificates.count == 2 && toc.files.map(\.name) == ["Content & more \u{263A}", "Metadata"])
        #expect(toc.files.map(\.encoding) == ["application/octet-stream", "application/x-bzip2"])
    }

    /// Paths up to 128 bytes are reported, longer ones as `""`; end tags still have to match.
    @Test func longPathsAreNotReported() throws {
        // "xar", 30 "/aaa", and "/aaaa": a path of 128 bytes; a child `b` inside makes it 130.
        let names = ["xar"] + Array(repeating: "aaa", count: 30) + ["aaaa"]
        let opening = names.map { "<\($0)>" }.joined(), closing = names.reversed().map { "</\($0)>" }.joined()
        let deepest = names.joined(separator: "/")
        #expect(deepest.utf8.count == 128)
        let events = try Self.events(Array((opening + "<b>t</b>" + closing).utf8))
        #expect(events.contains("start \(deepest) -") && events.contains("end \(deepest)"))
        #expect(events.contains("start  -") && events.contains("text  t -") && events.contains("end "))
        #expect(events.last == "end xar")
        #expect(throws: AEAError.invalidArchive("XML end tag a doesn't match")) { _ = try Self.events(Array("<a><b></a></b>".utf8)) }
    }

    /// A TOC 40,000 elements deep (the review's 511-byte `.xip` took 42.8 s, rebuilding the path for every event), and
    /// one with a 1 MB element name holding 100,000 children (every event's path a megabyte): each scanned in linear
    /// time, well under the limit even in a debug build.
    @Test(.timeLimit(.minutes(1))) func deepAndWideTOCsScanInLinearTime() throws {
        let deep = Array(("<xar><toc>" + String(repeating: "<a>", count: 40_000) + String(repeating: "</a>", count: 40_000) + "</toc></xar>").utf8)
        let name = String(repeating: "n", count: 1 << 20)
        let wide = Array(("<xar><toc><\(name)>" + String(repeating: "<c/>", count: 100_000) + "</\(name)></toc></xar>").utf8)
        for (label, xml) in [("deep", deep), ("wide", wide)] {
            let clock = ContinuousClock()
            let start = clock.now
            let toc = try XAR.parseTableOfContents(xml)
            let elapsed = clock.now - start
            #expect(toc.checksum == nil && toc.files.isEmpty)
            // Generous for a loaded machine: quadratic scanning takes minutes here (debug), linear well under a second.
            #expect(elapsed < .seconds(10), "\(label): \(elapsed)")
        }
    }
}

@Suite(.bulk, .diskLifetimes) struct ResourceLimitsBulkTests {
    /// `aa archive -b 64m`: blocks four times Xcode's, a file across several, extracted with the default budget (on this
    /// Mac, 3 decoders and no extra buffers: within 1 GiB).
    @Test(.timeLimit(.minutes(5))) func extractsLargeBlocks() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = directory.path("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(testBytes(150_000_000, seed: 4, compressible: true)).write(to: source.appending(path: "large"))
        try Data(testBytes(3_000_000, seed: 5, compressible: false)).write(to: source.appending(path: "small"))
        let archive = directory.path("large-blocks.aar")
        try ExternalTool.run("/usr/bin/aa", ["archive", "-a", "lzfse", "-b", "64m", "-d", source.path, "-o", archive.path])
        let file = try AppleArchiveFile(path: FilePath(archive.path))
        defer { file.close() }
        #expect(file.blockSize == 64 << 20)
        let statistics = try await file.extract(to: FilePath(directory.path("out").path))
        #expect(statistics.unreleasedBuffers == 0)
        #expect(try readTree(directory.path("out"), including: .entries) == readTree(source, including: .entries))
    }

    /// An 80,000,000-byte extended attribute, which Apple's tools carry (`aa archive`, then `aa extract`): extracted
    /// under the default limit.
    @Test(.timeLimit(.minutes(5))) func extractsAnAttributeAppleWrites() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let source = directory.path("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appending(path: "attributed")
        try Data([1, 2, 3]).write(to: file)
        let value = testBytes(80_000_000, seed: 6, compressible: false)
        let result = setxattr(file.path, "com.example.large", value, value.count, 0, 0)
        try #require(result == 0, "setxattr: \(errno)")
        let archive = directory.path("attributed.aar")
        try ExternalTool.run("/usr/bin/aa", ["archive", "-d", source.path, "-o", archive.path])
        let aar = try AppleArchiveFile(path: FilePath(archive.path))
        defer { aar.close() }
        try await aar.extract(to: FilePath(directory.path("out").path))
        #expect(extendedAttributes(of: directory.path("out/attributed"))["com.example.large"] == value)
    }
}
