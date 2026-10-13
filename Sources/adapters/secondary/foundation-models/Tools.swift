import FoundationModels
import DeskmanPorts

// The five tools the model may call. Each one forwards to `WindowCommands` and
// returns the outcome's message as text — a failure is something the model reads
// and answers, not an exception that ends the reply (ADR-2610101046 §6).

private let targetGuide = "The window's app name, like \"Safari\", or \"front\" for the window the user is looking at."

struct ListWindowsTool: Tool {
    let name = "listWindows"
    let description = "List the open windows on every desktop, with their app and title."
    let commands: any WindowCommands

    @Generable struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let windows = await commands.listWindows()
        let names = await commands.windowNames()
        guard !windows.isEmpty else { return "No windows are open." }
        // Short lines: every token here comes out of a 4,096-token context.
        func line(_ w: WindowSnapshot) -> String {
            // English only (EnglishOnly): a title in another language can make the model refuse the whole turn.
            let title = EnglishOnly.text(w.title.count > 40 ? String(w.title.prefix(40)) + "..." : w.title)
            let named = names[w.id].map { " [\(EnglishOnly.text($0))]" } ?? ""
            return "- \(EnglishOnly.text(w.app))" + (title.isEmpty ? "" : ": \(title)") + named + (w.isMinimized ? " (minimized)" : "")
        }
        // Other desktops last, under their own heading: listed among the rest, the
        // model took "my other screen" to mean a window on desktop 2 (DeskmanEval).
        let here = windows.filter(\.isOnCurrentDesktop).prefix(25).map(line)
        let away = windows.filter { !$0.isOnCurrentDesktop }.prefix(10).map { line($0) + " (\($0.desktopPhrase))" }
        return (here + (away.isEmpty ? [] : ["Other desktops, focus only:"] + away)).joined(separator: "\n")
    }
}

/// `nextDisplay` rides along with the layouts so the model needs one tool, not two, to place a window.
private let nextDisplay = "nextDisplay"

struct ArrangeWindowTool: Tool {
    let name = "arrangeWindow"
    let description = "Move and resize one window to a place on its screen, or to the next screen. To maximize or fill the screen, use layout maximize."
    let commands: any WindowCommands
    let recorder: ActionRecorder

    @Generable struct Arguments {
        @Guide(description: targetGuide)
        var target: String
        @Guide(description: "Where to put the window.", .anyOf(Layout.allCases.map(\.rawValue) + [nextDisplay]))
        var layout: String
    }

    func call(arguments: Arguments) async throws -> String {
        let outcome: CommandOutcome
        if arguments.layout == nextDisplay {
            outcome = await commands.moveToNextDisplay(arguments.target)
        } else if let layout = Layout(rawValue: arguments.layout) {
            outcome = await commands.arrange(arguments.target, layout: layout)
        } else {
            outcome = .failed("Unknown layout \(arguments.layout).")
        }
        return await recorder.record(outcome)
    }
}

struct WindowActionTool: Tool {
    let name = "windowAction"
    let description = "Focus (switch to), minimize, restore, close, or hide a window. fullScreen moves the window to its own Space; use it only when the user says full screen."
    let commands: any WindowCommands
    let recorder: ActionRecorder

    @Generable struct Arguments {
        @Guide(description: targetGuide)
        var target: String
        @Guide(description: "What to do.", .anyOf(WindowAction.allCases.map(\.rawValue)))
        var action: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let action = WindowAction(rawValue: arguments.action) else {
            return await recorder.record(.failed("Unknown action \(arguments.action)."))
        }
        return await recorder.record(commands.act(action, on: arguments.target))
    }
}

struct TileWindowsTool: Tool {
    let name = "tileWindows"
    let description = "Arrange two or more named apps side by side or in a grid. For one window, use arrangeWindow. For all windows, use tileAllWindows."
    let commands: any WindowCommands
    let recorder: ActionRecorder

    @Generable struct Arguments {
        @Guide(description: "The app names the user said, left to right. Only apps the user named.")
        var apps: [String]
    }

    func call(arguments: Arguments) async throws -> String {
        // An empty list would tile everything; that is tileAllWindows' job, not this tool's.
        guard !arguments.apps.isEmpty else {
            return await recorder.record(.failed("Name the apps to tile, or use tileAllWindows."))
        }
        // One app is a placement, not a tiling. Saying so lets the model retry correctly.
        guard arguments.apps.count > 1 else {
            return await recorder.record(.failed(
                "tileWindows needs two or more apps. To place one window, call arrangeWindow with a layout."))
        }
        return await recorder.record(commands.tile(apps: arguments.apps))
    }
}

// Its own tool, not a flag on tileWindows. With a flag, the small model either
// invented app names for "all my windows" or tiled everything for "Notes and Mail",
// depending on field order (DeskmanEval, 2026-10-10). Choosing a tool it does well.
struct TileAllWindowsTool: Tool {
    let name = "tileAllWindows"
    let description = "Arrange every visible window on the current screen. Use when the user says all, every, or everything."
    let commands: any WindowCommands
    let recorder: ActionRecorder

    @Generable struct Arguments {}

    // Smart Arrange, not a grid (ADR-2610101501 amendment): a seventh tool cost the
    // small model "this window" in other requests, so this one changed its meaning.
    func call(arguments: Arguments) async throws -> String {
        return await recorder.record(commands.smartArrange(biggest: nil))
    }
}

struct OpenAppTool: Tool {
    let name = "openApp"
    let description = "Start an app that is not open yet. To switch to an app that is already open, use windowAction focus."
    let commands: any WindowCommands
    let recorder: ActionRecorder

    @Generable struct Arguments {
        @Guide(description: "The app's name, like \"Calendar\".")
        var app: String
    }

    func call(arguments: Arguments) async throws -> String {
        await recorder.record(commands.open(app: arguments.app))
    }
}
