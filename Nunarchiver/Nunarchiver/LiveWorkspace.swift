import AppKit
import Foundation

/// The Finder and the app's settings.
struct LiveWorkspace: Workspace {
    /// The `UserDefaults` key the Settings toggle writes.
    static let revealsExpandedItemsKey = "RevealsExpandedItems"

    var revealsExpandedItems: Bool {
        UserDefaults.standard.bool(forKey: Self.revealsExpandedItemsKey)
    }

    func reveal(_ url: URL) async {
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
