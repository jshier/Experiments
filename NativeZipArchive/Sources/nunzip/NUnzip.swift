import ArgumentParser
import BytesAsync
import Disk
import Foundation
import NativeZip
import System

@main
struct NUnzip: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nunzip",
        abstract: "List, test, and extract files from zip archives, in parallel.",
        usage: "nunzip [<options>] <archive>[.zip] [<pattern> ...] [-x <pattern> ...] [-d <directory>]",
        discussion: """
        Options follow Info-ZIP's unzip. The archive may be a quoted wildcard ('*.zip'): every match is \
        processed, and their files are extracted together by one pool of workers. If <archive> doesn't exist, \
        <archive>.zip and <archive>.ZIP are tried.

        Reads stored, deflated, Deflate64, bzip2, LZMA, and xz entries; ZIP64; traditional (ZipCrypto) and \
        WinZip AES encryption; and archives with data before them, such as self-extractors.

        Patterns use shell-style wildcards (*, ?, [...]); quote them so your shell doesn't expand them. As in \
        Info-ZIP unzip, * also matches across '/'.

        Exit codes: 0 success, 1 warnings (files skipped, paths adjusted), 2 errors, 9 archive not found or \
        not a zip archive, 11 no matching entries, 81 unsupported compression or encryption, 82 incorrect \
        password.
        """,
        version: "2.0.0"
    )

    // MARK: Arguments

    enum Mode: EnumerableFlag {
        case list, verbose, test, pipe, console, comment, timestamp

        static func name(for value: Mode) -> NameSpecification {
            switch value {
            case .list: [.customShort("l"), .customLong("list")]
            case .verbose: [.customShort("v"), .customLong("verbose")]
            case .test: [.customShort("t"), .customLong("test")]
            case .pipe: [.customShort("p"), .customLong("pipe")]
            case .console: [.customShort("c"), .customLong("to-stdout")]
            case .comment: [.customShort("z"), .customLong("comment")]
            case .timestamp: [.customShort("T"), .customLong("timestamp-archive")]
            }
        }

        static func help(for value: Mode) -> ArgumentHelp? {
            switch value {
            case .list: "List archive contents."
            case .verbose: "List archive contents with sizes, compression method, ratio, and CRC-32."
            case .test: "Test archive integrity by decompressing and checking every entry's CRC-32."
            case .pipe: "Extract files to standard output, with no other output."
            case .console: "Extract files to standard output, each after its name."
            case .comment: "Display the archive comment only."
            case .timestamp: "Set the archive's modification time to its newest entry's."
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

    enum Update: EnumerableFlag {
        case freshen, update

        static func name(for value: Update) -> NameSpecification {
            switch value {
            case .freshen: [.customShort("f"), .customLong("freshen")]
            case .update: [.customShort("u"), .customLong("update")]
            }
        }

        static func help(for value: Update) -> ArgumentHelp? {
            switch value {
            case .freshen: "Freshen: extract only files that already exist and are older than the archive's."
            case .update: "Update: extract files that are missing or older than the archive's."
            }
        }
    }

    @Argument(help: ArgumentHelp("The zip archive, or a quoted wildcard matching several.", valueName: "archive"))
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

    @Flag(exclusivity: .exclusive, help: "Which entries to extract given what's on disk (default: all).")
    var update: Update?

    @Option(name: .customShort("P"), help: ArgumentHelp("Decrypt with <password> (visible to other users; omit it to be asked).", valueName: "password"))
    var password: String?

    @Flag(name: [.customShort("j"), .customLong("junk-paths")], help: "Don't recreate directories; extract every file into the destination itself.")
    var junkPaths = false

    @Flag(name: [.customShort("C"), .customLong("ignore-case")], help: "Match patterns case-insensitively.")
    var ignoreCase = false

    @Flag(name: [.customShort("L"), .customLong("lowercase")], help: "Lowercase names from uppercase-only (MS-DOS) systems; -LL lowercases all names.")
    var lowercase: Int

    @Flag(name: [.customShort("D"), .customLong("no-timestamps")], help: "Don't restore directories' timestamps; -DD: don't restore any timestamps.")
    var noTimestamps: Int

    @Flag(name: [.customShort("X"), .customLong("restore-owner")], help: "Restore the recorded user and group IDs (needs privileges).")
    var restoreOwner = false

    @Flag(name: [.customShort("K"), .customLong("keep-setid")], help: "Keep setuid, setgid, and sticky bits (cleared by default).")
    var keepSetID = false

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Quiet mode; -qq is quieter.")
    var quiet: Int

    @Option(
        name: .customLong("jobs"),
        help: "The most files to process at once (default: extracting, one per performance core; testing, the number of active cores)."
    )
    var jobs: Int?

    func validate() throws {
        if let jobs, jobs < 1 { throw ValidationError("--jobs must be at least 1.") }
        if update != nil, mode != nil { throw ValidationError("-f and -u only apply to extraction.") }
    }

    // MARK: Run

    func run() async throws {
        // The main task runs at the default priority; the work runs in a child at `.userInitiated` (the user waits
        // for it), which the extraction's and verification's worker tasks inherit.
        let command = self
        try await withPriority(.userInitiated) { try await command.work() }
    }

    private func work() async throws {
        let paths = try resolveArchives()
        var status = Status()
        switch mode {
        case nil:
            await extract(paths, status: &status)
        default:
            for (index, path) in paths.enumerated() {
                if index > 0, quiet < 2, mode != .pipe { Console.out("") }
                guard let zip = open(path, status: &status) else { continue }
                do {
                    try await process(zip, at: path, status: &status)
                } catch let exit as ExitCode {
                    status.archive(failed: exit.rawValue)
                } catch {
                    Console.error("nunzip: \(error)")
                    status.archive(failed: 2)
                }
            }
        }
        if paths.count > 1, quiet < 2, mode != .pipe, mode != .console {
            status.printSummary()
        }
        if status.code != 0 { throw ExitCode(status.code) }
    }

    private func process(_ zip: ZipArchive, at path: String, status: inout Status) async throws {
        let mode = mode!
        if mode == .comment {
            Console.out("Archive:  \(path)")
            if !zip.comment.isEmpty { Console.out(zip.comment) }
            status.archive(failed: 0)
            return
        }
        if mode == .timestamp {
            try timestamp(zip, at: path)
            status.archive(failed: 0)
            return
        }
        guard let selected = select(from: zip.entries) else {
            status.archive(failed: 11)
            return
        }
        switch mode {
        case .list: list(selected, of: zip, at: path)
        case .verbose: listVerbose(selected, of: zip, at: path)
        case .test: try await test(selected, in: zip, at: path)
        case .pipe, .console: try write(selected, from: zip, at: path, withNames: mode == .console)
        case .comment, .timestamp: break
        }
        status.archive(failed: 0)
    }

    /// The archives to process: the argument itself, with `.zip` or `.ZIP` added, or a wildcard's matches.
    private func resolveArchives() throws -> [String] {
        let manager = FileManager.default
        for candidate in [archive, archive + ".zip", archive + ".ZIP"] where manager.fileExists(atPath: candidate) {
            return [candidate]
        }
        if archive.contains(where: { "*?[".contains($0) }) {
            let matches = Glob.expand(archive).filter { !$0.hasSuffix("/") }
            if !matches.isEmpty { return matches }
        }
        Console.error("nunzip:  cannot find or open \(archive), \(archive).zip or \(archive).ZIP.")
        throw ExitCode(9)
    }

    private func open(_ path: String, status: inout Status) -> ZipArchive? {
        do {
            let zip = try ZipArchive(url: URL(filePath: path))
            if zip.leadingByteCount > 0, quiet < 2 {
                Console.error("warning [\(path)]:  \(zip.leadingByteCount) extra bytes at beginning or within zipfile")
                Console.error("  (attempting to process anyway)")
            }
            return zip
        } catch ZipError.notAZipArchive {
            Console.error("nunzip:  cannot find zipfile directory in '\(path)': it is not a zip archive, or it is truncated.")
        } catch let error as DiskError {
            // Info-ZIP's message for a file it can't open: the error alone (Disk's names the call and the path too).
            if case .system(_, _, let code) = error {
                Console.error("nunzip:  cannot open '\(path)': \(code).")
            } else {
                Console.error("nunzip:  cannot open '\(path)': \(error).")
            }
        } catch {
            Console.error("nunzip:  error in '\(path)': \(error)")
        }
        status.archive(failed: 9)
        return nil
    }

    /// Applies include/exclude patterns, warning about include patterns that matched nothing.
    ///
    /// With no include patterns, every entry is included; exclude patterns then remove entries.
    ///
    /// - Parameter entries: The archive's entries.
    /// - Returns: The entries that match an include pattern (if any) and no exclude pattern; `nil` if
    ///   patterns were given and none remain.
    private func select(from entries: [ZipEntry]) -> [ZipEntry]? {
        let flags = ignoreCase ? FNM_CASEFOLD : 0
        func matches(_ pattern: String, _ path: String) -> Bool {
            // libc's fnmatch(3). Without FNM_PATHNAME, `*` also matches `/`, as in Info-ZIP unzip. Unsafe: C
            // strings, bridged for the call only.
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
        if selected.isEmpty, !patterns.isEmpty || !exclude.isEmpty { return nil }
        return selected
    }

    /// The password for `zip`'s encrypted entries: `-P`'s, or asked for on the terminal and checked against
    /// the first encrypted entry (three tries, as Info-ZIP allows). `nil` if there are none, or no terminal.
    private func password(for zip: ZipArchive, entries: [ZipEntry], at path: String) -> String? {
        guard let first = entries.first(where: { $0.isEncrypted && $0.kind != .directory }) else { return nil }
        if let password { return password }
        guard isatty(STDIN_FILENO) != 0 else { return nil }
        var prompt = "[\(path)] \(first.path) password: "
        for _ in 0..<3 {
            guard let entered = Console.readPassword(prompt) else { return nil }
            if zip.passwordMatches(entered, for: first) { return entered }
            prompt = "password incorrect--reenter: "
        }
        return nil
    }

    // MARK: Extract

    private func extract(_ paths: [String], status: inout Status) async {
        let base = FilePath(directory ?? "")
        let destination = base.isEmpty ? FilePath(".") : base
        var archiveIndex: [URL: Int] = [:]
        var warnings: [Int] = Array(repeating: 0, count: paths.count)
        var remembered: OverwriteAnswer?
        let canPrompt = isatty(STDIN_FILENO) != 0

        // Archives are planned in order (opened, listed, asked about) while their files are being written.
        let failures: [ZipExtractionFailure]
        do {
            failures = try await ZipExtractor.extract(into: destination, maxConcurrency: jobs) { extractor in
                for (index, path) in paths.enumerated() {
                    if index > 0, quiet < 2 { Console.out("") }
                    guard let zip = open(path, status: &status) else { continue }
                    if quiet < 2 { Console.out("Archive:  \(path)") }
                    if quiet == 0, !zip.comment.isEmpty { Console.out(zip.comment) }
                    guard let selected = select(from: zip.entries) else {
                        status.archive(failed: 11)
                        continue
                    }
                    archiveIndex[zip.url] = index

                    var options = ZipExtractionOptions()
                    options.junkPaths = junkPaths
                    options.restoresTimestamps = noTimestamps < 2
                    options.restoresDirectoryTimestamps = noTimestamps < 1
                    options.restoresOwnership = restoreOwner
                    options.keepsSpecialBits = keepSetID
                    options.lowercaseNames = lowercase >= 2 ? .all : lowercase == 1 ? .fromUppercaseHosts : .none
                    options.password = password(for: zip, entries: selected, at: path)
                    options.update = switch update {
                    case nil: .all
                    case .freshen: .freshen
                    case .update: .update
                    }
                    switch overwrite {
                    case .always: options.overwrite = .always
                    case .never: options.overwrite = .never
                    case nil:
                        options.overwrite = .ask { _, relative in
                            let shown = base.pushing(relative).string
                            if remembered == nil, !canPrompt {
                                Console.error("nunzip: '\(shown)' exists; use -o to overwrite or -n to skip.")
                                return false
                            }
                            let answer = remembered ?? OverwriteAnswer.prompt(for: shown)
                            if answer == .all || answer == .none { remembered = answer }
                            return answer == .yes || answer == .all
                        }
                    }
                    let quiet = quiet
                    options.onEvent = { event in
                        switch event {
                        case .skipped, .pathAdjusted: warnings[index] += 1
                        default: break
                        }
                        if case let .pathAdjusted(entry, path) = event {
                            if quiet < 2 {
                                let what = entry.path.hasPrefix("/") ? "stripped absolute path spec from" : "skipped \"../\" path component(s) in"
                                Console.error("warning:  \(what) \(entry.path)\(path.isEmpty ? " (nothing left: not extracted)" : "")")
                            }
                            return
                        }
                        guard quiet == 0 else { return }
                        let (label, path, suffix): (String, FilePath, String) = switch event {
                        case let .creatingDirectory(_, path): ("creating", path, "/")
                        case let .extracting(entry, path): (Self.label(for: entry), path, "")
                        case let .linking(_, path, destination): ("linking", path, " -> \(destination)")
                        case let .skipped(_, path): ("skipping", path, "")
                        case let .pathAdjusted(_, path): ("", path, "")
                        }
                        Console.out("\(label.leftPadded(to: 11)): \(base.pushing(path))\(suffix)")
                    }
                    do {
                        try await extractor.add(zip, entries: selected, options: options)
                    } catch {
                        Console.error("nunzip: \(error)")
                        status.archive(failed: 2)
                        archiveIndex[zip.url] = nil
                    }
                }
            }
        } catch {
            Console.error("nunzip: \(error)")
            status.archive(failed: 2)
            return
        }
        var worst: [Int: Int32] = [:]
        for failure in failures {
            let shown = base.pushing(failure.path)
            Console.error("nunzip: \(shown): \(Self.message(for: failure.error))")
            if let index = archiveIndex[failure.archive] { worst[index] = max(worst[index] ?? 0, Self.exitCode(for: failure.error)) }
        }
        for index in archiveIndex.values.sorted() {
            status.archive(failed: worst[index] ?? (warnings[index] > 0 ? 1 : 0))
        }
    }

    private static func label(for entry: ZipEntry) -> String {
        switch entry.method {
        case ZipArchive.Method.stored: "extracting"
        case ZipArchive.Method.deflated, ZipArchive.Method.deflate64: "inflating"
        case ZipArchive.Method.bzip2: "bunzipping"
        default: "decoding"
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let error as ZipError: error.description
        case let error as Errno: error.description
        // Disk's errors (`DiskError`) describe the path and the call.
        case let error as any CustomStringConvertible: error.description
        default: error.localizedDescription
        }
    }

    /// Info-ZIP's exit codes for an entry's failure: 81 unsupported, 82 bad password, otherwise 2.
    private static func exitCode(for error: any Error) -> Int32 {
        switch error {
        case ZipError.unsupportedMethod, ZipError.unsupportedEncryption: 81
        case ZipError.incorrectPassword, ZipError.passwordRequired: 82
        default: 2
        }
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

    private func header(_ zip: ZipArchive, at path: String) {
        guard quiet < 2 else { return }
        Console.out("Archive:  \(path)")
        if quiet == 0, !zip.comment.isEmpty { Console.out(zip.comment) }
    }

    private func list(_ entries: [ZipEntry], of zip: ZipArchive, at path: String) {
        header(zip, at: path)
        if quiet < 2 {
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

    private func listVerbose(_ entries: [ZipEntry], of zip: ZipArchive, at path: String) {
        func ratio(_ compressed: UInt64, _ uncompressed: UInt64) -> String {
            guard uncompressed > 0 else { return "0%" }
            let saved = 1 - Double(compressed) / Double(uncompressed)
            return max(saved, 0).formatted(.percent.precision(.fractionLength(0)))
        }
        func method(_ entry: ZipEntry) -> String {
            switch entry.method {
            case ZipArchive.Method.stored: "Stored"
            case ZipArchive.Method.deflated: "Defl:N"
            case ZipArchive.Method.deflate64: "Def64"
            case ZipArchive.Method.bzip2: "BZip2"
            case ZipArchive.Method.lzma: "LZMA"
            case ZipArchive.Method.xz: "XZ"
            default: "Unk:\(entry.method)"
            }
        }

        header(zip, at: path)
        if quiet < 2 {
            Console.out(" Length   Method    Size  Cmpr    Date    Time   CRC-32   Name")
            Console.out("--------  ------  ------- ---- ---------- ----- --------  ----")
        }
        for entry in entries {
            let length = String(entry.uncompressedSize).leftPadded(to: 8)
            let size = String(entry.compressedSize).leftPadded(to: 7)
            let cmpr = ratio(entry.compressedSize, entry.uncompressedSize).leftPadded(to: 4)
            let crc = String(entry.crc32, radix: 16).leftPadded(to: 8, with: "0")
            let encrypted = entry.isEncrypted ? "*" : " "
            Console.out("\(length)  \(method(entry).rightPadded(to: 6))  \(size) \(cmpr) \(Self.date(entry)) \(crc) \(encrypted)\(entry.path)")
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

    private func test(_ entries: [ZipEntry], in zip: ZipArchive, at path: String) async throws {
        if quiet < 2 { Console.out("Archive:  \(path)") }
        // Entries are verified in parallel; results are reported afterwards, in archive order.
        let failed = await zip.verify(entries, maxConcurrency: jobs ?? ProcessInfo.processInfo.activeProcessorCount, password: password(for: zip, entries: entries, at: path))
        let errors = Dictionary(failed.map { ($0.entry.localHeaderOffset, $0.error) }, uniquingKeysWith: { first, _ in first })
        let width = min(entries.map(\.path.count).max() ?? 0, 60)
        for entry in entries where entry.kind != .directory {
            if let error = errors[entry.localHeaderOffset] {
                Console.out("    testing: \(entry.path.rightPadded(to: width))   \(Self.message(for: error))")
            } else if quiet == 0 {
                Console.out("    testing: \(entry.path.rightPadded(to: width))   OK")
            }
        }
        let failures = failed.count
        if failures == 0 {
            if quiet < 2 { Console.out("No errors detected in compressed data of \(path).") }
        } else {
            Console.out("\(failures) file\(failures == 1 ? "" : "s") failed in \(path).")
            throw ExitCode(failed.map { Self.exitCode(for: $0.error) }.max() ?? 2)
        }
    }

    // MARK: Pipe

    /// `-p` and `-c`: entries' contents to standard output, in archive order. A failing entry is reported and
    /// skipped; the others are still written.
    private func write(_ entries: [ZipEntry], from zip: ZipArchive, at path: String, withNames: Bool) throws {
        if withNames { header(zip, at: path) }
        let password = password(for: zip, entries: entries, at: path)
        var decoder = ZipDecoder()
        var code: Int32 = 0
        for entry in entries where entry.kind == .file {
            if withNames, quiet == 0 { Console.out("\(Self.label(for: entry).leftPadded(to: 11)): \(entry.path)") }
            do {
                try zip.contents(of: entry, using: &decoder, password: password) { chunk in
                    // Unsafe: System's `writeAll` takes a buffer pointer, not a span. Safe: read within the call.
                    _ = try chunk.withUnsafeBytes { try unsafe FileDescriptor.standardOutput.writeAll($0) }
                }
            } catch {
                Console.error("nunzip: \(entry.path): \(Self.message(for: error))")
                code = max(code, Self.exitCode(for: error))
            }
            if withNames { Console.out("") }
        }
        if code != 0 { throw ExitCode(code) }
    }

    // MARK: Timestamp

    /// `-T`: sets the archive's modification time to its newest entry's.
    private func timestamp(_ zip: ZipArchive, at path: String) throws {
        guard let newest = zip.entries.compactMap(\.modificationDate).max() else { return }
        try FileManager.default.setAttributes([.modificationDate: newest], ofItemAtPath: path)
        if quiet == 0 { Console.out("Updated time stamp for \(path).") }
    }
}

// MARK: - Helpers

/// Exit status across archives, with Info-ZIP's summary of how many succeeded.
struct Status {
    private(set) var code: Int32 = 0
    private var succeeded = 0
    private var warned = 0
    private var failed = 0

    /// Records an archive's outcome: 0 success, 1 warnings, anything else a failure (the highest code wins).
    mutating func archive(failed status: Int32) {
        switch status {
        case 0: succeeded += 1
        case 1: warned += 1
        default: failed += 1
        }
        code = max(code, status)
    }

    func printSummary() {
        Console.out("")
        if succeeded > 0 { Console.out("\(succeeded) archive\(succeeded == 1 ? " was" : "s were") successfully processed.") }
        if warned > 0 { Console.out("\(warned) archive\(warned == 1 ? "" : "s") had warnings but no fatal errors.") }
        if failed > 0 { Console.out("\(failed) archive\(failed == 1 ? "" : "s") had fatal errors.") }
    }
}

/// glob(3) for archive wildcards.
enum Glob {
    static func expand(_ pattern: String) -> [String] {
        var result = unsafe glob_t()
        defer { unsafe globfree(&result) }
        // Unsafe: glob's C API fills `result` with C strings, read here before `globfree`.
        guard unsafe glob(pattern, GLOB_MARK, nil, &result) == 0 else { return [] }
        return unsafe (0..<Int(result.gl_pathc)).compactMap { index in
            unsafe result.gl_pathv[index].map { unsafe String(cString: $0) }
        }
    }
}

/// Unbuffered output, so prompts and progress interleave correctly with `readLine()` and binary `-p` output.
enum Console {
    static func out(_ line: String, terminator: String = "\n") {
        try? FileHandle.standardOutput.write(contentsOf: Data((line + terminator).utf8))
    }

    static func error(_ line: String) {
        try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Reads a password from the terminal without echoing it.
    static func readPassword(_ prompt: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        // Unsafe: readpassphrase(3) writes a NUL-terminated string into the buffer, within its count.
        let result = buffer.withUnsafeMutableBufferPointer { buffer in
            unsafe readpassphrase(prompt, buffer.baseAddress, buffer.count, RPP_REQUIRE_TTY)
        }
        guard unsafe result != nil else { return nil }
        return buffer.withUnsafeBufferPointer { unsafe String(cString: $0.baseAddress!) }
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
