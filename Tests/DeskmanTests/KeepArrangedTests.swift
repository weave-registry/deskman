import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2610121130: Keep Arranged — Smart Arrange runs each time the desktop's windows change.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1410))

private func win(_ id: String, _ app: String, x: Double = 100, minimized: Bool = false) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "", frame: Rect(x: x, y: 100, width: 800, height: 600),
                   isMinimized: minimized)
}

@MainActor @Suite struct KeepArrangedTests {
    let clock = FakeClock()

    func make(_ windows: [WindowSnapshot], on: Bool = true, floating: [String] = [])
        -> (ActivityService, FakeWindowControl, InMemoryPreferenceStore) {
        let control = FakeWindowControl(windows: windows, displays: [wide], frontmost: windows.first?.id)
        let store = InMemoryPreferenceStore(Preferences(floatingApps: floating, keepArranged: on))
        let settings = Settings(store: store, control: control)
        let service = ActivityService(control: control, store: InMemoryActivityStore(), clock: clock,
                                      arranger: SmartArranger(control: control, history: nil, settings: settings),
                                      settings: settings)
        return (service, control, store)
    }

    @Test func pausingLearningDoesNotStopKeepArranged() {
        // Two separate switches (menu review, 2026-10-12): "Learn how I arrange windows" off
        // silently stopped Keep Arranged.
        let (service, _, _) = make([win("a", "Xcode")])
        service.isPaused = true
        #expect(service.keepArrangedDue())
    }

    @Test func offNeverArranges() {
        let (service, control, _) = make([win("a", "Xcode")], on: false)
        #expect(!service.keepArrangedDue())
        control.windowList.append(win("b", "Notes"))
        clock.t = 10
        #expect(!service.keepArrangedDue())
    }

    @Test func turningItOnArrangesOnceAtOnce() {
        let (service, _, store) = make([win("a", "Xcode")], on: false)
        #expect(service.setKeepArranged(true).succeeded)
        #expect(store.saved?.keepArranged == true)
        #expect(service.keepArrangedDue())
        _ = service.smartArrange()
        #expect(!service.keepArrangedDue())
    }

    @Test func aNewWindowArrangesOnceItHasSettled() {
        let (service, control, _) = make([win("a", "Xcode")])
        #expect(service.keepArrangedDue()); _ = service.smartArrange()
        control.windowList.append(win("b", "Notes", x: 900))
        clock.t = 1
        #expect(!service.keepArrangedDue())             // just changed: wait
        clock.t = 2
        #expect(!service.keepArrangedDue())             // 1 s: not yet
        clock.t = 2.6
        #expect(service.keepArrangedDue())              // 1.6 s the same: now
        _ = service.smartArrange()
        clock.t = 10
        #expect(!service.keepArrangedDue())
    }

    @Test func aBurstOfChangesArrangesOnce() {
        let (service, control, _) = make([win("a", "Xcode")])
        _ = service.keepArrangedDue(); _ = service.smartArrange()
        control.windowList.append(win("b", "Notes", x: 900)); clock.t = 1
        _ = service.keepArrangedDue()
        control.windowList.append(win("c", "Mail", x: 1900)); clock.t = 2
        #expect(!service.keepArrangedDue())             // changed again: the wait starts over
        clock.t = 3
        #expect(!service.keepArrangedDue())
        clock.t = 3.6
        #expect(service.keepArrangedDue())
    }

    @Test func movingOrResizingIsNotAChange() {
        let (service, control, _) = make([win("a", "Xcode"), win("b", "Notes", x: 900)])
        _ = service.keepArrangedDue(); _ = service.smartArrange()
        control.windowList = [win("a", "Xcode", x: 2000), win("b", "Notes", x: 900)]
        clock.t = 5
        #expect(!service.keepArrangedDue())
    }

    @Test func minimizingOneIsAChange() {
        let (service, control, _) = make([win("a", "Xcode"), win("b", "Notes", x: 900)])
        _ = service.keepArrangedDue(); _ = service.smartArrange()
        control.windowList = [win("a", "Xcode"), win("b", "Notes", x: 900, minimized: true)]
        clock.t = 1; _ = service.keepArrangedDue()
        clock.t = 3
        #expect(service.keepArrangedDue())
    }

    @Test func aFloatingAppOpeningIsNotAChange() {
        let (service, control, _) = make([win("a", "Xcode")], floating: ["Calculator"])
        _ = service.keepArrangedDue(); _ = service.smartArrange()
        control.windowList.append(win("c", "Calculator", x: 900))
        clock.t = 1; _ = service.keepArrangedDue()
        clock.t = 5
        #expect(!service.keepArrangedDue())
    }

    @Test func aFailedArrangeIsNotRetriedEverySecond() {
        let (service, _, _) = make([])
        #expect(service.keepArrangedDue())
        #expect(!service.smartArrange().succeeded)      // nothing to arrange
        clock.t = 5
        #expect(!service.keepArrangedDue())
    }

    @Test func whatSmartArrangeParkedIsTheNewBaseline() {
        // Smart Arrange minimized an idle window: that is not a change to arrange again for.
        let (service, control, _) = make([win("a", "Xcode"), win("b", "Notes", x: 900)])
        _ = service.keepArrangedDue()
        _ = service.smartArrange()
        control.windowList = [win("a", "Xcode"), win("b", "Notes", x: 900, minimized: true)]
        service.keepArrangedSettled()
        clock.t = 5
        #expect(!service.keepArrangedDue())
    }

