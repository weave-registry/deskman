// Hover to expand a stacked window (ADR-2611111000). Top-left origin, y down: the top of a stack
// is its smallest y, and "the height between the edges" is last.maxY − first.minY.

public enum HoverExpand {
    /// The hovered window gets at least this share of the stack's height (the user, 2026-11-11).
    public static let share = 0.75
    /// The others never get less than this, in points: enough to see what they are and point at them.
    public static let minimumHeight = 120.0
    /// Two windows are in one column when they overlap across this much of the wider one.
    public static let columnOverlap = 0.8
    /// Windows further apart than this, in points, are not stacked.
    public static let maxGap = 60.0
    /// Two windows that overlap vertically by more than this are on top of each other, not stacked.
    static let overlapTolerance = 8.0

    /// The windows stacked with `hovered`, top to bottom, or nil when it has none. `windows` front to back:
    /// of two that would overlap each other, the front one is the stack's.
    public static func stack(around hovered: WindowID, in windows: [WindowSnapshot]) -> [WindowSnapshot]? {
        guard let h = windows.first(where: { $0.id == hovered }) else { return nil }
        var column = [h]
        for w in windows where w.id != hovered && w.isVisible && sameColumn(w.frame, h.frame)
            && column.allSatisfy({ apart($0.frame, w.frame) }) {
            column.append(w)
        }
        column.sort { $0.frame.minY < $1.frame.minY }
        guard var lo = column.firstIndex(where: { $0.id == hovered }) else { return nil }
        var hi = lo
        while lo > 0, column[lo].frame.minY - column[lo - 1].frame.maxY <= maxGap { lo -= 1 }
        while hi < column.count - 1, column[hi + 1].frame.minY - column[hi].frame.maxY <= maxGap { hi += 1 }
        return hi > lo ? Array(column[lo...hi]) : nil
    }

    /// The stack's frames, top to bottom, with the window at `index` given the room: at least `share` of the
    /// height, the others sharing the rest equally and never under `minimumHeight`. The same top and bottom
    /// edges, x, widths and gaps. Nil when the window would not gain.
    public static func layout(_ frames: [Rect], expanding index: Int) -> [Rect]? {
        let n = frames.count
        guard n >= 2, frames.indices.contains(index) else { return nil }
        let gaps = (0..<(n - 1)).map { frames[$0 + 1].minY - frames[$0].maxY }
        let room = frames[n - 1].maxY - frames[0].minY - gaps.reduce(0, +)
        let height = min(max(frames[index].height, share * room), room - minimumHeight * Double(n - 1))
        guard height > frames[index].height + 1 else { return nil }
        let other = (room - height) / Double(n - 1)
        var y = frames[0].minY
        var out: [Rect] = []
        for i in 0..<n {
            let h = i == index ? height : other
            out.append(Rect(x: frames[i].x, y: y, width: frames[i].width, height: h))
            y += h + (i < n - 1 ? gaps[i] : 0)
        }
        return out
    }

    /// The area the stack stands in: leaving it is leaving the stack.
    public static func column(of frames: [Rect]) -> Rect? {
        guard let x0 = frames.map(\.minX).min(), let y0 = frames.map(\.minY).min(),
              let x1 = frames.map(\.maxX).max(), let y1 = frames.map(\.maxY).max() else { return nil }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func sameColumn(_ a: Rect, _ b: Rect) -> Bool {
        let across = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return across >= columnOverlap * max(a.width, b.width)
    }

    static func apart(_ a: Rect, _ b: Rect) -> Bool {
        min(a.maxY, b.maxY) - max(a.minY, b.minY) <= overlapTolerance
    }
}
