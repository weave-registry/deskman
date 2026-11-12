import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2611121000: resting a drag on a taken zone splits it by the dragged window's shape.
// Expected frames below are worked out by hand from the ADR, not from the code.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1380))
/// The ultrawide's center snap zone.
private let center = Rect(x: 1280, y: 30, width: 2560, height: 1380)

private func win(_ id: String, _ app: String, _ frame: Rect) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "", frame: frame, isMinimized: false)
}

@Suite struct ZoneSplitTests {
    @Test func aTallWindowSplitsTheZoneSideBySide() {
        let s = ZoneSplit.split(center, for: Rect(x: 0, y: 0, width: 800, height: 1300), at: Point(x: 1500, y: 700))
        #expect(s?.dragged == Rect(x: 1280, y: 30, width: 800, height: 1380))
        #expect(s?.other == Rect(x: 2080, y: 30, width: 1760, height: 1380))
    }

    @Test func theMouseSideGetsTheDraggedWindow() {
        let s = ZoneSplit.split(center, for: Rect(x: 0, y: 0, width: 800, height: 1300), at: Point(x: 3500, y: 700))
        #expect(s?.dragged == Rect(x: 3040, y: 30, width: 800, height: 1380))
        #expect(s?.other == Rect(x: 1280, y: 30, width: 1760, height: 1380))
    }

    @Test func aWideWindowStacks() {
        let s = ZoneSplit.split(center, for: Rect(x: 0, y: 0, width: 2400, height: 700), at: Point(x: 2000, y: 1200))
        #expect(s?.dragged == Rect(x: 1280, y: 710, width: 2560, height: 700))
        #expect(s?.other == Rect(x: 1280, y: 30, width: 2560, height: 680))
    }

    @Test func neitherPieceIsEverTooSmall() {
        // A 300-wide window would leave a sliver: its piece grows to the minimum.
        let s = ZoneSplit.split(center, for: Rect(x: 0, y: 0, width: 300, height: 1300), at: Point(x: 1500, y: 700))
        #expect(s?.dragged.width == 700)
        // A window wider than the zone leaves the other piece the minimum.
        let big = ZoneSplit.split(center, for: Rect(x: 0, y: 0, width: 3000, height: 2000), at: Point(x: 1500, y: 700))
        #expect(big.map { min($0.dragged.width, $0.other.width) >= 700 && min($0.dragged.height, $0.other.height) >= 400 }
                == true)
    }

    @Test func aZoneTooSmallToSplitIsNotSplit() {
        // A side zone of the ultrawide: 1280 × 690 halves to under 700 wide or under 400 high.
        let side = Rect(x: 0, y: 30, width: 1280, height: 690)
        #expect(ZoneSplit.split(side, for: Rect(x: 0, y: 0, width: 800, height: 1300), at: Point(x: 100, y: 100)) == nil)
    }

    @Test func thePiecesFillTheZoneWithoutOverlap() {
        for (w, h) in [(800.0, 1300.0), (2400.0, 700.0), (1200.0, 1200.0), (5000.0, 300.0)] {
            for p in [Point(x: 1300, y: 40), Point(x: 3800, y: 1400)] {
                guard let s = ZoneSplit.split(center, for: Rect(x: 0, y: 0, width: w, height: h), at: p) else { continue }
                #expect(s.dragged.intersection(s.other) == nil)
                #expect(abs(s.dragged.area + s.other.area - center.area) < 0.5)
                #expect(center.contains(s.dragged) && center.contains(s.other))
                // The dragged piece is on the mouse's side of the zone's center.
                let sideBySide = s.dragged.height == center.height
                let mouse = sideBySide ? p.x - center.midX : p.y - center.midY
                let piece = sideBySide ? s.dragged.midX - center.midX : s.dragged.midY - center.midY
                #expect(mouse * piece > 0)
            }
        }
    }
}

