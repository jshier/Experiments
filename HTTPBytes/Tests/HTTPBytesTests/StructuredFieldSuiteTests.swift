import Bytes
import BytesTestSupport
import Foundation
import HTTPBytes
import Testing

// RFC 9651's test suite (httpwg/structured-field-tests): every parsing case, and every serialization case, through the
// public API. Parsed fields are turned into an owned model (with repeated keys merged as RFC 9651 does) and compared
// with the expected structure; the expected structure is serialized and compared with the canonical form.

// MARK: - The model

/// A bare item, owned. Decimals in thousandths (`nil` when a serialization case's value can't be one).
enum SFValue: Equatable, Sendable, CustomStringConvertible {
    case integer(Int64)
    case decimal(Int64?)
    case string([UInt8])
    case token([UInt8])
    case binary([UInt8])
    case boolean(Bool)
    case date(Int64)
    case display([UInt8])

    var description: String {
        switch self {
        case let .integer(value): "\(value)"
        case let .decimal(value): value.map { "\(Double($0) / 1000)" } ?? "decimal?"
        case let .string(value): "\"\(String(decoding: value, as: UTF8.self))\""
        case let .token(value): "token(\(String(decoding: value, as: UTF8.self)))"
        case let .binary(value): "binary(\(value))"
        case let .boolean(value): "\(value)"
        case let .date(value): "@\(value)"
        case let .display(value): "%\"\(String(decoding: value, as: UTF8.self))\""
        }
    }
}

struct SFParameter: Equatable, Sendable {
    var key: [UInt8]
    var value: SFValue
}

struct SFItem: Equatable, Sendable {
    var value: SFValue
    var parameters: [SFParameter]
}

enum SFMember: Equatable, Sendable {
    case item(SFItem)
    case innerList([SFItem], [SFParameter])
}

struct SFDictionaryMember: Equatable, Sendable {
    var key: [UInt8]
    var value: SFMember
}

enum SFField: Equatable, Sendable {
    case list([SFMember])
    case dictionary([SFDictionaryMember])
    case item(SFItem)
}

/// One test record.
struct SFCase: CustomTestStringConvertible, Sendable {
    var file: String
    var name: String
    var raw: [String]?
    var headerType: String
    var mustFail: Bool
    var canFail: Bool
    var canonical: [String]?
    /// The expected structure.
    var expected: SFField?

    var testDescription: String { "\(file): \(name)" }
}

// MARK: - Loading

enum SFSuite {
    static let parsingFiles = [
        "binary.json", "boolean.json", "date.json", "dictionary.json", "display-string.json", "examples.json", "item.json",
        "key-generated.json", "large-generated.json", "list.json", "listlist.json", "number-generated.json", "number.json",
        "param-dict.json", "param-list.json", "param-listlist.json", "string-generated.json", "string.json",
        "token-generated.json", "token.json",
    ]
    static let serializationFiles = [
        "serialisation-tests/key-generated.json", "serialisation-tests/number.json",
        "serialisation-tests/string-generated.json", "serialisation-tests/token-generated.json",
    ]

    static func cases(_ file: String) throws -> [SFCase] {
        let url = try TestData.file(set: "structured-field-tests", name: file)
        let records = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        return records.map { record in
            SFCase(file: file, name: record["name"] as! String, raw: record["raw"] as? [String],
                   headerType: record["header_type"] as! String, mustFail: record["must_fail"] as? Bool ?? false,
                   canFail: record["can_fail"] as? Bool ?? false, canonical: record["canonical"] as? [String],
                   expected: record["expected"].map { SFJSON.field($0, type: record["header_type"] as! String) })
        }
    }

    static var allParsingCases: [SFCase] { parsingFiles.flatMap { (try? cases($0)) ?? [] } }
    static var allSerializationCases: [SFCase] { serializationFiles.flatMap { (try? cases($0)) ?? [] } }
}

// MARK: - JSON to the model

enum SFJSON {
    static func field(_ json: Any, type: String) -> SFField {
        switch type {
        case "list": .list((json as! [Any]).map(member))
        case "dictionary":
            .dictionary((json as! [Any]).map { pair in
                let pair = pair as! [Any]
                return SFDictionaryMember(key: Array((pair[0] as! String).utf8), value: member(pair[1]))
            })
        default: .item(item(json))
        }
    }

    static func member(_ json: Any) -> SFMember {
        let pair = json as! [Any]
        if let items = pair[0] as? [Any] {
            return .innerList(items.map(item), parameters(pair[1]))
        }
        return .item(item(json))
    }

