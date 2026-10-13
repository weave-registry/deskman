import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2610101501 queue item 4: a new browser window goes beside the terminal.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1380))
private let zones = ZoneGenerator.snapZones(on: wide)
private let center = zones[2]

private func win(_ id: String, _ app: String, _ frame: Rect) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "", frame: frame, isMinimized: false)
}

@Suite struct ZoneBesideTests {
    @Test func theZoneBesideIsTheNearestOtherZone() {
        let z = ZoneGenerator.zone(beside: center, in: zones)
        #expect(z != nil && z != center)
        #expect(z.map { $0.x == 1280 } == false)
    }

    @Test func aTerminalOffEveryZoneStillGetsANeighbour() {
        #expect(ZoneGenerator.zone(beside: Rect(x: 100, y: 100, width: 300, height: 300), in: zones) != nil)
    }
}

@MainActor @Suite struct BrowserBesideTerminalTests {
    let clock = FakeClock()
    let store = InMemoryActivityStore()

    func make(_ windows: [WindowSnapshot], jobs: [TerminalJob]) -> (ActivityService, FakeWindowControl) {
        let control = FakeWindowControl(windows: windows, displays: [wide])
        let terminals = TerminalWatch(source: FakeTerminalActivity(jobs: jobs), clock: clock)
        return (ActivityService(control: control, store: store, clock: clock, terminals: terminals), control)
    }

    private let warp = win("t", "Warp", center)
    private let busy = [TerminalJob(app: "Warp", tty: "t1", program: "claude", folder: "/p/deskman")]

    @Test func aNewBrowserWindowGoesBesideTheTerminal() {
        let (service, control) = make([warp], jobs: busy)
        _ = service.tick()                                  // what is open at start is never moved
        control.windowList = [win("f", "Firefox", Rect(x: 2000, y: 400, width: 900, height: 700)), warp]
        clock.t = 5
        guard case .placedBeside(let s, let terminal) = service.tick() else { Issue.record("not placed"); return }
        #expect(terminal == "Warp")
        #expect(s.moves.map(\.app) == ["Firefox"])
        let to = s.moves[0].to
        #expect(to != center && zones.contains(to))
        #expect(control.frames.map(\.0) == [WindowID("f")])
    }

    @Test func itCanBeUndone() {
        let (service, control) = make([warp], jobs: busy)
        _ = service.tick()
        let opened = Rect(x: 2000, y: 400, width: 900, height: 700)
        control.windowList = [win("f", "Firefox", opened), warp]
        clock.t = 5
        _ = service.tick()
        #expect(service.undo().succeeded)
        #expect(control.frames.last?.1 == opened)
    }

    @Test func undoingThePlacementLeavesTheLearnedTrustAlone() {
        let ctx = ContextKey(apps: ["Firefox", "Warp"], displays: 1)
        var ledger = TrustLedger()
        for _ in 0..<3 { ledger.recordAccept(ctx) }
        try? store.save(ledger)
        let (service, control) = make([warp], jobs: busy)
        _ = service.tick()
        control.windowList = [win("f", "Firefox", Rect(x: 2000, y: 400, width: 900, height: 700)), warp]
        clock.t = 5
        _ = service.tick()
        #expect(service.undo().succeeded)
        #expect(store.savedLedger.isAutomatic(ctx))
        #expect(!store.savedLedger.isSnoozed(ctx, now: clock.now()))
    }

    @Test func windowsOpenAtStartAreNeverMoved() {
        let (service, control) = make([win("f", "Firefox", Rect(x: 2000, y: 400, width: 900, height: 700)), warp], jobs: busy)
        #expect(service.tick() == .idle)
        #expect(control.frames.isEmpty)
    }

    @Test func withoutATerminalNothingMoves() {
        let (service, control) = make([win("n", "Notes", center)], jobs: [])
        _ = service.tick()
        control.windowList = [win("f", "Firefox", Rect(x: 2000, y: 400, width: 900, height: 700)), win("n", "Notes", center)]
        clock.t = 5
        _ = service.tick()
        #expect(control.frames.isEmpty)
    }

    @Test func manyNewBrowserWindowsAtOnceAreLeftAlone() {
        // A browser restoring its session is not a person opening a window.
        let (service, control) = make([warp], jobs: busy)
        _ = service.tick()
        control.windowList = [win("f1", "Firefox", Rect(x: 2000, y: 400, width: 900, height: 700)),
                              win("f2", "Firefox", Rect(x: 2100, y: 400, width: 900, height: 700)), warp]
        clock.t = 5
        _ = service.tick()
        #expect(control.frames.isEmpty)
    }

    @Test func aNewWindowThatIsNotABrowserIsLeftAlone() {
        let (service, control) = make([warp], jobs: busy)
        _ = service.tick()
        control.windowList = [win("n", "Notes", Rect(x: 2000, y: 400, width: 900, height: 700)), warp]
        clock.t = 5
        _ = service.tick()
        #expect(control.frames.isEmpty)
    }

    @Test func windowsOpenedDuringAPauseAreNotNewAfterIt() {
        let (service, control) = make([warp], jobs: busy)
        _ = service.tick()
        service.isPaused = true
        clock.t = 5
        _ = service.tick()
        control.windowList = [win("f", "Firefox", Rect(x: 2000, y: 400, width: 900, height: 700)), warp]
        service.isPaused = false
        clock.t = 10
        _ = service.tick()
        #expect(control.frames.isEmpty)
    }

    @Test func pausedLearningMovesNothing() {
        let (service, control) = make([warp], jobs: busy)
        _ = service.tick()
        service.isPaused = true
        control.windowList = [win("f", "Firefox", Rect(x: 2000, y: 400, width: 900, height: 700)), warp]
        clock.t = 5
        _ = service.tick()
        #expect(control.frames.isEmpty)
    }
}
