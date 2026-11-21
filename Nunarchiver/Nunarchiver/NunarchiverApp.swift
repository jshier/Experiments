import AppKit
import SwiftUI

/// Nunarchiver: Archive Utility's job on the repository's native expanders.
///
/// No window at launch: archives arrive through the app delegate (Finder, `open -a`, the Dock), and the progress
/// window appears only for expansions that take a while. A plain launch asks for archives instead.
@main
struct NunarchiverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Expand Archive…") {
                    appDelegate.chooseArchives()
                }
                .keyboardShortcut("o")
            }
        }
    }
}