    static func item(_ json: Any) -> SFItem {
        let pair = json as! [Any]
        return SFItem(value: value(pair[0]), parameters: parameters(pair[1]))
    }

    static func parameters(_ json: Any) -> [SFParameter] {
        (json as! [Any]).map { pair in
            let pair = pair as! [Any]
            return SFParameter(key: Array((pair[0] as! String).utf8), value: value(pair[1]))
        }
    }

    static func value(_ json: Any) -> SFValue {
        if let number = json as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            if CFNumberIsFloatType(number) {
                return .decimal(HTTPStructuredDecimal(rounding: number.doubleValue)?.thousandths)
            }
            return .integer(number.int64Value)
        }
        if let string = json as? String { return .string(Array(string.utf8)) }
        let object = json as! [String: Any]
        switch object["__type"] as! String {
        case "token": return .token(Array((object["value"] as! String).utf8))
        case "binary": return .binary(base32((object["value"] as! String)))
        case "date": return .date((object["value"] as! NSNumber).int64Value)
        case "displaystring": return .display(Array((object["value"] as! String).utf8))
        default: fatalError("unknown type")
        }
    }

    /// RFC 4648 base32, padded.
    static func base32(_ text: String) -> [UInt8] {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for character in text.utf8 where character != UInt8(ascii: "=") {
            value = value << 5 | alphabet.firstIndex(of: character)!
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8(truncatingIfNeeded: value >> bits))
            }
        }
        return bytes
    }
}

// MARK: - Views to the model

enum SFViews {
    static func written(_ write: (inout AlignedBytesWriter) throws(BytesError) -> Void, count: Int) -> [UInt8] {
        try! [UInt8](alignedByteCapacity: count) { (writer) throws(BytesError) in try write(&writer) }
    }

    static func value(_ item: HTTPStructuredBareItem) -> SFValue {
        switch item {
        case let .integer(value): .integer(value)
        case let .decimal(value): .decimal(value.thousandths)
        case let .string(value): .string(written({ writer throws(BytesError) in try value.write(to: &writer) }, count: value.byteCount))
        case let .token(value): .token(sfArray(value))
        case let .byteSequence(value):
            .binary(written({ writer throws(BytesError) in try value.write(to: &writer) }, count: value.byteCount))
        case let .boolean(value): .boolean(value)
        case let .date(value): .date(value)
        case let .displayString(value):
            .display(written({ writer throws(BytesError) in try value.write(to: &writer) }, count: value.byteCount))
        }
    }

    /// Parameters in order, a repeated key's last value in its first place.
    static func parameters(_ parameters: HTTPStructuredParameters) -> [SFParameter] {
        var result: [SFParameter] = []
        var parameters = parameters
        while let parameter = parameters.next() {
            let key = sfArray(parameter.key), value = value(parameter.value)
            if let index = result.firstIndex(where: { $0.key == key }) { result[index].value = value } else { result.append(SFParameter(key: key, value: value)) }
        }
        return result
    }

    static func item(_ item: HTTPStructuredItem) -> SFItem {
        SFItem(value: value(item.bareItem), parameters: parameters(item.parameters))
    }

    static func member(_ member: HTTPStructuredMember) -> SFMember {
        switch member {
        case let .item(item): return .item(Self.item(item))
        case let .innerList(list):
            var items: [SFItem] = []
            var iterator = list
            while let item = iterator.next() {
                items.append(Self.item(item))
            }
            return .innerList(items, parameters(list.parameters))
        }
    }

    /// The field in `lines` (several field lines joined, as RFC 9651 §4.2 says), as the parser hands it out.
    static func field(_ lines: [[UInt8]], type: String) throws(HTTPStructuredFieldError) -> SFField {
        // One buffer, so every line's span has the same lifetime.
        let joined = lines.flatMap(\.self)
        var bounds: [Range<Int>] = []
        var start = 0
        for line in lines {
            bounds.append(start..<start + line.count)
            start += line.count
        }
        let all = joined.span.bytes
        switch type {
        case "list":
            var list = HTTPStructuredList(all.extracting(bounds[0]))
            var members: [SFMember] = []
            for index in bounds.indices {
                if index > 0 { try list.appendFieldLine(all.extracting(bounds[index])) }
                while let member = try list.next() {
                    members.append(Self.member(member))
                }
            }
            return .list(members)
        case "dictionary":
            var dictionary = HTTPStructuredDictionary(all.extracting(bounds[0]))
            var members: [SFDictionaryMember] = []
            for index in bounds.indices {
                if index > 0 { try dictionary.appendFieldLine(all.extracting(bounds[index])) }
                while let member = try dictionary.next() {
                    let key = sfArray(member.key), value = Self.member(member.value)
                    if let found = members.firstIndex(where: { $0.key == key }) { members[found].value = value } else {
                        members.append(SFDictionaryMember(key: key, value: value))
                    }
                }
            }
            return .dictionary(members)
        default:
            // An Item can't span lines: joined, they'd have a comma between them.
            guard lines.count == 1 else { throw .trailingBytes }
            return try .item(item(HTTPStructuredItem(parsing: all)))
        }
    }
}

