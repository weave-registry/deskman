import Testing
import DeskmanPorts
import DeskmanUseCases

// ADR-2610120830: the model binds a project's windows together.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1380))
private let side = Display(index: 1, visibleFrame: Rect(x: 5120, y: 0, width: 1920, height: 1080))

private func win(_ id: String, _ app: String, _ title: String = "", x: Double = 100, minimized: Bool = false,
                 here: Bool = true) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: title, frame: Rect(x: x, y: 100, width: 800, height: 600),
                   isMinimized: minimized, desktop: here ? 1 : 2, isOnCurrentDesktop: here)
}

/// The model, as far as these tests care: a name and a project per title.
@MainActor final class ProjectNamer: WindowNamer {
    var projects: [String: String]
    init(_ projects: [String: String]) { self.projects = projects }
    func names(for subjects: [NamingSubject]) async throws -> [NamedWindow] {
        subjects.map { NamedWindow(name: "Named " + $0.window.title, project: projects[$0.window.title]) }
    }
}

private let portal = win("f", "Firefox", "Atlas Portal", x: 2000)
private let claude = win("t", "iTerm2", "tuios", x: 100)
private let mail = win("m", "Mail", "Inbox", x: 4000)
private let atlas = ["Atlas Portal": "atlas", "tuios": "Atlas", "Inbox": "none"]

@MainActor @Suite struct ProjectNamingTests {
    @Test func theModelsProjectIsKeptBesideTheNameAndTidied() async {
        let names = WindowNames(namer: ProjectNamer(atlas))
        await names.refresh([portal, claude, mail])
        #expect(names.project(for: portal) == "atlas")
        #expect(names.project(for: claude) == "atlas")          // "Atlas" → "atlas"
        #expect(names.project(for: mail) == nil)                  // "none" is no project
        #expect(names.name(for: portal) == "Named Atlas Portal")
    }

    @Test func aNameWithoutItsProjectGetsItInFront() async {
        // The real model, 2026-10-12: "Claude Code" [atlas] and "Claude Code" [deskman].
        final class Bare: WindowNamer {
            func names(for subjects: [NamingSubject]) async throws -> [NamedWindow] {
                subjects.map { NamedWindow(name: "Claude Code", project: $0.window.title) }
            }
        }
        let names = WindowNames(namer: Bare())
        let a = win("a", "iTerm2", "atlas"), b = win("b", "Warp", "deskman"), c = win("c", "Xcode", "none")
        await names.refresh([a, b, c])
        #expect(names.name(for: a) == "Atlas Claude Code")
        #expect(names.name(for: b) == "Deskman Claude Code")
        #expect(names.name(for: c) == "Claude Code")
    }

    @Test func aNameThatHasItsProjectIsLeftAlone() async {
        let names = WindowNames(namer: ProjectNamer(["Atlas Portal": "atlas"]))
        let w = win("f", "Firefox", "Atlas Portal")
        await names.refresh([w])
        #expect(names.name(for: w) == "Named Atlas Portal")
    }
}

@Suite struct BindingRulesTests {
    let projects: [WindowID: String] = [portal.id: "atlas", claude.id: "atlas"]

    @Test func twoAppsOfOneProjectAreACandidate() {
        let s = Bindings.candidate([portal, claude, mail], projects: projects, bound: [], declined: [])
        #expect(s?.project == "atlas")
        #expect(s.map { Set($0.windows) } == [portal.id, claude.id])
    }

    @Test func oneAppAloneIsNoCandidate() {
        let two = [win("a", "Firefox", "Atlas Portal"), win("b", "Firefox", "Atlas docs")]
        let p: [WindowID: String] = [WindowID("a"): "atlas", WindowID("b"): "atlas"]
        #expect(Bindings.candidate(two, projects: p, bound: [], declined: []) == nil)
    }

    @Test func aBoundOrDeclinedProjectIsNotOfferedAgain() {
        #expect(Bindings.candidate([portal, claude], projects: projects, bound: ["atlas"], declined: []) == nil)
        #expect(Bindings.candidate([portal, claude], projects: projects, bound: [], declined: ["atlas"]) == nil)
    }

