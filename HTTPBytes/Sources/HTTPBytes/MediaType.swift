/// A media type (RFC 9110 §8.3.1): `type/subtype` and parameters, as `Content-Type` carries it. Type, subtype, and
/// parameter names compare without case; parameter values as the parameter defines (`charset`'s without case).
///
/// ```swift
/// let type = try HTTPMediaType(parsing: contentType)
/// if type.matches("application", "json"), try type.charset?.equals(utf8, ignoringCase: true) ?? true { … }
/// ```
@frozen
public struct HTTPMediaType: ~Escapable {
    /// The type (`text`), as written.
    public let type: RawSpan
    /// The subtype (`html`), as written.
    public let subtype: RawSpan
    @usableFromInline let parameterBytes: RawSpan

    /// Parses a media type and checks its parameters' syntax.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidMediaType``, or a parameter's error.
    @inlinable
    @_lifetime(copy value)
    public init(parsing value: RawSpan) throws(HTTPFieldValueError) {
        let value = FieldGrammar.trimmed(value)
        let typeEnd = FieldGrammar.tokenEnd(value, from: 0)
        guard typeEnd > 0, typeEnd < value.byteCount, FieldGrammar.byte(value, typeEnd) == 0x2F else { throw .invalidMediaType }
        let subtypeEnd = FieldGrammar.tokenEnd(value, from: typeEnd &+ 1)
        guard subtypeEnd > typeEnd &+ 1 else { throw .invalidMediaType }
        type = value.extracting(0..<typeEnd)
        subtype = value.extracting(typeEnd &+ 1..<subtypeEnd)
        parameterBytes = value.extracting(droppingFirst: subtypeEnd)
        try HTTPParameters(parameterBytes).validate()
    }

    /// The parameters, in order.
    @inlinable
    public var parameters: HTTPParameters {
        @_lifetime(copy self)
        get { HTTPParameters(parameterBytes) }
    }

    /// Whether this is `type/subtype`, ignoring case on both sides.
    @inlinable
    public func matches(_ type: StaticString, _ subtype: StaticString) -> Bool {
        HTTPToken.equalsIgnoringCase(self.type, immortalSpan(type)) && HTTPToken.equalsIgnoringCase(self.subtype, immortalSpan(subtype))
    }

    /// The `charset` parameter's value, if there is one.
    @inlinable
    public var charset: HTTPParameterValue? {
        @_lifetime(copy self)
        get {
            // Checked by the initializer: no parameter throws.
            try? parameters.value(of: "charset")
        }
    }
}

/// An element of an `Accept`-style list (RFC 9110 §12.5): a media range, coding, charset, or language range, its
/// parameters, and its weight.
@frozen
public struct HTTPAcceptElement: ~Escapable {
    /// The value: `text/*`, `gzip`, `en-US`, `*`.
    public let value: RawSpan
    /// The weight in thousandths (1000 if there's no `q`; 0 means "not acceptable").
    public let weight: Int
    @usableFromInline let parameterBytes: RawSpan

    @inlinable
    @_lifetime(copy value, copy parameterBytes)
    init(value: RawSpan, weight: Int, parameterBytes: RawSpan) {
        self.value = value
        self.weight = weight
        self.parameterBytes = parameterBytes
    }

    /// The parameters before the weight (a media range's own; those after `q` are extensions, left out).
    @inlinable
    public var parameters: HTTPParameters {
        @_lifetime(copy self)
        get { HTTPParameters(parameterBytes) }
    }
}

/// The elements of an `Accept`, `Accept-Encoding`, `Accept-Language`, or `Accept-Charset` value, each with its weight,
/// and how much a value is wanted (``weight(ofToken:in:)``, ``weight(ofMediaType:_:in:)``,
/// ``weight(ofLanguage:in:)``).
@frozen
public struct HTTPAcceptList: ~Escapable {
    @usableFromInline var elements: HTTPListElements

    /// The elements of `value`.
    @inlinable
    @_lifetime(copy value)
    public init(_ value: RawSpan) { elements = HTTPListElements(value) }

    /// The next element, or `nil` at the end.
    ///
    /// - Throws: ``HTTPFieldValueError/invalidToken`` for a value that isn't a token (or `type/subtype`),
    ///   ``HTTPFieldValueError/invalidWeight``, or a parameter's error.
    @inlinable
    @_lifetime(copy self)
    public mutating func next() throws(HTTPFieldValueError) -> HTTPAcceptElement? {
        guard let element = try elements.next() else { return nil }
        // The value: a token, or two joined by `/` (a media range).
        var end = FieldGrammar.tokenEnd(element, from: 0)
        if end < element.byteCount, FieldGrammar.byte(element, end) == 0x2F {
            let subtypeEnd = FieldGrammar.tokenEnd(element, from: end &+ 1)
            guard subtypeEnd > end &+ 1 else { throw .invalidToken }
            end = subtypeEnd
        }
        guard end > 0 else { throw .invalidToken }
        let value = element.extracting(0..<end)
        // Parameters up to `q`; its value is the weight.
        var parameters = HTTPParameters(element.extracting(droppingFirst: end))
        var weight = 1000
        var ownEnd = element.byteCount &- end
        while true {
            let before = parameters.position
            guard let parameter = try parameters.next() else { break }
            if parameter.isNamed("q") {
                guard case .token(let text) = parameter.value, let thousandths = HTTPWeight.thousandths(text) else { throw .invalidWeight }
                weight = thousandths
                ownEnd = before
                // Extensions after the weight: checked, left out.
                while try parameters.next() != nil {}
                break
            }
        }
        return HTTPAcceptElement(value: value, weight: weight, parameterBytes: element.extracting(end..<end &+ ownEnd))
    }

