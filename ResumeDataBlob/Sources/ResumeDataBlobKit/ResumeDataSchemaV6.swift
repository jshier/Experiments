import Foundation

/// Resume data schema as observed on macOS 27 / current CFNetwork (`NSURLSessionResumeInfoVersion`
/// == 6). Key names found by unarchiving a real captured blob; see `README.md` for the full dump.
public enum ResumeDataSchemaV6: ResumeDataSchemaVersion {
    public static let version = 6

    /// Dictionary key names for this schema version.
    public enum Key {
        public static let infoVersion = ResumeDataSchema.versionKey
        public static let bytesReceived = "NSURLSessionResumeBytesReceived"
        public static let downloadURL = "NSURLSessionDownloadURL"
        public static let tempFileName = "NSURLSessionResumeInfoTempFileName"
        public static let serverDownloadDate = "NSURLSessionResumeServerDownloadDate"
        public static let currentRequestData = "NSURLSessionResumeCurrentRequest"
        public static let originalRequestData = "NSURLSessionResumeOriginalRequest"
        public static let responseData = "NSURLSessionResumeResponse"

        static let all: Set<String> = [infoVersion, bytesReceived, downloadURL, tempFileName,
                                        serverDownloadDate, currentRequestData,
                                        originalRequestData, responseData]
    }

    public static var downloadURLKey: String { Key.downloadURL }
    public static var currentRequestKey: String { Key.currentRequestData }
    public static var originalRequestKey: String { Key.originalRequestData }
    public static var knownKeys: Set<String> { Key.all }

    public static func decode(_ dictionary: [String: Any]) -> ResumeDataEnvelope {
        var envelope = ResumeDataEnvelope()
        envelope.infoVersion = (dictionary[Key.infoVersion] as? NSNumber)?.intValue
        envelope.bytesReceived = (dictionary[Key.bytesReceived] as? NSNumber)?.int64Value
        envelope.downloadURL = dictionary[Key.downloadURL] as? String
        envelope.tempFileName = dictionary[Key.tempFileName] as? String
        envelope.serverDownloadDate = dictionary[Key.serverDownloadDate] as? String
        envelope.currentRequestData = dictionary[Key.currentRequestData] as? Data
        envelope.originalRequestData = dictionary[Key.originalRequestData] as? Data
        envelope.responseData = dictionary[Key.responseData] as? Data
        return envelope
    }

    public static func decode(_ dictionary: NSDictionary) -> ResumeDataEnvelope {
        var envelope = ResumeDataEnvelope()
        envelope.infoVersion = (dictionary[Key.infoVersion] as? NSNumber)?.intValue
        envelope.bytesReceived = (dictionary[Key.bytesReceived] as? NSNumber)?.int64Value
        envelope.downloadURL = dictionary[Key.downloadURL] as? String
        envelope.tempFileName = dictionary[Key.tempFileName] as? String
        envelope.serverDownloadDate = dictionary[Key.serverDownloadDate] as? String
        envelope.currentRequestData = dictionary[Key.currentRequestData] as? Data
        envelope.originalRequestData = dictionary[Key.originalRequestData] as? Data
        envelope.responseData = dictionary[Key.responseData] as? Data
        return envelope
    }

    public static func encode(_ envelope: ResumeDataEnvelope) -> [String: Any] {
        var dict = [String: Any]()
        dict[Key.infoVersion] = envelope.infoVersion ?? version
        dict[Key.bytesReceived] = envelope.bytesReceived
        dict[Key.downloadURL] = envelope.downloadURL
        dict[Key.tempFileName] = envelope.tempFileName
        dict[Key.serverDownloadDate] = envelope.serverDownloadDate
        dict[Key.currentRequestData] = envelope.currentRequestData
        dict[Key.originalRequestData] = envelope.originalRequestData
        dict[Key.responseData] = envelope.responseData
        return dict
    }
}
