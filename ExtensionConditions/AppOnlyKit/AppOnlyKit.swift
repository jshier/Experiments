// A framework only the app links: its code can't end up in the extension's binary.

import UIKit

public enum AppOnlyKit {
    @MainActor public static func describeApplication() -> String {
        "MARK AppOnlyKit compiled, state \(UIApplication.shared.applicationState.rawValue)"
    }
}
