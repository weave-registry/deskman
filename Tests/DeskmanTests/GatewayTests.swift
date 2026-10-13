import Testing
import DeskmanPorts
import DeskmanUseCases

// The user, 2026-10-12: "build the gateway" — OpenBot's pattern: every action decided before it
// happens and recorded after. Until now Deskman's rules lived in each service, and some leaked.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1410))
private let somewhere = Rect(x: 0, y: 30, width: 1280, height: 705)

private func win(_ id: String, _ app: String, _ title: String = "", x: Double = 100) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: title, frame: Rect(x: x, y: 100, width: 800, height: 600),
                   isMinimized: false)
}

private let calm = GateContext(inMeeting: false, frontmost: WindowID("front"))
private let meeting = GateContext(inMeeting: true, frontmost: WindowID("front"))
private let auto = ActionOrigin.automatic("Keep Arranged")
private let you = ActionOrigin.person("a snap hotkey")

@Suite struct GatewayPolicyTests {
    @Test func onItsOwnDeskmanNeverMinimizesClosesOrHides() {
        for a in [WindowAction.minimize, .close, .hideApp, .fullScreen] {
            #expect(!GatewayPolicy.decide(.act(a), on: win("w", "Slack"), origin: auto, context: calm).allowed, "\(a)")
            #expect(GatewayPolicy.decide(.act(a), on: win("w", "Slack"), origin: you, context: calm).allowed, "\(a)")
        }
    }

    @Test func onItsOwnNothingMovesDuringAMeeting() {
        #expect(!GatewayPolicy.decide(.move(to: somewhere), on: win("w", "Slack"), origin: auto, context: meeting).allowed)
        #expect(!GatewayPolicy.decide(.act(.focus), on: win("w", "Slack"), origin: auto, context: meeting).allowed)
        #expect(GatewayPolicy.decide(.move(to: somewhere), on: win("w", "Slack"), origin: you, context: meeting).allowed)
    }

    @Test func onItsOwnTheWindowYouWorkInIsNeverMoved() {
        let d = GatewayPolicy.decide(.move(to: somewhere), on: win("front", "iTerm2"), origin: auto, context: calm)
        #expect(!d.allowed && d.reason.contains("working in it"))
        #expect(GatewayPolicy.decide(.move(to: somewhere), on: win("front", "iTerm2"), origin: you, context: calm).allowed)
    }

    @Test func onItsOwnAMeetingAppIsNeverTouched() {
        #expect(!GatewayPolicy.decide(.move(to: somewhere), on: win("z", "zoom.us", "Zoom Workplace"), origin: auto, context: calm).allowed)
    }

    @Test func onItsOwnAnUnknownWindowIsLeftAlone() {
        #expect(!GatewayPolicy.decide(.move(to: somewhere), on: nil, origin: auto, context: calm).allowed)
    }

    @Test func ordinaryAutomaticWorkIsAllowed() {
        #expect(GatewayPolicy.decide(.move(to: somewhere), on: win("w", "Slack"), origin: auto, context: calm).allowed)
        #expect(GatewayPolicy.decide(.act(.restore), on: win("w", "Slack"), origin: auto, context: calm).allowed)
        #expect(GatewayPolicy.decide(.act(.focus), on: win("w", "Slack"), origin: auto, context: calm).allowed)
    }
}

@MainActor @Suite struct WindowGatewayTests {
    func make(_ windows: [WindowSnapshot], front: String) -> (WindowGateway, FakeWindowControl, InMemoryDecisionLog) {
        let fake = FakeWindowControl(windows: windows, displays: [wide], frontmost: WindowID(front))
        let log = InMemoryDecisionLog()
        return (WindowGateway(fake, decisions: log), fake, log)
    }

    @Test func withNoOriginGivenTheStrictRulesApply() {
        let (gate, fake, log) = make([win("w", "Slack")], front: "other")
        #expect(throws: GatewayRefusal.self) { try gate.perform(.minimize, on: WindowID("w")) }
        #expect(fake.actions.isEmpty)
        #expect(log.text.contains("Refused") && log.text.contains("minimize"))
    }

    @Test func whatThePersonAsksForIsDoneAndRecorded() throws {
        let (gate, fake, log) = make([win("w", "Slack")], front: "other")
        try gate.acting(for: .person("the assistant")) { try gate.perform(.minimize, on: WindowID("w")) }
        #expect(fake.actions.map(\.0) == [.minimize])
        #expect(log.text.contains("Did") && log.text.contains("the assistant"))
    }

    @Test func everyMoveIsRecordedWithWhoAskedForIt() throws {
        let (gate, fake, log) = make([win("w", "Slack", "general")], front: "other")
        try gate.acting(for: .automatic("Keep Arranged")) { try gate.setFrame(somewhere, of: WindowID("w")) }
        #expect(fake.frames.count == 1)
        #expect(log.text.contains("Slack") && log.text.contains("Keep Arranged"))
    }

    @Test func theOriginEndsWithItsBlock() throws {
        let (gate, _, _) = make([win("w", "Slack")], front: "other")
        try gate.acting(for: .person("Undo")) { }
        #expect(throws: GatewayRefusal.self) { try gate.perform(.close, on: WindowID("w")) }
    }

    @Test func keepArrangedThroughTheGatewayNeverMovesTheActiveWindow() {
        let windows = [win("a", "Xcode", x: 2000), win("b", "Notes", x: 0), win("c", "Mail", x: 4000)]
        let (gate, fake, _) = make(windows, front: "a")
        let settings = Settings(store: InMemoryPreferenceStore(Preferences(keepArranged: true)), control: gate)
        let service = ActivityService(control: gate, store: InMemoryActivityStore(), clock: FakeClock(),
                                      arranger: SmartArranger(control: gate, history: nil, settings: settings), settings: settings)
        _ = service.smartArrange(automatic: true)
        #expect(!fake.frames.contains { $0.0 == WindowID("a") })
        #expect(!fake.actions.contains { $0.0 == .minimize })
    }
}
