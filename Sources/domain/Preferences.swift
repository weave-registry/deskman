/// What the person told Deskman (ADR-2610120742): the apps it leaves alone, and
/// whether drag-to-snap is on. Not learned, so "Forget My Activity" keeps it.
public struct Preferences: Codable, Equatable, Sendable {
    /// Hammerspoon's floating list, carried over.
    public static let defaultFloatingApps = ["Finder", "System Preferences", "System Settings", "Calculator",
                                             "Preview", "1Password", "Raycast", "Alfred", "Spotlight"]

    /// Apps whose windows Deskman never moves on its own.
    public var floatingApps: [String]
    public var dragSnap: Bool
    /// Projects whose windows move as one (ADR-2610120830), lowercase.
    public var boundProjects: [String]
    /// Projects the person said "Not now" to: never offered again.
    public var declinedProjects: [String]
    /// Smart Arrange each time the desktop's windows change (ADR-2610121130).
    public var keepArranged: Bool
    /// The learned grid in use, by display index as text (ADR-2610131157). Learned, so "Forget My
    /// Activity" clears it, with the records it came from.
    public var gridShapes: [String: GridShape]
    /// The mouse resting on a stacked window gives it the room (ADR-2611111000).
    public var hoverExpand: Bool
    /// The green button puts a grown window back in its zone (ADR-2611111100).
    public var greenButton: Bool
    /// Deskman learns the grid from the person's moves (ADR-2610131157). Off by default: the standard
    /// grid, 1 over 2 | 3 | 4 over 5, is the person's (the user, 2026-11-11).
    public var learnGrid: Bool

    public init(floatingApps: [String] = Preferences.defaultFloatingApps, dragSnap: Bool = true,
                boundProjects: [String] = [], declinedProjects: [String] = [], keepArranged: Bool = false,
                gridShapes: [String: GridShape] = [:], hoverExpand: Bool = true,
                greenButton: Bool = true, learnGrid: Bool = false) {
        self.learnGrid = learnGrid
        self.greenButton = greenButton
        self.hoverExpand = hoverExpand
        self.gridShapes = gridShapes
        self.keepArranged = keepArranged
        self.floatingApps = floatingApps
        self.dragSnap = dragSnap
        self.boundProjects = boundProjects
        self.declinedProjects = declinedProjects
    }

    public func isFloating(_ app: String) -> Bool {
        floatingApps.contains { $0.lowercased() == app.lowercased() }
    }

    // A field missing from a saved file takes its default, so older files still decode.
    private enum CodingKeys: String, CodingKey {
        case floatingApps, dragSnap, boundProjects, declinedProjects, keepArranged, gridShapes, hoverExpand, greenButton, learnGrid
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        floatingApps = try c.decodeIfPresent([String].self, forKey: .floatingApps) ?? Self.defaultFloatingApps
        dragSnap = try c.decodeIfPresent(Bool.self, forKey: .dragSnap) ?? true
        boundProjects = try c.decodeIfPresent([String].self, forKey: .boundProjects) ?? []
        declinedProjects = try c.decodeIfPresent([String].self, forKey: .declinedProjects) ?? []
        keepArranged = try c.decodeIfPresent(Bool.self, forKey: .keepArranged) ?? false
        gridShapes = try c.decodeIfPresent([String: GridShape].self, forKey: .gridShapes) ?? [:]
        hoverExpand = try c.decodeIfPresent(Bool.self, forKey: .hoverExpand) ?? true
        greenButton = try c.decodeIfPresent(Bool.self, forKey: .greenButton) ?? true
        learnGrid = try c.decodeIfPresent(Bool.self, forKey: .learnGrid) ?? false
    }
}
