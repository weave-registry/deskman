import DeskmanPorts

/// The action was refused by the gateway; `reason` says why, in words.
public struct GatewayRefusal: Error, CustomStringConvertible, Sendable {
    public let reason: String
    public var description: String { "refused: \(reason)" }
}

/// Every window action passes here (ADR-2610121800, after OpenBot's gateway): decided by
/// `GatewayPolicy` before it happens, recorded in the decision log after. The composition root
/// wraps the window control once, outermost, so nothing reaches a window around it.
@MainActor public final class WindowGateway: WindowControl {
    private let inner: any WindowControl
    private let decisions: (any DecisionLog)?
    /// Who is asking now; nil means Deskman on its own, and the strict rules.
    private var origin: ActionOrigin?

    public init(_ inner: any WindowControl, decisions: (any DecisionLog)?) {
        self.inner = inner
        self.decisions = decisions
    }

    public func acting<T>(for origin: ActionOrigin, _ body: () throws -> T) rethrows -> T {
        let outer = self.origin
        self.origin = origin
        defer { self.origin = outer }
        return try inner.acting(for: origin) { try body() }
    }

    public func setFrame(_ frame: Rect, of id: WindowID) throws {
        try gate(.move(to: frame), id) { try inner.setFrame(frame, of: id) }
    }

    public func perform(_ action: WindowAction, on id: WindowID) throws {
        try gate(.act(action), id) { try inner.perform(action, on: id) }
    }

    private func gate(_ action: GatedAction, _ id: WindowID, _ go: () throws -> Void) throws {
        let all = inner.windows()
        let window = all.first { $0.id == id }
        let who = origin ?? .automatic("Deskman")
        let decision = GatewayPolicy.decide(action, on: window, origin: who,
                                            context: GateContext(inMeeting: MeetingApps.inMeeting(all),
                                                                 frontmost: inner.frontmostWindowID()))
        let what = window.map { "\($0.app) \"\($0.title.prefix(40))\"" } ?? "window \(id.raw.prefix(8))"
        guard decision.allowed else {
            decisions?.record("Refused: \(action.phrase) of \(what), for \(who.phrase): \(decision.reason).")
            throw GatewayRefusal(reason: decision.reason)
        }
        do {
            try go()
            decisions?.record("Did: \(action.phrase) of \(what), for \(who.phrase).")
        } catch {
            decisions?.record("Failed: \(action.phrase) of \(what), for \(who.phrase): \(error).")
            throw error
        }
    }

    public func windows() -> [WindowSnapshot] { inner.windows() }
    public func displays() -> [Display] { inner.displays() }
    public func frontmostWindowID() -> WindowID? { inner.frontmostWindowID() }
    public func frame(of id: WindowID) -> Rect? { inner.frame(of: id) }
    public func launch(app: String) throws { try inner.launch(app: app) }
    public var isTrusted: Bool { inner.isTrusted }
    public func requestTrust() { inner.requestTrust() }
}
