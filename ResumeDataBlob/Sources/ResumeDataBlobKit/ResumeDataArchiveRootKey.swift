import Foundation

/// Resume data blobs mix two `NSKeyedArchiver` root-key conventions: the literal string
/// `"NSKeyedArchiveRootObjectKey"` (used by the outer envelope and archived requests) and the
/// standard `"root"` key — the value of the `NSKeyedArchiveRootObjectKey` Foundation constant
/// (used by the archived response). Call sites try both, in this order, since there's no way to
/// know which one a given blob used without attempting the decode.
enum ResumeDataArchiveRootKey {
    static let candidates = ["NSKeyedArchiveRootObjectKey", NSKeyedArchiveRootObjectKey]
}
