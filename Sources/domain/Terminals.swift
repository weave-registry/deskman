// What runs in terminals (ADR-2610101549). A job is the program in front in one
// terminal tab. Jobs are linked to windows only on evidence; otherwise they belong
// to the app, and no window is guessed.

public struct TerminalJob: Equatable, Hashable, Sendable {
    /// The terminal app, as `WindowSnapshot.app` names it ("Warp", "iTerm2").
    public let app: String
    public let tty: String
    /// The executable's name only. Never its arguments: they can hold secrets.
    public let program: String
    /// The working folder, when it can be read.
    public let folder: String?

    public init(app: String, tty: String, program: String, folder: String?) {
        self.app = app
        self.tty = tty
        self.program = program.hasPrefix("-") ? String(program.dropFirst()) : program
        self.folder = folder
    }

    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "tcsh", "csh", "ksh", "nu", "login"]

    /// Something other than a shell at its prompt.
    public var isBusy: Bool { !Self.shells.contains(program.lowercased()) }

    /// The folder's last part: "/Volumes/Crucial/projects/beacon" → "beacon". Nil for a home
    /// folder ("/Users/me") or the root: they say who, not which project.
    public var folderName: String? {
        guard let parts = folder?.split(separator: "/"), let last = parts.last else { return nil }
        if parts.count == 2, parts[0] == "Users" || parts[0] == "home" { return nil }
        return String(last)
    }

    /// "claude in beacon", or "zsh" when the folder is unknown.
    public var phrase: String { folderName.map { "\(program) in \($0)" } ?? program }
}

/// Jobs as matched to windows.
public struct TerminalMatch: Equatable, Sendable {
    public let byWindow: [WindowID: [TerminalJob]]
    /// Jobs that could be in more than one window of their app, or in none here.
    public let byApp: [String: [TerminalJob]]

    public static let none = TerminalMatch(byWindow: [:], byApp: [:])

    public init(byWindow: [WindowID: [TerminalJob]], byApp: [String: [TerminalJob]]) {
        self.byWindow = byWindow
        self.byApp = byApp
    }

    /// The windows a busy job could be in. A busy job that belongs to the app makes
    /// every window of that app busy: Deskman cannot tell which one runs it.
    public func busyWindows(among windows: [WindowSnapshot]) -> Set<WindowID> {
        var busy = Set(byWindow.filter { $0.value.contains(where: \.isBusy) }.keys)
        for (app, jobs) in byApp where jobs.contains(where: \.isBusy) {
            busy.formUnion(windows.filter { $0.app.lowercased() == app.lowercased() }.map(\.id))
        }
        return busy
    }

    public func phrases(for id: WindowID) -> [String] { Self.telling(byWindow[id] ?? []) }

    public func appPhrases(for app: String) -> [String] {
        Self.telling(byApp.first { $0.key.lowercased() == app.lowercased() }?.value ?? [])
    }

    /// What says most about a window: its busy jobs, or its shells when nothing is busy.
    /// Four idle prompts would otherwise outweigh the one program that matters.
    static func telling(_ jobs: [TerminalJob]) -> [String] {
        let busy = jobs.filter(\.isBusy)
        var seen = Set<String>()
        return (busy.isEmpty ? jobs : busy).map(\.phrase).filter { seen.insert($0).inserted }
    }
}

public enum TerminalMatcher {
    /// Strongest evidence first: the app's only window; then the one window whose
    /// title or document names the job's folder or program. Anything else stays with the app.
    public static func match(_ jobs: [TerminalJob], to windows: [WindowSnapshot]) -> TerminalMatch {
        var byWindow: [WindowID: [TerminalJob]] = [:]
        var byApp: [String: [TerminalJob]] = [:]
        for job in jobs {
            let own = windows.filter { $0.app.lowercased() == job.app.lowercased() }
            if own.count == 1 {
                byWindow[own[0].id, default: []].append(job)
                continue
            }
            let claims = own.filter { names(job, $0) }
            if claims.count == 1 {
                byWindow[claims[0].id, default: []].append(job)
            } else {
                byApp[job.app, default: []].append(job)
            }
        }
        return TerminalMatch(byWindow: byWindow, byApp: byApp)
    }

    /// The window's title or document names the job's folder or program. Short words
    /// and shell names are no evidence: "sh" is in too many titles.
    static func names(_ job: TerminalJob, _ w: WindowSnapshot) -> Bool {
        let hay = (w.title + " " + (w.document ?? "")).lowercased()
        if let f = job.folderName?.lowercased(), f.count >= 3, hay.contains(f) { return true }
        let p = job.program.lowercased()
        return job.isBusy && p.count >= 3 && hay.contains(p)
    }
}

/// Browsers by the name their windows carry. A new window of one goes beside the terminal.
/// Terminal apps, as `WindowSnapshot.app` names them.
public enum TerminalApps {
    public static let names: Set<String> = ["iterm2", "terminal", "warp", "ghostty", "kitty", "alacritty", "wezterm",
                                            "hyper", "tabby"]
    public static func contains(_ app: String) -> Bool { names.contains(app.lowercased()) }
}

public enum Browsers {
    public static let names: Set<String> = ["firefox", "safari", "google chrome", "chrome", "arc", "brave browser",
                                            "microsoft edge", "zen", "zen browser", "orion", "vivaldi", "opera", "chromium"]
    public static func contains(_ app: String) -> Bool { names.contains(app.lowercased()) }
}

/// What the namer is told about one window.
public struct NamingSubject: Equatable, Sendable {
    public let window: WindowSnapshot
    /// Jobs that run in this window ("claude in deskman").
    public let jobs: [String]
    /// Jobs that run in some window of this app, maybe this one.
    public let appJobs: [String]

    public init(window: WindowSnapshot, jobs: [String] = [], appJobs: [String] = []) {
        self.window = window
        self.jobs = jobs
        self.appJobs = appJobs
    }
}
