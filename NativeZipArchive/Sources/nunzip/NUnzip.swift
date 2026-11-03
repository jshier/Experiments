import ArgumentParser
import NativeZip
import Foundation
import System

@main
struct NUnzip: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nunzip",
        abstract: "List, test, and extract files from a zip archive.",
        usage: "nunzip [<options>] <archive> [<pattern> ...] [-x <pattern> ...] [-d <directory>]",
        discussion: """
        Patterns use shell-style wildcards (*, ?, [...]); quote them so your shell doesn't expand them. \
        As in Info-ZIP unzip, * also matches across '/'.

        Exit codes: 0 success, 1 warnings (files skipped), 2 errors, 9 not a zip archive, \
        11 no matching entries.
        """,
        version: "1.0.0"
    )

    // MARK: Arguments

    enum Mode: EnumerableFlag {
        case list, verbose, test, pipe

        static func name(for value: Mode) -> NameSpecification {
            switch value {
            case .list: [.customShort("l"), .customLong("list")]
            case .verbose: [.customShort("v"), .customLong("verbose")]
            case .test: [.customShort("t"), .customLong("test")]
            case .pipe: [.customShort("p"), .customLong("pipe")]
            }
        }

        static func help(for value: Mode) -> ArgumentHelp? {
            switch value {
            case .list: "List archive contents."
            case .verbose: "List archive contents with sizes, compression method, ratio, and CRC-32."
            case .test: "Test archive integrity by decompressing and checking every entry's CRC-32."
            case .pipe: "Extract files to standard output, with no other output."
            }
        }
    }

    enum Overwrite: EnumerableFlag {
        case always, never

        static func name(for value: Overwrite) -> NameSpecification {
            switch value {
            case .always: [.customShort("o"), .customLong("overwrite")]
            case .never: [.customShort("n"), .customLong("never-overwrite")]
            }
        }

        static func help(for value: Overwrite) -> ArgumentHelp? {
            switch value {
            case .always: "Overwrite existing files without prompting."
            case .never: "Never overwrite existing files."
            }
        }
    }

    @Argument(help: "The zip archive to read.")
    var archive: String

    @Argument(help: "Only process entries matching these patterns.")
    var patterns: [String] = []

    @Flag(exclusivity: .exclusive, help: "Operation (default: extract).")
    var mode: Mode?

    @Option(
        name: .customShort("x"),
        parsing: .upToNextOption,
        help: ArgumentHelp("Exclude entries matching these patterns.", valueName: "pattern")
    )
    var exclude: [String] = []

    @Option(name: [.customShort("d"), .customLong("directory")], help: "Extract into <directory> (default: current directory).")
    var directory: String?

    @Flag(exclusivity: .exclusive, help: "What to do when a file already exists (default: ask).")
    var overwrite: Overwrite?

    @Flag(name: [.customShort("j"), .customLong("junk-paths")], help: "Don't recreate directories; extract every file into the destination itself.")
    var junkPaths = false

    @Flag(name: [.customShort("C"), .customLong("ignore-case")], help: "Match patterns case-insensitively.")
    var ignoreCase = false

    @Flag(name: [.customShort("D"), .customLong("no-timestamps")], help: "Don't restore modification times; use the current time.")
    var noTimestamps = false

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Quiet mode; -qq is quieter.")
    var quiet: Int

    // MARK: Run

    func run() async throws {
        let zip: ZipArchive
        do {
            zip = try ZipArchive(url: URL(filePath: archive))
        } catch ZipError.notAZipArchive {
            Console.error("nunzip: '\(archive)' is not a zip archive (or it is truncated or corrupt).")
            throw ExitCode(9)
        } catch let error as Errno where error == .noSuchFileOrDirectory {
            Console.error("nunzip: cannot find '\(archive)'.")
            throw ExitCode(9)
        }

        let selected = try select(from: zip.entries)

        do {
            switch mode {
            case nil: try await extract(selected, from: zip)
            case .list: list(selected)
            case .verbose: listVerbose(selected)
            case .test: try await test(selected, in: zip)
            case .pipe: try pipe(selected, from: zip)
            }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            // Match unzip: report the problem and exit 2 rather than ArgumentParser's generic failure.
            Console.error("nunzip: \(error)")
            throw ExitCode(2)
        }
    }

    /// Applies include/exclude patterns, warning about include patterns that matched nothing.
    private func select(from entries: [ZipEntry]) throws -> [ZipEntry] {
        let flags = ignoreCase ? FNM_CASEFOLD : 0
        func matches(_ pattern: String, _ path: String) -> Bool {
            // libc's fnmatch(3). Without FNM_PATHNAME, `*` also matches `/`, as in Info-ZIP unzip.
            unsafe fnmatch(pattern, path, flags) == 0
        }

        var unmatched = Set(patterns)
        let selected = entries.filter { entry in
            if !patterns.isEmpty {
                let hits = patterns.filter { matches($0, entry.path) }
                guard !hits.isEmpty else { return false }
                unmatched.subtract(hits)
            }
            return !exclude.contains { matches($0, entry.path) }
        }

        for pattern in patterns where unmatched.contains(pattern) {
            Console.error("caution: filename not matched:  \(pattern)")
        }
        if selected.isEmpty, !patterns.isEmpty || !exclude.isEmpty {
            throw ExitCode(11)
        }
        return selected
    }

    // MARK: Extract

    private func extract(_ entries: [ZipEntry], from zip: ZipArchive) async throws {
        if quiet < 2 { Console.out("Archive:  \(archive)") }

        let base = FilePath(directory ?? "")
        var skipped = 0
        var options = ExtractionOptions()
        options.junkPaths = junkPaths
        options.restoreTimestamps = !noTimestamps
        switch overwrite {
        case .always: options.overwrite = .always
        case .never: options.overwrite = .never
        case nil:
            var remembered: OverwriteAnswer?
            let canPrompt = isatty(STDIN_FILENO) != 0
            options.overwrite = .ask { _, path in
                let shown = base.pushing(path).string
                if remembered == nil, !canPrompt {
                    Console.error("nunzip: '\(shown)' exists; use -o to overwrite or -n to skip.")
                    return false
                }
                let answer = remembered ?? OverwriteAnswer.prompt(for: shown)
                if answer == .all || answer == .none { remembered = answer }
                return answer == .yes || answer == .all
            }
        }
        options.onEvent = { event in
            if case .skipped = event { skipped += 1 }
            guard quiet == 0 else { return }
            let (label, path, suffix): (String, FilePath, String) = switch event {
            case let .creatingDirectory(_, path): ("creating", path, "/")
            case let .extracting(entry, path):
                (entry.method == ZipArchive.Method.stored ? "extracting" : "inflating", path, "")
            case let .linking(_, path, destination): ("linking", path, " -> \(destination)")
            case let .skipped(_, path): ("skipping", path, "")
            }
            Console.out("\(label.leftPadded(to: 11)): \(base.pushing(path))\(suffix)")
        }

        try await zip.extract(entries, to: base.isEmpty ? FilePath(".") : base, options: options)
        if skipped > 0 { throw ExitCode(1) }
    }

    private enum OverwriteAnswer {
        case yes, no, all, none

        static func prompt(for path: String) -> OverwriteAnswer {
            while true {
                Console.out("replace \(path)? [y]es, [n]o, [A]ll, [N]one: ", terminator: "")
                switch readLine()?.trimmingCharacters(in: .whitespaces) {
                case "y", "Y", "yes": return .yes
                case "n", "no": return .no
                case "A": return .all
                case "N", nil: return .none
                default: Console.out("error: invalid response")
                }
            }
        }
    }

    // MARK: List

    private static let dateStyle = Date.VerbatimFormatStyle(
        format: "\(month: .twoDigits)-\(day: .twoDigits)-\(year: .padded(4)) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: .current,
        calendar: .current
    )

    private static func date(_ entry: ZipEntry) -> String {
        entry.modificationDate?.formatted(dateStyle) ?? "                "
    }

    private func list(_ entries: [ZipEntry]) {
        if quiet < 2 {
            Console.out("Archive:  \(archive)")
            Console.out("  Length      Date    Time    Name")
            Console.out("---------  ---------- -----   ----")
        }
        for entry in entries {
            Console.out("\(String(entry.uncompressedSize).leftPadded(to: 9))  \(Self.date(entry))   \(entry.path)")
        }
        if quiet < 2 {
            let total = entries.reduce(0) { $0 + $1.uncompressedSize }
            Console.out("---------                     -------")
            Console.out("\(String(total).leftPadded(to: 9))                     \(entries.count) file\(entries.count == 1 ? "" : "s")")
        }
    }

    private func listVerbose(_ entries: [ZipEntry]) {
        func ratio(_ compressed: UInt64, _ uncompressed: UInt64) -> String {
            guard uncompressed > 0 else { return "0%" }
            let saved = 1 - Double(compressed) / Double(uncompressed)
            return max(saved, 0).formatted(.percent.precision(.fractionLength(0)))
        }
        func method(_ entry: ZipEntry) -> String {
            switch entry.method {
            case ZipArchive.Method.stored: "Stored"
            case ZipArchive.Method.deflated: "Defl:N"
            default: "Unk:\(entry.method)"
            }
        }

        if quiet < 2 {
            Console.out("Archive:  \(archive)")
            Console.out(" Length   Method    Size  Cmpr    Date    Time   CRC-32   Name")
            Console.out("--------  ------  ------- ---- ---------- ----- --------  ----")
        }
        for entry in entries {
            let length = String(entry.uncompressedSize).leftPadded(to: 8)
            let size = String(entry.compressedSize).leftPadded(to: 7)
            let cmpr = ratio(entry.compressedSize, entry.uncompressedSize).leftPadded(to: 4)
            let crc = String(entry.crc32, radix: 16).leftPadded(to: 8, with: "0")
            Console.out("\(length)  \(method(entry).rightPadded(to: 6))  \(size) \(cmpr) \(Self.date(entry)) \(crc)  \(entry.path)")
        }
        if quiet < 2 {
            let uncompressed = entries.reduce(0) { $0 + $1.uncompressedSize }
            let compressed = entries.reduce(0) { $0 + $1.compressedSize }
            let length = String(uncompressed).leftPadded(to: 8)
            let size = String(compressed).leftPadded(to: 7)
            let cmpr = ratio(compressed, uncompressed).leftPadded(to: 4)
            Console.out("--------          ------- ----                           -------")
            Console.out("\(length)          \(size) \(cmpr)                           \(entries.count) file\(entries.count == 1 ? "" : "s")")
        }
    }

    // MARK: Test

    private func test(_ entries: [ZipEntry], in zip: ZipArchive) async throws {
        if quiet < 2 { Console.out("Archive:  \(archive)") }
        // Entries are verified in parallel; results are reported afterwards, in archive order.
        let failed = await zip.verify(entries)
        let errors = Dictionary(failed.map { ($0.entry.localHeaderOffset, $0.error) }, uniquingKeysWith: { first, _ in first })
        let width = min(entries.map(\.path.count).max() ?? 0, 60)
        for entry in entries where entry.kind != .directory {
            if let error = errors[entry.localHeaderOffset] {
                Console.out("    testing: \(entry.path.rightPadded(to: width))   \(error)")
            } else if quiet == 0 {
                Console.out("    testing: \(entry.path.rightPadded(to: width))   OK")
            }
        }
        let failures = failed.count
        if failures == 0 {
            if quiet < 2 { Console.out("No errors detected in compressed data of \(archive).") }
        } else {
            Console.out("\(failures) file\(failures == 1 ? "" : "s") failed in \(archive).")
            throw ExitCode(2)
        }
    }

    // MARK: Pipe

    private func pipe(_ entries: [ZipEntry], from zip: ZipArchive) throws {
        var decoder = ZipDecoder()
        for entry in entries where entry.kind == .file {
            try zip.contents(of: entry, using: &decoder) { chunk in
                _ = try chunk.withUnsafeBytes { try unsafe FileDescriptor.standardOutput.writeAll($0) }
            }
        }
    }
}

// MARK: - Helpers

/// Unbuffered output, so prompts and progress interleave correctly with `readLine()` and binary `-p` output.
enum Console {
    static func out(_ line: String, terminator: String = "\n") {
        try? FileHandle.standardOutput.write(contentsOf: Data((line + terminator).utf8))
    }

    static func error(_ line: String) {
        try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
    }
}

private extension String {
    func leftPadded(to width: Int, with pad: Character = " ") -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }

    func rightPadded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
