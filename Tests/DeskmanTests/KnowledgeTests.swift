import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2610121600: What Deskman Knows shows everything Deskman knows, in words, not only habits.

private func win(_ id: String, _ app: String, _ title: String) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: title, frame: Rect(x: 0, y: 0, width: 800, height: 600), isMinimized: false)
}

@Suite struct KnowledgeTests {
    typealias K = DesktopMap.Knowledge

    @Test func anEmptySectionSaysNothingYet() {
        let k = K.build(windows: [], focus: [:], names: [:], zones: [:], keepArranged: "", bound: [])
        #expect(k.sections.map(\.title) == ["Habits", "Most used now", "Your grid", "Keep Arranged", "Bound projects"])
        #expect(k.sections.allSatisfy { $0.lines == [K.nothingYet] })
    }

    @Test func samplesBecomeMinutes() {
        #expect(K.minutes(3) == "<1 min")
        #expect(K.minutes(12) == "1 min")      // 12 samples of 5 s
        #expect(K.minutes(24) == "2 min")
    }

    @Test func theFiveMostUsedComeFirstTiesByName() {
        let ws = (0..<7).map { win("w\($0)", "App", "t\($0)") }
        let focus: [WindowID: Int] = [WindowID("w0"): 12, WindowID("w1"): 48, WindowID("w2"): 24, WindowID("w3"): 24,
                                      WindowID("w4"): 6, WindowID("w5"): 3, WindowID("w6"): 0]
        let names = Dictionary(uniqueKeysWithValues: ws.map { ($0.id, "N \($0.title)") })
        let k = K.build(windows: ws, focus: focus, names: names, zones: [:], keepArranged: "", bound: [])
        #expect(k.sections[1].lines == ["N t1: 4 min", "N t2: 2 min", "N t3: 2 min", "N t0: 1 min", "N t4: <1 min"])
    }

    @Test func aWindowNeverInFrontIsNotListed() {
        let k = K.build(windows: [win("a", "Mail", "Inbox")], focus: [WindowID("a"): 0], names: [:], zones: [:],
                        keepArranged: "", bound: [])
        #expect(k.sections[1].lines == [K.nothingYet])
    }

    @Test func withoutTheModelsNameAWindowShowsAppAndTitle() {
        let k = K.build(windows: [win("f", "Firefox", "Docs")], focus: [WindowID("f"): 12], names: [:],
                        zones: [WindowID("f"): "zone 3"], keepArranged: "watching 1 windows", bound: ["atlas"])
        #expect(k.sections[1].lines == ["Firefox — Docs: 1 min"])
        #expect(k.sections[2].lines == ["Firefox — Docs: zone 3"])
        #expect(k.sections[3].lines == ["watching 1 windows"])
        #expect(k.sections[4].lines == ["atlas"])
    }
}

@Suite struct ZoneLabelTests {
    let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1410))

    @Test func aWindowInAZoneIsNamedByIt() {
        let z = ZoneGenerator.snapZones(on: wide)
        #expect(GridPlanner.zoneLabel(of: z[2], on: wide) == "zone 3")
        #expect(GridPlanner.zoneLabel(of: Rect(x: z[0].x, y: z[0].y, width: z[0].width, height: z[1].maxY - z[0].y), on: wide) == "zones 1+2")
        #expect(GridPlanner.zoneLabel(of: Rect(x: z[4].x + 6, y: z[4].y + 4, width: z[4].width - 9, height: z[4].height - 12), on: wide) == "zone 5")
        #expect(GridPlanner.zoneLabel(of: Rect(x: 700, y: 300, width: 800, height: 600), on: wide) == nil)
    }
}

