import Foundation
import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2610131157. The user, 2026-10-13: "we need to learn new zone configurations then optimize them
// for equal distribution". Learn from the person's moves only; keep the shape, make the zones equal.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1410))
private let day = 86_400.0

/// The person's grid today: 1 over 2 | 3 | 4 over 5, as fractions.
private let standard: [Rect] = [
    Rect(x: 0, y: 0, width: 0.25, height: 0.5), Rect(x: 0, y: 0.5, width: 0.25, height: 0.5),
    Rect(x: 0.25, y: 0, width: 0.5, height: 1),
    Rect(x: 0.75, y: 0, width: 0.25, height: 0.5), Rect(x: 0.75, y: 0.5, width: 0.25, height: 0.5),
]
private let thirds: [Rect] = (0..<3).map { Rect(x: Double($0) / 3, y: 0, width: 1.0 / 3, height: 1) }

/// One settled record with a window at each place, all placed by the person unless `byPerson` is false.
/// Each window is its own app: one app in one place counts once.
private func record(_ time: Double, _ places: [Rect], tag: String, on display: Display = wide,
                    byPerson: Bool = true) -> DeskSnapshot {
    let windows = places.enumerated().map { i, r in
        WindowSnapshot(id: WindowID("\(tag)\(i)"), app: "App\(i)-\(tag)", title: "\(tag) \(i)",
                       frame: Placement(display: display.index, rect: r).frame(on: display), isMinimized: false)
    }
    return DeskSnapshot(time: time, windows: windows, displays: [display], focusedApp: nil,
                        placedByPerson: byPerson ? Set(windows.map(\.id)) : [])
}

/// Three different windows at each place: three placements, enough for an edge to count.
private func moves(_ time: Double, _ places: [Rect], on display: Display = wide) -> [DeskSnapshot] {
    (0..<3).map { record(time + Double($0), places, tag: "t\(Int(time))-\($0)-", on: display) }
}

@Suite struct GridLearnerTests {
    @Test func nothingIsLearnedFromPlacesDeskmanMade() {
        let history = (0..<30).map { record(Double($0), standard, tag: "d\($0)-", byPerson: false) }
        #expect(GridLearner.learn(from: history, on: wide, now: 40) == nil)
    }

    @Test func fewerThanFiveOfYourMovesTeachNothing() {
        let history = [record(0, Array(standard.prefix(4)), tag: "a")]
        #expect(GridLearner.learn(from: history, on: wide, now: 1) == nil)
    }

    @Test func yourGridIsLearnedAsAShape() {
        let learned = GridLearner.learn(from: moves(0, standard), on: wide, now: 10)
        #expect(learned?.shape == GridShape(rows: [2, 1, 2]))
        #expect(learned?.placements == 15)
    }

    @Test func oneWindowInOnePlaceCountsOnce() {
        // The same window, settled in the same place, in 40 records: one placement, not 40.
        let same = (0..<40).map { record(Double($0), [standard[2]], tag: "x") }
        #expect(GridLearner.learn(from: same, on: wide, now: 50) == nil)
    }

    @Test func movesOlderThanTwoWeeksAreForgotten() {
        let old = moves(0, standard)
        #expect(GridLearner.learn(from: old, on: wide, now: 15 * day) == nil)
        #expect(GridLearner.learn(from: old, on: wide, now: 13 * day) != nil)
    }

    @Test func theNewerPlaceWinsSoAnEqualGridDoesNotInventColumns() {
        // Learned 25|50|25, made equal 33|33|33, then the person's moves land on the thirds. Both
        // sets of edges are in the history; counting both would make five columns.
        let history = moves(1 * day, standard) + moves(9 * day, thirds)
        let learned = GridLearner.learn(from: history, on: wide, now: 10 * day)
        #expect(learned?.shape.rows.count == 3, "\(String(describing: learned))")
    }

