import Testing
import DeskmanPorts
import DeskmanUseCases

// The user, 2026-10-12: "we should never have overlapping windows or windows that are too small".
// The picture: three Firefox windows, WhatsApp squeezed to 633 pt, and Stream Deck, which will not
// go that narrow, over WhatsApp and off the screen's edge.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1410))

private func win(_ id: String, _ app: String, x: Double) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: id, frame: Rect(x: x, y: 100, width: 800, height: 600),
                   isMinimized: false)
}

private let five = [win("f1", "Firefox", x: 0), win("f2", "Firefox", x: 900), win("f3", "Firefox", x: 1800),
                    win("wa", "WhatsApp", x: 2700), win("sd", "Stream Deck", x: 3600)]

@MainActor @Suite struct NoOverlapTests {
    func make(_ control: FakeWindowControl) -> ActivityService {
        ActivityService(control: control, store: InMemoryActivityStore(), clock: FakeClock(),
                        arranger: SmartArranger(control: control, history: nil))
    }

    /// Where every window Deskman placed sits now, read back as Deskman would. `leftAlone`: windows
    /// with no room, left where they were (never minimized, 2026-10-12), outside this check.
    func onScreen(_ control: FakeWindowControl, leftAlone: Set<WindowID> = []) -> [(WindowID, Rect)] {
        #expect(!control.actions.contains { $0.0 == .minimize })
        // The windows Deskman placed. In the grid (2026-10-12) a window with no zone is not moved.
        let placed = Set(control.frames.map(\.0))
        return control.windowList.filter { !leftAlone.contains($0.id) && placed.contains($0.id) }.map { w in
            (w.id, control.frames.last { $0.0 == w.id }?.1 ?? w.frame)
        }
    }

    func check(_ placed: [(WindowID, Rect)], sourceLocation: SourceLocation = #_sourceLocation) {
        let area = wide.visibleFrame
        for (id, r) in placed {
            #expect(r.width >= ZonePlanner.minimumWidth, "\(id.raw) is \(Int(r.width)) pt wide", sourceLocation: sourceLocation)
            #expect(r.height >= ZonePlanner.minimumHeight, "\(id.raw) is \(Int(r.height)) pt tall", sourceLocation: sourceLocation)
            #expect(r.x >= area.x - 0.5 && r.maxX <= area.maxX + 0.5 && r.y >= area.y - 0.5 && r.maxY <= area.maxY + 0.5,
                    "\(id.raw) leaves the screen", sourceLocation: sourceLocation)
        }
        for i in placed.indices { for j in placed.indices where i < j {
            let overlap = placed[i].1.intersection(placed[j].1)?.area ?? 0
            #expect(overlap < 1, "\(placed[i].0.raw) overlaps \(placed[j].0.raw)", sourceLocation: sourceLocation)
        } }
    }

    @Test func noArrangedWindowIsTooSmall() {
        let control = FakeWindowControl(windows: five, displays: [wide], frontmost: WindowID("f1"))
        #expect(make(control).smartArrange().succeeded)
        check(onScreen(control))
    }

    @Test func aWindowThatWillNotShrinkIsPlannedAround() {
        let control = FakeWindowControl(windows: five, displays: [wide], frontmost: WindowID("f1"))
        control.minimumWidth[WindowID("sd")] = 1100
        let outcome = make(control).smartArrange()
        #expect(outcome.succeeded)
        // Three browsers take the middle and both side columns; WhatsApp and Stream Deck have no zone.
        #expect(outcome.message.contains("No room for") && outcome.message.contains("Stream Deck"))
        check(onScreen(control))
    }

    @Test func aWindowWiderThanTheScreenAllowsIsLeftWhereItWas() {
        let control = FakeWindowControl(windows: five, displays: [wide], frontmost: WindowID("f1"))
        control.minimumWidth[WindowID("sd")] = 6000
        let outcome = make(control).smartArrange()
        #expect(outcome.succeeded)
        #expect(outcome.message.contains("No room for") && outcome.message.contains("Stream Deck"))
        check(onScreen(control))
        #expect(control.frame(of: WindowID("sd"))?.x == five[4].frame.x, "Stream Deck was not put back")
    }

    @Test func undoAfterAReplanPutsEveryWindowBack() {
        let control = FakeWindowControl(windows: five, displays: [wide], frontmost: WindowID("f1"))
        control.minimumWidth[WindowID("sd")] = 1100
        let service = make(control)
        _ = service.smartArrange()
        #expect(service.undo().succeeded)
        for w in five where w.id != WindowID("sd") {
            // Put back, or never moved (a window with no zone in the grid stays where it was).
            #expect((control.frames.last { $0.0 == w.id }?.1 ?? w.frame) == w.frame, "\(w.id.raw) not put back")
        }
    }
}

// 2026-10-12, "when zoom is active it hides all other windows": Zoom would not go where it was
// put (one window gone, AXError -25202; the meeting window keeps its own shape), and every
// window it then covered was minimized. The window that would not move must not cost the others.
@MainActor @Suite struct AWindowThatWillNotMoveTests {
    // Recorder refused a resize in the trace (AXError -25200). Zoom itself is now never arranged (MeetingTests).
    let zoom = WindowSnapshot(id: WindowID("z"), app: "Recorder", title: "Recorder",
                              frame: Rect(x: 1500, y: 30, width: 2000, height: 1410), isMinimized: false)
    var windows: [WindowSnapshot] { [zoom, win("s", "Slack", x: 0), win("m", "Mail", x: 3600)] }

    func check(_ control: FakeWindowControl, _ service: ActivityService) {
        _ = service.smartArrange(automatic: true)
        #expect(!control.actions.contains { $0.0 == .minimize }, "minimized \(control.actions.map(\.1.raw))")
        let placed = control.windowList.map { w in (w.id, control.frame(of: w.id) ?? w.frame) }
        for i in placed.indices { for j in placed.indices where i < j {
            #expect((placed[i].1.intersection(placed[j].1)?.area ?? 0) < 1, "\(placed[i].0.raw) overlaps \(placed[j].0.raw)")
        } }
    }

    func make(_ control: FakeWindowControl) -> ActivityService {
        ActivityService(control: control, store: InMemoryActivityStore(), clock: FakeClock(),
                        arranger: SmartArranger(control: control, history: nil))
    }

    @Test func aWindowThatStaysPutIsArrangedAround() {
        let control = FakeWindowControl(windows: windows, displays: [wide], frontmost: WindowID("z"))
        control.immovable = [WindowID("z")]
        check(control, make(control))
    }

    @Test func aWindowThatCannotBeMovedIsArrangedAround() {
        let control = FakeWindowControl(windows: windows, displays: [wide], frontmost: WindowID("z"))
        control.stuck = [WindowID("z")]
        check(control, make(control))
    }
}


