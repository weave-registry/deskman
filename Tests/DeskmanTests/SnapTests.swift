import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2610101523 §4: Deskman's snap hotkeys and drag-to-snap replace Hammerspoon's.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1380))
private let start = Rect(x: 600, y: 300, width: 800, height: 600)

private func win(_ id: String, _ app: String, _ frame: Rect = start) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "", frame: frame, isMinimized: false)
}

@Suite struct SnapZoneTests {
    @Test func anUltrawideHasFiveSnapZonesLeftToRight() {
        let z = ZoneGenerator.snapZones(on: wide)
        #expect(z.count == 5)
        #expect(z[0].x == 0 && z[1].x == 0 && z[0].y < z[1].y)          // left top, left bottom
        #expect(z[2].x == 1280 && z[2].width == 2560)                     // center
        #expect(z[3].x == 3840 && z[4].x == 3840 && z[3].y < z[4].y)      // right top, right bottom
    }

    @Test func theZoneUnderAPointIsFound() {
        let z = ZoneGenerator.snapZones(on: wide)
        #expect(ZoneGenerator.zone(at: Point(x: 2000, y: 500), in: z) == 2)
        #expect(ZoneGenerator.zone(at: Point(x: 100, y: 1300), in: z) == 1)
        #expect(ZoneGenerator.zone(at: Point(x: 9000, y: 500), in: z) == nil)
    }
}

@MainActor @Suite struct SnapServiceTests {
    let clock = FakeClock()

    func make(_ windows: [WindowSnapshot], frontmost: String? = "w") -> (SnapService, FakeWindowControl, IntentLog) {
        let log = IntentLog(clock: clock)
        let fake = FakeWindowControl(windows: windows, displays: [wide], frontmost: frontmost.map(WindowID.init))
        let control = IntentRecordingControl(fake, log: log)
        return (SnapService(control: control, intents: log), fake, log)
    }

    @Test func aHotkeyPutsTheFrontWindowInThatZone() {
        let (snap, fake, _) = make([win("w", "Warp")])
        #expect(snap.snapFrontmost(toZone: 3).succeeded)
        #expect(fake.frames.map(\.1) == [ZoneGenerator.snapZones(on: wide)[2]])
    }

    @Test func aSnapIsThePersonsChoice() {
        let (snap, _, log) = make([win("w", "Warp")])
        _ = snap.snapFrontmost(toZone: 1)
        let placed = win("w", "Warp", ZoneGenerator.snapZones(on: wide)[0])
        log.observe([placed])
        #expect(log.pinned() == [WindowID("w")])
        #expect(log.placedByDeskman([placed]).isEmpty)
    }

    @Test func aZoneThatDoesNotExistSaysSo() {
        let (snap, fake, _) = make([win("w", "Warp")])
        let outcome = snap.snapFrontmost(toZone: 6)
        #expect(!outcome.succeeded)
        #expect(outcome.message.contains("5 zones"))
        #expect(fake.frames.isEmpty)
    }

    @Test func fillPutsTheFrontWindowOnTheWholeScreen() {
        let (snap, fake, _) = make([win("w", "Warp")])
        #expect(snap.fillFrontmost().succeeded)
        #expect(fake.frames.map(\.1) == [wide.visibleFrame])
    }

    @Test func draggingAWindowAndLettingGoSnapsIt() {
        let (snap, fake, _) = make([win("w", "Warp")])
        snap.beginDrag(at: Point(x: 700, y: 310))
        fake.windowList = [win("w", "Warp", Rect(x: 3900, y: 300, width: 800, height: 600))]   // the person dragged it right
        #expect(snap.confirmDrag())
        #expect(snap.dragTarget(at: Point(x: 4000, y: 1200)) == 4)
        #expect(snap.endDrag(at: Point(x: 4000, y: 1200), bypass: false)?.succeeded == true)
        #expect(fake.frames.map(\.1) == [ZoneGenerator.snapZones(on: wide)[4]])
    }

