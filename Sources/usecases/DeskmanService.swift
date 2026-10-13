import DeskmanPorts

/// One request from the person: check the preconditions, ask the model, and
/// recover once when the conversation outgrows the model's context window.
@MainActor public final class DeskmanService: DeskmanPort {
    private let assistant: any Assistant
    private let control: any WindowControl

    public init(assistant: any Assistant, control: any WindowControl) {
        self.assistant = assistant
        self.control = control
    }

    public var status: DeskmanStatus {
        DeskmanStatus(assistant: assistant.availability, windowControlTrusted: control.isTrusted)
    }

    public func requestWindowControlTrust() {
        control.requestTrust()
    }

    public func send(_ text: String) async -> AssistantReply {
        let text = text.trimmingWhitespaceAndNewlines()
        guard !text.isEmpty else { return AssistantReply(text: "", actions: []) }

        if case .unavailable(let reason) = assistant.availability {
            return AssistantReply(text: reason, actions: [])
        }
        guard control.isTrusted else {
            return AssistantReply(
                text: "Deskman needs Accessibility permission to move windows. "
                    + "Open System Settings → Privacy & Security → Accessibility and turn on Deskman.",
                actions: [])
        }

        do {
            return try await assistant.reply(to: text)
        } catch AssistantError.contextFull {
            // One fresh start. A second overflow means the request alone is too big.
            assistant.reset()
            do {
                return try await assistant.reply(to: text)
            } catch AssistantError.contextFull {
                return AssistantReply(text: "That request is too long for the on-device model. Try a shorter one.", actions: [])
            } catch {
                return failure(error)
            }
        } catch {
            return failure(error)
        }
    }

    private func failure(_ error: any Error) -> AssistantReply {
        if case AssistantError.failed(let message) = error {
            return AssistantReply(text: "Sorry, that did not work: \(message)", actions: [])
        }
        return AssistantReply(text: "Sorry, that did not work: \(error)", actions: [])
    }

    public func reset() {
        assistant.reset()
    }

    public func prewarm() {
        assistant.prewarm()
    }
}

extension String {
    func trimmingWhitespaceAndNewlines() -> String {
        var s = Substring(self)
        while s.first?.isWhitespace == true { s.removeFirst() }
        while s.last?.isWhitespace == true { s.removeLast() }
        return String(s)
    }
}
