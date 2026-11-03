@testable import NativeISO8601
import Testing

@Suite("SWAR fast path")
struct FastPathTests {
    private func lex(_ bytes: [UInt8], fastPath: Bool) -> Result<RawComponents, ISO8601ParseError> {
        Result { () throws(ISO8601ParseError) in try Lexer(bytes.span).lex(allowingFastPath: fastPath) }
    }

    @Test("Agrees with the general path for every byte value at every position", arguments: [
        "2024-01-15T10:30:45Z", "1999-12-31t23:59:59.999+05:30", "0000-01-01 00:00:00", "9999-12-31T23:59:60,5-23:59",
        "20240115T103045Z", "19991231T235959,25-0530", "00000101T000000",
    ])
    func mutations(_ string: String) {
        let original = Array(string.utf8)
        for index in original.indices {
            var bytes = original
            for value in UInt8.min...UInt8.max {
                bytes[index] = value
                let fast = lex(bytes, fastPath: true), general = lex(bytes, fastPath: false)
                #expect(fast == general, "byte \(value) at \(index) of \(string)")
            }
        }
    }
}
