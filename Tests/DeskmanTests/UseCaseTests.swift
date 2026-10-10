import Testing
import DeskmanPorts
import DeskmanUseCases

private let mainDisplay = Display(index: 0, visibleFrame: Rect(x: 0, y: 25, width: 1440, height: 875))
private let sideDisplay = Display(index: 1, visibleFrame: Rect(x: 1440, y: 0, width: 1920, height: 1080))

private func window(_ id: String, _ app: String, at frame: Rect, minimized: Bool = false) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), app: app, title: "\(app) window", frame: frame, isMinimized: minimized)
}

private let safari = window("s", "Safari", at: Rect(x: 100, y: 100, width: 800, height: 600))
private let notes = window("n", "Notes", at: Rect(x: 200, y: 200, width: 400, height: 400))
private let mail = window("m", "Mail", at: Rect(x: 1500, y: 50, width: 900, height: 700))   // on the side display
private let music = window("u", "Music", at: Rect(x: 0, y: 0, width: 300, height: 300), minimized: true)

@MainActor @Suite struct WindowServiceTests {
    func make(displays: [Display] = [mainDisplay, sideDisplay], frontmost: WindowID? = nil)
        -> (WindowService, FakeWindowControl)
    {
        let control = FakeWindowControl(windows: [safari, notes, mail, music], displays: displays, frontmost: frontmost)
        return (WindowService(control: control), control)
    }

    @Test func arrangeSetsTheLayoutFrameOnTheWindowsOwnDisplay() {
        let (service, control) = make()
        let outcome = service.arrange("safari", layout: .leftHalf)
        #expect(outcome.succeeded)
        #expect(control.frames.count == 1)
        #expect(control.frames[0].0 == safari.id)
        #expect(control.frames[0].1 == Rect(x: 0, y: 25, width: 720, height: 875))
    }

    @Test func arrangeUsesTheDisplayTheWindowIsOn() {
        let (service, control) = make()
        _ = service.arrange("mail", layout: .rightHalf)
        #expect(control.frames[0].1 == Rect(x: 2400, y: 0, width: 960, height: 1080))
    }

    @Test func arrangeRestoresAMinimizedWindowFirst() {
        let (service, control) = make()
        _ = service.arrange("music", layout: .maximize)
        #expect(control.actions.first?.0 == .restore)
        #expect(control.frames.count == 1)
    }

    @Test func anUnknownTargetFailsAndNamesTheOpenApps() {
        let (service, control) = make()
        let outcome = service.arrange("photoshop", layout: .leftHalf)
        #expect(!outcome.succeeded)
        #expect(outcome.message.contains("photoshop"))
        #expect(outcome.message.contains("Safari"))
        #expect(outcome.message.contains("Notes"))
        #expect(control.frames.isEmpty)
    }

    @Test func aFailedMoveIsReportedNotThrown() {
        let (service, control) = make()
        control.setFrameError = FakeError(description: "window refused")
        let outcome = service.arrange("safari", layout: .leftHalf)
        #expect(!outcome.succeeded)
        #expect(outcome.message.contains("window refused"))
    }

    @Test func noDisplaysIsAFailure() {
        let (service, _) = make(displays: [])
        #expect(!service.arrange("safari", layout: .leftHalf).succeeded)
    }

    @Test func actPerformsTheActionOnTheResolvedWindow() {
        let (service, control) = make(frontmost: notes.id)
        let outcome = service.act(.minimize, on: "this window")
        #expect(outcome.succeeded)
        #expect(control.actions.count == 1)
        #expect(control.actions[0].0 == .minimize)
        #expect(control.actions[0].1 == notes.id)
    }

    @Test func moveToNextDisplayKeepsTheRelativePlace() {
        let (service, control) = make()
        // Safari sits at (100,75) inside main's visible area, which is 1440×875.
        let outcome = service.moveToNextDisplay("safari")
        #expect(outcome.succeeded)
        let f = control.frames[0].1
        #expect(sideDisplay.visibleFrame.contains(f))
        #expect(abs((f.minX - 1440) / 1920 - 100.0 / 1440) < 0.0001)
        #expect(abs(f.width / 1920 - 800.0 / 1440) < 0.0001)
    }

