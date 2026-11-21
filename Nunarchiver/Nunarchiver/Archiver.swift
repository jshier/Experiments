import Clocks
import ComposableArchitecture
import Foundation

/// The app: archives being expanded, the progress window, and failures to report.
///
/// - Opening archives adds an ``Expansion`` per archive; each starts on mount and they run concurrently.
/// - The progress window appears only once something has been expanding for ``windowDelay`` (Archive Utility shows
///   nothing for quick expansions) and closes when the last one ends.
/// - While it's visible, ``pollInterval`` ticks of the clock read each expansion's counters from the expander. Nothing
///   is observed per entry: the writers bump relaxed atomics and this polls them. Each tick's byte count is also a
///   sample for the row's throughput (``Throughput``: bytes written to disk per second, over the last 2 s of ticks).
/// - An archive that needs a password or key shows the window at once: its row is the prompt.
/// - A finished expansion is revealed in the Finder if the setting is on; a failed one queues an alert naming it.
@Feature struct Archiver {
    struct State {
        var alerts: [FailureAlert] = []
        var expansions: [Expansion.State] = []
        var isProgressWindowVisible = false

        /// A row is asking for a password or key: its window needs the keyboard.
        var isAwaitingCredential: Bool { expansions.contains { $0.credentialRequest != nil } }

        /// Nothing running and nothing to report: the app may quit.
        var isIdle: Bool { expansions.isEmpty && alerts.isEmpty }
    }

    enum Action {
        case alertDismissed
        case archivesOpened([URL])
        case expansions(Expansion.State.ID, Expansion.Action)
        /// The app is quitting (the Quit command, logout, `SIGTERM`): stop every expansion, as each row's cancel
        /// button does (``Expansion/State/cancel``), so nothing staged is left behind.
        case quitRequested
    }

    /// How long expansion runs before the window appears.
    static let windowDelay = Duration.milliseconds(500)
    /// How often the window reads progress.
    static let pollInterval = Duration.milliseconds(250)

    @FeatureEnvironment(\.archiveExpander) var archiveExpander
    @FeatureEnvironment(\.continuousClock) var clock
    @FeatureEnvironment(\.uuid) var uuid
    @FeatureEnvironment(\.workspace) var workspace

    var body: some Feature {
        Update { state, action in
            switch action {
            case .alertDismissed:
                if !state.alerts.isEmpty { state.alerts.removeFirst() }

            case .archivesOpened(let archives):
                for archive in archives {
                    state.expansions.append(Expansion.State(id: uuid(), archive: archive))
                }

            case .expansions(let id, .expansionFinished(let outcome)):
                guard let index = state.expansions.firstIndex(where: { $0.id == id }) else { return }
                let archive = state.expansions.remove(at: index).archive
                switch outcome {
                case .expanded(let item):
                    store.addTask {
                        if workspace.revealsExpandedItems { await workspace.reveal(item) }
                    }
                case .failed(let message):
                    state.alerts.append(FailureAlert(id: uuid(), archive: archive, message: message))
                case .cancelled:
                    break
                case .needsCredential:
                    // Never sent as a finish: the expansion asks (`credentialRequested`) and stays.
                    break
                }

            case .expansions(_, .credentialRequested):
                // The row is the prompt: show it now, not after the delay.
                state.isProgressWindowVisible = true

            case .expansions:
                break

            case .quitRequested:
                // Each expansion's own trigger: nothing is sent on a row's behalf.
                store.addTask {
                    for expansion in store.expansions { try expansion.cancel() }
                }
            }
        }
        .forEach(\.expansions) {
            Expansion()
        }
        // `onMount(id:)` remounts the feature it modifies when the id changes, children included, so the two below
        // modify empty features of their own: on the `forEach` above they cancelled and restarted every expansion when
        // the window appeared.
        Update { _, _ in }
        .onMount(id: store.expansions.isEmpty) { state in
            guard !state.expansions.isEmpty else {
                state.isProgressWindowVisible = false
                return
            }
            guard !state.isProgressWindowVisible else { return }
            store.addTask {
                try await clock.sleep(for: Self.windowDelay)
                try store.modify { $0.isProgressWindowVisible = true }
            }
        }
        Update { _, _ in }
        .onMount(id: store.isProgressWindowVisible) { state in
            guard state.isProgressWindowVisible else { return }
            store.addTask {
                // NB: As in TCA26's examples, the timer goes through `AnyClock`.
                let clock = AnyClock(self.clock)
                try pollProgress()
                for await _ in clock.timer(interval: Self.pollInterval) {
                    try pollProgress()
                }
            }
        }
    }

    /// Reads every running expansion's counters: its progress, and one more sample of its bytes for the throughput (a
    /// sample per tick whether or not anything changed, so a stalled expansion's rate falls to nothing).
    private func pollProgress() throws {
        let readings = store.expansions.compactMap { expansion in
            archiveExpander.progress(of: expansion.id).map { (expansion.id, $0) }
        }
        guard !readings.isEmpty else { return }
        try store.modify { state in
            for (id, reading) in readings {
                guard let index = state.expansions.firstIndex(where: { $0.id == id }) else { continue }
                state.expansions[index].progress = reading
                state.expansions[index].byteSamples = Throughput.recording(reading.bytes, in: state.expansions[index].byteSamples)
            }
        }
    }
}

/// An expansion that failed, reported in an alert naming the archive.
struct FailureAlert: Equatable, Identifiable {
    let id: UUID
    let archive: URL
    let message: String

    var title: LocalizedStringResource {
        LocalizedStringResource(
            "Unable to expand “\(archive.lastPathComponent)”.",
            comment: "Title of the alert for an archive that couldn't be expanded. The variable is the archive's file name."
        )
    }
}
