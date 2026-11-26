import BytesCrypto
import NativeAEA
import Synchronization
import Testing

/// What the allocation pass changed: the header parser's typed errors, the key schedule's shared HKDF extract, and the
/// directory table that allocates nothing until a directory is opened.
@Suite(.diskLifetimes) struct AllocationTests {
    // MARK: Header errors, now returned as values inside typed throws

    /// Parses `bytes` as one header, as the walker does.
    private func parse(_ bytes: [UInt8]) throws(AEAError) -> AAEntryHeader {
        let count = try AppleArchive.headerByteCount(bytes.span.bytes)
        return try AppleArchive.parseHeader(bytes.span.bytes.extracting(0..<count))
    }

    /// A header of `fields`, with its magic and size.
    private func header(_ fields: [UInt8]) -> [UInt8] {
        let count = 6 + fields.count
        return Array("AA01".utf8) + [UInt8(count & 0xFF), UInt8(count >> 8)] + fields
    }

    @Test func headerErrorsKeepTheirMessages() {
        #expect(throws: AEAError.invalidArchive("entry type 90")) { _ = try parse(header(Array("TYP1".utf8) + [0x5A])) }
        #expect(throws: AEAError.invalidArchive("two DAT fields")) {
            _ = try parse(header(Array("DATA".utf8) + [1, 0] + Array("DATA".utf8) + [1, 0]))
        }
        #expect(throws: AEAError.invalidArchive("two DAT fields")) {
            _ = try parse(header(Array("DATA".utf8) + [1, 0] + Array("DATC".utf8) + [1, 0, 0, 0, 0, 0, 0, 0]))
        }
        #expect(throws: AEAError.invalidArchive("blob size")) {
            _ = try parse(header(Array("XATC".utf8) + [0, 0, 0, 0, 0, 0, 0, 0x40]))
        }
        #expect(throws: AEAError.invalidArchive("entry type 90")) { _ = try parse(header(Array("TYP2".utf8) + [0x5A, 0])) }
        #expect(throws: AEAError.invalidArchive("field subtype 90")) { _ = try parse(header(Array("ABCZ".utf8))) }
        // A field cut short: by the header's end, in the common fields and the others.
        #expect(throws: AEAError.invalidArchive("a field runs past its header")) { _ = try parse(header(Array("PATP".utf8) + [9, 0, 0x61])) }
        #expect(throws: AEAError.invalidArchive("a field runs past its header")) { _ = try parse(header(Array("MTMT".utf8) + [1, 2, 3])) }
        #expect(throws: AEAError.invalidArchive("a field runs past its header")) { _ = try parse(header(Array("TY".utf8))) }
        #expect(throws: AEAError.invalidArchive("no entry magic")) { _ = try parse(Array("AB01".utf8) + [6, 0]) }
        #expect(throws: AEAError.invalidArchive("header size 5")) { _ = try parse(Array("AA01".utf8) + [5, 0]) }
        #expect(throws: AEAError.invalidArchive("truncated header")) { _ = try parse(Array("AA01".utf8) + [6]) }
        #expect(throws: AEAError.invalidArchive("truncated header")) { _ = try parse(Array("AA0".utf8)) }
    }

    @Test func headerFieldsOfOtherWidths() throws {
        let fields = Array("TYP1".utf8) + [0x46] + Array("PATP".utf8) + [1, 0, 0x61]
            + Array("UID4".utf8) + [1, 2, 0, 0] + Array("HLC8".utf8) + [7, 0, 0, 0, 0, 0, 0, 0]
            + Array("MTMT".utf8) + [5, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0] + Array("SH2H".utf8) + [UInt8](repeating: 0, count: 32)
            + Array("XATB".utf8) + [4, 0, 0, 0] + Array("DATB".utf8) + [3, 0, 0, 0]
        let entry = try parse(header(fields))
        #expect(entry.type == .regularFile)
        #expect(entry.path == AAHeaderRange(offset: 17, count: 1)) // After the magic, size, `TYP1`, and `PATP`'s size.
        #expect(entry.uid == 0x201)
        #expect(entry.hardLinkCluster == 7)
        #expect(entry.modificationTime?.seconds == 5 && entry.modificationTime?.nanoseconds == 9)
        #expect(entry.extendedAttributes?.offset == 0 && entry.extendedAttributes?.count == 4)
        #expect(entry.data?.offset == 4 && entry.data?.count == 3)
        #expect(entry.blobByteCount == 7)
    }

    // MARK: Keys

    /// The expander gives what BytesCrypto's HKDF (extract, then expand) gives, for the lengths the schedule uses and
    /// more.
    @Test(arguments: [1, 32, 33, 64, 80, 255])
    func keyExpanderMatchesHKDF(length: Int) {
        var key = Key32(repeating: 0)
        for index in 0..<32 {
            key[index] = UInt8(truncatingIfNeeded: index &* 37 &+ 11)
        }
        let info = KeyInfo("AEA_SK", index: 0x0102_0304)

        var pseudorandom = Key32(repeating: 0)
        var prkSpan = pseudorandom.mutableSpan
        var prk = MutableRawSpan(mutating: &prkSpan)
        HKDF<SHA256>.extract(salt: RawSpan(), inputKeyMaterial: key.span.bytes, into: &prk)
        var expected = [UInt8](repeating: 0, count: length)
        var expectedSpan = expected.mutableSpan
        var expectedBytes = MutableRawSpan(mutating: &expectedSpan)
        info.withBytes { HKDF<SHA256>.expand(pseudorandomKey: pseudorandom.span.bytes, info: $0, into: &expectedBytes) }

        var output = [UInt8](repeating: 0, count: length)
        var outputSpan = output.mutableSpan
        var outputBytes = MutableRawSpan(mutating: &outputSpan)
        let expander = KeyExpander(key)
        info.withBytes { expander.expand(info: $0, into: &outputBytes) }
        #expect(output == expected)
    }

    /// One expander serves many keys: each the same as a derivation of its own.
    @Test func dataKeysFromOneExpander() {
        var key = Key32(repeating: 0)
        for index in 0..<32 {
            key[index] = UInt8(index)
        }
        let expander = KeyExpander(key)
        for index in [0, 1, 255, 70_000] as [UInt32] {
            let shared = AEAKeys.expandDataKey(expander, KeyInfo("AEA_SK", index: index))
            let alone = AEAKeys.deriveDataKey(key, KeyInfo("AEA_SK", index: index))
            #expect(shared.mac.span.bytes.withUnsafeBytes { Array($0) } == alone.mac.span.bytes.withUnsafeBytes { Array($0) })
            #expect(shared.cipher.span.bytes.withUnsafeBytes { Array($0) } == alone.cipher.span.bytes.withUnsafeBytes { Array($0) })
            #expect(shared.iv.span.bytes.withUnsafeBytes { Array($0) } == alone.iv.span.bytes.withUnsafeBytes { Array($0) })
        }
    }

    // MARK: Memory

    // (The pool's activation test moved with the pool: BytesCompression's `BlockDecoderTests`.)

    /// Files by disk compression, counted in a table and made into the statistics' dictionary at the end.
    @Test func countsFilesByDiskCompression() {
        var counts = DiskCompressionCounts()
        for type: UInt32? in [nil, 0, 8, 8, 14, 15, 16, 300, 300] {
            counts.count(type)
        }
        var dictionary: [UInt32: Int] = [8: 1]
        counts.add(to: &dictionary)
        #expect(dictionary == [0: 2, 8: 3, 14: 1, 15: 1, 16: 1, 300: 2])
    }

    /// A file's contents are copied into each of Disk's write jobs (a 16,384-slot ring, made when an extraction starts).
    @Test func contentsAreSmall() {
        #expect(MemoryLayout<SegmentContents.Contents>.stride <= 48)
    }
}