    @Test func moveToNextDisplayNeedsTwoDisplays() {
        let (service, control) = make(displays: [mainDisplay])
        #expect(!service.moveToNextDisplay("safari").succeeded)
        #expect(control.frames.isEmpty)
    }

    @Test func tileNamedAppsGivesEachOneATile() {
        let (service, control) = make()
        let outcome = service.tile(apps: ["Safari", "Notes"])
        #expect(outcome.succeeded)
        #expect(control.frames.map(\.0) == [safari.id, notes.id])
        #expect(control.frames[0].1 == Rect(x: 0, y: 25, width: 720, height: 875))
        #expect(control.frames[1].1 == Rect(x: 720, y: 25, width: 720, height: 875))
    }

    @Test func tileWithNoAppsTilesTheVisibleWindowsOnTheMainDisplay() {
        let (service, control) = make()
        _ = service.tile(apps: [])
        // Music is minimized; Mail is on the side display.
        #expect(Set(control.frames.map(\.0)) == [safari.id, notes.id])
    }

    @Test func tileSkipsUnknownAppsAndSaysSo() {
        let (service, control) = make()
        let outcome = service.tile(apps: ["Safari", "Photoshop"])
        #expect(outcome.succeeded)
        #expect(outcome.message.contains("Photoshop"))
        #expect(control.frames.count == 1)
    }

    @Test func openLaunchesAndReportsFailure() {
        let (service, control) = make()
        #expect(service.open(app: "Calendar").succeeded)
        #expect(control.launched == ["Calendar"])
        #expect(!service.open(app: "Nope").succeeded)
    }
}

@MainActor @Suite struct DeskmanServiceTests {
    func make() -> (DeskmanService, FakeAssistant, FakeWindowControl) {
        let assistant = FakeAssistant()
        let control = FakeWindowControl(windows: [], displays: [mainDisplay])
        return (DeskmanService(assistant: assistant, control: control), assistant, control)
    }

    @Test func aFullContextResetsTheConversationAndRetriesOnce() async {
        let (service, assistant, _) = make()
        let done = AssistantReply(text: "Done.", actions: [CommandOutcome(succeeded: true, message: "Moved")])
        assistant.script = [.failure(.contextFull), .success(done)]
        let reply = await service.send("left half")
        #expect(reply == done)
        #expect(assistant.resets == 1)
        #expect(assistant.prompts == ["left half", "left half"])
    }

    @Test func aSecondFullContextIsReportedNotLooped() async {
        let (service, assistant, _) = make()
        assistant.script = [.failure(.contextFull), .failure(.contextFull)]
        let reply = await service.send("x")
        #expect(assistant.prompts.count == 2)
        #expect(!reply.text.isEmpty)
    }

    @Test func anUnavailableModelIsExplainedWithoutBeingCalled() async {
        let (service, assistant, _) = make()
        assistant.availability = .unavailable("Turn on Apple Intelligence in System Settings.")
        let reply = await service.send("left half")
        #expect(reply.text.contains("Apple Intelligence"))
        #expect(assistant.prompts.isEmpty)
    }

    @Test func withoutAccessibilityPermissionTheModelIsNotCalled() async {
        let (service, assistant, control) = make()
        control.trusted = false
        let reply = await service.send("left half")
        #expect(reply.text.contains("Accessibility"))
        #expect(assistant.prompts.isEmpty)
    }

    @Test func blankInputDoesNothing() async {
        let (service, assistant, _) = make()
        _ = await service.send("   ")
        #expect(assistant.prompts.isEmpty)
    }

    @Test func statusReportsBothSides() {
        let (service, assistant, control) = make()
        control.trusted = false
        assistant.availability = .unavailable("x")
        #expect(service.status == DeskmanStatus(assistant: .unavailable("x"), windowControlTrusted: false))
        service.requestWindowControlTrust()
        #expect(control.trustRequests == 1)
    }
}
