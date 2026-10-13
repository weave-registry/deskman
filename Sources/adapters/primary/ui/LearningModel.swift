import Foundation
import Observation
import os
import DeskmanPorts

/// Drives learning: a timer calls `tick`, and a toast shows what came of it.
/// It talks to Deskman only through `ActivityPort`.
@MainActor @Observable public final class LearningModel {
    public enum Toast: Equatable {
        case suggestion(Suggestion)
        /// Windows moved; the card offers Undo.
        case applied(title: String, detail: String)
        case note(String)
        /// "These look like one project: bind them?" (ADR-2610120830)
        case binding(BindingSuggestion)
    }

    public private(set) var toast: Toast?
    public private(set) var recordCount = 0
    /// What has been learned, one habit per app. Updated when a record lands.
    public private(set) var habits: [Habit] = []
    /// The desktop map's data, refreshed while the map is open.
    public private(set) var map: DesktopMap?
    public var isPaused: Bool {
        get { port.isPaused }
        set { port.isPaused = newValue; refresh() }
    }

    private let port: any ActivityPort
    private let bindings: (any BindingPort)?
    /// Projects offered this run: an unanswered offer is not repeated until the next launch.
    private var offered: Set<String> = []
    public private(set) var boundProjects: [String] = []
    private var timer: Timer?
    private var followTimer: Timer?
    private var hideTask: Task<Void, Never>?
    /// Called when a toast appears or goes away, so the panel can show or hide.
    var onToastChange: ((Toast?) -> Void)?

    public static let interval: TimeInterval = 5

    public init(port: any ActivityPort, bindings: (any BindingPort)? = nil) {
        self.port = port
        self.bindings = bindings
        self.boundProjects = bindings?.boundProjects ?? []
        self.keepArranged = port.keepArranged
        self.recordCount = port.recordCount
        self.habits = port.habits()
    }

    public func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 1
        // Bound windows follow each other: a look every second (ADR-2610120830).
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.bindings?.observe()
                self?.watchKeepArranged()
            }
        }
        followTimer?.tolerance = 0.2
    }

    public func bind(_ s: BindingSuggestion) {
        guard let bindings else { return }
        let outcome = bindings.bind(s.project)
        boundProjects = bindings.boundProjects
        show(.note(outcome.message), for: outcome.succeeded ? 5 : 8)
    }

    public func declineBinding(_ s: BindingSuggestion) {
        guard let bindings else { return }
        let outcome = bindings.decline(s.project)
        if outcome.succeeded { hide() } else { show(.note(outcome.message), for: 8) }
    }

    public func unbind(_ project: String) {
        guard let bindings else { return }
        let outcome = bindings.unbind(project)
        boundProjects = bindings.boundProjects
        refreshMap()
        show(.note(outcome.message), for: 4)
    }

    func tick() {
        // Names come from the model in the background; only new windows reach it.
        Task { await port.refreshNames() }
        switch port.tick() {
        case .idle:
            // Nothing else to say: a binding the model found may be offered, once per run.
            if toast == nil, let s = bindings?.suggestion(), offered.insert(s.project).inserted {
                show(.binding(s), for: 20)
            }
        case .suggested(let s):
            show(.suggestion(s), for: 20)
        case .placedBeside(let s, let terminal):
            show(.applied(title: "Put \(s.moves.first?.app ?? "the browser") beside \(terminal).",
                          detail: "A new browser window goes next to your terminal."), for: 8)
        case .autoApplied(let s):
            show(.applied(title: s.summary + ".", detail: "Deskman did this because you always accept it."), for: 8)
        }
        refresh()
    }

    public func accept() {
        let outcome = port.accept()
        if outcome.succeeded { show(.note(outcome.message), for: 3) } else { show(.note(outcome.message), for: 5) }
    }

    public func dismiss() {
        let outcome = port.dismiss()
        if outcome.succeeded { hide() } else { show(.note(outcome.message), for: 6) }
    }

    /// Smart Arrange: windows fill the person's grid; none is minimized.
    public func smartArrange() {
        Task { await smartArrangeWithModel() }
    }

    /// Your grid (ADR-2610121700). `automatic`: Keep Arranged did it. It says nothing unless windows moved.
    public func smartArrangeWithModel(automatic: Bool = false) async {
        let outcome = port.smartArrange(automatic: automatic)
        lastOutcome = outcome.message
        refreshMap()
        if automatic {
            guard outcome.succeeded, port.lastApplied != nil || outcome.message.contains("out of the way") else { return }
            show(.applied(title: outcome.message, detail: "Keep Arranged. Undo puts everything back."), for: 6)
        } else if outcome.succeeded {
            show(.applied(title: outcome.message, detail: "Smart Arrange. Undo puts everything back."), for: 10)
        } else {
            show(.note(outcome.message), for: 6)
        }
    }

    // MARK: Keep Arranged (ADR-2610121130)

    public private(set) var keepArranged = false
    @ObservationIgnored private var lastOutcome: String?
    @ObservationIgnored private var arranging = false

    public func setKeepArranged(_ on: Bool) {
        let outcome = port.setKeepArranged(on)
        keepArranged = port.keepArranged
        show(.note(outcome.message), for: 4)
    }

    public func unpinAll() {
        show(.note(port.unpinAll().message), for: 4)
    }

    @ObservationIgnored private var lastTrace = ""
    /// NSLog's text is all `<private>` in the system log; this one is marked public.
    private static let trace = Logger(subsystem: "Deskman", category: "keep-arranged")

    /// Every second: when the windows changed and settled, Smart Arrange. One at a time.
    /// Each change of mind goes to the system log:
    /// `/usr/bin/log show --last 10m --predicate 'category == "keep-arranged"'`.
    private func watchKeepArranged() {
        guard !arranging else { return }
        let due = port.keepArrangedDue()
        let state = port.keepArrangedState
        if state != lastTrace {
            lastTrace = state
            Self.trace.notice("\(state, privacy: .public)")
        }
        guard due else { return }
        arranging = true
        Task {
            await smartArrangeWithModel(automatic: true)
            Self.trace.notice("outcome: \(self.lastOutcome ?? "none", privacy: .public)")
            arranging = false
        }
    }

    /// A short message on the card, for anything that reports an outcome.
    public func note(_ text: String) {
        show(.note(text), for: 4)
    }

    public func refreshMap() {
        let m = port.desktopMap()
        if m != map { map = m }
    }

    /// From the map: "I like that place".
    public func confirm(_ habit: Habit) {
        let outcome = port.confirm(habit)
        habits = port.habits()
        refreshMap()
        show(.note(outcome.message), for: 4)
    }

    public func undo() {
        let outcome = port.undo()
        show(.note(outcome.message), for: 3)
    }

    public func forget() {
        let outcome = port.forget()
        refresh()
        show(.note(outcome.message), for: 4)
    }

    public func hide() {
        hideTask?.cancel()
        toast = nil
        onToastChange?(nil)
    }

    private func show(_ t: Toast, for seconds: Double) {
        toast = t
        onToastChange?(t)
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            // An unanswered suggestion just goes away. Silence is not a "no".
            self?.hide()
        }
    }

    private func refresh() {
        let n = port.recordCount
        guard n != recordCount else { return }
        recordCount = n
        habits = port.habits()
    }
}
