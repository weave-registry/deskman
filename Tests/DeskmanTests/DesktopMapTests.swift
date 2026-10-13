import Testing
import DeskmanPorts
import DeskmanUseCases

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1380))
private let side = Display(index: 1, visibleFrame: Rect(x: 5120, y: 0, width: 1920, height: 1080))

private func win(_ id: String, _ app: String, x: Double = 100, here: Bool = true, minimized: Bool = false) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "", frame: Rect(x: x, y: 100, width: 800, height: 600),
                   isMinimized: minimized, desktop: here ? 1 : 2, isOnCurrentDesktop: here)
}

@MainActor @Suite struct DesktopMapTests {
    let store = InMemoryActivityStore()

    func map(_ windows: [WindowSnapshot], displays: [Display] = [wide]) -> DesktopMap {
        let control = FakeWindowControl(windows: windows, displays: displays, frontmost: windows.first?.id)
        let service = ActivityService(control: control, store: store, clock: FakeClock(),
                                      arranger: SmartArranger(control: control, history: store))
        return service.desktopMap()
    }

    @Test func itShowsTheVisibleWindowsAndCountsTheRest() {
        let m = map([win("a", "A"), win("b", "B"), win("m", "M", minimized: true), win("z", "Z", here: false)])
        #expect(m.windows.map(\.app) == ["A", "B"])
        #expect(m.hiddenCount == 2)
        #expect(m.otherDesktops.map(\.app) == ["Z"])
        #expect(m.otherDesktopNumbers == [2])
    }

    @Test func itPreviewsSmartArrangeWithoutMovingAnything() {
        let windows = [win("a", "A"), win("b", "B"), win("c", "C")]
        let control = FakeWindowControl(windows: windows, displays: [wide], frontmost: WindowID("a"))
        let service = ActivityService(control: control, store: store, clock: FakeClock(),
                                      arranger: SmartArranger(control: control, history: store))
        let m = service.desktopMap()
        #expect(m.plan.count == 3)
        #expect(m.plan.filter(\.isMain).map(\.app) == ["A"])
        #expect(control.frames.isEmpty && control.actions.isEmpty)
    }

    @Test func habitsAreDrawnOnTheirDisplay() {
        let left = Layout.leftHalf.frame(in: wide.visibleFrame)
        for i in 0..<3 {
            try? store.append(DeskSnapshot(time: Double(i), windows: [
                WindowSnapshot(id: WindowID("t"), app: "Terminal", title: "", frame: left, isMinimized: false),
            ], displays: [wide], focusedApp: nil))
        }
        let m = map([win("a", "A")])
        #expect(m.habits.count == 1)
        #expect(m.habits[0].frame == left)
        #expect(m.habits[0].habit.isLearned)
    }

    @Test func aHabitOnANegativeDisplayIsSkippedNotACrash() throws {
        // A damaged trust file: `display` decodes as any Int, with no check.
        var ledger = TrustLedger()
        ledger.confirm(app: "Terminal", placement: Placement(display: -1, rect: Rect(x: 0, y: 0, width: 0.5, height: 1)))
        try store.save(ledger)
        #expect(map([win("a", "A")]).habits.isEmpty)
    }

    @Test func appsThatShareAPlaceShareABox() {
        let left = Layout.leftHalf.frame(in: wide.visibleFrame)
        for i in 0..<3 {
            try? store.append(DeskSnapshot(time: Double(i), windows: [
                WindowSnapshot(id: WindowID("t"), app: "Terminal", title: "", frame: left, isMinimized: false),
            ], displays: [wide], focusedApp: nil))
        }
        try? store.append(DeskSnapshot(time: 9, windows: [
            WindowSnapshot(id: WindowID("w"), app: "Warp", title: "", frame: left, isMinimized: false),
        ], displays: [wide], focusedApp: nil))
        let groups = map([]).habitGroups
        #expect(groups.count == 1)
        #expect(Set(groups[0].habits.map(\.app)) == ["Terminal", "Warp"])
    }

    @Test func theBoundsHoldEveryDisplay() {
        let m = map([], displays: [wide, side])
        #expect(m.bounds == Rect(x: 0, y: 0, width: 7040, height: 1410))
    }
}
