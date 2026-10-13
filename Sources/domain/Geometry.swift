// Coordinate system (ADR-2610101046 §5): every Rect inside the hexagon uses the
// Accessibility convention — origin at the top-left corner of the primary
// display, x to the right, y DOWN, in points. A display above the primary one
// has negative y. AppKit's bottom-left convention exists only at the edge, and
// `CoordinateSpace` is the one place that converts it.

public struct Rect: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { width * height }

    /// The overlap of two rects, or nil when they only touch or do not meet.
    public func intersection(_ other: Rect) -> Rect? {
        let x0 = max(minX, other.minX), x1 = min(maxX, other.maxX)
        let y0 = max(minY, other.minY), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// True when `other` lies fully inside this rect. Edges count as inside.
    public func contains(_ other: Rect) -> Bool {
        let e = 0.0001
        return other.minX >= minX - e && other.maxX <= maxX + e
            && other.minY >= minY - e && other.maxY <= maxY + e
    }

    public var description: String {
        "(\(Int(x.rounded())), \(Int(y.rounded())), \(Int(width.rounded()))×\(Int(height.rounded())))"
    }
}

public enum CoordinateSpace {
    /// AppKit (origin bottom-left of the primary display, y up) → top-left, y down.
    public static func topLeft(fromAppKit r: Rect, primaryDisplayHeight h: Double) -> Rect {
        Rect(x: r.x, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// Top-left, y down → AppKit. The same flip; it is its own inverse.
    public static func appKit(fromTopLeft r: Rect, primaryDisplayHeight h: Double) -> Rect {
        Rect(x: r.x, y: h - r.maxY, width: r.width, height: r.height)
    }
}

public struct Display: Equatable, Hashable, Sendable {
    /// 0 is the primary display (the one with the menu bar).
    public let index: Int
    /// The area a window may use: the display minus the menu bar and the Dock.
    public let visibleFrame: Rect

    public init(index: Int, visibleFrame: Rect) {
        self.index = index
        self.visibleFrame = visibleFrame
    }
}

public enum Displays {
    /// The display that holds most of `rect`. A rect off every display gets the first one.
    public static func containing(_ rect: Rect, in displays: [Display]) -> Display? {
        let best = displays.max { a, b in
            (a.visibleFrame.intersection(rect)?.area ?? 0) < (b.visibleFrame.intersection(rect)?.area ?? 0)
        }
        guard let best, (best.visibleFrame.intersection(rect)?.area ?? 0) > 0 else { return displays.first }
        return best
    }

    /// The display after `display`, wrapping to the first.
    public static func next(after display: Display, in displays: [Display]) -> Display? {
        guard let i = displays.firstIndex(of: display) else { return displays.first }
        return displays[(i + 1) % displays.count]
    }
}

/// A point on the screen: top-left origin, y down, like `Rect`.
public struct Point: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public extension Rect {
    func contains(_ p: Point) -> Bool { p.x >= x && p.x < maxX && p.y >= y && p.y < maxY }
}