    @Test func aShapeTooFineForTheDisplayLosesItsWeakestEdges() {
        let laptop = Display(index: 0, visibleFrame: Rect(x: 0, y: 25, width: 1440, height: 875))
        // Halves that overlap, each 720 pt wide, so each counts: their edges are at 25%, 50% and 75%.
        let halves = (0..<3).map { Rect(x: Double($0) / 4, y: 0, width: 0.5, height: 1) }
        let learned = GridLearner.learn(from: moves(0, halves, on: laptop), on: laptop, now: 10)
        #expect(learned?.shape.rows.count == 2)
        for z in ZoneGenerator.snapZones(on: laptop, shape: learned?.shape) {
            #expect(z.width >= ZonePlanner.minimumWidth && z.height >= ZonePlanner.minimumHeight, "\(z)")
        }
    }

    @Test func aWindowSmallerThanAZoneTeachesNothing() {
        // 2026-10-13: Plaud, a 320 × 196 pt widget, counted as one of the person's five moves.
        let widgets = (0..<6).map { Rect(x: 0.9, y: Double($0) / 10, width: 0.06, height: 0.1) }
        #expect(GridLearner.placements(in: moves(0, widgets), on: wide, now: 10) == 0)
        #expect(GridLearner.learn(from: moves(0, standard + widgets), on: wide, now: 10)?.placements == 15)
    }

    @Test func anAppDeskmanLeavesAloneTeachesNothing() {
        // `record` names the apps App0-…App4-…, by place; App2 holds the middle.
        let history = moves(0, standard)
        let middle = { (app: String) in app.hasPrefix("App2-") }
        #expect(GridLearner.learn(from: history, on: wide, now: 10, ignoring: middle)?.placements == 12)
        #expect(GridLearner.placements(in: history, on: wide, now: 10, ignoring: middle) == 12)
    }

    @Test func aTitleChangeIsNotASecondMove() {
        // 2026-10-13: Slack went from "glenturner (DM)" to "Threads" in one place and counted twice.
        let place = Rect(x: 0.75, y: 0.5, width: 0.25, height: 0.5)
        let history = [placed(0, "Slack", "glenturner (DM)", place), placed(1, "Slack", "Threads", place)]
        #expect(GridLearner.placements(in: history, on: wide, now: 2) == 1)
    }

    /// The person's five moves of 2026-10-13, 12:18–12:50, as Deskman recorded them.
    static let today: [DeskSnapshot] = [
        placed(0, "Zoom", "Zoom Meeting", Rect(x: 0.75, y: 0.5, width: 0.25, height: 0.567)),
        placed(1, "iTerm2", "tuios", Rect(x: 0.75, y: 0, width: 0.25, height: 0.5)),
        placed(2, "Zoom", "Zoom Meeting", Rect(x: 0.25, y: 0, width: 0.5, height: 1)),
        placed(3, "Slack", "glenturner (DM)", Rect(x: 0.75, y: 0.5, width: 0.25, height: 0.5)),
        placed(4, "Slack", "Threads", Rect(x: 0.75, y: 0.5, width: 0.25, height: 0.5)),
    ]

    @Test func todaysMovesAreFourNotFive() {
        #expect(GridLearner.placements(in: Self.today, on: wide, now: 10) == 4)
        #expect(GridLearner.learn(from: Self.today, on: wide, now: 10) == nil)
    }

    @Test func movesOnOneSideKeepTheEdgesOfTheOther() {
        // Today's moves are all on the middle and the right. The left edge, at 25%, was never moved:
        // it stays, and the grid keeps its shape (it learned two columns, 2026-10-13).
        let history = Self.today + [placed(5, "Mail", "Inbox", Rect(x: 0.75, y: 0, width: 0.25, height: 1))]
        #expect(GridLearner.learn(from: history, on: wide, now: 10)?.shape == GridShape(rows: [2, 1, 2]))
    }

    @Test func aFullHeightMoveAcrossASplitRemovesIt() {
        // Full-height windows in each third: the side columns are no longer split.
        let learned = GridLearner.learn(from: moves(0, thirds), on: wide, now: 10)
        #expect(learned?.shape == GridShape(rows: [1, 1, 1]), "\(String(describing: learned))")
    }

    @Test func anotherDisplaysMovesTeachThisOneNothing() {
        let second = Display(index: 1, visibleFrame: Rect(x: 5120, y: 0, width: 2560, height: 1440))
        #expect(GridLearner.learn(from: moves(0, standard, on: second), on: wide, now: 10) == nil)
    }
}

