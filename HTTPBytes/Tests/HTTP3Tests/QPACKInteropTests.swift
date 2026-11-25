import Bytes
import BytesTesting
import BytesTestSupport
import Foundation
import HTTP3
import HTTPBytes
import Testing

/// The qifs offline interop corpus (`Tools/test-data fetch qifs`): every implementation's encodings must decode to their
/// QIF files' sections, in order. `encoded/qpack-05` (`qpack-06` is a link to it) is RFC 9204's wire format but for one
/// thing: the table starts at its maximum capacity, as drafts before Set Dynamic Table Capacity had it (the harness
/// applies that instruction first). Drafts 02 and 03 (absolute indexes from 1, an older static table) aren't tested.
enum QIFInterop {
    /// The files of draft 05, which must decode: 528 encodings of the six QIF files by six implementations.
    static func currentFiles() -> [(path: String, qif: String, capacity: Int, blocked: Int)] {
        // The examples file's QIF doesn't match its bytes (Appendix B's tests cover them).
        QIFCorpus.encodedFiles().filter { $0.path.hasPrefix("qpack-05/") && $0.qif != "draft-examples" }
    }

    /// Decodes one file and compares every section with its QIF's; returns a description of the first difference, or
    /// `nil`.
    static func check(_ file: (path: String, qif: String, capacity: Int, blocked: Int)) -> String? {
        let expected: [[Field]]
        let decoded: [UInt64: [Field]]
        do {
            expected = try QIFCorpus.sections(file.qif)
            decoded = try QIFCorpus.decode(file.path, capacity: file.capacity, blocked: file.blocked, startsFull: true)
        } catch {
            return "\(file.path): \(error)"
        }
        guard decoded.count == expected.count else { return "\(file.path): \(decoded.count) sections, expected \(expected.count)" }
        for (index, fields) in expected.enumerated() {
            guard let got = decoded[UInt64(index + 1)] else { return "\(file.path): no stream \(index + 1)" }
            if got != fields {
                let first = (0..<min(got.count, fields.count)).first { got[$0] != fields[$0] } ?? min(got.count, fields.count)
                return "\(file.path): stream \(index + 1) field \(first): \(first < got.count ? got[first].description : "end") != \(first < fields.count ? fields[first].description : "end")"
            }
        }
        return nil
    }
}

@Suite struct QPACKInteropTests {
    /// One file of each implementation for two table configurations: a 4,096-byte table with blocking allowed,
    /// and a 256-byte one (many evictions) without.
    @Test(arguments: QIFInterop.currentFiles().filter {
        $0.qif == "fb-resp-hq" && ($0.capacity == 4_096 && $0.blocked > 0 || $0.capacity == 256 && $0.blocked == 0)
    }.map(\.path))
    func decodesInteropFile(_ path: String) throws {
        let file = try #require(QIFInterop.currentFiles().first { $0.path == path })
        let difference = QIFInterop.check(file)
        #expect(difference == nil, "\(difference ?? "")")
    }

    @Test func corpusIsPresent() {
        #expect(QIFInterop.currentFiles().count >= 500, "Tools/test-data fetch qifs")
    }
}

@Suite(.bulk) struct QPACKInteropBulkTests {
    /// Every file: 528 encodings of the six QIF files by six implementations, at table capacities 256, 512, and 4,096, with
    /// and without blocked streams, and with and without acknowledgments.
    @Test func decodesEveryInteropFile() {
        var failures: [String] = []
        for file in QIFInterop.currentFiles() {
            if let difference = QIFInterop.check(file) { failures.append(difference) }
        }
        #expect(failures.isEmpty, "\(failures.count) files: \(failures.joined(separator: "\n"))")
    }
}
