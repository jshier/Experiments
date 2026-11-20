/// The bytes a string of hexadecimal digit pairs spells (`"00ff"` is `[0x00, 0xFF]`); traps on anything else.
///
/// - Parameter string: An even number of hexadecimal digits, either case.
/// - Returns: The bytes.
public func hex(_ string: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

/// Bytes as lowercase hexadecimal digit pairs, as ``hex(_:)-(String)`` reads them.
///
/// - Parameter bytes: The bytes.
/// - Returns: Two digits per byte.
public func hex(_ bytes: some Sequence<UInt8>) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var text: [UInt8] = []
    for byte in bytes {
        text.append(digits[Int(byte >> 4)])
        text.append(digits[Int(byte & 0xF)])
    }
    return String(decoding: text, as: UTF8.self)
}
