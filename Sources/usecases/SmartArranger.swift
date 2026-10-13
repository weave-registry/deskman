import DeskmanPorts

/// Plans and applies Smart Arrange (ADR-2610101501, ADR-2610101523). The model's tool reaches it
/// through `WindowService`; the menu through `ActivityService`, which keeps the
/// moves for undo. The decisions are the domain's `ZonePlanner`.
@MainActor public final class SmartArranger {
    enum Prepared {
        /// `parked`: windows with no room at a usable size. Never minimized (the user, 2026-10-12:
        /// "we should never minimize an app"): not moved, left where they are.
        case plan(ZonePlan, moves: [Move], parked: [WindowSnapshot], note: String?)
        case failed(CommandOutcome)
    }

    private let control: any WindowControl
    private let history: (any ActivityStore)?
    private let focus: FocusTracker?
    private let intents: IntentLog?
    private let settings: Settings?
    private let bindings: BindingService?
    /// The learned grid (ADR-2610131157); without it, the standard one.
    private let grid: LearnedGrid?

    /// Without `history` and `focus`, front-to-back order alone decides who gets the most room.
    public init(control: any WindowControl, history: (any ActivityStore)?,
                focus: FocusTracker? = nil, intents: IntentLog? = nil,
                settings: Settings? = nil, bindings: BindingService? = nil, grid: LearnedGrid? = nil) {
        self.grid = grid
        self.settings = settings
        self.bindings = bindings
        self.control = control
        self.history = history
        self.focus = focus
        self.intents = intents
    }

