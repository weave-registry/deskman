// Learning by counting (ADR-2610101415). No model: a habit is a placement seen
// often enough, in situations similar enough, to be worth repeating.

/// Where a window sits, relative to its display's visible frame, rounded to a
/// 1/60 grid — it holds halves, thirds, quarters and the center layout exactly —
/// so a few points of drift do not split one habit into many.
public struct Placement: Hashable, Codable, Sendable {
    public let display: Int
    /// Fractions of the visible frame, 0…1.
    public let rect: Rect

    public init(display: Int, rect: Rect) {
        self.display = display
        self.rect = rect
    }

    public static func of(_ frame: Rect, on display: Display) -> Placement {
        let v = display.visibleFrame
        func snap(_ x: Double) -> Double { (x * 60).rounded() / 60 }
        return Placement(display: display.index, rect: Rect(
            x: snap((frame.x - v.x) / v.width), y: snap((frame.y - v.y) / v.height),
            width: snap(frame.width / v.width), height: snap(frame.height / v.height)))
    }

    public func frame(on display: Display) -> Rect {
        let v = display.visibleFrame
        return Rect(x: v.x + rect.x * v.width, y: v.y + rect.y * v.height,
                    width: rect.width * v.width, height: rect.height * v.height)
    }

    /// Plain words: "the left half", "the right third of display 2", or the size
    /// when the place is no named layout.
    public var phrase: String {
        let unit = Display(index: display, visibleFrame: Rect(x: 0, y: 0, width: 1, height: 1))
        func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
        // Within one grid step of a layout counts as that layout: macOS often leaves a window a row short.
        func near(_ a: Rect, _ b: Rect) -> Bool {
            let step = 1.0 / 60 + 1e-9
            return abs(a.x - b.x) <= step && abs(a.y - b.y) <= step
                && abs(a.width - b.width) <= step && abs(a.height - b.height) <= step
        }
        let place = Layout.allCases.first { near(Placement.of($0.frame(in: unit.visibleFrame), on: unit).rect, rect) }?.phrase
            ?? "a spot \(percent(rect.width)) wide, \(percent(rect.height)) tall"
        return display == 0 ? place : place + " of display \(display + 1)"
    }
}

public struct WindowRecord: Equatable, Codable, Sendable {
    public let app: String
    public let title: String
    public let placement: Placement
    public let isMinimized: Bool
    /// True when Deskman put the window there and the person has not moved it
    /// since. Such a place is no evidence of a habit. Nil in records before 2026-10-10.
    public let byDeskman: Bool?
}

/// One settled arrangement of the desktop.
public struct DeskSnapshot: Equatable, Codable, Sendable {
    public let time: Double
    public let displayCount: Int
    public let focusedApp: String?
    public let windows: [WindowRecord]

    public init(time: Double, windows: [WindowSnapshot], displays: [Display], focusedApp: String?,
                placedByDeskman: Set<WindowID> = []) {
        self.time = time
        self.displayCount = displays.count
        self.focusedApp = focusedApp
        // Only the current desktop: another desktop's frames are not on screen (ADR-2610101429).
        self.windows = windows.filter(\.isOnCurrentDesktop).compactMap { w in
            guard let d = Displays.containing(w.frame, in: displays) else { return nil }
            return WindowRecord(app: w.app, title: w.title, placement: .of(w.frame, on: d), isMinimized: w.isMinimized,
                                byDeskman: placedByDeskman.contains(w.id) ? true : nil)
        }
    }

    public var context: ContextKey {
        ContextKey(apps: windows.filter { !$0.isMinimized }.map(\.app), displays: displayCount)
    }
}

/// A situation: which apps have visible windows, on how many displays.
public struct ContextKey: Hashable, Codable, Sendable {
    public let apps: [String]
    public let displays: Int

    public init(apps: some Sequence<String>, displays: Int) {
        self.apps = Array(Set(apps)).sorted()
        self.displays = displays
    }

    public var id: String { "\(displays)|" + apps.joined(separator: ",") }

    public func similarity(to other: ContextKey) -> Double {
        guard displays == other.displays else { return 0 }
        let a = Set(apps), b = Set(other.apps)
        let union = a.union(b).count
        return union == 0 ? 1 : Double(a.intersection(b).count) / Double(union)
    }
}

