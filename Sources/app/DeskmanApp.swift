// Composition root (ADR-2610101046 §2): the one place that names adapters.
// Everything else asks for a port.
import AppKit
import SwiftUI
import DeskmanPorts
import DeskmanUseCases
import AccessibilityAdapter
import FoundationModelsAdapter
import ActivityStoreAdapter
import ProcessesAdapter
import DeskmanUI

@MainActor final class CompositionRoot {
    let chat: ChatModel
    private let deskman: DeskmanService
    var status: DeskmanStatus { deskman.status }
    let panel: DeskmanPanel
    let learning: LearningModel
    let commands: WindowService
    let names: WindowNames
    let terminals: TerminalWatch
    let control: any WindowControl
    let arranger: SmartArranger
    private let toast: SuggestionToast
    private var hotKey: GlobalHotKey?
    private var snapKeys: SnapHotKeys?
    private var dragSnap: DragSnap?
    let snap: SnapService
    let settings: SettingsModel
    let bindings: BindingService
    let accessibility: AccessibilityWindowControl

    /// `interactive`: the hotkeys, the mouse event tap and the cards. A diagnose copy runs
    /// beside the real one and only looks; if it hangs, it must not hold the mouse (ADR-2610121200).
    init(interactive: Bool) {
        let store = FileActivityStore()
        let clock = SystemTimeSource()
        let intents = IntentLog(clock: clock)
        // Why Deskman did what it did, in words (DecisionLog). A diagnose copy only looks: it writes nothing.
        let decisions: FileDecisionLog? = interactive ? FileDecisionLog() : nil
        intents.decisions = decisions
        let raw = AccessibilityWindowControl()
        accessibility = raw
        // What the person told Deskman: apps it leaves alone, drag-to-snap (ADR-2610120742).
        let preferences = Settings(store: FilePreferenceStore(), control: raw)
        // Every Deskman move goes through this wrapper, so a hand move can be told apart; and,
        // outermost, through the gateway, which decides each action and records it (ADR-2610121800).
        let control = WindowGateway(IntentRecordingControl(raw, log: intents), decisions: decisions)
        let focus = FocusTracker(clock: clock)
        let names = WindowNames(namer: FoundationModelsNamer())
        self.names = names
        let terminals = TerminalWatch(source: ProcessTerminalActivity(), clock: clock)
        self.terminals = terminals
        // A project's windows, bound on the model's suggestion (ADR-2610120830).
        let bindings = BindingService(control: control, names: names, settings: preferences)
        self.bindings = bindings
        // The person's grid, learned from their own moves and made equal (ADR-2610131157).
        let grid = LearnedGrid(history: store, clock: clock)
        grid.decisions = decisions
        let arranger = SmartArranger(control: control, history: store, focus: focus, intents: intents,
                                 settings: preferences, bindings: bindings, grid: grid)
        self.arranger = arranger
        // The model's tool and the menu share one arranger.
        let commands = WindowService(control: control, arranger: arranger, names: names)
        self.commands = commands
        self.control = control
        let assistant = FoundationModelsAssistant(commands: commands)
        let deskman = DeskmanService(assistant: assistant, control: control)

        let activity = ActivityService(control: control, store: store, clock: clock, arranger: arranger,
                                       focus: focus, intents: intents, names: names, terminals: terminals,
                                       settings: preferences, bindings: bindings, decisions: decisions, grid: grid)

        self.deskman = deskman
        chat = ChatModel(port: deskman)
        learning = LearningModel(port: activity, bindings: bindings)
        panel = DeskmanPanel(model: chat, learning: learning)
        toast = SuggestionToast(model: learning)
        hotKey = interactive ? GlobalHotKey { [panel] in panel.toggle() } : nil
        // Hammerspoon's window manager, replaced (ADR-2610101523 §4).
        snap = SnapService(control: control, intents: intents, settings: preferences, bindings: bindings, grid: grid)
        snapKeys = interactive ? SnapHotKeys(port: snap, report: { [learning] in learning.note($0.message) }) : nil
        dragSnap = interactive ? DragSnap(port: snap) : nil
        settings = SettingsModel(port: preferences, keys: interactive, report: { [learning] in learning.note($0.message) })
        if interactive, dragSnap == nil { NSLog("Deskman: macOS refused the mouse event tap; drag-to-snap is off.") }
    }

