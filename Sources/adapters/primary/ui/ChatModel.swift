import Foundation
import Observation
import DeskmanPorts

/// The panel's state. It talks to Deskman only through `DeskmanPort`.
@MainActor @Observable public final class ChatModel {
    public struct Entry: Identifiable, Equatable {
        public enum Kind: Equatable { case user, assistant, action(succeeded: Bool) }
        public let id = UUID()
        public let kind: Kind
        public let text: String
    }

    public private(set) var entries: [Entry] = []
    public private(set) var status: DeskmanStatus
    public private(set) var isBusy = false
    public var input = ""

    private let port: any DeskmanPort

    public init(port: any DeskmanPort) {
        self.port = port
        self.status = port.status
    }

    public static let examples = [
        "Put this window on the left half",
        "Safari and Notes side by side",
        "Tile all my windows",
        "Open Calendar on the right third",
        "Move this to my other screen",
        "Minimize everything except Mail",
    ]

    public func submit(_ text: String? = nil) {
        let request = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isBusy else { return }
        input = ""
        entries.append(Entry(kind: .user, text: request))
        isBusy = true
        Task {
            let reply = await port.send(request)
            for action in reply.actions {
                entries.append(Entry(kind: .action(succeeded: action.succeeded), text: action.message))
            }
            if !reply.text.isEmpty {
                entries.append(Entry(kind: .assistant, text: reply.text))
            }
            isBusy = false
            refreshStatus()
        }
    }

    public func refreshStatus() {
        let new = port.status
        if new != status { status = new }
    }

    public func requestPermission() {
        port.requestWindowControlTrust()
    }

    public func clear() {
        entries = []
        port.reset()
    }

    public func prewarm() {
        port.prewarm()
    }
}
