import Foundation

/// Multiple strategies for converting between raw resume data bytes and `ResumeDataEnvelope`,
/// so their performance can be compared (see `ResumeDataBlobBenchmarks`). All decoding is
/// versioned: each strategy reads `NSURLSessionResumeInfoVersion` from the blob and dispatches
/// to the matching `ResumeDataSchemaVersion` (see `ResumeDataSchema`). Only the `*Codable`
/// strategies are exempt — they exist for comparison, not as a recommended path.
public enum ResumeDataCodec {
    // MARK: Decoding

    /// Unarchives the root object into `[String: Any]` with `NSKeyedUnarchiver`, then dispatches
    /// to the schema matching the blob's version.
    public static func decodeDirect(from data: Data) -> ResumeDataEnvelope? {
        guard let dictionary = KeyedArchiveCodec.decodeTopLevelDictionary(from: data) else { return nil }
        let version = (dictionary[ResumeDataSchema.versionKey] as? NSNumber)?.intValue
        return ResumeDataSchema.resolve(version).decode(dictionary)
    }

    /// Like `decodeDirect`, but reads fields straight off the unarchived `NSDictionary` instead
    /// of bridging it to `[String: Any]` first.
    public static func decodePerKey(from data: Data) -> ResumeDataEnvelope? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }

        guard let rootKey = ResumeDataArchiveRootKey.candidates.first(where: {
            unarchiver.containsValue(forKey: $0)
        }), let dictionary = unarchiver.decodeObject(forKey: rootKey) as? NSDictionary else { return nil }

        let version = (dictionary[ResumeDataSchema.versionKey] as? NSNumber)?.intValue
        return ResumeDataSchema.resolve(version).decode(dictionary)
    }

    /// Unarchives to `[String: Any]`, re-serializes as a flat property list, then decodes with
    /// `PropertyListDecoder`. Comparison baseline only — fixed to `ResumeDataSchemaV6`'s keys via
    /// `ResumeDataEnvelope: Codable` and strictly more work than `decodeDirect`.
    public static func decodeCodable(from data: Data) -> ResumeDataEnvelope? {
        guard let dict = KeyedArchiveCodec.decodeTopLevelDictionary(from: data) else { return nil }
        guard let flatPlistData = try? PropertyListSerialization.data(fromPropertyList: dict,
                                                                        format: .binary,
                                                                        options: 0) else { return nil }
        return try? PropertyListDecoder().decode(ResumeDataEnvelope.self, from: flatPlistData)
    }

    // MARK: Encoding

    /// Builds the top-level dictionary via the schema matching `envelope.infoVersion` (falling
    /// back to `ResumeDataSchema.current` if unset) and archives it with `NSKeyedArchiver` —
    /// produces a blob usable with `URLSession.downloadTask(withResumeData:)`.
    public static func encodeDirect(_ envelope: ResumeDataEnvelope) -> Data {
        let schema = ResumeDataSchema.resolve(envelope.infoVersion)
        return KeyedArchiveCodec.encodeTopLevelDictionary(schema.encode(envelope))
    }

    /// Round-trips `envelope` through `PropertyListEncoder`/`PropertyListSerialization` before
    /// archiving. Comparison baseline only; see `decodeCodable`.
    public static func encodeCodable(_ envelope: ResumeDataEnvelope) -> Data? {
        guard let flatPlistData = try? PropertyListEncoder().encode(envelope) else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let dict = try? PropertyListSerialization.propertyList(from: flatPlistData,
                                                                       options: [],
                                                                       format: &format) as? [String: Any] else {
            return nil
        }
        return KeyedArchiveCodec.encodeTopLevelDictionary(dict)
    }
}
