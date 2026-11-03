import Foundation

/// Maps a resume data dictionary's keys to and from `ResumeDataEnvelope` for one specific
/// `NSURLSessionResumeInfoVersion`. CFNetwork has changed this format before and will again;
/// to support a new version, add a conforming type and register it in `ResumeDataSchema.versions`
/// — no other code needs to change.
public protocol ResumeDataSchemaVersion: Sendable {
    /// The `NSURLSessionResumeInfoVersion` value this schema decodes/encodes.
    static var version: Int { get }

    /// Key for the original download URL, used by the mutation experiment to redirect a blob.
    static var downloadURLKey: String { get }

    /// Key for the archived `NSURLRequest` that will actually be reissued on resume.
    static var currentRequestKey: String { get }

    /// Key for the archived `NSURLRequest` that started the original download.
    static var originalRequestKey: String { get }

    /// Every dictionary key this schema knows how to decode, for reporting unmodeled keys.
    static var knownKeys: Set<String> { get }

    /// Builds an envelope from an unarchived resume data dictionary.
    static func decode(_ dictionary: [String: Any]) -> ResumeDataEnvelope

    /// Builds an envelope by reading fields straight off an `NSDictionary`, without bridging it
    /// to `[String: Any]` first.
    static func decode(_ dictionary: NSDictionary) -> ResumeDataEnvelope

    /// Builds the dictionary form of `envelope`, suitable for `NSKeyedArchiver`.
    static func encode(_ envelope: ResumeDataEnvelope) -> [String: Any]
}

/// Registry of known resume data schema versions, keyed by `NSURLSessionResumeInfoVersion`.
public enum ResumeDataSchema {
    /// Key holding the format version in every known resume data blob. Read this first to pick
    /// the right schema before decoding anything else.
    public static let versionKey = "NSURLSessionResumeInfoVersion"

    /// All schema versions this package knows how to decode.
    public static let versions: [Int: ResumeDataSchemaVersion.Type] = [
        ResumeDataSchemaV6.version: ResumeDataSchemaV6.self,
    ]

    /// Schema used to encode new blobs, and as a fallback when a decoded blob's version isn't
    /// one of `versions` (e.g. a newer OS release using an as-yet-unsupported format).
    public static let current: ResumeDataSchemaVersion.Type = ResumeDataSchemaV6.self

    /// Resolves the schema for `version`, falling back to `current` if unrecognized.
    public static func resolve(_ version: Int?) -> ResumeDataSchemaVersion.Type {
        version.flatMap { versions[$0] } ?? current
    }
}
