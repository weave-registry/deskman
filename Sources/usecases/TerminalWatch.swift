import DeskmanPorts

/// Terminal jobs, read at most every 15 seconds (ADR-2610101549 §5): they change
/// slowly, and a scan of every process is the cost.
@MainActor public final class TerminalWatch {
    public static let interval = 15.0

    private let source: any TerminalActivity
    private let clock: any TimeSource
    private var cached: [TerminalJob] = []
    private var readAt: Double?

    public init(source: any TerminalActivity, clock: any TimeSource) {
        self.source = source
        self.clock = clock
    }

    public func jobs() -> [TerminalJob] {
        let now = clock.now()
        if let readAt, now - readAt < Self.interval { return cached }
        cached = source.jobs()
        readAt = now
        return cached
    }

    public func match(_ windows: [WindowSnapshot]) -> TerminalMatch {
        TerminalMatcher.match(jobs(), to: windows)
    }
}