    @Test func windowsOnAnotherDesktopOrMinimizedAreNotOffered() {
        let away = win("t", "iTerm2", "tuios", here: false)
        #expect(Bindings.candidate([portal, away], projects: projects, bound: [], declined: []) == nil)
        let small = win("t", "iTerm2", "tuios", minimized: true)
        #expect(Bindings.candidate([portal, small], projects: projects, bound: [], declined: []) == nil)
    }

    @Test func aGroupIsEveryWindowOfABoundProjectMinimizedOrNot() {
        let small = win("t", "iTerm2", "tuios", minimized: true)
        let g = Bindings.groups([portal, small, mail], projects: projects, bound: ["atlas"])
        #expect(g.map { Set($0) } == [[portal.id, claude.id]])
    }

    @Test func aGroupMovesUpToItsHighestMember() {
        let order = [portal, mail, claude]
        let out = Bindings.adjacent(order, groups: [[portal.id, claude.id]])
        #expect(out.map(\.id) == [portal.id, claude.id, mail.id])
    }

    // MARK: follow

    let groups = [[WindowID("f"), WindowID("t")]]

    @Test func focusingOneRaisesTheOtherThenRefocusesIt() {
        let f = Bindings.follow(before: [portal, claude], after: [portal, claude], frontBefore: mail.id,
                                frontAfter: portal.id, groups: groups, displays: [wide])
        #expect(f == [.focus(claude.id), .focus(portal.id)])
    }

    @Test func noFrontChangeIsNoFocus() {
        let f = Bindings.follow(before: [portal, claude], after: [portal, claude], frontBefore: portal.id,
                                frontAfter: portal.id, groups: groups, displays: [wide])
        #expect(f.isEmpty)
    }

    @Test func minimizingOneLeavesTheOther() {
        // Deskman minimizes nothing (2026-10-12), not even a bound partner.
        let after = [win("f", "Firefox", "Atlas Portal", x: 2000, minimized: true), claude]
        let f = Bindings.follow(before: [portal, claude], after: after, frontBefore: nil, frontAfter: nil,
                                groups: groups, displays: [wide])
        #expect(f.isEmpty)
    }

    @Test func restoringOneRestoresTheOther() {
        let before = [win("f", "Firefox", "Atlas Portal", minimized: true), win("t", "iTerm2", "tuios", minimized: true)]
        let after = [portal, before[1]]
        let f = Bindings.follow(before: before, after: after, frontBefore: nil, frontAfter: nil,
                                groups: groups, displays: [wide])
        #expect(f == [.restore(claude.id)])
    }

    @Test func aFollowDoesNotTriggerItself() {
        // The partner minimized because its lead did: both are now minimized, nothing more to do.
        let before = [win("f", "Firefox", "Atlas Portal", minimized: true), claude]
        let after = [before[0], win("t", "iTerm2", "tuios", minimized: true)]
        #expect(Bindings.follow(before: before, after: after, frontBefore: nil, frontAfter: nil,
                                groups: groups, displays: [wide]).isEmpty)
    }

    @Test func movingOneToAnotherDisplayBringsTheOtherAlong() {
        let moved = WindowSnapshot(id: portal.id, app: "Firefox", title: "Atlas Portal",
                                   frame: Rect(x: 5300, y: 100, width: 800, height: 600), isMinimized: false)
        let f = Bindings.follow(before: [portal, claude], after: [moved, claude], frontBefore: nil, frontAfter: nil,
                                groups: groups, displays: [wide, side])
        guard case .move(let id, let to)? = f.first, f.count == 1 else { Issue.record("\(f)"); return }
        #expect(id == claude.id)
        #expect(side.visibleFrame.contains(Point(x: to.x + to.width / 2, y: to.y + to.height / 2)))
    }
}

@MainActor @Suite struct BindingServiceTests {
    func make(_ windows: [WindowSnapshot], front: WindowID? = nil, bound: [String] = [],
              floating: [String] = []) async -> (BindingService, FakeWindowControl, InMemoryPreferenceStore, WindowNames) {
        let control = FakeWindowControl(windows: windows, displays: [wide], frontmost: front)
        let store = InMemoryPreferenceStore(Preferences(floatingApps: floating, boundProjects: bound))
        let names = WindowNames(namer: ProjectNamer(atlas))
        await names.refresh(windows)
        let service = BindingService(control: control, names: names, settings: Settings(store: store, control: control))
        return (service, control, store, names)
    }

