import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2610101542: the model names windows; the names help find them.

private func win(_ id: String, _ app: String, _ title: String) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: title, frame: Rect(x: 0, y: 0, width: 800, height: 600),
                   isMinimized: false)
}

@MainActor final class FakeNamer: WindowNamer {
    var calls: [[String]] = []
    var error: FakeError?
    func names(for subjects: [NamingSubject]) async throws -> [NamedWindow] {
        calls.append(subjects.map(\.window.title))
        if let error { throw error }
        return subjects.map { NamedWindow(name: "Named \($0.window.title)") }
    }
}

@MainActor @Suite struct WindowNamesTests {
    @Test func windowsGetNamesAfterARefresh() async {
        let namer = FakeNamer()
        let names = WindowNames(namer: namer)
        let w = [win("a", "iTerm2", "Claude Code"), win("b", "Firefox", "Problem loading page")]
        #expect(names.name(for: w[0]) == nil)
        await names.refresh(w)
        #expect(names.name(for: w[0]) == "Named Claude Code")
        #expect(names.name(for: w[1]) == "Named Problem loading page")
    }

    @Test func aNamedWindowIsNotAskedAgain() async {
        let namer = FakeNamer()
        let names = WindowNames(namer: namer)
        let w = [win("a", "iTerm2", "Claude Code")]
        await names.refresh(w)
        await names.refresh(w)
        #expect(namer.calls.count == 1)
    }

    @Test func aChangedTitleIsNamedAgain() async {
        let namer = FakeNamer()
        let names = WindowNames(namer: namer)
        await names.refresh([win("a", "Firefox", "Inbox")])
        await names.refresh([win("a", "Firefox", "Pull request #12")])
        #expect(namer.calls == [["Inbox"], ["Pull request #12"]])
        #expect(names.name(for: win("a", "Firefox", "Pull request #12")) == "Named Pull request #12")
    }

    @Test func atMostTwelveAreAskedAtOnce() async {
        let namer = FakeNamer()
        let names = WindowNames(namer: namer)
        await names.refresh((0..<20).map { win("w\($0)", "App", "t\($0)") })
        #expect(namer.calls.map(\.count) == [12])
    }

    @Test func aFailureLeavesNoNameAndIsKept() async {
        let namer = FakeNamer()
        namer.error = FakeError(description: "model unavailable")
        let names = WindowNames(namer: namer)
        let w = [win("a", "iTerm2", "Claude Code")]
        await names.refresh(w)
        #expect(names.name(for: w[0]) == nil)
        #expect(names.lastError == "model unavailable")
    }

    @Test func anOldFailureClearsOnceNothingIsLeftToName() async {
        let namer = FakeNamer()
        namer.error = FakeError(description: "model unavailable")
        let names = WindowNames(namer: namer)
        await names.refresh([win("a", "iTerm2", "Claude Code")])
        #expect(names.lastError == "model unavailable")
        // The window closes; no call to the model, and no failure to show.
        await names.refresh([])
        #expect(namer.calls.count == 1)
        #expect(names.lastError == nil)
    }

    @Test func aNamerThatReturnsTooFewNamesNamesNothingWrongly() async {
        final class Short: WindowNamer {
            func names(for subjects: [NamingSubject]) async throws -> [NamedWindow] { [NamedWindow(name: "Only one")] }
        }
        let names = WindowNames(namer: Short())
        let w = [win("a", "A", "x"), win("b", "B", "y")]
        await names.refresh(w)
        #expect(names.name(for: w[0]) == nil && names.name(for: w[1]) == nil)
        #expect(names.lastError != nil)
    }

    @Test func untitledWindowsAreNotSentToTheModel() async {
        let namer = FakeNamer()
        let names = WindowNames(namer: namer)
        await names.refresh([win("a", "Finder", "")])
        #expect(namer.calls.isEmpty)
    }
}

@Suite struct FindByNameTests {
    @Test func aWindowIsFoundByItsName() {
        let w = [win("a", "iTerm2", "Claude Code"), win("b", "iTerm2", "Claude Code")]
        let names = [WindowID("b"): "Deskman Claude session"]
        #expect(TargetMatcher.resolve("the deskman session", in: w, frontmost: nil, names: names) == .window(w[1]))
    }

    @Test func anAppNameStillBeatsAPartialNameMatch() {
        let w = [win("a", "Notes", ""), win("b", "Firefox", "x")]
        let names = [WindowID("b"): "Notes on Swift"]
        #expect(TargetMatcher.resolve("notes", in: w, frontmost: nil, names: names) == .window(w[0]))
    }
}

@MainActor @Suite struct NameTidyTests {
    @Test func twoWindowsNeverShareAName() async {
        final class Same: WindowNamer {
            func names(for subjects: [NamingSubject]) async throws -> [NamedWindow] {
                subjects.map { _ in NamedWindow(name: "Claude Code session") }
            }
        }
        let names = WindowNames(namer: Same())
        let w = [win("a", "iTerm2", "✳ Claude Code"), win("b", "iTerm2", "◑ Claude Code")]
        await names.refresh(w)
        #expect(names.name(for: w[0]) == "Claude Code session")
        #expect(names.name(for: w[1]) == "Claude Code session 2")
    }

    @Test func aRenamedWindowIsNotBlockedByItsOwnOldName() async {
        final class Same: WindowNamer {
            func names(for subjects: [NamingSubject]) async throws -> [NamedWindow] {
                subjects.map { _ in NamedWindow(name: "Claude Code session") }
            }
        }
        let names = WindowNames(namer: Same())
        await names.refresh([win("a", "iTerm2", "✳ Claude Code")])
        let renamed = win("a", "iTerm2", "◑ Claude Code")
        await names.refresh([renamed])
        #expect(names.name(for: renamed) == "Claude Code session")
    }

    @Test func twoWindowsWithTheSameTitleGetTwoNames() async {
        let names = WindowNames(namer: FakeNamer())
        let w = [win("a", "Terminal", "~"), win("b", "Terminal", "~")]
        await names.refresh(w)
        let a = names.name(for: w[0]), b = names.name(for: w[1])
        #expect(a != nil && b != nil)
        #expect(a != b)
    }

    @Test func aCopiedAppPrefixAndQuotesAreDropped() {
        #expect(WindowNames.tidy("Firefox: \"Page loading issue\".", app: "Firefox") == "Page loading issue")
    }

    @Test func aFolderMakesTheSameTitleANewWindow() async {
        let namer = FakeNamer()
        let names = WindowNames(namer: namer)
        let a = WindowSnapshot(id: WindowID("a"), app: "Terminal", title: "zsh", frame: Rect(x: 0, y: 0, width: 1, height: 1),
                               isMinimized: false, document: "/p/deskman")
        let b = WindowSnapshot(id: WindowID("b"), app: "Terminal", title: "zsh", frame: Rect(x: 0, y: 0, width: 1, height: 1),
                               isMinimized: false, document: "/p/atlas")
        await names.refresh([a, b])
        #expect(namer.calls.first?.count == 2)
    }
}
