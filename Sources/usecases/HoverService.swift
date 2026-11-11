import DeskmanPorts

/// Expand on Hover (ADR-2611111000). The mouse resting on a stacked window gives it at least three
/// quarters of the stack's height; the others stay visible above and below it; leaving the stack puts
/// them all back. The layout is the domain's `HoverExpand`; this class keeps the one expansion there is.
@MainActor public final class HoverService: HoverPort {
    static let origin = ActionOrigin.person("hovering over a stacked window")

    private struct Expansion {
        /// Top to bottom.
        let order: [WindowID]
        let resting: [WindowID: Rect]
        /// The area the stack stands in, at rest.
        let column: Rect
        var hovered: WindowID
        /// Where each window really is now: what it took, which may not be what it was asked to take.
        var placed: [WindowID: Rect]
    }

    private let control: any WindowControl
    private let intents: IntentLog?
    private let settings: Settings?
    private var current: Expansion?
    private var pressed = false

    public init(control: any WindowControl, intents: IntentLog?, settings: Settings?) {
        self.control = control
        self.intents = intents
        self.settings = settings
    }

    public func pointerMoved(to point: Point) {
        guard let e = current, !e.column.contains(point) else { return }
        collapse()
    }

    public func pointerPressed() { pressed = true }
    public func pointerReleased() { pressed = false }

    public func pointerRested(at point: Point) {
        guard !pressed else { return }
        let all = control.windows()
        guard settings?.hoverExpand ?? true, control.isTrusted, !MeetingApps.inMeeting(all) else { return collapse() }
        if let e = current {
            guard !e.column.contains(point) else {
                // Inside the stack: the room goes to the window under the mouse, if it is not the one that has it.
                if let id = e.order.first(where: { e.placed[$0]?.contains(point) ?? false }), id != e.hovered,
                   let i = e.order.firstIndex(of: id) {
                    expand(e, index: i)
                }
                return
            }
            collapse()
        }
        start(at: point, in: all)
    }

    private func start(at point: Point, in all: [WindowSnapshot]) {
        // Only windows Deskman may move, and no meeting app: none is expanded, and none is squeezed.
        var candidates = all.filter {
            $0.isVisible && !(settings?.isFloating($0.app) ?? false) && !MeetingApps.contains($0.app)
        }
        guard let under = all.first(where: { $0.isVisible && $0.frame.contains(point) }),
              candidates.contains(where: { $0.id == under.id }),
              let loose = HoverExpand.stack(around: under.id, in: candidates) else { return }
        // The list may be a second old (ADR-2610121200), and just after a collapse it still shows the
        // expanded frames. The stack is read again, fresh, before anything is taken for its resting place.
        for w in loose {
            guard let fresh = control.frame(of: w.id), let i = candidates.firstIndex(where: { $0.id == w.id }) else { continue }
            candidates[i] = WindowSnapshot(id: w.id, app: w.app, title: w.title, frame: fresh, isMinimized: w.isMinimized,
                                           desktop: w.desktop, isOnCurrentDesktop: w.isOnCurrentDesktop, document: w.document)
        }
        guard let stack = HoverExpand.stack(around: under.id, in: candidates),
              let i = stack.firstIndex(where: { $0.id == under.id }), stack[i].frame.contains(point),
              let column = HoverExpand.column(of: stack.map(\.frame)) else { return }
        let resting = Dictionary(uniqueKeysWithValues: stack.map { ($0.id, $0.frame) })
        expand(Expansion(order: stack.map(\.id), resting: resting, column: column, hovered: under.id, placed: resting),
               index: i)
    }

    private func expand(_ e: Expansion, index: Int) {
        guard let frames = HoverExpand.layout(e.order.compactMap { e.resting[$0] }, expanding: index) else { return }
        var next = e
        next.hovered = e.order[index]
        for id in e.order { intents?.hoverBegan(id, resting: e.resting[id]!) }
        let targets = Dictionary(uniqueKeysWithValues: zip(e.order, frames))
        next.placed = move(e.order, to: targets, from: e.placed)
        current = next
    }

    /// Put every window back that is still where the hover left it.
    private func collapse() {
        guard let e = current else { return }
        current = nil
        // A window moved or resized by anything else meanwhile belongs to whoever did it.
        let ours = e.order.filter { id in
            guard let placed = e.placed[id], let now = control.frame(of: id) else { return false }
            return IntentLog.near(placed, now)
        }
        _ = move(ours, to: e.resting, from: e.placed)
        for id in e.order { intents?.hoverEnded(id) }
    }

    /// Move `ids` to `targets`, the shrinking ones first so no two overlap on the way. Returns where each is now.
    private func move(_ ids: [WindowID], to targets: [WindowID: Rect], from: [WindowID: Rect]) -> [WindowID: Rect] {
        var now = from
        let ordered = ids.filter { targets[$0] != nil && targets[$0] != from[$0] }
            .sorted { (targets[$0]!.height - (from[$0]?.height ?? 0)) < (targets[$1]!.height - (from[$1]?.height ?? 0)) }
        control.acting(for: Self.origin) {
            for id in ordered {
                let to = targets[id]!
                do {
                    try intents.map { try $0.transiently { try control.setFrame(to, of: id) } }
                        ?? control.setFrame(to, of: id)
                    now[id] = control.frame(of: id) ?? to
                } catch {
                    // A window that refuses (closed, another desktop) keeps its place; the others still move.
                    now[id] = control.frame(of: id) ?? now[id]
                }
            }
        }
        return now
    }
}
