import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2611111000: the mouse resting on a stacked window gives it at least three quarters of the
// stack's height; the windows above and below stay visible; leaving puts them back.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1380))
// Two windows stacked in the left column, 690 pt each, no gap: 30…720, 720…1410.
private let top = Rect(x: 0, y: 30, width: 1280, height: 690)
private let bottom = Rect(x: 0, y: 720, width: 1280, height: 690)
private let center = Rect(x: 1280, y: 30, width: 2560, height: 1380)

private func win(_ id: String, _ app: String, _ frame: Rect) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "", frame: frame, isMinimized: false)
}

private let pair = [win("t", "Warp", top), win("b", "Safari", bottom), win("c", "Xcode", center)]

@Suite struct HoverExpandTests {
    @Test func twoStackedWindowsAreAStackTopToBottom() {
        let s = HoverExpand.stack(around: WindowID("b"), in: pair)
        #expect(s?.map(\.id.raw) == ["t", "b"])
    }

    @Test func aWindowBesideIsNotStacked() {
        #expect(HoverExpand.stack(around: WindowID("c"), in: pair) == nil)
    }

    @Test func windowsInDifferentColumnsAreNotAStack() {
        // Half the width of the one below: not the same column.
        let narrow = win("n", "Notes", Rect(x: 0, y: 30, width: 640, height: 690))
        #expect(HoverExpand.stack(around: WindowID("n"), in: [narrow, win("b", "Safari", bottom)]) == nil)
    }

    @Test func overlappingWindowsAreNotAStack() {
        let over = win("o", "Notes", Rect(x: 0, y: 400, width: 1280, height: 690))
        #expect(HoverExpand.stack(around: WindowID("o"), in: [over, win("t", "Warp", top)]) == nil)
    }

    @Test func windowsFarApartAreNotAStack() {
        let low = win("l", "Notes", Rect(x: 0, y: 1000, width: 1280, height: 300))
        let high = win("h", "Warp", Rect(x: 0, y: 30, width: 1280, height: 300))
        #expect(HoverExpand.stack(around: WindowID("h"), in: [high, low]) == nil)
    }

    @Test func theHoveredWindowGetsThreeQuartersAndTheOtherStaysVisible() throws {
        let l = try #require(HoverExpand.layout([top, bottom], expanding: 1))
        let room = 1380.0
        #expect(l[1].height >= 0.75 * room - 0.5)
        #expect(l[0].height >= HoverExpand.minimumHeight)
        // Inside the same edges, not overlapping, same columns.
        #expect(l[0].minY == top.minY && l[1].maxY == bottom.maxY)
        #expect(l[0].maxY <= l[1].minY + 0.001)
        #expect(l.allSatisfy { $0.x == 0 && $0.width == 1280 })
    }

    @Test func gapsBetweenWindowsAreKept() throws {
        let a = Rect(x: 0, y: 30, width: 1280, height: 680)
        let b = Rect(x: 0, y: 720, width: 1280, height: 690)
        let l = try #require(HoverExpand.layout([a, b], expanding: 0))
        #expect(abs((l[1].minY - l[0].maxY) - 10) < 0.001)
        #expect(l[1].maxY == b.maxY)
    }

    @Test func threeStackedLeaveEachOtherAtLeastTheMinimum() throws {
        let h = 460.0
        let frames = (0..<3).map { Rect(x: 0, y: 30 + Double($0) * h, width: 1280, height: h) }
        let l = try #require(HoverExpand.layout(frames, expanding: 1))
        #expect(l[1].height >= 0.75 * 1380 - 0.5)
        #expect(l[0].height >= HoverExpand.minimumHeight && l[2].height >= HoverExpand.minimumHeight)
        #expect(l[2].maxY == frames[2].maxY)
    }

    @Test func aShortStackGivesWhatItCanAndNeverSqueezesBelowTheMinimum() throws {
        // 400 pt in all: three quarters would leave 100, under the minimum.
        let a = Rect(x: 0, y: 30, width: 1280, height: 200), b = Rect(x: 0, y: 230, width: 1280, height: 200)
        let l = try #require(HoverExpand.layout([a, b], expanding: 0))
        #expect(l[1].height == HoverExpand.minimumHeight)
        #expect(l[0].height == 400 - HoverExpand.minimumHeight)
    }

