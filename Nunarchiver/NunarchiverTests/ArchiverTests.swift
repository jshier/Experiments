import Clocks
import ComposableArchitecture
import ComposableArchitectureTestSupport
import Disk
import Foundation
import Synchronization
import Testing

@testable import Nunarchiver

// Every store here is a `TestStoreActor`: each test's feature runs on an actor of its own, so the tests run in
// parallel with each other (and nothing here is `@MainActor` or serialized). Time is the suite's `TestClock`.

/// The app feature against a scripted expander and a test clock: no archives, no files.
@Suite(
    .transformEnvironment {
        $0.archiveExpander = ScriptedExpander()
        $0.continuousClock = TestClock<Duration>()
        $0.uuid = .incrementing
        $0.workspace = MockWorkspace(revealsExpandedItems: true)
    }
)
struct ArchiverTests {
    @FeatureEnvironment(\.archiveExpander, as: ScriptedExpander.self) var expander
    @FeatureEnvironment(\.continuousClock, as: TestClock<Duration>.self) var clock
    @FeatureEnvironment(\.workspace, as: MockWorkspace.self) var workspace

    static let zip = URL(filePath: "/archives/Photos.zip")
    static let xip = URL(filePath: "/archives/Xcode.xip")

    @Test func `open, progress, finish`() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.zip])) {
            $0.expansions = [Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.zip)]
        }
        #expect(await expander.waitForStart(of: Self.zip))

        // Nothing shows for the first half second; then the window appears and reads progress at once.
        expander.setProgress(ExpansionProgress(entries: 10, bytes: 100_000_000, fraction: 0.25), for: UUID(1))
        await clock.advance(by: .milliseconds(499))
        await clock.advance(by: .milliseconds(1))
        await store.expect {
            $0.isProgressWindowVisible = true
            $0.expansions[0].progress = ExpansionProgress(entries: 10, bytes: 100_000_000, fraction: 0.25)
            $0.expansions[0].byteSamples = [100_000_000]
        }
        // One reading is no rate yet.
        #expect(await store.run { $0.state.expansions[0].bytesPerSecond } == nil)

        // Then on every tick of the poll interval: the progress, and a sample of the bytes for the throughput.
        expander.setProgress(ExpansionProgress(entries: 30, bytes: 400_000_000, fraction: 0.75), for: UUID(1))
        await clock.advance(by: Archiver.pollInterval)
        await store.expect {
            $0.expansions[0].progress = ExpansionProgress(entries: 30, bytes: 400_000_000, fraction: 0.75)
            $0.expansions[0].byteSamples = [100_000_000, 400_000_000]
        }
        // 300 MB in one 250 ms tick.
        #expect(await store.run { $0.state.expansions[0].bytesPerSecond } == 1_200_000_000)

        // Nothing written for a tick: the same progress, one more sample, half the rate.
        await clock.advance(by: Archiver.pollInterval)
        await store.expect {
            $0.expansions[0].byteSamples = [100_000_000, 400_000_000, 400_000_000]
        }
        #expect(await store.run { $0.state.expansions[0].bytesPerSecond } == 600_000_000)

        expander.finish(Self.zip, with: .expanded(URL(filePath: "/archives/Photos")))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
            $0.isProgressWindowVisible = false
        }?.value
        #expect(workspace.revealedURLs == [URL(filePath: "/archives/Photos")])
        // The window appearing and polling never restarts the expansion.
        #expect(expander.starts == [Self.zip: 1])
        #expect(expander.cancelled.isEmpty)
        await store.dismount()
    }

    /// The row as its polls go: no bar until the extraction has counted something (even with totals known), a bar
    /// while bytes remain, and none again once they're all written and only links and metadata are left.
    @Test func `the bar is indeterminate, then determinate, then finishing`() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.zip])) {
            $0.expansions = [Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.zip)]
        }
        #expect(await expander.waitForStart(of: Self.zip))
        // Before any poll: the row as it's made.
        var row = await Self.row(of: store)
        #expect(row.bar == nil)
        #expect(row.title == "Expanding “Photos.zip”")
        #expect(row.caption == nil)

        // Totals known, nothing counted yet.
        expander.setProgress(ExpansionProgress(entries: 0, bytes: 0, fraction: 0), for: UUID(1))
        await clock.advance(by: Archiver.windowDelay)
        await store.expect {
            $0.isProgressWindowVisible = true
            $0.expansions[0].progress = ExpansionProgress(entries: 0, bytes: 0, fraction: 0)
            $0.expansions[0].byteSamples = [0]
        }
        row = await Self.row(of: store)
        #expect(row.bar == nil)
        #expect(row.caption == nil)

        // The first counted entry makes it determinate, on the very next tick.
        expander.setProgress(ExpansionProgress(entries: 40, bytes: 400_000_000, fraction: 0.4), for: UUID(1))
        await clock.advance(by: Archiver.pollInterval)
        await store.expect {
            $0.expansions[0].progress = ExpansionProgress(entries: 40, bytes: 400_000_000, fraction: 0.4)
            $0.expansions[0].byteSamples = [0, 400_000_000]
        }
        row = await Self.row(of: store)
        #expect(row.bar == 0.4)
        #expect(row.title == "Expanding “Photos.zip”")
        // 400 MB in a 250 ms tick.
        #expect(row.caption == "40 items — 1.6 GB/s")

        // Every byte written, the expansion not over: no full bar, no rate.
        expander.setProgress(ExpansionProgress(entries: 100, bytes: 1_000_000_000, fraction: 1), for: UUID(1))
        await clock.advance(by: Archiver.pollInterval)
        await store.expect {
            $0.expansions[0].progress = ExpansionProgress(entries: 100, bytes: 1_000_000_000, fraction: 1)
            $0.expansions[0].byteSamples = [0, 400_000_000, 1_000_000_000]
        }
        row = await Self.row(of: store)
        #expect(row.bar == nil)
        #expect(row.title == "Finishing “Photos.zip”…")
        #expect(row.caption == "100 items")

        expander.finish(Self.zip, with: .expanded(URL(filePath: "/archives/Photos")))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
            $0.isProgressWindowVisible = false
        }?.value
        await store.dismount()
    }

    @Test(.transformEnvironment { $0.workspace = MockWorkspace(revealsExpandedItems: false) })
    func `quick expansions never show the window`() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.zip])) {
            $0.expansions = [Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.zip)]
        }
        #expect(await expander.waitForStart(of: Self.zip))
        await clock.advance(by: .milliseconds(400))
        expander.finish(Self.zip, with: .expanded(URL(filePath: "/archives/Photos")))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
        }?.value
        await clock.advance(by: .seconds(1))
        #expect(workspace.revealedURLs.isEmpty)
        await store.dismount()
    }

    @Test func cancel() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.xip])) {
            $0.expansions = [Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.xip)]
        }
        #expect(await expander.waitForStart(of: Self.xip))

        await store.send(to: \.expansions[0], .cancelButtonTapped) {
            $0.expansions[0].isCancelling = true
        }
        // The expander sees the cancellation, cleans up, and reports it; the row goes and nothing is revealed.
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
        }
        #expect(expander.cancelled == [Self.xip])
        #expect(workspace.revealedURLs.isEmpty)
        await store.dismount()
    }

    @Test func `cancelling with the window up closes it`() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.xip])) {
            $0.expansions = [Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.xip)]
        }
        #expect(await expander.waitForStart(of: Self.xip))
        expander.setProgress(ExpansionProgress(entries: 7, bytes: 7_000_000, fraction: 0.5), for: UUID(1))
        await clock.advance(by: Archiver.windowDelay)
        await store.expect {
            $0.isProgressWindowVisible = true
            $0.expansions[0].progress = ExpansionProgress(entries: 7, bytes: 7_000_000, fraction: 0.5)
            $0.expansions[0].byteSamples = [7_000_000]
        }

        await store.send(to: \.expansions[0], .cancelButtonTapped) {
            $0.expansions[0].isCancelling = true
        }
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
            $0.isProgressWindowVisible = false
        }
        #expect(expander.cancelled == [Self.xip])
        await store.dismount()
    }

    /// A row already stopping ignores another cancel (the button is disabled, but a key can repeat, and quitting
    /// cancels every row): the expansion's task is cancelled once.
    @Test func `a row that's stopping ignores another cancel`() async {
        var row = Expansion.State(id: UUID(1), archive: Self.xip)
        row.isCancelling = true
        let store = await TestStoreActor(initialState: row) {
            Expansion()
        }
        #expect(await expander.waitForStart(of: Self.xip))

        await store.send(.cancelButtonTapped)
        await store.trigger(\.cancel)
        #expect(expander.cancelled.isEmpty)

        expander.finish(Self.xip, with: .expanded(URL(filePath: "/archives/Xcode.app")))
        await store.receive(\.expansionFinished, timeout: .seconds(5))
        await store.dismount()
    }

    @Test func `quitting cancels every expansion`() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.zip, Self.xip])) {
            $0.expansions = [
                Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.zip),
                Expansion.State.DebugSnapshot(id: UUID(2), archive: Self.xip),
            ]
        }
        #expect(await expander.waitForStart(of: Self.zip))
        #expect(await expander.waitForStart(of: Self.xip))

        // Each expansion's cancel trigger is invoked: no action is sent on the rows' behalf.
        await store.send(.quitRequested) {
            $0.expansions[0].isCancelling = true
            $0.expansions[1].isCancelling = true
        }
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions.removeFirst()
        }
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
        }
        #expect(Set(expander.cancelled) == [Self.zip, Self.xip])
        await store.dismount()
    }

    @Test func `quitting with nothing running changes nothing`() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }
        await store.send(.quitRequested)
        #expect(await store.run { $0.state.isIdle })
        await store.dismount()
    }

    @Test func `failure shows an alert naming the archive`() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.zip])) {
            $0.expansions = [Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.zip)]
        }
        #expect(await expander.waitForStart(of: Self.zip))
        expander.finish(Self.zip, with: .failed("CRC mismatch for 'a.jpg'."))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
            $0.alerts = [FailureAlert(id: UUID(2), archive: Self.zip, message: "CRC mismatch for 'a.jpg'.")]
        }
        let title = await store.run { $0.state.alerts.first?.title }
        #expect(title?.english == "Unable to expand “Photos.zip”.")
        #expect(await !store.run { $0.state.isIdle })
        #expect(workspace.revealedURLs.isEmpty)

        await store.send(.alertDismissed) {
            $0.alerts = []
        }
        #expect(await store.run { $0.state.isIdle })
        // Nothing left to dismiss: nothing happens.
        await store.send(.alertDismissed)
        await store.dismount()
    }

    /// Failures queue in the order they happen and are dismissed from the front, one alert at a time; an archive
    /// that fails doesn't disturb one still running, and the app isn't idle until both are dealt with.
    @Test func `alerts queue in order while other archives run`() async {
        let third = URL(filePath: "/archives/Third.aar")
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.zip, Self.xip, third])) {
            $0.expansions = [
                Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.zip),
                Expansion.State.DebugSnapshot(id: UUID(2), archive: Self.xip),
                Expansion.State.DebugSnapshot(id: UUID(3), archive: third),
            ]
        }
        for archive in [Self.zip, Self.xip, third] {
            #expect(await expander.waitForStart(of: archive))
        }

        // The second fails first, then the first: the queue is in that order.
        expander.finish(Self.xip, with: .failed("Bad signature."))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions.remove(at: 1)
            $0.alerts = [FailureAlert(id: UUID(4), archive: Self.xip, message: "Bad signature.")]
        }
        expander.finish(Self.zip, with: .failed("CRC mismatch."))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions.remove(at: 0)
            $0.alerts.append(FailureAlert(id: UUID(5), archive: Self.zip, message: "CRC mismatch."))
        }
        #expect(await store.run { $0.state.alerts.first?.archive } == Self.xip)

        // Dismissing shows the next; the third archive is still running through all of it.
        await store.send(.alertDismissed) {
            $0.alerts.removeFirst()
        }
        #expect(await store.run { $0.state.alerts.first?.archive } == Self.zip)
        await store.send(.alertDismissed) {
            $0.alerts = []
        }
        #expect(await !store.run { $0.state.isIdle })
        #expect(expander.cancelled.isEmpty)

        expander.finish(third, with: .expanded(URL(filePath: "/archives/Third")))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
        }?.value
        #expect(await store.run { $0.state.isIdle })
        #expect(workspace.revealedURLs == [URL(filePath: "/archives/Third")])
        await store.dismount()
    }

    @Test func `several archives run at once`() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.zip, Self.xip])) {
            $0.expansions = [
                Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.zip),
                Expansion.State.DebugSnapshot(id: UUID(2), archive: Self.xip),
            ]
        }
        // Both started before either finished.
        #expect(await expander.waitForStart(of: Self.zip))
        #expect(await expander.waitForStart(of: Self.xip))

        await clock.advance(by: Archiver.windowDelay)
        await store.expect {
            $0.isProgressWindowVisible = true
        }
        expander.setProgress(ExpansionProgress(entries: 5, fraction: 0.5), for: UUID(2))
        await clock.advance(by: Archiver.pollInterval)
        await store.expect {
            $0.expansions[1].progress = ExpansionProgress(entries: 5, fraction: 0.5)
            $0.expansions[1].byteSamples = [0]
        }

        // The second finishes first; its row goes and the window stays for the other.
        expander.finish(Self.xip, with: .expanded(URL(filePath: "/archives/Xcode.app")))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = [Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.zip)]
        }?.value

        expander.finish(Self.zip, with: .expanded(URL(filePath: "/archives/Photos")))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
            $0.isProgressWindowVisible = false
        }?.value
        #expect(workspace.revealedURLs == [URL(filePath: "/archives/Xcode.app"), URL(filePath: "/archives/Photos")])
        #expect(expander.starts == [Self.zip: 1, Self.xip: 1])
        #expect(expander.cancelled.isEmpty)
        await store.dismount()
    }

    /// An archive opened while another expands joins it: the window's delay counts from the first, each row polls its
    /// own expansion, and neither is restarted by the other arriving or leaving.
    @Test func `an archive opened while another expands joins it`() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.zip])) {
            $0.expansions = [Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.zip)]
        }
        #expect(await expander.waitForStart(of: Self.zip))
        await clock.advance(by: .milliseconds(300))

        await store.send(.archivesOpened([Self.xip])) {
            $0.expansions.append(Expansion.State.DebugSnapshot(id: UUID(2), archive: Self.xip))
        }
        #expect(await expander.waitForStart(of: Self.xip))
        // 500 ms after the first, not the second.
        expander.setProgress(ExpansionProgress(entries: 1, bytes: 10, fraction: 0.1), for: UUID(1))
        expander.setProgress(ExpansionProgress(entries: 2, bytes: 20, fraction: 0.2), for: UUID(2))
        await clock.advance(by: .milliseconds(200))
        await store.expect {
            $0.isProgressWindowVisible = true
            $0.expansions[0].progress = ExpansionProgress(entries: 1, bytes: 10, fraction: 0.1)
            $0.expansions[0].byteSamples = [10]
            $0.expansions[1].progress = ExpansionProgress(entries: 2, bytes: 20, fraction: 0.2)
            $0.expansions[1].byteSamples = [20]
        }

        // The first finishes: the second's row keeps its readings and goes on being polled.
        expander.finish(Self.zip, with: .expanded(URL(filePath: "/archives/Photos")))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions.removeFirst()
        }?.value
        expander.setProgress(ExpansionProgress(entries: 4, bytes: 40, fraction: 0.4), for: UUID(2))
        await clock.advance(by: Archiver.pollInterval)
        await store.expect {
            $0.expansions[0].progress = ExpansionProgress(entries: 4, bytes: 40, fraction: 0.4)
            $0.expansions[0].byteSamples = [20, 40]
        }

        expander.finish(Self.xip, with: .expanded(URL(filePath: "/archives/Xcode.app")))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
            $0.isProgressWindowVisible = false
        }?.value
        #expect(expander.starts == [Self.zip: 1, Self.xip: 1])
        #expect(expander.cancelled.isEmpty)
        await store.dismount()
    }

    /// What a row shows, read from the store.
    static func row(of store: TestStoreActor<Archiver>, at index: Int = 0) async -> (bar: Double?, title: String, caption: String?) {
        await store.run {
            let expansion = $0.state.expansions[index]
            return (expansion.progress.barFraction, expansion.title.english, expansion.caption?.english)
        }
    }
}

