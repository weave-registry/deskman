// What the desktop map outlines on the real screen, as Hammerspoon's zone grid did
// (ADR-2610101523, amendment 2026-10-12). Screen coordinates, top-left, y down.

/// One outline drawn over the screen, with its label.
public struct ScreenOutline: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A snap zone, or a zone Smart Arrange would fill.
        case zone
        /// Smart Arrange's main zone, for the most active window.
        case main
        case learned
        case learning
    }

    public let frame: Rect
    public let label: String
    public let kind: Kind

    public init(frame: Rect, label: String, kind: Kind) {
        self.frame = frame
        self.label = label
        self.kind = kind
    }
}

/// The map's tabs, as far as the screen outlines care.
public enum MapTab: Sendable {
    case now, arrange, learned
}

extension DesktopMap {
    /// The outlines for a tab, in the order the map draws its boxes, so a box and
    /// its outline share an index. Now: the snap zones, numbered per display as the keys count them.
    public func outlines(_ tab: MapTab) -> [ScreenOutline] {
        switch tab {
        case .now:
            return displays.flatMap { d in
                ZoneGenerator.snapZones(on: d, shape: grids[d.index]).enumerated().map { ScreenOutline(frame: $1, label: "\($0 + 1)", kind: .zone) }
            }
        case .arrange:
            return plan.map { z in
                let name = z.window.flatMap { names[$0] } ?? z.app
                return ScreenOutline(frame: z.frame, label: (z.isMain ? "★ " : "") + name, kind: z.isMain ? .main : .zone)
            }
        case .learned:
            return habitGroups.map { g in
                ScreenOutline(frame: g.frame, label: g.habits.map(\.app).joined(separator: ", "),
                              kind: g.habits.allSatisfy(\.isLearned) ? .learned : .learning)
            }
        }
    }
}
