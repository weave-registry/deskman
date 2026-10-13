import DeskmanPorts

/// The window commands, written against `WindowControl` only.
@MainActor public final class WindowService: WindowCommands {
    private let control: any WindowControl
    private let arranger: SmartArranger
    private let names: WindowNames?
    private let launchWait: Duration

    /// `launchWait` bounds how long `open` waits for a new app's first window.
    /// `history`, `focus` and `intents` feed Smart Arrange.
    public init(control: any WindowControl, history: (any ActivityStore)? = nil,
                focus: FocusTracker? = nil, intents: IntentLog? = nil, names: WindowNames? = nil,
                settings: Settings? = nil, bindings: BindingService? = nil,
                launchWait: Duration = .seconds(3)) {
        self.control = control
        self.names = names
        self.arranger = SmartArranger(control: control, history: history, focus: focus, intents: intents,
                                      settings: settings, bindings: bindings)
        self.launchWait = launchWait
    }

    /// With an arranger already made, so the model tool and the menu share one.
    public init(control: any WindowControl, arranger: SmartArranger, names: WindowNames? = nil,
                launchWait: Duration = .seconds(3)) {
        self.control = control
        self.names = names
        self.arranger = arranger
        self.launchWait = launchWait
    }

    public func listWindows() -> [WindowSnapshot] {
        control.windows()
    }

    public func windowNames() -> [WindowID: String] {
        names?.names(for: control.windows()) ?? [:]
    }

    public func arrange(_ target: String, layout: Layout) -> CommandOutcome {
        withWindow(target) { w, displays in
            if w.isMinimized { try asked { try control.perform(.restore, on: w.id) } }
            guard let display = Displays.containing(w.frame, in: displays) else { return .failed("No display found.") }
            try asked { try control.setFrame(layout.frame(in: display.visibleFrame), of: w.id) }
            return .ok("Moved \(w.app) to \(layout.phrase).")
        }
    }

    public func act(_ action: WindowAction, on target: String) -> CommandOutcome {
        // Focus is the one action that reaches another desktop: macOS switches there.
        withWindow(target, reachesOtherDesktops: action == .focus) { w, _ in
            try asked { try control.perform(action, on: w.id) }
            return w.isOnCurrentDesktop ? .ok("\(action.pastTense) \(w.app).")
                                        : .ok("Switched to \(w.app) on \(w.desktopPhrase).")
        }
    }

    public func moveToNextDisplay(_ target: String) -> CommandOutcome {
        withWindow(target) { w, displays in
            guard displays.count > 1 else { return .failed("There is only one display.") }
            guard let from = Displays.containing(w.frame, in: displays),
                  let to = Displays.next(after: from, in: displays) else { return .failed("No display found.") }
            try asked { try control.setFrame(Self.map(w.frame, from: from.visibleFrame, to: to.visibleFrame), of: w.id) }
            return .ok("Moved \(w.app) to display \(to.index + 1).")
        }
    }

    public func tile(apps: [String]) -> CommandOutcome {
        let displays = control.displays()
        guard let fallback = displays.first else { return .failed("No display found.") }
        let all = control.windows()
        let frontmost = control.frontmostWindowID()

        var chosen: [WindowSnapshot] = []
        var missing: [String] = []
        var elsewhere: [WindowSnapshot] = []
        let display: Display
        if apps.isEmpty {
            let front = all.first { $0.id == frontmost }
            display = front.flatMap { Displays.containing($0.frame, in: displays) } ?? fallback
            chosen = all.filter { $0.isVisible && Displays.containing($0.frame, in: displays) == display }
        } else {
            for app in apps {
                // One window per app; never the same window twice.
                // Only this desktop: another desktop's window cannot be placed here.
                let rest = all.filter { w in w.isOnCurrentDesktop && !chosen.contains { $0.id == w.id } }
                if case .window(let w) = TargetMatcher.resolve(app, in: rest, frontmost: frontmost,
                                                               names: names?.names(for: rest) ?? [:]) {
                    chosen.append(w)
                } else if case .window(let w) = TargetMatcher.resolve(app, in: all.filter { !$0.isOnCurrentDesktop },
                                                                       frontmost: nil) {
                    elsewhere.append(w)
                } else {
                    missing.append(app)
                }
            }
            display = chosen.first.flatMap { Displays.containing($0.frame, in: displays) } ?? fallback
        }
        let away = elsewhere.isEmpty ? "" : " On another desktop: "
            + elsewhere.map { "\($0.app) (\($0.desktopPhrase))" }.joined(separator: ", ") + "."
        guard !chosen.isEmpty else {
            if !elsewhere.isEmpty { return .failed("Nothing to tile on this desktop." + away) }
            if apps.isEmpty { return .failed("No visible windows to tile on display \(display.index + 1).") }
            return .failed(notFound(apps.joined(separator: ", "), in: all))
        }

        do {
            for (w, frame) in zip(chosen, GridTiler.frames(count: chosen.count, in: display.visibleFrame)) {
                if w.isMinimized { try asked { try control.perform(.restore, on: w.id) } }
                try asked { try control.setFrame(frame, of: w.id) }
            }
        } catch {
            return .failed("Tiling stopped: \(error).")
        }
        var message = "Tiled \(chosen.count) window\(chosen.count == 1 ? "" : "s"): \(chosen.map(\.app).joined(separator: ", "))."
        if !missing.isEmpty { message += " Not found: \(missing.joined(separator: ", "))." }
        return .ok(message + away)
    }

