public struct WindowID: Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

public struct WindowSnapshot: Equatable, Sendable, Identifiable {
    public let id: WindowID
    public let app: String
    public let title: String
    public let frame: Rect
    public let isMinimized: Bool
    /// The Mission Control desktop number, 1-based and counted across displays.
    /// Nil when macOS does not say (ADR-2610101429).
    public let desktop: Int?
    /// False for a window on another desktop. Its frame is then not on screen,
    /// even though it overlaps the current display's coordinates.
    public let isOnCurrentDesktop: Bool
    /// The file or folder the window shows, when the app says (a terminal's folder,
    /// an editor's file). Helps the model name it (ADR-2610101542).
    public let document: String?

    public init(id: WindowID, app: String, title: String, frame: Rect, isMinimized: Bool,
                desktop: Int? = nil, isOnCurrentDesktop: Bool = true, document: String? = nil) {
        self.document = document
        self.id = id
        self.app = app
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.desktop = desktop
        self.isOnCurrentDesktop = isOnCurrentDesktop
    }

    /// On screen now: on the current desktop and not minimized.
    public var isVisible: Bool { isOnCurrentDesktop && !isMinimized }

    /// "desktop 3", or "another desktop" when the number is unknown.
    public var desktopPhrase: String { desktop.map { "desktop \($0)" } ?? "another desktop" }
}

public enum WindowAction: String, CaseIterable, Sendable {
    case focus, minimize, restore, close, hideApp, fullScreen

    public var pastTense: String {
        switch self {
        case .focus: "Focused"
        case .minimize: "Minimized"
        case .restore: "Restored"
        case .close: "Closed"
        case .hideApp: "Hid"
        case .fullScreen: "Made full screen"
        }
    }
}

/// What one command did. Tools return this instead of throwing, so the model
/// can read a failure and try again (ADR-2610101046 §6).
public struct CommandOutcome: Equatable, Sendable {
    public let succeeded: Bool
    public let message: String

    public init(succeeded: Bool, message: String) {
        self.succeeded = succeeded
        self.message = message
    }

    public static func ok(_ message: String) -> Self { .init(succeeded: true, message: message) }
    public static func failed(_ message: String) -> Self { .init(succeeded: false, message: message) }
}
