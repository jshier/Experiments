import Bytes
import BytesTestSupport
import Foundation
import HTTP3
import HTTPBytes

/// Bytes from hex digits, ignoring spaces and newlines.
func hexBytes(_ text: String) -> [UInt8] {
    let digits = Array(text.utf8.filter { $0 != 0x20 && $0 != 0x0A })
    precondition(digits.count % 2 == 0, "an odd number of hex digits")
    func value(_ digit: UInt8) -> UInt8 {
        switch digit {
        case 0x30...0x39: digit - 0x30
        case 0x61...0x66: digit - 0x61 + 10
        case 0x41...0x46: digit - 0x41 + 10
        default: preconditionFailure("not a hex digit")
        }
    }
    return stride(from: 0, to: digits.count, by: 2).map { value(digits[$0]) << 4 | value(digits[$0 + 1]) }
}

/// A span's bytes as a string (Latin-1, so any byte survives).
func text(_ bytes: RawSpan) -> String {
    String((0..<bytes.byteCount).map { Character(Unicode.Scalar(bytes.load(fromByteOffset: $0, as: UInt8.self))) })
}

/// Latin-1 bytes of a string's characters (test data is ASCII).
func latin1(_ string: String) -> [UInt8] {
    string.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
}

/// A decoded field as plain values.
struct Field: Equatable, CustomStringConvertible {
    var name: [UInt8]
    var value: [UInt8]
    var neverIndexed = false

    init(name: [UInt8], value: [UInt8], neverIndexed: Bool = false) {
        self.name = name
        self.value = value
        self.neverIndexed = neverIndexed
    }

    init(_ name: String, _ value: String, neverIndexed: Bool = false) {
        self.init(name: latin1(name), value: latin1(value), neverIndexed: neverIndexed)
    }

    /// Name and value: the N bit is checked where it matters (the automatic policy sets it on short cookies).
    static func ==(lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name && lhs.value == rhs.value }

    var description: String {
        "\(String(decoding: name, as: UTF8.self)): \(String(decoding: value, as: UTF8.self))\(neverIndexed ? " (N)" : "")"
    }
}

/// Every field of `section` (which must not be blocked), or `nil` if it's blocked.
func decodeSection(_ decoder: inout QPACKDecoder, _ section: [UInt8], stream: UInt64) throws(QPACKError) -> [Field]? {
    let span = section.span.bytes
    guard try decoder.begin(span, stream: stream) else { return nil }
    var fields: [Field] = []
    while let field = try decoder.next(in: span) {
        fields.append(Field(name: Array(copying: field.name), value: Array(copying: field.value), neverIndexed: field.isNeverIndexed))
    }
    return fields
}

/// The decoder's dynamic table, oldest first.
func tableEntries(_ decoder: borrowing QPACKDecoder) -> [Field] {
    ((decoder.insertCount - decoder.tableCount)..<decoder.insertCount).map { index in
        let entry = decoder.tableEntry(absoluteIndex: index)
        return Field(name: Array(copying: entry.name), value: Array(copying: entry.value))
    }
}

/// The decoder's pending decoder stream bytes.
func decoderInstructions(_ decoder: inout QPACKDecoder) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: 4_096)
    let written = output.withOutputRawSpan { span -> Int in
        decoder.writeDecoderInstructions(into: &span)
        return span.byteCount
    }
    return Array(output[0..<written])
}

/// Applies encoder stream bytes, all of which must be complete instructions.
func applyEncoderStream(_ decoder: inout QPACKDecoder, _ bytes: [UInt8]) throws(QPACKError) {
    let used = try decoder.processEncoderStream(bytes.span.bytes)
    precondition(used == bytes.count, "a complete instruction stream")
}

/// A field store from fields.
func store(_ fields: [Field]) -> HTTPFieldStore {
    var store = HTTPFieldStore()
    for field in fields {
        let view = HTTPFieldView(name: field.name.span.bytes, value: field.value.span.bytes,
                                 knownName: HTTPFieldName(lowercase: field.name.span.bytes))
        try! store.append(view, flags: field.neverIndexed ? HTTPFieldStore.neverIndexed : 0)
    }
    return store
}

/// One encoded section and the encoder stream bytes written with it.
struct EncodedSection {
    var section: [UInt8]
    var instructions: [UInt8]
}

/// Encodes `fields` as stream `stream`'s section.
func encodeSection(_ encoder: inout QPACKEncoder, _ fields: borrowing HTTPFieldStore, stream: UInt64,
                   indexing: QPACKIndexingStrategy = .automatic) throws(QPACKError) -> EncodedSection {
    var section = [UInt8](repeating: 0, count: 1 << 17)
    var instructions = [UInt8](repeating: 0, count: 1 << 17)
    var instructionCount = 0
    let sectionCount = try section.withOutputRawSpan { sectionSpan throws(QPACKError) -> Int in
        try instructions.withOutputRawSpan { instructionSpan throws(QPACKError) -> Int in
            defer { instructionCount = instructionSpan.byteCount }
            try encoder.encode(fields, stream: stream, indexing: indexing, into: &sectionSpan, instructions: &instructionSpan)
            return sectionSpan.byteCount
        }
    }
    return EncodedSection(section: Array(section[0..<sectionCount]), instructions: Array(instructions[0..<instructionCount]))
}

