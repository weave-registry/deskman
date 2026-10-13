import Foundation
import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2610101501 queue item 1: a move or resize by hand is an intent.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1380))
private let start = Rect(x: 100, y: 100, width: 800, height: 600)

private func win(_ id: String, _ app: String, _ frame: Rect = start) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "", frame: frame, isMinimized: false)
}

@MainActor @Suite struct IntentLogTests {
    let clock = FakeClock()

    @Test func aHandMoveIsAnIntent() {
        let log = IntentLog(clock: clock)
        log.observe([win("w", "Warp")])
        clock.t = 5
        log.observe([win("w", "Warp", Rect(x: 900, y: 100, width: 800, height: 600))])
        #expect(log.pinned() == [WindowID("w")])
    }

    @Test func aHandResizeIsAnIntent() {
        let log = IntentLog(clock: clock)
        log.observe([win("w", "Warp")])
        log.observe([win("w", "Warp", Rect(x: 100, y: 100, width: 1400, height: 600))])
        #expect(log.pinned() == [WindowID("w")])
    }

    @Test func aMoveDeskmanMadeIsNotAnIntent() {
        let log = IntentLog(clock: clock)
        let control = IntentRecordingControl(FakeWindowControl(windows: [win("w", "Warp")], displays: [wide]), log: log)
        log.observe(control.windows())
        try? control.setFrame(Rect(x: 900, y: 100, width: 800, height: 600), of: WindowID("w"))
        log.observe([win("w", "Warp", Rect(x: 900, y: 100, width: 800, height: 600))])
        #expect(log.pinned().isEmpty)
        #expect(log.placedByDeskman([win("w", "Warp", Rect(x: 900, y: 100, width: 800, height: 600))]) == [WindowID("w")])
    }

    @Test func aReadOlderThanDeskmansMoveDoesNotPinTheWindow() {
        // 2026-10-12: a background read started before Smart Arrange moved the window and finished
        // after it. It showed the old place, then the next read the new one: the second change was
        // taken for the person's, and four windows Deskman placed were pinned.
        let log = IntentLog(clock: clock)
        let control = IntentRecordingControl(FakeWindowControl(windows: [win("w", "Warp")], displays: [wide]), log: log)
        log.observe(control.windows())
        let deskman = Rect(x: 900, y: 100, width: 800, height: 600)
        try? control.setFrame(deskman, of: WindowID("w"))
        log.observe([win("w", "Warp", deskman)])   // the copy, updated at once
        log.observe([win("w", "Warp")])            // the read that started before the move
        clock.t = 1
        log.observe([win("w", "Warp", deskman)])   // the next read
        #expect(log.pinned().isEmpty)
        #expect(log.placedByDeskman([win("w", "Warp", deskman)]) == [WindowID("w")])
    }

    @Test func anAppSettlingNearDeskmansPlaceIsNotAPin() {
        // 2026-10-12: three windows pinned 3 s after Smart Arrange, right after a restart. iTerm2 snaps
        // its size to whole text cells and Firefox lands late: a second, small change after Deskman's move.
        let log = IntentLog(clock: clock)
        let control = IntentRecordingControl(FakeWindowControl(windows: [win("w", "iTerm2")], displays: [wide]), log: log)
        log.observe(control.windows())
        let deskman = Rect(x: 900, y: 30, width: 1690, height: 1410)
        try? control.setFrame(deskman, of: WindowID("w"))
        log.observe([win("w", "iTerm2", deskman)])
        clock.t = 3
        log.observe([win("w", "iTerm2", Rect(x: 900, y: 30, width: 1683, height: 1394))])   // to the cell grid
        #expect(log.pinned().isEmpty)
    }

    @Test func aRealDragSoonAfterDeskmansMoveIsStillAPin() {
        let log = IntentLog(clock: clock)
        let control = IntentRecordingControl(FakeWindowControl(windows: [win("w", "iTerm2")], displays: [wide]), log: log)
        log.observe(control.windows())
        let deskman = Rect(x: 900, y: 30, width: 1690, height: 1410)
        try? control.setFrame(deskman, of: WindowID("w"))
        log.observe([win("w", "iTerm2", deskman)])
        clock.t = 3
        log.observe([win("w", "iTerm2", Rect(x: 2400, y: 30, width: 1690, height: 1410))])
        #expect(log.pinned() == [WindowID("w")])
    }

    @Test func unpinAllForgetsEveryPin() {
        let log = IntentLog(clock: clock)
        log.observe([win("w", "Warp")])
        log.observe([win("w", "Warp", Rect(x: 900, y: 100, width: 800, height: 600))])
        #expect(log.pinned() == [WindowID("w")])
        log.unpinAll()
        #expect(log.pinned().isEmpty)
    }

    @Test func aHandMoveAfterDeskmansMoveIsAnIntentAgain() {
        let log = IntentLog(clock: clock)
        let control = IntentRecordingControl(FakeWindowControl(windows: [win("w", "Warp")], displays: [wide]), log: log)
        log.observe(control.windows())
        let deskman = Rect(x: 900, y: 100, width: 800, height: 600)
        try? control.setFrame(deskman, of: WindowID("w"))
        log.observe([win("w", "Warp", deskman)])
        log.observe([win("w", "Warp", Rect(x: 2000, y: 100, width: 800, height: 600))])
        #expect(log.pinned() == [WindowID("w")])
        #expect(log.placedByDeskman([win("w", "Warp", Rect(x: 2000, y: 100, width: 800, height: 600))]).isEmpty)
    }

