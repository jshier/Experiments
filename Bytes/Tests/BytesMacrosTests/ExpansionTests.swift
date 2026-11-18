import BytesMacrosPlugin
import MacroTesting
import Testing

@Suite(.macros(["BitFields": BitFieldsMacro.self, "BinaryRecord": BinaryRecordMacro.self, "Flag": FieldMarkerMacro.self, "Field": FieldMarkerMacro.self], record: .missing))
struct ExpansionTests {
    @Test func bitFieldsInAByte() {
        assertMacro {
            """
            @BitFields(Byte.self, reserved: 0...0)
            public struct ConnectFlags {
                @Flag(bit: 7) public var userName: Bool
                @Field(bits: 3...4) public var willQoS: QualityOfService
                @Field(bits: 1...2) public var count: Int
            }
            """
        } expansion: {
            """
            public struct ConnectFlags {
                public var userName: Bool
                public var willQoS: QualityOfService
                public var count: Int

                @inlinable @inline(__always) public init(userName: Bool, willQoS: QualityOfService, count: Int) {
                    self.userName = userName
                    self.willQoS = willQoS
                    self.count = count
                }

                /// Decodes every field from `rawValue`, checking its reserved bits.
                ///
                /// - Throws: `BytesError.invalidValue` if a reserved bit is set or a field has no matching case.
                @inlinable @inline(__always) public init(rawValue: Byte) throws(BytesError) {
                    try rawValue.requireZero(BitField<Int>(bits: 0 ... 0))
                    self.userName = rawValue[BitFlag(bit: 7)]
                    self.willQoS = try rawValue.value(of: BitField<QualityOfService>(bits: 3 ... 4))
                    self.count = Int(truncatingIfNeeded: rawValue[BitField<Int>(bits: 1 ... 2)])
                }

                /// The fields packed into one value.
                @inlinable @inline(__always) public var rawValue: Byte {
                    var raw: Byte = Byte.zero
                    raw[BitFlag(bit: 7)] = userName
                    raw[BitField<QualityOfService>(bits: 3 ... 4)] = willQoS
                    raw[BitField<Int>(bits: 1 ... 2)] = Int(count)
                    return raw
                }
            }

            extension ConnectFlags: BinaryParsable, BinaryWritable, FixedSizeBinary {
                @inlinable @inline(__always) public init<Mode: BytesCursorMode>(parsing reader: inout GenericBytesReader<Mode>) throws(BytesError) {
                    try self.init(rawValue: reader.read(Byte.self))
                }
                @inlinable @inline(__always) public func write<Mode: BytesCursorMode>(to writer: inout GenericBytesWriter<Mode>) throws(BytesError) {
                    try writer.write(rawValue)
                }
                @inlinable @inline(__always) public static var byteCount: Int {
                    1
                }
            }
            """
        }
    }

    @Test func record() {
        assertMacro {
            """
            @BinaryRecord(.littleEndian)
            struct Header {
                @Field(Byte4.self, expecting: 0x0403_4B50) var signature: UInt32
                @Field(Byte2.self) var version: Int
                @Field(Byte4.self) var offset: Int32
                var flags: ConnectFlags
                @Field(Byte2.self) var method: Method
            }
            """
        } expansion: {
            """
            struct Header {
                var signature: UInt32
                var version: Int
                var offset: Int32
                var flags: ConnectFlags
                var method: Method

                @inline(__always) init(signature: UInt32 = 0x0403_4B50, version: Int, offset: Int32, flags: ConnectFlags, method: Method) {
                    self.signature = signature
                    self.version = version
                    self.offset = offset
                    self.flags = flags
                    self.method = method
                }

                /// The record's size in bytes.
                @inline(__always) static var byteCount: Int {
                    4 + 2 + 4 + ConnectFlags.byteCount + 2
                }
            }

            extension Header: BinaryParsable, BinaryWritable, FixedSizeBinary {
                /// Reads the record: its bytes with one bounds check, then each field once. Consumes nothing if it throws.
                @inline(__always) init<Mode: BytesCursorMode>(parsing reader: inout GenericBytesReader<Mode>) throws(BytesError) {
                    let start = reader.position
                    var record = AlignedBytesReader(try reader.read(byteCount: Self.byteCount))
                    do throws(BytesError) {
                        let signature = try record.read(UInt32.self, as: Byte4.self, .littleEndian)
                        guard signature == 0x0403_4B50 else {
                            throw .mismatch
                        }
                        self.signature = signature
                        self.version = try record.read(Int.self, as: Byte2.self, .littleEndian)
                        self.offset = try record.read(Int32.self, asSigned: Byte4.self, .littleEndian)
                        self.flags = try ConnectFlags(parsing: &record)
                        self.method = try record.read(Method.self, as: Byte2.self, .littleEndian)
                    } catch {
                        reader.rewind(to: start)
                        throw error
                    }
                }
                /// Writes the record's fields in order.
                @inline(__always) func write<Mode: BytesCursorMode>(to writer: inout GenericBytesWriter<Mode>) throws(BytesError) {
                    try writer.write(signature, as: Byte4.self, .littleEndian)
                    try writer.write(version, as: Byte2.self, .littleEndian)
                    try writer.write(offset, asSigned: Byte4.self, .littleEndian)
                    try flags.write(to: &writer)
                    try writer.write(method, as: Byte2.self, .littleEndian)
                }
            }
            """
        }
    }
}

@Suite(.macros(["BitFields": BitFieldsMacro.self, "BinaryRecord": BinaryRecordMacro.self, "Flag": FieldMarkerMacro.self, "Field": FieldMarkerMacro.self], record: .missing))
struct DiagnosticTests {
    @Test func unmarkedPropertyInBitFields() {
        assertMacro {
            """
            @BitFields(Byte.self)
            struct Flags {
                var loose: Bool
            }
            """
        } diagnostics: {
            """
            @BitFields(Byte.self)
            struct Flags {
                var loose: Bool
                ┬──────────────
                ╰─ 🛑 'loose' needs @Flag or @Field: every stored property of a @BitFields struct is a field
            }
            """
        }
    }

    @Test func unsupportedStorage() {
        assertMacro {
            """
            @BitFields(UInt128.self)
            struct Flags {
                @Flag(bit: 1) var one: Bool
            }
            """
        } diagnostics: {
            """
            @BitFields(UInt128.self)
            ┬───────────────────────
            ╰─ 🛑 @BitFields stores its fields in Byte, UInt8, UInt16, UInt32, or UInt64, not UInt128
            struct Flags {
                @Flag(bit: 1) var one: Bool
            }
            """
        }
    }

    @Test func recordFieldWithoutAGroup() {
        assertMacro {
            """
            @BinaryRecord(.bigEndian)
            struct Record {
                @Field(bits: 0...3) var nibble: Int
            }
            """
        } diagnostics: {
            """
            @BinaryRecord(.bigEndian)
            struct Record {
                @Field(bits: 0...3) var nibble: Int
                ┬──────────────────────────────────
                ╰─ 🛑 @Field in a @BinaryRecord names its width: @Field(Byte2.self), or @Field(Byte.self) for one byte
            }
            """
        }
    }
}
