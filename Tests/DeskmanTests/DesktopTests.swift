import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2610101429: windows on other desktops are listed, named, and focusable,
// but never moved, tiled, or learned from — their frames are not on screen.

private let screen = Display(index: 0, visibleFrame: Rect(x: 0, y: 25, width: 1440, height: 875))
private let left = Rect(x: 0, y: 25, width: 720, height: 875)
private let right = Rect(x: 720, y: 25, width: 720, height: 875)

private func here(_ id: String, _ app: String, _ frame: Rect = left, minimized: Bool = false) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "\(app) window", frame: frame, isMinimized: minimized,
                   desktop: 1, isOnCurrentDesktop: true)
}

/// A window on desktop `n`. Its frame overlaps the current screen, as real ones do.
private func away(_ id: String, _ app: String, desktop n: Int? = 2, _ frame: Rect = left) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "\(app) window", frame: frame, isMinimized: false,
                   desktop: n, isOnCurrentDesktop: false)
}

@Suite struct WindowSnapshotDesktopTests {
    @Test func aWindowIsVisibleOnlyWhenOnTheCurrentDesktopAndNotMinimized() {
        #expect(here("a", "A").isVisible)
        #expect(!here("a", "A", minimized: true).isVisible)
        #expect(!away("b", "B").isVisible)
    }

    @Test func theOldInitializerMeansTheCurrentDesktop() {
        let w = WindowSnapshot(id: WindowID("a"), app: "A", title: "", frame: left, isMinimized: false)
        #expect(w.isOnCurrentDesktop)
        #expect(w.desktop == nil)
    }
}

@Suite struct TargetMatcherDesktopTests {
    @Test func aVisibleWindowBeatsTheSameAppOnAnotherDesktop() {
        let windows = [away("far", "Safari"), here("near", "Safari")]
        #expect(TargetMatcher.resolve("safari", in: windows, frontmost: nil) == .window(windows[1]))
    }

    @Test func aMinimizedWindowHereBeatsOneOnAnotherDesktop() {
        let windows = [away("far", "Safari"), here("near", "Safari", minimized: true)]
        #expect(TargetMatcher.resolve("safari", in: windows, frontmost: nil) == .window(windows[1]))
    }

    @Test func aWindowOnlyOnAnotherDesktopIsStillFound() {
        let windows = [here("n", "Notes"), away("s", "Slack", desktop: 3)]
        #expect(TargetMatcher.resolve("slack", in: windows, frontmost: nil) == .window(windows[1]))
    }
}

@MainActor @Suite struct WindowServiceDesktopTests {
    func make(_ windows: [WindowSnapshot]) -> (WindowService, FakeWindowControl) {
        let control = FakeWindowControl(windows: windows, displays: [screen])
        return (WindowService(control: control, launchWait: .zero), control)
    }

    @Test func listingIncludesWindowsOnEveryDesktop() {
        let (service, _) = make([here("n", "Notes"), away("s", "Slack", desktop: 3)])
        #expect(service.listWindows().map(\.app) == ["Notes", "Slack"])
    }

    @Test func focusReachesAWindowOnAnotherDesktop() {
        let (service, control) = make([away("s", "Slack", desktop: 3)])
        let outcome = service.act(.focus, on: "slack")
        #expect(outcome.succeeded)
        #expect(control.actions.map(\.0) == [.focus])
        #expect(control.actions.map(\.1) == [WindowID("s")])
    }

    @Test func otherActionsOnAnotherDesktopFailAndNameTheDesktop() {
        let (service, control) = make([away("s", "Slack", desktop: 3)])
        for action in WindowAction.allCases where action != .focus {
            let outcome = service.act(action, on: "slack")
            #expect(!outcome.succeeded)
            #expect(outcome.message.contains("desktop 3"))
        }
        #expect(control.actions.isEmpty)
    }

    @Test func arrangeOnAnotherDesktopFailsWithoutMovingAnything() {
        let (service, control) = make([away("s", "Slack", desktop: 2)])
        let outcome = service.arrange("slack", layout: .rightHalf)
        #expect(!outcome.succeeded)
        #expect(outcome.message.contains("desktop 2"))
        #expect(control.frames.isEmpty)
    }

    @Test func anUnknownDesktopIsCalledAnotherDesktop() {
        let (service, _) = make([away("s", "Slack", desktop: nil)])
        let outcome = service.arrange("slack", layout: .rightHalf)
        #expect(!outcome.succeeded)
        #expect(outcome.message.contains("another desktop"))
    }

    @Test func moveToNextDisplayOnAnotherDesktopFails() {
        let control = FakeWindowControl(
            windows: [away("s", "Slack")],
            displays: [screen, Display(index: 1, visibleFrame: Rect(x: 1440, y: 0, width: 1920, height: 1080))])
        let outcome = WindowService(control: control, launchWait: .zero).moveToNextDisplay("slack")
        #expect(!outcome.succeeded)
        #expect(control.frames.isEmpty)
    }

    @Test func tileAllLeavesOutWindowsOnOtherDesktops() {
        let (service, control) = make([here("n", "Notes", left), away("s", "Slack", left), here("m", "Mail", right)])
        _ = service.tile(apps: [])
        #expect(Set(control.frames.map(\.0)) == [WindowID("n"), WindowID("m")])
    }

    @Test func tileNamedSaysWhichAppsAreOnAnotherDesktop() {
        let (service, control) = make([here("n", "Notes"), away("s", "Slack", desktop: 2), here("m", "Mail", right)])
        let outcome = service.tile(apps: ["Notes", "Slack", "Mail"])
        #expect(outcome.succeeded)
        #expect(Set(control.frames.map(\.0)) == [WindowID("n"), WindowID("m")])
        #expect(outcome.message.contains("Slack"))
        #expect(outcome.message.contains("another desktop"))
    }

    @Test func tileNamedPrefersTheWindowHereWhenTheAppIsOnBoth() {
        let (service, control) = make([away("s2", "Safari"), here("s1", "Safari"), here("m", "Mail", right)])
        _ = service.tile(apps: ["Safari", "Mail"])
        #expect(Set(control.frames.map(\.0)) == [WindowID("s1"), WindowID("m")])
    }
}

@Suite struct LearningDesktopTests {
    @Test func aSnapshotRecordsOnlyTheCurrentDesktop() {
        let snap = DeskSnapshot(time: 0, windows: [here("n", "Notes"), away("s", "Slack")],
                                displays: [screen], focusedApp: "Notes")
        #expect(snap.windows.map(\.app) == ["Notes"])
        #expect(snap.context.apps == ["Notes"])
    }

    @Test func theLearnerNeverMovesAWindowOnAnotherDesktop() {
        // Slack habitually sits on the right half; today it is on desktop 2, its frame on the left.
        let history = (0..<5).map { i in
            DeskSnapshot(time: Double(i) * 3600, windows: [here("n", "Notes", left), here("s", "Slack", right)],
                         displays: [screen], focusedApp: "Notes")
        }
        let now = [here("n", "Notes", left), away("s", "Slack", left)]
        let suggestion = Learner.suggestion(for: now, displays: [screen], history: history,
                                            minSimilarity: 0)
        #expect(suggestion?.moves.contains { $0.app == "Slack" } != true)
    }
}