func sfArray(_ span: RawSpan) -> [UInt8] {
    (0..<span.byteCount).map { span.load(fromByteOffset: $0, as: UInt8.self) }
}

// MARK: - Model to bytes, through the encoder

enum SFSerializer {
    enum Place {
        case bare
        case parameter([UInt8])
        case dictionaryMember([UInt8])
    }

    static func serialize(_ field: SFField) throws(HTTPStructuredFieldError) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 1 << 16)
        let count: Int
        do {
            var span = output.mutableSpan
            var writer = AlignedBytesWriter(&span)
            try write(field, to: &writer)
            count = writer.byteCount
        }
        return Array(output[..<count])
    }

    static func write(_ field: SFField, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        switch field {
        case let .item(item):
            try write(item, to: &writer)
        case let .list(members):
            for (index, member) in members.enumerated() {
                if index > 0 { try HTTPStructuredFieldEncoder.writeMemberSeparator(to: &writer) }
                switch member {
                case let .item(item): try write(item, to: &writer)
                case let .innerList(items, parameters): try writeInnerList(items, parameters, to: &writer)
                }
            }
        case let .dictionary(members):
            for (index, member) in members.enumerated() {
                if index > 0 { try HTTPStructuredFieldEncoder.writeMemberSeparator(to: &writer) }
                switch member.value {
                case let .item(item):
                    try write(item.value, at: .dictionaryMember(member.key), to: &writer)
                    try write(item.parameters, to: &writer)
                case let .innerList(items, parameters):
                    try HTTPStructuredFieldEncoder.writeDictionaryKey(member.key.span.bytes, to: &writer)
                    try writeInnerList(items, parameters, to: &writer)
                }
            }
        }
    }

    static func write(_ item: SFItem, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        try write(item.value, at: .bare, to: &writer)
        try write(item.parameters, to: &writer)
    }

    static func write(_ parameters: [SFParameter], to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        for parameter in parameters {
            try write(parameter.value, at: .parameter(parameter.key), to: &writer)
        }
    }

    static func writeInnerList(_ items: [SFItem], _ parameters: [SFParameter], to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        try HTTPStructuredFieldEncoder.writeInnerListStart(to: &writer)
        for (index, item) in items.enumerated() {
            if index > 0 { try HTTPStructuredFieldEncoder.writeInnerListSeparator(to: &writer) }
            try write(item, to: &writer)
        }
        try HTTPStructuredFieldEncoder.writeInnerListEnd(to: &writer)
        try write(parameters, to: &writer)
    }

    static func write(_ value: SFValue, at place: Place, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        switch value {
        case let .integer(value): try put(.integer(value), at: place, to: &writer)
        case let .decimal(value):
            guard let value, let decimal = HTTPStructuredDecimal(thousandths: value) else { throw .valueOutOfRange }
            try put(.decimal(decimal), at: place, to: &writer)
        case let .string(bytes):
            guard let string = HTTPStructuredString(bytes.span.bytes) else { throw .invalidString }
            try put(.string(string), at: place, to: &writer)
        case let .token(bytes): try put(.token(bytes.span.bytes), at: place, to: &writer)
        case let .binary(bytes): try put(.byteSequence(HTTPStructuredByteSequence(bytes.span.bytes)), at: place, to: &writer)
        case let .boolean(value): try put(.boolean(value), at: place, to: &writer)
        case let .date(value): try put(.date(value), at: place, to: &writer)
        case let .display(bytes):
            let text = String(decoding: bytes, as: UTF8.self)
            try put(.displayString(HTTPStructuredDisplayString(text.utf8Span)), at: place, to: &writer)
        }
    }

    static func put(_ value: HTTPStructuredBareItem, at place: Place, to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        switch place {
        case .bare: try HTTPStructuredFieldEncoder.writeBareItem(value, to: &writer)
        case let .parameter(key): try HTTPStructuredFieldEncoder.writeParameter(key: key.span.bytes, value: value, to: &writer)
        case let .dictionaryMember(key): try HTTPStructuredFieldEncoder.writeDictionaryMember(key: key.span.bytes, value: value, to: &writer)
        }
    }

    /// The parsed field re-serialized straight from the views (`writeList`, `writeDictionary`, `write(_ item:)`).
    static func reserialize(_ raw: [UInt8], type: String) throws(HTTPStructuredFieldError) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 1 << 16)
        let count: Int
        do {
            let input = raw.span.bytes
            var span = output.mutableSpan
            var writer = AlignedBytesWriter(&span)
            switch type {
            case "list": try HTTPStructuredFieldEncoder.writeList(HTTPStructuredList(input), to: &writer)
            case "dictionary": try HTTPStructuredFieldEncoder.writeDictionary(HTTPStructuredDictionary(input), to: &writer)
            default: try HTTPStructuredFieldEncoder.write(HTTPStructuredItem(parsing: input), to: &writer)
            }
            count = writer.byteCount
        }
        return Array(output[..<count])
    }
}

