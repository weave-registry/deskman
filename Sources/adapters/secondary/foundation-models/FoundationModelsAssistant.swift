import FoundationModels
import DeskmanPorts

/// `Assistant` over Apple's on-device model. This file and `Tools.swift` are the
/// only places in Deskman that name a model (hexa G1, ADR-2610101046 §4).
@MainActor public final class FoundationModelsAssistant: Assistant {
    private let model = SystemLanguageModel.default
    private let commands: any WindowCommands
    private let recorder = ActionRecorder()
    private var session: LanguageModelSession

    public init(commands: any WindowCommands) {
        self.commands = commands
        self.session = Self.makeSession(model: model, commands: commands, recorder: recorder)
    }

    public var availability: AssistantAvailability {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable("This Mac cannot run Apple Intelligence, so the on-device model is not available.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri, then try again.")
        case .unavailable(.modelNotReady):
            return .unavailable("The on-device model is still downloading. Try again in a few minutes.")
        case .unavailable:
            return .unavailable("The on-device model is not available right now.")
        }
    }

    public func reply(to text: String) async throws -> AssistantReply {
        recorder.clear()
        do {
            let response = try await session.respond(to: text, options: GenerationOptions(temperature: 0.2))
            return AssistantReply(text: response.content, actions: recorder.outcomes)
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error { throw AssistantError.contextFull }
            throw AssistantError.failed(error.localizedDescription)
        } catch let error as LanguageModelSession.ToolCallError {
            throw AssistantError.failed(String(describing: error.underlyingError))
        }
    }

    public func reset() {
        session = Self.makeSession(model: model, commands: commands, recorder: recorder)
    }

    public func prewarm() {
        guard case .available = model.availability else { return }
        session.prewarm()
    }

    // The on-device model has a small context window: few tools, short words.
    static let instructions = """
        You are Deskman. You move and arrange windows on the user's Mac. You act only by calling tools.
        - Move or resize one window: arrangeWindow. Use layout nextDisplay to send it to the other screen.
        - Focus, minimize, restore, close, hide, or full-screen a window: windowAction.
        - Put two or more named apps side by side: tileWindows. Arrange all windows, or organize: tileAllWindows.
        - Start an app: openApp. To open an app and place it, call openApp first, then arrangeWindow.
        - If you do not know which windows are open, call listWindows.
        - A window on another desktop can only be focused. Focus it to switch to that desktop.
        Name a window by its app, for example "Safari". Use "front" for the window the user is looking at.
        Never say you did something unless a tool said it succeeded. If a tool fails, tell the user why.
        When you are done, answer in one short sentence.
        """

    private static func makeSession(model: SystemLanguageModel, commands: any WindowCommands,
                                    recorder: ActionRecorder) -> LanguageModelSession {
        LanguageModelSession(
            model: model,
            tools: [
                ListWindowsTool(commands: commands),
                ArrangeWindowTool(commands: commands, recorder: recorder),
                WindowActionTool(commands: commands, recorder: recorder),
                TileWindowsTool(commands: commands, recorder: recorder),
                TileAllWindowsTool(commands: commands, recorder: recorder),
                OpenAppTool(commands: commands, recorder: recorder),
            ],
            instructions: instructions)
    }
}

/// Collects what the tools did during one reply, for the user interface.
@MainActor final class ActionRecorder {
    private(set) var outcomes: [CommandOutcome] = []
    func clear() { outcomes = [] }
    func record(_ outcome: CommandOutcome) -> String {
        outcomes.append(outcome)
        return outcome.message
    }
}
