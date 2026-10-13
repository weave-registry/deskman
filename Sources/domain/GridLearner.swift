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
    /// A window smaller than this share of the smallest zone is a widget, not a place in the grid
    /// (Plaud, 320 × 196 pt, 2026-10-13). The share allows for the 1/60 rounding of a placement.
    static let zoneShare = 0.9
    /// A display's own edge, give or take the 1/60 rounding of a placement.
    static let frameEdge = 1.0 / 60 + 1e-9

    /// The shape the person's moves on `display` describe, or nil: too few moves, or one zone.
    /// `ignoring`: apps Deskman leaves alone (ADR-2610120742); their places are not the grid.
    ///
    /// `inUse`: the learned grid in use; nil for the standard one. It is where learning starts
    /// (using the learned grid must not erase it: 2026-10-13, 13:40–14:00): each of its edges counts as
    /// `minimumSupport` moves, older than any real one. A correction (`WindowRecord.corrected`) counts
    /// as `minimumSupport` moves too: the person resized a zone that did not fit. A move of the person's replaces an edge it lands near (the one used
    /// last wins) and counts against an edge it spans. An edge nobody moved stays (2026-10-13: five
    /// moves on the middle and the right merged the left column into the middle).
    public static func learn(from history: [DeskSnapshot], on display: Display, now: Double,
                             ignoring: (String) -> Bool = { _ in false }, inUse: GridShape? = nil) -> Learned? {
        let evidence = self.evidence(history, on: display, now: now, ignoring: ignoring)
        guard evidence.count >= minimumPlacements else { return nil }

        let v = display.visibleFrame
        let maxColumns = max(1, Int(v.width / ZonePlanner.minimumWidth))
        let maxRows = max(1, Int(v.height / ZonePlanner.minimumHeight))
        // The grid in use, as fractions of the visible frame.
        let standard = ZoneGenerator.snapZones(on: display, shape: inUse).map {
            Rect(x: ($0.x - v.x) / v.width, y: ($0.y - v.y) / v.height, width: $0.width / v.width, height: $0.height / v.height)
        }

        let cuts = boundaries(evidence.flatMap { e in [(e.rect.x, e.time, e.weight), (e.rect.maxX, e.time, e.weight)] },
                              prior: standard.flatMap { [$0.x, $0.maxX] },
                              spans: evidence.map { ($0.rect.x, $0.rect.maxX, $0.weight) }, limit: maxColumns - 1)
        let columns = zip([0.0] + cuts, cuts + [1.0]).map { (lo: $0, hi: $1) }
        let rows = columns.map { c -> Int in
            let inside = evidence.filter { $0.rect.x >= c.lo - sameEdge && $0.rect.maxX <= c.hi + sameEdge }
            // The standard rows of the standard column under this column's center.
            let center = (c.lo + c.hi) / 2
            let under = standard.filter { $0.x <= center && center < $0.maxX }
            return boundaries(inside.flatMap { e in [(e.rect.y, e.time, e.weight), (e.rect.maxY, e.time, e.weight)] },
                              prior: under.flatMap { [$0.y, $0.maxY] },
                              spans: inside.map { ($0.rect.y, $0.rect.maxY, $0.weight) }, limit: maxRows - 1).count + 1
        }
        guard rows.reduce(0, +) > 1 else { return nil }
        return Learned(shape: GridShape(rows: rows), placements: evidence.count)
    }

    /// How many of the person's placements on `display` count now: progress toward `minimumPlacements`.
    public static func placements(in history: [DeskSnapshot], on display: Display, now: Double,
                                  ignoring: (String) -> Bool = { _ in false }) -> Int {
        evidence(history, on: display, now: now, ignoring: ignoring).count
    }

    /// The person's placements. One app in one place counts once, at the last time it was there:
    /// a window whose title changes is not a second move (Slack, 2026-10-13). `weight`: how many moves
    /// it counts as, `minimumSupport` for a correction in any record of it.
    static func evidence(_ history: [DeskSnapshot], on display: Display, now: Double,
                         ignoring: (String) -> Bool) -> [(rect: Rect, time: Double, weight: Int)] {
        let v = display.visibleFrame
        let bigEnough = { (r: Rect) in r.width * v.width >= zoneShare * ZonePlanner.minimumWidth
            && r.height * v.height >= zoneShare * ZonePlanner.minimumHeight }
        var latest: [String: (rect: Rect, time: Double, weight: Int)] = [:]
        for s in history where now - s.time <= memorySeconds {
            for w in s.windows where w.byPerson == true && !w.isMinimized && w.placement.display == display.index
                && !ignoring(w.app) && bigEnough(w.placement.rect) {
                let r = w.placement.rect
                let key = "\(w.app)\u{0}\(r.x),\(r.y),\(r.width),\(r.height)"
                let weight = max(latest[key]?.weight ?? 1, w.corrected == true ? minimumSupport : 1)
                latest[key] = (r, max(latest[key]?.time ?? -.infinity, s.time), weight)
            }
        }
        return Array(latest.values)
    }

    /// The inner boundaries, sorted, at most `limit` of them. `edges`: the person's, each a
    /// position (0…1) and when it was last used. `prior`: the standard grid's, older than any.
    /// `spans`: the person's placements, from edge to edge; one that spans a boundary counts against it.
    static func boundaries(_ edges: [(Double, Double, Int)], prior: [Double], spans: [(Double, Double, Int)],
                           limit: Int) -> [Double] {
        let inner = { (x: Double) in x > frameEdge && x < 1 - frameEdge }
        // Groups of edges within `sameEdge` of the group's first edge.
        var groups: [(at: Double, support: Int, last: Double)] = []
        for (x, t, n) in edges.filter({ inner($0.0) }).sorted(by: { $0.0 < $1.0 }) {
            if let g = groups.last, x - g.at <= sameEdge {
                groups[groups.count - 1] = (g.at, g.support + n, max(g.last, t))
            } else {
                groups.append((x, n, t))
            }
        }
        for p in Set(prior.filter(inner)) {
            if let i = groups.firstIndex(where: { abs($0.at - p) <= sameEdge }) {
                groups[i].support += minimumSupport
            } else {
                groups.append((p, minimumSupport, -.infinity))
            }
        }
        for i in groups.indices {
            groups[i].support -= spans.filter { $0.0 < groups[i].at - sameEdge && $0.1 > groups[i].at + sameEdge }
                .map(\.2).reduce(0, +)
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
