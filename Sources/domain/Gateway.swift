// Every window action is decided before it happens and recorded after (the user, 2026-10-12:
// "build the gateway", after OpenBot's). One table of rules, here; the gateway in the use cases
// applies it to every move, resize, minimize, restore, focus and close, whoever asked.

/// Who asked for an action. Without one, the gateway assumes Deskman on its own: the strict rules.
public enum ActionOrigin: Equatable, Sendable {
    /// The person: a click, a hotkey, a drag, Undo, a request to the assistant.
    case person(String)
    /// Deskman on its own: Keep Arranged, a habit, a bound project, a new browser placed.
    case automatic(String)

    public var phrase: String {
        switch self {
        case .person(let how): "you asked (\(how))"
        case .automatic(let what): "Deskman on its own (\(what))"
        }
    }
}

public enum GatedAction: Equatable, Sendable {
    case move(to: Rect)
    case act(WindowAction)

    public var phrase: String {
        switch self {
        case .move(let r): "move to \(Int(r.x)),\(Int(r.y)) \(Int(r.width))×\(Int(r.height))"
        case .act(let a): String(describing: a)
        }
    }
}

public struct GateContext: Equatable, Sendable {
    /// A meeting app shows a meeting, call or share (MeetingApps).
    public let inMeeting: Bool
    /// The window the person is working in.
    public let frontmost: WindowID?

    public init(inMeeting: Bool, frontmost: WindowID?) {
        self.inMeeting = inMeeting
        self.frontmost = frontmost
    }
}

public struct GateDecision: Equatable, Sendable {
    public let allowed: Bool
    public let reason: String
}

public enum GatewayPolicy {
    /// What the person asks for is done. On its own, Deskman never minimizes, closes, hides or fills
    /// the screen; moves nothing during a meeting; never moves the window being worked in; never
    /// touches a meeting app; and leaves alone a window it cannot see.
    public static func decide(_ action: GatedAction, on window: WindowSnapshot?, origin: ActionOrigin,
                              context: GateContext) -> GateDecision {
        guard case .automatic = origin else { return GateDecision(allowed: true, reason: origin.phrase) }
        guard let window else {
            return GateDecision(allowed: false, reason: "Deskman cannot see that window, so it leaves it alone")
        }
        if context.inMeeting {
            return GateDecision(allowed: false, reason: "a meeting is on: Deskman changes nothing on its own")
        }
        if case .act(let a) = action, [.minimize, .close, .hideApp, .fullScreen].contains(a) {
            return GateDecision(allowed: false, reason: "Deskman never minimizes, closes, hides or fills the screen on its own")
        }
        if MeetingApps.contains(window.app) {
            return GateDecision(allowed: false, reason: "meeting apps are never moved")
        }
        if case .move = action, window.id == context.frontmost {
            return GateDecision(allowed: false, reason: "you are working in it")
        }
        return GateDecision(allowed: true, reason: origin.phrase)
    }
}
