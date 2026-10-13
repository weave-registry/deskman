import Testing
import DeskmanPorts
import DeskmanUseCases

private let main = Display(index: 0, visibleFrame: Rect(x: 0, y: 25, width: 1440, height: 875))
private let left23 = Layout.leftTwoThirds.frame(in: main.visibleFrame)
private let right13 = Layout.rightThird.frame(in: main.visibleFrame)
private let middle = Layout.center.frame(in: main.visibleFrame)

private func w(_ id: String, _ app: String, _ frame: Rect) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "", frame: frame, isMinimized: false)
}

private let usual = [w("x", "Xcode", left23), w("s", "Simulator", right13)]
private let misplaced = [w("x", "Xcode", middle), w("s", "Simulator", right13)]
private let ctx = ContextKey(apps: ["Simulator", "Xcode"], displays: 1)

@MainActor @Suite struct ActivityServiceTests {
    let clock = FakeClock()
    let store = InMemoryActivityStore()

    func make(_ windows: [WindowSnapshot]) -> (ActivityService, FakeWindowControl) {
        let control = FakeWindowControl(windows: windows, displays: [main])
        let service = ActivityService(control: control, store: store, clock: clock,
                                      settleSeconds: 30, suggestDelay: 5)
        return (service, control)
    }

    func learned(_ n: Int = 3) {
        for i in 0..<n {
            try? store.append(DeskSnapshot(time: Double(i) * 3600 - 100_000, windows: usual,
                                           displays: [main], focusedApp: nil))
        }
    }

    @Test func anArrangementIsRecordedOnceAfterItSettles() {
        let (service, control) = make(usual)
        clock.t = 0; _ = service.tick()
        clock.t = 20; _ = service.tick()
        #expect(store.records.isEmpty)
        clock.t = 31; _ = service.tick()
        #expect(store.records.count == 1)
        clock.t = 90; _ = service.tick()
        #expect(store.records.count == 1)

        control.windowList = misplaced
        clock.t = 100; _ = service.tick()
        clock.t = 125; _ = service.tick()
        #expect(store.records.count == 1)
        clock.t = 131; _ = service.tick()
        #expect(store.records.count == 2)
    }

    @Test func aFailedSnapshotWriteIsTriedAgain() {
        let (service, _) = make(usual)
        store.failingAppends = 1
        clock.t = 0; _ = service.tick()
        clock.t = 31; _ = service.tick()
        #expect(store.records.isEmpty)
        clock.t = 36; _ = service.tick()
        #expect(store.records.count == 1)
        clock.t = 90; _ = service.tick()
        #expect(store.records.count == 1)
    }

    @Test func aKnownSituationGetsASuggestionAfterTheDelay() {
        learned()
        let (service, _) = make(misplaced)
        clock.t = 0
        #expect(service.tick() == .idle)
        clock.t = 6
        guard case .suggested(let s) = service.tick() else { Issue.record("no suggestion"); return }
        #expect(s.moves.map(\.id) == [WindowID("x")])
        #expect(service.pending == s)
        clock.t = 12
        #expect(service.tick() == .idle)   // one suggestion per situation
    }

    @Test func acceptingAppliesTheMovesAndEarnsTrust() {
        learned()
        let (service, control) = make(misplaced)
        clock.t = 0; _ = service.tick()
        clock.t = 6; _ = service.tick()
        #expect(service.accept().succeeded)
        #expect(control.frames.count == 1)
        #expect(control.frames[0].0 == WindowID("x"))
        #expect(store.savedLedger.accepts[ctx.id] == 1)
        #expect(service.pending == nil)
    }

    @Test func aTrustedSituationIsArrangedAutomaticallyAndCanBeUndone() {
        learned()
        var ledger = TrustLedger()
        for _ in 0..<3 { ledger.recordAccept(ctx) }
        try? store.save(ledger)
        let (service, control) = make(misplaced)
        clock.t = 0; _ = service.tick()
        clock.t = 6
        guard case .autoApplied = service.tick() else { Issue.record("not automatic"); return }
        #expect(control.frames.count == 1)

        #expect(service.undo().succeeded)
        #expect(control.frames.count == 2)
        #expect(control.frames[1].1 == middle)          // back where it was
        #expect(!store.savedLedger.isAutomatic(ctx))    // undo costs the trust
    }

