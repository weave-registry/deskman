import DeskmanPorts

/// Watches the desktop, remembers settled arrangements, and offers them back
/// (ADR-2610101415). Every decision is the domain's `Learner` and `TrustLedger`;
/// this class only keeps time and talks to the ports.
@MainActor public final class ActivityService: ActivityPort {
    private let control: any WindowControl
    private let store: any ActivityStore
    private let clock: any TimeSource
    private let arranger: SmartArranger?
    private let focus: FocusTracker?
    private let intents: IntentLog?
    private let names: WindowNames?
    private let terminals: TerminalWatch?
    /// Where each decision is written, in words (DecisionLog).
    private let decisions: (any DecisionLog)?
    /// The learned grid (ADR-2610131157), relearned when a record lands; without it, the standard one.
    private let grid: LearnedGrid?
    private let settings: Settings?
    private let bindings: BindingService?
    /// Windows the last Smart Arrange minimized; `undo` restores them.
    private let settleSeconds: Double
    private let suggestDelay: Double

    private var ledger: TrustLedger

    // The arrangement now on screen, and since when.
    private var arrangement: [WindowRecord] = []
    private var arrangementSince = 0.0
    private var arrangementRecorded = false

    // The situation now on screen, and whether it has had its one suggestion.
    private var context: ContextKey?
    private var contextSince = 0.0
    private var contextEvaluated = false

    /// Every window seen so far; nil before the first tick, so what is open at start never moves.
    private var seen: Set<WindowID>?

    public private(set) var pending: Suggestion?
    /// The last applied suggestion, kept for undo.
    private var applied: Suggestion?
    /// Whether `applied` came from the `Learner`; only those earn or lose trust on undo.
    private var appliedIsLearned = false
    public var isPaused = false

    public init(control: any WindowControl, store: any ActivityStore, clock: any TimeSource,
                settleSeconds: Double = 30, suggestDelay: Double = 5, arranger: SmartArranger? = nil,
                focus: FocusTracker? = nil, intents: IntentLog? = nil, names: WindowNames? = nil,
                terminals: TerminalWatch? = nil, settings: Settings? = nil, bindings: BindingService? = nil,
                decisions: (any DecisionLog)? = nil, grid: LearnedGrid? = nil) {
        self.grid = grid
        self.decisions = decisions
        self.settings = settings
        self.bindings = bindings
        self.names = names
        self.terminals = terminals
        self.control = control
        self.arranger = arranger
        self.focus = focus
        self.intents = intents
        self.store = store
        self.clock = clock
        self.settleSeconds = settleSeconds
        self.suggestDelay = suggestDelay
        self.ledger = store.ledger()
    }

    public var recordCount: Int { store.snapshots().count }

    public func tick() -> TickResult {
        guard !isPaused, control.isTrusted else {
            seen = nil   // after a pause, what is open then is the new start
            return .idle
        }
        let now = clock.now()
        let windows = control.windows()
        let displays = control.displays()
        let front = control.frontmostWindowID().flatMap { id in windows.first { $0.id == id } }
        let focused = front?.app
        intents?.observe(windows)
        let snapshot = DeskSnapshot(time: now, windows: windows, displays: displays, focusedApp: focused,
                                    placedByDeskman: intents?.placedByDeskman(windows) ?? [],
                                    placedByPerson: intents?.pinned() ?? [])
        focus?.record(app: focused, window: front?.id)

        recordIfSettled(snapshot, now: now)
        // During a meeting Deskman watches but moves nothing on its own: no browser placed, no habit
        // suggested or applied (the user, 2026-10-12: "if we are sharing an app we dont want to change anything").
        guard !MeetingApps.inMeeting(windows) else { pending = nil; return .idle }
        if let (placed, terminal) = placeNewBrowser(windows, displays: displays) {
            return .placedBeside(placed, terminal: terminal)
        }

        let ctx = snapshot.context
        if ctx != context {
            context = ctx
            contextSince = now
            contextEvaluated = false
            pending = nil
        }
        guard !contextEvaluated, now - contextSince >= suggestDelay else { return .idle }
        contextEvaluated = true

        guard !ledger.isSnoozed(ctx, now: now),
              let suggestion = Learner.suggestion(for: movable(windows), displays: displays, history: store.snapshots(),
                                                  confirmed: ledger.confirmedPlaces)
        else { return .idle }

        if ledger.isAutomatic(ctx) {
            return apply(suggestion, origin: .automatic("a learned habit")).succeeded ? .autoApplied(suggestion) : .idle
        }
        pending = suggestion
        return .suggested(suggestion)
    }

