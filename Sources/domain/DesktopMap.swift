// Everything the desktop map draws (ADR-2610101523 §3). The view paints this and
// computes nothing: where windows are, where Smart Arrange would put them, and
// what Deskman has learned. Frames are screen coordinates, top-left, y down.

public struct DesktopMap: Equatable, Sendable {
    /// A zone Smart Arrange would use, and the app that would get it.
    public struct PlannedZone: Equatable, Sendable {
        public let frame: Rect
        public let app: String
        public let isMain: Bool
        /// The window that would go here, so the map can show its name.
        public let window: WindowID?

        public init(frame: Rect, app: String, isMain: Bool, window: WindowID? = nil) {
            self.frame = frame
            self.app = app
            self.isMain = isMain
            self.window = window
        }
    }

    /// An app's usual place: green when learned, red while still learning.
    public struct HabitZone: Equatable, Sendable {
        public let frame: Rect
        public let habit: Habit

        public init(frame: Rect, habit: Habit) {
            self.frame = frame
            self.habit = habit
        }
    }

    public let displays: [Display]
    /// On the current desktop and not minimized, front to back.
    public let windows: [WindowSnapshot]
    /// Minimized, or on another desktop.
    public let hiddenCount: Int
    /// Not minimized, on another desktop: where each one sits there.
    public let otherDesktops: [WindowSnapshot]
    public let plan: [PlannedZone]
    /// Apps Smart Arrange has no room for at a usable size: left where they are, never minimized.
    public let parked: [String]
    /// Windows placed by hand, which Smart Arrange keeps.
    public let pinned: Set<WindowID>
    public let habits: [HabitZone]
    /// The model's names, by window. A window without one shows app and title.
    public let names: [WindowID: String]
    /// Why naming failed last, if it did.
    public let namingProblem: String?
    /// What runs in each terminal window ("claude in deskman").
    public let jobs: [WindowID: [String]]
    /// The project of each bound window (ADR-2610120830).
    public let bound: [WindowID: String]
    /// Who made the Smart Arrange plan: the model, with its reason, or Deskman's rules, with why.
    public let planNote: String?
    /// Everything Deskman knows, in words, for What Deskman Knows (ADR-2610121600).
    public let knowledge: Knowledge
    /// The learned grid of each display, by index (ADR-2610131157); absent: the standard grid.
    public let grids: [Int: GridShape]

    public init(displays: [Display], windows: [WindowSnapshot], hiddenCount: Int, otherDesktops: [WindowSnapshot] = [],
                plan: [PlannedZone], parked: [String], pinned: Set<WindowID>, habits: [HabitZone],
                names: [WindowID: String] = [:], namingProblem: String? = nil, jobs: [WindowID: [String]] = [:],
                bound: [WindowID: String] = [:], planNote: String? = nil, knowledge: Knowledge = .empty,
                grids: [Int: GridShape] = [:]) {
        self.grids = grids
        self.knowledge = knowledge
        self.jobs = jobs
        self.bound = bound
        self.planNote = planNote
        self.names = names
        self.namingProblem = namingProblem
        self.displays = displays
        self.windows = windows
        self.hiddenCount = hiddenCount
        self.otherDesktops = otherDesktops
        self.plan = plan
        self.parked = parked
        self.pinned = pinned
        self.habits = habits
    }

    /// Habits that share one place, drawn as one box with a line per app.
    /// Boxes with a still-learning app come first, so learned ones are drawn on top.
    public var habitGroups: [(frame: Rect, habits: [Habit])] {
        var order: [Rect] = []
        var groups: [Rect: [Habit]] = [:]
        for h in habits {
            if groups[h.frame] == nil { order.append(h.frame) }
            groups[h.frame, default: []].append(h.habit)
        }
        return order.map { ($0, groups[$0]!) }
            .sorted { a, b in
                let la = a.habits.allSatisfy(\.isLearned), lb = b.habits.allSatisfy(\.isLearned)
                return !la && lb
            }
    }

    /// The desktop numbers that have windows elsewhere, in order. Nil numbers are left out.
    public var otherDesktopNumbers: [Int] {
        Array(Set(otherDesktops.compactMap(\.desktop))).sorted()
    }

