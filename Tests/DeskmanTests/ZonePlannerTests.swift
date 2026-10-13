import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2610101501. The layouts are the user's Hammerspoon layouts, as of 2026-10-10.

private func z(_ x: Double, _ w: Double, _ y: Double, _ h: Double, _ label: String) -> Zone {
    Zone(label: label, rect: Rect(x: x, y: y, width: w, height: h))
}

private let standard = ZoneLayout(name: "Default", zones: [
    z(0, 0.25, 0, 0.5, "1 Top"), z(0, 0.25, 0.5, 0.5, "1 Bottom"), z(0.25, 0.5, 0, 1, "2"),
    z(0.75, 0.25, 0, 0.5, "3 Top"), z(0.75, 0.25, 0.5, 0.5, "3 Bottom"),
])
private let coding = ZoneLayout(name: "Coding", zones: [
    z(0, 1.0 / 3, 0, 1, "Editor"), z(1.0 / 3, 1.0 / 3, 0, 1, "Editor"), z(2.0 / 3, 1.0 / 3, 0, 1, "Browser"),
])
private let demo = ZoneLayout(name: "Demo", zones: [
    z(0, 0.25, 0, 0.5, "Notes 1a"), z(0, 0.25, 0.5, 0.5, "Notes 1b"), z(0.25, 0.25, 0, 1, "Notes 2"),
    z(0.5, 0.5, 0, 1, "Main"),
])
private let layouts = [standard, coding, demo]
private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1380))

private func win(_ id: String, _ app: String, x: Double = 100, desktop here: Bool = true,
                 minimized: Bool = false) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "", frame: Rect(x: x, y: 100, width: 800, height: 600),
                   isMinimized: minimized, desktop: here ? 1 : 2, isOnCurrentDesktop: here)
}

private func windows(_ n: Int) -> [WindowSnapshot] {
    (0..<n).map { win("w\($0)", "App\($0)") }
}

@Suite struct ZonePlannerTests {
    func plan(_ w: [WindowSnapshot], named: String? = nil, current: String? = nil) -> ZonePlan? {
        ZonePlanner.plan(windows: w, on: wide, layouts: layouts, named: named, current: current)
    }

    @Test(arguments: [(1, "Demo"), (2, "Demo"), (3, "Coding"), (4, "Demo"), (5, "Default")])
    func theLayoutFitsTheWindowCount(count: Int, expected: String) {
        #expect(plan(windows(count))?.layout.name == expected)
    }

    @Test func aNamedLayoutWins() {
        #expect(plan(windows(3), named: "default")?.layout.name == "Default")
    }

    @Test func anUnknownNamedLayoutIsNoPlan() {
        #expect(plan(windows(3), named: "Gaming") == nil)
    }

    @Test func aTieGoesToTheCurrentHammerspoonLayout() {
        let twin = ZoneLayout(name: "Twin", zones: coding.zones)
        let p = ZonePlanner.plan(windows: windows(3), on: wide, layouts: [coding, twin], named: nil, current: "Twin")
        #expect(p?.layout.name == "Twin")
    }

    @Test func theFirstWindowGetsTheLargestZone() {
        let p = plan(windows(4))!
        #expect(p.layout.name == "Demo")
        let first = p.placements.first { $0.window.id == WindowID("w0") }!
        #expect(first.zone.label == "Main")
        #expect(first.frame == Rect(x: 2560, y: 30, width: 2560, height: 1380))
    }

    @Test func theTopWindowTakesTheCenterAndTheRestMoveLeast() {
        // a is the most active; b sits on the right, c in the middle.
        let w = [win("a", "A", x: 50), win("b", "B", x: 4000), win("c", "C", x: 2100)]
        let p = plan(w)!
        #expect(p.layout.name == "Coding")
        let x = Dictionary(uniqueKeysWithValues: p.placements.map { ($0.window.id.raw, $0.frame.x) })
        #expect(x["a"]! > 1700 && x["a"]! < 1710)   // the center column, straight ahead
        #expect(x["b"]! > 3400)                     // stays right
        #expect(x["c"] == 0)                        // the only column left
    }

