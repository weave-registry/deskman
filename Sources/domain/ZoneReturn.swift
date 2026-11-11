// The green button puts a window back in its zone (ADR-2611111100). Top-left origin, y down.

public enum ZoneReturn {
    /// A window this close to a place, on every edge, sits in it: apps settle off it (iTerm2 rounds to whole text
    /// lines: 35 pt short on the user's desktop, 2026-11-11). The same allowance as `IntentLog.settle`.
    public static let tolerance = 48.0
    /// A window covers another when they share more than this share of the smaller one.
    public static let coverShare = 0.1

    /// Where a window can sit: every zone, and each column of two zones stacked one on the other.
    public static func places(_ zones: [Rect]) -> [Rect] {
        var out = zones
        for a in zones {
            for b in zones where b.minY > a.minY && abs(a.x - b.x) < 1 && abs(a.width - b.width) < 1
                && abs(b.minY - a.maxY) < 1 {
                out.append(Rect(x: a.x, y: a.y, width: a.width, height: b.maxY - a.minY))
            }
        }
        return out
    }

    /// The place `frame` sits in, or nil.
    public static func place(of frame: Rect, in places: [Rect]) -> Rect? {
        places.first { p in
            abs(p.minX - frame.minX) <= tolerance && abs(p.minY - frame.minY) <= tolerance
                && abs(p.maxX - frame.maxX) <= tolerance && abs(p.maxY - frame.maxY) <= tolerance
        }
    }

    /// In no place, and over another visible window.
    public static func isOutOfZone(_ window: WindowSnapshot, among windows: [WindowSnapshot], places: [Rect]) -> Bool {
        guard place(of: window.frame, in: places) == nil else { return false }
        return windows.contains { other in
            guard other.id != window.id, other.isVisible, let shared = other.frame.intersection(window.frame) else { return false }
            return shared.area > coverShare * min(other.frame.area, window.frame.area)
        }
    }

    /// Where the window goes back to: the place it last sat in, else the zone it covers most (the first, on a tie).
    public static func target(for frame: Rect, zones: [Rect], remembered: Rect?) -> Rect? {
        if let remembered { return remembered }
        var best: (zone: Rect, area: Double)?
        for z in zones {
            let a = z.intersection(frame)?.area ?? 0
            if a > (best?.area ?? 0) { best = (z, a) }
        }
        return best?.zone
    }
}