/// Archives that need a password or key: the row asks, and the expansion starts again with what was entered.
@Suite(
    .transformEnvironment {
        $0.archiveExpander = ScriptedExpander()
        $0.continuousClock = TestClock<Duration>()
        $0.uuid = .incrementing
        $0.workspace = MockWorkspace(revealsExpandedItems: false)
    }
)
struct CredentialTests {
    @FeatureEnvironment(\.archiveExpander, as: ScriptedExpander.self) var expander
    @FeatureEnvironment(\.continuousClock, as: TestClock<Duration>.self) var clock

    static let zip = URL(filePath: "/archives/Secrets.zip")
    static let aea = URL(filePath: "/archives/Secrets.aea")

    @Test func `password prompt, wrong password, then expansion`() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.zip])) {
            $0.expansions = [Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.zip)]
        }
        #expect(await expander.waitForStart(of: Self.zip))
        // The archive can't be opened: the row becomes the prompt, and the window shows at once (no delay).
        expander.finish(Self.zip, with: .needsCredential(CredentialRequest(kind: .password)))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions[0].credentialRequest = CredentialRequest(kind: .password)
            $0.isProgressWindowVisible = true
        }
        #expect(await store.run { $0.state.isAwaitingCredential })
        #expect(expander.credentials[Self.zip] == [ArchiveCredentials()])

        // An empty field submits nothing.
        await store.send(to: \.expansions[0], .credentialSubmitButtonTapped)
        #expect(expander.starts == [Self.zip: 1])

        // The field is bound to state; submitting starts the expansion again with the password.
        await store.modify {
            $0.expansions[0].credentialText = "guess"
        }
        await store.send(to: \.expansions[0], .credentialSubmitButtonTapped) {
            $0.expansions[0].credentials = ArchiveCredentials(values: [.password: "guess"])
            $0.expansions[0].credentialRequest = nil
            $0.expansions[0].credentialText = ""
        }
        #expect(await !store.run { $0.state.isAwaitingCredential })
        #expect(await expander.waitForStart(of: Self.zip, count: 2))
        #expect(expander.credentials[Self.zip]?.last == ArchiveCredentials(values: [.password: "guess"]))

        // Wrong: the prompt comes back, marked as a retry, the field empty again.
        expander.finish(Self.zip, with: .needsCredential(CredentialRequest(kind: .password, isRetry: true)))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions[0].credentialRequest = CredentialRequest(kind: .password, isRetry: true)
        }

        await store.modify {
            $0.expansions[0].credentialText = "sesame"
        }
        await store.send(to: \.expansions[0], .credentialSubmitButtonTapped) {
            $0.expansions[0].credentials = ArchiveCredentials(values: [.password: "sesame"])
            $0.expansions[0].credentialRequest = nil
            $0.expansions[0].credentialText = ""
        }
        #expect(await expander.waitForStart(of: Self.zip, count: 3))
        expander.finish(Self.zip, with: .expanded(URL(filePath: "/archives/Secrets")))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
            $0.isProgressWindowVisible = false
        }
        #expect(expander.credentials[Self.zip]?.last == ArchiveCredentials(values: [.password: "sesame"]))
        #expect(expander.cancelled.isEmpty)
        await store.dismount()
    }

    /// An archive can ask for more than one thing, one at a time (an `.aea`'s key, then its signer's public key):
    /// each is kept under its kind and every attempt gets all of them.
    @Test func `a key, then a signer's key: each attempt gets everything entered`() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.aea])) {
            $0.expansions = [Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.aea)]
        }
        #expect(await expander.waitForStart(of: Self.aea))
        expander.finish(Self.aea, with: .needsCredential(CredentialRequest(kind: .key)))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions[0].credentialRequest = CredentialRequest(kind: .key)
            $0.isProgressWindowVisible = true
        }
        await store.modify {
            $0.expansions[0].credentialText = "00ff"
        }
        await store.send(to: \.expansions[0], .credentialSubmitButtonTapped) {
            $0.expansions[0].credentials = ArchiveCredentials(values: [.key: "00ff"])
            $0.expansions[0].credentialRequest = nil
            $0.expansions[0].credentialText = ""
        }
        #expect(await expander.waitForStart(of: Self.aea, count: 2))

        expander.finish(Self.aea, with: .needsCredential(CredentialRequest(kind: .signingPublicKey)))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions[0].credentialRequest = CredentialRequest(kind: .signingPublicKey)
        }
        await store.modify {
            $0.expansions[0].credentialText = "04ab"
        }
        let both = ArchiveCredentials(values: [.key: "00ff", .signingPublicKey: "04ab"])
        await store.send(to: \.expansions[0], .credentialSubmitButtonTapped) {
            $0.expansions[0].credentials = both
            $0.expansions[0].credentialRequest = nil
            $0.expansions[0].credentialText = ""
        }
        #expect(await expander.waitForStart(of: Self.aea, count: 3))
        #expect(expander.credentials[Self.aea] == [ArchiveCredentials(), ArchiveCredentials(values: [.key: "00ff"]), both])

        expander.finish(Self.aea, with: .expanded(URL(filePath: "/archives/Secrets")))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
            $0.isProgressWindowVisible = false
        }
        await store.dismount()
    }

    /// A password found wrong only after extraction began (a ZIP's first encrypted entry) comes back as a retry with
    /// progress already shown: the row starts over, with no stale bar or rate behind the prompt, and polls while the
    /// prompt is up (nothing is running) change nothing.
    @Test func `a retry after progress resets the row`() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.zip])) {
            $0.expansions = [Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.zip)]
        }
        #expect(await expander.waitForStart(of: Self.zip))
        expander.setProgress(ExpansionProgress(entries: 3, bytes: 3_000, fraction: 0.3), for: UUID(1))
        await clock.advance(by: Archiver.windowDelay)
        await store.expect {
            $0.isProgressWindowVisible = true
            $0.expansions[0].progress = ExpansionProgress(entries: 3, bytes: 3_000, fraction: 0.3)
            $0.expansions[0].byteSamples = [3_000]
        }

        expander.finish(Self.zip, with: .needsCredential(CredentialRequest(kind: .password, isRetry: true)))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions[0].credentialRequest = CredentialRequest(kind: .password, isRetry: true)
            $0.expansions[0].progress = ExpansionProgress()
            $0.expansions[0].byteSamples = []
        }
        await clock.advance(by: Archiver.pollInterval * 3)

        // The next attempt's readings start a new window of samples.
        await store.modify {
            $0.expansions[0].credentialText = "sesame"
        }
        await store.send(to: \.expansions[0], .credentialSubmitButtonTapped) {
            $0.expansions[0].credentials = ArchiveCredentials(values: [.password: "sesame"])
            $0.expansions[0].credentialRequest = nil
            $0.expansions[0].credentialText = ""
        }
        #expect(await expander.waitForStart(of: Self.zip, count: 2))
        expander.setProgress(ExpansionProgress(entries: 1, bytes: 1_000, fraction: 0.1), for: UUID(1))
        await clock.advance(by: Archiver.pollInterval)
        await store.expect {
            $0.expansions[0].progress = ExpansionProgress(entries: 1, bytes: 1_000, fraction: 0.1)
            $0.expansions[0].byteSamples = [1_000]
        }

        expander.finish(Self.zip, with: .expanded(URL(filePath: "/archives/Secrets")))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
            $0.isProgressWindowVisible = false
        }
        await store.dismount()
    }

    @Test func `cancelling the prompt ends the expansion`() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.zip])) {
            $0.expansions = [Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.zip)]
        }
        #expect(await expander.waitForStart(of: Self.zip))
        expander.finish(Self.zip, with: .needsCredential(CredentialRequest(kind: .key)))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions[0].credentialRequest = CredentialRequest(kind: .key)
            $0.isProgressWindowVisible = true
        }
        await store.modify {
            $0.expansions[0].credentialText = "half-typed"
        }

        // The prompt's Cancel is the row's cancel.
        await store.send(to: \.expansions[0], .cancelButtonTapped) {
            $0.expansions[0].credentialRequest = nil
            $0.expansions[0].credentialText = ""
            $0.expansions[0].isCancelling = true
        }
        // Nothing failed and nothing is revealed: the row goes, and the window with it.
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
            $0.isProgressWindowVisible = false
        }
        // The expander wasn't started again, and had nothing running to cancel.
        #expect(expander.starts == [Self.zip: 1])
        #expect(expander.cancelled.isEmpty)
        #expect(await store.run { $0.state.isIdle })
        await store.dismount()
    }

    @Test func `quitting dismisses a prompt too`() async {
        let store = await TestStoreActor(initialState: Archiver.State()) {
            Archiver()
        }

        await store.send(.archivesOpened([Self.zip])) {
            $0.expansions = [Expansion.State.DebugSnapshot(id: UUID(1), archive: Self.zip)]
        }
        #expect(await expander.waitForStart(of: Self.zip))
        expander.finish(Self.zip, with: .needsCredential(CredentialRequest(kind: .password)))
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions[0].credentialRequest = CredentialRequest(kind: .password)
            $0.isProgressWindowVisible = true
        }

        await store.send(.quitRequested) {
            $0.expansions[0].credentialRequest = nil
            $0.expansions[0].isCancelling = true
        }
        await store.receive(\.expansions, timeout: .seconds(5)) {
            $0.expansions = []
            $0.isProgressWindowVisible = false
        }
        await store.dismount()
    }
}