    @Test func aDismissedSituationIsQuietForAnHour() {
        learned()
        let (service, control) = make(misplaced)
        clock.t = 0; _ = service.tick()
        clock.t = 6; _ = service.tick()
        service.dismiss()
        #expect(service.pending == nil)

        control.windowList = [w("m", "Mail", middle)]   // leave the situation...
        clock.t = 10; _ = service.tick()
        clock.t = 20; _ = service.tick()
        control.windowList = misplaced                  // ...and come back
        clock.t = 30; _ = service.tick()
        clock.t = 40
        #expect(service.tick() == .idle)
        #expect(control.frames.isEmpty)
    }

    @Test func aLedgerThatCannotBeSavedIsReportedOnAcceptDismissAndUndo() {
        learned()
        let (service, _) = make(misplaced)
        clock.t = 0; _ = service.tick()
        clock.t = 6; _ = service.tick()
        store.failingSaves = 1
        let accepted = service.accept()
        #expect(accepted.succeeded)                         // the window did move...
        #expect(accepted.message.contains("could not save"))  // ...but the person hears the trust is lost
        #expect(store.savedLedger.accepts[ctx.id] == nil)

        store.failingSaves = 1
        let undone = service.undo()
        #expect(undone.message.contains("could not save"))

        let (again, _) = make(misplaced)
        clock.t = 100; _ = again.tick()
        clock.t = 106; _ = again.tick()
        store.failingSaves = 1
        let dismissed = again.dismiss()
        #expect(!dismissed.succeeded)
        #expect(dismissed.message.contains("could not save"))
        #expect(!store.savedLedger.isSnoozed(ctx, now: clock.now()))
    }

    @Test func pausedMeansNothingIsRecordedOrSuggested() {
        learned()
        let (service, _) = make(misplaced)
        service.isPaused = true
        let before = store.records.count
        for t in stride(from: 0.0, through: 100, by: 5) {
            clock.t = t
            #expect(service.tick() == .idle)
        }
        #expect(store.records.count == before)
    }

    @Test func forgetErasesTheHistoryAndTheTrust() {
        learned()
        let (service, _) = make(misplaced)
        #expect(service.recordCount == 3)
        #expect(service.forget().succeeded)
        #expect(store.records.isEmpty)
        #expect(service.recordCount == 0)
        #expect(store.savedLedger == TrustLedger())
    }

    @Test func undoingSmartArrangeLeavesTheLearnedTrustAlone() {
        var ledger = TrustLedger()
        for _ in 0..<3 { ledger.recordAccept(ctx) }
        try? store.save(ledger)
        let control = FakeWindowControl(windows: misplaced, displays: [main], frontmost: WindowID("x"))
        let service = ActivityService(control: control, store: store, clock: clock,
                                      arranger: SmartArranger(control: control, history: store))
        #expect(service.smartArrange().succeeded)
        #expect(service.lastApplied?.context == ctx)    // the same situation the person trusts
        #expect(service.undo().succeeded)
        #expect(store.savedLedger.isAutomatic(ctx))
        #expect(!store.savedLedger.isSnoozed(ctx, now: clock.now()))
    }

    @Test func anUndoThatCannotMoveTheWindowsBackFailsAndCanBeTriedAgain() {
        learned()
        var ledger = TrustLedger()
        for _ in 0..<3 { ledger.recordAccept(ctx) }
        try? store.save(ledger)
        let (service, control) = make(misplaced)
        clock.t = 0; _ = service.tick()
        clock.t = 6
        guard case .autoApplied = service.tick() else { Issue.record("not automatic"); return }

        control.setFrameError = FakeError(description: "Accessibility was turned off")
        let failed = service.undo()
        #expect(!failed.succeeded)                      // the person hears the truth
        #expect(failed.message.contains("Accessibility was turned off"))
        #expect(store.savedLedger.isAutomatic(ctx))     // an undo that did not happen costs no trust

        control.setFrameError = nil
        #expect(service.undo().succeeded)               // the original frame was kept for a second try
        #expect(control.frames.last?.1 == middle)
        #expect(!store.savedLedger.isAutomatic(ctx))
    }

    @Test func undoWithNothingToUndoFails() {
        let (service, _) = make(usual)
        #expect(!service.undo().succeeded)
    }
}
