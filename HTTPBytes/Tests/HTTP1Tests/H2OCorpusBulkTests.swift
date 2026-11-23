import BytesTestSupport
import BytesTesting
import Foundation
import HTTP1
import HTTPBytes
import Testing

/// h2o's HTTP/1 fuzzing corpus (h2o/h2o at d3e43fc, MIT: fuzz/http1-corpus, the 1,972 request inputs its fuzzer kept),
/// as the h2o-http1-corpus set has it, with llhttp's verdict on each (built from the llhttp set by the generator). Each
/// input is read as a whole request by HTTPBytes and checked three ways: nothing traps (strict and with bare LF allowed),
/// the outcome is the same when the bytes arrive in two pieces split anywhere or a byte at a time, and the verdict agrees
/// with llhttp's (accepted requests ending at the same byte), except in the `differences` categories, each with why.
@Suite(.bulk) struct H2OCorpusBulkTests {
    struct Input {
        let name: String
        let bytes: [UInt8]
        /// llhttp's verdict, offset, and error name.
        let llhttp: (verdict: String, offset: Int, error: String)
    }

    static let inputs: [Input] = {
        guard let verdicts = try? TestData.file(set: "h2o-http1-corpus", name: "llhttp-verdicts.tsv"),
              let text = try? String(contentsOf: verdicts, encoding: .utf8) else { return [] }
        let corpus = verdicts.deletingLastPathComponent().appending(path: "corpus")
        return text.split(separator: "\n").compactMap { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let data = try? Data(contentsOf: corpus.appending(path: columns[0])) else { return nil }
            return Input(name: columns[0], bytes: Array(data),
                         llhttp: (columns[1], Int(columns[2]) ?? -1, columns.count > 3 ? columns[3] : ""))
        }
    }()

    /// Kinds of disagreement with llhttp, by our outcome and llhttp's: "ours / llhttp" → why.
    static let differences: [String: String] = [
        "accept / reject HPE_INVALID_METHOD": "methods are tokens (RFC 9110 §9: extensible); llhttp knows a fixed list",
        "partial head / reject HPE_INVALID_METHOD": "`&` is a token character, so it may start an extension method: more bytes are needed",
        "accept / reject HPE_UNEXPECTED_CONTENT_LENGTH":
            "identical Content-Length fields are one value (RFC 9112 §6.3 lets a recipient accept them); llhttp rejects any repeat",
        "accept / reject HPE_INVALID_URL (a request-target)": "llhttp rejects targets RFC 9112 §3.2 and RFC 3986 allow",
        "partial body / reject HPE_INVALID_URL (a request-target)":
            "llhttp rejects targets RFC 9112 §3.2 allows (`masque:y-test` is an absolute URI); HTTPBytes waits for the body",
        "reject head unsupportedVersion / accept": "HTTP/2.0 in a request line isn't HTTP/1 (505); llhttp parses it",
    ]

    /// Kinds where HTTPBytes falls short of RFC 9112: checked as known issues.
    static let knownIssues: [String: String] = [
        "accept / reject HPE_INVALID_URL (not a request-target)": "the request target's form isn't checked (RFC 9112 §3.2)",
    ]

    /// The disagreement's kind: our verdict (with the error), then llhttp's (with its error name).
    static func category(_ input: [UInt8], _ ours: Conformance.Outcome, _ llhttp: (verdict: String, offset: Int, error: String)) -> String {
        let mine = switch ours {
        case .accept: "accept"
        case .reject(let error, let stage): "reject \(stage.rawValue) \(error)"
        case .partial(let stage): "partial \(stage.rawValue)"
        }
        var category = "\(mine) / \(llhttp.verdict)\(llhttp.error.isEmpty ? "" : " \(llhttp.error)")"
        // Whether llhttp's URL complaint is about a target RFC 9112 allows.
        if llhttp.error == "HPE_INVALID_URL" {
            var options = Conformance.Options()
            options.headOnly = true
            if let message = Conformance.parse(input, options: options).message {
                category += HTTParseTests.isRequestTarget(message.target, method: message.method) ? " (a request-target)" : " (not a request-target)"
            }
        }
        return category
    }