@MainActor @Suite struct SplitDragTests {
    let tall = Rect(x: 100, y: 40, width: 800, height: 1300)
    let moved = Rect(x: 1400, y: 40, width: 800, height: 1300)

    /// "w" is dragged; "a" sits in the center zone.
    func make(occupied: Bool = true) -> (SnapService, FakeWindowControl) {
        var list = [win("w", "Warp", tall)]
        if occupied { list.append(win("a", "Notes", center)) }
        let fake = FakeWindowControl(windows: list, displays: [wide])
        let snap = SnapService(control: fake, intents: nil)
        snap.beginDrag(at: Point(x: 200, y: 50))
        fake.freshFrames[WindowID("w")] = moved
        #expect(snap.confirmDrag())
        return (snap, fake)
    }

    @Test func restingOnATakenZoneSplitsItOnDrop() {
        let (snap, fake) = make()
        let p = Point(x: 1500, y: 700)
        let split = snap.dragRested(at: p)
        #expect(split?.dragged == Rect(x: 1280, y: 30, width: 800, height: 1380))
        #expect(snap.dragSplit(at: p) == split)
        #expect(snap.endDrag(at: p, bypass: false)?.succeeded == true)
        let placed = Dictionary(fake.frames.map { ($0.0, $0.1) }, uniquingKeysWith: { _, b in b })
        #expect(placed[WindowID("w")] == Rect(x: 1280, y: 30, width: 800, height: 1380))
        #expect(placed[WindowID("a")] == Rect(x: 2080, y: 30, width: 1760, height: 1380))
    }

    @Test func anEmptyZoneIsNotSplit() {
        let (snap, fake) = make(occupied: false)
        let p = Point(x: 1500, y: 700)
        #expect(snap.dragRested(at: p) == nil)
        _ = snap.endDrag(at: p, bypass: false)
        #expect(fake.frames.map(\.1) == [center])
    }

    @Test func dropWithoutRestingSnapsAsBefore() {
        let (snap, fake) = make()
        _ = snap.endDrag(at: Point(x: 1500, y: 700), bypass: false)
        #expect(fake.frames.map(\.0) == [WindowID("w")])
        #expect(fake.frames.map(\.1) == [center])
    }

    @Test func theSplitFollowsTheMouseInsideTheZone() {
        let (snap, _) = make()
        _ = snap.dragRested(at: Point(x: 1500, y: 700))
        #expect(snap.dragSplit(at: Point(x: 3500, y: 700))?.dragged == Rect(x: 3040, y: 30, width: 800, height: 1380))
    }

    @Test func leavingTheZoneDisarmsTheSplit() {
        let (snap, fake) = make()
        _ = snap.dragRested(at: Point(x: 1500, y: 700))
        let away = Point(x: 100, y: 1300)
        #expect(snap.dragSplit(at: away) == nil)
        // Back in the zone without a new rest: a plain snap.
        #expect(snap.dragSplit(at: Point(x: 1500, y: 700)) == nil)
        _ = snap.endDrag(at: Point(x: 1500, y: 700), bypass: false)
        #expect(fake.frames.map(\.0) == [WindowID("w")])
    }

    @Test func optionSkipsTheSplitToo() {
        let (snap, fake) = make()
        _ = snap.dragRested(at: Point(x: 1500, y: 700))
        #expect(snap.endDrag(at: Point(x: 1500, y: 700), bypass: true) == nil)
        #expect(fake.frames.isEmpty)
    }

    @Test func theNextDragStartsUnarmed() {
        let (snap, fake) = make()
        _ = snap.dragRested(at: Point(x: 1500, y: 700))
        _ = snap.endDrag(at: Point(x: 1500, y: 700), bypass: true)
        fake.freshFrames = [:]
        snap.beginDrag(at: Point(x: 200, y: 50))
        fake.freshFrames[WindowID("w")] = moved
        _ = snap.confirmDrag()
        #expect(snap.dragSplit(at: Point(x: 1500, y: 700)) == nil)
    }
}
