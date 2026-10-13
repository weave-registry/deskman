// Deskman learns the person's grid from their moves, and makes its zones equal (ADR-2610131157).
// The user, 2026-10-13: "we need to learn new zone configurations then optimize them for equal
// distribution". Only the shape is learned; the edges are where "equal" puts them.
// Placements are fractions of the visible frame, top-left, y down.

/// How many zones each column stacks, left to right: the person's grid today is `[2, 1, 2]`.
public struct GridShape: Equatable, Codable, Sendable {
    public let rows: [Int]

    public init(rows: [Int]) {
        self.rows = rows
    }

    /// Equal columns, and equal zones within a column, tiling the visible frame: no gap, no
    /// overlap. Numbered left to right, then top to bottom, as the snap zones are.
    public func zones(on display: Display) -> [Rect] {
        let v = display.visibleFrame
        let n = Double(rows.count)
        return rows.enumerated().flatMap { c, count -> [Rect] in
            // Edges as fractions of the whole, so the last zone ends exactly at the frame's edge.
            let x0 = v.x + v.width * Double(c) / n, x1 = v.x + v.width * Double(c + 1) / n
            return (0..<count).map { r in
                let y0 = v.y + v.height * Double(r) / Double(count), y1 = v.y + v.height * Double(r + 1) / Double(count)
                return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            }
        }
    }

    /// "3 equal columns of 2, 1 and 2 zones".
    public var phrase: String {
        let counts = rows.map(String.init)
        let list = counts.count == 1 ? counts[0] : counts.dropLast().joined(separator: ", ") + " and " + counts.last!
        return rows.count == 1 ? "one column of \(list) zones" : "\(rows.count) equal columns of \(list) zones"
    }
}

public enum GridLearner {
    public struct Learned: Equatable, Sendable {
        public let shape: GridShape
        /// How many of the person's placements it was learned from.
        public let placements: Int
    }

    /// Fewer placements than this teach nothing.
    public static let minimumPlacements = 5
    /// An edge seen in fewer placements than this is noise.
    public static let minimumSupport = 3
    /// Older moves are forgotten.
    public static let memorySeconds = 14.0 * 86_400
    /// Edges this close, as a fraction of the display, are one edge.
    static let sameEdge = 0.04
    /// Edges closer than this are one boundary: the one used last wins. It stops an equal grid
    /// from feeding itself (25% edges from before, 33% edges since).
    static let oneBoundary = 0.10
    /// A display's own edge, give or take the 1/60 rounding of a placement.
    static let frameEdge = 1.0 / 60 + 1e-9

    /// The shape the person's moves on `display` describe, or nil: too few moves, or one zone.
    public static func learn(from history: [DeskSnapshot], on display: Display, now: Double) -> Learned? {
        let evidence = self.evidence(history, on: display, now: now)
        guard evidence.count >= minimumPlacements else { return nil }

        let v = display.visibleFrame
        let maxColumns = max(1, Int(v.width / ZonePlanner.minimumWidth))
        let maxRows = max(1, Int(v.height / ZonePlanner.minimumHeight))

        let cuts = boundaries(evidence.flatMap { e in [(e.rect.x, e.time), (e.rect.maxX, e.time)] }, limit: maxColumns - 1)
        let columns = zip([0.0] + cuts, cuts + [1.0]).map { (lo: $0, hi: $1) }
        let rows = columns.map { c -> Int in
            let inside = evidence.filter { $0.rect.x >= c.lo - sameEdge && $0.rect.maxX <= c.hi + sameEdge }
            return boundaries(inside.flatMap { e in [(e.rect.y, e.time), (e.rect.maxY, e.time)] }, limit: maxRows - 1).count + 1
        }
        guard rows.reduce(0, +) > 1 else { return nil }
        return Learned(shape: GridShape(rows: rows), placements: evidence.count)
    }

    /// How many of the person's placements on `display` count now: progress toward `minimumPlacements`.
    public static func placements(in history: [DeskSnapshot], on display: Display, now: Double) -> Int {
        evidence(history, on: display, now: now).count
    }

    /// The person's placements: one window in one place counts once, at the last time it was seen there.
    static func evidence(_ history: [DeskSnapshot], on display: Display, now: Double) -> [(rect: Rect, time: Double)] {
        var latest: [String: (rect: Rect, time: Double)] = [:]
        for s in history where now - s.time <= memorySeconds {
            for w in s.windows where w.byPerson == true && !w.isMinimized && w.placement.display == display.index {
                let r = w.placement.rect
                let key = "\(w.app)\u{0}\(w.title)\u{0}\(r.x),\(r.y),\(r.width),\(r.height)"
                if (latest[key]?.time ?? -.infinity) < s.time { latest[key] = (r, s.time) }
            }
        }
        return Array(latest.values)
    }

    /// The inner boundaries the edges describe, sorted, at most `limit` of them.
    /// `edges`: a position (0…1) and when it was last used.
    static func boundaries(_ edges: [(Double, Double)], limit: Int) -> [Double] {
        // Groups of edges within `sameEdge` of the group's first edge.
        var groups: [(at: Double, support: Int, last: Double)] = []
        for (x, t) in edges.filter({ $0.0 > frameEdge && $0.0 < 1 - frameEdge }).sorted(by: { $0.0 < $1.0 }) {
            if let g = groups.last, x - g.at <= sameEdge {
                groups[groups.count - 1] = (g.at, g.support + 1, max(g.last, t))
            } else {
                groups.append((x, 1, t))
            }
        }
        // The one used last wins a boundary; then the better supported; then the one further left.
        var kept: [(at: Double, support: Int, last: Double)] = []
        for g in groups.filter({ $0.support >= minimumSupport })
            .sorted(by: { ($1.last, $1.support, -$1.at) < ($0.last, $0.support, -$0.at) })
        where kept.allSatisfy({ abs($0.at - g.at) >= oneBoundary }) {
            kept.append(g)
        }
        // Too fine for the display: the weakest go first (fewest placements, then the oldest).
        while kept.count > max(0, limit) {
            let weakest = kept.indices.min { (kept[$0].support, kept[$0].last) < (kept[$1].support, kept[$1].last) }!
            kept.remove(at: weakest)
        }
        return kept.map(\.at).sorted()
    }
}
