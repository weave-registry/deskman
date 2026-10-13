import DeskmanPorts

/// The model's names for windows, kept for the session (ADR-2610101542). Keyed by
/// window, app, title, document and the window's own terminal jobs (ADR-2610101549), so a
/// change in any of them is named again. The window is in the key because two windows
/// that look the same still need two names. Reads never wait for the model.
@MainActor public final class WindowNames {
    static let batch = 12

    private let namer: any WindowNamer
    private var byKey: [String: String] = [:]
    /// The model's project for each key (ADR-2610120830); a key without one has none.
    private var projectByKey: [String: String] = [:]
    /// The key each window had at the last refresh, so reads match what was named.
    private var keyOf: [WindowID: String] = [:]
    private var busy = false
    /// Why the last refresh failed, or nil when it did not.
    public private(set) var lastError: String?

    public init(namer: any WindowNamer) {
        self.namer = namer
    }

    public func name(for w: WindowSnapshot) -> String? {
        byKey[keyOf[w.id] ?? Self.key(w, jobs: [])]
    }

    public func project(for w: WindowSnapshot) -> String? {
        projectByKey[keyOf[w.id] ?? Self.key(w, jobs: [])]
    }

    public func projects(for windows: [WindowSnapshot]) -> [WindowID: String] {
        var out: [WindowID: String] = [:]
        for w in windows { if let p = project(for: w) { out[w.id] = p } }
        return out
    }

    public func names(for windows: [WindowSnapshot]) -> [WindowID: String] {
        var out: [WindowID: String] = [:]
        for w in windows { if let n = name(for: w) { out[w.id] = n } }
        return out
    }

    /// Names up to 12 windows that have a title or a job and no name yet. One refresh at a time.
    public func refresh(_ windows: [WindowSnapshot], terminals: TerminalMatch = .none) async {
        guard !busy else { return }
        var seen = Set<String>()
        var unnamed: [NamingSubject] = []
        for w in windows {
            let jobs = terminals.phrases(for: w.id)
            let k = Self.key(w, jobs: jobs)
            keyOf[w.id] = k
            guard !w.title.trimmingWhitespace().isEmpty || !jobs.isEmpty, byKey[k] == nil,
                  seen.insert(k).inserted, unnamed.count < Self.batch else { continue }
            unnamed.append(NamingSubject(window: w, jobs: jobs, appJobs: terminals.appPhrases(for: w.app)))
        }
        // Nothing left to name means nothing failed: an old error no longer applies.
        guard !unnamed.isEmpty else { lastError = nil; return }
        busy = true
        defer { busy = false }
        do {
            let got = try await namer.names(for: unnamed)
            guard got.count == unnamed.count else {
                // A short answer cannot be matched to windows safely: name none.
                lastError = "the model gave \(got.count) names for \(unnamed.count) windows"
                return
            }
            // Only names a window holds now: a renamed window's old name must not block its new one.
            let live = Set(keyOf.values)
            var taken = Set(byKey.filter { live.contains($0.key) }.values.map { $0.lowercased() })
            for (s, n) in zip(unnamed, got) {
                let w = s.window
                let k = Self.key(w, jobs: s.jobs)
                let project = NamedWindow.tidyProject(n.project)
                projectByKey[k] = project
                var clean = Self.tidy(n.name, app: w.app)
                // Given a project field, the model drops the project from the name: two terminals
                // both came back "Claude Code" (2026-10-12). The name must still say which.
                if let project, !clean.isEmpty, !clean.lowercased().contains(project) {
                    clean = project.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
                        .joined(separator: " ") + " " + clean
                }
                guard !clean.isEmpty else { continue }
                // A name finds one window: two the same would defeat it.
                if taken.contains(clean.lowercased()) {
                    var i = 2
                    while taken.contains("\(clean) \(i)".lowercased()) { i += 1 }
                    clean = "\(clean) \(i)"
                }
                taken.insert(clean.lowercased())
                byKey[k] = clean
            }
            lastError = nil
            if byKey.count > 500 {
                byKey = byKey.filter { k, _ in keyOf.values.contains(k) }
                projectByKey = projectByKey.filter { k, _ in keyOf.values.contains(k) }
            }
        } catch {
            lastError = "\(error)"
        }
    }

    /// The model sometimes copies the list's "App: " prefix and quotes; drop them.
    public static func tidy(_ name: String, app: String) -> String {
        var s = name.trimmingWhitespace()
        for q in ["\"", "'", "“", "”"] { s = s.replacing(q, with: "") }
        if s.lowercased().hasPrefix(app.lowercased() + ":") { s = String(s.dropFirst(app.count + 1)) }
        while let last = s.last, ".,;:".contains(last) { s.removeLast() }
        s = s.trimmingWhitespace()
        // The model sometimes answers all in lowercase ("claude in atlas").
        if let first = s.first, first.isLowercase { s = first.uppercased() + s.dropFirst() }
        return s
    }

    private static func key(_ w: WindowSnapshot, jobs: [String]) -> String {
        [w.id.raw, w.app, w.title, w.document ?? "", jobs.joined(separator: ",")].joined(separator: "\u{1F}")
    }
}
