public import HTTPBytes
public import HTTPTypes

// Conversions between HTTPBytes' values and swift-http-types', for code that hands parsed messages to APIs built on
// swift-http-types. These copy (swift-http-types' fields are strings): use them at the boundary, not in a parse loop.

public extension HTTPMethod {
    /// The method swift-http-types names `method`, or `nil` if it's longer than 16 bytes.
    init?(_ method: HTTPRequest.Method) {
        let bytes = Array(method.rawValue.utf8)
        self.init(bytes.span.bytes)
    }
}

public extension HTTPRequest.Method {
    /// The same method in swift-http-types.
    init(_ method: HTTPMethod) {
        // A token's bytes are ASCII, so always a valid method.
        self.init(method.description)!
    }
}

public extension HTTPStatus {
    /// The same status as swift-http-types' `status`.
    init?(_ status: HTTPResponse.Status) {
        self.init(code: status.code)
    }
}

public extension HTTPResponse.Status {
    /// The same status in swift-http-types, with RFC 9110's reason phrase.
    init(_ status: HTTPStatus) {
        self.init(code: status.code, reasonPhrase: status.description.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? "")
    }
}

public extension HTTPFieldStore {
    /// `fields` as a store: names and values copied, never-index strategies (`.disallow`) kept as
    /// ``HTTPFieldStore/neverIndexed``. Pseudo-header fields (swift-http-types keeps them apart) aren't included.
    ///
    /// - Throws: `HTTPFieldError` for a field whose value a store doesn't accept (swift-http-types accepts some it
    ///   doesn't, through `lenientValue`).
    init(_ fields: HTTPFields) throws(HTTPFieldError) {
        self.init()
        for field in fields {
            let name = Array(field.name.rawName.utf8), value = Array(field.value.utf8)
            try append(name: name.span.bytes, value: value.span.bytes,
                       flags: field.indexingStrategy == .disallow ? HTTPFieldStore.neverIndexed : 0)
        }
    }
}

extension HTTPFields {
    /// The store's fields as swift-http-types' (names as received, values as strings);
    /// ``HTTPFieldStore/neverIndexed`` becomes `.disallow`. Fields swift-http-types doesn't take as field names are left
    /// out: pseudo-header fields (`:method`, `:path`, …, which it keeps in `HTTPRequest`/`HTTPResponse` instead) and any
    /// name it rejects. Build the request or response from those yourself.
    public init(_ store: borrowing HTTPFieldStore) {
        self.init()
        reserveCapacity(store.count)
        for index in 0..<store.count {
            let view = store.field(at: index)
            let nameText = Self.string(view.name)
            guard let name = HTTPField.Name(nameText) else { continue }
            var field = HTTPField(name: name, lenientValue: Self.bytes(view.value))
            if store.flags(at: index) & HTTPFieldStore.neverIndexed != 0 { field.indexingStrategy = .disallow }
            append(field)
        }
    }

    static func bytes(_ span: RawSpan) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(span.byteCount)
        for offset in 0..<span.byteCount {
            bytes.append(span.load(fromByteOffset: offset, as: UInt8.self))
        }
        return bytes
    }

    static func string(_ span: RawSpan) -> String { String(decoding: bytes(span), as: UTF8.self) }
}
