// The contracts of the hexagon (ADR-2610101046 §3). Adapters depend on this
// target alone; it re-exports the domain value types the contracts use.
@_exported import DeskmanDomain

// All ports are main-actor bound: window control on macOS is main-thread work,
// and every call here is short.

// MARK: Driven (secondary) ports — what Deskman uses.

/// The desktop's windows. Frames are top-left, y down (see `CoordinateSpace`).
@MainActor public protocol WindowControl: AnyObject, Sendable {
    /// Every standard window of every regular app, front to back. Deskman's own windows are left out.
    func windows() -> [WindowSnapshot]
    /// Primary display first.
    func displays() -> [Display]
    /// The window the person was last looking at, outside Deskman.
    func frontmostWindowID() -> WindowID?
    /// One window's frame as it is now. `windows()` may be up to a second old (ADR-2610121200).
    func frame(of id: WindowID) -> Rect?
    func setFrame(_ frame: Rect, of id: WindowID) throws
    func perform(_ action: WindowAction, on id: WindowID) throws
    func launch(app: String) throws

    /// Whether macOS lets Deskman control other apps' windows (Accessibility permission).
    var isTrusted: Bool { get }
    /// Ask macOS to show the permission prompt.
    func requestTrust()
    /// Run `body` with every action in it attributed to `origin` (the gateway, ADR-2610121800).
    func acting<T>(for origin: ActionOrigin, _ body: () throws -> T) rethrows -> T
}

extension WindowControl {
    /// A control without a gateway has no rules to apply: it runs the body.
    public func acting<T>(for origin: ActionOrigin, _ body: () throws -> T) rethrows -> T { try body() }

    /// From `windows()`, for controls whose list is never stale.
    public func frame(of id: WindowID) -> Rect? { windows().first { $0.id == id }?.frame }
}

/// Names windows by what they are for (ADR-2610101542). Slow; never in a command's path.
@MainActor public protocol WindowNamer: AnyObject, Sendable {
    /// One name per window, in order: 2–5 words, with the project the window belongs to
    /// when the model sees one (ADR-2610120830). Throws when the model cannot answer.
    func names(for subjects: [NamingSubject]) async throws -> [NamedWindow]
}

/// What runs in terminal tabs now (ADR-2610101549): program names and folders,
/// never arguments. Reads; changes nothing.
@MainActor public protocol TerminalActivity: AnyObject, Sendable {
    func jobs() -> [TerminalJob]
}

/// Where the person's preferences are kept (ADR-2610120742). Not erased with the activity.
@MainActor public protocol PreferenceStore: AnyObject, Sendable {
    /// The defaults when nothing is saved yet. Throws when a saved file cannot be read.
    func load() throws -> Preferences
    func save(_ preferences: Preferences) throws
}

/// A language model that can run `WindowCommands` as tools.
@MainActor public protocol Assistant: AnyObject, Sendable {
    var availability: AssistantAvailability { get }
    /// Throws `AssistantError`.
    func reply(to text: String) async throws -> AssistantReply
    /// Forget the conversation.
    func reset()
    /// Load the model ahead of the first request.
    func prewarm()
}

// MARK: Driving (primary) ports — what may drive Deskman. Use cases implement these.

/// What the assistant's tools may do. Each call returns an outcome; none throws.
@MainActor public protocol WindowCommands: AnyObject, Sendable {
    func listWindows() -> [WindowSnapshot]
    /// The model's names for the windows it has named so far.
    func windowNames() -> [WindowID: String]
    func arrange(_ target: String, layout: Layout) -> CommandOutcome
    func act(_ action: WindowAction, on target: String) -> CommandOutcome
    func moveToNextDisplay(_ target: String) -> CommandOutcome
    /// Tile the windows of `apps`; an empty list means every visible window on the current display.
    func tile(apps: [String]) -> CommandOutcome
    /// Waits a short time for the app's first window, so a following `arrange` finds it.
    func open(app: String) async -> CommandOutcome
    /// Arrange the visible windows in zones Deskman draws (ADR-2610101523).
    /// `biggest` names the app that gets the most room; nil lets activity decide.
    func smartArrange(biggest: String?) -> CommandOutcome
}

/// What the user interface may do.
@MainActor public protocol DeskmanPort: AnyObject, Sendable {
    var status: DeskmanStatus { get }
    func requestWindowControlTrust()
    func send(_ text: String) async -> AssistantReply
    func reset()
    func prewarm()
}