    var hotKeyRegistered: Bool { hotKey != nil }
    var snapKeysRegistered: Int { snapKeys?.registered ?? 0 }
    var dragSnapOn: Bool { dragSnap != nil }
}

/// Observable, because the menu is built before `root` exists. Without it, the
/// menu is drawn once with no root and never shows the learning items.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var root: CompositionRoot?

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar app. The bundle's Info.plist says so too (LSUIElement); this
        // line covers `swift run`, which has no bundle.
        NSApp.setActivationPolicy(.accessory)
        // `--out <file>`: a diagnose started by `open` (scripts/diagnose.sh) has no terminal;
        // its output goes to the file instead. `exit` flushes it.
        if let i = CommandLine.arguments.firstIndex(of: "--out"), i + 1 < CommandLine.arguments.count {
            freopen(CommandLine.arguments[i + 1], "w", stdout)
        }
        // Every diagnose but the plain one, which reports the keys it got, runs without keys or the mouse tap.
        let looking = CommandLine.arguments.contains { $0.hasPrefix("--diagnose-") }
        let root = CompositionRoot(interactive: !looking)
        self.root = root
        // A diagnose that needs windows and cannot see them fails loudly, not with "no windows".
        let needsWindows = ["--diagnose-speed", "--diagnose-bindings", "--diagnose-names", "--diagnose-arrange",
                            "--diagnose-terminals"]
        if CommandLine.arguments.contains(where: needsWindows.contains), !root.control.isTrusted {
            print("FAILED: " + SmartArranger.untrusted)
            exit(1)
        }
        // `--diagnose`: print what Deskman sees through its ports, then quit.
        if CommandLine.arguments.contains("--diagnose") {
            let status = root.status
            print("windowControlTrusted=\(status.windowControlTrusted) assistant=\(status.assistant)")
            print("bundle=\(Bundle.main.bundlePath) pid=\(ProcessInfo.processInfo.processIdentifier)")
            print("snapKeys=\(root.snapKeysRegistered)/6 dragSnap=\(root.dragSnapOn) settingsKeys=\(root.settings.registered)/2")
            print("dragSnapSwitch=\(root.settings.dragSnap) leftAlone=\(root.settings.floatingApps.joined(separator: ", "))")
            if let p = root.settings.problem { print("problem: \(p)") }
            exit(0)
        }
        // `--diagnose-arrange`: print the plan Smart Arrange would carry out. Moves nothing.
        // `--diagnose-names`: ask the model to name every window, print the names, quit.
        if CommandLine.arguments.contains("--diagnose-names") {
            Task { @MainActor in
                let all = root.control.windows()
                await root.names.refresh(all.filter(\.isVisible) + all.filter { !$0.isVisible },
                                         terminals: root.terminals.match(all))
                for w in all {
                    let where_ = w.isOnCurrentDesktop ? "here" : w.desktopPhrase
                    print("\(w.app) | \(w.title.prefix(50)) → \(root.names.name(for: w) ?? "(no name)")  [\(where_)]")
                }
                if let e = root.names.lastError { print("problem: \(e)") }
                exit(0)
            }
            return
        }
        // `--diagnose-speed`: how long each look at the desktop holds the main thread (ADR-2610121200).
        // Fails when `windows()` holds it 5 ms or more once a background read is in.
        if CommandLine.arguments.contains("--diagnose-speed") {
            Task { @MainActor in
                func ms(_ f: () -> Void) -> Double {
                    let t = Date(); f(); return Date().timeIntervalSince(t) * 1000
                }
                let first = ms { _ = root.control.windows() }
                let fresh = await root.accessibility.readFresh()
                let background = (root.accessibility.lastReadSeconds ?? 0) * 1000
                var cached: [Double] = []
                for _ in 0..<20 { cached.append(ms { _ = root.control.windows() }) }
                let jobs = ms { _ = root.terminals.jobs() }
                let front = ms { _ = root.control.frontmostWindowID() }
                let plan = ms { _ = root.arranger.preview() }
                func f(_ v: Double) -> String { String((v * 10).rounded() / 10) }
                print("windows: \(fresh.count)")
                print("first read, on the main thread (start-up only): \(f(first)) ms")
                print("background read: \(f(background)) ms, off the main thread")
                print("windows() on the main thread: max \(f(cached.max() ?? 0)) ms over 20 calls")
                print("terminal jobs: \(f(jobs)) ms; front window: \(f(front)) ms; Smart Arrange plan: \(f(plan)) ms")
                if (cached.max() ?? 0) >= 5 {
                    print("FAILED: windows() held the main thread \(f(cached.max() ?? 0)) ms")
                    exit(1)
                }
                print("PASS: windows() does not block the main thread")
                exit(0)
            }
            return
        }
        // `--diagnose-arrange apply`: carry it out, then read every frame back twice.
        if CommandLine.arguments.contains("--diagnose-arrange") {
            Task { @MainActor in
            // As a click does: names first, for the plan's labels.
            let all = root.control.windows()
            await root.names.refresh(all.filter(\.isVisible), terminals: root.terminals.match(all))
            print(root.arranger.preview())
            guard CommandLine.arguments.contains("apply") else { exit(0) }
            print("outcome: " + root.commands.smartArrange(biggest: nil).message)
            let report = { (when: String) in
                print(when + ":")
                for w in root.control.windows() where w.isVisible {
                    print("  \(w.id) \(w.app) \(Int(w.frame.x)),\(Int(w.frame.y)) \(Int(w.frame.width))×\(Int(w.frame.height))")
                }
            }
            report("right after")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { report("3 s later"); exit(0) }
            }
            return
        }
        // `--diagnose-map <png>`: open the desktop map, save a picture of it, quit.
        if let i = CommandLine.arguments.firstIndex(of: "--diagnose-map"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            let tab = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : nil
            root.panel.show(tab: .map, mapTab: tab ?? "Now")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print(root.panel.snapshot(to: URL(fileURLWithPath: path)) ? "saved \(path)" : "could not draw the map")
                exit(0)
            }
            return
        }
        // `--diagnose-outline [tab]`: open the map with Show on Screen on, report what each display draws, quit.
        if let i = CommandLine.arguments.firstIndex(of: "--diagnose-outline") {
            let tab = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "Now"
            root.panel.show(tab: .map, mapTab: tab, onScreen: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let lines = root.panel.outlineReport
                print(lines.isEmpty ? "no outline panels" : lines.joined(separator: "\n"))
                exit(0)
            }
            return
        }
        // `--diagnose-menu`: open Deskman's own menu-bar menu, print its items, quit.
        // Proof that a person can see them, not only that the code compiles.
        if CommandLine.arguments.contains("--diagnose-menu") {
            // Off the main thread: pressing the menu opens it, and an open menu runs on the main
            // thread. Pressed from the main thread, the two waited for each other (2026-10-12).
            print(Self.menuItems().joined(separator: "\n"))
            exit(0)
            return
        }
        root.chat.prewarm()
        root.learning.start()
        root.panel.show()
    }
}

