// A file with membership in both the app and the widget extension: each target compiles it with its own
// compilation conditions, so each binary carries a different set of the markers below.

import Foundation

enum SharedSource {
    static var conditions: [String] {
        var active = ["MARK SharedSource compiled"]
        #if APP_EXTENSION_API
        active.append("MARK SharedSource APP_EXTENSION_API")
        #endif
        #if APPEX_PRODUCT
        active.append("MARK SharedSource APPEX_PRODUCT")
        #endif
        // Not a real condition: unknown targetEnvironment values are silently false.
        #if targetEnvironment(applicationExtension)
        active.append("MARK SharedSource targetEnvironment(applicationExtension)")
        #endif
        return active
    }
}

#if !APPEX_PRODUCT
import UIKit

extension SharedSource {
    /// Extension-unsafe API, compiled only into the app.
    @MainActor static func openSettings() {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }
}
#endif

#if NEG_UNGUARDED_SHARED_SOURCE
import UIKit

extension SharedSource {
    /// Negative test: the same call without the guard. Expected: an error in the widget only.
    @MainActor static func openSettingsUnguarded() {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }
}
#endif