    @Test func aWindowYouBringBackIsNeverMinimizedAgain() {
        // 2026-10-12, "whats app keeps minimizing": Keep Arranged parked WhatsApp as idle; brought
        // back, it changed the set, and the next arrange parked it again.
        let control = FakeWindowControl(windows: [win("x", "Xcode"), win("w", "WhatsApp", x: 900)],
                                        displays: [wide], frontmost: WindowID("x"))
        let store = InMemoryPreferenceStore(Preferences(keepArranged: true))
        let settings = Settings(store: store, control: control)
        let focus = FocusTracker(clock: clock)
        for t in stride(from: 0.0, through: 600, by: 5) { clock.t = t; focus.record(app: "Xcode") }  // WhatsApp idle
        let service = ActivityService(control: control, store: InMemoryActivityStore(), clock: clock,
                                      arranger: SmartArranger(control: control, history: nil, focus: focus, settings: settings),
                                      settings: settings)
        #expect(service.keepArrangedDue()); _ = service.smartArrange()
        // The person minimizes it (Deskman no longer does, 2026-10-12).
        control.windowList = [win("x", "Xcode"), win("w", "WhatsApp", x: 900, minimized: true)]
        service.keepArrangedSettled()
        // The person brings it back.
        control.windowList = [win("x", "Xcode"), win("w", "WhatsApp", x: 900)]
        clock.t += 1; _ = service.keepArrangedDue()
        clock.t += 2
        #expect(service.keepArrangedDue())
        let before = control.actions.count
        _ = service.smartArrange()
        #expect(!control.actions.dropFirst(before).contains { $0 == (.minimize, WindowID("w")) })
    }

    @Test func keepArrangedNeverMinimizesAWindowForBeingInactive() {
        // 2026-10-12, "problems with whatsapp and zoom": both are watched, not typed into, so they
        // were never in front and counted as inactive. Each change Keep Arranged saw minimized them.
        let control = FakeWindowControl(windows: [win("s", "Slack"), win("z", "WhatsApp", x: 900)],
                                        displays: [wide], frontmost: WindowID("s"))
        let store = InMemoryPreferenceStore(Preferences(keepArranged: true))
        let settings = Settings(store: store, control: control)
        let focus = FocusTracker(clock: clock)
        for t in stride(from: 0.0, through: 600, by: 5) { clock.t = t; focus.record(app: "Slack") }  // WhatsApp never in front
        let service = ActivityService(control: control, store: InMemoryActivityStore(), clock: clock,
                                      arranger: SmartArranger(control: control, history: nil, focus: focus, settings: settings),
                                      settings: settings)
        #expect(service.keepArrangedDue())
        _ = service.smartArrange(automatic: true)
        control.windowList.append(win("m", "Mail", x: 1800))     // something else changes
        clock.t += 1; _ = service.keepArrangedDue()
        clock.t += 2
        #expect(service.keepArrangedDue())
        _ = service.smartArrange(automatic: true)
        #expect(!control.actions.contains { $0.0 == .minimize })
        // Asked for, Smart Arrange does not either: Deskman minimizes nothing (2026-10-12).
        _ = service.smartArrange()
        #expect(!control.actions.contains { $0.0 == .minimize })
    }

    // The user, 2026-10-12: "if a window is active it should never be modified, otherwise the user can
    // get dizzy ... if there is a better arrangement wait for that window to not be active anymore".
    @Test func keepArrangedNeverMovesTheActiveWindow() {
        let a = win("a", "Xcode", x: 2000)          // in front, not where a plan would put it
        let (service, control, _) = make([a, win("b", "Notes", x: 0), win("c", "Mail", x: 4000)])
        control.frontmost = WindowID("a")
        #expect(service.keepArrangedDue())
        _ = service.smartArrange(automatic: true)
        #expect(!control.frames.contains { $0.0 == WindowID("a") }, "the active window moved")
        for (id, f) in control.frames {
            #expect((f.intersection(a.frame)?.area ?? 0) < 1, "\(id.raw) was put over the active window")
        }
        #expect(!control.actions.contains { $0.1 == WindowID("a") })
    }

    @Test func theBetterArrangementWaitsUntilTheWindowIsNoLongerActive() {
        let (service, control, _) = make([win("a", "Xcode", x: 2000), win("b", "Notes", x: 0), win("c", "Mail", x: 4000)])
        control.frontmost = WindowID("a")
        _ = service.keepArrangedDue(); _ = service.smartArrange(automatic: true)
        clock.t = 5
        #expect(!service.keepArrangedDue())                 // still active: wait
        #expect(service.keepArrangedState.contains("active"))
        control.frontmost = WindowID("b")                   // the person moves on
        clock.t = 6
        #expect(service.keepArrangedDue())
        _ = service.smartArrange(automatic: true)
        #expect(control.frames.contains { $0.0 == WindowID("a") }, "a never got its place")
    }

    @Test func aClickStillMovesTheActiveWindow() {
        let (service, control, _) = make([win("a", "Xcode", x: 2000), win("b", "Notes", x: 0), win("c", "Mail", x: 4000)])
        control.frontmost = WindowID("a")
        _ = service.smartArrange()
        #expect(control.frames.contains { $0.0 == WindowID("a") })
    }
}
