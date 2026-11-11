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

// A window whose green button Deskman would take shows a ring on it (the user, 2026-11-11: "I don't see where the
// green button is telling me that there's an overlapping window").
@MainActor @Suite struct GreenButtonHintTests {
    let clock = FakeClock()

    func make(_ windows: [WindowSnapshot], preferences: Preferences = Preferences()) -> (SnapService, FakeWindowControl) {
        let fake = FakeWindowControl(windows: windows, displays: [wide], frontmost: windows.first?.id)
        for w in windows { fake.greenButtons[w.id] = button(of: w.frame) }
        let settings = Settings(store: InMemoryPreferenceStore(preferences), control: fake)
        return (SnapService(control: fake, intents: IntentLog(clock: clock), settings: settings), fake)
    }

    @Test func aGrownWindowCoveringAnotherShowsARingOnItsGreenButton() {
        let big = Rect(x: 0, y: 30, width: 1280, height: 1200)
        let (snap, _) = make([win("t", "Warp", big), win("b", "Safari", z2), win("c", "Xcode", z3)])
        #expect(snap.greenButtonHints() == [button(of: big)])
    }

    @Test func windowsInTheirZonesShowNoRing() {
        let (snap, _) = make([win("t", "Warp", z1), win("b", "Safari", z2), win("c", "Xcode", z3)])
        #expect(snap.greenButtonHints().isEmpty)
    }

    @Test func aButtonCoveredByAnotherWindowShowsNoRing() {
        let big = Rect(x: 0, y: 30, width: 1280, height: 1200)
        let front = win("f", "Notes", Rect(x: 40, y: 35, width: 400, height: 300))
        let (snap, _) = make([front, win("t", "Warp", big), win("b", "Safari", z2)])
        // Notes is out of its zone too, and its own button is in view: only its ring shows.
        #expect(snap.greenButtonHints() == [button(of: front.frame)])
    }

    @Test func offInTheMenuShowsNoRing() {
        let (snap, _) = make([win("f", "Safari", fullScreen), win("b", "Warp", z2)], preferences: Preferences(greenButton: false))
        #expect(snap.greenButtonHints().isEmpty)
    }

    @Test func theButtonIsAskedForOnceWhileTheWindowStaysPut() {
        let (snap, fake) = make([win("f", "Safari", fullScreen), win("b", "Warp", z2)])
        _ = snap.greenButtonHints()
        fake.greenButtons[WindowID("f")] = nil   // asked again, it would say nothing
        #expect(snap.greenButtonHints() == [button(of: fullScreen)])
    }
}

// 2026-11-11, the user's screenshot: a ring floated over Mail's sidebar. The list, a second old, had Slack in front;
// the window server had Mail in front, over Slack's green button. The ring is decided by the order on screen now.
@MainActor @Suite struct GreenButtonOrderTests {
    let clock = FakeClock()

    @Test func aButtonCoveredNowShowsNoRingThoughTheOldListSaysItIsInFront() {
        let slack = Rect(x: 0, y: 400, width: 1280, height: 1000)   // grown over the window in zone 1
        let mail = Rect(x: 0, y: 30, width: 1280, height: 420)      // now in front, over Slack's button
        let windows = [win("s", "Slack", slack), win("m", "Mail", mail)]
        let fake = FakeWindowControl(windows: windows, displays: [wide], frontmost: WindowID("s"))
        for w in windows { fake.greenButtons[w.id] = button(of: w.frame) }
        fake.onScreen = [(WindowID("m"), mail), (WindowID("s"), slack)]
        let snap = SnapService(control: fake, intents: IntentLog(clock: clock))
        #expect(!snap.greenButtonHints().contains(button(of: slack)))
        #expect(snap.greenButtonClaim(at: onButton(of: slack)) == nil)
    }

    @Test func theFramesOnScreenNowAreTheOnesJudged() {
        // The list still shows the window in zone 1; on screen it has grown over zone 2's.
        let big = Rect(x: 0, y: 30, width: 1280, height: 1200)
        let windows = [win("t", "Warp", z1), win("b", "Safari", z2)]
        let fake = FakeWindowControl(windows: windows, displays: [wide], frontmost: WindowID("t"))
        fake.greenButtons[WindowID("t")] = button(of: big)
        fake.onScreen = [(WindowID("t"), big), (WindowID("b"), z2)]
        let snap = SnapService(control: fake, intents: IntentLog(clock: clock))
        #expect(snap.greenButtonHints() == [button(of: big)])
    }