    @Test func agreesWithLLHTTP() throws {
        try #require(!Self.inputs.isEmpty, "run Tools/test-data fetch h2o llhttp h2o-http1-corpus")
        #expect(Self.inputs.count == 1_972)
        var counts: [String: Int] = [:], examples: [String: String] = [:]
        var mismatchedEnds: [String] = []
        for input in Self.inputs {
            var options = Conformance.Options()
            options.closesAtEnd = false
            let ours = Conformance.parse(input.bytes, options: options)
            if case .accept(let message) = ours, input.llhttp.verdict == "accept" {
                if message.end != input.llhttp.offset {
                    mismatchedEnds.append("\(input.name): ends at \(message.end); llhttp \(input.llhttp.offset) [\(Conformance.escaped(input.bytes))]")
                }
                continue
            }
            if ours.verdict == input.llhttp.verdict { continue }
            let category = Self.category(input.bytes, ours, input.llhttp)
            counts[category, default: 0] += 1
            examples[category] = examples[category] ?? "\(input.name) [\(Conformance.escaped(input.bytes, limit: 200))]"
        }
        // Both accept: they must agree where the request ends, or a pipelined request after it starts in two places.
        #expect(mismatchedEnds.isEmpty, "\(mismatchedEnds.joined(separator: "\n"))")
        for (category, issue) in Self.knownIssues {
            withKnownIssue(Comment(rawValue: issue)) {
                #expect(counts[category] == nil, "\(category): \(counts[category] ?? 0), e.g. \(examples[category] ?? "")")
            }
        }
        let unexplained = counts.keys.filter { Self.differences[$0] == nil && Self.knownIssues[$0] == nil }.sorted()
        #expect(unexplained.isEmpty, """
            \(unexplained.map { "\($0): \(counts[$0]!), e.g. \(examples[$0]!)" }.joined(separator: "\n"))
            """)
        let stale = Self.differences.keys.filter { counts[$0] == nil }.sorted()
        #expect(stale.isEmpty, "differences that no longer occur: \(stale)")
    }

    static func splitPoints(_ count: Int) -> [Int] {
        Array(1..<max(1, min(count, 2048))) + (count > 2048 ? Array(stride(from: 2048, to: count, by: 37)) : [])
    }

    /// Whole, in two pieces split at every byte, and a byte at a time: the same outcome. With bare LF allowed too (more of
    /// the corpus gets past the head, into framing and bodies).
    @Test func splitsDontChangeTheOutcome() throws {
        try #require(!Self.inputs.isEmpty, "run Tools/test-data fetch h2o llhttp h2o-http1-corpus")
        var report: [String] = []
        for input in Self.inputs {
            for allowsBareLineFeed in [false, true] {
                var options = Conformance.Options()
                options.head.allowsBareLineFeed = allowsBareLineFeed
                options.chunked.allowsBareLineFeed = allowsBareLineFeed
                options.closesAtEnd = false
                let whole = Conformance.parse(input.bytes, options: options)
                let bytewise = Conformance.parse(input.bytes, options: options, splits: Array(1..<max(1, input.bytes.count)))
                if bytewise != whole {
                    report.append("\(input.name) (bare LF \(allowsBareLineFeed)) byte at a time: \(bytewise); whole: \(whole)")
                    continue
                }
                // Every split point in the first 2 KiB (where heads end), then every 37th byte: the corpus' largest inputs
                // are 16 KiB, and every split of every input would be 2.5 GB of parsing.
                for split in Self.splitPoints(input.bytes.count) {
                    let pieces = Conformance.parse(input.bytes, options: options, splits: [split])
                    if pieces != whole {
                        report.append("\(input.name) (bare LF \(allowsBareLineFeed)) split at \(split): \(pieces); whole: \(whole)")
                        break
                    }
                }
            }
        }
        #expect(report.isEmpty, "\(report.count):\n\(report.prefix(50).joined(separator: "\n"))")
    }

    /// Every input as a response too (to a GET and to a HEAD): nothing traps, and splits don't change the outcome.
    @Test func responsesDontTrap() throws {
        try #require(!Self.inputs.isEmpty, "run Tools/test-data fetch h2o llhttp h2o-http1-corpus")
        var report: [String] = []
        for input in Self.inputs {
            for method in [HTTPMethod.get, .head] {
                let whole = Conformance.parse(input.bytes, as: .response(requestMethod: method))
                let bytewise = Conformance.parse(input.bytes, as: .response(requestMethod: method), splits: Array(1..<max(1, input.bytes.count)))
                if bytewise != whole { report.append("\(input.name) (\(method)): byte at a time \(bytewise); whole \(whole)") }
            }
        }
        #expect(report.isEmpty, "\(report.joined(separator: "\n"))")
    }
}