/// What the snap hotkeys and drag-to-snap may do (ADR-2610101523 §4).
@MainActor public protocol SnapPort: AnyObject, Sendable {
    /// The snap zones of the display under `point`, for the drag overlay.
    func snapZones(at point: Point) -> [Rect]
    /// `zone` counts from 1, as the hotkeys do.
    func snapFrontmost(toZone zone: Int) -> CommandOutcome
    func fillFrontmost() -> CommandOutcome
    /// The mouse went down at `point`: remember the window under it.
    func beginDrag(at point: Point)
    /// True when that window has moved without changing size: a drag, not a click or a resize.
    func confirmDrag() -> Bool
    /// The zone the drop would snap to, while a confirmed drag goes on.
    func dragTarget(at point: Point) -> Int?
    /// The mouse went up. Nil when nothing was snapped.
    func endDrag(at point: Point, bypass: Bool) -> CommandOutcome?
}

/// The apps Deskman leaves alone, and the drag-to-snap switch (ADR-2610120742).
@MainActor public protocol SettingsPort: AnyObject, Sendable {
    /// Sorted.
    var floatingApps: [String] { get }
    func isFloating(_ app: String) -> Bool
    func setFloating(_ app: String, _ on: Bool) -> CommandOutcome
    /// Adds the front window's app, or removes it when it is already there.
    func toggleFloatingFrontmost() -> CommandOutcome
    var dragSnap: Bool { get }
    func setDragSnap(_ on: Bool) -> CommandOutcome
    /// Why the saved preferences could not be read, until the next change saves good ones.
    var problem: String? { get }
}

/// A project's windows, bound on the model's suggestion (ADR-2610120830).
@MainActor public protocol BindingPort: AnyObject, Sendable {
    /// Two apps' windows here that the model gave one project, not yet bound or declined.
    func suggestion() -> BindingSuggestion?
    func bind(_ project: String) -> CommandOutcome
    /// "Not now": never offered again.
    func decline(_ project: String) -> CommandOutcome
    func unbind(_ project: String) -> CommandOutcome
    var boundProjects: [String] { get }
    /// One look at the desktop: bound windows follow each other. Call it every second.
    func observe()
}

// MARK: Learning (ADR-2610101415)

/// Seconds since 1970. A port so tests can move time.
@MainActor public protocol TimeSource: AnyObject, Sendable {
    func now() -> Double
}

/// Where settled arrangements and the trust ledger are kept.
@MainActor public protocol ActivityStore: AnyObject, Sendable {
    func append(_ snapshot: DeskSnapshot) throws
    /// Oldest first.
    func snapshots() -> [DeskSnapshot]
    func ledger() -> TrustLedger
    func save(_ ledger: TrustLedger) throws
    func eraseAll() throws
}

/// What may drive learning: a timer calls `tick`; the person answers suggestions.
@MainActor public protocol ActivityPort: AnyObject, Sendable {
    /// Observe the desktop once. Call it every few seconds.
    func tick() -> TickResult
    var pending: Suggestion? { get }
    func accept() -> CommandOutcome
    /// Fails when the snooze could not be saved.
    @discardableResult func dismiss() -> CommandOutcome
    /// Smart Arrange with the best-fit layout. It can be undone, and earns no trust. `automatic`:
    /// Keep Arranged did it, not the person, and it never minimizes a window for being inactive.
    func smartArrange(automatic: Bool) -> CommandOutcome
    /// Keep Arranged (ADR-2610121130): Smart Arrange each time the desktop's windows change.
    var keepArranged: Bool { get }
    func setKeepArranged(_ on: Bool) -> CommandOutcome
    /// True when the windows changed and have settled: Smart Arrange now. Call it every second.
    func keepArrangedDue() -> Bool
    /// Why Keep Arranged last did or did not arrange, in words, for the trace.
    var keepArrangedState: String { get }
    /// Forget every pin: Smart Arrange may move every window again. Keep Arranged arranges at once.
    func unpinAll() -> CommandOutcome
    /// The last suggestion applied, by request or automatically; `undo` reverses it.
    var lastApplied: Suggestion? { get }
    /// What has been learned, one habit per app.
    func habits() -> [Habit]
    /// The desktop as the map draws it: windows, the Smart Arrange preview, habits.
    func desktopMap() -> DesktopMap
    /// "I like that": the habit's place counts as learned from now on.
    func confirm(_ habit: Habit) -> CommandOutcome
    /// Ask the model to name windows it has not named yet. Call it from a timer.
    func refreshNames() async
    /// Put back the windows the last applied suggestion moved.
    func undo() -> CommandOutcome
    var isPaused: Bool { get set }
    /// Erase every record and all earned trust.
    func forget() -> CommandOutcome
    var recordCount: Int { get }
}


public extension ActivityPort {
    /// Smart Arrange because the person asked.
    func smartArrange() -> CommandOutcome { smartArrange(automatic: false) }
}

/// One line per decision, in words, for the person (the user, 2026-10-12: "i need a log to know why
/// you are making certain decisions"). The adapter adds the time and keeps the file.
@MainActor public protocol DecisionLog: AnyObject {
    func record(_ line: String)
}