    public func accept() -> CommandOutcome {
        guard let suggestion = pending else { return .failed("There is no suggestion to apply.") }
        pending = nil
        let outcome = apply(suggestion, origin: .person("you accepted a suggestion"))
        guard outcome.succeeded else { return outcome }
        ledger.recordAccept(suggestion.context)
        return persistLedger().map { .ok(outcome.message + " " + $0) } ?? outcome
    }

    @discardableResult public func dismiss() -> CommandOutcome {
        guard let suggestion = pending else { return .failed("There is no suggestion to dismiss.") }
        pending = nil
        ledger.recordDismiss(suggestion.context, now: clock.now())
        return persistLedger().map { .failed($0) } ?? .ok("Dismissed.")
    }

    public func undo() -> CommandOutcome {
        guard applied != nil else { return .failed("There is nothing to undo.") }
        // Only what really went back is forgotten; the rest stays, so a second undo tries again.
        var failures: [String] = []
        let undone = applied
        if let suggestion = undone {
            let stayed = suggestion.moves.reversed().filter { move in
                do { try control.acting(for: .person("Undo")) { try control.setFrame(move.from, of: move.id) }; return false } catch {
                    failures.append("\(move.app): \(error)")
                    return true
                }
            }
            applied = stayed.isEmpty ? nil
                : Suggestion(context: suggestion.context, moves: stayed.reversed(), evidence: suggestion.evidence)
        }
        guard failures.isEmpty else {
            return .failed("Could not put back \(failures.joined(separator: "; ")). Try Undo again.")
        }
        guard let suggestion = undone else { return .ok("Brought the windows back.") }
        let done = "Put \(suggestion.moves.count == 1 ? "the window" : "the windows") back."
        // Undoing a move Deskman chose is the clearest "no" there is.
        guard appliedIsLearned else { return .ok(done) }
        ledger.recordDismiss(suggestion.context, now: clock.now())
        return .ok(persistLedger().map { done + " " + $0 } ?? done)
    }


    public var lastApplied: Suggestion? { applied }

    // MARK: Keep Arranged (ADR-2610121130)

    /// A change must stay the same this long, so a burst causes one arrange.
    static let settleSeconds = 1.5
    /// The windows as Smart Arrange last left them; nil arranges at once.
    private var arrangedSet: Set<WindowID>?
    private var changedSet: Set<WindowID>?
    private var changedSince = 0.0
    /// The window Keep Arranged left alone because it was in front, while it waits for its place.
    private var heldActive: WindowID?

    public var keepArranged: Bool { settings?.keepArranged ?? false }

    public func setKeepArranged(_ on: Bool) -> CommandOutcome {
        guard let settings else { return .failed("Keep Arranged is not set up.") }
        arrangedSet = nil
        changedSet = nil
        return settings.setKeepArranged(on)
    }

    /// The visible windows Deskman may move, on the desktop on screen. Moving one changes nothing here.
    private func watchedSet() -> Set<WindowID> {
        Set(movable(control.windows()).filter { $0.isVisible && !MeetingApps.contains($0.app) }.map(\.id))
    }

    /// Why Keep Arranged last did or did not arrange, for the trace.
    public private(set) var keepArrangedState = "on: it takes its first look within a second" {
        didSet { if keepArrangedState != oldValue { decisions?.record("Keep Arranged: \(keepArrangedState)") } }
    }

