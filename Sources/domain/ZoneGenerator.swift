// Deskman draws its own zones (ADR-2610101523), sized to the display and to how
// active each window is. Coordinates are top-left, y down. The generator works in
// a local "landscape" space; an upright display is drawn turned, then turned back.

public enum ZoneGenerator {
    /// An ultrawide: wide enough to put the main window in the center, straight ahead.
    static let ultrawideAspect = 2.0

    /// Zones for `count` windows in priority order. `weights` are their activity
    /// (empty when unknown). `area` limits the zones to part of the display.
    /// There may be fewer zones than windows: a column holds only what fits tall.
    public static func layout(count: Int, weights: [Double], on display: Display, within area: Rect? = nil) -> ZoneLayout {
        let a = area ?? display.visibleFrame
        let upright = a.height > a.width
        // In local space the long side is x. Minimums swap with it.
        let W = upright ? a.height : a.width, H = upright ? a.width : a.height
        let minW = upright ? ZonePlanner.minimumHeight : ZonePlanner.minimumWidth
        let minH = upright ? ZonePlanner.minimumWidth : ZonePlanner.minimumHeight

        let local = cells(count: max(1, count), share: share(weights), W: W, H: H, minW: minW, minH: minH)
        let v = display.visibleFrame
        let zones = local.map { cell -> Zone in
            let r = upright ? Rect(x: cell.rect.y, y: cell.rect.x, width: cell.rect.height, height: cell.rect.width)
                            : cell.rect
            let abs = Rect(x: a.x + r.x, y: a.y + r.y, width: r.width, height: r.height)
            return Zone(label: cell.label, rect: Rect(x: (abs.x - v.x) / v.width, y: (abs.y - v.y) / v.height,
                                                       width: abs.width / v.width, height: abs.height / v.height))
        }
        return ZoneLayout(name: "Deskman", zones: zones)
    }

    /// The zones the snap hotkeys and drag-to-snap use: the ones Deskman would draw
    /// for five windows, so a key always means the same place on a display. Numbered
    /// left to right, then top to bottom.
    public static func snapZones(on display: Display) -> [Rect] {
        layout(count: 5, weights: [], on: display).zones.map { $0.frame(in: display) }
            .sorted { ($0.x, $0.y) < ($1.x, $1.y) }
    }

    /// The snap zone nearest `frame` that is not the one `frame` sits in: where a
    /// window goes to sit beside another (a new browser beside the terminal).
    public static func zone(beside frame: Rect, in zones: [Rect]) -> Rect? {
        let c = Point(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        let own = zone(at: c, in: zones)
        func d(_ r: Rect) -> Double {
            let dx = r.x + r.width / 2 - c.x, dy = r.y + r.height / 2 - c.y
            return dx * dx + dy * dy
        }
        return zones.enumerated().filter { $0.offset != own }.min { d($0.element) < d($1.element) }?.element
    }

    /// The index of the zone under `point`, or nil.
    public static func zone(at point: Point, in zones: [Rect]) -> Int? {
        zones.firstIndex { $0.contains(point) }
    }

    /// The widest full-height strip of `frame` that no placed window overlaps.
    /// Upright displays use full-width strips.
    public static func freeArea(in frame: Rect, avoiding placed: [Rect]) -> Rect {
        let upright = frame.height > frame.width
        let lo = upright ? frame.y : frame.x, hi = upright ? frame.maxY : frame.maxX
        let blocked = placed.compactMap { p -> (Double, Double)? in
            let s = max(lo, upright ? p.y : p.x), e = min(hi, upright ? p.maxY : p.maxX)
            return e > s ? (s, e) : nil
        }.sorted { $0.0 < $1.0 }
        var best = (lo, lo), cursor = lo
        for (s, e) in blocked {
            if s - cursor > best.1 - best.0 { best = (cursor, s) }
            cursor = max(cursor, e)
        }
        if hi - cursor > best.1 - best.0 { best = (cursor, hi) }
        return upright ? Rect(x: frame.x, y: best.0, width: frame.width, height: best.1 - best.0)
                       : Rect(x: best.0, y: frame.y, width: best.1 - best.0, height: frame.height)
    }

    /// How much more active the main window is than an even share: 0 (even) … 1 (all of it).
    /// Nil when activity is unknown.
    static func share(_ weights: [Double]) -> Double? {
        let total = weights.reduce(0, +)
        guard weights.count > 1, total > 0 else { return nil }
        let even = 1 / Double(weights.count)
        return min(1, max(0, (weights[0] / total - even) / (1 - even)))
    }

    private static func cells(count n: Int, share s: Double?, W: Double, H: Double,
                              minW: Double, minH: Double) -> [(label: String, rect: Rect)] {
        // Two at most, however tall: three stacked are too short to work in (the user, 2026-10-12),
        // the same rule everywhere (ZonePlanner.maxStack).
        let rows = max(1, min(Int(H / minH), ZonePlanner.maxStack))
        func column(_ x: Double, _ w: Double, _ k: Int, _ name: String) -> [(label: String, rect: Rect)] {
            let k = min(k, rows)
            guard k > 0 else { return [] }
            return (0..<k).map { i in
                (k == 1 ? name : "\(name) \(i + 1)", Rect(x: x, y: H * Double(i) / Double(k), width: w, height: H / Double(k)))
            }
        }

        // Too narrow for two columns: one column, stacked.
        guard W >= 2 * minW else { return column(0, W, n, "Main") }

        if n == 1 {
            // A single window across a whole ultrawide is too wide to read: the center half.
            if W / H >= ultrawideAspect, W / 2 >= minW { return [("Main", Rect(x: W / 4, y: 0, width: W / 2, height: H))] }
            return [("Main", Rect(x: 0, y: 0, width: W, height: H))]
        }

        if n >= 3, W / H >= ultrawideAspect {
            // Center column 40–60% (50% when activity is unknown), sides stacked.
            var main = W * (s.map { 0.4 + 0.2 * $0 } ?? 0.5)
            main = min(main, W - 2 * minW)
            if main >= minW {
                let side = (W - main) / 2
                let sides = n - 1
                return [("Main", Rect(x: side, y: 0, width: main, height: H))]
                    + column(0, side, (sides + 1) / 2, "Left")
                    + column(side + main, side, sides / 2, "Right")
            }
        }

        // Main column 50–67% (50% when activity is unknown), one stacked side column.
        let main = min(W * (s.map { 0.5 + $0 / 6 } ?? 0.5), W - minW)
        return [("Main", Rect(x: 0, y: 0, width: main, height: H))] + column(main, W - main, n - 1, "Side")
    }
}
