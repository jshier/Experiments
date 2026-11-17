// A package target linked by both the app and the widget extension. Client targets' compilation
// conditions don't reach package targets.

import UIKit

public enum SharedPackage {
    public static var conditions: [String] {
        var active = ["MARK SharedPackage compiled"]
        #if APP_EXTENSION_API
        active.append("MARK SharedPackage APP_EXTENSION_API")
        #endif
        #if APPEX_PRODUCT
        active.append("MARK SharedPackage APPEX_PRODUCT")
        #endif
        return active
    }

    @available(iOSApplicationExtension, unavailable)
    @MainActor public static func openSettings() {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }
}