    public func keepArrangedDue() -> Bool {
        // Its own switch only: pausing learning does not stop it.
        guard keepArranged, control.isTrusted else {
            arrangedSet = nil
            keepArrangedState = !keepArranged ? "off" : "no Accessibility permission"
            return false
        }
        // During a meeting nothing moves: a share shows every move (MeetingApps). The baseline stays,
        // so what changed meanwhile is arranged once the meeting ends.
        guard !MeetingApps.inMeeting(control.windows()) else {
            keepArrangedState = "paused: a meeting is on"
            return false
        }
        let now = clock.now()
        let set = watchedSet()
        guard let arranged = arrangedSet else {
            keepArrangedState = "arranging: first look, \(set.count) windows"
            return true
        }
        guard set != arranged else {
            changedSet = nil
            // A window held because it was in front gets its place once the person moves on.
            if let held = heldActive {
                guard control.frontmostWindowID() != held else {
                    keepArrangedState = "waiting: the active window keeps its place until you move on"
                    return false
                }
                heldActive = nil
                keepArrangedState = "arranging: the held window is no longer active"
                return true
            }
            keepArrangedState = "watching \(set.count) windows"
            return false
        }
        if set != changedSet {
            changedSet = set
            changedSince = now
            keepArrangedState = "changed: \(arranged.count) → \(set.count) windows, waiting to settle"
            return false
        }
        guard now - changedSince >= Self.settleSeconds else { return false }
        keepArrangedState = "arranging: \(set.count) windows settled"
        return true
    }

    public func unpinAll() -> CommandOutcome {
        guard let intents else { return .failed("Pins are not set up.") }
        let n = intents.pinned().count
        intents.unpinAll()
        arrangedSet = nil
        return .ok(n == 0 ? "No window was pinned." : "Unpinned \(n) window\(n == 1 ? "" : "s"). Smart Arrange may move \(n == 1 ? "it" : "them") again.")
    }

    /// What Smart Arrange left on screen is the new baseline.
    public func keepArrangedSettled() {
        arrangedSet = watchedSet()
        changedSet = nil
    }

    public func smartArrange(automatic: Bool) -> CommandOutcome {
        guard control.isTrusted else { return .failed("Deskman needs Accessibility permission to move windows.") }
        guard let arranger else { return .failed("Smart Arrange is not set up.") }
        // What the person opened or brought back since the last arrange: never moved out of the way again.
        let fresh = arrangedSet.map { watchedSet().subtracting($0) } ?? []
        // Keep Arranged never moves the window the person is working in. If the best plan would,
        // that window is held where it is, and gets its place once it is no longer in front.
        decisions?.record(automatic ? "Smart Arrange: Keep Arranged saw the windows change." : "Smart Arrange: you asked.")
        heldActive = nil
        if automatic, let front = control.frontmostWindowID(),
           case .plan(_, let moves, _, _) = arranger.prepare(biggest: nil, keep: fresh),
           moves.contains(where: { $0.id == front }) {
            heldActive = front
        }
        switch arranger.prepare(biggest: nil, keep: fresh, hold: heldActive) {
        case .failed(let outcome):
            // Also a baseline: Keep Arranged must not retry the same failure every second.
            keepArrangedSettled()
            return outcome
        case .plan(let plan, let moves, _, let note):
            pending = nil
            for r in arranger.lastReasons { decisions?.record("  " + r) }
            // Each move is recorded by the gateway, decided and done (ADR-2610121800).
            if !moves.isEmpty {
                // A Suggestion, so `undo` puts it back. Its context earns nothing: no ledger write.
                let suggestion = Suggestion(context: ContextKey(apps: moves.map(\.app), displays: control.displays().count),
                                            moves: moves, evidence: 0)
                let outcome = apply(suggestion, learned: false,
                                    origin: automatic ? .automatic("Keep Arranged") : .person("Smart Arrange"))
                guard outcome.succeeded else { return outcome }
            } else {
                applied = nil
                lastFailures = []
            }
            // Read back: an app that will not fit its zone is named, not chased. The grid does not move.
            for r in arranger.refusals(moves) { decisions?.record("  " + r) }
            keepArrangedSettled()
            let result = SmartArranger.message(plan, moved: moves.count - lastFailures.count, note: note,
                                               failed: lastFailures)
            decisions?.record("  Result: " + result)
            return .ok(result)
        }
    }

