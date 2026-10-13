/// A named place on a display. The raw values are what the language model sees.
public enum Layout: String, CaseIterable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    case leftTwoThirds, rightTwoThirds
    case maximize, center

    /// The frame this layout takes inside `area` (a display's visible frame).
    public func frame(in a: Rect) -> Rect {
        let w = a.width, h = a.height
        func part(_ fx: Double, _ fy: Double, _ fw: Double, _ fh: Double) -> Rect {
            Rect(x: a.x + w * fx, y: a.y + h * fy, width: w * fw, height: h * fh)
        }
        switch self {
        case .leftHalf: return part(0, 0, 0.5, 1)
        case .rightHalf: return part(0.5, 0, 0.5, 1)
        case .topHalf: return part(0, 0, 1, 0.5)
        case .bottomHalf: return part(0, 0.5, 1, 0.5)
        case .topLeft: return part(0, 0, 0.5, 0.5)
        case .topRight: return part(0.5, 0, 0.5, 0.5)
        case .bottomLeft: return part(0, 0.5, 0.5, 0.5)
        case .bottomRight: return part(0.5, 0.5, 0.5, 0.5)
        // Thirds are built from edges, not widths, so they meet with no gap.
        case .leftThird: return Rect(x: a.x, y: a.y, width: (w / 3), height: h)
        case .centerThird: return Rect(x: a.x + w / 3, y: a.y, width: (2 * w / 3) - (w / 3), height: h)
        case .rightThird: return Rect(x: a.x + 2 * w / 3, y: a.y, width: w - (2 * w / 3), height: h)
        case .leftTwoThirds: return Rect(x: a.x, y: a.y, width: 2 * w / 3, height: h)
        case .rightTwoThirds: return Rect(x: a.x + w / 3, y: a.y, width: w - (w / 3), height: h)
        case .maximize: return a
        case .center: return part(0.2, 0.15, 0.6, 0.7)
        }
    }

    /// Plain words for a status line: "the left half".
    public var phrase: String {
        switch self {
        case .leftHalf: "the left half"
        case .rightHalf: "the right half"
        case .topHalf: "the top half"
        case .bottomHalf: "the bottom half"
        case .topLeft: "the top-left quarter"
        case .topRight: "the top-right quarter"
        case .bottomLeft: "the bottom-left quarter"
        case .bottomRight: "the bottom-right quarter"
        case .leftThird: "the left third"
        case .centerThird: "the center third"
        case .rightThird: "the right third"
        case .leftTwoThirds: "the left two-thirds"
        case .rightTwoThirds: "the right two-thirds"
        case .maximize: "the full screen"
        case .center: "the center"
        }
    }
}

public enum GridTiler {
    /// `count` tiles that cover `area` with no overlap. Columns = ⌈√count⌉;
    /// when the last row is short, its tiles stretch to fill the width.
    public static func frames(count: Int, in area: Rect) -> [Rect] {
        guard count > 0 else { return [] }
        let columns = Int(Double(count).squareRoot().rounded(.up))
        let rows = (count + columns - 1) / columns
        let rowHeight = area.height / Double(rows)
        var frames: [Rect] = []
        for row in 0..<rows {
            let inRow = min(columns, count - row * columns)
            let tileWidth = area.width / Double(inRow)
            for col in 0..<inRow {
                frames.append(Rect(x: area.x + tileWidth * Double(col), y: area.y + rowHeight * Double(row),
                                   width: tileWidth, height: rowHeight))
            }
        }
        return frames
    }
}