    public func open(app: String) async -> CommandOutcome {
        do {
            try control.launch(app: app)
        } catch {
            return .failed("Could not open \(app): \(error).")
        }
        let step = Duration.milliseconds(150)
        var waited = Duration.zero
        while waited < launchWait {
            if case .window = TargetMatcher.resolve(app, in: control.windows(), frontmost: nil) { break }
            try? await Task.sleep(for: step)
            waited += step
        }
        return .ok("Opened \(app).")
    }

    public func smartArrange(biggest: String?) -> CommandOutcome {
        switch arranger.prepare(biggest: biggest) {
        case .failed(let outcome):
            return outcome
        case .plan(let plan, let moves, _, let note):
            var failures: [String] = []
            for move in moves {
                do { try asked { try control.setFrame(move.to, of: move.id) } } catch { failures.append("\(move.app): \(error)") }
            }
            guard failures.count < moves.count || moves.isEmpty else {
                return .failed("Could not move \(failures.joined(separator: "; ")).")
            }
            return .ok(SmartArranger.message(plan, moved: moves.count - failures.count, note: note, failed: failures))
        }
    }

    // MARK: -

    /// Every command here is the person's request, through the assistant (the gateway, ADR-2610121800).
    private func asked<T>(_ body: () throws -> T) rethrows -> T {
        try control.acting(for: .person("the assistant"), body)
    }

    /// Resolves `target`, runs `body`, and turns a thrown error into a failed outcome.
    /// A window on another desktop is refused unless `reachesOtherDesktops`: its
    /// frame is not on screen, so moving it would place it blind (ADR-2610101429).
    private func withWindow(_ target: String, reachesOtherDesktops: Bool = false,
                            _ body: (WindowSnapshot, [Display]) throws -> CommandOutcome) -> CommandOutcome {
        let all = control.windows()
        guard case .window(let w) = TargetMatcher.resolve(target, in: all, frontmost: control.frontmostWindowID(),
                                                          names: names?.names(for: all) ?? [:]) else {
            return .failed(notFound(target, in: all))
        }
        guard w.isOnCurrentDesktop || reachesOtherDesktops else {
            return .failed("\(w.app) is on \(w.desktopPhrase). Focus \(w.app) first to switch there, then ask again.")
        }
        let displays = control.displays()
        guard !displays.isEmpty else { return .failed("No display found.") }
        do {
            return try body(w, displays)
        } catch {
            return .failed("\(w.app): \(error).")
        }
    }

    private func notFound(_ target: String, in windows: [WindowSnapshot]) -> String {
        var seen = Set<String>()
        let apps = windows.map(\.app).filter { seen.insert($0).inserted }
        let list = apps.isEmpty ? "none" : apps.prefix(15).joined(separator: ", ")
        return "No window matches '\(target)'. Apps with windows: \(list)."
    }

    /// Keeps a window's place and size relative to its display when it moves to another.
    static func map(_ f: Rect, from a: Rect, to b: Rect) -> Rect {
        let sx = b.width / a.width, sy = b.height / a.height
        var r = Rect(x: b.x + (f.x - a.x) * sx, y: b.y + (f.y - a.y) * sy,
                     width: min(f.width * sx, b.width), height: min(f.height * sy, b.height))
        // Pull it back inside if it hung off the old display.
        r.x = min(max(r.x, b.minX), b.maxX - r.width)
        r.y = min(max(r.y, b.minY), b.maxY - r.height)
        return r
    }
}