    @Test func aWindowThatAlreadyHasTheRoomIsLeftAlone() {
        let big = Rect(x: 0, y: 30, width: 1280, height: 1100), small = Rect(x: 0, y: 1130, width: 1280, height: 280)
        #expect(HoverExpand.layout([big, small], expanding: 0) == nil)
    }
}

@MainActor @Suite struct HoverServiceTests {
    let clock = FakeClock()

    func make(_ windows: [WindowSnapshot] = pair, preferences: Preferences = Preferences())
        -> (HoverService, FakeWindowControl, IntentLog) {
        let log = IntentLog(clock: clock)
        let fake = FakeWindowControl(windows: windows, displays: [wide], frontmost: WindowID("t"))
        let control = IntentRecordingControl(fake, log: log)
        let settings = Settings(store: InMemoryPreferenceStore(preferences), control: fake)
        return (HoverService(control: control, intents: log, settings: settings), fake, log)
    }

    func last(_ fake: FakeWindowControl, _ id: String) -> Rect? { fake.frames.last { $0.0.raw == id }?.1 }

    @Test func restingOnTheLowerWindowExpandsItAndKeepsTheUpperVisible() throws {
        let (hover, fake, _) = make()
        hover.pointerRested(at: Point(x: 600, y: 1000))
        let b = try #require(last(fake, "b")), t = try #require(last(fake, "t"))
        #expect(b.height >= 0.75 * 1380 - 0.5)
        #expect(t.height >= HoverExpand.minimumHeight && t.minY == top.minY)
        #expect(t.maxY <= b.minY + 0.001 && b.maxY == bottom.maxY)
    }

    @Test func leavingTheColumnPutsBothBack() {
        let (hover, fake, _) = make()
        hover.pointerRested(at: Point(x: 600, y: 1000))
        hover.pointerMoved(to: Point(x: 2000, y: 500))
        #expect(last(fake, "b") == bottom)
        #expect(last(fake, "t") == top)
    }

    @Test func movingWithinTheExpandedWindowChangesNothing() {
        let (hover, fake, _) = make()
        hover.pointerRested(at: Point(x: 600, y: 1000))
        let n = fake.frames.count
        hover.pointerMoved(to: Point(x: 700, y: 1100))
        hover.pointerRested(at: Point(x: 700, y: 1100))
        #expect(fake.frames.count == n)
    }

    @Test func restingOnTheOtherWindowMovesTheRoomToIt() throws {
        let (hover, fake, _) = make()
        hover.pointerRested(at: Point(x: 600, y: 1000))
        // The upper window is now a strip at the top; rest on it.
        hover.pointerRested(at: Point(x: 600, y: 60))
        let t = try #require(last(fake, "t")), b = try #require(last(fake, "b"))
        #expect(t.height >= 0.75 * 1380 - 0.5)
        #expect(b.height >= HoverExpand.minimumHeight && b.maxY == bottom.maxY)
        hover.pointerMoved(to: Point(x: 2000, y: 500))
        #expect(last(fake, "t") == top && last(fake, "b") == bottom)
    }

    @Test func aWindowAloneIsNeverExpanded() {
        let (hover, fake, _) = make()
        hover.pointerRested(at: Point(x: 2000, y: 500))
        #expect(fake.frames.isEmpty)
    }

    @Test func nothingExpandsWithTheButtonDown() {
        let (hover, fake, _) = make()
        hover.pointerPressed()
        hover.pointerRested(at: Point(x: 600, y: 1000))
        #expect(fake.frames.isEmpty)
        hover.pointerReleased()
        hover.pointerRested(at: Point(x: 600, y: 1000))
        #expect(!fake.frames.isEmpty)
    }

    @Test func offInTheMenuMeansOff() {
        let (hover, fake, _) = make(preferences: Preferences(hoverExpand: false))
        hover.pointerRested(at: Point(x: 600, y: 1000))
        #expect(fake.frames.isEmpty)
    }