    /// `keep`: windows the person just opened or brought back. They are why Keep Arranged runs:
    /// never idle, placed first. With the window in front, never moved out of the way.
    /// `hold`: the window the person is working in, when Keep Arranged runs. It stays exactly where
    /// it is and the others are planned around it (the user, 2026-10-12: moving it makes you dizzy).
    func prepare(biggest: String?, keep: Set<WindowID> = [], hold: WindowID? = nil) -> Prepared {
        // Without the permission the window list is empty: say why, not "no windows".
        guard control.isTrusted else { return .failed(.failed(Self.untrusted)) }
        let displays = control.displays()
        guard let fallback = displays.first else { return .failed(.failed("No display found.")) }
        let all = control.windows()
        let frontmost = control.frontmostWindowID()
        let display = all.first { $0.id == frontmost && $0.isVisible }
            .flatMap { Displays.containing($0.frame, in: displays) } ?? fallback
        // Floating apps are not there for Smart Arrange: not moved, not parked, not kept clear (ADR-2610120742).
        // Nor are meeting apps' windows, ever (MeetingApps).
        let onDisplay = (settings?.movable(all) ?? all)
            .filter { !MeetingApps.contains($0.app) }
            .filter { $0.isVisible && Displays.containing($0.frame, in: displays) == display }
        // Windows the person placed by hand stay put; the plan works around them.
        let pinnedIDs = intents?.pinned() ?? []
        // A meeting app's windows are never moved, and never covered: planned around, as pinned ones are.
        let meetings = all.filter { MeetingApps.contains($0.app) && $0.isVisible
            && Displays.containing($0.frame, in: displays) == display }
        let kept = onDisplay.filter { pinnedIDs.contains($0.id) || $0.id == hold } + meetings
        let visible = onDisplay.filter { !pinnedIDs.contains($0.id) && $0.id != hold }
        guard !visible.isEmpty else { return .failed(.failed("There are no windows to arrange on this desktop.")) }

        let pinnedApps = kept.filter { pinnedIDs.contains($0.id) }.map(\.app)
        var notes: [String] = pinnedApps.isEmpty ? [] : ["Kept \(pinnedApps.joined(separator: ", ")) where you put it."]
        if let held = kept.first(where: { $0.id == hold }) {
            notes.append("Left \(held.app) alone while you work in it; it gets its place when you move on.")
        }
        var named: WindowID?
        if let biggest, !biggest.trimmingWhitespace().isEmpty {
            if case .window(let w) = TargetMatcher.resolve(biggest, in: visible, frontmost: frontmost) {
                named = w.id
            } else {
                notes.append("No window here matches '\(biggest)'.")
            }
        }
        let live = focus?.activity() ?? [:]
        // A bound group sits in consecutive zones, at its most active member's place (ADR-2610120830).
        let groups = bindings?.groups(all) ?? []
        let wanted = keep.union(frontmost.map { [$0] } ?? [])
        let liveWindows = focus?.windowActivity() ?? [:]
        let ranked = Self.priority(visible, named: named, live: live, focusCounts: focusCounts(), liveWindows: liveWindows)
        var reasons = ["Ranked: " + ranked.prefix(8).map { w in
            "\(w.app) \"\(w.title.prefix(30))\" (\(FocusTracker.minutes(liveWindows[w.id] ?? 0)))" }.joined(separator: ", ")]
        for w in onDisplay where pinnedIDs.contains(w.id) { reasons.append("Kept \(w.app) in place: you placed it by hand (pinned).") }
        for w in onDisplay where w.id == hold { reasons.append("Kept \(w.app) in place: you are working in it; it gets its place when you move on.") }
        for w in meetings { reasons.append("Kept \(w.app) in place: meeting apps are never moved, and nothing covers them.") }
        for w in all where w.isVisible && !MeetingApps.contains(w.app) && (settings?.isFloating(w.app) ?? false)
            && Displays.containing(w.frame, in: displays) == display {
            reasons.append("Left \(w.app) alone: it is in Apps Deskman Leaves Alone.")
        }
        // Only what the person brought back goes first; the front window is only never parked.
        let ordered = Bindings.adjacent(ranked.filter { keep.contains($0.id) } + ranked.filter { !keep.contains($0.id) },
                                        groups: groups)

        // Every window is arranged: none is minimized for being inactive (2026-10-12).
        let active = ordered

        // The person's grid, and only that: 1 over 2, 3 in the middle, 4 over 5 (GridPlanner).
        // Windows already in a zone stay; the rest fill free zones; none is squeezed or minimized.
        let shape = self.grid?.shape(on: display)
        let grid = GridPlanner.plan(active, on: display, kept: kept.map(\.frame), center: named, shape: shape)
        let plan = grid.zonePlan(on: display, shape: shape)
        guard !plan.placements.isEmpty else {
            return .failed(.failed("There is no free zone on this display: every zone is kept."))
        }
        reasons.append("Layout: your grid, 1 over 2, 3 in the middle, 4 over 5. A window already in a zone stays; "
                       + "the middle goes to " + (named != nil ? "the window you named" : "the most used browser, else the most used window") + ".")
        for p in plan.placements where GridPlanner.near(p.window.frame, p.frame) {
            reasons.append("Stays: \(p.window.app) \"\(p.window.title.prefix(30))\" is already in \(p.zone.label).")
        }
        // A window already in its zone, give or take an app's settling, is not moved.
        let moves = plan.placements.filter { !GridPlanner.near($0.window.frame, $0.frame) }
            .map { Move(id: $0.window.id, app: $0.window.app, from: $0.window.frame, to: $0.frame) }
        lastDisplay = display
        // Say why: "inactive" was said of windows that only had no room.
        if !plan.unplaced.isEmpty {
            reasons.append("No room for \(plan.unplaced.map(\.app).joined(separator: ", ")) at 700 × 400 pt or more: left where it is, never minimized.")
            notes.append("No room for \(plan.unplaced.map(\.app).joined(separator: ", ")) at a usable size; left where it is.")
        }
        lastReasons = reasons
        return .plan(plan, moves: moves, parked: plan.unplaced,
                     note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    // MARK: Read back (the user, 2026-10-12: never an overlap)

    /// The display the last plan was for.
    private(set) var lastDisplay: Display?
    /// Why the last plan is what it is, one line each, for the decision log.
    private(set) var lastReasons: [String] = []

    /// After the moves: each app that kept a wider frame than its zone, in words. The grid's
    /// boundaries do not move for it (ADR-2610121700); the decision log says so.
    func refusals(_ moves: [Move]) -> [String] {
        moves.compactMap { move in
            guard let landed = control.frame(of: move.id), landed.width > move.to.width + 8 else { return nil }
            return "\(move.app) kept \(Int(landed.width)) pt wide in a \(Int(move.to.width)) pt zone: it will not go narrower."
        }
    }

    public static let untrusted = "Deskman cannot see any windows: macOS has not given this process Accessibility permission. "
        + "Started from a terminal, it runs with the terminal's permission. Use scripts/diagnose.sh to run it as the app."

    /// What Smart Arrange would do now, for the map. Moves nothing.
    func previewPlan() -> (zones: [DesktopMap.PlannedZone], parked: [String], note: String?) {
        guard case .plan(let plan, _, let parked, let note) = prepare(biggest: nil) else { return ([], [], nil) }
        let zones = plan.placements.enumerated().map { i, p in
            DesktopMap.PlannedZone(frame: p.frame, app: p.window.app, isMain: i == 0, window: p.window.id)
        }
        return (zones, parked.map(\.app), note)
    }

    /// What Smart Arrange would do now, in words. Moves nothing.
    public func preview() -> String {
        switch prepare(biggest: nil) {
        case .failed(let outcome):
            return outcome.message
        case .plan(let plan, let moves, let parked, let note):
            var lines = ["zones: \(plan.layout.zones.count)"]
            lines += plan.placements.map { "  \($0.window.app) → \($0.zone.label) \(Self.size($0.frame))" }
            lines += parked.map { "  \($0.app) → left where it is (no room)" }
            lines.append("windows to move: \(moves.count)")
            if let note { lines.append(note) }
            return lines.joined(separator: "\n")
        }
    }

    private static func size(_ r: Rect) -> String {
        "(\(Int(r.x)),\(Int(r.y)) \(Int(r.width))×\(Int(r.height)))"
    }

    /// The named window first, then the window most in front in the last 30 minutes, then the
    /// most active app, then the apps focused most often in the learning history, then front to back.
    static func priority(_ windows: [WindowSnapshot], named: WindowID?, live: [String: Int],
                         focusCounts: [String: Int], liveWindows: [WindowID: Int] = [:]) -> [WindowSnapshot] {
        windows.enumerated().sorted { a, b in
            let na = a.element.id == named, nb = b.element.id == named
            if na != nb { return na }
            // The window's own time in front first: of three Firefox windows, the one you use.
            let wa = liveWindows[a.element.id] ?? 0, wb = liveWindows[b.element.id] ?? 0
            if wa != wb { return wa > wb }
            let la = live[a.element.app] ?? 0, lb = live[b.element.app] ?? 0
            if la != lb { return la > lb }
            let ca = focusCounts[a.element.app] ?? 0, cb = focusCounts[b.element.app] ?? 0
            if ca != cb { return ca > cb }
            return a.offset < b.offset
        }.map(\.element)
    }

    static func message(_ plan: ZonePlan, moved: Int, note: String?, failed: [String] = []) -> String {
        var m: String
        if moved == 0 {
            m = "Your windows are already arranged."
        } else {
            let n = moved
            m = "Arranged \(n) window\(n == 1 ? "" : "s")."
            if let top = plan.placements.first, n > 1 { m += " \(top.window.app) got the most room." }
        }
        if !failed.isEmpty { m += " Could not move: \(failed.joined(separator: "; "))." }
        if let note { m += " " + note }
        return m
    }

    private func focusCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for s in history?.snapshots() ?? [] { if let app = s.focusedApp { counts[app, default: 0] += 1 } }
        return counts
    }
}
