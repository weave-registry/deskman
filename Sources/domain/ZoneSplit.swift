import Foundation

// Resting a drag on a taken zone splits it (ADR-2611121000). Top-left origin, y down.

/// A zone cut in two: one piece for the dragged window, the other for the window that was there.
public struct ZoneSplit: Equatable, Sendable {
    public let zone: Rect
    public let dragged: Rect
    public let other: Rect

    /// The split `window`'s shape asks for, with the dragged window on the side of `point`; nil when either
    /// direction would leave a piece too small to work in (`ZonePlanner` minimums).
    public static func split(_ zone: Rect, for window: Rect, at point: Point) -> ZoneSplit? {
        let minW = ZonePlanner.minimumWidth, minH = ZonePlanner.minimumHeight
        guard window.width > 0, window.height > 0 else { return nil }
        let aspect = log(window.width / window.height)

        // The dragged window's extent along the cut, clamped so both pieces are worked in.
        var options: [(sideBySide: Bool, size: Double, miss: Double)] = []
        if zone.width >= 2 * minW, zone.height >= minH {
            let w = min(max(window.width, minW), zone.width - minW)
            options.append((true, w, abs(log(w / zone.height) - aspect)))
        }
        if zone.height >= 2 * minH, zone.width >= minW {
            let h = min(max(window.height, minH), zone.height - minH)
            options.append((false, h, abs(log(zone.width / h) - aspect)))
        }
        // Nearest the window's shape; on a tie, side by side (never more than two high).
        guard let best = options.min(by: { $0.miss < $1.miss }) else { return nil }

        if best.sideBySide {
            let left = point.x < zone.midX
            let d = Rect(x: left ? zone.minX : zone.maxX - best.size, y: zone.y, width: best.size, height: zone.height)
            let o = Rect(x: left ? d.maxX : zone.minX, y: zone.y, width: zone.width - best.size, height: zone.height)
            return ZoneSplit(zone: zone, dragged: d, other: o)
        }
        let top = point.y < zone.midY
        let d = Rect(x: zone.x, y: top ? zone.minY : zone.maxY - best.size, width: zone.width, height: best.size)
        let o = Rect(x: zone.x, y: top ? d.maxY : zone.minY, width: zone.width, height: zone.height - best.size)
        return ZoneSplit(zone: zone, dragged: d, other: o)
    }
}
