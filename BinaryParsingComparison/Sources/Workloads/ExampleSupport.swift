//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Binary Parsing open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

// The helpers the copied examples (PNG, PCAPNG, BPList) share, from swift-binary-parsing 0.0.4's Examples
// (commit 8f0f56a): Misc.swift unchanged except for renaming `TestError`, and the hex formatting from
// RawParser/Raw.swift that the PCAPNG example's `MACAddress.description` uses.

@usableFromInline
struct ExampleTestError: Error, CustomStringConvertible {
    @usableFromInline
    var description: String

    @usableFromInline
    init(description: String) {
        self.description = description
    }

    @usableFromInline
    init() {
        description = ""
    }
}

extension UInt32 {
    var utf8: String {
        withUnsafeBytes(of: byteSwapped) { buffer in
            String(decoding: buffer, as: UTF8.self)
        }
    }
}

extension String {
    func leftPadded(with padding: Character = " ", toCount: Int) -> String {
        let paddingLength = toCount - count
        let prefix =
            paddingLength > 0
                ? String(repeating: padding, count: paddingLength)
                : ""
        return prefix + self
    }
}

extension FixedWidthInteger {
    func hexString(count: Int) -> String {
        let str = String(self, radix: 16, uppercase: true)
        return str.leftPadded(with: "0", toCount: count)
    }
}
