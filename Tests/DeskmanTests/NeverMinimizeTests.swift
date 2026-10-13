import Testing
import DeskmanPorts
import DeskmanUseCases

// The user, 2026-10-12: "we should never minimize an app in deskman". Deskman minimized windows
// it called inactive, windows with no room, windows left overlapping, and a bound project's
// other windows when one was minimized.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1410))

private func win(_ id: String, _ app: String, x: Double, minimized: Bool = false) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: id, frame: Rect(x: x, y: 100, width: 800, height: 600),
                   isMinimized: minimized)
}

@MainActor @Suite struct NeverMinimizeTests {
    let clock = FakeClock()

    /// 20 windows: more than fit at 700 pt; most never in front; one refuses to shrink.
    func crowded() -> (ActivityService, FakeWindowControl) {
        let windows = (0..<20).map { win("w\($0)", "App\($0)", x: Double($0) * 200) }
        let control = FakeWindowControl(windows: windows, displays: [wide], frontmost: WindowID("w0"))
        control.minimumWidth[WindowID("w1")] = 3000
        let focus = FocusTracker(clock: clock)
        for t in stride(from: 0.0, through: 900, by: 5) { clock.t = t; focus.record(app: "App0", window: WindowID("w0")) }
        let settings = Settings(store: InMemoryPreferenceStore(Preferences(keepArranged: true)), control: control)
        let service = ActivityService(control: control, store: InMemoryActivityStore(), clock: clock,
                                      arranger: SmartArranger(control: control, history: nil, focus: focus, settings: settings),
                                      settings: settings)
        return (service, control)
    }

    @Test func smartArrangeNeverMinimizes() {
        let (service, control) = crowded()
        let outcome = service.smartArrange()
        #expect(outcome.succeeded)
        #expect(!control.actions.contains { $0.0 == .minimize })
        #expect(outcome.message.contains("No room"))
    }

    @Test func keepArrangedNeverMinimizes() {
        let (service, control) = crowded()
        _ = service.smartArrange(automatic: true)
        #expect(!control.actions.contains { $0.0 == .minimize })
    }

    @Test func theToolNeverMinimizes() {
        let (_, control) = crowded()
        let arranger = SmartArranger(control: control, history: nil)
        _ = WindowService(control: control, arranger: arranger).smartArrange(biggest: nil)
        #expect(!control.actions.contains { $0.0 == .minimize })
    }

    @Test func aBoundWindowMinimizedDoesNotMinimizeItsPartners() {
        let before = [win("a", "iTerm2", x: 0), win("b", "Firefox", x: 900)]
        let after = [win("a", "iTerm2", x: 0, minimized: true), win("b", "Firefox", x: 900)]
        let follows = Bindings.follow(before: before, after: after, frontBefore: nil, frontAfter: nil,
                                      groups: [[WindowID("a"), WindowID("b")]], displays: [wide])
        #expect(follows.isEmpty, "\(follows)")
    }
}