extension AppDelegate {
    /// The titles in the running Deskman's menu-bar menu, read back through Accessibility.
    /// Never this process's own menu: Accessibility calls to one's own app run on the calling
    /// thread, so the press waited for itself on the main thread, and built SwiftUI off it on
    /// any other (2026-10-12: a 25 s hang, then a crash). The running app answers on its own main thread.
    static func menuItems() -> [String] {
        func copy(_ e: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success ? v : nil
        }
        func titles(_ e: AXUIElement, depth: Int) -> [String] {
            let children = copy(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
            return children.flatMap { child -> [String] in
                let title = copy(child, kAXTitleAttribute) as? String ?? ""
                let own = title.isEmpty ? [] : [String(repeating: "  ", count: depth) + title]
                return own + titles(child, depth: depth + 1)
            }
        }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != me }) else {
            return ["FAILED: no running Deskman to read the menu of. Start build/Deskman.app first."]
        }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        guard let extras = copy(app, kAXExtrasMenuBarAttribute),
              let item = (copy(extras as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first else {
            return ["no menu-bar item"]
        }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        defer { AXUIElementPerformAction(item, kAXCancelAction as CFString) }
        return ["menu-bar item: present"] + titles(item, depth: 1)
    }
}

@main
struct DeskmanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Deskman", systemImage: "rectangle.3.group") {
            DeskmanMenu(delegate: delegate)
        }
    }
}

