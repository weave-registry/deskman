import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2611111100: clicking the green button of a window that has grown out of its zone over
// other windows puts it back in its zone, instead of sending it to full screen.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1380))
// The standard snap zones on this display (ZoneGenerator.snapZones).
private let z1 = Rect(x: 0, y: 30, width: 1280, height: 690)
private let z2 = Rect(x: 0, y: 720, width: 1280, height: 690)
private let z3 = Rect(x: 1280, y: 30, width: 2560, height: 1380)
private let leftColumn = Rect(x: 0, y: 30, width: 1280, height: 1380)
private let fullScreen = Rect(x: 0, y: 30, width: 5120, height: 1380)

private func win(_ id: String, _ app: String, _ frame: Rect) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "", frame: frame, isMinimized: false)
}

/// The green button sits about 60 pt in from the window's top-left corner.
private func button(of frame: Rect) -> Rect { Rect(x: frame.x + 52, y: frame.y + 6, width: 14, height: 14) }
private func onButton(of frame: Rect) -> Point { Point(x: frame.x + 59, y: frame.y + 13) }

@Suite struct ZoneReturnTests {
    let zones = ZoneGenerator.snapZones(on: wide)

    @Test func theSideColumnsArePlacesToo() {
        let places = ZoneReturn.places(zones)
        #expect(places.contains(leftColumn))
        #expect(places.contains(z1) && places.contains(z3))
    }

    @Test func aWindowGrownOverItsNeighbourIsOutOfItsZone() {
        let tall = win("t", "Warp", leftColumn.withHeight(1380))
        let grown = win("g", "Warp", Rect(x: 0, y: 30, width: 1280, height: 1100))
        let below = win("b", "Safari", z2)
        #expect(ZoneReturn.isOutOfZone(grown, among: [grown, below], places: ZoneReturn.places(zones)))
        // A whole side column is a place: in it, the window is home, whatever it covers.
        #expect(!ZoneReturn.isOutOfZone(tall, among: [tall, below], places: ZoneReturn.places(zones)))
    }

    @Test func aWindowCoveringNothingIsNotOutOfItsZone() {
        let alone = win("g", "Warp", Rect(x: 100, y: 100, width: 2000, height: 1200))
        #expect(!ZoneReturn.isOutOfZone(alone, among: [alone], places: ZoneReturn.places(zones)))
    }

    @Test func aWindowInItsZoneIsHomeEvenWhenAnAppSettledItAFewPointsOff() {
        let near = win("n", "iTerm2", Rect(x: 0, y: 30, width: 1274, height: 683))
        let other = win("o", "Safari", Rect(x: 0, y: 500, width: 1280, height: 900))
        #expect(!ZoneReturn.isOutOfZone(near, among: [near, other], places: ZoneReturn.places(zones)))
    }

    @Test func theTargetIsTheZoneItCameFrom() {
        let target = ZoneReturn.target(for: fullScreen, zones: zones, remembered: z2)
        #expect(target == z2)
    }

    @Test func withoutAMemoryTheTargetIsTheZoneItCoversMost() {
        #expect(ZoneReturn.target(for: fullScreen, zones: zones, remembered: nil) == z3)
        let leftish = Rect(x: 0, y: 30, width: 1400, height: 900)
        #expect(ZoneReturn.target(for: leftish, zones: zones, remembered: nil) == z1)
    }
}

private extension Rect {
    func withHeight(_ h: Double) -> Rect { Rect(x: x, y: y, width: width, height: h) }
}

@MainActor @Suite struct GreenButtonTests {
    let clock = FakeClock()

    func make(_ windows: [WindowSnapshot], preferences: Preferences = Preferences())
        -> (SnapService, FakeWindowControl, IntentLog) {
        let log = IntentLog(clock: clock)
        let fake = FakeWindowControl(windows: windows, displays: [wide], frontmost: windows.first?.id)
        for w in windows { fake.greenButtons[w.id] = button(of: w.frame) }
        let control = IntentRecordingControl(fake, log: log)
        let settings = Settings(store: InMemoryPreferenceStore(preferences), control: fake)
        return (SnapService(control: control, intents: log, settings: settings), fake, log)
    }

    /// The upper-left window has grown to most of the column, over the one in zone 2.
    func grown() -> (SnapService, FakeWindowControl, IntentLog, Rect) {
        let (snap, fake, log) = make([win("t", "Warp", z1), win("b", "Safari", z2), win("c", "Xcode", z3)])
        snap.observe()   // Deskman sees it in zone 1
        let big = Rect(x: 0, y: 30, width: 1280, height: 1200)
        fake.windowList[0] = win("t", "Warp", big)
        fake.greenButtons[WindowID("t")] = button(of: big)
        return (snap, fake, log, big)
    }