    @Test func anAppDeskmanLeavesAloneIsNotExpandedOrSqueezed() {
        let (hover, fake, _) = make(preferences: Preferences(floatingApps: ["Warp"]))
        hover.pointerRested(at: Point(x: 600, y: 1000))
        #expect(fake.frames.isEmpty)
    }

    @Test func nothingExpandsDuringAMeeting() {
        let meeting = WindowSnapshot(id: WindowID("z"), app: "zoom.us", title: "Zoom Meeting",
                                     frame: Rect(x: 4000, y: 30, width: 800, height: 600), isMinimized: false)
        let (hover, fake, _) = make(pair + [meeting])
        hover.pointerRested(at: Point(x: 600, y: 1000))
        #expect(fake.frames.isEmpty)
    }

    @Test func aWindowSomeoneElseMovedMeanwhileIsNotPutBack() throws {
        let (hover, fake, _) = make()
        hover.pointerRested(at: Point(x: 600, y: 1000))
        // The person drags the lower window elsewhere while it is expanded.
        let dragged = Rect(x: 3000, y: 200, width: 1280, height: 1000)
        fake.freshFrames[WindowID("b")] = dragged
        let n = fake.frames.filter { $0.0.raw == "b" }.count
        hover.pointerMoved(to: Point(x: 2000, y: 500))
        #expect(fake.frames.filter { $0.0.raw == "b" }.count == n)
        #expect(last(fake, "t") == top)
    }

    @Test func aStaleListDoesNotTakeTheExpandedFramesForTheResting() throws {
        // windows() can be a second old (ADR-2610121200): just after a collapse it still shows the
        // expanded frames. Expanding again must start from where the windows really are.
        let (hover, fake, _) = make()
        hover.pointerRested(at: Point(x: 600, y: 1000))
        let expandedB = try #require(last(fake, "b")), expandedT = try #require(last(fake, "t"))
        hover.pointerMoved(to: Point(x: 2000, y: 500))
        fake.windowList = [win("t", "Warp", expandedT), win("b", "Safari", expandedB), win("c", "Xcode", center)]
        hover.pointerRested(at: Point(x: 600, y: 1000))
        hover.pointerMoved(to: Point(x: 2000, y: 500))
        #expect(last(fake, "b") == bottom && last(fake, "t") == top)
    }

    @Test func hoverMovesPinNothingAndUnpinNothing() {
        let (hover, fake, log) = make()
        log.observe(fake.windows())
        log.personPlaced(WindowID("t"))   // the person snapped the upper window there
        hover.pointerRested(at: Point(x: 600, y: 1000))
        let expanded = fake.windowList.map { w in
            WindowSnapshot(id: w.id, app: w.app, title: "", frame: fake.frame(of: w.id)!, isMinimized: false)
        }
        clock.t = 2
        log.observe(expanded)
        hover.pointerMoved(to: Point(x: 2000, y: 500))
        clock.t = 4
        log.observe(fake.windows())
        #expect(log.pinned() == [WindowID("t")])
        #expect(log.placedByDeskman(fake.windows()).isEmpty)
    }

    @Test func whileExpandedTheLearnerSeesTheRestingFrames() {
        let (hover, fake, log) = make()
        hover.pointerRested(at: Point(x: 600, y: 1000))
        let expanded = fake.windowList.map { w in
            WindowSnapshot(id: w.id, app: w.app, title: "", frame: fake.frame(of: w.id)!, isMinimized: false)
        }
        log.observe(expanded)
        #expect(log.atRest(expanded).map(\.frame) == [top, bottom, center])
    }

    @Test func aHandMoveOfAnExpandedWindowIsStillAnIntent() {
        let (hover, fake, log) = make()
        log.observe(fake.windows())
        hover.pointerRested(at: Point(x: 600, y: 1000))
        clock.t = 30
        log.observe([win("t", "Warp", top), win("b", "Safari", Rect(x: 3000, y: 200, width: 1280, height: 1000)),
                     win("c", "Xcode", center)])
        #expect(log.pinned() == [WindowID("b")])
    }
}