/// One window the person placed, in a record of its own.
private func placed(_ time: Double, _ app: String, _ title: String, _ rect: Rect) -> DeskSnapshot {
    let w = WindowSnapshot(id: WindowID("\(app)\(time)"), app: app, title: title,
                           frame: Placement(display: 0, rect: rect).frame(on: wide), isMinimized: false)
    return DeskSnapshot(time: time, windows: [w], displays: [wide], focusedApp: nil, placedByPerson: [w.id])
}

@Suite struct EqualGridTests {
    @Test func equalZonesTileTheScreenForEveryShape() {
        let v = wide.visibleFrame
        for columns in 1...5 {
            for rows in [[1], [2], [3], [1, 2], [2, 1, 3]] {
                let shape = GridShape(rows: (0..<columns).map { rows[$0 % rows.count] })
                let z = ZoneGenerator.snapZones(on: wide, shape: shape)
                #expect(z.count == shape.rows.reduce(0, +), "\(shape)")
                // Equal widths everywhere, equal heights within a column.
                #expect(z.allSatisfy { abs($0.width - v.width / Double(columns)) < 1e-6 }, "\(shape)")
                for x in Set(z.map(\.x)) {
                    let column = z.filter { $0.x == x }
                    #expect(column.allSatisfy { abs($0.height - v.height / Double(column.count)) < 1e-6 }, "\(shape)")
                }
                // No gap, no overlap: the areas add up to the screen, and no two zones share area.
                #expect(abs(z.map(\.area).reduce(0, +) - v.area) < 1e-3, "\(shape)")
                for i in z.indices { for j in z.indices where i < j {
                    #expect((z[i].intersection(z[j])?.area ?? 0) < 1e-6, "\(shape): \(z[i]) \(z[j])")
                } }
                #expect(z.allSatisfy { $0.x >= v.x - 1e-6 && $0.maxX <= v.maxX + 1e-6
                    && $0.y >= v.y - 1e-6 && $0.maxY <= v.maxY + 1e-6 }, "\(shape)")
            }
        }
    }

    @Test func yourShapeMadeEqual() {
        let z = ZoneGenerator.snapZones(on: wide, shape: GridShape(rows: [2, 1, 2]))
        #expect(z.count == 5)
        #expect(abs(z[2].x - 5120.0 / 3) < 1e-6 && abs(z[2].width - 5120.0 / 3) < 1e-6)   // zone 3, the middle
        #expect(z[0].x == 0 && z[1].x == 0 && z[0].y < z[1].y)                          // 1 over 2
        #expect(abs(z[0].height - 705) < 1e-6)
    }

    @Test func withoutAShapeTheStandardGridStays() {
        #expect(ZoneGenerator.snapZones(on: wide, shape: nil) == ZoneGenerator.snapZones(on: wide))
    }

    @Test func theMiddleOfAnEqualGridIsTheCenterColumn() {
        let shape = GridShape(rows: [2, 1, 2])
        let z = ZoneGenerator.snapZones(on: wide, shape: shape)
        let start = Rect(x: 600, y: 300, width: 800, height: 600)
        let ws = [WindowSnapshot(id: WindowID("a"), app: "iTerm2", title: "a", frame: start, isMinimized: false),
                  WindowSnapshot(id: WindowID("f"), app: "Firefox", title: "f", frame: start, isMinimized: false)]
        let r = GridPlanner.plan(ws, on: wide, kept: [], shape: shape)
        #expect(r.placements.first { $0.window.id == WindowID("f") }?.frame == z[2])
        #expect(GridPlanner.zoneLabel(of: z[2], on: wide, shape: shape) == "zone 3")
    }
}

