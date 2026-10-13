import Testing
import DeskmanPorts
import DeskmanUseCases

// The user, 2026-10-12: track focus per window. Deskman knew only that "Firefox" was in front,
// not which of three Firefox windows, so the middle column went to whichever came first.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1410))

private func win(_ id: String, _ app: String, x: Double) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: id, frame: Rect(x: x, y: 100, width: 800, height: 600),
                   isMinimized: false)
}

@MainActor @Suite struct WindowFocusTests {
    let clock = FakeClock()

    @Test func focusIsCountedPerWindow() {
        let focus = FocusTracker(clock: clock)
        focus.record(app: "Firefox", window: WindowID("f1"))
        focus.record(app: "Firefox", window: WindowID("f3"))
        focus.record(app: "Firefox", window: WindowID("f3"))
        #expect(focus.windowActivity() == [WindowID("f1"): 1, WindowID("f3"): 2])
        #expect(focus.activity() == ["Firefox": 3])
    }

    @Test func oldSamplesAreForgottenPerWindowToo() {
        let focus = FocusTracker(clock: clock)
        focus.record(app: "Firefox", window: WindowID("f1"))
        clock.t = FocusTracker.horizon + 1
        focus.record(app: "Firefox", window: WindowID("f2"))
        #expect(focus.windowActivity() == [WindowID("f2"): 1])
    }

    @Test func theBrowserWindowUsedMostGetsTheMiddle() {
        let ws = [win("f1", "Firefox", x: 0), win("f2", "Firefox", x: 900), win("f3", "Firefox", x: 1800),
                  win("t", "iTerm2", x: 2700)]
        let control = FakeWindowControl(windows: ws, displays: [wide], frontmost: WindowID("t"))
        let focus = FocusTracker(clock: clock)
        for i in 0..<10 { clock.t = Double(i); focus.record(app: "Firefox", window: WindowID(i < 8 ? "f3" : "f1")) }
        let arranger = SmartArranger(control: control, history: nil, focus: focus)
        #expect(WindowService(control: control, arranger: arranger).smartArrange(biggest: nil).succeeded)
        let f3 = control.frames.last { $0.0 == WindowID("f3") }?.1 ?? ws[2].frame
        #expect(f3.x <= wide.visibleFrame.midX && wide.visibleFrame.midX <= f3.maxX, "f3 at \(f3)")
    }
}
