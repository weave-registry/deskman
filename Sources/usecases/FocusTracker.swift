import DeskmanPorts

/// Which apps are in use now: one sample per learning tick, kept for 30 minutes.
/// In memory only; "most active" is about this session, not about last week.
@MainActor public final class FocusTracker {
    public static let horizon = 1800.0
    /// One sample per learning tick: 5 s (LearningModel.interval).
    public static let sampleSeconds = 5.0

    /// Samples as minutes in front, for the decision log: one rule with What Deskman Knows's.
    public static func minutes(_ samples: Int) -> String { DesktopMap.Knowledge.minutes(samples) }

    private let clock: any TimeSource
    private var samples: [(time: Double, app: String, window: WindowID?)] = []

    public init(clock: any TimeSource) {
        self.clock = clock
    }

    /// `window`: which of the app's windows was in front (the user, 2026-10-12: three Firefox
    /// windows were one "Firefox", so the middle went to whichever came first).
    public func record(app: String?, window: WindowID? = nil) {
        let now = clock.now()
        if let app { samples.append((now, app, window)) }
        samples.removeAll { $0.time < now - Self.horizon }
    }

    /// Samples per app within the last 30 minutes.
    public func activity() -> [String: Int] {
        let since = clock.now() - Self.horizon
        var counts: [String: Int] = [:]
        for s in samples where s.time >= since { counts[s.app, default: 0] += 1 }
        return counts
    }

    /// Samples per window within the last 30 minutes.
    public func windowActivity() -> [WindowID: Int] {
        let since = clock.now() - Self.horizon
        var counts: [WindowID: Int] = [:]
        for s in samples where s.time >= since { if let w = s.window { counts[w, default: 0] += 1 } }
        return counts
    }
}