@MainActor @Suite struct KnowledgeServiceTests {
    @Test func theMapCarriesWhatDeskmanKnows() {
        let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1410))
        let z = ZoneGenerator.snapZones(on: wide)
        let f = WindowSnapshot(id: WindowID("f"), app: "Firefox", title: "Docs", frame: z[2], isMinimized: false)
        let control = FakeWindowControl(windows: [f], displays: [wide], frontmost: f.id)
        let clock = FakeClock()
        let focus = FocusTracker(clock: clock)
        for t in 0..<24 { clock.t = Double(t * 5); focus.record(app: "Firefox", window: f.id) }
        let service = ActivityService(control: control, store: InMemoryActivityStore(), clock: clock, focus: focus)
        let k = service.desktopMap().knowledge
        #expect(k.sections[1].lines == ["Firefox — Docs: 2 min"])
        #expect(k.sections[2].lines == ["Firefox — Docs: zone 3"])
    }
}

@MainActor @Suite struct KeepArrangedStateTests {
    @Test func beforeItsFirstLookKeepArrangedIsNotCalledOff() {
        // The first picture of the tab said "off" for a Keep Arranged that was on (2026-10-13).
        let control = FakeWindowControl(windows: [], displays: [Display(index: 0, visibleFrame: Rect(x: 0, y: 0, width: 1440, height: 900))])
        let settings = Settings(store: InMemoryPreferenceStore(Preferences(keepArranged: true)), control: control)
        let service = ActivityService(control: control, store: InMemoryActivityStore(), clock: FakeClock(), settings: settings)
        let line = service.desktopMap().knowledge.sections[3].lines[0]
        #expect(!line.lowercased().hasPrefix("off"), "\(line)")
    }
}

// The user, 2026-10-13: "drop the habit strip, keep habits as lines". The strip overlapped its labels.
@Suite struct HabitLinesTests {
    let left = Placement(display: 0, rect: Rect(x: 0, y: 0, width: 0.5, height: 1))

    @Test func habitsAreLinesLearnedFirst() {
        let habits = [Habit(app: "Notes", placement: left, support: 2, sightings: 2, isLearned: false),
                      Habit(app: "iTerm2", placement: left, support: 6, sightings: 8, isLearned: true)]
        let k = DesktopMap.Knowledge.build(windows: [], focus: [:], names: [:], zones: [:], keepArranged: "", bound: [],
                                           habits: habits)
        let section = k.sections[0]
        #expect(section.title == "Habits")
        #expect(section.lines == ["✓ iTerm2: \(left.phrase) (6 of 8)", "… Notes: still learning, seen 2×, mostly \(left.phrase)"])
        // A line still learning carries its habit, so it can be confirmed; a learned one does not.
        #expect(section.confirmable == [nil, habits[0]])
    }
}

// The user, 2026-10-13: "describe habits by zone". "Mostly a spot 25% wide, 50% tall" meant zone 1.
@Suite struct HabitZoneTests {
    let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1410))

    func habit(_ app: String, _ frame: Rect, learned: Bool = true) -> Habit {
        Habit(app: app, placement: .of(frame, on: wide), support: 6, sightings: 8, isLearned: learned)
    }

    @Test func aHabitInAZoneIsNamedByTheZone() {
        let z = ZoneGenerator.snapZones(on: wide)
        let column = Rect(x: z[3].x, y: z[3].y, width: z[3].width, height: z[4].maxY - z[3].y)
        let small = Rect(x: 4000, y: 400, width: 100, height: 160)
        let habits = [habit("Firefox", z[2]), habit("Slack", column), habit("Claude", z[0], learned: false), habit("Recorder", small)]
        let k = DesktopMap.Knowledge.build(windows: [], focus: [:], names: [:], zones: [:], keepArranged: "", bound: [],
                                           habits: habits, displays: [wide])
        let lines = k.sections[0].lines
        #expect(lines.contains("✓ Firefox: zone 3 (6 of 8)"))
        #expect(lines.contains("✓ Slack: zones 4+5 (6 of 8)"))
        #expect(lines.contains("… Claude: still learning, seen 8×, mostly zone 1"))
        // Not in a zone: the spot, as before.
        #expect(lines.contains { $0.hasPrefix("✓ Recorder: ") && !$0.contains("zone") })
    }
}
