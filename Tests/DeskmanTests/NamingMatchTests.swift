import Testing
import DeskmanPorts

// 2026-10-12, the map: "Naming paused: the model gave 2 names for 1 windows". The answer was
// thrown away, and the same window was asked again every few seconds. Each answer carries
// the window's number: that is what matches it, not the count.

@Suite struct NamingMatchTests {
    @Test func anExtraAnswerForOneWindowIsDropped() {
        #expect(NamedWindow.match(numbers: [1, 1], count: 1) == [0])
    }

    @Test func anAnswerForAWindowNotAskedAboutIsDropped() {
        #expect(NamedWindow.match(numbers: [1, 2, 3], count: 2) == [0, 1])
    }

    @Test func answersOutOfOrderAreMatchedByNumber() {
        #expect(NamedWindow.match(numbers: [2, 1], count: 2) == [1, 0])
    }

    @Test func numbersFromZeroAreShifted() {
        #expect(NamedWindow.match(numbers: [0, 1, 1], count: 2) == [0, 1])
    }

    @Test func unusableNumbersFallBackToOrderWhenTheCountIsRight() {
        #expect(NamedWindow.match(numbers: [7, 7], count: 2) == [0, 1])
    }

    @Test func aMissingWindowCannotBeMatched() {
        // Fewer answers than windows, and no number for window 2: nothing is safe to match.
        #expect(NamedWindow.match(numbers: [1], count: 2) == nil)
        #expect(NamedWindow.match(numbers: [], count: 1) == nil)
        // Two answers both numbered 1 for two windows: the order is all there is, as before.
        #expect(NamedWindow.match(numbers: [1, 1], count: 2) == [0, 1])
    }
}
