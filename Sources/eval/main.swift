// DeskmanEval: the real on-device model, real use cases, pretend windows.
// Each case is one request on a fresh conversation. A case passes when the
// commands it expects appear, in order, among the commands the model ran.
// Nothing on the real screen moves.
import Foundation
import DeskmanPorts
import DeskmanUseCases
import FoundationModelsAdapter

// MARK: Pretend desktop

@MainActor final class InMemoryControl: WindowControl {
    private var list: [WindowSnapshot]
    let frontmost: WindowID? = WindowID("safari")  // keep in step with RecordingCommands.norm

    init() {
        func w(_ id: String, _ app: String, _ title: String, _ x: Double) -> WindowSnapshot {
            WindowSnapshot(id: WindowID(id), app: app, title: title,
                           frame: Rect(x: x, y: 60, width: 700, height: 600), isMinimized: false)
        }
        list = [
            w("safari", "Safari", "Apple", 40),
            w("notes", "Notes", "Shopping list", 200),
            w("mail", "Mail", "Inbox", 300),
            w("terminal", "Terminal", "zsh", 400),
            w("xcode", "Xcode", "Deskman — Package.swift", 500),
            // On desktop 2: listed, focusable, never moved (ADR-2610101429).
            WindowSnapshot(id: WindowID("slack"), app: "Slack", title: "general",
                           frame: Rect(x: 40, y: 60, width: 900, height: 700), isMinimized: false,
                           desktop: 2, isOnCurrentDesktop: false),
        ]
    }

    func windows() -> [WindowSnapshot] { list }
    func displays() -> [Display] {
        [Display(index: 0, visibleFrame: Rect(x: 0, y: 25, width: 1440, height: 875)),
         Display(index: 1, visibleFrame: Rect(x: 1440, y: 0, width: 1920, height: 1080))]
    }
    func frontmostWindowID() -> WindowID? { frontmost }
    func setFrame(_ frame: Rect, of id: WindowID) throws {}
    func perform(_ action: WindowAction, on id: WindowID) throws {}
    func launch(app: String) throws {
        let id = WindowID(app.lowercased())
        if !list.contains(where: { $0.id == id }) {
            list.append(WindowSnapshot(id: id, app: app, title: app,
                                       frame: Rect(x: 100, y: 100, width: 800, height: 600), isMinimized: false))
        }
    }
    var isTrusted: Bool { true }
    func requestTrust() {}
}

/// Forwards to the real `WindowService` and writes down every call as a short string.
@MainActor final class RecordingCommands: WindowCommands {
    private let inner: WindowService
    private(set) var calls: [String] = []

    init(inner: WindowService) { self.inner = inner }
    func clear() { calls = [] }

    func listWindows() -> [WindowSnapshot] { calls.append("list"); return inner.listWindows() }
    func windowNames() -> [WindowID: String] { inner.windowNames() }
    func arrange(_ target: String, layout: Layout) -> CommandOutcome {
        calls.append("arrange \(norm(target)) \(layout.rawValue)"); return inner.arrange(target, layout: layout)
    }
    func act(_ action: WindowAction, on target: String) -> CommandOutcome {
        calls.append("\(action.rawValue) \(norm(target))"); return inner.act(action, on: target)
    }
    func moveToNextDisplay(_ target: String) -> CommandOutcome {
        calls.append("arrange \(norm(target)) nextDisplay"); return inner.moveToNextDisplay(target)
    }
    func tile(apps: [String]) -> CommandOutcome {
        calls.append("tile [\(apps.map(norm).joined(separator: ","))]"); return inner.tile(apps: apps)
    }
    func open(app: String) async -> CommandOutcome {
        calls.append("open \(app.lowercased())"); return await inner.open(app: app)
    }
    func smartArrange(biggest: String?) -> CommandOutcome {
        calls.append("smart"); return inner.smartArrange(biggest: biggest)
    }

    /// The window the words point to, by the real matcher; "?words" when none.
    /// The pretend frontmost window is Safari, so "this window" becomes "safari".
    private func norm(_ target: String) -> String {
        let windows = inner.listWindows()
        if case .window(let w) = TargetMatcher.resolve(target, in: windows, frontmost: WindowID("safari")) {
            return w.id.raw
        }
        return "?" + target.lowercased()
    }
}

// MARK: Cases

struct Case {
    let request: String
    let expected: [String]
    /// Other command sequences that do the same thing on the desktop.
    var alsoAccepted: [[String]] = []
}