    /// How much a coding or charset is wanted (`Accept-Encoding`, `Accept-Charset`): the weight of the element naming it
    /// (ignoring case), else of `*`, else 0. For `identity` in `Accept-Encoding` (RFC 9110 §12.5.3), 1000 unless an
    /// element refuses it (`identity;q=0`, or `*;q=0` without one naming it). An empty value accepts only `identity`.
    ///
    /// - Throws: As ``next()``.
    @inlinable
    public static func weight(ofToken token: RawSpan, in value: RawSpan) throws(HTTPFieldValueError) -> Int {
        var list = HTTPAcceptList(value)
        var exact = -1, any = -1
        while let element = try list.next() {
            if HTTPToken.equalsIgnoringCase(element.value, token) {
                exact = Swift.max(exact, element.weight)
            } else if element.value.byteCount == 1, FieldGrammar.byte(element.value, 0) == 0x2A {
                any = Swift.max(any, element.weight)
            }
        }
        if exact >= 0 { return exact }
        if any >= 0 { return any }
        return HTTPToken.equalsIgnoringCase(token, "identity") ? 1000 : 0
    }

    /// How much a media type is wanted (`Accept`, RFC 9110 §12.5.1): the weight of the most specific range that matches
    /// it (`type/subtype`, then `type/*`, then `*/*`), or 0. A range's parameters make it more specific only when the
    /// media type has each of them; otherwise the range doesn't match.
    ///
    /// - Parameters:
    ///   - type: The media type's type.
    ///   - subtype: Its subtype.
    ///   - parameters: Its parameters (an empty span for none).
    /// - Throws: As ``next()``.
    @inlinable
    public static func weight(ofMediaType type: RawSpan, _ subtype: RawSpan, parameters: RawSpan = RawSpan(), in value: RawSpan) throws(HTTPFieldValueError) -> Int {
        var list = HTTPAcceptList(value)
        var best = -1, bestWeight = 0
        while let element = try list.next() {
            let range = element.value
            let slash = FieldGrammar.tokenEnd(range, from: 0)
            guard slash < range.byteCount else { continue }
            let rangeType = range.extracting(0..<slash), rangeSubtype = range.extracting(droppingFirst: slash &+ 1)
            let anyType = rangeType.byteCount == 1 && FieldGrammar.byte(rangeType, 0) == 0x2A
            let anySubtype = rangeSubtype.byteCount == 1 && FieldGrammar.byte(rangeSubtype, 0) == 0x2A
            var specificity: Int
            if anyType {
                guard anySubtype else { continue }
                specificity = 0
            } else {
                guard HTTPToken.equalsIgnoringCase(rangeType, type) else { continue }
                if anySubtype { specificity = 1 } else {
                    guard HTTPToken.equalsIgnoringCase(rangeSubtype, subtype) else { continue }
                    specificity = 2
                }
            }
            // Every parameter of the range must be one of the type's.
            var rangeParameters = element.parameters
            var matched = true, count = 0
            while let parameter = try rangeParameters.next() {
                count &+= 1
                var mine = HTTPParameters(parameters)
                var found = false
                while let candidate = try mine.next() {
                    if HTTPToken.equalsIgnoringCase(candidate.name, parameter.name), parameterValuesEqual(candidate.value, parameter.value) {
                        found = true
                        break
                    }
                }
                if !found { matched = false; break }
            }
            guard matched else { continue }
            specificity = specificity &* 64 &+ Swift.min(count, 63)
            if specificity > best { (best, bestWeight) = (specificity, element.weight) }
        }
        return best >= 0 ? bestWeight : 0
    }

    @inlinable
    static func parameterValuesEqual(_ a: borrowing HTTPParameterValue, _ b: borrowing HTTPParameterValue) -> Bool {
        switch b {
        case .token(let token): a.equals(token, ignoringCase: true)
        case .quoted(let string):
            switch a {
            case .token(let token): string.equals(token, ignoringCase: true)
            case .quoted(let other): string.equals(other, ignoringCase: true)
            }
        }
    }

    /// How much a language tag is wanted (`Accept-Language`, RFC 9110 §12.5.4 with RFC 4647 §3.3.1's basic filtering):
    /// the weight of the longest range that is the tag or a prefix of it ending before a `-` (ignoring case), else of
    /// `*`, else 0.
    ///
    /// - Throws: As ``next()``.
    @inlinable
    public static func weight(ofLanguage tag: RawSpan, in value: RawSpan) throws(HTTPFieldValueError) -> Int {
        var list = HTTPAcceptList(value)
        var best = -1, bestWeight = 0
        while let element = try list.next() {
            let range = element.value
            let length: Int
            if range.byteCount == 1, FieldGrammar.byte(range, 0) == 0x2A {
                length = 0
            } else if range.byteCount <= tag.byteCount,
                      HTTPToken.equalsIgnoringCase(range, tag.extracting(0..<range.byteCount)),
                      range.byteCount == tag.byteCount || FieldGrammar.byte(tag, range.byteCount) == 0x2D {
                length = range.byteCount
            } else {
                continue
            }
            if length > best { (best, bestWeight) = (length, element.weight) }
        }
        return best >= 0 ? bestWeight : 0
    }
}
