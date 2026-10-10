import Testing
import DeskmanDomain

private func window(_ id: String, _ app: String, _ title: String, minimized: Bool = false) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: title,
                   frame: Rect(x: 0, y: 0, width: 100, height: 100), isMinimized: minimized)
}

private let windows = [
    window("1", "Safari", "Apple"),
    window("2", "Notes", "Shopping list"),
    window("3", "Visual Studio Code", "README.md — deskman"),
    window("4", "Safari", "Safari settings"),
    window("5", "Terminal", "zsh", minimized: true),
]

@Suite struct TargetMatcherTests {
    @Test(arguments: ["front", "this", "current", "active", "focused", "", "  This Window "])
    func frontAliasesPickTheFrontmostWindow(query: String) {
        #expect(TargetMatcher.resolve(query, in: windows, frontmost: WindowID("2")) == .window(windows[1]))
    }

    @Test func frontWithNoFrontmostWindowIsNotFound() {
        #expect(TargetMatcher.resolve("front", in: windows, frontmost: nil) == .notFound)
    }

    @Test func appNameIsCaseInsensitive() {
        #expect(TargetMatcher.resolve("notes", in: windows, frontmost: nil) == .window(windows[1]))
    }

    @Test func anExactAppNameBeatsATitleThatContainsIt() {
        // Window 4's title contains "Safari", but window 1 is the first Safari window.
        #expect(TargetMatcher.resolve("Safari", in: windows, frontmost: nil) == .window(windows[0]))
    }

    @Test func theFrontmostWindowWinsATie() {
        #expect(TargetMatcher.resolve("safari", in: windows, frontmost: WindowID("4")) == .window(windows[3]))
    }

    @Test func aPartialAppNameMatches() {
        #expect(TargetMatcher.resolve("vs code", in: windows, frontmost: nil) == .notFound)
        #expect(TargetMatcher.resolve("visual studio", in: windows, frontmost: nil) == .window(windows[2]))
    }

    @Test func aTitleFragmentMatches() {
        #expect(TargetMatcher.resolve("shopping", in: windows, frontmost: nil) == .window(windows[1]))
        #expect(TargetMatcher.resolve("readme", in: windows, frontmost: nil) == .window(windows[2]))
    }

    @Test func aQueryThatWrapsTheAppNameMatches() {
        #expect(TargetMatcher.resolve("the notes window", in: windows, frontmost: nil) == .window(windows[1]))
    }

    @Test func minimizedWindowsStillMatchByName() {
        #expect(TargetMatcher.resolve("terminal", in: windows, frontmost: nil) == .window(windows[4]))
    }

    @Test func nothingMatchesAnUnknownName() {
        #expect(TargetMatcher.resolve("photoshop", in: windows, frontmost: nil) == .notFound)
    }
}
