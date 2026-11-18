import Foundation

/// The repository's `TestData/SET`, which `Tools/test-data fetch SET` makes with the generator in
/// `Fixtures/` (the test files aren't checked in).
func testDataDirectory(_ set: String) -> URL {
    URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../TestData/\(set)").standardized
}

/// A test file that hasn't been generated.
struct MissingTestData: Error, CustomStringConvertible {
    let set: String
    let name: String
    var description: String { "\(set)/\(name) is missing: run Tools/test-data fetch \(set)" }
}

/// The file `name` of the set, or `MissingTestData` if it isn't there.
func testDataFile(_ set: String, _ name: String) throws -> URL {
    let url = testDataDirectory(set).appending(path: name)
    guard FileManager.default.fileExists(atPath: url.path()) else { throw MissingTestData(set: set, name: name) }
    return url
}
