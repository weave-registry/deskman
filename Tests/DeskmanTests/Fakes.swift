import DeskmanPorts

// Deps pattern (hexa ADR-014): fakes implement the PORTS. They never redefine
// the subject under test — WindowService and DeskmanService are the real types.

struct FakeError: Error, CustomStringConvertible {
    let description: String
}

@MainActor final class FakeWindowControl: WindowControl {
    var windowList: [WindowSnapshot]
    var displayList: [Display]
    var frontmost: WindowID?
    var trusted = true
    var setFrameError: FakeError?
    /// Windows that refuse to move, as Firefox did before ADR-2610101523's fix.
    var stuck: Set<WindowID> = []

    private(set) var frames: [(WindowID, Rect)] = []
    private(set) var actions: [(WindowAction, WindowID)] = []
    private(set) var launched: [String] = []
    private(set) var trustRequests = 0

    init(windows: [WindowSnapshot], displays: [Display], frontmost: WindowID? = nil) {
        self.windowList = windows
        self.displayList = displays
        self.frontmost = frontmost
    }

    func windows() -> [WindowSnapshot] { windowList }
    /// Frames as they are now, when `windowList` is a second old, as the background read can be.
    var freshFrames: [WindowID: Rect] = [:]
    /// As a real window: where it was last moved, else where it was.
    func frame(of id: WindowID) -> Rect? {
        freshFrames[id] ?? frames.last { $0.0 == id }?.1 ?? windowList.first { $0.id == id }?.frame
    }
    func displays() -> [Display] { displayList }
    func frontmostWindowID() -> WindowID? { frontmost }

    func setFrame(_ frame: Rect, of id: WindowID) throws {
        if let setFrameError { throw setFrameError }
        if stuck.contains(id) { throw FakeError(description: "it stayed at 1754,37") }
        // A window that goes nowhere it is put, and says nothing (a Zoom meeting, 2026-10-12).
        if immovable.contains(id) { return }
        // An app with a minimum size takes the place but keeps its own width (Stream Deck, 2026-10-12).
        if let minimum = minimumWidth[id], let i = windowList.firstIndex(where: { $0.id == id }) {
            let landed = Rect(x: frame.x, y: frame.y, width: max(frame.width, minimum), height: frame.height)
            let w = windowList[i]
            windowList[i] = WindowSnapshot(id: w.id, app: w.app, title: w.title, frame: landed, isMinimized: w.isMinimized)
            frames.append((id, landed))
            return
        }
        frames.append((id, frame))
    }
    /// Windows that stay where they are, though the move "succeeds".
    var immovable: Set<WindowID> = []
    /// Windows whose app will not go narrower than this.
    var minimumWidth: [WindowID: Double] = [:]

    func perform(_ action: WindowAction, on id: WindowID) throws {
        actions.append((action, id))
    }

    func launch(app: String) throws {
        if app == "Nope" { throw FakeError(description: "no app named Nope") }
        launched.append(app)
    }

    var isTrusted: Bool { trusted }
    func requestTrust() { trustRequests += 1 }
}

@MainActor final class FakeAssistant: Assistant {
    var availability: AssistantAvailability = .available
    /// Each call to `reply` takes the next result.
    var script: [Result<AssistantReply, AssistantError>] = []
    private(set) var prompts: [String] = []
    private(set) var resets = 0

    func reply(to text: String) async throws -> AssistantReply {
        prompts.append(text)
        guard !script.isEmpty else { return AssistantReply(text: "ok", actions: []) }
        return try script.removeFirst().get()
    }

    func reset() { resets += 1 }
    func prewarm() {}
}

@MainActor final class FakeClock: TimeSource {
    var t: Double = 0
    func now() -> Double { t }
}

struct DiskFull: Error {}

@MainActor final class InMemoryActivityStore: ActivityStore {
    private(set) var records: [DeskSnapshot] = []
    private(set) var savedLedger = TrustLedger()
    /// How many of the next `append` calls throw, as a full disk would.
    var failingAppends = 0
    /// How many of the next `save` calls throw.
    var failingSaves = 0

    func append(_ snapshot: DeskSnapshot) throws {
        if failingAppends > 0 {
            failingAppends -= 1
            throw DiskFull()
        }
        records.append(snapshot)
    }
    func snapshots() -> [DeskSnapshot] { records }
    func ledger() -> TrustLedger { savedLedger }
    func save(_ ledger: TrustLedger) throws {
        if failingSaves > 0 {
            failingSaves -= 1
            throw DiskFull()
        }
        savedLedger = ledger
    }
    func eraseAll() throws {
        records = []
        savedLedger = TrustLedger()
    }
}


@MainActor final class FakeTerminalActivity: TerminalActivity {
    var current: [TerminalJob]
    private(set) var reads = 0

    init(jobs: [TerminalJob]) { current = jobs }

    func jobs() -> [TerminalJob] {
        reads += 1
        return current
    }
}

@MainActor final class InMemoryPreferenceStore: PreferenceStore {
    var saved: Preferences?
    /// Thrown by `load`, as a damaged file would.
    var loadError: FakeError?
    /// How many of the next `save` calls throw.
    var failingSaves = 0
    private(set) var saves = 0

    init(_ saved: Preferences? = nil) { self.saved = saved }

    func load() throws -> Preferences {
        if let loadError { throw loadError }
        return saved ?? Preferences()
    }
    func save(_ preferences: Preferences) throws {
        if failingSaves > 0 {
            failingSaves -= 1
            throw DiskFull()
        }
        saves += 1
        saved = preferences
    }
}

/// The decision log, kept in memory for tests.
@MainActor final class InMemoryDecisionLog: DecisionLog {
    private(set) var lines: [String] = []
    func record(_ line: String) { lines.append(line) }
    var text: String { lines.joined(separator: "\n") }
}