    public func desktopMap() -> DesktopMap {
        let all = control.windows()
        let displays = control.displays()
        let shown = all.filter(\.isVisible)
        let none: (zones: [DesktopMap.PlannedZone], parked: [String], note: String?) = ([], [], nil)
        let preview = control.isTrusted ? arranger?.previewPlan() ?? none : none
        let habits = self.habits().compactMap { h -> DesktopMap.HabitZone? in
            guard displays.indices.contains(h.placement.display) else { return nil }
            return DesktopMap.HabitZone(frame: h.placement.frame(on: displays[h.placement.display]), habit: h)
        }
        return DesktopMap(displays: displays, windows: shown, hiddenCount: all.count - shown.count,
                          otherDesktops: all.filter { !$0.isOnCurrentDesktop && !$0.isMinimized },
                          plan: preview.zones, parked: preview.parked,
                          pinned: (intents?.pinned() ?? []).intersection(shown.map(\.id)), habits: habits,
                          names: names?.names(for: all) ?? [:], namingProblem: names?.lastError,
                          jobs: (terminals?.match(all).byWindow ?? [:]).mapValues { $0.map(\.phrase) },
                          bound: bindings?.boundProject(of: all) ?? [:], planNote: preview.note,
                          knowledge: knowledge(shown, displays: displays), grids: grids(displays))
    }

    /// What Deskman knows, in words (ADR-2610121600): what it already holds, nothing new stored.
    private func knowledge(_ shown: [WindowSnapshot], displays: [Display]) -> DesktopMap.Knowledge {
        var zones: [WindowID: String] = [:]
        for w in shown {
            if let d = Displays.containing(w.frame, in: displays),
               let z = GridPlanner.zoneLabel(of: w.frame, on: d, shape: grid?.shape(on: d)) {
                zones[w.id] = z
            }
        }
        return .build(windows: shown, focus: focus?.windowActivity() ?? [:], names: names?.names(for: shown) ?? [:],
                      zones: zones, keepArranged: keepArranged ? keepArrangedState : "Off. Turn it on in the menu.",
                      bound: settings?.boundProjects ?? [], habits: habits(), displays: displays,
                      grids: grids(displays), grid: displays.first.map { grid?.describe(on: $0) ?? "" } ?? "")
    }

    /// The learned shape of each display, by index; a display on the standard grid is not here.
    private func grids(_ displays: [Display]) -> [Int: GridShape] {
        var shapes: [Int: GridShape] = [:]
        for d in displays { shapes[d.index] = grid?.shape(on: d) }
        return shapes
    }

    public func refreshNames() async {
        guard let names, control.isTrusted else { return }
        // This desktop first: those are the windows the person is looking for.
        let all = control.windows()
        await names.refresh(all.filter(\.isVisible) + all.filter { !$0.isVisible },
                            terminals: terminals?.match(all) ?? .none)
    }

    public func habits() -> [Habit] {
        Learner.habits(in: store.snapshots(), confirmed: ledger.confirmedPlaces)
    }

    public func confirm(_ habit: Habit) -> CommandOutcome {
        // Change a copy: if the save fails, the confirmation must not take effect.
        var next = ledger
        next.confirm(app: habit.app, placement: habit.placement)
        do {
            try store.save(next)
        } catch {
            return .failed("Could not save that: \(error).")
        }
        ledger = next
        return .ok("Got it: \(habit.app) goes in \(habit.placement.phrase).")
    }