/// What Deskman knows about one app, for the person to see: its most frequent
/// place across all history, and whether that is strong enough to act on.
public struct Habit: Equatable, Sendable {
    public let app: String
    public let placement: Placement
    /// Sightings in `placement`.
    public let support: Int
    /// All sightings of the app, not minimized.
    public let sightings: Int
    /// True when `Learner` would move the app's window there.
    public let isLearned: Bool
    /// The person said so on the map, so no sightings are needed.
    public var isConfirmed: Bool = false

    public init(app: String, placement: Placement, support: Int, sightings: Int, isLearned: Bool, isConfirmed: Bool = false) {
        self.app = app
        self.placement = placement
        self.support = support
        self.sightings = sightings
        self.isLearned = isLearned
        self.isConfirmed = isConfirmed
    }
}

public struct Move: Equatable, Sendable {
    public let id: WindowID
    public let app: String
    public let from: Rect
    public let to: Rect

    public init(id: WindowID, app: String, from: Rect, to: Rect) {
        self.id = id
        self.app = app
        self.from = from
        self.to = to
    }
}

public struct Suggestion: Equatable, Sendable {
    public let context: ContextKey
    public let moves: [Move]
    /// The fewest sightings behind any one move.
    public let evidence: Int

    public init(context: ContextKey, moves: [Move], evidence: Int) {
        self.context = context
        self.moves = moves
        self.evidence = evidence
    }

    public var summary: String {
        var seen = Set<String>()
        let apps = moves.map(\.app).filter { seen.insert($0).inserted }
        return apps.count == 1 ? "Put \(apps[0]) where you usually do" : "Arrange \(apps.joined(separator: ", ")) like usual"
    }
}

public enum TickResult: Equatable, Sendable {
    case idle
    case suggested(Suggestion)
    case autoApplied(Suggestion)
    /// A new browser window went beside this terminal app (ADR-2610101501 queue item 4).
    case placedBeside(Suggestion, terminal: String)
}

public enum Learner {
    /// The fewest sightings behind a habit.
    public static let minSupport = 3

    /// One habit per app seen in `history`: learned ones first, then the most seen.
    public static func habits(in history: [DeskSnapshot], confirmed: [String: Placement] = [:],
                              minSupport: Int = minSupport, minShare: Double = 0.6) -> [Habit] {
        var order: [String] = []
        var counts: [String: [(placement: Placement, n: Int)]] = [:]
        for r in history.flatMap(\.windows) where !r.isMinimized && r.byDeskman != true {
            if counts[r.app] == nil { order.append(r.app) }
            if let i = counts[r.app]?.firstIndex(where: { $0.placement == r.placement }) {
                counts[r.app]![i].n += 1
            } else {
                counts[r.app, default: []].append((r.placement, 1))
            }
        }
        // A confirmed app with no sightings still has a habit to show.
        for app in confirmed.keys.sorted() where counts[app] == nil {
            order.append(app)
            counts[app] = [(confirmed[app]!, 0)]
        }
        let habits = order.map { app -> Habit in
            let places = counts[app]!
            if let place = confirmed[app] {
                let n = places.first { $0.placement == place }?.n ?? 0
                return Habit(app: app, placement: place, support: n, sightings: places.reduce(0) { $0 + $1.n },
                             isLearned: true, isConfirmed: true)
            }
            // The first place to reach the top count wins a tie, so the list does not flicker.
            let top = places.reduce(places[0]) { $1.n > $0.n ? $1 : $0 }
            // Learned means exactly what the suggestions use, never a second opinion.
            let learned = usualPlacement(app: app, qualifier: nil, in: history,
                                         minSupport: minSupport, minShare: minShare) != nil
            return Habit(app: app, placement: top.placement, support: top.n,
                         sightings: places.reduce(0) { $0 + $1.n }, isLearned: learned)
        }
        return habits.sorted { a, b in
            if a.isLearned != b.isLearned { return a.isLearned }
            if a.sightings != b.sightings { return a.sightings > b.sightings }
            return a.app < b.app
        }
    }