    @Test func aWindowNoLongerOnScreenShowsNoRing() {
        let windows = [win("f", "Safari", fullScreen), win("b", "Warp", z2)]
        let fake = FakeWindowControl(windows: windows, displays: [wide], frontmost: WindowID("f"))
        for w in windows { fake.greenButtons[w.id] = button(of: w.frame) }
        fake.onScreen = [(WindowID("b"), z2)]   // Safari was closed a moment ago
        let snap = SnapService(control: fake, intents: IntentLog(clock: clock))
        #expect(snap.greenButtonHints().isEmpty)
    }
}

// 2026-11-11, on the user's desktop: iTerm2 in its column, 35 pt short (whole text lines), got a ring because a
// Preview window, which Deskman leaves alone, lay under it.
@MainActor @Suite struct GreenButtonFalseRingTests {
    let clock = FakeClock()

    func make(_ windows: [WindowSnapshot]) -> SnapService {
        let fake = FakeWindowControl(windows: windows, displays: [wide], frontmost: windows.first?.id)
        for w in windows { fake.greenButtons[w.id] = button(of: w.frame) }
        let settings = Settings(store: InMemoryPreferenceStore(Preferences()), control: fake)   // Preview is left alone
        return SnapService(control: fake, intents: IntentLog(clock: clock), settings: settings)
    }

    @Test func aWindowAFewLinesShortOfItsColumnIsInIt() {
        let short = Rect(x: 0, y: 30, width: 1280, height: 1380 - 40)
        let s = make([win("i", "iTerm2", short), win("b", "Safari", Rect(x: 0, y: 1000, width: 1280, height: 410))])
        #expect(s.greenButtonHints().isEmpty)
    }

    @Test func coveringOnlyAWindowDeskmanLeavesAloneIsNotGrowingOverANeighbour() {
        let big = Rect(x: 0, y: 30, width: 1280, height: 1200)
        let s = make([win("t", "Warp", big), win("p", "Preview", Rect(x: 600, y: 30, width: 1100, height: 1300))])
        #expect(s.greenButtonHints().isEmpty)
        #expect(s.greenButtonClaim(at: onButton(of: big)) == nil)
    }

    @Test func coveringAnArrangedWindowStillCounts() {
        let big = Rect(x: 0, y: 30, width: 1280, height: 1200)
        let s = make([win("t", "Warp", big), win("p", "Preview", Rect(x: 600, y: 30, width: 1100, height: 1300)),
                      win("b", "Safari", z2)])
        #expect(s.greenButtonHints() == [button(of: big)])
    }
}

// The second grid (2026-11-11): 1 over 2 | 3 | 4 | 5 over 6. A window Smart Arrange put in one of its
// zones is home there too; grown, it goes back to that zone, not to the first grid's wide middle.
@MainActor @Suite struct GreenButtonSecondGridTests {
    let clock = FakeClock()
    static let q3 = Rect(x: 1280, y: 30, width: 1280, height: 1380)
    static let q4 = Rect(x: 2560, y: 30, width: 1280, height: 1380)

    func make(_ windows: [WindowSnapshot]) -> (SnapService, FakeWindowControl) {
        let fake = FakeWindowControl(windows: windows, displays: [wide], frontmost: windows.first?.id)
        for w in windows { fake.greenButtons[w.id] = button(of: w.frame) }
        let settings = Settings(store: InMemoryPreferenceStore(Preferences()), control: fake)
        return (SnapService(control: fake, intents: nil, settings: settings), fake)
    }

    @Test func aWindowInZone3OfTheSecondGridIsHomeEvenSettledAFewPointsOver() {
        let settled = Rect(x: 1280, y: 30, width: 1300, height: 1380)  // 20 pt over zone 4
        let (snap, _) = make([win("a", "Warp", settled), win("b", "Safari", Self.q4)])
        #expect(snap.greenButtonClaim(at: onButton(of: settled)) == nil)
    }

    @Test func grownFromZone3OfTheSecondGridItGoesBackThere() {
        let (snap, fake) = make([win("a", "Warp", Self.q3), win("b", "Safari", Self.q4)])
        snap.observe()
        let big = Rect(x: 1280, y: 30, width: 2200, height: 1380)
        fake.windowList[0] = win("a", "Warp", big)
        fake.greenButtons[WindowID("a")] = button(of: big)
        #expect(snap.greenButtonClaim(at: onButton(of: big)) == WindowID("a"))
        #expect(snap.returnToZone(WindowID("a")).succeeded)
        #expect(fake.frames.last?.1 == Self.q3, "\(fake.frames)")
    }
}
