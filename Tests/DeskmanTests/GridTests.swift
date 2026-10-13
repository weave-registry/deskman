import Testing
import DeskmanPorts

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
