// Smart Arrange fills the person's grid, and only that (the user, 2026-10-12: "we have a layout
// already of 1 over 2, 3 middle, 4 over 5 ... we should only auto arrange around these
// boundaries"). The grid is the snap zones, so a hotkey and an arrange mean the same place.
// Screen coordinates, top-left origin, y down.

public enum GridPlanner {
    public struct Placement: Equatable, Sendable {
        public let window: WindowSnapshot
        public let frame: Rect
    }

    public struct Result: Equatable, Sendable {
        public let placements: [Placement]
        /// No place in the grid: left where they are, never minimized.
        public let leftAlone: [WindowSnapshot]

        /// As a plan Smart Arrange carries out, each place labelled by its zone number.
        public func zonePlan(on display: Display) -> ZonePlan {
            let v = display.visibleFrame
            let snap = ZoneGenerator.snapZones(on: display)
            let label = { (f: Rect) -> String in
                if let i = snap.firstIndex(of: f) { return "zone \(i + 1)" }
                if let i = snap.firstIndex(where: { $0.x == f.x && $0.y == f.y }) { return "zones \(i + 1)+\(i + 2)" }
                return "a zone"
            }
            let placed = placements.map { p in
                ZonePlacement(window: p.window,
                              zone: Zone(label: label(p.frame), rect: Rect(x: (p.frame.x - v.x) / v.width, y: (p.frame.y - v.y) / v.height,
                                                                         width: p.frame.width / v.width, height: p.frame.height / v.height)),
                              frame: p.frame)
            }
            return ZonePlan(layout: ZoneLayout(name: "Grid", zones: placed.map(\.zone)), placements: placed, unplaced: leftAlone)
        }
    }

    /// How far a window may sit from a zone and still be in it, per edge (an app settles: iTerm2
    /// snaps to whole text cells).
    static let tolerance = 48.0

    /// `ranked`: most important first. `kept`: frames of windows that stay (pinned, being worked
    /// in, a meeting); a zone they cover by more than a tenth is not used. `center`: a window the
    /// person named, for the middle.
    ///
    /// 1. A window already in a zone, or filling a side column, stays: it is not moved.
    /// 2. The middle goes to the named window, else the most used browser, else the most used window.
    /// 3. Browsers next, each a whole side column: a browser is never stacked.
    /// 4. The rest fill the halves in order: left top, right top, left bottom, right bottom.
    /// 5. A side column with one window and a free half gives that window its full height.
    public static func plan(_ ranked: [WindowSnapshot], on display: Display, kept: [Rect],
                            center: WindowID? = nil) -> Result {
        let zones = ZoneGenerator.snapZones(on: display)
        guard !zones.isEmpty else { return Result(placements: [], leftAlone: ranked) }
        // Columns: the zones that share an x, top to bottom. The middle is the widest.
        let xs = zones.map(\.x).reduce(into: [Double]()) { if !$0.contains($1) { $0.append($1) } }.sorted()
        let columns = xs.map { x in zones.filter { $0.x == x }.sorted { $0.y < $1.y } }
        let middle = columns.indices.max { columns[$0][0].width < columns[$1][0].width }!
        func whole(_ c: Int) -> Rect {
            let top = columns[c][0], bottom = columns[c].last!
            return Rect(x: top.x, y: top.y, width: top.width, height: bottom.maxY - top.y)
        }
        let blocked: [[Bool]] = columns.map { col in col.map { z in
            kept.contains { k in (k.intersection(z)?.area ?? 0) > 0.1 * z.area } } }
        var owner: [[WindowID?]] = columns.map { $0.map { _ in nil } }
        var frames: [WindowID: Rect] = [:]
        func free(_ c: Int, _ r: Int) -> Bool { owner[c][r] == nil && !blocked[c][r] }
        func take(_ w: WindowSnapshot, _ c: Int, rows: [Int]) {
            for r in rows { owner[c][r] = w.id }
            frames[w.id] = rows.count == columns[c].count && rows.count > 1 ? whole(c) : columns[c][rows[0]]
        }

        // 1. Already in place: stays.
        for w in ranked {
            for c in columns.indices where frames[w.id] == nil {
                let all = Array(columns[c].indices)
                if all.count > 1, near(w.frame, whole(c)), all.allSatisfy({ free(c, $0) }) { take(w, c, rows: all); break }
                if let r = all.first(where: { near(w.frame, columns[c][$0]) && free(c, $0) }) { take(w, c, rows: [r]) }
            }
        }
        var rest = ranked.filter { frames[$0.id] == nil }

        // 2. The middle.
        if columns[middle].indices.allSatisfy({ free(middle, $0) }),
           let pick = rest.first(where: { $0.id == center }) ?? rest.first(where: { Browsers.contains($0.app) }) ?? rest.first {
            take(pick, middle, rows: Array(columns[middle].indices))
            rest.removeAll { $0.id == pick.id }
        }

        // Side columns, nearest the middle first, the left before the right.
        let sides = columns.indices.filter { $0 != middle }
            .sorted { (abs($0 - middle), $0) < (abs($1 - middle), $1) }

        // 3. Browsers: a whole column each.
        for w in rest where Browsers.contains(w.app) {
            if let c = sides.first(where: { c in columns[c].indices.allSatisfy { free(c, $0) } }) {
                take(w, c, rows: Array(columns[c].indices))
            }
        }
        rest.removeAll { frames[$0.id] != nil }

        // 4. The halves, row by row across the sides.
        let rows = columns.map(\.count).max() ?? 1
        let order = (0..<rows).flatMap { r in sides.filter { r < columns[$0].count }.map { ($0, r) } }
        for w in rest where !Browsers.contains(w.app) {
            if let (c, r) = order.first(where: { free($0.0, $0.1) }) { take(w, c, rows: [r]) }
        }

        // 5. Alone in a side column, with the other half free: the full height.
        for c in sides where columns[c].count > 1 {
            let owners = Set(owner[c].compactMap { $0 })
            guard owners.count == 1, let id = owners.first, frames[id] != whole(c),
                  columns[c].indices.allSatisfy({ owner[c][$0] == id || free(c, $0) }) else { continue }
            take(ranked.first { $0.id == id }!, c, rows: Array(columns[c].indices))
        }

        let placements = ranked.compactMap { w in frames[w.id].map { Placement(window: w, frame: $0) } }
        return Result(placements: placements, leftAlone: ranked.filter { frames[$0.id] == nil })
    }

    /// Which zone of the grid a window is in now, give or take an app's settling: "zone 3",
    /// "zones 4+5" for a whole side column, nil when it is in none.
    public static func zoneLabel(of frame: Rect, on display: Display) -> String? {
        let z = ZoneGenerator.snapZones(on: display)
        if let i = z.firstIndex(where: { near(frame, $0) }) { return "zone \(i + 1)" }
        for i in z.indices.dropLast() where z[i].x == z[i + 1].x {
            let column = Rect(x: z[i].x, y: z[i].y, width: z[i].width, height: z[i + 1].maxY - z[i].y)
            if near(frame, column) { return "zones \(i + 1)+\(i + 2)" }
        }
        return nil
    }

    public static func near(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }
}