/// The throughput arithmetic: pure functions of the polled byte counts.
@Suite struct ThroughputTests {
    @Test func `rate over the window of ticks`() {
        let tick = Duration.milliseconds(250)
        #expect(Throughput.bytesPerSecond(samples: [], interval: tick) == nil)
        #expect(Throughput.bytesPerSecond(samples: [5], interval: tick) == nil)
        // 250 MB in one tick is 1 GB/s; the same over four ticks, a quarter of it.
        #expect(Throughput.bytesPerSecond(samples: [0, 250_000_000], interval: tick) == 1_000_000_000)
        #expect(Throughput.bytesPerSecond(samples: [0, 0, 0, 0, 250_000_000], interval: tick) == 250_000_000)
        // Only the ends matter: bursts inside the window are averaged.
        #expect(Throughput.bytesPerSecond(samples: [100, 100, 900, 900, 1_100], interval: .seconds(1)) == 250)
        // Stalled: nothing written across the window.
        #expect(Throughput.bytesPerSecond(samples: [7, 7, 7], interval: tick) == 0)
        // A counter that went back (an expansion started over) is no rate.
        #expect(Throughput.bytesPerSecond(samples: [900, 100], interval: tick) == nil)
    }

    @Test func `edges: no time, one byte, the largest counts`() {
        // No time between samples is no rate (not a division by zero), nor is time running backwards.
        #expect(Throughput.bytesPerSecond(samples: [0, 100], interval: .zero) == nil)
        #expect(Throughput.bytesPerSecond(samples: [0, 100], interval: .milliseconds(-250)) == nil)
        // A back step inside the window doesn't matter if the ends are in order.
        #expect(Throughput.bytesPerSecond(samples: [10, 5, 30], interval: .seconds(1)) == 10)
        #expect(Throughput.bytesPerSecond(samples: [0, 1], interval: .seconds(1)) == 1)
        // Counts near `Int.max` don't overflow (the difference is taken first, and it fits).
        #expect(Throughput.bytesPerSecond(samples: [Int.max - 1_000, Int.max], interval: .seconds(1)) == 1_000)
        #expect(Throughput.bytesPerSecond(samples: [0, Int.max], interval: .seconds(1)) == Double(Int.max))
    }