    /// Moves that put each visible window in its usual place, or nil when no
    /// window has a habit strong enough or every window is already there.
    public static func suggestion(for windows: [WindowSnapshot], displays: [Display], history: [DeskSnapshot],
                                  confirmed: [String: Placement] = [:], minSupport: Int = minSupport, minShare: Double = 0.6,
                                  minSimilarity: Double = 0.6) -> Suggestion? {
        let visible = windows.filter(\.isVisible)
        let context = ContextKey(apps: visible.map(\.app), displays: displays.count)
        let similar = history.filter { $0.context.similarity(to: context) >= minSimilarity }
        guard !similar.isEmpty || !confirmed.isEmpty else { return nil }

        var moves: [Move] = []
        var evidence = Int.max
        var taken = Set<Placement>()
        for w in visible {
            let confirmedHabit = confirmed[w.app].map { (placement: $0, support: minSupport) }
            guard let habit = confirmedHabit ?? usualPlacement(app: w.app, qualifier: qualifier(w.title), in: similar,
                                                               minSupport: minSupport, minShare: minShare),
                  displays.indices.contains(habit.placement.display),
                  !taken.contains(habit.placement) else { continue }
            taken.insert(habit.placement)
            let display = displays[habit.placement.display]
            guard let current = Displays.containing(w.frame, in: displays),
                  Placement.of(w.frame, on: current) != habit.placement else { continue }
            moves.append(Move(id: w.id, app: w.app, from: w.frame, to: habit.placement.frame(on: display)))
            evidence = min(evidence, habit.support)
        }
        return moves.isEmpty ? nil : Suggestion(context: context, moves: moves, evidence: evidence)
    }

    /// The most frequent placement of this app's windows. Windows whose title
    /// qualifier matches count first; the whole app counts only when they are too few.
    static func usualPlacement(app: String, qualifier q: String?, in history: [DeskSnapshot],
                               minSupport: Int, minShare: Double) -> (placement: Placement, support: Int)? {
        // Deskman's own placements are not the person's habit: learning from them would echo.
        let records = history.flatMap(\.windows).filter { $0.app == app && !$0.isMinimized && $0.byDeskman != true }
        let qualified = q.map { q in records.filter { qualifier($0.title) == q } } ?? []
        let pool = qualified.count >= minSupport ? qualified : records
        guard pool.count >= minSupport else { return nil }

        var counts: [Placement: Int] = [:]
        for r in pool { counts[r.placement, default: 0] += 1 }
        guard let (placement, n) = counts.max(by: { $0.value < $1.value }),
              Double(n) / Double(pool.count) >= minShare else { return nil }
        return (placement, n)
    }

    /// The last segment of a title, lowercased: "README.md — deskman" → "deskman".
    /// Apps put the project or app name there; a title with one segment has none.
    public static func qualifier(_ title: String) -> String? {
        for separator in [" — ", " – ", " - "] {
            let parts = title.split(separator: separator, omittingEmptySubsequences: true)
            if parts.count >= 2, let last = parts.last {
                let q = String(last).lowercased().trimmingWhitespace()
                return q.isEmpty || q.count > 40 ? nil : q
            }
        }
        return nil
    }
}

/// Per situation: how often its suggestion was accepted, and whether it is snoozed.
public struct TrustLedger: Equatable, Codable, Sendable {
    public static let acceptsToAutomate = 3
    public static let snoozeSeconds = 3600.0

    public private(set) var accepts: [String: Int] = [:]
    public private(set) var snoozedUntil: [String: Double] = [:]
    /// Places the person confirmed on the map, by app. Optional, so a ledger
    /// written before it existed still decodes instead of resetting all trust.
    private var confirmed: [String: Placement]?

    public var confirmedPlaces: [String: Placement] { confirmed ?? [:] }

    public mutating func confirm(app: String, placement: Placement) {
        confirmed = confirmedPlaces.merging([app: placement]) { _, new in new }
    }

    public init() {}

    public mutating func recordAccept(_ c: ContextKey) {
        accepts[c.id, default: 0] += 1
    }

    /// A dismissal, or an undo of an automatic move: trust starts again from zero.
    public mutating func recordDismiss(_ c: ContextKey, now: Double) {
        accepts[c.id] = 0
        snoozedUntil[c.id] = now + Self.snoozeSeconds
    }

    public func isAutomatic(_ c: ContextKey) -> Bool {
        (accepts[c.id] ?? 0) >= Self.acceptsToAutomate
    }

    public func isSnoozed(_ c: ContextKey, now: Double) -> Bool {
        (snoozedUntil[c.id] ?? 0) > now
    }
}
