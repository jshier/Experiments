// A framework linked by both the app and the widget extension: compiled once, so it can't know its client.

import UIKit

public enum SharedKit {
    /// The conditions this framework was compiled with (the same for every client).
    public static var conditions: [String] {
        var active = ["MARK SharedKit compiled"]
        #if APP_EXTENSION_API
        active.append("MARK SharedKit APP_EXTENSION_API")
        #endif
        #if APPEX_PRODUCT
        active.append("MARK SharedKit APPEX_PRODUCT")
        #endif
        return active
    }

    /// Inlined into clients in optimized builds, but its `#if`s were resolved when SharedKit was compiled.
    @inlinable public static var inlinableConditions: [String] {
        var active = ["MARK SharedKit inlinable compiled"]
        #if APP_EXTENSION_API
        active.append("MARK SharedKit inlinable APP_EXTENSION_API")
        #endif
        #if APPEX_PRODUCT
        active.append("MARK SharedKit inlinable APPEX_PRODUCT")
        #endif
        return active
    }

    /// Runtime check: which kind of bundle is the main bundle?
    public static var isRunningInExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    /// Extension-unsafe API, compiled into the framework but uncallable from extensions.
    @available(iOSApplicationExtension, unavailable)
    @MainActor public static func openSettings() {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }

    #if NEG_UNANNOTATED_IN_FRAMEWORK
    /// Negative test: without the annotation. Expected: an error, since SharedKit is built with
    /// APPLICATION_EXTENSION_API_ONLY = YES.
    @MainActor public static func openSettingsUnannotated() {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }
    #endif
}