    @Test func aClickIsNotADrag() {
        // Hammerspoon snapped on any click in a title bar: a Firefox tab click moved the window.
        let (snap, fake, _) = make([win("w", "Firefox")])
        snap.beginDrag(at: Point(x: 700, y: 310))
        #expect(!snap.confirmDrag())
        #expect(snap.endDrag(at: Point(x: 700, y: 310), bypass: false) == nil)
        #expect(fake.frames.isEmpty)
    }

    @Test func aResizeIsNotADrag() {
        let (snap, fake, _) = make([win("w", "Warp")])
        snap.beginDrag(at: Point(x: 600, y: 600))
        fake.windowList = [win("w", "Warp", Rect(x: 400, y: 300, width: 1000, height: 600))]   // left edge pulled
        #expect(!snap.confirmDrag())
        #expect(snap.endDrag(at: Point(x: 400, y: 600), bypass: false) == nil)
        #expect(fake.frames.isEmpty)
    }

    @Test func optionHeldLeavesTheWindowWhereItWasDropped() {
        let (snap, fake, _) = make([win("w", "Warp")])
        snap.beginDrag(at: Point(x: 700, y: 310))
        fake.windowList = [win("w", "Warp", Rect(x: 3900, y: 300, width: 800, height: 600))]
        _ = snap.confirmDrag()
        #expect(snap.endDrag(at: Point(x: 4000, y: 400), bypass: true) == nil)
        #expect(fake.frames.isEmpty)
    }

    @Test func aDragOnTheDesktopIsNothing() {
        let (snap, fake, _) = make([win("w", "Warp")])
        snap.beginDrag(at: Point(x: 4500, y: 1300))
        #expect(!snap.confirmDrag())
        #expect(snap.dragTarget(at: Point(x: 4000, y: 400)) == nil)
        #expect(fake.frames.isEmpty)
    }

    @Test func theFrontWindowOfSeveralIsTheOneDragged() {
        // Front to back: "a" lies on top of "b" at the click.
        let (snap, fake, _) = make([win("a", "Warp"), win("b", "Notes")])
        snap.beginDrag(at: Point(x: 700, y: 310))
        fake.windowList = [win("a", "Warp", Rect(x: 3900, y: 300, width: 800, height: 600)), win("b", "Notes")]
        #expect(snap.confirmDrag())
        _ = snap.endDrag(at: Point(x: 4000, y: 400), bypass: false)
        #expect(fake.frames.map(\.0) == [WindowID("a")])
    }
}

// ADR-2610121200: the window list can be a second old; a drag is judged on fresh frames.
@MainActor @Suite struct FreshDragTests {
    @Test func aDragIsSeenWhileTheListIsStill() {
        let fake = FakeWindowControl(windows: [win("w", "Warp")], displays: [wide])
        let snap = SnapService(control: fake, intents: nil)
        snap.beginDrag(at: Point(x: 700, y: 310))
        fake.freshFrames[WindowID("w")] = Rect(x: 1000, y: 300, width: 800, height: 600)   // moved; the list did not see it yet
        #expect(snap.confirmDrag())
        #expect(snap.endDrag(at: Point(x: 2500, y: 600), bypass: false)?.succeeded == true)
    }

    @Test func aClickIsNotADragWhenTheListIsStale() {
        // The list still shows where the window was before Deskman moved it; it has not moved since.
        let now = Rect(x: 1280, y: 30, width: 2560, height: 1380)
        let fake = FakeWindowControl(windows: [win("w", "Firefox", Rect(x: 1200, y: 100, width: 800, height: 600))],
                                     displays: [wide])
        fake.freshFrames[WindowID("w")] = now
        let snap = SnapService(control: fake, intents: nil)
        snap.beginDrag(at: Point(x: 1400, y: 120))
        #expect(!snap.confirmDrag())
        #expect(snap.endDrag(at: Point(x: 1400, y: 120), bypass: false) == nil)
    }
}
