import DeskmanPorts

/// A move or resize by hand is an intent (ADR-2610101501 queue item 1). A window the
/// person placed is pinned for 30 minutes: Smart Arrange keeps it and plans around it.
/// A place Deskman made is marked, so learning never takes it for a habit.
@MainActor public final class IntentLog {
    public static let pinSeconds = 1800.0
    /// Moves smaller than this, in points, are jitter.
    static let threshold = 8.0
    /// A change this soon after Deskman moved a window is Deskman's (apps may clamp the frame).
    static let attributionSeconds = 10.0

    private let clock: any TimeSource
    /// Where pins are explained. Set by the composition root.
    public var decisions: (any DecisionLog)?
    private var last: [WindowID: Rect] = [:]
    private var intents: [WindowID: (time: Double, app: String)] = [:]
    private var deskmanMoved: [WindowID: Double] = [:]
    private var deskmanFrame: [WindowID: Rect] = [:]
    /// The frame Deskman last set, until the person moves the window. A window that sits there
    /// is Deskman's, however many reads it took to show it (a read older than the move, 2026-10-12).
    private var deskmanTarget: [WindowID: Rect] = [:]
    /// Where the window was before Deskman's move, and when: a read that shows it there again
    /// this soon started before the move. It is no news, and nobody's intent.
    private var deskmanFrom: [WindowID: (time: Double, frame: Rect)] = [:]
    /// Where Deskman, or a snap, last put each window, until the person takes it elsewhere.
    private var placedAt: [WindowID: Rect] = [:]
    /// Windows the person resized from where Deskman or a snap put them (ADR-2610131157): the zone did
    /// not fit. Kept while the window stays pinned, however often it is adjusted after.
    private var corrections: Set<WindowID> = []

    public init(clock: any TimeSource) {
        self.clock = clock
    }

    /// Call on every observation of the desktop.
    public func observe(_ windows: [WindowSnapshot]) {
        let now = clock.now()
        for w in windows where w.isVisible {
            defer { last[w.id] = w.frame }
            // One observation per Deskman move, changed or not: a move that showed no
            // change (target within jitter, or the app ignored it) must not claim the
            // person's next move.
            let movedAt = deskmanMoved.removeValue(forKey: w.id)
            guard let before = last[w.id], Self.changed(before, w.frame) else { continue }
            if let from = deskmanFrom[w.id], now - from.time <= Self.attributionSeconds, !Self.changed(from.frame, w.frame) {
                continue
            } else if let target = deskmanTarget[w.id], !Self.changed(target, w.frame) {
                deskmanFrame[w.id] = w.frame
            } else if let t = movedAt, now - t <= Self.attributionSeconds {
                deskmanFrame[w.id] = w.frame
            } else if let target = deskmanTarget[w.id], let from = deskmanFrom[w.id],
                      now - from.time <= Self.attributionSeconds, Self.near(target, w.frame) {
                // The app settling after Deskman's move: iTerm2 snaps to whole text cells, Firefox lands
                // late (2026-10-12: three windows pinned 3 s after Smart Arrange). Not the person.
                deskmanFrame[w.id] = w.frame
            } else {
                let moved = Int(max(abs(w.frame.x - before.x), abs(w.frame.y - before.y),
                                    abs(w.frame.maxX - before.maxX), abs(w.frame.maxY - before.maxY)))
                let r = { (f: Rect) in "\(Int(f.x)),\(Int(f.y)) \(Int(f.width))×\(Int(f.height))" }
                let deskman = deskmanTarget[w.id].map { "; Deskman last put it at \(r($0))" } ?? "; Deskman had not moved it"
                let resized = abs(w.frame.width - before.width) > Self.threshold
                    || abs(w.frame.height - before.height) > Self.threshold
                if let at = placedAt[w.id], !Self.changed(at, before), resized { corrections.insert(w.id) }
                if let at = placedAt[w.id], Self.changed(at, w.frame) { placedAt[w.id] = nil }
                decisions?.record("Pinned \(w.app) \"\(w.title.prefix(40))\" [\(w.id.raw.prefix(8))]: it moved \(moved) pt, "
                                  + "\(r(before)) → \(r(w.frame))\(deskman). Smart Arrange keeps it where it is for 30 minutes, or until Unpin All.")
                intents[w.id] = (now, w.app)
                deskmanFrame[w.id] = nil
                deskmanTarget[w.id] = nil
                deskmanFrom[w.id] = nil
            }
        }
        intents = intents.filter { now - $0.value.time < Self.pinSeconds }
    }

