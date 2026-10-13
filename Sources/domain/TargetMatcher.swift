public enum TargetResolution: Equatable, Sendable {
    case window(WindowSnapshot)
    case notFound
}

/// Turns the words a person (or the model) uses for a window into one window.
public enum TargetMatcher {
    static let frontAliases: Set<String> = ["", "front", "frontmost", "this", "current", "active", "focused", "it", "that"]

    /// `names`: the model's names for windows (ADR-2610101542); a window is found by its name too.
    public static func resolve(_ query: String, in windows: [WindowSnapshot], frontmost: WindowID?,
                               names: [WindowID: String] = [:]) -> TargetResolution {
        let q = normalize(query)

        if frontAliases.contains(q) {
            guard let frontmost, let w = windows.first(where: { $0.id == frontmost }) else { return .notFound }
            return .window(w)
        }

        // Highest score wins; ties go to the frontmost window, then to a visible
        // one, then a minimized one, then one on another desktop, then to the
        // first in the list (the system's front-to-back order).
        let scored = windows.enumerated().compactMap { i, w -> (score: Int, rank: Int, w: WindowSnapshot)? in
            let s = max(score(q, w), nameScore(q, names[w.id]))
            guard s > 0 else { return nil }
            let rank = (w.id == frontmost ? 0 : 4) + (w.isMinimized ? 1 : 0) + (w.isOnCurrentDesktop ? 0 : 2)
            return (s, rank * 10_000 + i, w)
        }
        let best = scored.min { a, b in a.score != b.score ? a.score > b.score : a.rank < b.rank }
        guard let best else { return .notFound }
        return .window(best.w)
    }

    static func normalize(_ s: String) -> String {
        var q = s.lowercased().trimmingWhitespace()
        for prefix in ["the ", "my "] where q.hasPrefix(prefix) { q.removeFirst(prefix.count) }
        for suffix in [" windows", " window", " app"] where q.hasSuffix(suffix) { q.removeLast(suffix.count) }
        return q.trimmingWhitespace()
    }

    /// Below an exact app name (100), above a partial app match: a name is what the person sees.
    static func nameScore(_ q: String, _ name: String?) -> Int {
        guard let name = name?.lowercased(), !q.isEmpty else { return 0 }
        if name == q { return 90 }
        if name.contains(q) { return 70 }
        let words: [String] = q.split(separator: " ").map(String.init).filter { $0.count >= 3 }
        let have: Set<String> = Set(name.split(separator: " ").map(String.init))
        return !words.isEmpty && words.allSatisfy { have.contains($0) } ? 58 : 0
    }

    static func score(_ q: String, _ w: WindowSnapshot) -> Int {
        let app = w.app.lowercased(), title = w.title.lowercased()
        if app == q { return 100 }
        if title == q { return 80 }
        if app.hasPrefix(q) { return 60 }
        if q.contains(app) { return 55 }
        if app.contains(q) { return 50 }
        if title.contains(q) { return 40 }
        return 0
    }
}

public extension String {
    func trimmingWhitespace() -> String {
        var s = Substring(self)
        while s.first?.isWhitespace == true { s.removeFirst() }
        while s.last?.isWhitespace == true { s.removeLast() }
        return String(s)
    }
}
