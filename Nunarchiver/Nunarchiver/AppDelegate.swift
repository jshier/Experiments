import AppKit
import ComposableArchitecture
import IssueReporting
import Observation
import UniformTypeIdentifiers

/// Receives archives (Finder, `open -a`, the Dock, the open panel) and shows what the store asks for: the progress
/// window, failure alerts, and quitting once a launch's archives are done.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store(initialState: Archiver.State()) {
        Archiver()
    }

    /// The archive types Nunarchiver expands (all declared by the system; see Info.plist).
    static let archiveTypes: [UTType] = [
        .zip,
        UTType("com.apple.encrypted-archive"),
        UTType("com.apple.archive"),
        UTType("com.apple.xip-archive"),
    ].compactMap(\.self)

    private lazy var progressWindow = ProgressWindowController(store: store)
    private var observations: [Task<Void, Never>] = []
    private var terminationSource: any DispatchSourceSignal?
    /// Whether archives were opened at launch: then the app quits when they're done, as Archive Utility does.
    private var launchedWithArchives = false
    private var isLaunching = true

    func application(_ sender: NSApplication, open urls: [URL]) {
        if isLaunching { launchedWithArchives = true }
        store.send(.archivesOpened(urls))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        isLaunching = false
        // As the tests' host, the app shows nothing and watches nothing (IssueReporting's check).
        guard !isTesting else { return }
        observe()
        if !launchedWithArchives {
            chooseArchives()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows && store.isIdle { chooseArchives() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting mid-expansion cancels every expansion and waits for each to remove what it staged.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !store.expansions.isEmpty else { return .terminateNow }
        store.send(.quitRequested)
        Task { [store] in
            for await isDone in Observations({ store.expansions.isEmpty }) where isDone {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
        }
        return .terminateLater
    }

    /// File > Expand Archive…: an open panel for archives.
    func chooseArchives() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = String(localized: "Expand Archive", comment: "Title of the panel for choosing archives to expand.")
        panel.prompt = String(localized: "Expand", comment: "Default button of the panel for choosing archives to expand.")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.archiveTypes
        panel.begin { [store] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            store.send(.archivesOpened(panel.urls))
        }
    }

    private func observe() {
        // `SIGTERM` (logout, `kill`) quits as the Quit command does, so expansions clean up. (`signal` takes a C
        // function pointer: here the constant `SIG_IGN`, so the dispatch source below is the only handler.)
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { Self.requestTermination() }
        termination.resume()
        terminationSource = termination

        observations.append(Task { [store, progressWindow] in
            for await isVisible in Observations({ store.isProgressWindowVisible }) {
                progressWindow.setVisible(isVisible)
            }
        })
        observations.append(Task { [store, progressWindow] in
            // A row asking for a password or key needs the keyboard: the app comes forward and the window takes it.
            for await isAsking in Observations({ store.isProgressWindowVisible && store.isAwaitingCredential }) where isAsking {
                progressWindow.focus()
            }
        })
        observations.append(Task { [store] in
            // The queue changes when alerts are added behind the one showing: present each one once.
            var presented: FailureAlert.ID?
            for await alert in Observations({ store.alerts.first }) {
                guard let alert, alert.id != presented else { continue }
                presented = alert.id
                Self.present(alert) { store.send(.alertDismissed) }
            }
        })
        observations.append(Task { [store, weak self] in
            for await isIdle in Observations({ store.isIdle }) {
                guard isIdle, self?.launchedWithArchives == true else { continue }
                // A moment for a reveal in the Finder to land, and for more archives opened on the heels of these.
                try? await Task.sleep(for: .seconds(1))
                if store.isIdle { Self.requestTermination() }
            }
        })
    }

    /// Quits from a run loop block. `terminate` called on the main queue (from a task or a dispatch source) waits for
    /// `applicationShouldTerminate`'s reply in a nested run loop that doesn't drain the main queue, so the main actor,
    /// and the expansions' cleanup with it, never ran again: a `SIGTERM` mid-expansion hung the app.
    private static func requestTermination() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    /// Shows `alert` as Archive Utility does, a standalone alert naming the archive. `runModal` runs from a run loop
    /// block, not inside a task, so the main actor's queue (the other expansions' rows) keeps draining under it.
    private static func present(_ alert: FailureAlert, dismissed: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                let panel = NSAlert()
                panel.alertStyle = .warning
                panel.messageText = String(localized: alert.title)
                panel.informativeText = alert.message
                panel.addButton(withTitle: String(localized: "OK", comment: "Button that dismisses a failure alert."))
                NSApp.activate()
                panel.runModal()
                dismissed()
            }
        }
    }
}
