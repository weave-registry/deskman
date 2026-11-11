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

    // MARK: The green button (ADR-2611111100)

    /// The place each window last sat in.
    private var lastPlace: [WindowID: Rect] = [:]
    /// The green button is in a window's top-left corner: a click further in is never on it.
    static let buttonCorner = (width: 140.0, height: 60.0)

    public func observe() {
        let displays = control.displays()
        let visible = control.windows().filter(\.isVisible)
        for w in visible {
            guard let d = Displays.containing(w.frame, in: displays),
                  let p = ZoneReturn.place(of: w.frame, in: ZoneReturn.places(zones(on: d))) else { continue }
            lastPlace[w.id] = p
        }
        // Forget windows that are gone, so the memory does not grow forever.
        if lastPlace.count > 200 {
            let ids = Set(control.windows().map(\.id))
            lastPlace = lastPlace.filter { ids.contains($0.key) }
        }
    }

    public func greenButtonClaim(at point: Point) -> WindowID? {
        guard settings?.greenButton ?? true else { return nil }
        let all = control.windows()
        // Front to back: the click is the front window's. Cheap tests first; this runs while the click waits.
        guard let under = all.first(where: { $0.isVisible && $0.frame.contains(point) }),
              point.x - under.frame.minX < Self.buttonCorner.width, point.y - under.frame.minY < Self.buttonCorner.height,
              !(settings?.isFloating(under.app) ?? false), !MeetingApps.contains(under.app),
              !MeetingApps.inMeeting(all) else { return nil }
        // The button first: its read gives up fast on an app that does not answer, so a hung app cannot hold the click.
        guard let button = control.greenButtonFrame(of: under.id), button.contains(point) else { return nil }
        // The list may be a second old (ADR-2610121200): judge the window by its frame now.
        let fresh = control.frame(of: under.id) ?? under.frame
        let w = WindowSnapshot(id: under.id, app: under.app, title: under.title, frame: fresh, isMinimized: false)
        guard let d = Displays.containing(fresh, in: control.displays()),
              ZoneReturn.isOutOfZone(w, among: all, places: ZoneReturn.places(zones(on: d))) else { return nil }
        return w.id
    }

    public func returnToZone(_ id: WindowID) -> CommandOutcome {
        guard let listed = control.windows().first(where: { $0.id == id }) else {
            return .failed("That window is gone.")
        }
        let frame = control.frame(of: id) ?? listed.frame
        let displays = control.displays()
        guard let d = Displays.containing(frame, in: displays) else { return .failed("\(listed.app) is on no display.") }
        let zones = zones(on: d)
        // A remembered place on another display, or from a grid no longer in use, is no place now.
        let remembered = lastPlace[id].flatMap { ZoneReturn.place(of: $0, in: ZoneReturn.places(zones)) }
        guard let target = ZoneReturn.target(for: frame, zones: zones, remembered: remembered) else {
            return .failed("There is no zone for \(listed.app) on this display.")
        }
        let w = WindowSnapshot(id: listed.id, app: listed.app, title: listed.title, frame: frame, isMinimized: listed.isMinimized)
        let outcome = place(w, in: target, how: "the green button")
        if outcome.succeeded { lastPlace[id] = target }
        return outcome.succeeded ? .ok("Put \(listed.app) back in its zone.") : outcome
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

    private func place(_ w: WindowSnapshot, in frame: Rect, how: String = "a snap hotkey or a drag") -> CommandOutcome {
        do {
            try control.acting(for: .person(how)) {
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
