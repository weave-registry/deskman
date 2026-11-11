import Testing
import DeskmanPorts
import DeskmanUseCases

// The user, 2026-10-12: "you keep moving my windows around, we have a layout already of 1 over 2,
// 3 middle, 4 over 5. These are organized to maximize the content and focus area; we should only
// auto arrange around these boundaries." Smart Arrange invented its own columns until now.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1410))
private let z = ZoneGenerator.snapZones(on: wide)          // 0: 1, 1: 2, 2: 3, 3: 4, 4: 5
private func union(_ a: Rect, _ b: Rect) -> Rect { Rect(x: a.x, y: a.y, width: a.width, height: b.maxY - a.y) }
private let leftColumn = union(z[0], z[1]), rightColumn = union(z[3], z[4])

private func win(_ id: String, _ app: String, _ frame: Rect = Rect(x: 600, y: 300, width: 800, height: 600)) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: id, frame: frame, isMinimized: false)
}

private func frame(_ r: GridPlanner.Result, _ id: String) -> Rect? { r.placements.first { $0.window.id == WindowID(id) }?.frame }

@Suite struct GridTests {
    @Test func everyPlaceIsAZoneOrAWholeSideColumn() {
        let allowed = z + [leftColumn, rightColumn]
        for n in 1...8 {
            let ws = (0..<n).map { win("w\($0)", $0 == 2 ? "Firefox" : "App\($0)") }
            let r = GridPlanner.plan(ws, on: wide, kept: [])
            for p in r.placements { #expect(allowed.contains(p.frame), "\(n): \(p.window.id.raw) at \(p.frame)") }
            #expect(r.placements.count + r.leftAlone.count == n)
            #expect(r.placements.count <= 5)
        }
    }

    @Test func fiveWindowsFillTheGridWithTheBrowserInTheMiddle() {
        let ws = [win("a", "iTerm2"), win("b", "Slack"), win("f", "Firefox"), win("c", "Mail"), win("d", "Notes")]
        let r = GridPlanner.plan(ws, on: wide, kept: [])
        #expect(frame(r, "f") == z[2])
        #expect(frame(r, "a") == z[0] && frame(r, "b") == z[3] && frame(r, "c") == z[1] && frame(r, "d") == z[4])
    }

    @Test func aLoneWindowInASideColumnGetsItsFullHeight() {
        let r = GridPlanner.plan([win("a", "iTerm2"), win("f", "Firefox"), win("b", "Slack")], on: wide, kept: [])
        #expect(frame(r, "f") == z[2])
        #expect(frame(r, "a") == leftColumn && frame(r, "b") == rightColumn)
    }

    @Test func aWindowAlreadyInAZoneStaysThere() {
        // Ranked first, but already sitting in zone 5: it is not moved.
        let r = GridPlanner.plan([win("a", "iTerm2", z[4]), win("f", "Firefox"), win("b", "Slack"), win("c", "Mail")],
                                 on: wide, kept: [])
        #expect(frame(r, "a") == z[4])
        #expect(frame(r, "f") == z[2])
    }

    @Test func aKeptWindowBlocksItsZone() {
        let r = GridPlanner.plan([win("a", "iTerm2"), win("f", "Firefox"), win("b", "Slack")], on: wide, kept: [z[0]])
        #expect(r.placements.allSatisfy { ($0.frame.intersection(z[0])?.area ?? 0) < 1 })
        #expect(frame(r, "f") == z[2])
    }

    @Test func aBrowserIsNeverStacked() {
        let r = GridPlanner.plan([win("f1", "Firefox"), win("f2", "Firefox"), win("a", "iTerm2"), win("b", "Slack")],
                                 on: wide, kept: [])
        #expect(frame(r, "f1") == z[2])
        #expect(frame(r, "f2") == leftColumn || frame(r, "f2") == rightColumn)
    }

    @Test func moreThanFiveAreLeftWhereTheyAre() {
        let ws = (0..<7).map { win("w\($0)", "App\($0)") }
        let r = GridPlanner.plan(ws, on: wide, kept: [])
        #expect(r.placements.count == 5)
        #expect(r.leftAlone.map(\.id) == [WindowID("w5"), WindowID("w6")])
    }

    @Test func theNamedWindowTakesTheMiddle() {
        let r = GridPlanner.plan([win("a", "iTerm2"), win("f", "Firefox")], on: wide, kept: [], center: WindowID("a"))
        #expect(frame(r, "a") == z[2])
    }
}

// The user, 2026-11-11: "second is divide the center by 2 and have 1 over 2, 3 next to 4 then 5 over 6".
// Used when there are more windows than the five zones hold.
@Suite struct SixZoneGridTests {
    /// 1 over 2 | 3 | 4 | 5 over 6, quarters, as fractions: the oracle, written from the words.
    static let sixths: [Rect] = [
        Rect(x: 0, y: 0, width: 0.25, height: 0.5), Rect(x: 0, y: 0.5, width: 0.25, height: 0.5),
        Rect(x: 0.25, y: 0, width: 0.25, height: 1), Rect(x: 0.5, y: 0, width: 0.25, height: 1),
        Rect(x: 0.75, y: 0, width: 0.25, height: 0.5), Rect(x: 0.75, y: 0.5, width: 0.25, height: 0.5),
    ]
    static var six: [Rect] {
        let v = wide.visibleFrame
        return sixths.map { Rect(x: v.x + $0.x * v.width, y: v.y + $0.y * v.height, width: $0.width * v.width,
                                 height: $0.height * v.height) }
    }

