import Testing
import DeskmanPorts
import DeskmanUseCases

// What Deskman learned, shown to the person, and "arrange like usual" on request.

private let screen = Display(index: 0, visibleFrame: Rect(x: 0, y: 25, width: 1440, height: 875))
private let left = Layout.leftHalf.frame(in: screen.visibleFrame)
private let right = Layout.rightThird.frame(in: screen.visibleFrame)
private let middle = Layout.center.frame(in: screen.visibleFrame)

private func w(_ id: String, _ app: String, _ frame: Rect, minimized: Bool = false) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "", frame: frame, isMinimized: minimized)
}

private func seen(_ windows: [WindowSnapshot], times n: Int, from start: Double = 0) -> [DeskSnapshot] {
    (0..<n).map { DeskSnapshot(time: start + Double($0), windows: windows, displays: [screen], focusedApp: nil) }
}

@Suite struct HabitTests {
    @Test func aHabitIsTheMostFrequentPlaceWithItsCounts() {
        let history = seen([w("t", "Terminal", left)], times: 4) + seen([w("t", "Terminal", middle)], times: 1)
        let habits = Learner.habits(in: history)
        #expect(habits.count == 1)
        let h = habits[0]
        #expect(h.app == "Terminal")
        #expect(h.support == 4)
        #expect(h.sightings == 5)
        #expect(h.isLearned)
        #expect(h.placement.phrase == "the left half")
    }

    @Test func tooFewSightingsIsStillLearning() {
        let habits = Learner.habits(in: seen([w("n", "Notes", right)], times: 2))
        #expect(habits.map(\.isLearned) == [false])
    }

    @Test func aSplitHabitIsNotLearned() {
        let history = seen([w("n", "Notes", left)], times: 3) + seen([w("n", "Notes", middle)], times: 3)
        #expect(Learner.habits(in: history).map(\.isLearned) == [false])
    }

    @Test func minimizedSightingsDoNotCount() {
        let history = seen([w("n", "Notes", left, minimized: true)], times: 5)
        #expect(Learner.habits(in: history).isEmpty)
    }

    @Test func learnedHabitsComeFirstThenTheMostSeen() {
        let history = seen([w("a", "A", left), w("b", "B", right)], times: 3)
            + seen([w("c", "C", middle)], times: 2) + seen([w("c", "C", left)], times: 2)
        #expect(Learner.habits(in: history).map(\.app) == ["A", "B", "C"])
    }

    @Test func everyLayoutHasItsOwnPhrase() {
        for layout in Layout.allCases {
            #expect(Placement.of(layout.frame(in: screen.visibleFrame), on: screen).phrase == layout.phrase)
        }
    }

    @Test func aPlaceThatIsNoLayoutIsDescribedBySize() {
        let odd = Rect(x: 100, y: 100, width: 720, height: 437.5)
        #expect(Placement.of(odd, on: screen).phrase == "a spot 50% wide, 50% tall")
    }

    @Test func aPlaceOneGridStepOffALayoutTakesItsName() {
        // A terminal one row short of the full height, as macOS often leaves it.
        let short = Placement(display: 0, rect: Rect(x: 40.0 / 60, y: 0, width: 20.0 / 60, height: 59.0 / 60))
        #expect(short.phrase == "the right third")
        let far = Placement(display: 0, rect: Rect(x: 40.0 / 60, y: 0, width: 20.0 / 60, height: 57.0 / 60))
        #expect(far.phrase == "a spot 33% wide, 95% tall")
    }

    @Test func aSecondDisplayIsNamed() {
        let side = Display(index: 1, visibleFrame: Rect(x: 1440, y: 0, width: 1920, height: 1080))
        #expect(Placement.of(Layout.leftHalf.frame(in: side.visibleFrame), on: side).phrase
                == "the left half of display 2")
    }
}

@MainActor @Suite struct HabitStoreTests {
    let store = InMemoryActivityStore()

    func make(_ windows: [WindowSnapshot]) -> (ActivityService, FakeWindowControl) {
        let control = FakeWindowControl(windows: windows, displays: [screen])
        return (ActivityService(control: control, store: store, clock: FakeClock()), control)
    }

    @Test func habitsAreReadFromTheStore() {
        for s in seen([w("t", "Terminal", left)], times: 3) { try? store.append(s) }
        let (service, _) = make([])
        #expect(service.habits().map(\.app) == ["Terminal"])
    }
}
