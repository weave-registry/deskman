/// Value types for talking to a language model. No model is named here (hexa G1).

public enum AssistantAvailability: Equatable, Sendable {
    case available
    /// The reason, in words a person can act on.
    case unavailable(String)
}

public enum AssistantError: Error, Equatable, Sendable {
    /// The conversation no longer fits in the model's context window.
    case contextFull
    case failed(String)
}

public struct AssistantReply: Equatable, Sendable {
    public let text: String
    /// Every command the model ran to produce this reply, in order.
    public let actions: [CommandOutcome]

    public init(text: String, actions: [CommandOutcome]) {
        self.text = text
        self.actions = actions
    }
}

public struct DeskmanStatus: Equatable, Sendable {
    public let assistant: AssistantAvailability
    public let windowControlTrusted: Bool

    public init(assistant: AssistantAvailability, windowControlTrusted: Bool) {
        self.assistant = assistant
        self.windowControlTrusted = windowControlTrusted
    }
}
