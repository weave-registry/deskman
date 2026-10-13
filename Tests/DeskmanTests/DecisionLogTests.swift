import Testing
import DeskmanPorts
import DeskmanUseCases

// The user, 2026-10-12: "i need a log to know why you are making certain decisions". Until now the
// only record was the system log's keep-arranged trace, read for the user by hand.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1410))

private func win(_ id: String, _ app: String, _ title: String = "", x: Double = 100) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: title, frame: Rect(x: x, y: 100, width: 800, height: 600),
                   isMinimized: false)
}

@MainActor @Suite struct DecisionLogTests {
    let clock = FakeClock()

    func make(_ windows: [WindowSnapshot], front: String, keep: Bool = true)
        -> (ActivityService, FakeWindowControl, InMemoryDecisionLog, IntentLog) {
        let control = FakeWindowControl(windows: windows, displays: [wide], frontmost: WindowID(front))
        let log = InMemoryDecisionLog()
        let intents = IntentLog(clock: clock)
        intents.decisions = log
        let focus = FocusTracker(clock: clock)
        for t in 0..<24 { clock.t = Double(t * 5); focus.record(app: "Firefox", window: WindowID("f")) }
        let settings = Settings(store: InMemoryPreferenceStore(Preferences(keepArranged: keep)), control: control)
        let recording = IntentRecordingControl(control, log: intents)
        let arranger = SmartArranger(control: recording, history: nil, focus: focus, intents: intents, settings: settings)
        let service = ActivityService(control: recording, store: InMemoryActivityStore(), clock: clock, arranger: arranger,
                                      focus: focus, intents: intents, settings: settings, decisions: log)
        return (service, control, log, intents)
    }

    @Test func anArrangeSaysWhatStartedItAndWhyEachWindowWentWhere() {
        let (service, _, log, _) = make([win("f", "Firefox", "Docs"), win("t", "iTerm2", "shell", x: 2000),
                                         win("m", "Mail", "Inbox", x: 4000)], front: "t")
        _ = service.smartArrange()
        let text = log.text
        #expect(text.contains("Smart Arrange: you asked"))
        #expect(text.contains("Ranked: Firefox"))                 // the most used first
        #expect(text.contains("2 min"))                           // 24 samples of 5 s
        #expect(text.contains("Layout:"))                         // who made it
        #expect(text.contains("Smart Arrange"))                   // each move is recorded by the gateway (GatewayTests)
        #expect(text.contains("Result:"))
    }

    @Test func keepArrangedSaysWhyItWaitsOrActs() {
        let (service, _, log, _) = make([win("f", "Firefox", "Docs"), win("t", "iTerm2", "shell", x: 2000),
                                         win("m", "Mail", "Inbox", x: 4000)], front: "t")
        _ = service.keepArrangedDue()
        _ = service.smartArrange(automatic: true)
        #expect(log.text.contains("Keep Arranged: arranging"))
        #expect(log.text.contains("Kept iTerm2 in place: you are working in it") || log.text.contains("Layout:"))
    }

    @Test func aMeetingPauseIsWrittenOnceNotEverySecond() {
        let (service, _, log, _) = make([win("z", "zoom.us", "Zoom Meeting"), win("t", "iTerm2", "shell", x: 2000)], front: "t")
        for t in 0..<10 { clock.t = 1000 + Double(t); _ = service.keepArrangedDue() }
        #expect(log.lines.filter { $0.contains("meeting") }.count == 1)
    }

    @Test func aPinSaysHowTheWindowMoved() {
        let (_, _, log, intents) = make([win("t", "iTerm2", "shell")], front: "t")
        intents.observe([win("t", "iTerm2", "shell")])
        intents.observe([win("t", "iTerm2", "shell", x: 310)])
        #expect(log.text.contains("Pinned iTerm2"))
        #expect(log.text.contains("210"))
    }
}