    @Test func theSecondGridIsOneOverTwoThreeFourFiveOverSix() {
        let zones = ZoneGenerator.snapZones(on: wide, shape: .six)
        #expect(zones.count == 6)
        for (a, b) in zip(zones, Self.six) {
            #expect(abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 && abs(a.width - b.width) < 0.5
                    && abs(a.height - b.height) < 0.5, "\(a) is not \(b)")
        }
    }

    @Test func fiveWindowsOrFewerKeepTheFirstGrid() {
        for n in 0...5 { #expect(GridPlanner.shape(windows: n, on: wide, learned: nil) == nil) }
    }

    @Test func sixOrMoreTakeTheSecond() {
        for n in 6...9 { #expect(GridPlanner.shape(windows: n, on: wide, learned: nil) == .six) }
    }

    @Test func aLearnedGridWins() {
        #expect(GridPlanner.shape(windows: 8, on: wide, learned: GridShape(rows: [1, 1, 1])) == GridShape(rows: [1, 1, 1]))
    }

    @Test func aDisplayTooNarrowForFourColumnsKeepsTheFirst() {
        // 2,560 pt: a quarter is 640, under the 700 pt minimum.
        let narrow = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 2560, height: 1410))
        #expect(GridPlanner.shape(windows: 7, on: narrow, learned: nil) == nil)
    }

    @Test func sixWindowsFillSixZonesTheBrowserIn3TheNextIn4() {
        let ws = [win("f", "Firefox"), win("a", "iTerm2"), win("b", "Slack"), win("c", "Mail"),
                  win("d", "Notes"), win("e", "Music")]
        let r = GridPlanner.plan(ws, on: wide, kept: [], shape: .six)
        let zones = ZoneGenerator.snapZones(on: wide, shape: .six)
        #expect(r.leftAlone.isEmpty)
        #expect(Set(r.placements.map { "\($0.frame)" }) == Set(zones.map { "\($0)" }))
        #expect(frame(r, "f") == zones[2])
        #expect(frame(r, "a") == zones[3])
    }
}

@MainActor @Suite struct SixZoneArrangeTests {
    @Test func smartArrangeWithSixWindowsUsesTheSecondGrid() {
        let ws = (0..<6).map { i in
            WindowSnapshot(id: WindowID("w\(i)"), app: "App\(i)", title: "w\(i)",
                           frame: Rect(x: 100 + Double(i) * 50, y: 100, width: 800, height: 600), isMinimized: false)
        }
        let control = FakeWindowControl(windows: ws, displays: [wide], frontmost: WindowID("w0"))
        let arranger = SmartArranger(control: control, history: nil)
        #expect(WindowService(control: control, arranger: arranger).smartArrange(biggest: nil).succeeded)
        let zones = ZoneGenerator.snapZones(on: wide, shape: .six)
        #expect(Set(control.frames.map { "\($0.1)" }) == Set(zones.map { "\($0)" }), "\(control.frames)")
    }

    @Test func smartArrangeWithFiveKeepsTheFirstGrid() {
        let ws = (0..<5).map { i in
            WindowSnapshot(id: WindowID("w\(i)"), app: "App\(i)", title: "w\(i)",
                           frame: Rect(x: 100 + Double(i) * 50, y: 100, width: 800, height: 600), isMinimized: false)
        }
        let control = FakeWindowControl(windows: ws, displays: [wide], frontmost: WindowID("w0"))
        let arranger = SmartArranger(control: control, history: nil)
        #expect(WindowService(control: control, arranger: arranger).smartArrange(biggest: nil).succeeded)
        #expect(Set(control.frames.map { "\($0.1)" }) == Set(z.map { "\($0)" }), "\(control.frames)")
    }
}