private struct DeskmanMenu: View {
    @ObservedObject var delegate: AppDelegate

    /// The menu, simplified 2026-10-12 to what Deskman is today: Smart Arrange and Keep Arranged
    /// first, then the map and the assistant, then the switches. Habits live in the map's Learned
    /// tab; pins are removed where they are shown, in the map.
    var body: some View {
        if let root = delegate.root {
            ArrangeMenu(learning: root.learning, showMap: { root.panel.show(tab: .map) },
                        showKnows: { root.panel.show(tab: .map, mapTab: "What Deskman Knows") })
            Button("Open Deskman  \(GlobalHotKey.description)") { root.panel.show() }
            Divider()
            SettingsMenu(settings: root.settings, learning: root.learning)
        } else {
            Text("Starting…")
        }
        Divider()
        Button("Quit Deskman") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// What Deskman is for: arrange now, keep arranged, see it.
private struct ArrangeMenu: View {
    @Bindable var learning: LearningModel
    let showMap: () -> Void
    /// The map's What Deskman Knows tab, directly: two levels down it went unseen (the user, 2026-10-13).
    let showKnows: () -> Void

    var body: some View {
        Button("Smart Arrange") { learning.smartArrange() }
            .keyboardShortcut("s")
        Toggle("Keep Arranged", isOn: Binding(get: { learning.keepArranged }, set: { learning.setKeepArranged($0) }))
        Button("Desktop Map") { showMap() }
            .keyboardShortcut("m")
        Button("What Deskman Knows") { showKnows() }
            .keyboardShortcut("k")
        // Why Deskman did what it did, one line per decision (opens in Console).
        Button("Open Decision Log") { NSWorkspace.shared.open(FileDecisionLog.url) }
            .keyboardShortcut("l")
    }
}

/// The switches (ADR-2610120742, ADR-2610120830, ADR-2610101415).
private struct SettingsMenu: View {
    @Bindable var settings: SettingsModel
    @Bindable var learning: LearningModel

    var body: some View {
        Toggle("Drag to Snap  ⌃⌥D", isOn: Binding(get: { settings.dragSnap }, set: { settings.setDragSnap($0) }))
        Menu("Apps Deskman Leaves Alone") {
            Button("Leave the Front App Alone, or Not  ⌃⌥F") { settings.toggleFrontmost() }
            Divider()
            if settings.floatingApps.isEmpty { Text("None. Deskman arranges every app.") }
            // A checkmark: click it to let Deskman arrange the app again.
            ForEach(settings.floatingApps, id: \.self) { app in
                Toggle(app, isOn: Binding(get: { true }, set: { settings.setFloating(app, $0) }))
            }
        }
        // Only once there is one: Deskman offers to bind when two apps' windows share a project.
        if !learning.boundProjects.isEmpty {
            Menu("Bound Projects") {
                // A checkmark: click it to unbind.
                ForEach(learning.boundProjects, id: \.self) { p in
                    Toggle(p, isOn: Binding(get: { true }, set: { if !$0 { learning.unbind(p) } }))
                }
            }
        }
        Menu("Learning") {
            Toggle("Learn How I Arrange Windows", isOn: Binding(
                get: { !learning.isPaused }, set: { learning.isPaused = !$0 }))
            Button("Forget My Activity…") {
                let alert = NSAlert()
                alert.messageText = "Forget your window activity?"
                alert.informativeText = "This erases every recorded arrangement, with its window titles, and every habit Deskman learned."
                alert.addButton(withTitle: "Forget")
                alert.addButton(withTitle: "Cancel")
                alert.alertStyle = .warning
                if alert.runModal() == .alertFirstButtonReturn { learning.forget() }
            }
        }
        if let problem = settings.problem { Text(problem) }
    }
}