    @Test func `the window keeps the last eight ticks`() {
        var samples: [Int] = []
        for tick in 0..<20 {
            samples = Throughput.recording(tick * 1_000, in: samples)
            // Never more than a sample per tick of the window, plus the one it starts from.
            #expect(samples.count == min(tick + 1, Throughput.windowTicks + 1))
            #expect(samples.last == tick * 1_000)
        }
        #expect(samples == Array(stride(from: 11_000, through: 19_000, by: 1_000)))
        // 8,000 bytes over 8 ticks of 250 ms.
        #expect(Throughput.bytesPerSecond(samples: samples, interval: Archiver.pollInterval) == 4_000)
        // Exactly full: the next sample pushes the oldest out.
        let full = Array(0...Throughput.windowTicks)
        #expect(Throughput.recording(99, in: full) == Array(1...Throughput.windowTicks) + [99])
        // An over-long history (none is ever made) is trimmed in one step.
        #expect(Throughput.recording(1, in: Array(repeating: 0, count: 30)).count == Throughput.windowTicks + 1)
    }

    /// Foundation's byte count format (the Finder's units and digits, for the locale given), per second.
    @Test func `labels are Foundation's byte counts per second`() {
        let english = Locale(identifier: "en_US")
        func label(_ bytesPerSecond: Double, _ locale: Locale = english) -> String? {
            Throughput.label(bytesPerSecond: bytesPerSecond, locale: locale).map { String(localized: $0) }
        }
        #expect(label(512_000) == "512 kB/s")
        #expect(label(87_540_000) == "87.5 MB/s")
        #expect(label(312_400_000) == "312.4 MB/s")
        #expect(label(1_000_000_000) == "1 GB/s")
        #expect(label(1_254_000_000) == "1.25 GB/s")
        #expect(label(12_340_000_000) == "12.34 GB/s")
        // The unit's boundary is Foundation's.
        #expect(label(999_000) == "999 kB/s")
        #expect(label(999_999_999) == "1 GB/s")
        // Another locale's digits and units.
        #expect(label(999_999) == "1 MB/s")
        // Another locale's digits, units, and spacing (no-break spaces).
        #expect(label(1_254_000_000, Locale(identifier: "de_DE")) == "1,25\u{A0}GB/s")
        #expect(label(1_254_000_000, Locale(identifier: "fr_FR")) == "1,25\u{202F}Go/s")
    }

