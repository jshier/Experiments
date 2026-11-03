import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Helpers for decoding the archived `NSURLRequest`/`NSHTTPURLResponse` blobs embedded in a
/// resume data dictionary, and re-archiving a modified request back into the same shape.
public enum ArchivedRequestCodec {
    /// Classes that can appear in an archived `NSURLRequest`'s object graph, required because
    /// `decodeObject(of:forKey:)` enforces a class allow-list.
    private static let requestClasses: [AnyClass] = [
        NSURLRequest.self, NSMutableURLRequest.self,
        NSURL.self, NSString.self, NSMutableString.self, NSNumber.self,
        NSDictionary.self, NSMutableDictionary.self,
        NSArray.self, NSMutableArray.self,
        NSData.self, NSMutableData.self, NSDate.self,
    ]

    /// Classes that can appear in an archived `NSHTTPURLResponse`'s object graph.
    private static let responseClasses: [AnyClass] = [
        HTTPURLResponse.self, URLResponse.self,
        NSURL.self, NSString.self, NSMutableString.self, NSNumber.self,
        NSDictionary.self, NSMutableDictionary.self,
        NSArray.self, NSMutableArray.self, NSDate.self,
    ]

    /// Unarchives `data` as an `NSURLRequest`. Requires `requiresSecureCoding = true` — the
    /// class-restricted `decodeObject(of:forKey:)` silently returns `nil` otherwise, even though
    /// the same archive decodes fine via the unrestricted `decodeObject(forKey:)`.
    public static func decodeRequest(from data: Data) -> URLRequest? {
        decode(from: data, classes: requestClasses)
    }

    /// Re-archives `request` the same way `URLSession` does, for round-tripping into a mutated
    /// resume data blob.
    public static func encodeRequest(_ request: URLRequest) -> Data? {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(request as NSURLRequest, forKey: ResumeDataArchiveRootKey.candidates[0])
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// Human readable summary of a decoded request, for logging.
    public static func describe(_ request: URLRequest) -> String {
        var lines = [String]()
        lines.append("URL: \(request.url?.absoluteString ?? "nil")")
        lines.append("HTTP method: \(request.httpMethod ?? "nil")")
        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            lines.append("Headers:")
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(key): \(value)")
            }
        }
        lines.append("Cache policy: \(request.cachePolicy)")
        lines.append("Timeout: \(request.timeoutInterval)")
        return lines.joined(separator: "\n")
    }

    /// Unarchives `data` as an `NSHTTPURLResponse`.
    public static func decodeResponse(from data: Data) -> HTTPURLResponse? {
        decode(from: data, classes: responseClasses)
    }

    /// Human readable summary of a decoded response, for logging.
    public static func describe(_ response: HTTPURLResponse) -> String {
        var lines = [String]()
        lines.append("URL: \(response.url?.absoluteString ?? "nil")")
        lines.append("Status: \(response.statusCode)")
        if !response.allHeaderFields.isEmpty {
            lines.append("Headers:")
            for (key, value) in response.allHeaderFields.sorted(by: { "\($0.key)" < "\($1.key)" }) {
                lines.append("  \(key): \(value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func decode<T>(from data: Data, classes: [AnyClass]) -> T? {
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            defer { unarchiver.finishDecoding() }
            for key in ResumeDataArchiveRootKey.candidates {
                if let value = unarchiver.decodeObject(of: classes, forKey: key) as? T {
                    return value
                }
            }
            return nil
        } catch {
            return nil
        }
    }
}
