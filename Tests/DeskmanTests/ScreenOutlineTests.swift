import Testing
import DeskmanPorts
import DeskmanUseCases

// The desktop map draws outlines on the real screen, as Hammerspoon's zone grid did
// (ADR-2610101523, amendment 2026-10-12). The map decides what; the view only paints.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1380))
private let side = Display(index: 1, visibleFrame: Rect(x: 5120, y: 0, width: 1920, height: 1080))
private let screen = Display(index: 0, visibleFrame: Rect(x: 0, y: 25, width: 1440, height: 875))

private func win(_ id: String, _ app: String, _ frame: Rect = Rect(x: 100, y: 100, width: 800, height: 600)) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "", frame: frame, isMinimized: false)
}

@MainActor @Suite struct ScreenOutlineTests {
    let store = InMemoryActivityStore()

    func map(_ windows: [WindowSnapshot], displays: [Display]) -> DesktopMap {
        let control = FakeWindowControl(windows: windows, displays: displays, frontmost: windows.first?.id)
        return ActivityService(control: control, store: store, clock: FakeClock(),
                               arranger: SmartArranger(control: control, history: store)).desktopMap()
    }

    @Test func nowOutlinesTheNumberedSnapZonesOfEveryDisplay() {
        let m = map([win("a", "A")], displays: [wide, side])
        let o = m.outlines(.now)
        let expected = ZoneGenerator.snapZones(on: wide) + ZoneGenerator.snapZones(on: side)
        #expect(o.map(\.frame) == expected)
        #expect(o.allSatisfy { $0.kind == .zone })
        // Numbered per display, as the hotkeys count them.
        let n = ZoneGenerator.snapZones(on: wide).count
        #expect(o.prefix(n).map(\.label) == (1...n).map(String.init))
        #expect(o[n].label == "1")
    }

    @Test func smartArrangeOutlinesThePlanInTheMapsOrder() {
        let m = map([win("a", "A"), win("b", "B"), win("c", "C")], displays: [wide])
        let o = m.outlines(.arrange)
        #expect(o.map(\.frame) == m.plan.map(\.frame))
        #expect(o.first?.kind == .main && o.first?.label == "★ A")
        #expect(o.dropFirst().allSatisfy { $0.kind == .zone })
    }

    @Test func learnedOutlinesAreGreenOrRedInTheMapsOrder() {
        let left = Layout.leftHalf.frame(in: screen.visibleFrame)
        let right = Layout.rightThird.frame(in: screen.visibleFrame)
        let learned = (0..<3).map { DeskSnapshot(time: Double($0), windows: [win("t", "Terminal", left)],
                                                 displays: [screen], focusedApp: nil) }
        let learning = [DeskSnapshot(time: 9, windows: [win("n", "Notes", right)], displays: [screen], focusedApp: nil)]
        for s in learned + learning { try? store.append(s) }
        let m = map([], displays: [screen])
        let o = m.outlines(.learned)
        #expect(o.map(\.frame) == m.habitGroups.map(\.frame))
        #expect(o.map(\.kind) == [.learning, .learned])
        #expect(o.map(\.label) == ["Notes", "Terminal"])
    }

    @Test func nothingToShowIsNoOutlines() {
        let m = map([], displays: [wide])
        #expect(m.outlines(.arrange).isEmpty)
        #expect(m.outlines(.learned).isEmpty)
    }
}