    @Test func `no label for nothing written, or for no number`() {
        #expect(Throughput.label(bytesPerSecond: 0) == nil)
        #expect(Throughput.label(bytesPerSecond: 0.99) == nil)
        #expect(Throughput.label(bytesPerSecond: -5) == nil)
        #expect(Throughput.label(bytesPerSecond: .nan) == nil)
        #expect(Throughput.label(bytesPerSecond: .infinity) == nil)
        // A byte a second is the least there is to say.
        #expect(Throughput.label(bytesPerSecond: 1, locale: Locale(identifier: "en_US")).map { String(localized: $0) } == "1 byte/s")
    }
}

/// The row's states and texts: pure functions of a polled reading and the expansion's state.
@Suite struct ExpansionRowTests {
    @Test func `the bar is indeterminate until something is counted`() {
        #expect(ExpansionProgress().barFraction == nil)
        #expect(ExpansionProgress(entries: 0, fraction: 0).barFraction == nil)
        #expect(ExpansionProgress(entries: 3, fraction: nil).barFraction == nil)
        #expect(ExpansionProgress(entries: 3, fraction: 0).barFraction == 0)
        #expect(ExpansionProgress(entries: 0, fraction: 0.2).barFraction == 0.2)
    }

    @Test func `finishing once everything counted is written`() {
        // Still writing: a bar.
        let writing = ExpansionProgress(entries: 100, bytes: 900, fraction: 0.9)
        #expect(!writing.isFinishing)
        #expect(writing.barFraction == 0.9)
        // The last step before the end is still a bar.
        #expect(ExpansionProgress(entries: 100, bytes: 999, fraction: 0.999).barFraction == 0.999)
        // All written, not ended (directories' times, the move into place): no full bar.
        let finishing = ExpansionProgress(entries: 100, bytes: 1_000, fraction: 1)
        #expect(finishing.isFinishing)
        #expect(finishing.barFraction == nil)
        // Totals unknown: never "finishing".
        #expect(!ExpansionProgress(entries: 100, bytes: 1_000, fraction: nil).isFinishing)
    }

