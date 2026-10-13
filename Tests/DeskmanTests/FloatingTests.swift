import Foundation
import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2610120742: apps Deskman leaves alone, and a switch for drag-to-snap.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1380))
private let screen = Display(index: 0, visibleFrame: Rect(x: 0, y: 25, width: 1440, height: 875))
private let left = Layout.leftHalf.frame(in: screen.visibleFrame)
private let middle = Layout.center.frame(in: screen.visibleFrame)
private let small = Rect(x: 600, y: 300, width: 300, height: 400)

private func win(_ id: String, _ app: String, _ frame: Rect = small) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "", frame: frame, isMinimized: false)
}

@Suite struct PreferencesTests {
    @Test func theDefaultsAreHammerspoonsFloatingAppsAndDragSnapOn() {
        let p = Preferences()
        #expect(p.dragSnap)
        for app in ["Finder", "System Settings", "Calculator", "Preview", "1Password", "Raycast", "Alfred", "Spotlight"] {
            #expect(p.isFloating(app), "\(app)")
        }
        #expect(!p.isFloating("Warp"))
    }

    @Test func appNamesMatchWithoutCase() {
        #expect(Preferences(floatingApps: ["Calculator"]).isFloating("calculator"))
    }

    @Test func aFileWithoutAFieldTakesItsDefault() throws {
        let p = try JSONDecoder().decode(Preferences.self, from: Data(#"{"floatingApps":["Notes"]}"#.utf8))
        #expect(p.floatingApps == ["Notes"])
        #expect(p.dragSnap)
        let empty = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(empty == Preferences())
    }

    @Test func itRoundTrips() throws {
        let p = Preferences(floatingApps: ["Notes", "Mail"], dragSnap: false)
        #expect(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p)) == p)
    }
}

@MainActor @Suite struct SettingsTests {
    @Test func toggleTheFrontAppAddsItThenRemovesIt() {
        let store = InMemoryPreferenceStore(Preferences(floatingApps: []))
        let control = FakeWindowControl(windows: [win("w", "Warp")], displays: [wide], frontmost: WindowID("w"))
        let settings = Settings(store: store, control: control)
        let on = settings.toggleFloatingFrontmost()
        #expect(on.succeeded && on.message.contains("Warp"))
        #expect(settings.isFloating("Warp"))
        #expect(store.saved?.floatingApps == ["Warp"])
        #expect(settings.toggleFloatingFrontmost().succeeded)
        #expect(!settings.isFloating("Warp"))
        #expect(store.saved?.floatingApps == [])
    }

    @Test func noFrontWindowSaysSo() {
        let control = FakeWindowControl(windows: [], displays: [wide])
        let outcome = Settings(store: InMemoryPreferenceStore(), control: control).toggleFloatingFrontmost()
        #expect(!outcome.succeeded)
    }

    @Test func theDragSwitchIsSaved() {
        let store = InMemoryPreferenceStore()
        let settings = Settings(store: store, control: nil)
        #expect(settings.setDragSnap(false).succeeded)
        #expect(!settings.dragSnap)
        #expect(store.saved?.dragSnap == false)
        // A second Settings reads what the first saved: it lasts across a restart.
        #expect(!Settings(store: store, control: nil).dragSnap)
    }

    @Test func aFailedSaveKeepsTheChangeAndSaysItWillBeLost() {
        let store = InMemoryPreferenceStore()
        store.failingSaves = 1
        let settings = Settings(store: store, control: nil)
        let outcome = settings.setDragSnap(false)
        #expect(!outcome.succeeded)
        #expect(outcome.message.contains("could not save"))
        #expect(!settings.dragSnap)
    }

    @Test func aDamagedFileIsReportedAndTheDefaultsRun() {
        let store = InMemoryPreferenceStore()
        store.loadError = FakeError(description: "bad JSON at line 1")
        let settings = Settings(store: store, control: nil)
        #expect(settings.problem?.contains("bad JSON") == true)
        #expect(settings.isFloating("Finder"))
        #expect(store.saves == 0)                       // not overwritten behind the person's back
        _ = settings.setFloating("Mail", true)
        #expect(store.saved?.floatingApps.contains("Mail") == true)
        #expect(settings.problem == nil)                // the next change wrote a good file
    }

    @Test func theListIsSortedAndHasNoDuplicates() {
        let settings = Settings(store: InMemoryPreferenceStore(Preferences(floatingApps: [])), control: nil)
        _ = settings.setFloating("Mail", true)
        _ = settings.setFloating("Calculator", true)
        _ = settings.setFloating("mail", true)
        #expect(settings.floatingApps == ["Calculator", "Mail"])
        _ = settings.setFloating("MAIL", false)
        #expect(settings.floatingApps == ["Calculator"])
    }
}

@MainActor @Suite struct LeaveAloneTests {
    let clock = FakeClock()
    let store = InMemoryActivityStore()
    let settings = Settings(store: InMemoryPreferenceStore(Preferences(floatingApps: ["Calculator"])), control: nil)

    @Test func smartArrangeNeitherMovesNorParksAFloatingApp() {
        let windows = [win("e", "Xcode", Rect(x: 10, y: 40, width: 900, height: 700)), win("c", "Calculator"),
                       win("t", "Warp", Rect(x: 2000, y: 40, width: 900, height: 700))]
        let control = FakeWindowControl(windows: windows, displays: [wide], frontmost: WindowID("e"))
        let service = ActivityService(control: control, store: store, clock: clock,
                                      arranger: SmartArranger(control: control, history: store, settings: settings))
        #expect(service.smartArrange().succeeded)
        #expect(!control.frames.map(\.0).contains(WindowID("c")))
        #expect(!control.actions.map(\.1).contains(WindowID("c")))
        #expect(Set(control.frames.map(\.0)) == [WindowID("e"), WindowID("t")])
    }

    @Test func aFloatingAppDoesNotShrinkTheZones() {
        let windows = [win("e", "Xcode", Rect(x: 10, y: 40, width: 900, height: 700)), win("c", "Calculator")]
        let control = FakeWindowControl(windows: windows, displays: [wide], frontmost: WindowID("e"))
        let service = WindowService(control: control, settings: settings)
        #expect(service.smartArrange(biggest: nil).succeeded)
        // One window to arrange: it gets the zone a lone window gets, as if Calculator were not there.
        let lone = ZoneGenerator.layout(count: 1, weights: [0], on: wide, within: wide.visibleFrame).zones[0].frame(in: wide)
        #expect(control.frames.map(\.1) == [lone])
    }

    @Test func onlyFloatingAppsLeavesNothingToArrange() {
        let control = FakeWindowControl(windows: [win("c", "Calculator")], displays: [wide], frontmost: WindowID("c"))
        let outcome = WindowService(control: control, settings: settings).smartArrange(biggest: nil)
        #expect(!outcome.succeeded)
        #expect(control.frames.isEmpty)
    }

    @Test func aLearnedSuggestionLeavesAFloatingAppOut() {
        let history = (0..<3).map { DeskSnapshot(time: Double($0), windows: [win("c", "Calculator", left)],
                                                 displays: [screen], focusedApp: nil) }
        for s in history { try? store.append(s) }
        let control = FakeWindowControl(windows: [win("c", "Calculator", middle)], displays: [screen])
        let service = ActivityService(control: control, store: store, clock: clock, settings: settings)
        clock.t = 100; _ = service.tick()
        clock.t = 106
        #expect(service.tick() == .idle)
        #expect(service.pending == nil)
    }

    @Test func aNewFloatingBrowserIsNotPutBesideTheTerminal() {
        let center = ZoneGenerator.snapZones(on: wide)[2]
        let warp = win("t", "Warp", center)
        let jobs = [TerminalJob(app: "Warp", tty: "t1", program: "claude", folder: "/p")]
        let floatingFirefox = Settings(store: InMemoryPreferenceStore(Preferences(floatingApps: ["Firefox"])), control: nil)
        let control = FakeWindowControl(windows: [warp], displays: [wide])
        let service = ActivityService(control: control, store: store, clock: clock,
                                      terminals: TerminalWatch(source: FakeTerminalActivity(jobs: jobs), clock: clock),
                                      settings: floatingFirefox)
        _ = service.tick()
        control.windowList = [win("f", "Firefox", Rect(x: 2000, y: 400, width: 900, height: 700)), warp]
        clock.t = 5
        if case .placedBeside = service.tick() { Issue.record("a floating browser was moved") }
        #expect(control.frames.isEmpty)
    }

    @Test func aSnapHotkeyStillMovesAFloatingApp() {
        let control = FakeWindowControl(windows: [win("c", "Calculator")], displays: [wide], frontmost: WindowID("c"))
        let snap = SnapService(control: control, intents: nil, settings: settings)
        #expect(snap.snapFrontmost(toZone: 1).succeeded)
        #expect(control.frames.count == 1)
    }

    @Test func theModelNamingTheWindowStillMovesIt() {
        let control = FakeWindowControl(windows: [win("c", "Calculator")], displays: [wide], frontmost: WindowID("c"))
        #expect(WindowService(control: control, settings: settings).arrange("Calculator", layout: .leftHalf).succeeded)
        #expect(control.frames.count == 1)
    }
}

@MainActor @Suite struct DragSwitchTests {
    let start = Rect(x: 600, y: 300, width: 800, height: 600)

    /// Grab at the title bar, move 400 pt right, drop in the center zone.
    func drag(_ app: String, settings: Settings) -> (CommandOutcome?, FakeWindowControl, SnapService) {
        let control = FakeWindowControl(windows: [win("w", app, start)], displays: [wide])
        let snap = SnapService(control: control, intents: nil, settings: settings)
        snap.beginDrag(at: Point(x: 700, y: 310))
        control.windowList = [win("w", app, Rect(x: 1000, y: 300, width: 800, height: 600))]
        let drop = Point(x: 2500, y: 600)
        _ = snap.confirmDrag()
        return (snap.endDrag(at: drop, bypass: false), control, snap)
    }

    @Test func dragSnapOnSnaps() {
        let (outcome, control, _) = drag("Warp", settings: Settings(store: InMemoryPreferenceStore(), control: nil))
        #expect(outcome?.succeeded == true)
        #expect(control.frames.count == 1)
    }

    @Test func dragSnapOffNeverSnapsOrShowsTheOverlay() {
        let settings = Settings(store: InMemoryPreferenceStore(), control: nil)
        _ = settings.setDragSnap(false)
        let control = FakeWindowControl(windows: [win("w", "Warp", start)], displays: [wide])
        let snap = SnapService(control: control, intents: nil, settings: settings)
        snap.beginDrag(at: Point(x: 700, y: 310))
        control.windowList = [win("w", "Warp", Rect(x: 1000, y: 300, width: 800, height: 600))]
        #expect(!snap.confirmDrag())                    // no confirmed drag: DragSnap shows no overlay
        #expect(snap.dragTarget(at: Point(x: 2500, y: 600)) == nil)
        #expect(snap.endDrag(at: Point(x: 2500, y: 600), bypass: false) == nil)
        #expect(control.frames.isEmpty)
    }

    @Test func dragSnapOffKeepsTheHotkeys() {
        let settings = Settings(store: InMemoryPreferenceStore(), control: nil)
        _ = settings.setDragSnap(false)
        let control = FakeWindowControl(windows: [win("w", "Warp", start)], displays: [wide], frontmost: WindowID("w"))
        #expect(SnapService(control: control, intents: nil, settings: settings).snapFrontmost(toZone: 2).succeeded)
    }

    @Test func aFloatingAppIsNeverDragSnapped() {
        let settings = Settings(store: InMemoryPreferenceStore(Preferences(floatingApps: ["Finder"])), control: nil)
        let (outcome, control, _) = drag("Finder", settings: settings)
        #expect(outcome == nil)
        #expect(control.frames.isEmpty)
    }

    @Test func turningItBackOnSnapsAgain() {
        let settings = Settings(store: InMemoryPreferenceStore(), control: nil)
        _ = settings.setDragSnap(false)
        _ = settings.setDragSnap(true)
        #expect(drag("Warp", settings: settings).0?.succeeded == true)
    }
}
