import Foundation
import Testing
import DeskmanPorts
import DeskmanUseCases

// Clicking a red (still learning) place on the map means "I like that" (ADR-2610101523 §4).

private let screen = Display(index: 0, visibleFrame: Rect(x: 0, y: 25, width: 1440, height: 875))
private let left = Layout.leftHalf.frame(in: screen.visibleFrame)
private let middle = Layout.center.frame(in: screen.visibleFrame)

private func w(_ app: String, _ frame: Rect) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(app), app: app, title: "", frame: frame, isMinimized: false)
}

@Suite struct ConfirmedHabitTests {
    @Test func aConfirmedPlaceIsLearnedAtOnce() {
        let once = [DeskSnapshot(time: 0, windows: [w("Notes", left)], displays: [screen], focusedApp: nil)]
        var ledger = TrustLedger()
        ledger.confirm(app: "Notes", placement: .of(left, on: screen))
        let habits = Learner.habits(in: once, confirmed: ledger.confirmedPlaces)
        #expect(habits.map(\.isLearned) == [true])
        #expect(habits[0].isConfirmed)
    }

    @Test func aConfirmedPlaceDrivesSuggestions() {
        var ledger = TrustLedger()
        ledger.confirm(app: "Notes", placement: .of(left, on: screen))
        let s = Learner.suggestion(for: [w("Notes", middle)], displays: [screen], history: [],
                                   confirmed: ledger.confirmedPlaces, minSimilarity: 0)
        #expect(s?.moves.map(\.to) == [left])
    }

    @Test func anOldLedgerWithoutConfirmationsStillDecodes() throws {
        let json = #"{"accepts":{"1|A":2},"snoozedUntil":{}}"#
        let ledger = try JSONDecoder().decode(TrustLedger.self, from: Data(json.utf8))
        #expect(ledger.confirmedPlaces.isEmpty)
        #expect(ledger.accepts["1|A"] == 2)
    }

    @Test func confirmationsSurviveTheRoundTrip() throws {
        var ledger = TrustLedger()
        ledger.confirm(app: "Notes", placement: .of(left, on: screen))
        let back = try JSONDecoder().decode(TrustLedger.self, from: JSONEncoder().encode(ledger))
        #expect(back == ledger)
    }
}

@MainActor @Suite struct ConfirmServiceTests {
    @Test func confirmingPersistsAndShowsAsLearned() {
        let store = InMemoryActivityStore()
        try? store.append(DeskSnapshot(time: 0, windows: [w("Notes", left)], displays: [screen], focusedApp: nil))
        let control = FakeWindowControl(windows: [w("Notes", left)], displays: [screen])
        let service = ActivityService(control: control, store: store, clock: FakeClock())
        let habit = service.habits()[0]
        #expect(!habit.isLearned)
        #expect(service.confirm(habit).succeeded)
        #expect(service.habits()[0].isLearned)
        #expect(store.savedLedger.confirmedPlaces["Notes"] == habit.placement)
    }

    @Test func aConfirmThatCannotSaveDoesNotTakeEffect() {
        let store = InMemoryActivityStore()
        let windows = [w("Notes", left), w("Mail", middle)]
        try? store.append(DeskSnapshot(time: 0, windows: windows, displays: [screen], focusedApp: nil))
        let control = FakeWindowControl(windows: windows, displays: [screen])
        let service = ActivityService(control: control, store: store, clock: FakeClock())
        let notes = service.habits().first { $0.app == "Notes" }!
        let mail = service.habits().first { $0.app == "Mail" }!
        store.failingSaves = 1
        #expect(!service.confirm(notes).succeeded)
        // Told it failed, so this session must not act on it.
        #expect(service.habits().first { $0.app == "Notes" }?.isLearned == false)
        // And the next save, for something else, must not write it to disk.
        #expect(service.confirm(mail).succeeded)
        #expect(store.savedLedger.confirmedPlaces.keys.sorted() == ["Mail"])
    }
}
