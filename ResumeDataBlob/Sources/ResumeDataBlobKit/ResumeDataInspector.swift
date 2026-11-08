import Foundation

/// Part 2 of the experiment: explore an opaque resume data blob and decode it into
/// `ResumeDataEnvelope`.
public enum ResumeDataInspector {
    /// 1. Parses the raw bytes as a property list to show what's visible at face value (just
    ///    the generic `NSKeyedArchiver` envelope, not the meaningful keys).
    /// 2. Unarchives the root object to get the real `NSURLSessionResume*` dictionary and dumps
    ///    its schema.
    /// 3. Decodes that dictionary into `ResumeDataEnvelope` via `ResumeDataCodec`, cross-checking
    ///    the direct and `Codable` decode paths agree.
    /// 4. Unarchives the embedded request/response blobs found inside.
    public static func explore(resumeData: Data) throws {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let rawPlist = try PropertyListSerialization.propertyList(from: resumeData,
                                                                  options: [.mutableContainersAndLeaves],
                                                                  format: &format)
        print("Top-level plist format: \(formatName(format))")
        if let rawDict = rawPlist as? [String: Any] {
            print("Raw (un-unarchived) shape — this is just the generic NSKeyedArchiver envelope:")
            print(PlistSchema.describe(rawDict))
        }

        guard let dict = KeyedArchiveCodec.decodeTopLevelDictionary(from: resumeData) else {
            print("\nFailed to unarchive the resume data as an NSKeyedArchiver root object.")
            return
        }

        print("\nUnarchived resume data dictionary (the real schema):")
        let schema = PlistSchema.describe(dict)
        print(schema)

        let schemaURL = Configuration.outputDirectory.appendingPathComponent("resume-data-schema.txt")
        try schema.write(to: schemaURL, atomically: true, encoding: .utf8)
        print("Wrote schema dump to \(schemaURL.path)")

        let version = (dict[ResumeDataSchema.versionKey] as? NSNumber)?.intValue
        let knownKeys = ResumeDataSchema.resolve(version).knownKeys
        let unknownKeys = Set(dict.keys).subtracting(knownKeys).sorted()

        if let envelope = ResumeDataCodec.decodeDirect(from: resumeData) {
            print("\nDecoded directly (NSKeyedUnarchiver -> ResumeDataSchema, no Codable) into ResumeDataEnvelope:")
            print("  infoVersion: \(String(describing: envelope.infoVersion))")
            print("  bytesReceived: \(String(describing: envelope.bytesReceived))")
            print("  downloadURL: \(String(describing: envelope.downloadURL))")
            print("  tempFileName: \(String(describing: envelope.tempFileName))")
            print("  serverDownloadDate: \(String(describing: envelope.serverDownloadDate))")
            print("  currentRequestData present: \(envelope.currentRequestData != nil)")
            print("  originalRequestData present: \(envelope.originalRequestData != nil)")
            print("  responseData present: \(envelope.responseData != nil)")
            if !unknownKeys.isEmpty {
                print("  Keys present in blob but not yet modeled: \(unknownKeys)")
            }

            if let codableEnvelope = ResumeDataCodec.decodeCodable(from: resumeData) {
                print("  (PropertyListDecoder round trip agrees: \(codableEnvelope == envelope))")
            }
        } else {
            print("\nFailed to decode ResumeDataEnvelope from the resume data.")
        }

        // Demonstrates why NSKeyedUnarchiver is required: PropertyListDecoder alone "succeeds"
        // against the raw bytes (every field is optional) but yields only nils.
        do {
            let direct = try PropertyListDecoder().decode(ResumeDataEnvelope.self, from: resumeData)
            let sawSomething = direct.infoVersion != nil || direct.bytesReceived != nil ||
                direct.downloadURL != nil || direct.currentRequestData != nil
            if sawSomething {
                print("\n(Unexpectedly) decoding ResumeDataEnvelope directly from the raw resume data " +
                    "also produced real values.")
            } else {
                print("\nAs expected, decoding ResumeDataEnvelope directly from the *raw* resume data " +
                    "bytes (skipping NSKeyedUnarchiver) 'succeeds' but yields only nils (it's an " +
                    "NSKeyedArchiver graph, not a flat plist — the real keys are nested inside " +
                    "$objects, not at the top level).")
            }
        } catch {
            print("\nAs expected, decoding ResumeDataEnvelope directly from the *raw* resume data bytes " +
                "fails outright (it's an NSKeyedArchiver graph, not a flat plist): \(error)")
        }

        print("\nInspecting embedded archived requests/response:")
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            guard let data = value as? Data else { continue }
            if let request = ArchivedRequestCodec.decodeRequest(from: data) {
                print("--- \(key) (NSURLRequest) ---")
                print(ArchivedRequestCodec.describe(request))
            } else if let response = ArchivedRequestCodec.decodeResponse(from: data) {
                print("--- \(key) (NSHTTPURLResponse) ---")
                print(ArchivedRequestCodec.describe(response))
            } else {
                print("--- \(key) --- present (\(data.count) bytes) but could not be unarchived")
            }
        }
    }

    private static func formatName(_ format: PropertyListSerialization.PropertyListFormat) -> String {
        switch format {
        case .xml: "xml"
        case .binary: "binary"
        case .openStep: "openStep"
        @unknown default: "unknown"
        }
    }
}
