import Testing
import DeskmanPorts
import DeskmanUseCases

// The user, 2026-10-12: "treat zoom completely differently ... autoarrange turned off, because if we
// are sharing an app we dont want to change anything". Zoom hid other windows when it was active.

private let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1410))

private func win(_ id: String, _ app: String, _ title: String = "", x: Double = 100) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: title, frame: Rect(x: x, y: 100, width: 800, height: 600),
                   isMinimized: false)
}

@Suite struct MeetingAppsTests {
    @Test func meetingAppsAreKnown() {
        for app in ["zoom.us", "Zoom", "Microsoft Teams", "Webex", "FaceTime"] { #expect(MeetingApps.contains(app), "\(app)") }
        #expect(!MeetingApps.contains("Slack"))
    }

    @Test func aMeetingIsSeenByItsWindows() {
        #expect(MeetingApps.inMeeting([win("z", "zoom.us", "Zoom Meeting")]))
        #expect(MeetingApps.inMeeting([win("z", "zoom.us", "zoom share toolbar window")]))
        #expect(MeetingApps.inMeeting([win("t", "Microsoft Teams", "Meeting with Ana | Microsoft Teams")]))
        #expect(!MeetingApps.inMeeting([win("z", "zoom.us", "Zoom Workplace")]))
        #expect(!MeetingApps.inMeeting([win("s", "Slack", "Meeting notes")]))
    }
}

@MainActor @Suite struct MeetingArrangeTests {
    let clock = FakeClock()

    func make(_ windows: [WindowSnapshot]) -> (ActivityService, FakeWindowControl) {
        let control = FakeWindowControl(windows: windows, displays: [wide], frontmost: windows.first?.id)
        let settings = Settings(store: InMemoryPreferenceStore(Preferences(keepArranged: true)), control: control)
        let service = ActivityService(control: control, store: InMemoryActivityStore(), clock: clock,
                                      arranger: SmartArranger(control: control, history: nil, settings: settings),
                                      settings: settings)
        return (service, control)
    }

    @Test func keepArrangedChangesNothingDuringAMeeting() {
        let (service, control) = make([win("z", "zoom.us", "Zoom Meeting"), win("s", "Slack", x: 900)])
        #expect(!service.keepArrangedDue())
        #expect(service.keepArrangedState.contains("meeting"))
        control.windowList.append(win("m", "Mail", x: 1800))
        clock.t = 10
        #expect(!service.keepArrangedDue())
        #expect(control.frames.isEmpty && control.actions.isEmpty)
    }

    @Test func keepArrangedResumesAfterTheMeeting() {
        let (service, control) = make([win("z", "zoom.us", "Zoom Meeting"), win("s", "Slack", x: 900)])
        _ = service.keepArrangedDue()
        control.windowList = [win("z", "zoom.us", "Zoom Workplace"), win("s", "Slack", x: 900)]
        clock.t = 5
        #expect(service.keepArrangedDue())
    }

    @Test func smartArrangeNeverTouchesAMeetingApp() {
        let (service, control) = make([win("z", "zoom.us", "Zoom Workplace"), win("s", "Slack", x: 900),
                                       win("m", "Mail", x: 1800)])
        #expect(service.smartArrange().succeeded)
        #expect(!control.frames.contains { $0.0 == WindowID("z") })
        #expect(!control.actions.contains { $0.1 == WindowID("z") })
    }

    @Test func smartArrangeArrangesAroundAMeetingApp() {
        // Left alone is not covered: the others are planned around Zoom's window.
        let zoom = WindowSnapshot(id: WindowID("z"), app: "zoom.us", title: "Zoom Workplace",
                                  frame: Rect(x: 1500, y: 30, width: 2000, height: 1410), isMinimized: false)
        let (service, control) = make([win("s", "Slack", x: 0), zoom, win("m", "Mail", x: 3600)])
        _ = service.smartArrange()
        for id in [WindowID("s"), WindowID("m")] {
            let f = control.frame(of: id) ?? Rect(x: 0, y: 0, width: 0, height: 0)
            #expect((f.intersection(zoom.frame)?.area ?? 0) < 1, "\(id.raw) covers Zoom")
        }
        #expect(!control.actions.contains { $0.0 == .minimize })
    }
}

// The user, 2026-10-12: "remember when in a zoom call we shutdown auto arrange" — and the reason,
// "if we are sharing an app we dont want to change anything": every move Deskman makes on its own
// stops during a meeting, not only Keep Arranged.
@MainActor @Suite struct NothingMovesDuringAMeetingTests {
    let clock = FakeClock()
    let meeting = win("z", "zoom.us", "Zoom Meeting", x: 4000)

    @Test func aNewBrowserIsNotPlacedDuringAMeeting() {
        let warp = win("t", "Warp", "claude", x: 0)
        let control = FakeWindowControl(windows: [warp, meeting], displays: [wide])
        let terminals = TerminalWatch(source: FakeTerminalActivity(jobs: [TerminalJob(app: "Warp", tty: "t1", program: "claude",
                                                                                       folder: "/p/deskman")]), clock: clock)
        let service = ActivityService(control: control, store: InMemoryActivityStore(), clock: clock, terminals: terminals)
        _ = service.tick()
        control.windowList = [warp, meeting, win("f", "Firefox", "Docs", x: 2000)]
        clock.t = 5
        if case .placedBeside = service.tick() { Issue.record("a browser was moved during a meeting") }
        #expect(control.frames.isEmpty && control.actions.isEmpty)
    }

    @Test func boundWindowsDoNotFollowDuringAMeeting() async {
        let portal = win("f", "Firefox", "Atlas Portal", x: 2000), claude = win("t", "iTerm2", "tuios", x: 0)
        let mail = win("m", "Mail", "Inbox", x: 1000)
        let control = FakeWindowControl(windows: [portal, claude, mail, meeting], displays: [wide], frontmost: mail.id)
        let store = InMemoryPreferenceStore(Preferences(boundProjects: ["atlas"]))
        let names = WindowNames(namer: ProjectNamer(["Atlas Portal": "atlas", "tuios": "atlas"]))
        await names.refresh(control.windowList)
        let service = BindingService(control: control, names: names, settings: Settings(store: store, control: control))
        service.observe()
        control.frontmost = portal.id                     // in a share, a partner popping up shows to everyone
        service.observe()
        #expect(control.actions.isEmpty && control.frames.isEmpty)
    }
}
