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
    func displays() -> [Display] { displayList }
    func frontmostWindowID() -> WindowID? { frontmost }

    func setFrame(_ frame: Rect, of id: WindowID) throws {
        if let setFrameError { throw setFrameError }
        frames.append((id, frame))
    }

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