    @Test func itSuggestsTheHorizonPairWithTheModelsNames() async {
        let (service, _, _, _) = await make([portal, claude, mail])
        let s = service.suggestion()
        #expect(s?.project == "atlas")
        #expect(s?.names.sorted() == ["Atlas Named tuios", "Named Atlas Portal"])   // the project goes in front of a name without it
    }

    @Test func bindingIsSavedAndEndsTheSuggestion() async {
        let (service, _, store, _) = await make([portal, claude])
        #expect(service.bind("atlas").succeeded)
        #expect(store.saved?.boundProjects == ["atlas"])
        #expect(service.suggestion() == nil)
        #expect(service.boundProjects == ["atlas"])
    }

    @Test func declineIsSavedAndNotAskedAgain() async {
        let (service, _, store, _) = await make([portal, claude])
        #expect(service.decline("atlas").succeeded)
        #expect(store.saved?.declinedProjects == ["atlas"])
        #expect(service.suggestion() == nil)
    }

    @Test func aFloatingAppIsNeverBound() async {
        let (service, _, _, _) = await make([portal, claude], floating: ["Firefox"])
        #expect(service.suggestion() == nil)
    }

    @Test func observeFocusesThePartnerWhenOneComesToTheFront() async {
        let (service, control, _, _) = await make([portal, claude, mail], front: mail.id, bound: ["atlas"])
        service.observe()                               // the first look only remembers
        #expect(control.actions.isEmpty)
        control.frontmost = portal.id
        service.observe()
        #expect(control.actions.map(\.0) == [.focus, .focus])
        #expect(control.actions.map(\.1) == [claude.id, portal.id])
    }

    @Test func observeNeverMinimizesThePartner() async {
        // Deskman minimizes nothing (2026-10-12), not even a bound partner.
        let (service, control, _, _) = await make([portal, claude], bound: ["atlas"])
        service.observe()
        control.windowList = [win("f", "Firefox", "Atlas Portal", x: 2000, minimized: true), claude]
        service.observe()
        #expect(control.actions.isEmpty)
    }

    @Test func withNothingBoundObserveDoesNothing() async {
        let (service, control, _, _) = await make([portal, claude], front: mail.id)
        service.observe()
        control.frontmost = portal.id
        service.observe()
        #expect(control.actions.isEmpty)
    }

    @Test func unbindStopsTheFollowing() async {
        let (service, control, _, _) = await make([portal, claude, mail], front: mail.id, bound: ["atlas"])
        #expect(service.unbind("atlas").succeeded)
        service.observe()
        control.frontmost = portal.id
        service.observe()
        #expect(control.actions.isEmpty)
    }

    @Test func smartArrangePutsTheBoundPairInConsecutiveZones() async {
        // Front to back: Firefox, Mail, iTerm2. Bound, iTerm2 comes up beside Firefox.
        let windows = [portal, mail, claude]
        let (service, control, _, _) = await make(windows, front: portal.id, bound: ["atlas"])
        let arranger = SmartArranger(control: control, history: nil, bindings: service)
        let plan = ActivityService(control: control, store: InMemoryActivityStore(), clock: FakeClock(),
                                   arranger: arranger).desktopMap().plan
        #expect(plan.map(\.app) == ["Firefox", "iTerm2", "Mail"])
    }

    @Test func aSnapKeyPutsThePartnerInTheZoneBeside() async {
        let (service, control, _, _) = await make([portal, claude], front: portal.id, bound: ["atlas"])
        let snap = SnapService(control: control, intents: nil, bindings: service)
        #expect(snap.snapFrontmost(toZone: 3).succeeded)
        let zones = ZoneGenerator.snapZones(on: wide)
        let beside = ZoneGenerator.zone(beside: zones[2], in: zones)
        #expect(control.frames.map(\.0) == [portal.id, claude.id])
        #expect(control.frames.last?.1 == beside)
    }
}