    /// The smallest rectangle holding every display: what the map scales to fit.
    public var bounds: Rect {
        let frames = displays.map(\.visibleFrame)
        guard !frames.isEmpty else { return Rect(x: 0, y: 0, width: 1, height: 1) }
        let x0 = frames.map(\.x).min()!, y0 = frames.map(\.y).min()!
        let x1 = frames.map(\.maxX).max()!, y1 = frames.map(\.maxY).max()!
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

extension DesktopMap {
    /// Everything Deskman knows, in words, for What Deskman Knows (ADR-2610121600). Nothing here is
    /// stored and nothing moves a window: it is what the use cases already hold, put in sentences.
    public struct Knowledge: Equatable, Sendable {
        public struct Section: Equatable, Sendable {
            public let title: String
            public let lines: [String]
            /// Per line: the habit the person may confirm, for a habit still learning; else nil.
            public let confirmable: [Habit?]

            init(title: String, lines: [String], confirmable: [Habit?]? = nil) {
                self.title = title
                self.lines = lines
                self.confirmable = confirmable ?? lines.map { _ in nil }
            }
        }

        public static let nothingYet = "Nothing yet"
        /// One focus sample per learning tick (FocusTracker).
        public static let sampleSeconds = 5.0

        public let sections: [Section]

        public static let empty = Knowledge(sections: [])

        /// Samples as minutes in front: "<1 min", "2 min".
        public static func minutes(_ samples: Int) -> String {
            let seconds = Double(samples) * sampleSeconds
            return seconds < 60 ? "<1 min" : "\(Int((seconds / 60).rounded())) min"
        }

        /// `focus`: samples per window in the last 30 minutes. `names`: the model's names.
        /// `zones`: each window's place in the grid ("zone 3"). The five most used windows, ties by name.
        public static func build(windows: [WindowSnapshot], focus: [WindowID: Int], names: [WindowID: String],
                                 zones: [WindowID: String], keepArranged: String, bound: [String],
                                 habits: [Habit] = [], displays: [Display] = [], grids: [Int: GridShape] = [:],
                                 grid: String = "") -> Knowledge {
            let name = { (w: WindowSnapshot) in names[w.id] ?? "\(w.app) — \(w.title.prefix(40))" }
            let used = windows.filter { (focus[$0.id] ?? 0) > 0 }
                .sorted { (focus[$1.id] ?? 0, name($0)) < (focus[$0.id] ?? 0, name($1)) }
                .prefix(5)
                .map { "\(name($0)): \(minutes(focus[$0.id] ?? 0))" }
            // Which grid it is comes first: the learned one, or the standard one (ADR-2610131157 §7).
            let placed = (grid.isEmpty ? [] : [grid]) + windows.compactMap { w in zones[w.id].map { "\(name(w)): \($0)" } }
            let state = keepArranged.isEmpty ? [] : [keepArranged]
            func section(_ title: String, _ lines: [String]) -> Section {
                Section(title: title, lines: lines.isEmpty ? [nothingYet] : lines)
            }
            // Habits as lines, learned first (the user, 2026-10-13: the strip overlapped its labels).
            let ordered = habits.sorted { ($0.isLearned ? 0 : 1, $0.app) < ($1.isLearned ? 0 : 1, $1.app) }
            // In the person's grid terms when the place is one of its zones (the user, 2026-10-13).
            let place = { (h: Habit) -> String in
                guard displays.indices.contains(h.placement.display) else { return h.placement.phrase }
                let d = displays[h.placement.display]
                return GridPlanner.zoneLabel(of: h.placement.frame(on: d), on: d, shape: grids[d.index]) ?? h.placement.phrase
            }
            let habitLines = ordered.map { h in
                h.isLearned ? "✓ \(h.app): \(place(h)) (\(h.isConfirmed ? "you chose this" : "\(h.support) of \(h.sightings)"))"
                    : "… \(h.app): still learning, seen \(h.sightings)×, mostly \(place(h))"
            }
            let habitSection = habitLines.isEmpty ? section("Habits", [])
                : Section(title: "Habits", lines: habitLines, confirmable: ordered.map { $0.isLearned ? nil : $0 })
            return Knowledge(sections: [habitSection, section("Most used now", Array(used)), section("Your grid", placed),
                                        section("Keep Arranged", state), section("Bound projects", bound)])
        }
    }
}
