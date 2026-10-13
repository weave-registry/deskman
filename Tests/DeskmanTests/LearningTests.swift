import Testing
import DeskmanDomain

private let main = Display(index: 0, visibleFrame: Rect(x: 0, y: 25, width: 1440, height: 875))
private let side = Display(index: 1, visibleFrame: Rect(x: 1440, y: 0, width: 1920, height: 1080))

private func w(_ id: String, _ app: String, _ title: String = "", _ frame: Rect, minimized: Bool = false) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: title, frame: frame, isMinimized: minimized)
}

private let left23 = Layout.leftTwoThirds.frame(in: main.visibleFrame)
private let right13 = Layout.rightThird.frame(in: main.visibleFrame)
private let middle = Layout.center.frame(in: main.visibleFrame)

/// `n` past sightings of Xcode on the left two-thirds and Simulator on the right third.
private func history(_ n: Int, xcode: Rect = left23, at start: Double = 0) -> [DeskSnapshot] {
    (0..<n).map { i in
        DeskSnapshot(time: start + Double(i) * 3600,
                     windows: [w("x", "Xcode", "Deskman", xcode), w("s", "Simulator", "iPhone", right13)],
                     displays: [main], focusedApp: "Xcode")
    }
}

@Suite struct PlacementTests {
    @Test func aLayoutFrameSurvivesTheRoundTrip() {
        for layout in Layout.allCases {
            let frame = layout.frame(in: main.visibleFrame)
            let p = Placement.of(frame, on: main)
            #expect(p.display == 0)
            let back = p.frame(on: main)
            #expect(abs(back.x - frame.x) < 0.5 && abs(back.width - frame.width) < 0.5)
        }
    }

    @Test func smallDifferencesRoundToTheSamePlacement() {
        let nudged = Rect(x: left23.x + 6, y: left23.y + 4, width: left23.width - 8, height: left23.height)
        #expect(Placement.of(nudged, on: main) == Placement.of(left23, on: main))
    }

    @Test func aPlacementMapsOntoAnotherDisplaySize() {
        let p = Placement.of(Layout.rightHalf.frame(in: main.visibleFrame), on: main)
        #expect(p.frame(on: side) == Layout.rightHalf.frame(in: side.visibleFrame))
    }
}

@Suite struct LearnerTests {
    @Test func noHistoryMeansNoSuggestion() {
        let now = [w("x", "Xcode", "", middle), w("s", "Simulator", "", right13)]
        #expect(Learner.suggestion(for: now, displays: [main], history: []) == nil)
    }

    @Test func aConfirmedPlaceOnANegativeDisplayIsSkippedNotACrash() {
        let now = [w("x", "Xcode", "", middle)]
        let bad = ["Xcode": Placement(display: -1, rect: Rect(x: 0, y: 0, width: 0.5, height: 1))]
        #expect(Learner.suggestion(for: now, displays: [main], history: [], confirmed: bad) == nil)
    }

    @Test func threeSightingsTeachAPlacementAndOnlyMisplacedWindowsMove() throws {
        let now = [w("x", "Xcode", "", middle), w("s", "Simulator", "", right13)]
        let s = try #require(Learner.suggestion(for: now, displays: [main], history: history(3)))
        #expect(s.moves.count == 1)
        #expect(s.moves[0].id == WindowID("x"))
        #expect(s.moves[0].from == middle)
        let to = s.moves[0].to
        #expect(abs(to.x - left23.x) < 0.5 && abs(to.width - left23.width) < 0.5)
        #expect(s.evidence >= 3)
    }

    @Test func twoSightingsAreNotEnough() {
        let now = [w("x", "Xcode", "", middle), w("s", "Simulator", "", right13)]
        #expect(Learner.suggestion(for: now, displays: [main], history: history(2)) == nil)
    }

    @Test func anInconsistentHabitIsNotLearned() {
        // Xcode was left 2 times and centered 2 times: 50%, under the 60% floor.
        let mixed = history(2) + history(2, xcode: middle, at: 100_000)
        let now = [w("x", "Xcode", "", right13), w("s", "Simulator", "", right13)]
        let s = Learner.suggestion(for: now, displays: [main], history: mixed)
        #expect(s?.moves.contains { $0.id == WindowID("x") } != true)
    }

