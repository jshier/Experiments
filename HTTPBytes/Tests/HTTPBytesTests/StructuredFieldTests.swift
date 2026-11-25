import Bytes
import HTTPBytes
import Testing

private func sfBytes(_ text: String) -> [UInt8] { Array(text.utf8) }

/// `body`'s output, written into a fresh buffer of `capacity` bytes.
private func sfWritten(capacity: Int = 1024, _ body: (inout AlignedBytesWriter) throws(HTTPStructuredFieldError) -> Void) throws(HTTPStructuredFieldError) -> String {
    var output = [UInt8](repeating: 0, count: capacity)
    let count: Int
    do {
        var span = output.mutableSpan
        var writer = AlignedBytesWriter(&span)
        try body(&writer)
        count = writer.byteCount
    }
    return String(decoding: output[..<count], as: UTF8.self)
}

@Suite struct StructuredFieldTests {
    /// The views' values: numbers as values, strings and byte sequences decoded on demand.
    @Test func itemViews() throws {
        let field = sfBytes(#"  "a \"quoted\" \\ string";q=0.5;x;n=-42  "#)
        let item = try HTTPStructuredItem(parsing: field.span.bytes)
        guard case let .string(string) = item.bareItem else { Issue.record("not a string"); return }
        let isEscaped = string.isEscaped, count = string.byteCount, value = String(string)
        #expect(isEscaped)
        let noUnescaped = string.unescapedBytes == nil
        #expect(noUnescaped)
        let equal = string.isEqual(to: sfBytes(#"a "quoted" \ string"#).span.bytes)
        let different = string.isEqual(to: sfBytes(#"a "quoted" \ strinG"#).span.bytes)
        let shorter = string.isEqual(to: sfBytes(#"a "quoted" \ strin"#).span.bytes)
        #expect(count == 19)
        #expect(value == #"a "quoted" \ string"#)
        #expect(equal && !different && !shorter)

        let parameters = item.parameters
        let hasParameters = !parameters.isEmpty
        #expect(hasParameters)
        if case let .decimal(q)? = parameters.value(forKey: sfBytes("q").span.bytes) {
            #expect(q.thousandths == 500)
            #expect(q.doubleValue == 0.5)
            #expect(q.description == "0.5")
        } else {
            Issue.record("no q")
        }
        if case let .boolean(x)? = parameters.value(forKey: sfBytes("x").span.bytes) { #expect(x) } else { Issue.record("no x") }
        if case let .integer(n)? = parameters.value(forKey: sfBytes("n").span.bytes) { #expect(n == -42) } else { Issue.record("no n") }
        let missing = parameters.value(forKey: sfBytes("z").span.bytes) == nil
        #expect(missing)
    }

    @Test func byteSequencesAndDisplayStrings() throws {
        let field = sfBytes(#"(:aGVsbG8=: :aGVsbG8: %"f%c3%bc%c3%bc" %"plain")"#)
        var list = HTTPStructuredList(field.span.bytes)
        guard case var .innerList(inner)? = try list.next() else { Issue.record("no inner list"); return }
        var decoded: [String] = []
        while let item = inner.next() {
            switch item.bareItem {
            case let .byteSequence(bytes):
                let isBase64 = bytes.isBase64, count = bytes.byteCount
                #expect(isBase64 && count == 5)
                let output = try [UInt8](alignedByteCapacity: bytes.byteCount) { (writer) throws(BytesError) in try bytes.write(to: &writer) }
                decoded.append(String(decoding: output, as: UTF8.self))
            case let .displayString(text):
                decoded.append(String(text))
                if text.isPercentEncoded {
                    let noUTF8 = text.utf8 == nil
                    #expect(noUTF8)
                    let count = text.byteCount
                    #expect(count == 5)
                } else {
                    let hasUTF8 = text.utf8 != nil
                    #expect(hasUTF8)
                }
            default:
                Issue.record("unexpected item")
            }
        }
        #expect(decoded == ["hello", "hello", "füü", "plain"])
        let ended = try list.next() == nil
        #expect(ended)
    }

    /// Decoding into a writer without room throws and writes nothing.
    @Test func decodingNeedsRoom() throws {
        let item = try HTTPStructuredItem(parsing: sfBytes(":aGVsbG8=:").span.bytes)
        guard case let .byteSequence(bytes) = item.bareItem else { Issue.record("not bytes"); return }
        var output = [UInt8](repeating: 0, count: 4)
        var span = output.mutableSpan
        var writer = AlignedBytesWriter(&span)
        #expect(throws: BytesError.insufficientCapacity) { try bytes.write(to: &writer) }
        #expect(writer.byteCount == 0)
    }

    /// A Dictionary's last value for a key; multiple field lines; errors where joining would leave an empty member.
    @Test func dictionariesAndFieldLines() throws {
        let joined = sfBytes("a=1, b=2;x, a=3" + "c=(1 2)")
        let all = joined.span.bytes
        var dictionary = HTTPStructuredDictionary(all.extracting(0..<15))
        guard case let .item(a)? = try dictionary.lastValue(forKey: sfBytes("a").span.bytes), case .integer(3) = a.bareItem else {
            Issue.record("a isn't 3")
            return
        }
        try dictionary.appendFieldLine(all.extracting(15..<joined.count))
        guard let member = try dictionary.next(), case .innerList = member.value else { Issue.record("no c"); return }
        let ended = try dictionary.next() == nil
        #expect(ended)

        // An empty line among several: a comma with nothing after it.
        let lines = sfBytes("1" + "" + "2")
        let lineBytes = lines.span.bytes
        var list = HTTPStructuredList(lineBytes.extracting(0..<1))
        while try list.next() != nil {}
        try list.appendFieldLine(lineBytes.extracting(1..<1))
        do throws(HTTPStructuredFieldError) {
            _ = try list.next()
            Issue.record("parsed an empty line")
        } catch {
            #expect(error == .missingMember)
        }
        // An empty first line.
        var empty = HTTPStructuredList(lineBytes.extracting(0..<0))
        let emptyEnded = try empty.next() == nil
        #expect(emptyEnded)
        do throws(HTTPStructuredFieldError) {
            try empty.appendFieldLine(lineBytes.extracting(1..<2))
            Issue.record("appended after an empty line")
        } catch {
            #expect(error == .missingMember)
        }
    }

    /// Errors say what was wrong, and a parser that threw throws again.
    @Test func errors() {
        let cases: [(String, HTTPStructuredFieldError)] = [
            ("1, 2,", .missingMember), ("1 2", .missingSeparator), ("(1 2", .invalidInnerList), ("(1,2)", .invalidInnerList),
            ("\"abc", .invalidString), ("\"a\\b\"", .invalidString), (":abc", .invalidByteSequence), ("?2", .invalidBoolean),
            ("@1.5", .invalidDate), ("%\"%C3\"", .invalidDisplayString), ("1;A=2", .invalidKey), ("1234567890123456", .invalidInteger),
            ("1.2345", .invalidDecimal), ("a;b=", .invalidBareItem), ("!", .invalidBareItem),
        ]
        for (text, error) in cases {
            let field = sfBytes(text)
            var list = HTTPStructuredList(field.span.bytes)
            #expect(throws: error, "\(text)") { while try list.next() != nil {} }
            #expect(throws: error, "\(text), again") { while try list.next() != nil {} }
        }
        #expect(throws: HTTPStructuredFieldError.trailingBytes) { _ = try HTTPStructuredItem(parsing: sfBytes("1 2").span.bytes) }
    }

    /// Decimals: rounding to thousandths, ties to even as written in decimal.
    @Test func decimals() {
        #expect(HTTPStructuredDecimal(rounding: 0.5015)?.thousandths == 502)
        #expect(HTTPStructuredDecimal(rounding: 0.5025)?.thousandths == 502)
        #expect(HTTPStructuredDecimal(rounding: -0.0015)?.thousandths == -2)
        #expect(HTTPStructuredDecimal(rounding: 2.0005)?.thousandths == 2000)
        #expect(HTTPStructuredDecimal(rounding: 1.0004)?.thousandths == 1000)
        #expect(HTTPStructuredDecimal(rounding: 1.0006)?.thousandths == 1001)
        #expect(HTTPStructuredDecimal(rounding: 999_999_999_999.9996) == nil)
        #expect(HTTPStructuredDecimal(rounding: .nan) == nil)
        #expect(HTTPStructuredDecimal(thousandths: 1_000_000_000_000_000) == nil)
        #expect(HTTPStructuredDecimal(thousandths: -1_250)?.description == "-1.25")
        #expect(HTTPStructuredDecimal(thousandths: 10_000)?.description == "10.0")
    }

    /// Values serialize canonically; invalid ones throw and leave the writer where it was.
    @Test func encoder() throws {
        let key = sfBytes("key"), token = sfBytes("text/html"), text = sfBytes(#"say "hi" \o/"#), binary: [UInt8] = [0xFF, 0x00, 0x10]
        let display = "naïve 100%"
        let output = try sfWritten { writer throws(HTTPStructuredFieldError) in
            try HTTPStructuredFieldEncoder.writeBareItem(.token(token.span.bytes), to: &writer)
            try HTTPStructuredFieldEncoder.writeParameter(key: key.span.bytes, value: .boolean(true), to: &writer)
            try HTTPStructuredFieldEncoder.writeParameter(key: key.span.bytes, value: .boolean(false), to: &writer)
            try HTTPStructuredFieldEncoder.writeMemberSeparator(to: &writer)
            try HTTPStructuredFieldEncoder.writeBareItem(.string(HTTPStructuredString(text.span.bytes)!), to: &writer)
            try HTTPStructuredFieldEncoder.writeMemberSeparator(to: &writer)
            try HTTPStructuredFieldEncoder.writeInnerListStart(to: &writer)
            try HTTPStructuredFieldEncoder.writeBareItem(.byteSequence(HTTPStructuredByteSequence(binary.span.bytes)), to: &writer)
            try HTTPStructuredFieldEncoder.writeInnerListSeparator(to: &writer)
            try HTTPStructuredFieldEncoder.writeBareItem(.displayString(HTTPStructuredDisplayString(display.utf8Span)), to: &writer)
            try HTTPStructuredFieldEncoder.writeInnerListSeparator(to: &writer)
            try HTTPStructuredFieldEncoder.writeBareItem(.date(-1), to: &writer)
            try HTTPStructuredFieldEncoder.writeInnerListEnd(to: &writer)
        }
        #expect(output == #"text/html;key;key=?0, "say \"hi\" \\o/", (:/wAQ: %"na%c3%afve 100%25" @-1)"#)

        let bad = sfBytes("Key"), badToken = sfBytes("1abc")
        let empty = try sfWritten { writer throws(HTTPStructuredFieldError) in
            #expect(throws: HTTPStructuredFieldError.invalidKey) {
                try HTTPStructuredFieldEncoder.writeParameter(key: bad.span.bytes, value: .integer(1), to: &writer)
            }
            #expect(throws: HTTPStructuredFieldError.invalidToken) {
                try HTTPStructuredFieldEncoder.writeDictionaryMember(key: key.span.bytes, value: .token(badToken.span.bytes), to: &writer)
            }
            #expect(throws: HTTPStructuredFieldError.valueOutOfRange) {
                try HTTPStructuredFieldEncoder.writeBareItem(.integer(1_000_000_000_000_000), to: &writer)
            }
        }
        #expect(empty == "")
        let rejected = HTTPStructuredString(sfBytes("tab\there").span.bytes) == nil
        #expect(rejected)

        // Out of room partway: rewound.
        #expect(throws: HTTPStructuredFieldError.insufficientCapacity) {
            _ = try sfWritten(capacity: 8) { writer throws(HTTPStructuredFieldError) in
                try HTTPStructuredFieldEncoder.writeBareItem(.integer(1), to: &writer)
                do throws(HTTPStructuredFieldError) {
                    try HTTPStructuredFieldEncoder.writeBareItem(.string(HTTPStructuredString(text.span.bytes)!), to: &writer)
                } catch {
                    #expect(writer.byteCount == 1)
                    throw error
                }
            }
        }
    }

    /// Parsed fields re-serialize canonically, repeated keys merged in the place of the first.
    @Test func reserializing() throws {
        let field = sfBytes("a=1;x=1;y;x=?0,  b=(1   2);z, a=%\"%61%25\";p, c")
        let output = try sfWritten { writer throws(HTTPStructuredFieldError) in
            try HTTPStructuredFieldEncoder.writeDictionary(HTTPStructuredDictionary(field.span.bytes), to: &writer)
        }
        #expect(output == #"a=%"a%25";p, b=(1 2);z, c"#)
        let item = sfBytes(":iZ==:;k=:aGVsbG8:")
        let reserialized = try sfWritten { writer throws(HTTPStructuredFieldError) in
            try HTTPStructuredFieldEncoder.write(HTTPStructuredItem(parsing: item.span.bytes), to: &writer)
        }
        #expect(reserialized == ":iQ==:;k=:aGVsbG8=:")
    }

    /// Long strings, tokens, and byte sequences, scanned 16 bytes at a time: every length up to 80, and a stop at every
    /// place.
    @Test func longValues() throws {
        for length in 0...80 {
            let plain = String(repeating: "x", count: length)
            for field in ["\"\(plain)\"", "t\(plain)", ":\(String(repeating: "QUJD", count: length / 4)):", "%\"\(plain)\""] {
                let item = try HTTPStructuredItem(parsing: sfBytes(field).span.bytes)
                let output = try sfWritten { writer throws(HTTPStructuredFieldError) in
                    try HTTPStructuredFieldEncoder.write(item, to: &writer)
                }
                #expect(output == field)
            }
            // A bad byte at each place in a string, a token, and a display string.
            for place in 0..<length {
                var bytes = sfBytes("\"\(plain)\"")
                bytes[1 + place] = 0x7F
                #expect(throws: HTTPStructuredFieldError.invalidString) { _ = try HTTPStructuredItem(parsing: bytes.span.bytes) }
                var token = sfBytes("t\(plain)")
                token[1 + place] = 0x22
                #expect(throws: HTTPStructuredFieldError.trailingBytes) { _ = try HTTPStructuredItem(parsing: token.span.bytes) }
                var display = sfBytes("%\"\(plain)\"")
                display[2 + place] = 0xC3
                #expect(throws: HTTPStructuredFieldError.invalidDisplayString) { _ = try HTTPStructuredItem(parsing: display.span.bytes) }
            }
        }
    }
}

@Suite struct PriorityTests {
    private func priority(_ text: String) throws(HTTPStructuredFieldError) -> HTTPPriority {
        try HTTPPriority(parsing: sfBytes(text).span.bytes)
    }

    @Test func parsing() throws {
        #expect(try priority("") == .default)
        #expect(try priority("u=5, i") == HTTPPriority(urgency: 5, isIncremental: true))
        #expect(try priority("i=?0, u=0") == HTTPPriority(urgency: 0))
        #expect(try priority("u=1;a=b, x=(1 2), i;q") == HTTPPriority(urgency: 1, isIncremental: true))
        // Out of range or of another type: ignored, so the default.
        #expect(try priority("u=8, i=1") == .default)
        #expect(try priority("u=-1") == .default)
        #expect(try priority("u=2.0") == .default)
        #expect(try priority("u=(1), i=\"yes\"") == .default)
        // The last value counts, even when it's ignored.
        #expect(try priority("u=2, u=9") == .default)
        #expect(try priority("u=9, u=2") == HTTPPriority(urgency: 2))
        // Not a Dictionary.
        #expect(throws: HTTPStructuredFieldError.invalidKey) { _ = try priority("U=1") }
        #expect(throws: HTTPStructuredFieldError.missingMember) { _ = try priority("u=1,") }
    }

    @Test func fieldLines() throws {
        let lines = sfBytes("u=6" + "i")
        let lineBytes = lines.span.bytes
        var dictionary = HTTPStructuredDictionary(lineBytes.extracting(0..<3))
        var priority = HTTPPriority()
        try priority.update(from: &dictionary)
        try dictionary.appendFieldLine(lineBytes.extracting(3..<4))
        try priority.update(from: &dictionary)
        #expect(priority == HTTPPriority(urgency: 6, isIncremental: true))
    }

    @Test func serializing() throws {
        for (priority, text) in [(HTTPPriority.default, ""), (HTTPPriority(urgency: 0), "u=0"),
                                 (HTTPPriority(isIncremental: true), "i"), (HTTPPriority(urgency: 7, isIncremental: true), "u=7, i")] {
            let output = try sfWritten { writer throws(HTTPStructuredFieldError) in try priority.write(to: &writer) }
            #expect(output == text)
            #expect(priority.description == text)
            #expect(try HTTPPriority(parsing: sfBytes(output).span.bytes) == priority)
        }
        #expect(throws: HTTPStructuredFieldError.insufficientCapacity) {
            _ = try sfWritten(capacity: 5) { writer throws(HTTPStructuredFieldError) in try HTTPPriority(urgency: 7, isIncremental: true).write(to: &writer) }
        }
    }
}