    /// The fraction counts entries beside bytes (each entry as 64 KiB), so work that writes no bytes moves the bar: Disk's
    /// `ExtractionProgress.read()`, which the live expander reports.
    @Test func `the fraction weighs bytes and entries together`() {
        let weight = ExtractionProgress.defaultEntryWeight
        func fraction(_ entries: Int, of expectedEntries: Int, _ bytes: Int, of expectedBytes: Int) -> Double? {
            ExtractionProgress.fraction(entries: entries, of: expectedEntries, bytes: bytes, of: expectedBytes)
        }
        // Neither total known: no fraction. One known: by that one.
        #expect(fraction(50, of: 0, 500, of: 0) == nil)
        #expect(fraction(50, of: 0, 500, of: 1_000) == 0.5)
        #expect(fraction(50, of: 200, 500, of: 0) == 0.25)
        // Both: each entry counts as `entryWeight` bytes. Here the entries are worth as much as the bytes.
        #expect(fraction(0, of: 100, 0, of: 100 * weight) == 0)
        #expect(fraction(50, of: 100, 0, of: 100 * weight) == 0.25)
        #expect(fraction(50, of: 100, 100 * weight, of: 100 * weight) == 0.75)
        #expect(fraction(100, of: 100, 100 * weight, of: 100 * weight) == 1)
        // One large file: the bar follows its bytes, not stuck until its one entry is counted.
        let large = 6_000_000_000
        #expect(abs(fraction(0, of: 1, large / 2, of: large)! - 0.5) < 0.001)
        // Every byte written with links still to make (a xip's last third): not full, and still moving.
        let bytes = 9_568_368_046
        let written = fraction(135_527, of: 167_522, bytes, of: bytes)!
        let later = fraction(160_000, of: 167_522, bytes, of: bytes)!
        #expect(written > 0.85 && written < later && later < 1)
        #expect(!ExpansionProgress(entries: 135_527, bytes: bytes, fraction: written).isFinishing)
        // Counters past an estimated total (or read a moment apart) never pass 1; nonsense never goes below 0.
        #expect(fraction(300, of: 200, 2_000, of: 1_000) == 1)
        #expect(fraction(0, of: 0, 2_000, of: 1_000) == 1)
        #expect(fraction(-5, of: 10, -5, of: 10) == 0)
    }

