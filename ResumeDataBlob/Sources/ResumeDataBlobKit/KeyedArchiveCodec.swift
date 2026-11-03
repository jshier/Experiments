import Foundation

/// Helpers for treating the resume data blob as an `NSKeyedArchiver` archive. Raw
/// `PropertyListSerialization` only reveals the generic `$archiver`/`$objects`/`$top`/`$version`
/// envelope; the real `NSURLSessionResume*` keys only appear after unarchiving.
public enum KeyedArchiveCodec {
    /// Unarchives the root object of `data` as `[String: Any]`. Secure coding stays disabled
    /// since resume data embeds private CFNetwork types Swift can't reference by class.
    ///
    /// Tries both root-key conventions in `ResumeDataArchiveRootKey`, since the outer envelope
    /// uses the non-standard one but callers may also feed this an already-unwrapped nested blob.
    public static func decodeTopLevelDictionary(from data: Data) -> [String: Any]? {
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            defer { unarchiver.finishDecoding() }
            for key in ResumeDataArchiveRootKey.candidates {
                if let dictionary = unarchiver.decodeObject(forKey: key) as? [String: Any] {
                    return dictionary
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Re-archives `dictionary` the same way, producing a blob usable with
    /// `URLSession.downloadTask(withResumeData:)`.
    public static func encodeTopLevelDictionary(_ dictionary: [String: Any]) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(dictionary as NSDictionary, forKey: ResumeDataArchiveRootKey.candidates[0])
        archiver.finishEncoding()
        return archiver.encodedData
    }
}
