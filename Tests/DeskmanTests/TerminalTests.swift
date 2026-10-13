import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2610101549: what runs in terminals, matched to windows only on evidence.

private func win(_ id: String, _ app: String, _ title: String, document: String? = nil) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: title, frame: Rect(x: 100, y: 100, width: 800, height: 600),
                   isMinimized: false, document: document)
}

private func job(_ app: String, _ tty: String, _ program: String, in folder: String?) -> TerminalJob {
    TerminalJob(app: app, tty: tty, program: program, folder: folder)
}

@Suite struct TerminalJobTests {
    @Test func aShellAtItsPromptIsNotBusy() {
        #expect(!job("Warp", "ttys005", "zsh", in: "/p/beacon").isBusy)
        #expect(!job("Warp", "ttys005", "-zsh", in: "/p/beacon").isBusy)
        #expect(job("Warp", "ttys001", "claude", in: "/p/beacon").isBusy)
    }

    @Test func aJobSaysWhatRunsWhere() {
        #expect(job("Warp", "ttys001", "claude", in: "/Volumes/Crucial/projects/beacon").phrase == "claude in beacon")
        #expect(job("Warp", "ttys001", "-zsh", in: nil).phrase == "zsh")
    }
}

@Suite struct TerminalMatcherTests {
    @Test func theOnlyWindowOfAnAppGetsEveryJob() {
        let w = [win("w", "iTerm2", "✳ Claude Code")]
        let jobs = [job("iTerm2", "ttys008", "claude", in: "/p/deskman"), job("iTerm2", "ttys009", "zsh", in: "/p/x")]
        let m = TerminalMatcher.match(jobs, to: w)
        #expect(m.byWindow[WindowID("w")] == jobs)
        #expect(m.byApp.isEmpty)
    }

    @Test func aTitleThatNamesTheFolderClaimsTheJob() {
        let w = [win("a", "Warp", "me@mac: ~/projects/deskman"), win("b", "Warp", "me@mac: ~/projects/beacon")]
        let j = job("Warp", "ttys001", "claude", in: "/Volumes/Crucial/projects/beacon")
        let m = TerminalMatcher.match([j], to: w)
        #expect(m.byWindow[WindowID("b")] == [j])
        #expect(m.byWindow[WindowID("a")] == nil)
    }

    @Test func aDocumentThatNamesTheFolderClaimsTheJob() {
        let w = [win("a", "Terminal", "zsh", document: "/p/deskman"), win("b", "Terminal", "zsh", document: "/p/atlas")]
        let j = job("Terminal", "ttys002", "npm", in: "/p/atlas")
        #expect(TerminalMatcher.match([j], to: w).byWindow[WindowID("b")] == [j])
    }

    @Test func aTitleThatNamesTheProgramClaimsTheJob() {
        let w = [win("a", "Warp", "watcher"), win("b", "Warp", "zsh")]
        let j = job("Warp", "ttys012", "watcher", in: "/p/beacon")
        #expect(TerminalMatcher.match([j], to: w).byWindow[WindowID("a")] == [j])
    }

    @Test func anAmbiguousJobBelongsToTheAppNeverToAWindow() {
        // Both titles say Claude Code: the job could be in either.
        let w = [win("a", "Warp", "✳ Claude Code"), win("b", "Warp", "◐ Claude Code")]
        let j = job("Warp", "ttys001", "claude", in: "/p/beacon")
        let m = TerminalMatcher.match([j], to: w)
        #expect(m.byWindow.isEmpty)
        #expect(m.byApp["Warp"] == [j])
    }

    @Test func aShellNameMatchesNothing() {
        let w = [win("a", "Warp", "zsh"), win("b", "Warp", "something")]
        let j = job("Warp", "ttys005", "zsh", in: nil)
        #expect(TerminalMatcher.match([j], to: w).byApp["Warp"] == [j])
    }

    @Test func aJobOfAnAppWithNoWindowHereBelongsToTheApp() {
        let j = job("iTerm2", "ttys008", "claude", in: "/p/deskman")
        let m = TerminalMatcher.match([j], to: [win("x", "Firefox", "Inbox")])
        #expect(m.byApp["iTerm2"] == [j])
    }

    @Test func appNamesMatchWhateverTheirCase() {
        let j = job("iterm2", "ttys008", "claude", in: "/p/deskman")
        #expect(TerminalMatcher.match([j], to: [win("w", "iTerm2", "")]).byWindow[WindowID("w")] == [j])
    }

    @Test func idleShellsAreLeftOutWhenSomethingIsBusy() {
        let w = [win("w", "Warp", "")]
        let m = TerminalMatcher.match([job("Warp", "t5", "zsh", in: "/p/beacon"), job("Warp", "t1", "claude", in: "/p/beacon"),
                                       job("Warp", "t6", "zsh", in: "/p/beacon"), job("Warp", "t12", "watcher", in: "/p/beacon")],
                                      to: w)
        #expect(m.phrases(for: WindowID("w")) == ["claude in beacon", "watcher in beacon"])
    }