let cases = [
    Case(request: "put this window on the left half", expected: ["arrange safari leftHalf"]),
    Case(request: "Notes and Mail side by side", expected: ["tile [notes,mail]"]),
    Case(request: "maximize this", expected: ["arrange safari maximize"]),
    Case(request: "minimize Mail", expected: ["minimize mail"]),
    Case(request: "tile all my windows", expected: ["smart"]),
    Case(request: "open Calendar on the right third", expected: ["open calendar", "arrange calendar rightThird"]),
    Case(request: "move this to my other screen", expected: ["arrange safari nextDisplay"]),
    Case(request: "put Terminal in the top right corner", expected: ["arrange terminal topRight"]),
    Case(request: "close the notes window", expected: ["close notes"]),
    // openApp on a running app brings it forward, so it has the same effect.
    Case(request: "switch to Xcode", expected: ["focus xcode"], alsoAccepted: [["open xcode"]]),
    Case(request: "center this window", expected: ["arrange safari center"]),
    Case(request: "Xcode on the left two thirds", expected: ["arrange xcode leftTwoThirds"]),
    Case(request: "switch to Slack", expected: ["focus slack"], alsoAccepted: [["open slack"]]),
    Case(request: "organize my windows so I can work", expected: ["smart"]),
    Case(request: "set me up for coding", expected: ["smart"]),
    Case(request: "arrange everything efficiently", expected: ["smart"]),
]

func containsInOrder(_ calls: [String], _ expected: [String]) -> Bool {
    var i = 0
    for c in calls where i < expected.count && c == expected[i] { i += 1 }
    return i == expected.count
}

// MARK: Projects (ADR-2610120830)

// `DeskmanEval --projects`: the real namer on the user's Atlas windows, as the activity
// log recorded them, plus decoys. Passes when the Atlas pair shares a project, the
// Deskman pair shares another, and Mail has none, in every one of 3 runs.
if CommandLine.arguments.contains("--projects") {
    func w(_ id: String, _ app: String, _ title: String) -> WindowSnapshot {
        WindowSnapshot(id: WindowID(id), app: app, title: title, frame: Rect(x: 0, y: 0, width: 800, height: 600),
                       isMinimized: false)
    }
    let subjects = [
        NamingSubject(window: w("t", "iTerm2", "tuios"), jobs: ["claude in atlas"]),
        NamingSubject(window: w("f", "Firefox", "Atlas Portal")),
        NamingSubject(window: w("m", "Mail", "Inbox (3 messages)")),
        NamingSubject(window: w("x", "Xcode", "Deskman — Package.swift")),
        NamingSubject(window: w("d", "Warp", "✳ Claude Code"), jobs: ["claude in deskman"]),
    ]
    let namer = FoundationModelsNamer()
    var good = 0
    for run in 1...3 {
        do {
            let got = try await namer.names(for: subjects)
            let p = got.map { NamedWindow.tidyProject($0.project) }
            for (s, n) in zip(subjects, got) { print("  \(s.window.app): \(s.window.title) → \(n.name) [\(n.project ?? "nil")]") }
            let ok = got.count == 5 && p[0] != nil && p[0] == p[1] && p[3] != nil && p[3] == p[4] && p[0] != p[3] && p[2] == nil
            if ok { good += 1 }
            print("run \(run): \(ok ? "PASS" : "FAIL")")
        } catch {
            print("run \(run): ERROR \(error)")
        }
    }
    print("\n\(good)/3 passed")
    exit(good == 3 ? 0 : 1)
}

// MARK: Run

let commands = RecordingCommands(inner: WindowService(control: InMemoryControl(), launchWait: .zero))
let assistant = FoundationModelsAssistant(commands: commands)

guard case .available = assistant.availability else {
    print("The model is not available: \(assistant.availability)")
    exit(2)
}

let filter = CommandLine.arguments.dropFirst().first
var passed = 0
var run = 0
for c in cases where filter == nil || c.request.contains(filter!) {
    run += 1
    assistant.reset()
    commands.clear()
    let clock = ContinuousClock()
    let start = clock.now
    var replyText: String
    do {
        replyText = try await assistant.reply(to: c.request).text
    } catch {
        replyText = "ERROR \(error)"
    }
    let seconds = (clock.now - start).components.seconds
    let ok = ([c.expected] + c.alsoAccepted).contains { containsInOrder(commands.calls, $0) }
    if ok { passed += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(c.request)  (\(seconds)s)")
    if !ok {
        print("      expected: \(c.expected.joined(separator: " → "))")
        print("      got:      \(commands.calls.isEmpty ? "(no tool call)" : commands.calls.joined(separator: " → "))")
        print("      said:     \(replyText.replacingOccurrences(of: "\n", with: " ").prefix(160))")
    }
}
print("\n\(passed)/\(run) passed")
exit(passed == run ? 0 : 1)
