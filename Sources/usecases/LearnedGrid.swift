import DeskmanPorts

/// The grid each display uses (ADR-2610131157): the shape the person's own moves describe, made
/// equal, or the standard grid until there are enough of them. Derived from the records, so
/// nothing new is stored and Forget My Activity forgets it too. A new shape moves no window.
@MainActor public final class LearnedGrid {
    private let history: any ActivityStore
    private let clock: any TimeSource
    /// Apps Deskman leaves alone teach no grid (ADR-2610120742).
    private let settings: Settings?
    /// Where a change of shape is explained. Set by the composition root.
    public var decisions: (any DecisionLog)?
    /// By display index. A display not here has not been learned yet.
    private var learned: [Int: GridLearner.Learned?] = [:]

    public init(history: any ActivityStore, clock: any TimeSource, settings: Settings? = nil) {
        self.settings = settings
        self.history = history
        self.clock = clock
    }

    /// Learn again from the records: on the learning tick. A change is logged once.
    public func relearn(displays: [Display]) {
        let records = history.snapshots()
        for d in displays {
            let now = GridLearner.learn(from: records, on: d, now: clock.now(), ignoring: ignored,
                                        inUse: settings?.gridShape(on: d.index) ?? learned[d.index]??.shape)
            if let saved = settings?.setGridShape(now?.shape, on: d.index), !saved.succeeded {
                decisions?.record("Could not keep the grid in use for the next start:\(saved.message)")
            }
            let before = learned[d.index]
            learned[d.index] = .some(now)
            guard before == nil ? now != nil : before! != now else { continue }
            let screen = d.index == 0 ? "" : " on display \(d.index + 1)"
            decisions?.record(now.map { "Learned your grid\(screen) from \($0.placements) of your moves: \($0.shape.phrase). "
                                        + "Smart Arrange and the snap keys use it from the next arrange; nothing moved now." }
                              ?? "Back to the standard grid\(screen): too few of your moves to learn one.")
        }
    }

    /// The learned shape on `display`, or nil for the standard grid.
    public func shape(on display: Display) -> GridShape? {
        if learned[display.index] == nil { relearn(displays: [display]) }
        return learned[display.index]??.shape
    }

    public func zones(on display: Display) -> [Rect] {
        ZoneGenerator.snapZones(on: display, shape: shape(on: display))
    }

    /// Forget My Activity: the grid goes with the records it was learned from.
    public func forget() {
        if let cleared = settings?.clearGridShapes(), !cleared.succeeded {
            decisions?.record("Could not forget the grid in use:\(cleared.message)")
        }
        learned = [:]
    }

    private func ignored(_ app: String) -> Bool { settings?.isFloating(app) ?? false }

    /// In words, for What Deskman Knows.
    public func describe(on display: Display) -> String {
        if learned[display.index] == nil { relearn(displays: [display]) }
        if let l = learned[display.index] ?? nil {
            return "Learned from \(l.placements) of your moves: \(l.shape.phrase)."
        }
        let n = GridLearner.placements(in: history.snapshots(), on: display, now: clock.now(), ignoring: ignored)
        return "Standard grid. Yours is learned after \(GridLearner.minimumPlacements) of your moves (\(n) so far)."
    }
}
