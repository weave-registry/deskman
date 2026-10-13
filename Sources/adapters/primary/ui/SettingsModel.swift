import Observation
import Carbon.HIToolbox
import DeskmanPorts

/// The apps Deskman leaves alone and the drag-to-snap switch, for the menu and
/// the keys (ADR-2610120742). Talks to Deskman only through `SettingsPort`.
@MainActor @Observable public final class SettingsModel {
    public private(set) var floatingApps: [String] = []
    public private(set) var dragSnap = true
    public private(set) var problem: String?

    private let port: any SettingsPort
    /// Shows what a key or menu item did.
    private let report: @MainActor (CommandOutcome) -> Void
    @ObservationIgnored private var keys: [GlobalHotKey] = []

    /// `keys`: register Control-Option-F and D. A diagnose copy does not (ADR-2610121200).
    public init(port: any SettingsPort, keys registerKeys: Bool = true,
                report: @escaping @MainActor (CommandOutcome) -> Void) {
        self.port = port
        self.report = report
        refresh()
        guard registerKeys else { return }
        // Hammerspoon's keys: Control-Option-F floats the front app, Control-Option-D switches drag-to-snap.
        if let k = GlobalHotKey(keyCode: kVK_ANSI_F, modifiers: controlKey | optionKey, action: { [weak self] in
            self?.toggleFrontmost()
        }) { keys.append(k) }
        if let k = GlobalHotKey(keyCode: kVK_ANSI_D, modifiers: controlKey | optionKey, action: { [weak self] in
            guard let self else { return }
            self.setDragSnap(!self.dragSnap)
        }) { keys.append(k) }
    }

    /// How many of the two keys this Mac let Deskman have.
    public var registered: Int { keys.count }

    public func toggleFrontmost() { run(port.toggleFloatingFrontmost()) }
    public func setFloating(_ app: String, _ on: Bool) { run(port.setFloating(app, on)) }
    public func setDragSnap(_ on: Bool) { run(port.setDragSnap(on)) }

    private func run(_ outcome: CommandOutcome) {
        refresh()
        report(outcome)
    }

    private func refresh() {
        floatingApps = port.floatingApps
        dragSnap = port.dragSnap
        problem = port.problem
    }
}
