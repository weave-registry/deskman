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

    public init(floatingApps: [String] = Preferences.defaultFloatingApps, dragSnap: Bool = true,
                boundProjects: [String] = [], declinedProjects: [String] = [], keepArranged: Bool = false) {
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
    private enum CodingKeys: String, CodingKey { case floatingApps, dragSnap, boundProjects, declinedProjects, keepArranged }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        floatingApps = try c.decodeIfPresent([String].self, forKey: .floatingApps) ?? Self.defaultFloatingApps
        dragSnap = try c.decodeIfPresent(Bool.self, forKey: .dragSnap) ?? true
        boundProjects = try c.decodeIfPresent([String].self, forKey: .boundProjects) ?? []
        declinedProjects = try c.decodeIfPresent([String].self, forKey: .declinedProjects) ?? []
        keepArranged = try c.decodeIfPresent(Bool.self, forKey: .keepArranged) ?? false
    }
}
