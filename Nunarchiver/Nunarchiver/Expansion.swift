import ComposableArchitecture
import Foundation

/// One archive being expanded: a row in the progress window.
///
/// Mounting starts the expansion; it ends with ``Action/expansionFinished(_:)``, which the parent (``Archiver``) acts on
/// and removes the row. Cancelling (the row's button, the prompt's, or the parent invoking ``State/cancel`` when the
/// app quits) cancels the expansion's task; the expander then removes what it staged and reports
/// ``ExpansionOutcome/cancelled``, so the row stays until nothing is left on disk.
///
/// An archive that needs a password or key reports ``ExpansionOutcome/needsCredential(_:)`` instead of expanding: the
/// row becomes a prompt (``State/credentialRequest``), and submitting starts the expansion again with what was entered.
/// A wrong one comes back as another request, marked as a retry. Cancelling the prompt ends the expansion as cancelled.
@Feature struct Expansion {
    struct State: Identifiable {
        let id: UUID
        let archive: URL
        /// The polled byte counter at the last ticks of the poll timer (see ``Throughput``).
        var byteSamples: [Int] = []
        /// What the archive needs before it can be expanded: the row shows a field for it.
        var credentialRequest: CredentialRequest?
        /// The prompt's field.
        var credentialText = ""
        /// What's been entered so far, given to every attempt.
        var credentials = ArchiveCredentials()
        var isCancelling = false
        var progress = ExpansionProgress()
        /// Cancels the expansion, as the cancel button does: for the parent, when the app quits.
        @Trigger var cancel
        @StoreTaskID var expansion

        var name: String { archive.lastPathComponent }

        /// Bytes written to disk per second over the last ticks, once two readings exist.
        var bytesPerSecond: Double? {
            Throughput.bytesPerSecond(samples: byteSamples, interval: Archiver.pollInterval)
        }
    }

    enum Action {
        /// The row's cancel button, or the prompt's.
        case cancelButtonTapped
        case credentialRequested(CredentialRequest)
        case credentialSubmitButtonTapped
        case expansionFinished(ExpansionOutcome)
    }

    @FeatureEnvironment(\.archiveExpander) var archiveExpander

    var body: some Feature {
        Update { state, action in
            switch action {
            case .cancelButtonTapped:
                cancel(&state)

            case let .credentialRequested(request):
                state.byteSamples = []
                state.credentialRequest = request
                state.credentialText = ""
                state.progress = ExpansionProgress()

            case .credentialSubmitButtonTapped:
                guard let request = state.credentialRequest, !state.credentialText.isEmpty else { return }
                state.credentials[request.kind] = state.credentialText
                state.credentialRequest = nil
                state.credentialText = ""
                expand(state)

            case .expansionFinished:
                // Handled by the parent, which removes this row.
                break
            }
        }
        .onMount { state in
            expand(state)
        }
        .onTrigger(store.cancel) { state in
            cancel(&state)
        }
    }

    // MARK: Helpers

    /// Stops the expansion, once. A running one is cancelled through its task, and ends when the expander has cleaned
    /// up; behind a prompt nothing is running, so the prompt goes and the expansion ends as cancelled here.
    private func cancel(_ state: inout State) {
        guard !state.isCancelling else { return }
        state.isCancelling = true
        if state.credentialRequest != nil {
            state.credentialRequest = nil
            state.credentialText = ""
            store.addTask {
                try store.send(.expansionFinished(.cancelled))
            }
        } else {
            store.addTask {
                store.expansion.cancel()
            }
        }
    }

    /// Starts the expansion with what's been entered so far.
    private func expand(_ state: State) {
        let archive = state.archive
        let credentials = state.credentials
        let id = state.id
        // Explicitly user-initiated: the user opened it and is waiting. Inherited priority isn't enough (the live
        // expander also raises its own work and holds an activity against App Nap).
        store.addTask(id: state.expansion, priority: .userInitiated) {
            switch await archiveExpander.expand(archive, id: id, credentials: credentials) {
            case let .needsCredential(request):
                try store.send(.credentialRequested(request))
            case let outcome:
                try store.send(.expansionFinished(outcome))
            }
        }
    }
}

// MARK: What the row shows

extension Expansion.State {
    /// What's happening to the archive.
    var title: LocalizedStringResource {
        if isCancelling {
            LocalizedStringResource("Stopping “\(name)”…", comment: "Row title while an expansion is being cancelled. The variable is the archive's file name.")
        } else if progress.isFinishing {
            LocalizedStringResource("Finishing “\(name)”…", comment: "Row title once everything is written and only the last steps remain. The variable is the archive's file name.")
        } else {
            LocalizedStringResource("Expanding “\(name)”", comment: "Row title while an archive is expanded. The variable is the archive's file name.")
        }
    }

    /// Items written, and how fast: bytes written to disk per second (see ``Throughput``), left out while nothing is
    /// being written. `nil` until anything is counted.
    var caption: LocalizedStringResource? {
        guard progress.entries > 0 else { return nil }
        let items = itemCount
        guard !progress.isFinishing, !isCancelling, let rate = bytesPerSecond.flatMap({ Throughput.label(bytesPerSecond: $0) }) else {
            return items
        }
        return LocalizedStringResource(
            "\(items) — \(rate)",
            comment: "Row caption: how many items have been written (such as “1,234 items”), then the rate they're written at (such as “312 MB/s”)."
        )
    }

    /// "1 item", "1,234 items". Two keys, so English is right with no String Catalog; in one, "%lld items" takes each
    /// language's plural variations. (Automatic grammar agreement, `^[…](inflect: true)`, isn't applied by
    /// `String(localized:)` here, which VoiceOver's value and the tests read: the markup came out as written.)
    private var itemCount: LocalizedStringResource {
        let items = progress.entries
        return items == 1
            ? LocalizedStringResource("1 item", comment: "Row caption: exactly one file, folder, or link has been written.")
            : LocalizedStringResource("\(items) items", comment: "Row caption: how many files, folders, and links have been written.")
    }
}
