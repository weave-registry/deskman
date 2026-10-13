import DeskmanPorts

/// Windows of one project, bound together by the person on the model's suggestion
/// (ADR-2610120830). They arrange side by side, focus, move and minimize as one.
/// The rules are the domain's `Bindings`; this class keeps the last look and acts.
@MainActor public final class BindingService: BindingPort {
    private let control: any WindowControl
    private let names: WindowNames
    private let settings: Settings
    private var last: (windows: [WindowSnapshot], front: WindowID?)?

    public init(control: any WindowControl, names: WindowNames, settings: Settings) {
        self.control = control
        self.names = names
        self.settings = settings
    }

    public var boundProjects: [String] { settings.boundProjects }

    /// A project the model gave two apps' windows here, not yet bound or declined.
    public func suggestion() -> BindingSuggestion? {
        let windows = settings.movable(control.windows())
        guard let s = Bindings.candidate(windows, projects: names.projects(for: windows),
                                         bound: Set(settings.boundProjects), declined: Set(settings.declinedProjects))
        else { return nil }
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return BindingSuggestion(project: s.project, windows: s.windows,
                                 names: s.windows.compactMap { byID[$0] }.map { names.name(for: $0) ?? $0.app })
    }

    public func bind(_ project: String) -> CommandOutcome {
        last = nil
        return settings.setBound(project, true, done: "Bound the \(project) windows: they now arrange, focus, move and minimize together.")
    }

    public func decline(_ project: String) -> CommandOutcome {
        settings.decline(project, done: "Deskman will not ask about \(project) again.")
    }

    public func unbind(_ project: String) -> CommandOutcome {
        last = nil
        return settings.setBound(project, false, done: "Unbound the \(project) windows.")
    }

    /// The bound groups among `windows`. Floating apps are never bound.
    public func groups(_ windows: [WindowSnapshot]) -> [[WindowID]] {
        let movable = settings.movable(windows)
        return Bindings.groups(movable, projects: names.projects(for: movable), bound: Set(settings.boundProjects))
    }

    /// The other members of `id`'s group.
    public func partners(of id: WindowID, in windows: [WindowSnapshot]) -> [WindowSnapshot] {
        guard let group = groups(windows).first(where: { $0.contains(id) }) else { return [] }
        return windows.filter { group.contains($0.id) && $0.id != id }
    }

    /// The project of each bound window, for the map.
    public func boundProject(of windows: [WindowSnapshot]) -> [WindowID: String] {
        let grouped = Set(groups(windows).flatMap { $0 })
        return names.projects(for: windows).filter { grouped.contains($0.key) }
    }

    /// One look at the desktop. Call it every second. With nothing bound it reads nothing.
    public func observe() {
        guard !settings.boundProjects.isEmpty else { last = nil; return }
        let windows = control.windows()
        let front = control.frontmostWindowID()
        defer { last = (windows, front) }
        guard let last else { return }
        // During a meeting partners do not follow: in a share, one popping up shows to everyone (MeetingApps).
        guard !MeetingApps.inMeeting(windows) else { return }
        let follows = Bindings.follow(before: last.windows, after: windows, frontBefore: last.front, frontAfter: front,
                                      groups: groups(windows), displays: control.displays())
        control.acting(for: .automatic("a bound project")) {
            for f in follows {
                // A partner that refuses (closed meanwhile, another desktop, the gateway) is skipped, not fatal.
                switch f {
                case .focus(let id): try? control.perform(.focus, on: id)
                case .restore(let id): try? control.perform(.restore, on: id)
                case .move(let id, let to): try? control.setFrame(to, of: id)
                }
            }
        }
    }
}