    @Test func theGreenButtonOfAGrownWindowIsClaimedAndPutsItBackInItsZone() {
        let (snap, fake, _, big) = grown()
        let id = snap.greenButtonClaim(at: onButton(of: big))
        #expect(id == WindowID("t"))
        #expect(snap.returnToZone(WindowID("t")).succeeded)
        #expect(fake.frames.last?.0 == WindowID("t") && fake.frames.last?.1 == z1)
    }

    @Test func aFullScreenSizedWindowWithNoMemoryGoesToTheZoneItCoversMost() {
        let (snap, fake, _) = make([win("f", "Safari", fullScreen), win("b", "Warp", z2)])
        #expect(snap.greenButtonClaim(at: onButton(of: fullScreen)) == WindowID("f"))
        _ = snap.returnToZone(WindowID("f"))
        #expect(fake.frames.last?.1 == z3)
    }

    @Test func aWindowInItsZoneKeepsTheGreenButtonsUsualMeaning() {
        let (snap, _, _) = make([win("t", "Warp", z1), win("b", "Safari", z2)])
        #expect(snap.greenButtonClaim(at: onButton(of: z1)) == nil)
    }

    @Test func aGrownWindowCoveringNothingKeepsTheGreenButtonsUsualMeaning() {
        let big = Rect(x: 0, y: 30, width: 1280, height: 1200)
        let (snap, _, _) = make([win("t", "Warp", big), win("c", "Xcode", z3)])
        #expect(snap.greenButtonClaim(at: onButton(of: big)) == nil)
    }

    @Test func aClickBesideTheGreenButtonIsNotClaimed() {
        let (snap, _, _, big) = grown()
        #expect(snap.greenButtonClaim(at: Point(x: big.x + 20, y: big.y + 13)) == nil)    // the red one
        #expect(snap.greenButtonClaim(at: Point(x: big.x + 600, y: big.y + 400)) == nil)  // the window's content
    }

    @Test func aWindowCoveredAtThatPointIsNotTheOneClicked() {
        // Zone 2's window is in front of the grown one, at the grown one's button: the click is the front window's.
        let big = Rect(x: 0, y: 30, width: 1280, height: 1200)
        let front = win("f", "Notes", Rect(x: 40, y: 35, width: 400, height: 300))
        let (snap, _, _) = make([front, win("t", "Warp", big), win("b", "Safari", z2)])
        #expect(snap.greenButtonClaim(at: onButton(of: big)) == nil)
    }

    @Test func theFrameIsReadFreshBeforeTheClickIsClaimed() {
        // The list is a second old and still shows the window in its zone; it has grown since.
        let (snap, fake, _) = make([win("t", "Warp", z1), win("b", "Safari", z2)])
        snap.observe()
        let big = Rect(x: 0, y: 30, width: 1280, height: 1200)
        fake.freshFrames[WindowID("t")] = big
        #expect(snap.greenButtonClaim(at: onButton(of: z1)) == WindowID("t"))
    }

    @Test func offInTheMenuMeansOff() {
        let (snap, _, _) = make([win("f", "Safari", fullScreen), win("b", "Warp", z2)],
                                preferences: Preferences(greenButton: false))
        #expect(snap.greenButtonClaim(at: onButton(of: fullScreen)) == nil)
    }

    @Test func anAppDeskmanLeavesAloneIsNotClaimed() {
        let (snap, _, _) = make([win("f", "Safari", fullScreen), win("b", "Warp", z2)],
                                preferences: Preferences(floatingApps: ["Safari"]))
        #expect(snap.greenButtonClaim(at: onButton(of: fullScreen)) == nil)
    }

    @Test func nothingIsClaimedDuringAMeeting() {
        let meeting = win("z", "zoom.us", Rect(x: 4000, y: 30, width: 800, height: 600))
        let zoom = WindowSnapshot(id: meeting.id, app: meeting.app, title: "Zoom Meeting", frame: meeting.frame, isMinimized: false)
        let (snap, _, _) = make([win("f", "Safari", fullScreen), win("b", "Warp", z2), zoom])
        #expect(snap.greenButtonClaim(at: onButton(of: fullScreen)) == nil)
    }

    @Test func aWindowWithNoGreenButtonInReachIsNotClaimed() {
        // Native full screen: the adapter reports no button; the click leaves full screen as macOS does.
        let (snap, fake, _) = make([win("f", "Safari", fullScreen), win("b", "Warp", z2)])
        fake.greenButtons[WindowID("f")] = nil
        #expect(snap.greenButtonClaim(at: onButton(of: fullScreen)) == nil)
    }

    @Test func theWindowPutBackIsPinnedAsTheChoiceOfThePerson() {
        let (snap, _, log, _) = grown()
        _ = snap.returnToZone(WindowID("t"))
        #expect(log.pinned().contains(WindowID("t")))
    }
}
