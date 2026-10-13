import AppKit
import SwiftUI
import Carbon.HIToolbox
import DeskmanPorts

/// The snap hotkeys: Control-Command-1…5 put the front window in a zone, Control-Command-F
/// fills the screen (ADR-2610101523 §4, the keys Hammerspoon used).
@MainActor public final class SnapHotKeys {
    private var keys: [GlobalHotKey] = []

    public init(port: any SnapPort, report: @escaping @MainActor (CommandOutcome) -> Void) {
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]
        for (i, code) in digits.enumerated() {
            if let k = GlobalHotKey(keyCode: code, modifiers: controlKey | cmdKey, action: {
                let o = port.snapFrontmost(toZone: i + 1)
                if !o.succeeded { report(o) }
            }) { keys.append(k) }
        }
        if let k = GlobalHotKey(keyCode: kVK_ANSI_F, modifiers: controlKey | cmdKey, action: {
            let o = port.fillFrontmost()
            if !o.succeeded { report(o) }
        }) { keys.append(k) }
    }

    /// How many of the six keys this Mac let Deskman have.
    public var registered: Int { keys.count }
}

/// Drag a window and drop it on a zone. A listen-only mouse event tap; Option held
/// while letting go skips the snap. A click or a resize never snaps (SnapService).
@MainActor public final class DragSnap {
    private let port: any SnapPort
    private var tap: CFMachPort?
    private let overlay = SnapOverlay()
    private var down: Point?
    private var checked = false
    private var confirmed = false

    /// Nil when macOS refuses the event tap (no Accessibility permission).
    public init?(port: any SnapPort) {
        self.port = port
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            // The tap's source is on the main run loop, so this runs on the main thread.
            let snap = Unmanaged<DragSnap>.fromOpaque(info!).takeUnretainedValue()
            MainActor.assumeIsolated { snap.handle(type, event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return nil }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        // CGEvent locations are top-left, y down: the hexagon's own convention.
        let p = Point(x: event.location.x, y: event.location.y)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            down = p
            checked = false
            confirmed = false
            port.beginDrag(at: p)
        case .leftMouseDragged:
            guard let d = down else { return }
            if !checked, abs(p.x - d.x) + abs(p.y - d.y) > 20 {
                checked = true
                // Let the app move the window first, then look once.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, self.down != nil else { return }
                    self.confirmed = self.port.confirmDrag()
                    if self.confirmed { self.overlay.show(self.port.snapZones(at: p)) }
                }
            }
            if confirmed { overlay.highlight(port.dragTarget(at: p)) }
        case .leftMouseUp:
            guard down != nil else { return }
            down = nil
            overlay.hide()
            _ = port.endDrag(at: p, bypass: event.flags.contains(.maskAlternate))
        default:
            break
        }
    }
}

/// The zones drawn over the screen while a window is dragged; the one under the
/// mouse is green. It takes no clicks.
@MainActor final class SnapOverlay {
    @Observable final class State {
        var zones: [CGRect] = []
        var active: Int?
    }

    private let panel: NSPanel
    private let state = State()

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: SnapOverlayView(state: state))
    }

    func show(_ zones: [Rect]) {
        guard !zones.isEmpty, let primary = NSScreen.screens.first else { return }
        let x0 = zones.map(\.x).min()!, y0 = zones.map(\.y).min()!
        let x1 = zones.map(\.maxX).max()!, y1 = zones.map(\.maxY).max()!
        let area = Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        let appKit = CoordinateSpace.appKit(fromTopLeft: area, primaryDisplayHeight: Double(primary.frame.height))
        panel.setFrame(NSRect(x: appKit.x, y: appKit.y, width: appKit.width, height: appKit.height), display: false)
        state.zones = zones.map { CGRect(x: $0.x - x0, y: $0.y - y0, width: $0.width, height: $0.height) }
        state.active = nil
        panel.orderFrontRegardless()
    }

    func highlight(_ zone: Int?) {
        if state.active != zone { state.active = zone }
    }

    func hide() {
        panel.orderOut(nil)
        state.zones = []
    }
}

private struct SnapOverlayView: View {
    let state: SnapOverlay.State

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(state.zones.enumerated()), id: \.offset) { i, z in
                let on = i == state.active
                RoundedRectangle(cornerRadius: 12)
                    .fill((on ? Color.green : Color.blue).opacity(on ? 0.25 : 0.10))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder((on ? Color.green : Color.white).opacity(0.85), lineWidth: on ? 3 : 1.5))
                    .overlay(Text("\(i + 1)").font(.system(size: 40, weight: .bold)).foregroundStyle(.white.opacity(0.8)))
                    .frame(width: z.width - 12, height: z.height - 12)
                    .position(x: z.midX, y: z.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