    @Test func aHandMoveAfterADeskmanMoveTheAppIgnoredIsAnIntent() {
        let log = IntentLog(clock: clock)
        let control = IntentRecordingControl(FakeWindowControl(windows: [win("w", "Warp")], displays: [wide]), log: log)
        log.observe(control.windows())
        try? control.setFrame(Rect(x: 900, y: 100, width: 800, height: 600), of: WindowID("w"))
        log.observe([win("w", "Warp")])                         // the app ignored the frame
        clock.t = 3
        let hand = Rect(x: 2000, y: 100, width: 800, height: 600)
        log.observe([win("w", "Warp", hand)])
        #expect(log.pinned() == [WindowID("w")])
        #expect(log.placedByDeskman([win("w", "Warp", hand)]).isEmpty)
    }

    @Test func aHandMoveAfterADeskmanMoveWithinJitterIsAnIntent() {
        let log = IntentLog(clock: clock)
        let control = IntentRecordingControl(FakeWindowControl(windows: [win("w", "Warp")], displays: [wide]), log: log)
        log.observe(control.windows())
        let near = Rect(x: 104, y: 100, width: 800, height: 600)
        try? control.setFrame(near, of: WindowID("w"))
        log.observe([win("w", "Warp", near)])
        clock.t = 3
        let hand = Rect(x: 2000, y: 100, width: 800, height: 600)
        log.observe([win("w", "Warp", hand)])
        #expect(log.pinned() == [WindowID("w")])
        #expect(log.placedByDeskman([win("w", "Warp", hand)]).isEmpty)
    }

    @Test func jitterIsNotAnIntent() {
        let log = IntentLog(clock: clock)
        log.observe([win("w", "Warp")])
        log.observe([win("w", "Warp", Rect(x: 103, y: 101, width: 800, height: 600))])
        #expect(log.pinned().isEmpty)
    }

    @Test func anIntentLastsThirtyMinutes() {
        let log = IntentLog(clock: clock)
        log.observe([win("w", "Warp")])
        log.observe([win("w", "Warp", Rect(x: 900, y: 100, width: 800, height: 600))])
        clock.t = 1799
        #expect(log.pinned() == [WindowID("w")])
        clock.t = 1801
        #expect(log.pinned().isEmpty)
    }

    @Test func aWindowSeenForTheFirstTimeIsNoIntent() {
        let log = IntentLog(clock: clock)
        log.observe([win("w", "Warp")])
        log.observe([win("w", "Warp"), win("n", "Notes", Rect(x: 3000, y: 100, width: 500, height: 500))])
        #expect(log.pinned().isEmpty)
    }
}

@Suite struct KeepClearTests {
    @Test func aZoneUnderAPinnedWindowIsNotUsed() {
        let layout = ZoneLayout(name: "Thirds", zones: (0..<3).map {
            Zone(label: "\($0)", rect: Rect(x: Double($0) / 3, y: 0, width: 1.0 / 3, height: 1))
        })
        let pinned = Rect(x: 0, y: 30, width: 1700, height: 1380)   // covers the left third
        let windows = [win("a", "A"), win("b", "B")]
        let p = ZonePlanner.plan(windows: windows, on: wide, layouts: [layout], named: nil, current: nil,
                                 keepClear: [pinned])!
        #expect(p.placements.allSatisfy { $0.frame.x > 1000 })
    }
}

@MainActor @Suite struct SmartArrangeIntentTests {
    @Test func aHandPlacedWindowStaysAndIsNeverParked() {
        let clock = FakeClock()
        let log = IntentLog(clock: clock)
        let focus = FocusTracker(clock: clock)
        let placed = Rect(x: 0, y: 30, width: 1700, height: 1380)
        let windows = [win("w", "Warp", placed), win("f", "Firefox"), win("c", "Calendar")]
        log.observe([win("w", "Warp"), win("f", "Firefox"), win("c", "Calendar")])
        log.observe(windows)                                    // Warp moved by hand
        for t in 0..<70 { clock.t = Double(t * 5); focus.record(app: "Firefox") }   // Warp never in front
        let fake = FakeWindowControl(windows: windows, displays: [wide], frontmost: WindowID("f"))
        let service = WindowService(control: fake, history: nil, focus: focus, intents: log, launchWait: .zero)
        let outcome = service.smartArrange(biggest: nil)
        #expect(!fake.frames.contains { $0.0 == WindowID("w") })
        #expect(!fake.actions.contains { $0.1 == WindowID("w") })
        #expect(fake.frames.allSatisfy { $0.1.x >= 1700 - 1 || $0.1.maxX <= 0 })
        #expect(outcome.message.contains("Kept Warp"))
    }
}

@Suite struct LearningIgnoresDeskmansOwnMovesTests {
    private let screen = Display(index: 0, visibleFrame: Rect(x: 0, y: 25, width: 1440, height: 875))

    @Test func aPlacementDeskmanMadeIsNoEvidence() {
        let left = Layout.leftHalf.frame(in: screen.visibleFrame)
        let history = (0..<5).map { i in
            DeskSnapshot(time: Double(i), windows: [win("t", "Terminal", left)], displays: [screen],
                         focusedApp: nil, placedByDeskman: [WindowID("t")])
        }
        #expect(Learner.habits(in: history).isEmpty)
    }

    @Test func oldRecordsWithoutTheMarkStillDecode() throws {
        let json = #"{"time":1,"displayCount":1,"focusedApp":null,"windows":[{"app":"A","title":"","isMinimized":false,"placement":{"display":0,"rect":{"x":0,"y":0,"width":0.5,"height":1}}}]}"#
        let s = try JSONDecoder().decode(DeskSnapshot.self, from: Data(json.utf8))
        #expect(s.windows.first?.byDeskman == nil)
        #expect(Learner.habits(in: [s, s, s]).first?.isLearned == true)
    }
}