    @Test func anUprightDisplayTurnsTheZonesIntoRows() {
        let upright = Display(index: 0, visibleFrame: Rect(x: 0, y: 0, width: 1080, height: 1920))
        let p = ZonePlanner.plan(windows: windows(3), on: upright, layouts: [coding], named: nil, current: nil)!
        #expect(p.placements.allSatisfy { $0.frame.width == 1080 && abs($0.frame.height - 640) < 0.01 })
    }

    @Test func aSmallDisplayAvoidsZonesTooNarrowToWorkIn() {
        // A laptop: Default and Demo have 378-point columns, Coding's thirds are 504: all under 700.
        // Only the zones big enough are used; the other windows go out of the way.
        let laptop = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 1512, height: 915))
        let p = ZonePlanner.plan(windows: windows(4), on: laptop, layouts: layouts, named: nil, current: nil)!
        #expect(!p.placements.isEmpty)
        #expect(p.placements.allSatisfy { $0.frame.width >= ZonePlanner.minimumWidth && $0.frame.height >= ZonePlanner.minimumHeight })
        #expect(p.placements.count + p.unplaced.count == 4)
    }

    @Test func windowsBeyondTheZonesAreTheLowestPriority() {
        let p = plan(windows(7))!
        #expect(p.layout.name == "Default")
        #expect(p.placements.count == 5)
        #expect(p.unplaced.map(\.id.raw) == ["w5", "w6"])
    }

    @Test func zonesCoverTheVisibleFrameWithNoOverlap() {
        for layout in layouts {
            let frames = layout.zones.map { $0.frame(in: wide) }
            let area = frames.reduce(0) { $0 + $1.width * $1.height }
            #expect(abs(area - wide.visibleFrame.width * wide.visibleFrame.height) < 1)
        }
    }

    @Test func noWindowsIsNoPlan() {
        #expect(plan([]) == nil)
    }
}

/// The window that got the largest frame.
private func roomiest(_ frames: [(WindowID, Rect)]) -> WindowID? {
    frames.max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
}

@MainActor @Suite struct SmartArrangeTests {
    let store = InMemoryActivityStore()

    func make(_ w: [WindowSnapshot], focus: FocusTracker? = nil) -> (WindowService, FakeWindowControl) {
        let control = FakeWindowControl(windows: w, displays: [wide], frontmost: w.first?.id)
        return (WindowService(control: control, history: store, focus: focus, launchWait: .zero), control)
    }

    @Test func itArrangesEveryVisibleWindowIntoZones() {
        let (service, control) = make(windows(3))
        let outcome = service.smartArrange(biggest: nil)
        #expect(outcome.succeeded)
        #expect(control.frames.count == 3)
        #expect(outcome.message.contains("Arranged 3 windows"))
    }

    @Test func aWindowThatDidNotMoveIsNamedNotHidden() {
        let (service, control) = make(windows(3))
        control.stuck = [WindowID("w1")]
        let outcome = service.smartArrange(biggest: nil)
        #expect(outcome.succeeded)
        #expect(outcome.message.contains("Could not move: App1: it stayed at 1754,37"))
        #expect(outcome.message.hasPrefix("Arranged 2 windows."))
    }

    @Test func itLeavesMinimizedAndOtherDesktopWindowsAlone() {
        let w = windows(2) + [win("m", "Min", minimized: true), win("a", "Away", desktop: false)]
        let (service, control) = make(w)
        _ = service.smartArrange(biggest: nil)
        #expect(Set(control.frames.map(\.0.raw)) == ["w0", "w1"])
    }

