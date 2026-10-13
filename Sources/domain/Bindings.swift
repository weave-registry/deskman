// The model binds a project's windows together (ADR-2610120830). Pure rules: which
// windows to offer, which are bound, and what bound windows do when one changes.

/// The model's answer for one window: its name, and its project when it sees one.
public struct NamedWindow: Equatable, Sendable {
    public let name: String
    public let project: String?

    public init(name: String, project: String? = nil) {
        self.name = name
        self.project = project
    }

    /// "Atlas " → "atlas"; "none", "unknown" and empty → nil.
    public static func tidyProject(_ p: String?) -> String? {
        guard let p else { return nil }
        let s = p.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
        return ["", "none", "unknown", "n/a", "nil", "null", "other"].contains(s) ? nil : s
    }
}

/// "These look like one project: bind them?"
public struct BindingSuggestion: Equatable, Sendable {
    public let project: String
    public let windows: [WindowID]
    /// The model's names, or the app when a window has none, in the same order.
    public let names: [String]

    public init(project: String, windows: [WindowID], names: [String]) {
        self.project = project
        self.windows = windows
        self.names = names
    }
}

/// What a bound window does when its partner changed.
public enum Follow: Equatable, Sendable {
    case focus(WindowID)
    case restore(WindowID)
    case move(WindowID, to: Rect)
}

public enum Bindings {
    /// The first project, front to back, that two or more visible windows here share,
    /// from two or more apps, and that is neither bound nor declined.
    public static func candidate(_ windows: [WindowSnapshot], projects: [WindowID: String],
                                 bound: Set<String>, declined: Set<String>) -> BindingSuggestion? {
        let shown = windows.filter { $0.isVisible && projects[$0.id] != nil }
        var order: [String] = []
        for w in shown { if let p = projects[w.id], !order.contains(p) { order.append(p) } }
        for p in order where !bound.contains(p) && !declined.contains(p) {
            let members = shown.filter { projects[$0.id] == p }
            guard members.count >= 2, Set(members.map(\.app)).count >= 2 else { continue }
            return BindingSuggestion(project: p, windows: members.map(\.id), names: members.map(\.app))
        }
        return nil
    }

    /// One group per bound project with two or more windows: every desktop, minimized or not.
    public static func groups(_ windows: [WindowSnapshot], projects: [WindowID: String],
                              bound: Set<String>) -> [[WindowID]] {
        var order: [String] = []
        var members: [String: [WindowID]] = [:]
        for w in windows {
            guard let p = projects[w.id], bound.contains(p) else { continue }
            if members[p] == nil { order.append(p) }
            members[p, default: []].append(w.id)
        }
        return order.compactMap { members[$0]!.count >= 2 ? members[$0] : nil }
    }

    /// The same windows, with each group's members moved up to its highest member, in order.
    public static func adjacent(_ ordered: [WindowSnapshot], groups: [[WindowID]]) -> [WindowSnapshot] {
        var out: [WindowSnapshot] = []
        var placed = Set<WindowID>()
        for w in ordered where !placed.contains(w.id) {
            let group = groups.first { $0.contains(w.id) } ?? [w.id]
            for m in ordered where group.contains(m.id) && !placed.contains(m.id) {
                out.append(m)
                placed.insert(m.id)
            }
        }
        return out
    }

    /// What the partners do, from one look at the desktop to the next. A partner that is
    /// already where its lead is gets nothing, so a follow never triggers itself.
    public static func follow(before: [WindowSnapshot], after: [WindowSnapshot], frontBefore: WindowID?,
                              frontAfter: WindowID?, groups: [[WindowID]], displays: [Display]) -> [Follow] {
        let was = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Follow] = []
        for group in groups {
            let partners = { (lead: WindowID) in group.filter { $0 != lead }.compactMap { now[$0] } }

            // Focus: the person brought a member to the front.
            if let lead = frontAfter, lead != frontBefore, group.contains(lead) {
                let raise = partners(lead).filter { $0.isVisible }
                if !raise.isEmpty { out += raise.map { .focus($0.id) } + [.focus(lead)] }
            }

            for id in group {
                guard let a = was[id], let b = now[id] else { continue }
                // Restore: the partners come back too. Never minimize: Deskman minimizes nothing (2026-10-12).
                if a.isMinimized && !b.isMinimized {
                    out += partners(id).filter(\.isMinimized).map { .restore($0.id) }
                }
                // Another display: the partners still on the old one follow, at the same relative place.
                guard !b.isMinimized, b.isOnCurrentDesktop,
                      let from = Displays.containing(a.frame, in: displays),
                      let to = Displays.containing(b.frame, in: displays), from != to else { continue }
                for p in partners(id) where !p.isMinimized && Displays.containing(p.frame, in: displays) == from {
                    out.append(.move(p.id, to: map(p.frame, from: from.visibleFrame, to: to.visibleFrame)))
                }
            }
        }
        // One action per window and kind, first one wins.
        var seen: [Follow] = []
        for f in out where !seen.contains(f) || isFocus(f) { seen.append(f) }
        return seen
    }

    private static func isFocus(_ f: Follow) -> Bool {
        if case .focus = f { return true }
        return false
    }

    /// The same place, as fractions, on another display.
    static func map(_ r: Rect, from a: Rect, to b: Rect) -> Rect {
        Rect(x: b.x + (r.x - a.x) / a.width * b.width, y: b.y + (r.y - a.y) / a.height * b.height,
             width: r.width / a.width * b.width, height: r.height / a.height * b.height)
    }
}

extension NamedWindow {
    /// Which answer names each window, given the window number each answer gives: for window k
    /// (from 1), the index of its answer. Extra answers and answers for windows not asked about
    /// are dropped (2026-10-12: "2 names for 1 windows"); numbers from 0 are shifted. Numbers
    /// that do not name every window fall back to the order given, when the count is right.
    /// Nil when some window has no answer.
    public static func match(numbers: [Int], count: Int) -> [Int]? {
        guard count > 0 else { return [] }
        let shift = numbers.contains(0) && !numbers.contains(count) ? 1 : 0
        var first: [Int: Int] = [:]
        for (i, n) in numbers.enumerated() where first[n + shift] == nil { first[n + shift] = i }
        let byNumber = (1...count).compactMap { first[$0] }
        if byNumber.count == count { return byNumber }
        return numbers.count == count ? Array(0..<count) : nil
    }
}