    @Test func aWindowWithOnlyShellsIsDescribedByThem() {
        let w = [win("w", "Warp", "")]
        let m = TerminalMatcher.match([job("Warp", "t5", "zsh", in: "/p/beacon"), job("Warp", "t6", "zsh", in: "/p/beacon")], to: w)
        #expect(m.phrases(for: WindowID("w")) == ["zsh in beacon"])
    }

    @Test func busyWindowsAreTheWindowsABusyJobCouldBeIn() {
        let w = [win("a", "Warp", "✳ Claude Code"), win("b", "Warp", "◐ Claude Code"), win("c", "iTerm2", "zsh")]
        let m = TerminalMatcher.match([job("Warp", "ttys001", "claude", in: "/p/r"), job("iTerm2", "ttys9", "zsh", in: nil)],
                                      to: w)
        // The claude job is in one of the two Warp windows: neither is idle. The idle shell makes nothing busy.
        #expect(m.busyWindows(among: w) == [WindowID("a"), WindowID("b")])
    }
}

@MainActor @Suite struct TerminalWatchTests {
    @Test func jobsAreReadAtMostEveryFifteenSeconds() {
        let clock = FakeClock()
        let source = FakeTerminalActivity(jobs: [job("Warp", "t1", "claude", in: "/p/r")])
        let watch = TerminalWatch(source: source, clock: clock)
        _ = watch.jobs()
        clock.t = 14
        _ = watch.jobs()
        #expect(source.reads == 1)
        clock.t = 15
        _ = watch.jobs()
        #expect(source.reads == 2)
    }
}

@MainActor @Suite struct TerminalUseTests {
    @Test func theNamerIsToldWhatRunsInTheWindow() async {
        let namer = RecordingNamer()
        let names = WindowNames(namer: namer)
        let w = [win("w", "iTerm2", "✳ Claude Code")]
        let jobs = TerminalMatcher.match([job("iTerm2", "t8", "claude", in: "/p/deskman")], to: w)
        await names.refresh(w, terminals: jobs)
        #expect(namer.subjects.first?.first?.jobs == ["claude in deskman"])
    }

    @Test func aJobChangeNamesTheWindowAgain() async {
        let namer = RecordingNamer()
        let names = WindowNames(namer: namer)
        let w = [win("w", "iTerm2", "✳ Claude Code")]
        await names.refresh(w, terminals: TerminalMatcher.match([job("iTerm2", "t8", "claude", in: "/p/deskman")], to: w))
        await names.refresh(w, terminals: TerminalMatcher.match([job("iTerm2", "t8", "npm", in: "/p/deskman")], to: w))
        #expect(namer.subjects.count == 2)
    }

    @Test func appLevelJobsAreGivenAsContextNotAsTheWindowsOwn() async {
        let namer = RecordingNamer()
        let names = WindowNames(namer: namer)
        let w = [win("a", "Warp", "✳ Claude Code"), win("b", "Warp", "◐ Claude Code")]
        await names.refresh(w, terminals: TerminalMatcher.match([job("Warp", "t1", "claude", in: "/p/beacon")], to: w))
        let s = namer.subjects.first ?? []
        #expect(s.allSatisfy { $0.jobs.isEmpty && $0.appJobs == ["claude in beacon"] })
    }

    @Test func aTerminalWithABusyJobIsNeverMovedOutOfTheWay() {
        // Watched five minutes; Firefox in front all along; Warp runs claude.
        let clock = FakeClock()
        let focus = FocusTracker(clock: clock)
        for t in 0..<70 { clock.t = Double(t * 5); focus.record(app: "Firefox") }
        let w = [win("f", "Firefox", "Inbox"), win("t", "Warp", "✳ Claude Code")]
        let control = FakeWindowControl(windows: w, displays: [Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1380))],
                                        frontmost: WindowID("f"))
        // Nothing is ever minimized now (NeverMinimizeTests); this case stays as a witness.
        let service = WindowService(control: control, focus: focus, launchWait: .zero)
        _ = service.smartArrange(biggest: nil)
        #expect(!control.actions.contains { $0.0 == .minimize })
        #expect(Set(control.frames.map(\.0)) == [WindowID("f"), WindowID("t")])
    }
}

@MainActor final class RecordingNamer: WindowNamer {
    var subjects: [[NamingSubject]] = []
    func names(for subjects: [NamingSubject]) async throws -> [NamedWindow] {
        self.subjects.append(subjects)
        return subjects.map { NamedWindow(name: "n " + $0.window.title) }
    }
}

@Suite struct HomeFolderTests {
    // 2026-10-12: "tuios in gary" made the model give the home folder as a project.
    @Test func aHomeFolderIsNoProject() {
        #expect(TerminalJob(app: "iTerm2", tty: "s1", program: "tuios", folder: "/Users/me").folderName == nil)
        #expect(TerminalJob(app: "iTerm2", tty: "s1", program: "tuios", folder: "/Users/me").phrase == "tuios")
        #expect(TerminalJob(app: "iTerm2", tty: "s1", program: "zsh", folder: "/").folderName == nil)
        #expect(TerminalJob(app: "iTerm2", tty: "s1", program: "claude", folder: "/Users/me/app/atlas").folderName == "atlas")
    }
}