    @Test func `titles say what's happening`() {
        var row = Expansion.State(id: UUID(1), archive: URL(filePath: "/a/Photos.zip"))
        #expect(row.name == "Photos.zip")
        #expect(row.title.english == "Expanding “Photos.zip”")
        row.progress = ExpansionProgress(entries: 9, bytes: 90, fraction: 1)
        #expect(row.title.english == "Finishing “Photos.zip”…")
        // Stopping wins over finishing.
        row.isCancelling = true
        #expect(row.title.english == "Stopping “Photos.zip”…")
    }

    @Test func `captions count items, with a rate only while writing`() {
        var row = Expansion.State(id: UUID(1), archive: URL(filePath: "/a/Photos.zip"))
        // Nothing counted: no caption (the view keeps the line's height).
        #expect(row.caption == nil)
        row.byteSamples = [0, 250_000_000]
        #expect(row.caption == nil)

        // One item is "1 item"; thousands are grouped.
        row.byteSamples = []
        row.progress = ExpansionProgress(entries: 1, bytes: 10, fraction: 0.1)
        #expect(row.caption?.english == "1 item")
        row.progress = ExpansionProgress(entries: 12_345, bytes: 250_000_000, fraction: 0.5)
        #expect(row.caption?.english == "12,345 items")

        // With two samples there's a rate: 250 MB in a 250 ms tick.
        row.byteSamples = [0, 250_000_000]
        #expect(row.bytesPerSecond == 1_000_000_000)
        #expect(row.caption?.english == "12,345 items — 1 GB/s")
        // Stalled for the whole window: nothing is being written, so no rate.
        row.byteSamples = [250_000_000, 250_000_000]
        #expect(row.caption?.english == "12,345 items")

        // No rate while finishing or stopping, whatever the samples say.
        row.byteSamples = [0, 250_000_000]
        row.progress.fraction = 1
        #expect(row.caption?.english == "12,345 items")
        row.progress.fraction = 0.5
        row.isCancelling = true
        #expect(row.caption?.english == "12,345 items")
    }
}

