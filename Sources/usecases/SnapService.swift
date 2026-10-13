import DeskmanPorts

/// Snap hotkeys and drag-to-snap (ADR-2610101523 §4). A snap is the person's choice:
/// the window is pinned and its place counts as a habit, though Deskman moves it.
@MainActor public final class SnapService: SnapPort {
    /// A move smaller than this, in points, is a click.
    static let moveThreshold = 20.0
    /// A size change bigger than this is a resize, not a drag.
    static let sizeTolerance = 4.0

    private let control: any WindowControl
    private let intents: IntentLog?
    private let settings: Settings?
    private let bindings: BindingService?
    /// The learned grid (ADR-2610131157); without it, the standard one.
    private let grid: LearnedGrid?
    private var drag: (id: WindowID, app: String, frame: Rect)?
    private var confirmed = false

    public init(control: any WindowControl, intents: IntentLog?, settings: Settings? = nil,
                bindings: BindingService? = nil, grid: LearnedGrid? = nil) {
        self.grid = grid
        self.control = control
        self.settings = settings
        self.bindings = bindings
        self.intents = intents
    }

    public func snapZones(at point: Point) -> [Rect] {
        let displays = control.displays()
        let d = displays.first { $0.visibleFrame.contains(point) } ?? displays.first
        return d.map(zones(on:)) ?? []
    }

    private func zones(on display: Display) -> [Rect] {
        grid?.zones(on: display) ?? ZoneGenerator.snapZones(on: display)
    }

    public func snapFrontmost(toZone zone: Int) -> CommandOutcome {
        guard let (w, display) = frontmost() else { return .failed("There is no window in front to snap.") }
        let zones = zones(on: display)
        guard (1...zones.count).contains(zone) else {
            return .failed("This display has \(zones.count) zones; there is no zone \(zone).")
        }
        return placeWithPartners(w, in: zones[zone - 1], zones: zones)
    }

    public func fillFrontmost() -> CommandOutcome {
        guard let (w, display) = frontmost() else { return .failed("There is no window in front to fill the screen with.") }
        return place(w, in: display.visibleFrame)
    }

    public func beginDrag(at point: Point) {
        confirmed = false
        // Front to back: the first window under the mouse is the one it grabbed.
        drag = nil
        // Drag-to-snap off, or a floating app under the mouse: no drag to watch, so no overlay and no snap.
        guard settings?.dragSnap ?? true,
              let w = control.windows().first(where: { $0.isVisible && $0.frame.contains(point) }),
              !(settings?.isFloating(w.app) ?? false) else { return }
        // The list may be a second old: the frame the drag starts from is read fresh (ADR-2610121200).
        drag = (w.id, w.app, control.frame(of: w.id) ?? w.frame)
    }

    public func confirmDrag() -> Bool {
        guard let drag, let now = control.frame(of: drag.id) else { return false }
        let moved = abs(now.x - drag.frame.x) > Self.moveThreshold || abs(now.y - drag.frame.y) > Self.moveThreshold
        let sameSize = abs(now.width - drag.frame.width) <= Self.sizeTolerance
            && abs(now.height - drag.frame.height) <= Self.sizeTolerance
        confirmed = moved && sameSize
        return confirmed
    }

    public func dragTarget(at point: Point) -> Int? {
        guard confirmed, drag != nil else { return nil }
        return ZoneGenerator.zone(at: point, in: snapZones(at: point))
    }

    public func endDrag(at point: Point, bypass: Bool) -> CommandOutcome? {
        defer { drag = nil; confirmed = false }
        // Without a confirmed drag, a last look: a quick flick may end before the first check.
        guard let d = drag, !bypass, confirmed || confirmDrag() else { return nil }
        let zones = snapZones(at: point)
        guard let i = ZoneGenerator.zone(at: point, in: zones),
              let w = control.windows().first(where: { $0.id == d.id }) else { return nil }
        return placeWithPartners(w, in: zones[i], zones: zones)
    }

    private func frontmost() -> (WindowSnapshot, Display)? {
        let displays = control.displays()
        guard let id = control.frontmostWindowID(),
              let w = control.windows().first(where: { $0.id == id && $0.isOnCurrentDesktop }),
              let d = Displays.containing(w.frame, in: displays) ?? displays.first else { return nil }
        return (w, d)
    }

    /// A bound window's partners go in the zone beside it (ADR-2610120830). One beside zone for all:
    /// with more partners than zones, they share it.
    private func placeWithPartners(_ w: WindowSnapshot, in frame: Rect, zones: [Rect]) -> CommandOutcome {
        let outcome = place(w, in: frame)
        guard outcome.succeeded, let bindings else { return outcome }
        let all = control.windows()
        let partners = bindings.partners(of: w.id, in: all).filter(\.isOnCurrentDesktop)
        guard !partners.isEmpty, let beside = ZoneGenerator.zone(beside: frame, in: zones) else { return outcome }
        let moved = partners.filter { place($0, in: beside).succeeded }
        return moved.isEmpty ? outcome : .ok("Snapped \(w.app), with \(moved.map(\.app).joined(separator: ", ")) beside it.")
    }

    private func place(_ w: WindowSnapshot, in frame: Rect) -> CommandOutcome {
        do {
            try control.acting(for: .person("a snap hotkey or a drag")) {
                if w.isMinimized { try control.perform(.restore, on: w.id) }
                try control.setFrame(frame, of: w.id)
            }
        } catch {
            return .failed("\(w.app): \(error).")
        }
        intents?.personPlaced(w.id)
        return .ok("Snapped \(w.app).")
    }
}