@Suite struct RecordsSayWhoPlacedTests {
    @Test func aRecordSaysWhichWindowsThePersonPlaced() {
        let a = WindowSnapshot(id: WindowID("a"), app: "Notes", title: "", frame: Rect(x: 0, y: 30, width: 1280, height: 705),
                               isMinimized: false)
        let b = WindowSnapshot(id: WindowID("b"), app: "Mail", title: "", frame: Rect(x: 1280, y: 30, width: 2560, height: 1410),
                               isMinimized: false)
        let s = DeskSnapshot(time: 0, windows: [a, b], displays: [wide], focusedApp: nil, placedByPerson: [a.id])
        #expect(s.windows.map(\.byPerson) == [true, nil])
    }

    @Test func aRecordWrittenBeforeTheFlagStillReads() throws {
        let line = #"{"time":1,"displayCount":1,"windows":[{"app":"Firefox","title":"t","isMinimized":false,"#
            + #""placement":{"display":0,"rect":{"x":0.25,"y":0,"width":0.5,"height":1}}}]}"#
        let s = try JSONDecoder().decode(DeskSnapshot.self, from: Data(line.utf8))
        #expect(s.windows.first?.byPerson == nil)
        #expect(s.windows.first?.app == "Firefox")
    }

    @Test func theFlagSurvivesTheRoundTrip() throws {
        let s = record(0, [standard[0]], tag: "r")
        let back = try JSONDecoder().decode(DeskSnapshot.self, from: JSONEncoder().encode(s))
        #expect(back.windows.first?.byPerson == true)
    }
}

@MainActor @Suite struct LearnedGridTests {
    func learned(_ history: [DeskSnapshot], log: InMemoryDecisionLog = InMemoryDecisionLog()) -> LearnedGrid {
        let store = InMemoryActivityStore()
        for s in history { try? store.append(s) }
        let clock = FakeClock()
        clock.t = 10 * day
        let grid = LearnedGrid(history: store, clock: clock)
        grid.decisions = log
        return grid
    }

    @Test func theSnapKeysUseTheLearnedGrid() {
        let grid = learned(moves(9 * day, standard))
        let start = Rect(x: 600, y: 300, width: 800, height: 600)
        let fake = FakeWindowControl(windows: [WindowSnapshot(id: WindowID("w"), app: "Warp", title: "", frame: start,
                                                              isMinimized: false)],
                                     displays: [wide], frontmost: WindowID("w"))
        let snap = SnapService(control: fake, intents: nil, grid: grid)
        #expect(snap.snapFrontmost(toZone: 3).succeeded)
        #expect(fake.frames.map(\.1) == [ZoneGenerator.snapZones(on: wide, shape: GridShape(rows: [2, 1, 2]))[2]])
    }

    @Test func withNothingLearnedTheSnapKeysKeepTheStandardGrid() {
        let grid = learned([])
        #expect(grid.zones(on: wide) == ZoneGenerator.snapZones(on: wide))
    }

    @Test func aNewShapeIsLoggedOnceAndMovesNothing() {
        let log = InMemoryDecisionLog()
        let grid = learned(moves(9 * day, standard), log: log)
        grid.relearn(displays: [wide])
        grid.relearn(displays: [wide])
        let lines = log.lines.filter { $0.contains("grid") }
        #expect(lines.count == 1, "\(log.lines)")
        #expect(lines.first?.contains("15") == true, "\(lines)")
    }

    @Test func untilItIsLearnedTheMapCountsYourMoves() {
        let grid = learned([record(9 * day, Array(standard.prefix(2)), tag: "p"),
                            record(9 * day, Array(standard.prefix(2)), tag: "q", byPerson: false)])
        #expect(grid.describe(on: wide).contains("(2 so far)"), "\(grid.describe(on: wide))")
    }

    @Test func whatDeskmanKnowsSaysWhichGridIsInUse() {
        let store = InMemoryActivityStore()
        for s in moves(9 * day, standard) { try? store.append(s) }
        let clock = FakeClock()
        clock.t = 10 * day
        let control = FakeWindowControl(windows: [], displays: [wide])
        let grid = LearnedGrid(history: store, clock: clock)
        let service = ActivityService(control: control, store: store, clock: clock, grid: grid)
        let section = service.desktopMap().knowledge.sections.first { $0.title == "Your grid" }
        #expect(section?.lines.first?.contains("15 of your moves") == true, "\(String(describing: section))")
    }
}