/// An expander whose expansions end when the test says, reporting the progress the test sets.
final class ScriptedExpander: ArchiveExpander {
    private struct Script {
        var started: [URL: Int] = [:]
        var cancelled: [URL] = []
        var credentials: [URL: [ArchiveCredentials]] = [:]
        var outcomes: [URL: AsyncStream<ExpansionOutcome>.Continuation] = [:]
        var progress: [UUID: ExpansionProgress] = [:]
    }

    private let script = Mutex(Script())

    var cancelled: [URL] { script.withLock { $0.cancelled } }

    /// What each start of an archive's expansion was given, in order.
    var credentials: [URL: [ArchiveCredentials]] { script.withLock { $0.credentials } }

    /// How many times each archive's expansion was started (once, unless something restarted it).
    var starts: [URL: Int] { script.withLock { $0.started } }

    func expand(_ archive: URL, id: UUID, credentials: ArchiveCredentials) async -> ExpansionOutcome {
        let (outcomes, continuation) = AsyncStream<ExpansionOutcome>.makeStream()
        script.withLock {
            $0.credentials[archive, default: []].append(credentials)
            $0.started[archive, default: 0] += 1
            $0.outcomes[archive] = continuation
        }
        // As the live expander: an expansion that isn't running has no progress to read.
        defer { script.withLock { $0.progress[id] = nil } }
        for await outcome in outcomes { return outcome }
        // The stream ends when the task is cancelled: clean up, as the live expander does.
        script.withLock { $0.cancelled.append(archive) }
        return .cancelled
    }

    func progress(of id: UUID) -> ExpansionProgress? {
        script.withLock { $0.progress[id] }
    }

    func setProgress(_ progress: ExpansionProgress, for id: UUID) {
        script.withLock { $0.progress[id] = progress }
    }

    func finish(_ archive: URL, with outcome: ExpansionOutcome) {
        script.withLock { $0.outcomes[archive] }?.yield(outcome)
    }

    /// Whether `archive`'s expansion has started `count` times (waiting up to 5 seconds of real time: this waits for
    /// the store's task to reach the expander, which no clock of the feature's governs).
    func waitForStart(of archive: URL, count: Int = 1) async -> Bool {
        for _ in 0..<5_000 {
            if script.withLock({ $0.started[archive, default: 0] >= count }) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

/// A workspace that records reveals.
final class MockWorkspace: Workspace {
    let revealsExpandedItems: Bool
    private let revealed = Mutex<[URL]>([])

    init(revealsExpandedItems: Bool) {
        self.revealsExpandedItems = revealsExpandedItems
    }

    var revealedURLs: [URL] { revealed.withLock { $0 } }

    func reveal(_ url: URL) async {
        revealed.withLock { $0.append(url) }
    }
}

extension UUID {
    /// The incrementing generator's `n`th UUID.
    init(_ n: Int) {
        self.init(uuidString: String(format: "00000000-0000-0000-0000-%012x", n))!
    }
}

extension LocalizedStringResource {
    /// The text in English, whatever the machine's locale.
    var english: String {
        var resource = self
        resource.locale = Locale(identifier: "en_US")
        return String(localized: resource)
    }
}