// MARK: - Tests

@Suite struct StructuredFieldSuiteTests {
    /// Every file is there and has cases (a missing set fails here, saying which `fetch` to run).
    @Test func suiteIsPresent() throws {
        for file in SFSuite.parsingFiles + SFSuite.serializationFiles {
            #expect(try !SFSuite.cases(file).isEmpty, "\(file)")
        }
    }

    /// Parsing: `must_fail` cases throw; the others parse to the expected structure (or, if `can_fail`, may throw),
    /// and the expected structure serializes to the canonical form, as do the parsed views themselves.
    @Test(arguments: SFSuite.allParsingCases)
    func parse(_ test: SFCase) throws {
        let lines = test.raw!.map { Array($0.utf8) }
        let parsed: SFField
        do throws(HTTPStructuredFieldError) {
            parsed = try SFViews.field(lines, type: test.headerType)
        } catch {
            #expect(test.mustFail || test.canFail, "failed: \(error)")
            return
        }
        guard !test.mustFail else {
            Issue.record("parsed what must fail: \(parsed)")
            return
        }
        let expected = test.expected!
        #expect(parsed == expected)
        // Serializing the expected structure gives the canonical form (`raw` if none is given; an empty List or
        // Dictionary, nothing).
        let canonical = test.canonical ?? test.raw!
        let serialized = try SFSerializer.serialize(expected)
        #expect(String(decoding: serialized, as: UTF8.self) == (canonical.first ?? ""))
        // So does the parsed field, re-serialized from its views (one line only: the views' writers take one).
        if lines.count == 1 {
            let reserialized = try SFSerializer.reserialize(lines[0], type: test.headerType)
            #expect(String(decoding: reserialized, as: UTF8.self) == (canonical.first ?? ""))
        }
    }

    /// The cases RFC 9651 lets a parser fail (`can_fail`) are all accepted, as its SHOULDs ask (unpadded Base64, nonzero
    /// pad bits, 15-digit dates), except strings spanning field lines, which an Item parser over one line can't see.
    @Test func lenientCases() {
        var rejected: [String] = []
        for test in SFSuite.allParsingCases where test.canFail {
            do throws(HTTPStructuredFieldError) {
                _ = try SFViews.field(test.raw!.map { Array($0.utf8) }, type: test.headerType)
            } catch {
                rejected.append(test.name)
            }
        }
        #expect(rejected.sorted() == ["two lines display string", "two lines string"])
    }

    /// Serialization: the expected structure serializes to the canonical form, or throws for `must_fail`.
    @Test(arguments: SFSuite.allSerializationCases)
    func serialize(_ test: SFCase) {
        let expected = test.expected!
        do throws(HTTPStructuredFieldError) {
            let serialized = try SFSerializer.serialize(expected)
            #expect(!test.mustFail, "serialized what must fail: \(String(decoding: serialized, as: UTF8.self))")
            if !test.mustFail {
                #expect(String(decoding: serialized, as: UTF8.self) == (test.canonical?.first ?? ""))
            }
        } catch {
            #expect(test.mustFail, "failed: \(error)")
        }
    }
}
