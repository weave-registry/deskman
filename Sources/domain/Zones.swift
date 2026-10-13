// Smart Arrange (ADR-2610101501, ADR-2610101523). `ZoneGenerator` draws the zones;
// the planner decides which window goes in which zone. Fractions are 0…1 of a
// display's visible frame, top-left origin, y down.

public struct Zone: Equatable, Codable, Sendable {
    public let label: String
    /// Fractions of the visible frame.
    public let rect: Rect

    public init(label: String, rect: Rect) {
        self.label = label
        self.rect = rect
    }

    public func frame(in display: Display) -> Rect {
        let v = display.visibleFrame
        return Rect(x: v.x + rect.x * v.width, y: v.y + rect.y * v.height,
                    width: rect.width * v.width, height: rect.height * v.height)
    }

    var area: Double { rect.width * rect.height }

    /// The same zone on a display turned upright: columns become rows.
    var turned: Zone {
        Zone(label: label, rect: Rect(x: rect.y, y: rect.x, width: rect.height, height: rect.width))
    }
}

public struct ZoneLayout: Equatable, Codable, Sendable {
    public let name: String
    public let zones: [Zone]

    public init(name: String, zones: [Zone]) {
        self.name = name
        self.zones = zones
    }
}

public struct ZonePlacement: Equatable, Sendable {
    public let window: WindowSnapshot
    public let zone: Zone
    public let frame: Rect
}

public struct ZonePlan: Equatable, Sendable {
    public let layout: ZoneLayout
    /// In priority order: the first one got the largest zone.
    public let placements: [ZonePlacement]
    /// Windows beyond the zone count. They stay where they are.
    public let unplaced: [WindowSnapshot]
}

public enum ZonePlanner {
    /// The smallest zone a window can be worked in, in points.
    public static let minimumWidth = 700.0
    /// Two windows at most on top of each other, however tall the area (the user, 2026-10-12).
    public static let maxStack = 2
    public static let minimumHeight = 400.0

    /// A plan for `windows`, given in priority order (most important first), or
    /// nil when there are no windows, no layouts, or `named` names no layout.
    /// On an upright display the zones turn: columns become rows.
    /// `keepClear`: frames of windows the person placed; a zone that overlaps one
    /// by more than a tenth of its area is not used.
    public static func plan(windows: [WindowSnapshot], on display: Display, layouts: [ZoneLayout],
                            named: String?, current: String?, keepClear: [Rect] = []) -> ZonePlan? {
        guard !windows.isEmpty else { return nil }
        let v = display.visibleFrame
        let upright = v.height > v.width
        func oriented(_ l: [ZoneLayout]) -> [ZoneLayout] {
            l.map { layout in
                let zones = upright ? layout.zones.map(\.turned) : layout.zones
                return ZoneLayout(name: layout.name, zones: zones.filter { z in
                    let f = z.frame(in: display)
                    // A zone too small to work in is never used (the user, 2026-10-12): fewer windows, not smaller ones.
                    guard f.width >= minimumWidth - 0.5, f.height >= minimumHeight - 0.5 else { return false }
                    return !keepClear.contains { overlap(f, $0) > 0.1 * f.width * f.height }
                })
            }.filter { !$0.zones.isEmpty }
        }
        let candidates: [ZoneLayout]
        if let named {
            candidates = oriented(layouts.filter { $0.name.lowercased() == named.lowercased().trimmingWhitespace() })
        } else {
            candidates = oriented(layouts)
        }
        guard let layout = candidates.min(by: {
            better($0, than: $1, count: windows.count, current: current, on: display)
        }) else { return nil }
        return assign(windows, to: layout, on: display)
    }

    /// How many of the zones `count` windows would take are too small to work in.
    static func tooSmall(_ l: ZoneLayout, count n: Int, on display: Display) -> Int {
        l.zones.sorted { $0.area > $1.area }.prefix(n).filter {
            let f = $0.frame(in: display)
            return f.width < minimumWidth - 0.5 || f.height < minimumHeight - 0.5
        }.count
    }

    /// Fewest zones too small, then fewest windows unplaced, then the most screen
    /// covered, then the fewest empty zones, then the current Hammerspoon layout,
    /// then the first listed.
    static func better(_ a: ZoneLayout, than b: ZoneLayout, count n: Int, current: String?,
                       on display: Display) -> Bool {
        func key(_ l: ZoneLayout) -> (small: Int, unplaced: Int, covered: Double, empty: Int, notCurrent: Int) {
            let covered = l.zones.map(\.area).sorted(by: >).prefix(n).reduce(0, +)
            return (tooSmall(l, count: n, on: display), max(0, n - l.zones.count), (covered * 1e6).rounded(),
                    max(0, l.zones.count - n), l.name == current ? 0 : 1)
        }
        let ka = key(a), kb = key(b)
        if ka.small != kb.small { return ka.small < kb.small }
        if ka.unplaced != kb.unplaced { return ka.unplaced < kb.unplaced }
        if ka.covered != kb.covered { return ka.covered > kb.covered }
        if ka.empty != kb.empty { return ka.empty < kb.empty }
        return ka.notCurrent < kb.notCurrent
    }

    /// Each window, in order, takes the largest free zone. Among equal ones, the
    /// first window takes the one nearest the display's center, straight ahead;
    /// every other window takes the one nearest where it is, so it moves least.
    static func assign(_ windows: [WindowSnapshot], to layout: ZoneLayout, on display: Display) -> ZonePlan {
        var free = Array(layout.zones.indices)
        var placements: [ZonePlacement] = []
        for (i, w) in windows.prefix(layout.zones.count).enumerated() {
            let largest = free.map { layout.zones[$0].area }.max()!
            let sameSize = free.filter { abs(layout.zones[$0].area - largest) < 1e-9 }
            let anchor = i == 0 ? display.visibleFrame : w.frame
            let pick = sameSize.min { distance(anchor, layout.zones[$0].frame(in: display))
                < distance(anchor, layout.zones[$1].frame(in: display)) }!
            free.removeAll { $0 == pick }
            let zone = layout.zones[pick]
            placements.append(ZonePlacement(window: w, zone: zone, frame: zone.frame(in: display)))
        }
        return ZonePlan(layout: layout, placements: placements, unplaced: Array(windows.dropFirst(layout.zones.count)))
    }

    private static func overlap(_ a: Rect, _ b: Rect) -> Double {
        let w = min(a.maxX, b.maxX) - max(a.x, b.x)
        let h = min(a.maxY, b.maxY) - max(a.y, b.y)
        return w > 0 && h > 0 ? w * h : 0
    }

    private static func distance(_ a: Rect, _ b: Rect) -> Double {
        let dx = (a.x + a.width / 2) - (b.x + b.width / 2)
        let dy = (a.y + a.height / 2) - (b.y + b.height / 2)
        return dx * dx + dy * dy
    }
}
