import AppKit
import ComposableArchitecture
import SwiftUI

/// The small progress window, like Archive Utility's: a row per archive in flight.
@MainActor
final class ProgressWindowController {
    private let window: NSWindow

    init(store: StoreOf<Archiver>) {
        let hosting = NSHostingController(rootView: ExpansionsView(store: store))
        hosting.sizingOptions = [.preferredContentSize]
        window = NSWindow(contentViewController: hosting)
        window.title = "Nunarchiver"
        window.styleMask = [.titled, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.frameName)
    }

    /// The name the window's position is saved under.
    private static let frameName = "ProgressWindow"

    func setVisible(_ isVisible: Bool) {
        if isVisible {
            if !window.isVisible, !window.setFrameUsingName(Self.frameName) { window.center() }
            window.orderFront(nil)
        } else {
            window.orderOut(nil)
        }
    }

    /// Brings the window forward to be typed in: a row is asking for a password or key.
    func focus() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct ExpansionsView: View {
    let store: StoreOf<Archiver>

    var body: some View {
        VStack(spacing: 0) {
            ForEach(store.scope(\.expansions)) { row in
                ExpansionRow(store: row)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One archive's row: its icon, then its progress or, when it needs a password or key, the prompt.
///
/// This body reads only what changes rarely (the archive, whether a prompt is up). What the poll timer changes four
/// times a second is read by ``ExpansionProgressView``'s body alone, so a tick re-evaluates that and nothing else.
struct ExpansionRow: View {
    let store: StoreOf<Expansion>

    var body: some View {
        HStack(spacing: 12) {
            ArchiveIcon(archive: store.archive)
            if let request = store.credentialRequest {
                CredentialPrompt(store: store, request: request)
            } else {
                ExpansionProgressView(store: store)
            }
        }
    }
}

/// The Finder's icon for the archive. A view of its own, taking only the URL, so the lookup runs when the row
/// appears, not on every poll.
struct ArchiveIcon: View {
    let archive: URL

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: archive.path))
            .resizable()
            .frame(width: 32, height: 32)
            // Decoration: the row's text names the archive.
            .accessibilityHidden(true)
    }
}

/// The polled part of a row: what's happening to the archive, the bar, the counts, and the cancel button.
struct ExpansionProgressView: View {
    let store: StoreOf<Expansion>

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Always a determinate bar, bound to the polled fraction: empty until there is one, full while the
                // last steps finish. (An optional value, indeterminate while `nil`, stayed drawn as indeterminate on
                // screen after it got a value, though the control underneath reported the value.)
                ProgressView(value: store.progress.fraction ?? 0)
                    .progressViewStyle(.linear)
                caption
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // One element for VoiceOver: "Expanding “Photos.zip”, 40%, 1,234 items — 312 MB/s", not three unrelated
            // ones (the bar alone has no label, and no value while it's indeterminate).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(store.title))
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(.updatesFrequently)
            Button("Stop", systemImage: "xmark.circle.fill") {
                store.send(.cancelButtonTapped)
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .help(Text("Stop expanding “\(store.name)”", comment: "Help tag of a row's stop button. The variable is the archive's file name."))
            .disabled(store.isCancelling)
        }
    }

    /// The counts, or a blank line of the same height before there's anything to count.
    private var caption: Text {
        store.caption.map { Text($0) } ?? Text(verbatim: " ")
    }

    /// How far along, and the counts: whichever of the two there are.
    private var accessibilityValue: Text {
        let percent = store.progress.barFraction.map { Text($0, format: .percent.precision(.fractionLength(0))) }
        return switch (percent, store.caption) {
        case let (percent?, caption?): Text("\(percent), \(Text(caption))", comment: "VoiceOver value of a row: the percent done, then the counts.")
        case let (percent?, nil): percent
        case let (nil, caption?): Text(caption)
        case (nil, nil): Text(verbatim: "")
        }
    }
}

/// A row asking for what its archive needs: a secure field for a password or key (a plain one for a signer's public
/// key, which is no secret), Cancel, and Expand. A wrong entry comes back here with a note.
struct CredentialPrompt: View {
    @Bindable var store: StoreOf<Expansion>
    let request: CredentialRequest
    @FocusState private var isFocused: Bool

    // The variable in each title is the archive's file name.
    private var title: LocalizedStringResource {
        switch request.kind {
        case .password: "“\(store.name)” needs a password."
        case .key: "“\(store.name)” needs its encryption key."
        case .signingPublicKey: "“\(store.name)” needs its signer’s public key."
        }
    }

    private var placeholder: LocalizedStringResource {
        switch request.kind {
        case .password: "Password"
        case .key: "Key (hex or base64:…)"
        case .signingPublicKey: "Public key (PEM, hex, or base64:…)"
        }
    }

    /// Why the prompt is (still) here, when there's something to say.
    private var note: LocalizedStringResource? {
        guard request.isRetry else {
            return request.kind == .signingPublicKey ? "The archive is signed but doesn’t say by whom." : nil
        }
        return switch request.kind {
        case .password: "That password didn’t open the archive. Try again."
        case .key: "That key didn’t open the archive. Try again."
        case .signingPublicKey: "That key didn’t sign the archive. Try again."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Group {
                if request.kind == .signingPublicKey {
                    TextField(placeholder, text: $store.credentialText)
                } else {
                    SecureField(placeholder, text: $store.credentialText)
                }
            }
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit { store.send(.credentialSubmitButtonTapped) }
            HStack {
                // A blank line of the same height when there's no note.
                (note.map { Text($0) } ?? Text(verbatim: " "))
                    .font(.caption)
                    .foregroundStyle(request.isRetry ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                Spacer()
                Button("Cancel", role: .cancel) {
                    store.send(.cancelButtonTapped)
                }
                .keyboardShortcut(.cancelAction)
                Button("Expand") {
                    store.send(.credentialSubmitButtonTapped)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.credentialText.isEmpty)
            }
        }
        .onAppear { isFocused = true }
    }
}

struct SettingsView: View {
    @AppStorage(LiveWorkspace.revealsExpandedItemsKey) private var revealsExpandedItems = false

    var body: some View {
        Form {
            Toggle("Reveal expanded items in the Finder", isOn: $revealsExpandedItems)
        }
        .padding(20)
        .frame(width: 380)
    }
}

#Preview {
    ExpansionsView(
        store: Store(
            initialState: Archiver.State(
                expansions: [
                    Expansion.State(
                        id: UUID(),
                        archive: URL(filePath: "/tmp/Xcode_27.3_beta.xip"),
                        byteSamples: [0, 2_600_000_000],
                        progress: ExpansionProgress(entries: 12_345, bytes: 2_600_000_000, fraction: 0.4)
                    ),
                    Expansion.State(id: UUID(), archive: URL(filePath: "/tmp/Photos.zip")),
                    Expansion.State(
                        id: UUID(),
                        archive: URL(filePath: "/tmp/Secrets.zip"),
                        credentialRequest: CredentialRequest(kind: .password, isRetry: true)
                    ),
                ]
            )
        ) {
            Archiver()
        }
    )
}
