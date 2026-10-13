import DeskmanPorts

/// The apps Deskman leaves alone and the drag-to-snap switch (ADR-2610120742).
/// Smart Arrange, learning and drag-to-snap ask it; a request that names a window does not.
@MainActor public final class Settings: SettingsPort {
    private let store: any PreferenceStore
    private let control: (any WindowControl)?
    private var current: Preferences
    public private(set) var problem: String?

    /// `control` finds the front window for `toggleFloatingFrontmost`.
    public init(store: any PreferenceStore, control: (any WindowControl)?) {
        self.store = store
        self.control = control
        do {
            current = try store.load()
        } catch {
            // Run on the defaults, say why, and leave the file alone until the person changes something.
            current = Preferences()
            problem = "Deskman could not read its saved preferences, so it uses the defaults: \(error)."
        }
    }

    public var floatingApps: [String] {
        current.floatingApps.sorted { $0.lowercased() < $1.lowercased() }
    }

    public func isFloating(_ app: String) -> Bool { current.isFloating(app) }

    /// The windows Deskman may move on its own: every one whose app is not floating.
    public func movable(_ windows: [WindowSnapshot]) -> [WindowSnapshot] {
        windows.filter { !current.isFloating($0.app) }
    }

    public func setFloating(_ app: String, _ on: Bool) -> CommandOutcome {
        // Already on the list: keep the spelling it was added with.
        if !on { current.floatingApps.removeAll { $0.lowercased() == app.lowercased() } }
        if on && !current.isFloating(app) { current.floatingApps.append(app) }
        return save(on ? "Deskman leaves \(app) alone." : "Deskman arranges \(app) again.")
    }

    public func toggleFloatingFrontmost() -> CommandOutcome {
        guard let control, let id = control.frontmostWindowID(),
              let app = control.windows().first(where: { $0.id == id })?.app else {
            return .failed("There is no window in front.")
        }
        return setFloating(app, !isFloating(app))
    }

    public var boundProjects: [String] { current.boundProjects.sorted() }
    public var declinedProjects: [String] { current.declinedProjects }

    /// Bind or unbind a project (ADR-2610120830). Binding clears an earlier "Not now".
    func setBound(_ project: String, _ on: Bool, done: String) -> CommandOutcome {
        current.boundProjects.removeAll { $0 == project }
        if on {
            current.boundProjects.append(project)
            current.declinedProjects.removeAll { $0 == project }
        }
        return save(done)
    }

    func decline(_ project: String, done: String) -> CommandOutcome {
        if !current.declinedProjects.contains(project) { current.declinedProjects.append(project) }
        return save(done)
    }

    public var keepArranged: Bool { current.keepArranged }

    func setKeepArranged(_ on: Bool) -> CommandOutcome {
        current.keepArranged = on
        return save(on ? "Keep Arranged is on: Smart Arrange runs each time your windows change."
                       : "Keep Arranged is off.")
    }

    public var dragSnap: Bool { current.dragSnap }

    public func setDragSnap(_ on: Bool) -> CommandOutcome {
        current.dragSnap = on
        return save(on ? "Drag to snap is on." : "Drag to snap is off. The snap keys still work.")
    }

    private func save(_ done: String) -> CommandOutcome {
        do {
            try store.save(current)
            problem = nil
            return .ok(done)
        } catch {
            return .failed(done + " But Deskman could not save this, so it will forget it when it quits: \(error).")
        }
    }
}