    /// Called by `IntentRecordingControl` for every frame Deskman sets.
    func deskmanPlaced(_ id: WindowID, _ frame: Rect) {
        deskmanMoved[id] = clock.now()
        deskmanFrame[id] = frame
        deskmanTarget[id] = frame
        if let before = last[id] { deskmanFrom[id] = (clock.now(), before) }
        intents[id] = nil
        placedAt[id] = frame
        corrections.remove(id)
    }

    /// The person chose this place (a snap hotkey, a drag onto a zone), even though
    /// Deskman did the moving: it is pinned, and it counts as the person's habit.
    public func personPlaced(_ id: WindowID) {
        intents[id] = (clock.now(), intents[id]?.app ?? "")
        deskmanMoved[id] = nil
        deskmanFrame[id] = nil
        deskmanTarget[id] = nil
        deskmanFrom[id] = nil
    }

    /// Forget every pin: Smart Arrange may move every window again.
    public func unpinAll() {
        intents = [:]
        corrections = []
    }

    /// Windows the person placed in the last 30 minutes.
    public func pinned() -> Set<WindowID> {
        let now = clock.now()
        return Set(intents.filter { now - $0.value.time < Self.pinSeconds }.keys)
    }

    /// Pinned windows the person resized from where Deskman or a snap put them.
    public func corrected() -> Set<WindowID> {
        corrections.intersection(pinned())
    }

    /// Windows that sit where Deskman put them.
    public func placedByDeskman(_ windows: [WindowSnapshot]) -> Set<WindowID> {
        Set(windows.filter { w in deskmanFrame[w.id].map { !Self.changed($0, w.frame) } ?? false }.map(\.id))
    }

    /// How far an app may settle from Deskman's frame, per edge. A drag moves much further.
    static let settle = 48.0

    static func near(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) <= settle && abs(a.y - b.y) <= settle
            && abs(a.maxX - b.maxX) <= settle && abs(a.maxY - b.maxY) <= settle
    }

    static func changed(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) > threshold || abs(a.y - b.y) > threshold
            || abs(a.width - b.width) > threshold || abs(a.height - b.height) > threshold
    }
}

/// Every frame Deskman sets passes through here, so `IntentLog` can tell Deskman's
/// moves from the person's. The composition root wraps the real control once.
@MainActor public final class IntentRecordingControl: WindowControl {
    private let inner: any WindowControl
    private let log: IntentLog

    public init(_ inner: any WindowControl, log: IntentLog) {
        self.inner = inner
        self.log = log
    }

    public func windows() -> [WindowSnapshot] { inner.windows() }
    public func displays() -> [Display] { inner.displays() }
    public func frontmostWindowID() -> WindowID? { inner.frontmostWindowID() }
    public func frame(of id: WindowID) -> Rect? { inner.frame(of: id) }
    public func setFrame(_ frame: Rect, of id: WindowID) throws {
        try inner.setFrame(frame, of: id)
        log.deskmanPlaced(id, frame)
    }
    public func perform(_ action: WindowAction, on id: WindowID) throws { try inner.perform(action, on: id) }
    public func launch(app: String) throws { try inner.launch(app: app) }
    public var isTrusted: Bool { inner.isTrusted }
    public func requestTrust() { inner.requestTrust() }
    public func acting<T>(for origin: ActionOrigin, _ body: () throws -> T) rethrows -> T {
        try inner.acting(for: origin, body)
    }
}