    @Test func everythingInPlaceMeansNoSuggestion() {
        let now = [w("x", "Xcode", "", left23), w("s", "Simulator", "", right13)]
        #expect(Learner.suggestion(for: now, displays: [main], history: history(5)) == nil)
    }

    @Test func aDifferentDisplaySetupIsADifferentSituation() {
        let now = [w("x", "Xcode", "", middle), w("s", "Simulator", "", right13)]
        #expect(Learner.suggestion(for: now, displays: [main, side], history: history(5)) == nil)
    }

    @Test func anUnrelatedSetOfAppsIsADifferentSituation() {
        let now = [w("x", "Xcode", "", middle), w("m", "Mail", "", right13), w("n", "Notes", "", right13)]
        // {Xcode, Mail, Notes} vs {Xcode, Simulator}: Jaccard 1/4.
        #expect(Learner.suggestion(for: now, displays: [main], history: history(5)) == nil)
    }

    @Test func minimizedWindowsAreNeitherContextNorMoved() {
        let now = [w("x", "Xcode", "", middle), w("s", "Simulator", "", right13),
                   w("m", "Music", "", middle, minimized: true)]
        let s = Learner.suggestion(for: now, displays: [main], history: history(3))
        #expect(s?.context.apps == ["Simulator", "Xcode"])
        #expect(s?.moves.map(\.id) == [WindowID("x")])
    }

    @Test func titlesTellTwoWindowsOfOneAppApart() throws {
        let leftHalf = Layout.leftHalf.frame(in: main.visibleFrame)
        let rightHalf = Layout.rightHalf.frame(in: main.visibleFrame)
        let past = (0..<3).map { i in
            DeskSnapshot(time: Double(i) * 3600, windows: [
                w("a", "Code", "main.swift — deskman", leftHalf),
                w("b", "Code", "index.ts — website", rightHalf),
            ], displays: [main], focusedApp: "Code")
        }
        // Both windows are now in the wrong halves, with different files open.
        let now = [w("p", "Code", "README.md — deskman", rightHalf), w("q", "Code", "app.ts — website", leftHalf)]
        let s = try #require(Learner.suggestion(for: now, displays: [main], history: past))
        let toP = try #require(s.moves.first { $0.id == WindowID("p") }).to
        let toQ = try #require(s.moves.first { $0.id == WindowID("q") }).to
        #expect(abs(toP.x - leftHalf.x) < 0.5)
        #expect(abs(toQ.x - rightHalf.x) < 0.5)
    }

    @Test(arguments: [
        ("README.md — deskman", "deskman"),
        ("Inbox - Mail", "mail"),
        ("Apple", nil),
        ("", nil),
    ] as [(String, String?)])
    func theQualifierIsTheTitlesLastSegment(title: String, expected: String?) {
        #expect(Learner.qualifier(title) == expected)
    }
}

@Suite struct TrustLedgerTests {
    let ctx = ContextKey(apps: ["Simulator", "Xcode"], displays: 1)

    @Test func threeAcceptsMakeAContextAutomatic() {
        var ledger = TrustLedger()
        ledger.recordAccept(ctx)
        ledger.recordAccept(ctx)
        #expect(!ledger.isAutomatic(ctx))
        ledger.recordAccept(ctx)
        #expect(ledger.isAutomatic(ctx))
    }

    @Test func aDismissalResetsTrustAndSnoozesForAnHour() {
        var ledger = TrustLedger()
        for _ in 0..<3 { ledger.recordAccept(ctx) }
        ledger.recordDismiss(ctx, now: 1000)
        #expect(!ledger.isAutomatic(ctx))
        #expect(ledger.isSnoozed(ctx, now: 1000 + 3599))
        #expect(!ledger.isSnoozed(ctx, now: 1000 + 3601))
    }

    @Test func contextsAreIndependent() {
        var ledger = TrustLedger()
        for _ in 0..<3 { ledger.recordAccept(ctx) }
        #expect(!ledger.isAutomatic(ContextKey(apps: ["Mail"], displays: 1)))
    }

    @Test func contextKeysIgnoreOrder() {
        #expect(ContextKey(apps: ["B", "A"], displays: 1) == ContextKey(apps: ["A", "B"], displays: 1))
    }
}