    @Test func theMostFocusedAppInHistoryGetsTheMostRoom() {
        for i in 0..<5 {
            try? store.append(DeskSnapshot(time: Double(i), windows: [], displays: [wide], focusedApp: "App2"))
        }
        let (service, control) = make(windows(4))
        _ = service.smartArrange(biggest: nil)
        #expect(roomiest(control.frames) == WindowID("w2"))
    }

    @Test func aNamedAppGetsTheMostRoom() {
        let (service, control) = make(windows(4))
        _ = service.smartArrange(biggest: "App3")
        #expect(roomiest(control.frames) == WindowID("w3"))
    }

    @Test func theMostActiveAppNowGetsTheMostRoom() {
        let clock = FakeClock()
        let focus = FocusTracker(clock: clock)
        for t in 0..<20 { clock.t = Double(t * 5); focus.record(app: "App1") }
        let (service, control) = make(windows(4), focus: focus)
        _ = service.smartArrange(biggest: nil)
        #expect(roomiest(control.frames) == WindowID("w1"))
    }

    @Test func theMiddleZoneKeepsItsWidthWhateverTheActivity() {
        // The person's grid has fixed boundaries (2026-10-12): activity picks who goes in zone 3,
        // never how wide it is.
        let clock = FakeClock()
        let calm = FocusTracker(clock: clock), busy = FocusTracker(clock: clock)
        for t in 0..<30 {
            clock.t = Double(t * 5)
            calm.record(app: "App\(t % 3)")
            busy.record(app: t % 10 == 0 ? "App1" : "App0")
        }
        let (a, ca) = make(windows(3), focus: calm)
        let (b, cb) = make(windows(3), focus: busy)
        _ = a.smartArrange(biggest: nil)
        _ = b.smartArrange(biggest: nil)
        let wa = ca.frames.map(\.1.width).max()!, wb = cb.frames.map(\.1.width).max()!
        #expect(wb == wa)
    }

    @Test func unusedWindowsAreArrangedNotMinimized() {
        // Five minutes watched: App0 and App1 used, App2 and App3 never. Deskman minimizes nothing (2026-10-12).
        let clock = FakeClock()
        let focus = FocusTracker(clock: clock)
        for t in 0..<70 { clock.t = Double(t * 5); focus.record(app: t % 2 == 0 ? "App0" : "App1") }
        let (service, control) = make(windows(4), focus: focus)
        let outcome = service.smartArrange(biggest: nil)
        #expect(Set(control.frames.map(\.0.raw)) == ["w0", "w1", "w2", "w3"])
        #expect(!control.actions.contains { $0.0 == .minimize })
        #expect(outcome.succeeded)
    }

    @Test func aShortWatchArrangesEveryWindow() {
        let clock = FakeClock()
        let focus = FocusTracker(clock: clock)
        for t in 0..<10 { clock.t = Double(t * 5); focus.record(app: "App0") }
        let (service, control) = make(windows(3), focus: focus)
        _ = service.smartArrange(biggest: nil)
        #expect(control.actions.isEmpty)
        #expect(control.frames.count == 3)
    }

    @Test func activityOlderThanThirtyMinutesIsForgotten() {
        let clock = FakeClock()
        let focus = FocusTracker(clock: clock)
        clock.t = 0; focus.record(app: "Old")
        clock.t = 1900; focus.record(app: "New")
        #expect(focus.activity() == ["New": 1])
    }

    @Test func theActivityPathCanBeUndone() {
        let w = windows(3)
        let control = FakeWindowControl(windows: w, displays: [wide], frontmost: w.first?.id)
        let activity = ActivityService(control: control, store: store, clock: FakeClock(),
                                       arranger: SmartArranger(control: control, history: store))
        #expect(activity.smartArrange().succeeded)
        #expect(activity.undo().succeeded)
        #expect(control.frames.suffix(3).map(\.1).allSatisfy { $0 == Rect(x: 100, y: 100, width: 800, height: 600) })
    }
}