// MARK: - The QIF interop corpus

/// The qifs corpus (`Tools/test-data fetch qifs`): QIF files (field sections as `name TAB value` lines, a blank line
/// between them) and their encodings by several QPACK implementations, in the offline interop format: records of an
/// 8-byte stream ID (0 for the encoder stream), a 4-byte length, and the bytes, big-endian. Section i of a QIF file is
/// stream i + 1. File names end `.<table capacity>.<blocked streams>.<acknowledgment mode>`.
enum QIFCorpus {
    /// A QIF file's sections.
    static func sections(_ name: String) throws -> [[Field]] {
        let url = try TestData.file(set: "qifs", name: "qifs/\(name).qif")
        let text = try String(contentsOf: url, encoding: .isoLatin1)
        return parse(text)
    }

    /// QIF text's sections.
    static func parse(_ text: String) -> [[Field]] {
        var sections: [[Field]] = [], current: [Field] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") { continue }
            if line.isEmpty {
                if !current.isEmpty { sections.append(current) }
                current = []
                continue
            }
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            current.append(Field(String(parts[0]), parts.count > 1 ? String(parts[1]) : ""))
        }
        if !current.isEmpty { sections.append(current) }
        return sections
    }

    /// The encoded files: (path below `encoded/`, QIF name, table capacity, blocked streams).
    static func encodedFiles() -> [(path: String, qif: String, capacity: Int, blocked: Int)] {
        guard let root = try? TestData.file(set: "qifs", name: "encoded") else { return [] }
        let base = root.path(percentEncoded: false)
        var files: [(String, String, Int, Int)] = []
        guard let enumerator = FileManager.default.enumerator(atPath: base) else { return [] }
        let qifs = ["draft-examples", "fb-req-hq", "fb-req", "fb-resp-hq", "fb-resp", "netbsd-hq", "netbsd"]
        for case let path as String in enumerator where !path.hasPrefix("errors") {
            let name = (path as NSString).lastPathComponent
            let parts = name.split(separator: ".")
            guard parts.count >= 4, let capacity = Int(parts[parts.count - 3]), let blocked = Int(parts[parts.count - 2]) else { continue }
            // The QIF's name is the file name's first part ("examples" is the draft's examples).
            let first = String(parts[0])
            let qif = first == "examples" ? "draft-examples" : first
            guard qifs.contains(qif) else { continue }
            files.append((path, qif, capacity, blocked))
        }
        return files.sorted { $0.0 < $1.0 }
    }

    /// An encoded file's records.
    static func records(_ path: String) throws -> [(stream: UInt64, bytes: [UInt8])] {
        let data = try [UInt8](Data(contentsOf: TestData.file(set: "qifs", name: "encoded/\(path)")))
        var records: [(UInt64, [UInt8])] = []
        var offset = 0
        while offset + 12 <= data.count {
            var stream: UInt64 = 0
            for index in 0..<8 {
                stream = stream << 8 | UInt64(data[offset + index])
            }
            var length = 0
            for index in 8..<12 {
                length = length << 8 | Int(data[offset + index])
            }
            offset += 12
            guard offset + length <= data.count else { break }
            records.append((stream, Array(data[offset..<offset + length])))
            offset += length
        }
        return records
    }

    /// Decodes an encoded file as a peer would: encoder stream bytes as they come, sections when they can be decoded
    /// (held while blocked). Returns each stream's fields. Draft 05's table started at its maximum capacity (draft 06
    /// added Set Dynamic Table Capacity and a table starting at 0): `startsFull` applies that instruction first.
    static func decode(_ path: String, capacity: Int, blocked: Int, startsFull: Bool = false) throws -> [UInt64: [Field]] {
        var decoder = QPACKDecoder(maximumTableCapacity: capacity, maximumBlockedStreams: blocked, maximumFieldSectionSize: 1 << 20)
        if startsFull {
            var instruction = [UInt8](repeating: 0, count: 8)
            let count = instruction.withOutputRawSpan { span -> Int in
                try! HPACKPrefixInteger.write(capacity, prefixBits: 5, flags: 0x20, into: &span)
                return span.byteCount
            }
            try applyEncoderStream(&decoder, Array(instruction[0..<count]))
        }
        var held: [UInt64: [UInt8]] = [:]
        var decoded: [UInt64: [Field]] = [:]
        var pending: [UInt8] = []
        for (stream, bytes) in try records(path) {
            if stream == 0 {
                pending += bytes
                let used = try decoder.processEncoderStream(pending.span.bytes)
                pending.removeFirst(used)
                while let unblocked = decoder.nextUnblockedStream() {
                    let section = held.removeValue(forKey: unblocked)!
                    decoded[unblocked] = try decodeSection(&decoder, section, stream: unblocked)
                    _ = decoderInstructions(&decoder)
                }
            } else if let fields = try decodeSection(&decoder, bytes, stream: stream) {
                decoded[stream] = fields
            } else {
                held[stream] = bytes
            }
            _ = decoderInstructions(&decoder)
        }
        if !held.isEmpty { throw QIFError.stillBlocked(Array(held.keys)) }
        return decoded
    }

    enum QIFError: Error { case stillBlocked([UInt64]) }
}