    public func forget() -> CommandOutcome {
        do {
            try store.eraseAll()
        } catch {
            return .failed("Could not erase the activity history: \(error).")
        }
        ledger = TrustLedger()
        arrangement = []
        arrangementRecorded = false
        pending = nil
        applied = nil
        return .ok("Erased all activity history and learned habits.")
    }

    // MARK: -

    /// Floating apps are left out of every move Deskman chooses (ADR-2610120742).
    private func movable(_ windows: [WindowSnapshot]) -> [WindowSnapshot] {
        settings?.movable(windows) ?? windows
    }

    /// One new browser window, with a terminal on its display: it goes in the snap zone
    /// beside the terminal (ADR-2610101501 queue item 4). A busy terminal is preferred.
    private func placeNewBrowser(_ windows: [WindowSnapshot], displays: [Display]) -> (Suggestion, String)? {
        let ids = Set(windows.map(\.id))
        defer { seen = (seen ?? []).union(ids) }
        guard let seen, let terminals else { return nil }
        let fresh = windows.filter { !seen.contains($0.id) && $0.isVisible }
        // Several at once is a browser restoring its session, not a person opening one.
        guard fresh.count == 1, let browser = fresh.first, Browsers.contains(browser.app),
              !(settings?.isFloating(browser.app) ?? false),
              let display = Displays.containing(browser.frame, in: displays) else { return nil }
        let match = terminals.match(windows)
        let terminalApps = Set(terminals.jobs().map { $0.app.lowercased() })
        let here = windows.filter {
            $0.isVisible && terminalApps.contains($0.app.lowercased()) && Displays.containing($0.frame, in: displays) == display
        }
        let busy = match.busyWindows(among: here)
        guard let terminal = here.first(where: { busy.contains($0.id) }) ?? here.first,
              let to = ZoneGenerator.zone(beside: terminal.frame, in: ZoneGenerator.snapZones(on: display, shape: grid?.shape(on: display))) else { return nil }
        let suggestion = Suggestion(context: ContextKey(apps: [browser.app, terminal.app], displays: displays.count),
                                    moves: [Move(id: browser.id, app: browser.app, from: browser.frame, to: to)], evidence: 0)
        return apply(suggestion, learned: false, origin: .automatic("a new browser beside its terminal")).succeeded
            ? (suggestion, terminal.app) : nil
    }

    private func recordIfSettled(_ snapshot: DeskSnapshot, now: Double) {
        if snapshot.windows != arrangement {
            arrangement = snapshot.windows
            arrangementSince = now
            arrangementRecorded = false
            return
        }
        guard !arrangementRecorded, now - arrangementSince >= settleSeconds, !snapshot.windows.isEmpty else { return }
        // Only a write that lands counts; a failed one is tried again on the next tick.
        do {
            try store.append(snapshot)
            grid?.relearn(displays: control.displays())
            arrangementRecorded = true
        } catch {}
    }

    /// The windows the last `apply` could not move, with why.
    private var lastFailures: [String] = []

    /// `origin`: who asked, for the gateway (ADR-2610121800).
    private func apply(_ suggestion: Suggestion, learned: Bool = true, origin: ActionOrigin) -> CommandOutcome {
        var failures: [String] = []
        control.acting(for: origin) {
            for move in suggestion.moves {
                do { try control.setFrame(move.to, of: move.id) } catch { failures.append("\(move.app): \(error)") }
            }
        }
        lastFailures = failures
        guard failures.count < suggestion.moves.count else {
            return .failed("Could not move \(failures.joined(separator: "; ")).")
        }
        applied = suggestion
        appliedIsLearned = learned
        return .ok(suggestion.summary + ".")
    }

    /// Saves the ledger; nil when it landed, else the sentence that tells the person.
    /// The windows already moved, so the caller still reports what it did.
    private func persistLedger() -> String? {
        do {
            try store.save(ledger)
            return nil
        } catch {
            return "Deskman could not save this, so it will forget it when it quits: \(error)."
        }
    }
}
