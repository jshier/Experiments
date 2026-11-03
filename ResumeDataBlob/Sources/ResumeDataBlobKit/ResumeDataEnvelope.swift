import Foundation

/// A model of the resume data blob's meaningful (unarchived) dictionary contents. The blob
/// itself is an `NSKeyedArchiver` archive, not a flat property list — see `ResumeDataSchema` for
/// how raw bytes get mapped to this type, versioned by `NSURLSessionResumeInfoVersion`.
///
/// Every field is optional since older/newer schema versions may not populate all of them.
public struct ResumeDataEnvelope: Equatable, Sendable {
    /// `NSURLSessionResumeInfoVersion` — identifies which `ResumeDataSchemaVersion` produced or
    /// should encode this envelope.
    public var infoVersion: Int?

    /// Number of bytes already written to the partial download at the time of cancellation.
    public var bytesReceived: Int64?

    /// The URL the download was originally targeting.
    public var downloadURL: String?

    /// Name of the temporary file holding the partially downloaded bytes.
    public var tempFileName: String?

    /// `Last-Modified`-style validator string used for an `If-Range` check when resuming.
    /// Despite the name, this is a header-formatted `String`, not a `Date`.
    public var serverDownloadDate: String?

    /// Archived `NSURLRequest` for the in-flight request (including any `Range` header already
    /// applied) — this is what actually gets resumed.
    public var currentRequestData: Data?

    /// Archived `NSURLRequest` for the original, un-ranged request that started the download.
    public var originalRequestData: Data?

    /// Archived `NSHTTPURLResponse` capturing the headers of the original response.
    public var responseData: Data?

    public init(infoVersion: Int? = nil,
                bytesReceived: Int64? = nil,
                downloadURL: String? = nil,
                tempFileName: String? = nil,
                serverDownloadDate: String? = nil,
                currentRequestData: Data? = nil,
                originalRequestData: Data? = nil,
                responseData: Data? = nil) {
        self.infoVersion = infoVersion
        self.bytesReceived = bytesReceived
        self.downloadURL = downloadURL
        self.tempFileName = tempFileName
        self.serverDownloadDate = serverDownloadDate
        self.currentRequestData = currentRequestData
        self.originalRequestData = originalRequestData
        self.responseData = responseData
    }
}

// MARK: - Codable (comparison baseline only; see ResumeDataCodec.decodeCodable/encodeCodable)

/// Fixed to `ResumeDataSchemaV6`'s key names — unlike `ResumeDataSchema.resolve`, this does not
/// pick a schema based on `NSURLSessionResumeInfoVersion`. It exists purely so
/// `ResumeDataCodec`'s `Codable`-based strategies have something to measure against the direct
/// (version-aware) ones; it is not a recommended decode/encode path.
extension ResumeDataEnvelope: Codable {
    enum CodingKeys: String, CodingKey {
        case infoVersion = "NSURLSessionResumeInfoVersion"
        case bytesReceived = "NSURLSessionResumeBytesReceived"
        case downloadURL = "NSURLSessionDownloadURL"
        case tempFileName = "NSURLSessionResumeInfoTempFileName"
        case serverDownloadDate = "NSURLSessionResumeServerDownloadDate"
        case currentRequestData = "NSURLSessionResumeCurrentRequest"
        case originalRequestData = "NSURLSessionResumeOriginalRequest"
        case responseData = "NSURLSessionResumeResponse"
    }
}
